#!/bin/bash
set -uo pipefail

# ── utilidades visuais ────────────────────────────────────────────────────────
red()  { printf '\033[0;31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
info() { printf '\033[0;36m%s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m%s\033[0m\n' "$*"; }

# ── verificar sessão gráfica (x11grab não funciona em Wayland) ───────────────
if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
    red "Sessão Wayland detectada. A captura de tela requer uma sessão X11."
    red "Ao fazer login, clique na engrenagem e selecione 'Ubuntu on Xorg'."
    exit 1
fi
if [[ -z "${DISPLAY:-}" ]]; then
    red "Variável \$DISPLAY não definida. Execute em uma sessão X11 ativa."
    exit 1
fi

# ── serial number do SO ───────────────────────────────────────────────────────
# Tenta DMI; fallback para machine-id se indisponível ou genérico
SERIAL=$(cat /sys/class/dmi/id/product_serial 2>/dev/null | tr -d ' \n')
if [[ -z "$SERIAL" || "$SERIAL" == "None" || "$SERIAL" == "ToBeFilledByO.E.M." ]]; then
    SERIAL=$(head -c 12 /etc/machine-id)
fi

# ── diretório de gravação ─────────────────────────────────────────────────────
REC_BASE="/home/$USER/REC_SHARE"
mkdir -p "$REC_BASE"

# Reutiliza pasta do dia se já existir; senão cria com timestamp de início
REC_DIR=$(find "$REC_BASE" -maxdepth 1 -name "${SERIAL}_$(date '+%Y-%m-%d')*" -type d 2>/dev/null \
    | sort | head -1)
if [[ -z "$REC_DIR" ]]; then
    REC_DIR="${REC_BASE}/${SERIAL}_$(date '+%Y-%m-%d_%H-%M-%S')"
    mkdir -p "$REC_DIR"
fi
info "Pasta de gravação : $REC_DIR"

# ── cron de zip diário às 6h (idempotente) ────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZIP_SCRIPT="${SCRIPT_DIR}/zip_daily.sh"
if [[ -f "$ZIP_SCRIPT" ]] && ! crontab -l 2>/dev/null | grep -qF "$ZIP_SCRIPT"; then
    chmod +x "$ZIP_SCRIPT"
    (crontab -l 2>/dev/null; echo "0 6 * * * $ZIP_SCRIPT >> /tmp/screenrec_zip.log 2>&1") | crontab -
    info "Cron de zip diário registrado (06:00)."
fi

# ── dependências ──────────────────────────────────────────────────────────────
missing=()
command -v ffmpeg  > /dev/null 2>&1 || missing+=(ffmpeg)
command -v xrandr  > /dev/null 2>&1 || missing+=(x11-xserver-utils)
command -v pactl   > /dev/null 2>&1 || missing+=(pipewire-pulse)
command -v zip     > /dev/null 2>&1 || missing+=(zip)

if [[ ${#missing[@]} -gt 0 ]]; then
    info "Instalando dependências: ${missing[*]}"
    sudo apt-get install -y "${missing[@]}"
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
