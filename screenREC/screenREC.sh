#!/bin/bash
set -uo pipefail

# ── utilidades visuais ────────────────────────────────────────────────────────
red()  { printf '\033[0;31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
info() { printf '\033[0;36m%s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m%s\033[0m\n' "$*"; }

# ── diretório do script ───────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ENV_FILE="${SCRIPT_DIR}/.env"

# ── leitura da senha sudo ─────────────────────────────────────────────────────
SUDO_PASS=""
if [[ -f "$_ENV_FILE" ]]; then
    SUDO_PASS=$(grep '^SUDO_PASS=' "$_ENV_FILE" 2>/dev/null \
        | cut -d= -f2- | tr -d '"'"'" | head -1)
fi

# ── localização do REC_SHARE (lê smb.conf se disponível; fallback ~/REC_SHARE) ─
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
    echo "$HOME/REC_SHARE"
}

# ── verificar e corrigir sessão gráfica ───────────────────────────────────────
#
# A gravação usa x11grab (ffmpeg), que requer uma sessão X11.
# Se a sessão for Wayland, o script tenta aplicar a correção automaticamente
# usando a senha sudo salva em .env (configurada pelo install.sh).
# Caso não consiga corrigir, exibe um alerta na área de trabalho e encerra.
#
check_session() {
    local session="${XDG_SESSION_TYPE:-}"

    # Sessão X11 com DISPLAY definido — tudo certo, continua normalmente
    [[ "$session" == "x11" && -n "${DISPLAY:-}" ]] && return 0

    # ── sem display (ambiente headless / serviço sem sessão gráfica) ──────────
    if [[ -z "${DISPLAY:-}" && "$session" != "wayland" ]]; then
        red "screenREC: \$DISPLAY não definido. Aguardando sessão gráfica ativa."
        exit 1
    fi

    # ── sessão Wayland ou DISPLAY ausente em Wayland ─────────────────────────
    # Tenta aplicar configuração X11 automaticamente via sudo + SUDO_PASS do .env
    local _fixed=false

    if [[ -n "$SUDO_PASS" ]]; then
        if echo "$SUDO_PASS" | sudo -S bash -s 2>/dev/null << 'SUDOFIX'
set -e
conf=/etc/gdm3/custom.conf
mkdir -p "$(dirname "$conf")"
if [[ -f "$conf" ]] && grep -q 'WaylandEnable' "$conf"; then
    sed -i 's/#\?WaylandEnable=.*/WaylandEnable=false/' "$conf"
elif [[ -f "$conf" ]] && grep -q '^\[daemon\]' "$conf"; then
    sed -i '/^\[daemon\]/a WaylandEnable=false' "$conf"
else
    printf '[daemon]\nWaylandEnable=false\n' >> "$conf"
fi
ln -sf /dev/null /etc/udev/rules.d/61-gdm.rules 2>/dev/null || true
udevadm control --reload-rules 2>/dev/null || true
SUDOFIX
        then
            _fixed=true
        fi
    fi

    # ── alerta na área de trabalho ────────────────────────────────────────────
    local _title="screenREC — Sessão gráfica incompatível"
    local _body
    if [[ "$_fixed" == true ]]; then
        _body="Sessão Wayland detectada.\n\nA configuração foi corrigida automaticamente para X11.\nFaça logout e login novamente para iniciar a gravação."
    else
        _body="Sessão Wayland detectada. A gravação de tela requer X11.\n\nAo fazer login, clique na engrenagem e selecione 'Ubuntu on Xorg'."
    fi

    # notify-send funciona em Wayland
    if command -v notify-send &>/dev/null; then
        notify-send --urgency=critical --icon=display \
            "$_title" "$_body" 2>/dev/null || true
    fi

    # zenity como fallback visual (também funciona em Wayland)
    if command -v zenity &>/dev/null; then
        zenity --warning \
            --title="$_title" \
            --text="$_body" \
            --width=480 2>/dev/null || true
    fi

    red "$_title"
    warn "$_body"
    exit 1
}

check_session

