#!/bin/bash
set -uo pipefail

# Executado pelo cron às 06:00 — zipa a pasta de gravações do dia anterior
# e a remove, deixando apenas o .zip em REC_SHARE

# ── diretório do script ───────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# ── leitura da senha sudo (para instalação de dependências sem prompt) ────────
SUDO_PASS=""
if [[ -f "$ENV_FILE" ]]; then
    SUDO_PASS=$(grep '^SUDO_PASS=' "$ENV_FILE" 2>/dev/null \
        | cut -d= -f2- | tr -d '"'"'" | head -1)
fi

_sudo_install() {
    if [[ -n "$SUDO_PASS" ]]; then
        echo "$SUDO_PASS" | sudo -S apt-get install -y "$1" >/dev/null 2>&1
    else
        sudo apt-get install -y "$1" >/dev/null 2>&1
    fi
}

# ── serial number (mesma lógica do screenREC.sh) ──────────────────────────────
SERIAL=$(cat /sys/class/dmi/id/product_serial 2>/dev/null | tr -d ' \n')
if [[ -z "$SERIAL" || "$SERIAL" == "None" || "$SERIAL" == "ToBeFilledByO.E.M." ]]; then
    SERIAL=$(head -c 12 /etc/machine-id)
fi

# ── tag de identificação (do .env; fallback para serial number) ───────────────
TAG=""
if [[ -f "$ENV_FILE" ]]; then
    TAG=$(grep '^TAG=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"'"'")
fi
PREFIX="${TAG:-$SERIAL}"

# Resolve o home via UID — $HOME e $USER não são confiáveis no contexto do cron
HOME_DIR=$(getent passwd "$(id -u)" | cut -d: -f6)

# ── localização do REC_SHARE (lê smb.conf se disponível; fallback para ~/REC_SHARE) ─
_resolve_rec_base() {
    if [[ -f /etc/samba/smb.conf ]]; then
        local path
        path=$(awk '
            /^\[REC_SHARE\]/             { in_s=1; next }
            /^\[/ && !/^\[REC_SHARE\]/  { in_s=0 }
            in_s && /path[[:space:]]*=/ {
                gsub(/.*=[[:space:]]*/,""); gsub(/[[:space:]]*$/,""); print; exit
            }
        ' /etc/samba/smb.conf 2>/dev/null)
        [[ -n "$path" ]] && { echo "$path"; return 0; }
    fi
    echo "${HOME_DIR}/REC_SHARE"
}

REC_BASE=$(_resolve_rec_base)
YESTERDAY=$(date -d yesterday '+%Y-%m-%d')

if ! command -v zip > /dev/null 2>&1; then
    _sudo_install zip
fi

found=0
while IFS= read -r folder; do
    [[ -d "$folder" ]] || continue
    found=1
    name=$(basename "$folder")
    zip_file="${REC_BASE}/${name}.zip"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Zipando: $name"
    cd "$REC_BASE"
    if zip -r "$zip_file" "$name/"; then
        rm -rf "$folder"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Concluído: ${name}.zip"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERRO ao zipar $name — pasta mantida."
    fi
done < <(find "$REC_BASE" -maxdepth 1 -name "${PREFIX}_${YESTERDAY}*" -type d 2>/dev/null | sort)

if [[ $found -eq 0 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Nenhuma pasta de ${YESTERDAY} encontrada em $REC_BASE"
fi
