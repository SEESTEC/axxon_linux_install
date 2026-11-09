#!/usr/bin/env bash
#
# Axxon One — Painel web (página web exibida como câmera)
# SEESTEC — Engenharia e Tecnologia
#
# O Client Linux do Axxon One não tem o "Web Board". Este script contorna isso:
# um Google Chrome sem tela (Xvfb) abre a página, o ffmpeg transforma a tela em
# vídeo H.264 e o MediaMTX publica em RTSP (só em localhost). A página é então
# cadastrada no Axxon One Server como uma câmera (driver FFMPEG).
#
# Uso:
#   sudo bash webpanel.sh                      # instala (pergunta a URL)
#   sudo bash webpanel.sh install --url URL    # instala com a URL informada
#   axxon-webpanel url [URL]                   # troca a URL (aliases: axxon-web, axxon-dashboard)
#   axxon-webpanel status | restart | logs | remove
#   axxon-webpanel --help
#   axxon --help                               # todos os comandos de terminal do Axxon One
#
# A troca de página não pede senha para o grupo axxonweb (quem rodou o sudo na
# instalação; outros: --allow-user USUARIO). O painel roda como o usuário de
# sistema axxon_web.
#
# Requisitos: Ubuntu 24.04+ (amd64), Axxon One Server instalado nesta máquina.

if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
set -uo pipefail

# ── constantes ────────────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="1.0.0"
readonly MIN_UBUNTU="24.04"

readonly CMD_PATH="/usr/local/bin/axxon-webpanel"
readonly RUNNER="/usr/local/libexec/axxon-webpanel/run"
readonly CONF_DIR="/etc/axxon-webpanel"
readonly CONF="$CONF_DIR/webpanel.conf"
readonly MTX_CONF="$CONF_DIR/mediamtx.yml"
readonly MTX_DIR="/opt/mediamtx"
readonly MTX_BIN="$MTX_DIR/mediamtx"
readonly MTX_VERSION="v1.21.3"
readonly MTX_SHA256="0a2ea7eba96023631efa1bea7804823a9145b043b6646a8a05798d4ac24ed635"
readonly MTX_URL="https://github.com/bluenviron/mediamtx/releases/download/$MTX_VERSION/mediamtx_${MTX_VERSION}_linux_amd64.tar.gz"
readonly CHROME_DEB_URL="https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
readonly CHROME_POLICY="/etc/opt/chrome/policies/managed/axxon-webpanel.json"
readonly SVC_PANEL="axxon-webpanel.service"
readonly SVC_RTSP="axxon-webpanel-rtsp.service"
readonly UNIT_DIR="/etc/systemd/system"
readonly SVC_USER="axxon_web"
readonly SVC_HOME="/var/lib/axxon-webpanel"
readonly BASHRC="/etc/bash.bashrc"
readonly ALIAS_BEGIN="# >>> axxon-webpanel (gerenciado pelo instalador SEESTEC) >>>"
readonly ALIAS_END="# <<< axxon-webpanel <<<"
# Membros deste grupo trocam a página sem senha (só url/status/restart via sudoers)
readonly WEB_GROUP="axxonweb"
readonly SUDOERS_FILE="/etc/sudoers.d/axxon-webpanel"
readonly BACKUP_DIR="/var/lib/axxon-webpanel-backup"
readonly LOG_FILE="/var/log/axxon-webpanel.log"
readonly LOCK_FILE="/run/lock/axxon-webpanel.lock"
readonly AXXON_CMD="/usr/local/bin/axxon"
readonly AXXON_HELP_MARKER="Axxon One — comandos de terminal"
readonly AXXON_HELP_RAW_URL="https://raw.githubusercontent.com/SEESTEC/axxon_linux_install/main/axxon.sh"
readonly MARKER="Painel web do Axxon One"

readonly AXXON_HOME="/opt/AxxonSoft/AxxonOne"
readonly DRIVERPACK_ROOT="/opt/AxxonSoft/Ipint.DriverPack"
readonly CAM_VENDOR="FFMPEG"
readonly CAM_MODEL="1 channel device"

# Portas evitadas: 8554 (RTSP do Axxon One) e 8000/8001 (Web do Axxon One)
DEFAULT_RTSP_PORT=8654
DEFAULT_NAME="Painel Web"

# ── opções ────────────────────────────────────────────────────────────────────
ACTION=""
OPT_URL=""
OPT_NAME=""
OPT_RTSP_PORT=""
OPT_WEB_PORT=""
ASSUME_YES=false
QUIET=false
KEEP_CAMERA=false
ALLOW_USERS=()

# ── saída ─────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m' C_GRN=$'\033[0;32m' C_YLW=$'\033[0;33m'
    C_CYN=$'\033[0;36m' C_BLD=$'\033[1m'    C_RST=$'\033[0m'
else
    C_RED="" C_GRN="" C_YLW="" C_CYN="" C_BLD="" C_RST=""
fi
_log() {
    [[ -w "$LOG_FILE" ]] || return 0
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"
}
info() { $QUIET || printf '%s%s%s\n' "$C_CYN" "$*" "$C_RST"; _log "INFO  $*"; }
ok()   { $QUIET || printf '%s  [✓] %s%s\n' "$C_GRN" "$*" "$C_RST"; _log "OK    $*"; }
warn() { printf '%s  [!] %s%s\n' "$C_YLW" "$*" "$C_RST" >&2; _log "WARN  $*"; }
err()  { printf '%s  [✗] %s%s\n' "$C_RED" "$*" "$C_RST" >&2; _log "ERROR $*"; }
die()  {
    err "$1"
    [[ -n "${2:-}" ]] && printf '      %s\n' "$2" >&2
    exit "${3:-1}"
}
run() {
    _log "\$ $*"
    "$@" >> "$LOG_FILE" 2>&1
}