# ── garantir entrada de autostart (recria se ausente) ────────────────────────
_autostart_dir="$HOME/.config/autostart"
_autostart_file="$_autostart_dir/screenREC.desktop"
if [[ ! -f "$_autostart_file" ]]; then
    mkdir -p "$_autostart_dir"
    cat > "$_autostart_file" << DESKTOP
[Desktop Entry]
Type=Application
Name=screenREC — Axxon Gravação de Tela
Exec=bash -c 'nohup bash ${SCRIPT_DIR}/screenREC.sh >> /tmp/screenrec.log 2>&1 &'
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Terminal=false
DESKTOP
    info "Autostart recriado: $_autostart_file"
fi

# ── garantir serviço cron ativo ───────────────────────────────────────────────
if ! systemctl is-active --quiet cron 2>/dev/null; then
    if [[ -n "$SUDO_PASS" ]]; then
        echo "$SUDO_PASS" | sudo -S systemctl enable --now cron 2>/dev/null \
            && info "Serviço cron habilitado automaticamente." || true
    else
        warn "Serviço cron inativo. Reinicie o sistema ou contate o suporte."
    fi
fi

# ── serial number do SO ───────────────────────────────────────────────────────
# Tenta DMI; fallback para machine-id se indisponível ou genérico
SERIAL=$(cat /sys/class/dmi/id/product_serial 2>/dev/null | tr -d ' \n')
if [[ -z "$SERIAL" || "$SERIAL" == "None" || "$SERIAL" == "ToBeFilledByO.E.M." ]]; then
    SERIAL=$(head -c 12 /etc/machine-id)
fi

