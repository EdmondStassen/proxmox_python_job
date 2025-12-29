#!/usr/bin/env bash
# Draait op de Proxmox host

set -e

# Community-scripts core inladen
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main/misc/build.func)

# ================== BASIS-INFO OVER DE APP ==================
APP="Python uv cron"
var_tags="${var_tags:-python;uv;cron}"     # tags voor in Proxmox
var_cpu="${var_cpu:-1}"                    # CPU cores
var_ram="${var_ram:-512}"                  # RAM in MB
var_disk="${var_disk:-4}"                  # Disk in GB
var_os="${var_os:-debian}"                 # debian/ubuntu/alpine
var_version="${var_version:-13}"           # Debian 13
var_unprivileged="${var_unprivileged:-1}"  # unprivileged LXC

# ================== INTERACTIEVE VRAGEN ==================

echo
echo "=============================================="
echo "   ${APP} - interactieve configuratie"
echo "=============================================="
echo

# 0) Containernaam / hostname opvragen
DEFAULT_HN="${HN:-$(echo "$APP" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')}"
while true; do
  read -rp "Naam/hostname voor de nieuwe container [${DEFAULT_HN}]: " INPUT_HN
  HN="${INPUT_HN:-$DEFAULT_HN}"

  # eenvoudige validatie: letters, cijfers en koppeltekens, begint met letter/cijfer
  if [[ "$HN" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
    break
  else
    echo "Ongeldige naam. Gebruik alleen letters, cijfers en koppeltekens, en laat niet beginnen met een koppelstreep."
  fi
done
export HN

# 1) Proxmox LXC root-wachtwoord genereren + eventueel overschrijven
echo "Er wordt automatisch een sterk root-wachtwoord voor de LXC gegenereerd."
GEN_ROOT_PW="$(tr -dc 'A-Za-z0-9!@#$%_-+=' </dev/urandom | head -c 20 || true)"
if [[ -z "$GEN_ROOT_PW" ]]; then
  GEN_ROOT_PW="Pve$(date +%s%N | sha256sum | head -c 12)!"
fi

echo
echo "Voorgesteld root-wachtwoord voor de LXC:"
echo "  $GEN_ROOT_PW"
echo

ROOT_PW=""
while true; do
  read -srp "Druk Enter om dit wachtwoord te gebruiken, of voer een eigen wachtwoord in: " PW1
  echo
  if [[ -z "$PW1" ]]; then
    ROOT_PW="$GEN_ROOT_PW"
    echo "Gegenereerd wachtwoord wordt gebruikt."
    break
  else
    read -srp "Herhaal het eigen wachtwoord: " PW2
    echo
    if [[ "$PW1" != "$PW2" ]]; then
      echo "Wachtwoorden komen niet overeen, probeer opnieuw."
    else
      ROOT_PW="$PW1"
      echo "Eigen wachtwoord wordt gebruikt."
      break
    fi
  fi
done
export ROOT_PW

# Helper: multi-line geheim (deploy key) inlezen
prompt_multiline_secret() {
  local label="$1"
  local varname="$2"
  local line data=""
  echo
  echo "----------------------------------------------"
  echo "Plak nu de ${label}."
  echo "Beëindig met een regel die alleen bevat: __END_KEY__"
  echo "----------------------------------------------"
  echo

  while IFS= read -r line; do
    if [[ "$line" == "__END_KEY__" ]]; then
      break
    fi
    data+="$line"$'\n'
  done

  data="${data%$'\n'}"
  printf -v "$varname" '%s' "$data"
}

# 2) GitHub via PAT / HTTPS URL of via SSH deploy key
echo
echo "Repository toegang via GitHub:"
echo
echo "  [1] GitHub PAT of HTTPS-URL (https://github.com/user/repo.git / https://PAT@github.com/user/repo.git)"
echo "  [2] Deploy key (SSH) + SSH clone-URL (git@github.com:user/repo.git)"
echo

GIT_AUTH_METHOD=""
GIT_REPO=""
DEPLOY_KEY=""
DEPLOY_KEY_B64=""

while [[ -z "$GIT_AUTH_METHOD" ]]; do
  read -rp "Kies authenticatiemethode [1/2]: " AUTH_CHOICE
  case "$AUTH_CHOICE" in
    1)
      GIT_AUTH_METHOD="https"
      echo
      echo "Je hebt gekozen voor: PAT / HTTPS-URL"
      echo
      while [[ -z "$GIT_REPO" ]]; do
        echo
        echo "Je kunt hier één van de twee opties gebruiken:"
        echo
        echo "  Voorbeeld 1 - ALLEEN PAT-string:"
        echo "    github_pat_..."
        echo
        echo "  Voorbeeld 2 - Volledige HTTPS-URL met PAT:"
        echo "    https://github_pat_...@github.com/user/repo.git"
        echo
        read -rp "Voer je GitHub PAT of volledige HTTPS-URL in: " GIT_INPUT

        if [[ "$GIT_INPUT" == github_pat_* ]]; then
          GITHUB_PAT="$GIT_INPUT"
          REPO_SLUG=""
          while [[ -z "$REPO_SLUG" ]]; do
            read -rp "Voer de repository-naam in als 'user/repo' (bijv. mijnuser/mijnrepo): " REPO_SLUG
            if [[ "$REPO_SLUG" != */* ]]; then
              echo "Formaat ongeldig. Gebruik 'user/repo'."
              REPO_SLUG=""
            fi
          done

          GIT_REPO="https://$GITHUB_PAT@github.com/$REPO_SLUG.git"
          echo
          echo "Gegenereerde HTTPS-URL op basis van PAT:"
          echo "  $GIT_REPO"
          echo
        else
          GIT_REPO="$GIT_INPUT"
          echo
          echo "Ingevoerde Git clone-URL:"
          echo "  $GIT_REPO"
          echo
        fi

        if command -v git >/dev/null 2>&1; then
          echo "Controleer toegang tot de repository met deze URL..."
          if git ls-remote --heads "$GIT_REPO" >/dev/null 2>&1; then
            echo "✅ URL en toegang lijken geldig."
          else
            echo "❌ FOUT: kan de repository niet benaderen met deze URL."
            echo "   - Controleer PAT, rechten en repositorynaam."
            GIT_REPO=""
          fi
        else
          echo "Let op: 'git' is niet beschikbaar op de host, URL kan niet vooraf online gevalideerd worden."
        fi
      done
      ;;
    2)
      GIT_AUTH_METHOD="ssh_deploy_key"
      echo
      echo "Je hebt gekozen voor: Deploy key (SSH)."
      echo "Zorg dat de *publieke* key als deploy key op GitHub in de repo staat."
      echo

      while [[ -z "$GIT_REPO" ]]; do
        read -rp "Voer de SSH clone-URL in (bijv. git@github.com:user/repo.git): " GIT_REPO
        if [[ -z "$GIT_REPO" ]]; then
          echo "SSH clone-URL mag niet leeg zijn."
        fi
      done

      prompt_multiline_secret "PRIVATE deploy key (begint met '-----BEGIN ... PRIVATE KEY-----')" DEPLOY_KEY

      if [[ -z "$DEPLOY_KEY" ]]; then
        echo "Deploy key is leeg; kan niet doorgaan met SSH deploy key."
        exit 1
      fi

      DEPLOY_KEY_B64="$(printf '%s' "$DEPLOY_KEY" | base64 -w0)"
      ;;
    *)
      echo "Ongeldige keuze, kies 1 of 2."
      ;;
  esac
done

# Repository-naam (user/repo) netjes afleiden voor weergave/description
REPO_NAME=""
if [[ "$GIT_REPO" =~ github.com[:/]+([^/]+/[^/.]+)(\.git)?$ ]]; then
  REPO_NAME="${BASH_REMATCH[1]}"
fi

if [[ -z "$REPO_NAME" ]]; then
  read -rp "Kon de repo-naam niet automatisch afleiden, voer in als 'user/repo': " REPO_NAME
fi

export GIT_AUTH_METHOD GIT_REPO DEPLOY_KEY_B64 REPO_NAME

# Voor weergave in description (geen secrets)
if [[ "$GIT_AUTH_METHOD" == "https" ]]; then
  REPO_DISPLAY="https://github.com/$REPO_NAME"
else
  REPO_DISPLAY="git@github.com:$REPO_NAME.git"
fi

# App specifieke defaults
APP_DIR="${APP_DIR:-/opt/app}"
PYTHON_SCRIPT="${PYTHON_SCRIPT:-main.py}"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 */6 * * *}"
UV_BIN="${UV_BIN:-/root/.local/bin/uv}"

echo
echo "Samenvatting invoer:"
echo "  - Containernaam   : $HN"
echo "  - Root wachtwoord : $ROOT_PW"
echo "  - Git methode     : $GIT_AUTH_METHOD"
echo "  - Git repo        : $REPO_DISPLAY"
echo "  - App directory   : $APP_DIR"
echo "  - Script          : $PYTHON_SCRIPT"
echo "  - Cron schedule   : $CRON_SCHEDULE"
echo

# ================== STANDAARD COMMUNITY-SCRIPTS FLOW ==================
header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info "$APP"
  if [[ ! -d /var ]]; then
    msg_error "No ${APP} Installation Found!"
    exit 1
  fi
  msg_info "Updating $APP LXC"
  $STD apt update
  $STD apt -y upgrade
  msg_ok "Updated $APP LXC"
  msg_ok "Updated successfully!"
  exit 0
}

# ================== POST-INSTALL: UV + GIT + CRON ==================
post_install_python_uv() {
  msg_info "Configureer uv, GitHub repo en cron in CT ${CTID}"

  pct exec "$CTID" -- bash -c "
    set -e

    # Basis packages
    apt-get update
    apt-get -y upgrade
    apt-get install -y git curl openssh-client python3 python3-venv cron

    # uv installeren (indien nog niet aanwezig)
    if [ ! -x '$UV_BIN' ]; then
      curl -LsSf https://astral.sh/uv/install.sh | sh
    fi

    # Git auth configureren
    GIT_AUTH_METHOD='$GIT_AUTH_METHOD'
    REPO_URL='$GIT_REPO'
    DEPLOY_KEY_B64='$DEPLOY_KEY_B64'

    if [ \"\$GIT_AUTH_METHOD\" = \"ssh_deploy_key\" ]; then
      echo \"[INFO] SSH deploy key configureren voor GitHub (poort 443 via ssh.github.com)...\"
      mkdir -p /root/.ssh
      chmod 700 /root/.ssh

      printf '%s' \"\$DEPLOY_KEY_B64\" | base64 -d > /root/.ssh/id_ed25519
      chmod 600 /root/.ssh/id_ed25519

      # SSH config: gebruik ssh.github.com:443 voor github.com
      cat >/root/.ssh/config <<'EOF'
Host github.com
  HostName ssh.github.com
  Port 443
  User git
  IdentityFile /root/.ssh/id_ed25519
  IdentitiesOnly yes
EOF
      chmod 600 /root/.ssh/config

      touch /root/.ssh/known_hosts
      if ! grep -q \"github.com\" /root/.ssh/known_hosts 2>/dev/null; then
        ssh-keyscan -H github.com >> /root/.ssh/known_hosts 2>/dev/null || true
      fi

      echo \"[INFO] SSH config voor github.com ingesteld (via ssh.github.com:443).\"
    fi

    # App directory + repo
    mkdir -p '$APP_DIR'
    if [ ! -d '$APP_DIR/.git' ]; then
      echo \"[INFO] Clone van repo: \$REPO_URL\"
      git clone \"\$REPO_URL\" '$APP_DIR'
    else
      echo \"[INFO] Bestaande repo gevonden, voer git pull uit...\"
      cd '$APP_DIR'
      git pull
    fi

    cd '$APP_DIR'

    # Dependencies controleren en evt. syncen via uv
    if [ -f \"pyproject.toml\" ] || [ -f \"requirements.txt\" ] || [ -f \"requirements.in\" ]; then
      echo \"[INFO] Dependency-bestanden gevonden in $APP_DIR:\"
      [ -f \"pyproject.toml\" ]   && echo \"  - pyproject.toml\"
      [ -f \"requirements.txt\" ] && echo \"  - requirements.txt\"
      [ -f \"requirements.in\" ]  && echo \"  - requirements.in\"

      echo \"[INFO] Voer 'uv sync' uit...\"
      '$UV_BIN' sync
    else
      echo \"[WARN] Geen pyproject.toml, requirements.txt of requirements.in gevonden in $APP_DIR\"
      echo \"[WARN] 'uv sync' wordt overgeslagen.\"
    fi

    # Log-directory
    mkdir -p /var/log/python-job

    # Cron job instellen (PATH uitbreiden voor uv)
    CRON_ENV='PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
    (
      crontab -l 2>/dev/null
      echo \"\${CRON_ENV}
$CRON_SCHEDULE cd $APP_DIR && $UV_BIN sync && $UV_BIN run $PYTHON_SCRIPT >> /var/log/python-job/job.log 2>&1\"
    ) | crontab -

    systemctl enable cron
    systemctl restart cron

    # IP ook in /etc/motd zetten (voor console)
    if command -v hostname >/dev/null 2>&1; then
      IP=\$(hostname -I | awk '{print \$1}')
      sed -i '/IP Address:/d' /etc/motd 2>/dev/null || true
      echo \"IP Address: \$IP\" >> /etc/motd
    fi
  "

  msg_ok "uv, repo en cron zijn in de container geconfigureerd"

  # IP-adres ophalen (met wat retries voor DHCP)
  IP=""
  for i in {1..10}; do
    IP=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -n "$IP" ]]; then
      break
    fi
    sleep 3
  done

  if [[ -n "$IP" ]]; then
    pct set "$CTID" -description "Python uv cron container

Hostname: $HN
IP address: $IP

Root password: $ROOT_PW

Repo: $REPO_DISPLAY
Script: $PYTHON_SCRIPT
Cron: $CRON_SCHEDULE"
    msg_ok "Container description bijgewerkt met hostname en IP: $IP"
  else
    msg_warn "Kon IP niet ophalen voor CT ${CTID} (mogelijk nog geen DHCP lease)."
  fi

  if [[ -n "$ROOT_PW" ]]; then
    echo "root:${ROOT_PW}" | pct exec "$CTID" -- chpasswd
    msg_ok "Root-wachtwoord ingesteld binnen de container."
  else
    msg_warn "ROOT_PW is leeg; root-wachtwoord niet ingesteld in de container."
  fi
}

# ================== CONTAINER MAKEN EN CONFIGUREREN ==================
start
build_container
description
post_install_python_uv

msg_ok "Completed Successfully!\n"
echo -e \"${CREATING}${GN}${APP} setup has been successfully initialized!${CL}\"
echo -e \"${INFO}${YW} Containernaam/hostname:${CL} ${GN}$HN${CL}\"
echo -e \"${INFO}${YW} De container gebruikt DHCP voor zijn IP-adres.${CL}\"
echo -e \"${INFO}${YW} Het IP-adres wordt getoond in:${CL}\"
echo -e \"${TAB}${NETWORK}${GN}- Proxmox 'Summary / Algemene informatie' (Description)${CL}\"
echo -e \"${TAB}${NETWORK}${GN}- /etc/motd binnen de container${CL}\"
echo
echo -e \"${INFO}${YW} Root-wachtwoord van de container:${CL} ${GN}$ROOT_PW${CL}\"