usage() {
    cat <<EOF
Axxon One — Painel web v$SCRIPT_VERSION
Mostra uma página web no layout do Axxon One como se fosse uma câmera.

Uso: sudo bash webpanel.sh [comando] [opções]
     axxon-webpanel [comando] [opções]      (depois de instalado)

Comandos:
  install           Instala e configura o painel (padrão)
  url [URL]         Troca a página exibida (aliases: axxon-web, axxon-dashboard)
  status            Mostra o estado dos serviços, do vídeo e da câmera no Axxon
  restart           Reinicia o painel (recarrega a página)
  logs              Últimas linhas do log dos serviços
  remove            Remove o painel (e, se confirmado, a câmera do Axxon)

Uso interno (install.sh):
  ask-url           Pergunta a URL, testa e imprime a URL aceita (código 3: cancelado)
  check-url URL     Testa a URL e imprime a forma normalizada (0 ok, 2 ressalvas, 1 inválida)

Opções:
  --url URL         Página a exibir (http, https ou file://)
  --name NOME       Nome da câmera no Axxon (padrão: "$DEFAULT_NAME")
  --rtsp-port N     Porta RTSP local (padrão: $DEFAULT_RTSP_PORT)
  --web-port N      Porta Web/API do Axxon One Server (padrão: lida do servidor, 8000)
  --allow-user U    Permite ao usuário U trocar a página sem senha (grupo $WEB_GROUP);
                    pode repetir. Padrão: quem chamou o sudo (SUDO_USER)
  --keep-camera     Em "remove": mantém a câmera cadastrada no Axxon
  -y, --yes         Sem perguntas (exige --url na instalação)
  -q, --quiet       Menos mensagens
  -h, --help        Esta ajuda

Credenciais do Axxon One (para cadastrar a câmera): o script tenta root/root e,
se não funcionar, pergunta. Para automação: AXXON_USER e AXXON_PASSWORD.
Nada é gravado em disco.

"axxon --help" lista todos os comandos de terminal do Axxon One.
Log: $LOG_FILE
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
            install|url|status|restart|logs|remove|ask-url|check-url)
                        # um comando por chamada (a regra do sudoers depende disso)
                        [[ -z "$ACTION" ]] || die "Informe só um comando (recebido: $ACTION e $1)."
                        ACTION="$1"
                        if [[ "$1" == url || "$1" == check-url ]] && [[ $# -ge 2 && "$2" != -* ]]; then
                            OPT_URL="$2"; shift
                        fi ;;
            --url)      [[ $# -ge 2 ]] || die "--url exige um valor."; OPT_URL="$2"; shift ;;
            --url=*)    OPT_URL="${1#*=}" ;;
            --name)     [[ $# -ge 2 ]] || die "--name exige um valor."; OPT_NAME="$2"; shift ;;
            --name=*)   OPT_NAME="${1#*=}" ;;
            --rtsp-port) [[ $# -ge 2 ]] || die "--rtsp-port exige um valor."; OPT_RTSP_PORT="$2"; shift ;;
            --web-port) [[ $# -ge 2 ]] || die "--web-port exige um valor."; OPT_WEB_PORT="$2"; shift ;;
            --keep-camera) KEEP_CAMERA=true ;;
            --allow-user) [[ $# -ge 2 ]] || die "--allow-user exige um valor."; ALLOW_USERS+=("$2"); shift ;;
            -y|--yes)   ASSUME_YES=true ;;
            -q|--quiet) QUIET=true ;;
            -h|--help)  usage; exit 0 ;;
            *)          usage >&2; die "Opção desconhecida: $1" ;;
        esac
        shift
    done
    ACTION="${ACTION:-install}"
    local p
    for p in "$OPT_RTSP_PORT" "$OPT_WEB_PORT"; do
        [[ -z "$p" || ( "$p" =~ ^[0-9]+$ && "$p" -ge 1 && "$p" -le 65535 ) ]] ||
            die "Porta inválida: $p"
    done
}

# ── perguntas ─────────────────────────────────────────────────────────────────
has_tty() { [[ -t 0 ]]; }
confirm() {
    local question="$1" default="${2:-S}" ans hint
    $ASSUME_YES && { [[ "$default" == "S" ]]; return; }
    has_tty || die "Sem terminal interativo para confirmar: \"$question\"." "Use -y."
    [[ "$default" == "S" ]] && hint="[S/n]" || hint="[s/N]"
    while true; do
        read -rp "${C_BLD}${question}${C_RST} $hint: " ans || exit 1
        ans="${ans:-$default}"
        case "${ans,,}" in
            s|sim|y|yes) return 0 ;;
            n|nao|não|no) return 1 ;;
            *) warn "Responda S ou N." ;;
        esac
    done
}

# ── ambiente ──────────────────────────────────────────────────────────────────
check_os() {
    local id version
    id=$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")
    version=$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_ID:-}")
    if [[ "${id,,}" != ubuntu || -z "$version" ]] ||
       ! printf '%s\n%s\n' "$MIN_UBUNTU" "$version" | sort -V -C; then
        die "Sistema incompatível: requer Ubuntu $MIN_UBUNTU ou superior."
    fi
    [[ "$(dpkg --print-architecture)" == amd64 ]] ||
        die "Arquitetura não suportada: $(dpkg --print-architecture)." "O Google Chrome para Linux só existe para amd64."
}

ensure_root() {
    [[ $EUID -eq 0 ]] && return 0
    local self
    self=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)
    [[ -f "$self" ]] || die "Execute como root: sudo bash webpanel.sh"
    command -v sudo >/dev/null || die "sudo não encontrado. Execute como root."
    # O comando instalado é chamado direto: é o que a regra do sudoers libera sem senha
    [[ "$self" == "$CMD_PATH" ]] && exec sudo "$CMD_PATH" "$@"
    exec sudo bash "$self" "$@"
}

acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 8>"$LOCK_FILE"
    flock -n 8 || die "Outra execução do painel web já está em andamento."
}

init_log() {
    touch "$LOG_FILE" && chmod 640 "$LOG_FILE"
    printf '\n[%s] ===== Painel web v%s — %s =====\n' "$(date '+%F %T')" "$SCRIPT_VERSION" "$ACTION" >> "$LOG_FILE"
}

pkg_installed() {
    [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" == "installed" ]]
}
pkg_version() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null; }

backup_file() {
    [[ -e "$1" ]] || return 0
    mkdir -p "$BACKUP_DIR"
    cp -a "$1" "$BACKUP_DIR/$(basename "$1").$(date +%Y%m%d-%H%M%S)"
}

# ── configuração ──────────────────────────────────────────────────────────────
# Lê uma chave do arquivo de configuração (em subshell: o arquivo é shell)
conf_get() {
    [[ -r "$CONF" ]] || return 0
    # shellcheck source=/dev/null
    ( . "$CONF" 2>/dev/null; eval "printf '%s' \"\${$1:-}\"" )
}
# Grava/atualiza uma chave com quoting seguro (printf %q)
conf_set() {
    local key="$1" val="$2" tmp
    mkdir -p "$CONF_DIR"
    tmp=$(mktemp "$CONF_DIR/.webpanel.conf.XXXXXX")
    if [[ -f "$CONF" ]]; then
        grep -v "^$key=" "$CONF" > "$tmp" || true
    fi
    printf '%s=%q\n' "$key" "$val" >> "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$CONF"
}
write_default_conf() {
    [[ -f "$CONF" ]] && return 0
    mkdir -p "$CONF_DIR"
    cat > "$CONF" <<EOF
# $MARKER — configuração
# Para trocar a página use: axxon-web (ou axxon-dashboard, ou axxon-webpanel url)
# Depois de editar à mão: sudo axxon-webpanel restart
WIDTH=1280
HEIGHT=720
FPS=10
BITRATE=1500k
# Recarrega a página (reinicia o painel) a cada N horas; 0 desativa
RELOAD_HOURS=6
DISPLAY_NUM=99
EOF
    chmod 0644 "$CONF"
}