# ── tag de identificação (do .env; fallback para serial number) ───────────────
TAG=""
if [[ -f "$_ENV_FILE" ]]; then
    TAG=$(grep '^TAG=' "$_ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"'"'")
fi
PREFIX="${TAG:-$SERIAL}"

# ── diretório de gravação ─────────────────────────────────────────────────────
REC_BASE=$(_resolve_rec_base)

if ! mkdir -p "$REC_BASE" 2>/dev/null || ! [[ -w "$REC_BASE" ]]; then
    _msg="Diretório de gravação inacessível: $REC_BASE\nVerifique se o disco está montado e o Samba está configurado."
    red "ERRO: $_msg"
    command -v notify-send &>/dev/null && \
        notify-send --urgency=critical "screenREC — Erro de gravação" "$_msg" 2>/dev/null || true
    command -v zenity &>/dev/null && \
        zenity --error --title="screenREC — Erro de gravação" --text="$_msg" --width=480 2>/dev/null || true
    exit 1
fi

# Reutiliza pasta do dia se já existir; senão cria com timestamp de início
REC_DIR=$(find "$REC_BASE" -maxdepth 1 -name "${PREFIX}_$(date '+%Y-%m-%d')*" -type d 2>/dev/null \
    | sort | head -1)
if [[ -z "$REC_DIR" ]]; then
    REC_DIR="${REC_BASE}/${PREFIX}_$(date '+%Y-%m-%d_%H-%M-%S')"
    mkdir -p "$REC_DIR"
fi
info "Pasta de gravação : $REC_DIR"

# ── cron de zip diário às 6h (idempotente) ────────────────────────────────────
ZIP_SCRIPT="${SCRIPT_DIR}/zip_daily.sh"
if [[ -f "$ZIP_SCRIPT" ]] && ! crontab -l 2>/dev/null | grep -qF "$ZIP_SCRIPT"; then
    chmod +x "$ZIP_SCRIPT"
    (crontab -l 2>/dev/null; echo "0 6 * * * $ZIP_SCRIPT >> /tmp/screenrec_zip.log 2>&1") | crontab -
    info "Cron de zip diário registrado (06:00)."
fi

# ── cron de limpeza de zips antigos às 5h (idempotente) ──────────────────────
CLEANUP_SCRIPT="${SCRIPT_DIR}/cleanup_old.sh"
if [[ -f "$CLEANUP_SCRIPT" ]] && ! crontab -l 2>/dev/null | grep -qF "$CLEANUP_SCRIPT"; then
    chmod +x "$CLEANUP_SCRIPT"
    (crontab -l 2>/dev/null; echo "0 5 * * * $CLEANUP_SCRIPT >> /tmp/screenrec_cleanup.log 2>&1") | crontab -
    info "Cron de limpeza de ZIPs antigos registrado (05:00)."
fi

# ── dependências ──────────────────────────────────────────────────────────────
missing=()
command -v ffmpeg       > /dev/null 2>&1 || missing+=(ffmpeg)
command -v xrandr       > /dev/null 2>&1 || missing+=(x11-xserver-utils)
command -v pactl        > /dev/null 2>&1 || missing+=(pipewire-pulse)
command -v zip          > /dev/null 2>&1 || missing+=(zip)
command -v notify-send  > /dev/null 2>&1 || missing+=(libnotify-bin)

if [[ ${#missing[@]} -gt 0 ]]; then
    info "Instalando dependências: ${missing[*]}"
    if [[ -n "$SUDO_PASS" ]]; then
        echo "$SUDO_PASS" | sudo -S apt-get install -y "${missing[@]}"
    else
        sudo apt-get install -y "${missing[@]}"
    fi
fi

# ── aguardar Axxon One iniciar ────────────────────────────────────────────────
wait_for_axxon() {
    warn "Aguardando Axxon One iniciar..."
    while ! pgrep -f "AxxonSoft" > /dev/null 2>&1; do
        sleep 2
    done
    grn "Axxon One detectado (PID: $(pgrep -f 'AxxonSoft' | head -1))"
}

# ── gravar uma tela individual (executado em subshell em background) ──────────
#
# Fluxo de sinal:
#   monitor_axxon → SIGTERM → subshell → trap → SIGINT p/ ffmpeg
#   SIGINT é o sinal correto para ffmpeg finalizar o container MP4 graciosamente
#
record_screen() {
    local monitor_num="$1"
    local resolution="$2"
    local offset_x="$3"
    local offset_y="$4"
    local audio_source="$5"
    local audio_monitor="$6"

    local start_time
    start_time=$(date '+%H-%M-%S')
    local tmp_file="${REC_DIR}/.rec_monitor${monitor_num}_${start_time}.mp4"

    ffmpeg -loglevel error \
        -video_size "$resolution" -framerate 30 -f x11grab -i ":0.0+${offset_x},${offset_y}" \
        -f pulse -i "$audio_source" \
        -f pulse -i "$audio_monitor" \
        -filter_complex "[1:a][2:a]amerge=inputs=2[a]" \
        -map 0:v -map "[a]" \
        -ac 2 -c:v libx264 -preset ultrafast -c:a aac \
        "$tmp_file" &
    local ffmpeg_pid=$!

    # Recebe SIGTERM do pai → manda SIGINT para ffmpeg (fecha o MP4 corretamente)
    trap "kill -INT $ffmpeg_pid 2>/dev/null; wait $ffmpeg_pid 2>/dev/null || true" TERM INT

    wait $ffmpeg_pid || true
    trap - TERM INT

    local end_time
    end_time=$(date '+%H-%M-%S')
    if [[ -f "$tmp_file" ]]; then
        mv "$tmp_file" "${REC_DIR}/monitor${monitor_num}_${start_time}-${end_time}.mp4"
        grn "Salvo: monitor${monitor_num}_${start_time}-${end_time}.mp4"
    fi
}

# ── monitorar Axxon e encerrar gravações ao fechar ────────────────────────────
monitor_axxon() {
    local -a pids=("$@")
    while pgrep -f "AxxonSoft" > /dev/null 2>&1; do
        sleep 5
    done
    red "Axxon One encerrado. Finalizando gravações..."
    if [[ ${#pids[@]} -gt 0 ]]; then
        kill -TERM "${pids[@]}" 2>/dev/null || true
        wait "${pids[@]}" 2>/dev/null || true
    fi
    grn "Gravações salvas em: $REC_DIR"
}

# ── main ──────────────────────────────────────────────────────────────────────
wait_for_axxon

# ── dialog de tag (abre cada vez que o Axxon inicia) ─────────────────────────
if [[ -f "${SCRIPT_DIR}/ask_tag.py" ]]; then
    python3 "${SCRIPT_DIR}/ask_tag.py" || true
    # Reler TAG após o dialog e atualizar pasta de gravação
    _new_tag=""
    if [[ -f "$_ENV_FILE" ]]; then
        _new_tag=$(grep '^TAG=' "$_ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"'"'")
    fi
    if [[ -n "$_new_tag" && "$_new_tag" != "$PREFIX" ]]; then
        PREFIX="$_new_tag"
        REC_DIR=$(find "$REC_BASE" -maxdepth 1 -name "${PREFIX}_$(date '+%Y-%m-%d')*" -type d 2>/dev/null \
            | sort | head -1)
        if [[ -z "$REC_DIR" ]]; then
            REC_DIR="${REC_BASE}/${PREFIX}_$(date '+%Y-%m-%d_%H-%M-%S')"
            mkdir -p "$REC_DIR"
        fi
        info "Pasta de gravação : $REC_DIR"
    fi
fi

# Detectar fontes de áudio via PipeWire/PulseAudio
AUDIO_SOURCE=$(pactl info 2>/dev/null | awk '/Default Source/{print $3}')
AUDIO_SINK=$(pactl info 2>/dev/null | awk '/Default Sink/{print $3}')
AUDIO_SOURCE=${AUDIO_SOURCE:-default}

if [[ -n "$AUDIO_SINK" ]]; then
    AUDIO_MONITOR="${AUDIO_SINK}.monitor"
else
    # Fallback: primeiro monitor source disponível
    AUDIO_MONITOR=$(pactl list short sources 2>/dev/null | awk '/\.monitor/{print $2; exit}')
    AUDIO_MONITOR=${AUDIO_MONITOR:-"@DEFAULT_MONITOR@"}
fi

info "Áudio source  : $AUDIO_SOURCE"
info "Áudio monitor : $AUDIO_MONITOR"

# Detectar monitores via xrandr
# Formato de saída: "1920/508x1080/285+0+0"  (pode conter frações /DPI)
mapfile -t monitor_list < <(xrandr --listmonitors | tail -n +2 | awk '{print $3}')

if [[ ${#monitor_list[@]} -eq 0 ]]; then
    red "Nenhum monitor detectado via xrandr. Abortando."
    exit 1
fi
info "Monitores detectados: ${#monitor_list[@]}"

RECORD_PIDS=()

for i in "${!monitor_list[@]}"; do
    monitor_info="${monitor_list[$i]}"
    monitor_num=$((i + 1))

    # Remove as frações "/DPI" antes de fazer o parse
    # "1920/508x1080/285+0+0" → "1920x1080+0+0"
    clean=$(echo "$monitor_info" | sed 's|/[0-9]*||g')
    resolution=$(echo "$clean" | grep -oE '[0-9]+x[0-9]+' | head -1)
    offset_x=$(echo "$clean" | grep -oP '\+\K[0-9]+' | sed -n '1p')
    offset_y=$(echo "$clean" | grep -oP '\+\K[0-9]+' | sed -n '2p')
    offset_x=${offset_x:-0}
    offset_y=${offset_y:-0}

    info "Gravando monitor${monitor_num}: ${resolution} +${offset_x}+${offset_y} (c/ áudio)"

    record_screen "$monitor_num" "$resolution" "$offset_x" "$offset_y" \
        "$AUDIO_SOURCE" "$AUDIO_MONITOR" &
    RECORD_PIDS+=($!)
done

# Encerramento manual via Ctrl+C ou SIGTERM externo
trap '
    red "Interrompido manualmente."
    if [[ ${#RECORD_PIDS[@]} -gt 0 ]]; then
        kill -TERM "${RECORD_PIDS[@]}" 2>/dev/null || true
        wait "${RECORD_PIDS[@]}" 2>/dev/null || true
    fi
    exit 0
' INT TERM

monitor_axxon "${RECORD_PIDS[@]}"