rtsp_port() { local p; p=$(conf_get RTSP_PORT); printf '%s' "${p:-$DEFAULT_RTSP_PORT}"; }
rtsp_url()  { printf 'rtsp://127.0.0.1:%s/painel' "$(rtsp_port)"; }

# ── URL: normalização e teste ─────────────────────────────────────────────────
normalize_url() {
    local u="$1"
    u="${u#"${u%%[![:space:]]*}"}"; u="${u%"${u##*[![:space:]]}"}"
    if [[ "$u" == /* ]]; then
        u="file://$u"
    elif [[ "$u" != *://* && -n "$u" ]]; then
        u="https://$u"
    fi
    printf '%s' "$u"
}

# Testa se a página abre. Retorna 0 (ok), 1 (inválida), 2 (abre com ressalvas)
check_url() {
    local url="$1" scheme path out code eff
    [[ "$url" =~ [[:space:]] ]] && { err "A URL não pode ter espaços."; return 1; }
    scheme="${url%%://*}"
    case "${scheme,,}" in
        http|https)
            out=$(curl -sS -L --max-redirs 5 --connect-timeout 8 --max-time 20 -o /dev/null \
                -A "Mozilla/5.0 (X11; Linux x86_64) AxxonWebPanel/$SCRIPT_VERSION" \
                -w '%{http_code} %{url_effective}' "$url" 2>&1)
            code=$(printf '%s\n' "$out" | tail -n1); code="${code%% *}"
            if [[ ! "$code" =~ ^[0-9]{3}$ || "$code" == 000 ]]; then
                err "Não foi possível abrir $url"
                printf '      %s\n' "$(printf '%s\n' "$out" | grep -m1 '^curl:' || printf 'sem resposta')" >&2
                [[ "$url" == *localhost* || "$url" == *127.0.0.1* ]] &&
                    printf '      Lembrete: "localhost" aqui é esta máquina Linux/WSL, não o Windows.\n' >&2
                return 1
            fi
            out=$(printf '%s\n' "$out" | tail -n1)
            eff="${out#* }"
            case "$code" in
                2??|3??) ok "Página respondeu (HTTP $code)${eff:+ — $eff}" >&2; return 0 ;;
                401|403) warn "A página exige autenticação (HTTP $code): o painel mostrará a tela de login."; return 2 ;;
                000)     err "Sem resposta de $url"; return 1 ;;
                *)       warn "A página respondeu HTTP $code."; return 2 ;;
            esac
            ;;
        file)
            path="${url#file://}"
            [[ -f "$path" ]] || { err "Arquivo não encontrado: $path"; return 1; }
            if id "$SVC_USER" >/dev/null 2>&1 && ! runuser -u "$SVC_USER" -- test -r "$path"; then
                err "O usuário $SVC_USER não consegue ler $path (permissões)."; return 1
            fi
            ok "Arquivo encontrado: $path" >&2; return 0
            ;;
        *)
            err "Esquema não suportado: $scheme (use http, https ou file://)"; return 1 ;;
    esac
}

# Pede a URL até ser válida. $1 = valor atual (Enter mantém). Retorna 3 se cancelado
ask_url() {
    local current="${1:-}" ans url rc
    while true; do
        if [[ -n "$current" ]]; then
            printf '  URL atual: %s\n' "$current" >&2
            read -rp "${C_BLD}Nova URL (Enter mantém a atual, \"q\" cancela):${C_RST} " ans || exit 1
            [[ -z "$ans" ]] && { printf '%s' "$current"; return 0; }
        else
            read -rp "${C_BLD}URL da página a exibir (ex.: https://painel.empresa.com, \"q\" cancela):${C_RST} " ans || exit 1
            [[ -z "$ans" ]] && { warn "Informe uma URL."; continue; }
        fi
        [[ "${ans,,}" == q ]] && return 3
        url=$(normalize_url "$ans")
        [[ "$url" != "$ans" ]] && printf '  Usando: %s\n' "$url" >&2
        check_url "$url"; rc=$?
        if ((rc == 0)); then
            printf '%s' "$url"; return 0
        elif ((rc == 2)) && confirm "Usar esta URL mesmo assim?" N; then
            printf '%s' "$url"; return 0
        fi
        warn "Informe outra URL."
    done
}

# URL final: --url (testada) ou pergunta interativa
resolve_url() {
    local current="${1:-}" url rc
    if [[ -n "$OPT_URL" ]]; then
        url=$(normalize_url "$OPT_URL")
        check_url "$url"; rc=$?
        if ((rc == 1)); then
            die "URL inválida: $url"
        elif ((rc == 2)) && ! $ASSUME_YES && ! confirm "Usar esta URL mesmo assim?" N; then
            die "Cancelado."
        fi
        printf '%s' "$url"; return 0
    fi
    $ASSUME_YES && [[ -n "$current" ]] && { printf '%s' "$current"; return 0; }
    $ASSUME_YES && die "Informe a página com --url (modo -y)."
    has_tty || die "Sem terminal para perguntar a URL." "Use --url URL."
    ask_url "$current"
}

# ── Axxon One: versão, driver pack e API ──────────────────────────────────────
NODE=""
WEB_PORT=""
AX_USER=""
AX_PASS=""

check_axxon() {
    pkg_installed axxon-one ||
        die "O Axxon One Server não está instalado nesta máquina." \
            "Instale-o antes (sudo bash install.sh --server): a câmera é cadastrada no Server local."
    local core dp dp_cand rep
    core=$(pkg_version axxon-one-core)
    info "  Axxon One Server: $(pkg_version axxon-one) (core $core)"
    systemctl is-active --quiet axxon-one.service ||
        die "O serviço axxon-one não está ativo." "sudo systemctl start axxon-one"

    # Driver pack: o core só exige "axxon-drivers-pack" (sem versão), então a
    # compatibilidade é conferida pelo conteúdo: driver FFMPEG com o modelo usado.
    pkg_installed axxon-drivers-pack ||
        die "O pacote axxon-drivers-pack não está instalado." "sudo apt-get install axxon-drivers-pack"
    dp=$(pkg_version axxon-drivers-pack)
    rep=$(find "$DRIVERPACK_ROOT" -maxdepth 2 -name 'Ipint.FFMPEG.rep' 2>/dev/null | sort -V | tail -n1)
    [[ -n "$rep" ]] ||
        die "Driver FFMPEG não encontrado no driver pack $dp ($DRIVERPACK_ROOT)." \
            "Atualize: sudo apt-get install --only-upgrade axxon-drivers-pack"
    if ! grep -q "<brand>$CAM_VENDOR</brand>" "$rep" || ! grep -q "<name>$CAM_MODEL</name>" "$rep"; then
        die "O driver pack $dp não tem o modelo \"$CAM_VENDOR / $CAM_MODEL\"." \
            "Atualize: sudo apt-get install --only-upgrade axxon-drivers-pack"
    fi
    info "  Driver pack: $dp ($(basename "$(dirname "$rep")")) — driver $CAM_VENDOR / \"$CAM_MODEL\" disponível"
    dp_cand=$(apt-cache policy axxon-drivers-pack 2>/dev/null | awk '/Candidate:/ {print $2}')
    if [[ -n "$dp_cand" && "$dp_cand" != "(none)" && "$dp_cand" != "$dp" ]] &&
       dpkg --compare-versions "$dp_cand" gt "$dp"; then
        warn "Há um driver pack mais novo ($dp_cand). Opcional: sudo apt-get install --only-upgrade axxon-drivers-pack"
    fi

    NODE=$( (. "$AXXON_HOME/instance.conf" 2>/dev/null; printf '%s' "${NGP_NODE_NAME:-}") )
    [[ -n "$NODE" ]] || NODE=$(hostname)
    WEB_PORT="${OPT_WEB_PORT:-$(conf_get AXXON_WEB_PORT)}"
    WEB_PORT="${WEB_PORT:-8000}"
}

# Configuração do curl com a senha (não aparece na linha de comando)
_curl_auth() {
    local u="${AX_USER//\\/\\\\}" p="${AX_PASS//\\/\\\\}"
    u="${u//\"/\\\"}"; p="${p//\"/\\\"}"
    printf 'user = "%s:%s"\n' "$u" "$p"
}

# api METHOD JSON_DATA → corpo da resposta em stdout; código HTTP em API_CODE
API_CODE=""
api() {
    local method="$1" data="$2" body tmp
    tmp=$(mktemp)
    API_CODE=$(printf '{"method":"%s","data":%s}' "$method" "$data" |
        curl -s -m 60 -K <(_curl_auth) -X POST "http://127.0.0.1:$WEB_PORT/grpc" \
            -H 'Content-Type: application/json' --data-binary @- -o "$tmp" -w '%{http_code}') || API_CODE="000"
    body=$(cat "$tmp"); rm -f "$tmp"
    printf '%s' "$body"
}

api_login() {
    local i
    AX_USER="${AXXON_USER:-root}"
    AX_PASS="${AXXON_PASSWORD:-root}"
    for ((i = 0; i <= 3; i++)); do
        api axxonsoft.bl.config.ConfigurationService.ListUnits "{\"unit_uids\":[\"hosts/$NODE\"]}" >/dev/null
        case "$API_CODE" in
            200) ok "API do Axxon One: autenticado como $AX_USER"; return 0 ;;
            401|403) ;;
            000) die "A API do Axxon One não responde em http://127.0.0.1:$WEB_PORT." \
                     "Confira o serviço axxon-one ou informe --web-port." ;;
            *) die "Resposta inesperada da API do Axxon One (HTTP $API_CODE)." ;;
        esac
        ((i == 0)) && [[ -z "${AXXON_PASSWORD:-}" ]] &&
            info "  A senha padrão do usuário root não foi aceita."
        ((i == 0)) && [[ -n "${AXXON_PASSWORD:-}" ]] && warn "AXXON_USER/AXXON_PASSWORD não foram aceitos."
        ((i == 3)) && break
        if ! has_tty || $ASSUME_YES; then
            die "Credenciais do Axxon One recusadas." "Defina AXXON_USER e AXXON_PASSWORD."
        fi
        read -rp "  Usuário administrador do Axxon One [root]: " AX_USER || exit 1
        AX_USER="${AX_USER:-root}"
        read -rsp "  Senha: " AX_PASS || exit 1
        echo
    done
    die "Credenciais do Axxon One recusadas."
}

# Procura a câmera do painel (pelo endereço RTSP). Imprime o uid, se existir.
find_camera() {
    local want uid addr
    want=$(rtsp_url)
    while read -r uid; do
        [[ -n "$uid" ]] || continue
        addr=$(api axxonsoft.bl.config.ConfigurationService.ListUnits "{\"unit_uids\":[\"$uid\"]}" |
            python3 -I -c 'import json,sys
d=json.load(sys.stdin)
for p in d["units"][0].get("properties",[]):
    if p.get("id")=="address": print(p.get("value_string",""))' 2>/dev/null)
        [[ "$addr" == "$want" ]] && { printf '%s' "$uid"; return 0; }
    done < <(api axxonsoft.bl.config.ConfigurationService.ListUnits "{\"unit_uids\":[\"hosts/$NODE\"]}" |
        python3 -I -c 'import json,sys
d=json.load(sys.stdin)
for c in d["units"][0].get("units",[]):
    if c.get("type")=="DeviceIpint": print(c["uid"])' 2>/dev/null)
    return 1
}

add_camera() {
    local name="$1" data out
    data=$(NAME="$name" NODE="$NODE" ADDR="$(rtsp_url)" VENDOR="$CAM_VENDOR" MODEL="$CAM_MODEL" python3 -I -c '
import json,os
props=[("vendor",os.environ["VENDOR"]),("model",os.environ["MODEL"]),("firmware","auto"),
       ("address",os.environ["ADDR"]),("display_name",os.environ["NAME"]),("user",""),
       ("password",""),("archiveBinding",""),("recordingMode","")]
p=[{"id":k,"value_string":v} for k,v in props]+[{"id":"port","value_int32":0}]
print(json.dumps({"added":[{"uid":"hosts/"+os.environ["NODE"],"units":[{"type":"DeviceIpint","properties":p}]}]}))')
    out=$(api axxonsoft.bl.config.ConfigurationService.ChangeConfig "$data")
    [[ "$API_CODE" == 200 ]] || { err "Falha ao cadastrar a câmera (HTTP $API_CODE): $out"; return 1; }
    printf '%s' "$out" | python3 -I -c 'import json,sys
d=json.load(sys.stdin)
if d.get("failed") or not d.get("added"): sys.exit(1)
print(d["added"][0])'
}

remove_camera() {
    local uid="$1" out
    out=$(api axxonsoft.bl.config.ConfigurationService.ChangeConfig "{\"removed\":[{\"uid\":\"$uid\"}]}")
    if [[ "$API_CODE" != 200 ]] || printf '%s' "$out" | grep -q '"failed":\["'; then
        err "Falha ao remover a câmera $uid: $out"; return 1
    fi
}

# Imagem da câmera pelo próprio Axxon (prova de que o Server recebe o vídeo)
check_snapshot() {
    local uid="$1" i code tmp
    tmp=$(mktemp)
    for ((i = 0; i < 12; i++)); do
        code=$(curl -s -m 15 -K <(_curl_auth) -o "$tmp" -w '%{http_code}' \
            "http://127.0.0.1:$WEB_PORT/live/media/snapshot/${uid#hosts/}/SourceEndpoint.video:0:0") || code=000
        if [[ "$code" == 200 ]] && [[ "$(head -c 2 "$tmp" | od -An -tx1 | tr -d ' ')" == ffd8 ]]; then
            rm -f "$tmp"; return 0
        fi
        sleep 5
    done
    rm -f "$tmp"; return 1
}

# ── vídeo ─────────────────────────────────────────────────────────────────────
check_stream() {
    local i
    for ((i = 0; i < "${1:-12}"; i++)); do
        ffprobe -v error -rtsp_transport tcp -timeout 5000000 -select_streams v:0 \
            -show_entries stream=codec_name -of csv=p=0 "$(rtsp_url)" 2>/dev/null | grep -q h264 && return 0
        sleep 5
    done
    return 1
}

port_owner() { ss -ltnpH "( sport = :$1 )" 2>/dev/null | grep -oP 'users:\(\("\K[^"]+' | head -n1; }

# ── instalação: componentes ───────────────────────────────────────────────────
install_packages() {
    local -a pkgs=(ca-certificates curl ffmpeg python3 xvfb fonts-liberation fonts-dejavu-core fonts-noto-color-emoji)
    local -a missing=() p
    for p in "${pkgs[@]}"; do pkg_installed "$p" || missing+=("$p"); done
    export DEBIAN_FRONTEND=noninteractive
    if ((${#missing[@]})); then
        info "  Instalando: ${missing[*]}"
        run apt-get -y -o DPkg::Lock::Timeout=600 update || return 1
        run apt-get -y -o DPkg::Lock::Timeout=600 install --no-install-recommends "${missing[@]}" || return 1
    fi
    if ! pkg_installed google-chrome-stable; then
        info "  Instalando o Google Chrome (pacote oficial; ele configura o repositório do Google)"
        local tmp
        tmp=$(mktemp -d)
        chmod 755 "$tmp"
        curl -fsSL --retry 3 -o "$tmp/chrome.deb" "$CHROME_DEB_URL" || { rm -rf "$tmp"; err "Falha ao baixar o Chrome."; return 1; }
        [[ "$(dpkg-deb -f "$tmp/chrome.deb" Package 2>/dev/null)" == google-chrome-stable ]] ||
            { rm -rf "$tmp"; err "O arquivo baixado não é o pacote do Chrome."; return 1; }
        run apt-get -y -o DPkg::Lock::Timeout=600 install "$tmp/chrome.deb"; local rc=$?
        rm -rf "$tmp"
        ((rc == 0)) || return 1
    fi
    ok "Dependências: $(google-chrome --version 2>/dev/null), ffmpeg, Xvfb"
}

install_mediamtx() {
    if [[ -x "$MTX_BIN" ]] && [[ "$("$MTX_BIN" --version 2>/dev/null)" == "$MTX_VERSION" ]]; then
        ok "MediaMTX $MTX_VERSION já instalado"; return 0
    fi
    local tmp
    tmp=$(mktemp -d)
    curl -fsSL --retry 3 -o "$tmp/mtx.tar.gz" "$MTX_URL" || { rm -rf "$tmp"; err "Falha ao baixar o MediaMTX."; return 1; }
    if [[ "$(sha256sum "$tmp/mtx.tar.gz" | cut -d' ' -f1)" != "$MTX_SHA256" ]]; then
        rm -rf "$tmp"; err "SHA-256 do MediaMTX não confere — download recusado."; return 1
    fi
    tar -xzf "$tmp/mtx.tar.gz" -C "$tmp" mediamtx LICENSE || { rm -rf "$tmp"; return 1; }
    install -d -m 0755 "$MTX_DIR"
    install -m 0755 "$tmp/mediamtx" "$MTX_BIN"
    install -m 0644 "$tmp/LICENSE" "$MTX_DIR/LICENSE"
    rm -rf "$tmp"
    ok "MediaMTX $MTX_VERSION instalado (SHA-256 conferido)"
}

ensure_user() {
    if ! id "$SVC_USER" >/dev/null 2>&1; then
        useradd --system --home-dir "$SVC_HOME" --create-home --shell /usr/sbin/nologin "$SVC_USER" || return 1
        info "  Usuário de serviço criado: $SVC_USER"
    fi
    install -d -m 0750 -o "$SVC_USER" -g "$SVC_USER" "$SVC_HOME"
}

write_files() {
    local port
    port=$(rtsp_port)
    install -d -m 0755 "$CONF_DIR" "$(dirname "$RUNNER")"

    cat > "$MTX_CONF" <<EOF
# $MARKER — servidor RTSP (gerenciado pelo instalador SEESTEC)
# Só RTSP/TCP e só em localhost. Portas evitadas: 8554 (Axxon) e 8000/8001 (Web do Axxon).
logLevel: warn
api: false
metrics: false
pprof: false
playback: false
rtsp: true
rtspTransports: [tcp]
rtspAddress: 127.0.0.1:$port
rtpAddress: 127.0.0.1:$((port + 10000))
rtcpAddress: 127.0.0.1:$((port + 10001))
rtmp: false
hls: false
webrtc: false
srt: false
paths:
  painel:
    source: publisher
EOF
    chmod 0644 "$MTX_CONF"

    cat > "$RUNNER" <<'EOF'
#!/usr/bin/env bash
# Painel web do Axxon One — Chrome num display virtual → vídeo RTSP.
# Gerenciado pelo instalador SEESTEC. Configuração: /etc/axxon-webpanel/webpanel.conf
set -euo pipefail
. /etc/axxon-webpanel/webpanel.conf
: "${URL:?URL não configurada}" "${RTSP_PORT:=8654}"
D=":${DISPLAY_NUM:-99}"
pids=()
cleanup() { kill "${pids[@]}" 2>/dev/null || true; wait 2>/dev/null || true; }
trap cleanup EXIT
trap 'exit 0' TERM INT   # parada normal pelo systemd

Xvfb "$D" -screen 0 "${WIDTH}x${HEIGHT}x24" -nolisten tcp -nocursor &
pids+=($!)
for _ in $(seq 50); do [[ -S "/tmp/.X11-unix/X${DISPLAY_NUM:-99}" ]] && break; sleep 0.2; done

DISPLAY="$D" google-chrome \
    --user-data-dir="$HOME/chrome" --no-first-run --no-default-browser-check \
    --kiosk --window-position=0,0 --window-size="${WIDTH},${HEIGHT}" --lang=pt-BR \
    --noerrdialogs --disable-infobars --disable-session-crashed-bubble \
    --disable-features=Translate,MediaRouter --password-store=basic \
    --autoplay-policy=no-user-gesture-required --hide-scrollbars \
    "$URL" >/dev/null 2>&1 &
pids+=($!)
sleep 6   # tempo para a página carregar antes do vídeo começar

ffmpeg -nostdin -hide_banner -loglevel warning \
    -f x11grab -draw_mouse 0 -framerate "$FPS" -video_size "${WIDTH}x${HEIGHT}" -i "$D" \
    -c:v libx264 -preset veryfast -tune zerolatency -pix_fmt yuv420p \
    -g "$((FPS * 2))" -b:v "$BITRATE" -maxrate "$BITRATE" -bufsize "$BITRATE" \
    -f rtsp -rtsp_transport tcp "rtsp://127.0.0.1:${RTSP_PORT}/painel" &
pids+=($!)

if (( ${RELOAD_HOURS:-0} > 0 )); then
    sleep "$((RELOAD_HOURS * 3600))" &   # recarga periódica da página
    pids+=($!)
fi

# Qualquer componente que cair (ou a recarga) derruba o conjunto; o systemd reinicia
wait -n
exit 1
EOF
    chmod 0755 "$RUNNER"

    cat > "$UNIT_DIR/$SVC_RTSP" <<EOF
[Unit]
Description=$MARKER — servidor RTSP local (MediaMTX)
After=network.target

[Service]
User=$SVC_USER
ExecStart=$MTX_BIN $MTX_CONF
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true

[Install]
WantedBy=multi-user.target
EOF

    cat > "$UNIT_DIR/$SVC_PANEL" <<EOF
[Unit]
Description=$MARKER — Chrome → vídeo RTSP ($(rtsp_url))
After=network-online.target $SVC_RTSP axxon-one.service
Wants=network-online.target
Requires=$SVC_RTSP

[Service]
User=$SVC_USER
Environment=HOME=$SVC_HOME
WorkingDirectory=$SVC_HOME
ExecStart=$RUNNER
Restart=always
RestartSec=5
TimeoutStopSec=15
KillMode=control-group
PrivateTmp=true
ProtectHome=true
Nice=5

[Install]
WantedBy=multi-user.target
EOF

    install -d -m 0755 "$(dirname "$CHROME_POLICY")"
    cat > "$CHROME_POLICY" <<'EOF'
{
  "TranslateEnabled": false,
  "DefaultBrowserSettingEnabled": false,
  "PromotionsEnabled": false,
  "BrowserSignin": 0,
  "MetricsReportingEnabled": false,
  "PasswordManagerEnabled": false,
  "AutofillAddressEnabled": false,
  "AutofillCreditCardEnabled": false
}
EOF
    chmod 0644 "$CHROME_POLICY"
}

# Instala este script como comando e cria os aliases para todos os usuários
install_command() {
    local self
    self=$(readlink -f "${BASH_SOURCE[0]}")
    if [[ "$self" != "$CMD_PATH" ]]; then
        [[ -f "$CMD_PATH" ]] && ! grep -q "Axxon One — Painel web" "$CMD_PATH" && backup_file "$CMD_PATH"
        install -m 0755 "$self" "$CMD_PATH"
    fi
    if ! grep -qF "$ALIAS_BEGIN" "$BASHRC" 2>/dev/null; then
        backup_file "$BASHRC"
        cat >> "$BASHRC" <<EOF

$ALIAS_BEGIN
# Troca a página do painel web do Axxon One (sem senha para o grupo $WEB_GROUP)
alias axxon-web='axxon-webpanel url'
alias axxon-dashboard='axxon-webpanel url'
$ALIAS_END
EOF
    fi
    ok "Comando $CMD_PATH e aliases axxon-web / axxon-dashboard ($BASHRC)"
    install_axxon_help && ok "Comando axxon: axxon --help lista todos os comandos"
}

# sudoers: o grupo pode rodar só url/status/restart sem senha. O script recusa
# mais de um comando por chamada, então "url remove" não passa pela regra.
install_sudoers() {
    local tmp u
    local -a users=("${ALLOW_USERS[@]}")
    [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]] && users+=("$SUDO_USER")
    getent group "$WEB_GROUP" >/dev/null || groupadd --system "$WEB_GROUP" || return 1
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
# $MARKER — gerenciado pelo instalador SEESTEC
# Membros do grupo $WEB_GROUP trocam a página do painel sem senha (axxon-web / axxon-dashboard)
%$WEB_GROUP ALL=(root) NOPASSWD: $CMD_PATH url, $CMD_PATH url *, $CMD_PATH status, $CMD_PATH restart
EOF
    if ! visudo -cqf "$tmp"; then
        rm -f "$tmp"; err "Regra do sudoers inválida — não instalada."; return 1
    fi
    install -m 0440 -o root -g root "$tmp" "$SUDOERS_FILE"
    rm -f "$tmp"
    for u in "${users[@]}"; do
        if id "$u" >/dev/null 2>&1; then
            usermod -aG "$WEB_GROUP" "$u" && info "  $u pode trocar a página sem senha (grupo $WEB_GROUP)"
        else
            warn "Usuário inexistente: $u"
        fi
    done
    local members
    members=$(getent group "$WEB_GROUP" | cut -d: -f4)
    if [[ -n "$members" ]]; then
        ok "Sem senha para: ${members//,/, } ($SUDOERS_FILE)"
    else
        warn "Ninguém no grupo $WEB_GROUP: os aliases vão pedir a senha do sudo. Inclua com --allow-user USUARIO."
    fi
}

remove_aliases() {
    grep -qF "$ALIAS_BEGIN" "$BASHRC" 2>/dev/null || return 0
    backup_file "$BASHRC"
    local tmp
    tmp=$(mktemp)
    awk -v b="$ALIAS_BEGIN" -v e="$ALIAS_END" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$BASHRC" > "$tmp" &&
        cat "$tmp" > "$BASHRC"
    rm -f "$tmp"
}

# Comando "axxon" (lista todos os comandos de terminal): axxon.sh do repositório,
# a cópia ao lado deste script ou baixada do GitHub. Falha aqui não é fatal.
install_axxon_help() {
    local dir tmp
    dir=$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo .)")
    tmp=$(mktemp)
    if [[ -f "$dir/axxon.sh" ]] && grep -q "$AXXON_HELP_MARKER" "$dir/axxon.sh"; then
        cp "$dir/axxon.sh" "$tmp"
    elif [[ -f "$AXXON_CMD" ]] && grep -q "$AXXON_HELP_MARKER" "$AXXON_CMD"; then
        rm -f "$tmp"; return 0            # já instalado e sem cópia mais nova à mão
    elif ! curl -fsSL --retry 2 -m 30 -o "$tmp" "$AXXON_HELP_RAW_URL" 2>/dev/null; then
        rm -f "$tmp"; warn "Não foi possível obter o axxon.sh (comando axxon não instalado)."; return 1
    fi
    if ! grep -q "$AXXON_HELP_MARKER" "$tmp" || ! bash -n "$tmp"; then
        rm -f "$tmp"; warn "axxon.sh inválido — comando axxon não instalado."; return 1
    fi
    if [[ -e "$AXXON_CMD" ]] && ! grep -q "$AXXON_HELP_MARKER" "$AXXON_CMD"; then
        rm -f "$tmp"; warn "Já existe outro comando $AXXON_CMD — não substituído."; return 1
    fi
    install -m 0755 "$tmp" "$AXXON_CMD"
    rm -f "$tmp"
}

# Prova de conceito anterior (mediamtx.service, /etc/mediamtx, /etc/axxon-webpanel.conf)
migrate_legacy() {
    local old_unit="$UNIT_DIR/mediamtx.service" old_conf="/etc/axxon-webpanel.conf" url
    if [[ -f "$old_unit" ]] && grep -q "painel web do Axxon One" "$old_unit"; then
        info "  Migrando a instalação anterior do painel"
        systemctl disable --now mediamtx.service >/dev/null 2>&1 || true
        backup_file "$old_unit"; rm -f "$old_unit"
        if [[ -f /etc/mediamtx/mediamtx.yml ]] && grep -q "Painel web" /etc/mediamtx/mediamtx.yml; then
            backup_file /etc/mediamtx/mediamtx.yml; rm -f /etc/mediamtx/mediamtx.yml
            rmdir /etc/mediamtx 2>/dev/null || true
        fi
        systemctl daemon-reload
    fi
    if [[ -f "$old_conf" ]]; then
        # shellcheck source=/dev/null
        url=$( (. "$old_conf" 2>/dev/null; printf '%s' "${URL:-}") )
        write_default_conf
        [[ -n "$url" && -z "$(conf_get URL)" ]] && conf_set URL "$url"
        backup_file "$old_conf"; rm -f "$old_conf"
    fi
}

start_services() {
    systemctl daemon-reload
    run systemctl enable "$SVC_RTSP" "$SVC_PANEL" || return 1
    run systemctl restart "$SVC_RTSP" || return 1
    run systemctl restart "$SVC_PANEL" || return 1
}

# ── comandos ──────────────────────────────────────────────────────────────────
cmd_install() {
    local url name port owner uid
    echo
    info "━━ Painel web do Axxon One — instalação"
    check_axxon
    migrate_legacy

    port="${OPT_RTSP_PORT:-$(rtsp_port)}"
    owner=$(port_owner "$port")
    if [[ -n "$owner" && "$owner" != mediamtx ]]; then
        die "A porta $port já está em uso por \"$owner\"." "Escolha outra com --rtsp-port."
    fi

    echo
    info "━━ Página a exibir"
    url=$(resolve_url "$(conf_get URL)")
    case $? in
        0) ;;
        3) die "Instalação cancelada." ;;
        *) exit 1 ;;
    esac
    name="${OPT_NAME:-$(conf_get CAMERA_NAME)}"
    name="${name:-$DEFAULT_NAME}"

    echo
    info "━━ Credenciais do Axxon One (para cadastrar a câmera)"
    api_login

    echo
    info "━━ Instalação dos componentes"
    install_packages || die "Falha ao instalar as dependências (veja $LOG_FILE)."
    install_mediamtx || die "Falha ao instalar o MediaMTX (veja $LOG_FILE)."
    ensure_user || die "Falha ao criar o usuário $SVC_USER."
    write_default_conf
    conf_set URL "$url"
    conf_set RTSP_PORT "$port"
    conf_set CAMERA_NAME "$name"
    conf_set AXXON_WEB_PORT "$WEB_PORT"
    write_files
    install_command
    install_sudoers || warn "Os aliases vão pedir a senha do sudo."
    start_services || die "Falha ao iniciar os serviços (veja: axxon-webpanel logs)."

    info "  Aguardando o vídeo do painel..."
    check_stream 12 || die "O vídeo não ficou disponível em $(rtsp_url)." "Veja: axxon-webpanel logs"
    ok "Vídeo publicado em $(rtsp_url)"

    echo
    info "━━ Câmera no Axxon One"
    if uid=$(find_camera); then
        ok "Câmera já cadastrada: $uid"
    else
        uid=$(add_camera "$name") || die "Não foi possível cadastrar a câmera."
        ok "Câmera \"$name\" cadastrada: $uid (sem gravação)"
    fi
    conf_set CAMERA_UID "$uid"
    if check_snapshot "$uid"; then
        ok "O Axxon One está recebendo o vídeo do painel"
    else
        warn "A câmera foi cadastrada, mas o Axxon ainda não mostrou imagem. Confira em alguns segundos: axxon-webpanel status"
    fi
    summary
}

cmd_url() {
    [[ -f "$CONF" ]] || die "O painel web não está instalado." "Instale com: sudo bash webpanel.sh"
    local current url
    current=$(conf_get URL)
    url=$(resolve_url "$current")
    case $? in
        0) ;;
        3) info "Nada alterado."; exit 0 ;;
        *) exit 1 ;;
    esac
    if [[ "$url" == "$current" && -z "$OPT_URL" ]]; then
        info "URL mantida: $url"; exit 0
    fi
    backup_file "$CONF"
    conf_set URL "$url"
    run systemctl restart "$SVC_PANEL" || die "Falha ao reiniciar o painel."
    info "  Aguardando o vídeo do painel..."
    if check_stream 12; then
        ok "Painel exibindo: $url"
    else
        die "O painel não voltou a publicar o vídeo." "Veja: axxon-webpanel logs"
    fi
}

cmd_status() {
    [[ -f "$CONF" ]] || die "O painel web não está instalado."
    local s
    if $QUIET; then
        # Verificação silenciosa (usada pelo install.sh): serviços, câmera e vídeo
        systemctl is-active --quiet "$SVC_RTSP" "$SVC_PANEL" && [[ -n "$(conf_get CAMERA_UID)" ]] && check_stream 3
        return
    fi
    printf '%sPainel web do Axxon One%s\n' "$C_BLD" "$C_RST"
    printf '  URL      : %s\n' "$(conf_get URL)"
    printf '  Câmera   : %s (%s)\n' "$(conf_get CAMERA_NAME)" "$(conf_get CAMERA_UID)"
    printf '  RTSP     : %s\n' "$(rtsp_url)"
    printf '  Vídeo    : %s×%s, %s fps, %s; recarga a cada %s h\n' \
        "$(conf_get WIDTH)" "$(conf_get HEIGHT)" "$(conf_get FPS)" "$(conf_get BITRATE)" "$(conf_get RELOAD_HOURS)"
    for s in "$SVC_RTSP" "$SVC_PANEL"; do
        printf '  %-27s: %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)"
    done
    if check_stream 1; then
        printf '  Stream   : %sonline%s\n' "$C_GRN" "$C_RST"
    else
        printf '  Stream   : %soffline%s\n' "$C_RED" "$C_RST"; return 1
    fi
}

cmd_restart() {
    [[ -f "$CONF" ]] || die "O painel web não está instalado."
    run systemctl restart "$SVC_RTSP" "$SVC_PANEL" || die "Falha ao reiniciar."
    check_stream 12 || die "O vídeo não voltou." "Veja: axxon-webpanel logs"
    ok "Painel reiniciado"
}

cmd_logs() { journalctl -u "$SVC_RTSP" -u "$SVC_PANEL" -n 60 --no-pager; }

cmd_remove() {
    local uid
    uid=$(conf_get CAMERA_UID)
    echo
    info "Serão removidos: serviços $SVC_PANEL e $SVC_RTSP, $CONF_DIR, $RUNNER,"
    info "  $MTX_DIR, a política do Chrome, os aliases e o comando $CMD_PATH."
    [[ -n "$uid" ]] && ! $KEEP_CAMERA && info "  E a câmera $uid do Axxon One."
    info "Pacotes (Chrome, ffmpeg, Xvfb) e o usuário $SVC_USER são mantidos."
    # -y confirma a remoção (usado pelo install.sh --remove)
    $ASSUME_YES || confirm "Confirma a remoção do painel web?" N || exit 0

    if [[ -n "$uid" ]] && ! $KEEP_CAMERA; then
        check_axxon
        api_login
        if remove_camera "$uid"; then ok "Câmera $uid removida do Axxon One"; else warn "Remova a câmera $uid pelo Client."; fi
    fi
    systemctl disable --now "$SVC_PANEL" "$SVC_RTSP" >/dev/null 2>&1 || true
    backup_file "$CONF"
    rm -f "$UNIT_DIR/$SVC_PANEL" "$UNIT_DIR/$SVC_RTSP" "$RUNNER" "$CHROME_POLICY"
    rm -f "$CONF" "$MTX_CONF" "$MTX_BIN" "$MTX_DIR/LICENSE"
    rmdir "$(dirname "$RUNNER")" "$CONF_DIR" "$MTX_DIR" 2>/dev/null || true
    systemctl daemon-reload
    systemctl reset-failed "$SVC_PANEL" "$SVC_RTSP" >/dev/null 2>&1 || true
    remove_aliases
    rm -f "$SUDOERS_FILE" "$CMD_PATH"
    # o comando axxon fica se ainda houver Server ou Client (é do install.sh também)
    if ! pkg_installed axxon-one && ! pkg_installed axxon-one-client &&
       [[ -f "$AXXON_CMD" ]] && grep -q "$AXXON_HELP_MARKER" "$AXXON_CMD"; then
        rm -f "$AXXON_CMD"
    fi
    getent group "$WEB_GROUP" >/dev/null && groupdel "$WEB_GROUP" 2>/dev/null
    ok "Painel web removido (backup da configuração em $BACKUP_DIR)"
}

summary() {
    echo
    printf '%s══════════════════════════════════════════════════════%s\n' "$C_GRN" "$C_RST"
    printf '%s  Painel web pronto%s\n' "$C_GRN$C_BLD" "$C_RST"
    printf '%s══════════════════════════════════════════════════════%s\n' "$C_GRN" "$C_RST"
    printf '  Página   : %s\n' "$(conf_get URL)"
    printf '  Câmera   : "%s" — arraste-a para uma célula do layout no Client\n' "$(conf_get CAMERA_NAME)"
    printf '  Trocar   : axxon-web  (ou axxon-dashboard) — abra um terminal novo para os aliases\n'
    printf '  Estado   : axxon-webpanel status | restart | logs\n'
    printf '  Ajuda    : axxon --help (todos os comandos de terminal)\n'
    printf '  Ajustes  : %s (resolução, fps, recarga)\n' "$CONF"
    printf '  Log      : %s\n\n' "$LOG_FILE"
}

main() {
    parse_args "$@"
    case "$ACTION" in
        logs) cmd_logs; exit $? ;;
        ask-url)
            has_tty || die "Sem terminal para perguntar a URL."
            ask_url ""; exit $? ;;
        check-url)
            [[ -n "$OPT_URL" ]] || die "Informe a URL."
            local u rc
            u=$(normalize_url "$OPT_URL")
            check_url "$u"; rc=$?
            printf '%s\n' "$u"; exit "$rc" ;;
    esac
    check_os
    ensure_root "$@"
    acquire_lock
    init_log
    case "$ACTION" in
        install) cmd_install ;;
        url)     cmd_url ;;
        status)  cmd_status ;;
        restart) cmd_restart ;;
        remove)  cmd_remove ;;
    esac
}

main "$@"
