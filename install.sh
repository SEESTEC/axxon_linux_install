#!/usr/bin/env bash
#
# Axxon One — instalador Linux (Server ou Client)
# SEESTEC — Engenharia e Tecnologia
#
# Requisitos: Ubuntu 24.04 LTS ou superior, acesso root (sudo) e internet.
#
# Uso:
#   sudo bash install.sh                 # menu interativo
#   sudo bash install.sh --server        # instala o Axxon One Server
#   sudo bash install.sh --client        # instala o Axxon One Client
#   sudo bash install.sh --server -y     # sem perguntas (valores padrão)
#   sudo bash install.sh --client --version 3.1.0.8   # versão específica
#   sudo bash install.sh --help          # todas as opções
#
# A instalação é dividida em etapas com checkpoint. Se algo falhar (queda de
# internet, falta de energia, Ctrl+C...), basta executar o script novamente:
# ele retoma da etapa onde parou. Downloads parciais são reaproveitados pelo apt.

# Reexecuta com bash caso tenha sido chamado via "sh install.sh"
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -uo pipefail

# ── constantes ────────────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="2.1.0"
readonly MIN_UBUNTU="24.04"

readonly REPO_URL="https://download.axxonsoft.com/debian-repository"
readonly REPO_HOST="download.axxonsoft.com"
readonly KEY_URL="$REPO_URL/info@axxonsoft.com.gpg.key"
readonly KEYRING="/etc/apt/keyrings/axxonsoft.gpg"
readonly SOURCES_FILE="/etc/apt/sources.list.d/axxonsoft.list"
readonly PREFS_FILE="/etc/apt/preferences.d/axxonsoft"
readonly MONO_PREFS_FILE="/etc/apt/preferences.d/axxonsoft-mono"
readonly LEGACY_KEY="/etc/apt/trusted.gpg.d/axxonsoft.gpg"
# Pacotes principais: Server e Client compartilham o axxon-one-core, logo
# precisam estar sempre na mesma versão
readonly -a MAIN_PKGS=(axxon-one axxon-one-client)

readonly STATE_DIR="/var/lib/axxon-install"
readonly STATE_FILE="$STATE_DIR/state"
readonly BACKUP_DIR="$STATE_DIR/backup"
readonly LOG_FILE="/var/log/axxon-install.log"
readonly LOCK_FILE="/run/lock/axxon-install.lock"

readonly MIN_FREE_GB=5
readonly SERVICE_TIMEOUT=180

# apt com retentativas de download e espera pelo lock do dpkg (ex.: unattended-upgrades)
readonly -a APT=(apt-get -y
    -o Acquire::Retries=5
    -o DPkg::Lock::Timeout=600
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold)

# ── opções ────────────────────────────────────────────────────────────────────
TYPE=""          # server | client
ASSUME_YES=false # -y: sem perguntas, debconf com valores padrão
DOMAIN=""        # domínio do Axxon One Server (opcional)
VERSION=""       # versão do Axxon One (vazio: a instalada ou a mais recente)
RESET=false
REMOVE=false

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
info() { printf '%s%s%s\n' "$C_CYN" "$*" "$C_RST"; _log "INFO  $*"; }
ok()   { printf '%s  [✓] %s%s\n' "$C_GRN" "$*" "$C_RST"; _log "OK    $*"; }
warn() { printf '%s  [!] %s%s\n' "$C_YLW" "$*" "$C_RST" >&2; _log "WARN  $*"; }
err()  { printf '%s  [✗] %s%s\n' "$C_RED" "$*" "$C_RST" >&2; _log "ERROR $*"; }

die() {
    err "$1"
    [[ -n "${2:-}" ]] && printf '      %s\n' "$2" >&2
    exit "${3:-1}"
}

usage() {
    cat <<EOF
Axxon One — instalador Linux v$SCRIPT_VERSION

Uso: sudo bash $(basename "$0") [opções]

  --server          Instala o Axxon One Server (pacote axxon-one)
  --client          Instala o Axxon One Client (pacote axxon-one-client)
  -y, --yes         Não faz perguntas; o debconf usa os valores padrão
  --domain NOME     Domínio do Axxon One Server (pode ficar em branco)
  --version VER     Versão do Axxon One (padrão: a já instalada nesta máquina;
                    se não houver nenhuma, a mais recente). Uma versão diferente
                    da instalada atualiza Server e Client juntos.
  --reset           Descarta o checkpoint e refaz todas as etapas
  --remove          Remove o Axxon One, o repositório e o checkpoint
  -h, --help        Mostra esta ajuda

Sem --server/--client, um menu pergunta o que instalar.
Log completo: $LOG_FILE
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
            --server)   TYPE="server" ;;
            --client)   TYPE="client" ;;
            -y|--yes)   ASSUME_YES=true ;;
            --domain)   [[ $# -ge 2 ]] || die "--domain exige um valor."
                        DOMAIN="$2"; shift ;;
            --domain=*) DOMAIN="${1#*=}" ;;
            --version)  [[ $# -ge 2 ]] || die "--version exige um valor."
                        VERSION="$2"; shift ;;
            --version=*) VERSION="${1#*=}" ;;
            --reset)    RESET=true ;;
            --remove)   REMOVE=true ;;
            -h|--help)  usage; exit 0 ;;
            *)          usage >&2; die "Opção desconhecida: $1" ;;
        esac
        shift
    done
}

# ── perguntas ─────────────────────────────────────────────────────────────────
has_tty() { [[ -t 0 ]]; }

# confirm "pergunta" [padrão S|N]
confirm() {
    local question="$1" default="${2:-S}" ans hint
    $ASSUME_YES && return 0
    has_tty || die "Sem terminal interativo para confirmar: \"$question\"." "Use -y para executar sem perguntas."
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

# ── verificações de ambiente ──────────────────────────────────────────────────
check_os() {
    local id="" version="" pretty=""
    if [[ -r /etc/os-release ]]; then
        id=$(. /etc/os-release && printf '%s' "${ID:-}")
        version=$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")
        pretty=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-}")
    fi

    if [[ "${id,,}" != "ubuntu" || -z "$version" ]] ||
       ! printf '%s\n%s\n' "$MIN_UBUNTU" "$version" | sort -V -C; then
        echo
        err "Sistema operacional incompatível: ${pretty:-desconhecido}"
        printf '      Esta instalação do Axxon One requer %sUbuntu %s LTS ou superior%s.\n' \
            "$C_BLD" "$MIN_UBUNTU" "$C_RST" >&2
        printf '      Instale/atualize a distro para Ubuntu %s+ e execute o instalador novamente.\n\n' \
            "$MIN_UBUNTU" >&2
        exit 2
    fi
}

ensure_root() {
    [[ $EUID -eq 0 ]] && return 0
    local self
    self=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)
    [[ -f "$self" ]] || die "Execute o instalador como root: sudo bash install.sh"
    command -v sudo >/dev/null || die "sudo não encontrado. Execute como root."
    info "Permissão de administrador necessária — solicitando via sudo..."
    exec sudo bash "$self" "$@"
}

acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Outra execução do instalador já está em andamento." \
        "Aguarde ela terminar ou encerre-a antes de continuar."
}

init_log() {
    touch "$LOG_FILE" && chmod 640 "$LOG_FILE"
    printf '\n[%s] ===== Instalador Axxon One v%s — args: %s =====\n' \
        "$(date '+%F %T')" "$SCRIPT_VERSION" "${ORIG_ARGS:-}" >> "$LOG_FILE"
}

check_arch() {
    local arch
    arch=$(dpkg --print-architecture)
    [[ "$arch" == "amd64" || "$arch" == "arm64" ]] ||
        die "Arquitetura não suportada: $arch (o repositório Axxon publica amd64 e arm64)."
}

check_systemd() {
    [[ -d /run/systemd/system ]] && return 0
    die "O Axxon One Server precisa do systemd ativo e ele não está em execução." \
        "No WSL: adicione [boot] systemd=true em /etc/wsl.conf e rode 'wsl --shutdown' no Windows."
}

check_disk() {
    local path avail_kb
    for path in /var/cache/apt /opt /; do
        [[ -d "$path" ]] || continue
        avail_kb=$(df -Pk "$path" | awk 'NR==2 {print $4}')
        if ((avail_kb < MIN_FREE_GB * 1024 * 1024)); then
            die "Espaço insuficiente em $path: $((avail_kb / 1024 / 1024)) GB livres." \
                "São necessários pelo menos $MIN_FREE_GB GB livres."
        fi
    done
}

# Aguarda conectividade com o repositório Axxon (até ~5 min)
check_network() {
    local i
    for ((i = 1; i <= 30; i++)); do
        if timeout 8 bash -c "exec 3<>/dev/tcp/$REPO_HOST/443" 2>/dev/null; then
            return 0
        fi
        ((i == 1)) && warn "Sem acesso a $REPO_HOST. Aguardando conexão (Ctrl+C para cancelar)..."
        sleep 10
    done
    die "Sem conexão com $REPO_HOST após várias tentativas." \
        "Verifique a internet/proxy/DNS e execute o instalador novamente — ele retomará de onde parou."
}

# ── execução de comandos ──────────────────────────────────────────────────────
# Executa um comando registrando a saída no log
run() {
    _log "\$ $*"
    "$@" 2>&1 | tee -a "$LOG_FILE"
    return "${PIPESTATUS[0]}"
}

# Executa um comando mantendo o terminal real (necessário para as telas do
# debconf) e registra a sessão no log via script(1)
run_tty() {
    _log "\$ $* (terminal)"
    local cmd
    printf -v cmd '%q ' "$@"
    script -q -e -a -c "$cmd" "$LOG_FILE" </dev/tty
}

# retry TENTATIVAS ESPERA comando...
retry() {
    local tries="$1" wait="$2" n
    shift 2
    for ((n = 1; n <= tries; n++)); do
        "$@" && return 0
        ((n < tries)) || break
        warn "Falhou (tentativa $n/$tries). Nova tentativa em ${wait}s..."
        sleep "$wait"
    done
    return 1
}

# ── checkpoint ────────────────────────────────────────────────────────────────
st_get() {
    [[ -f "$STATE_FILE" ]] || return 0
    grep -m1 "^$1=" "$STATE_FILE" | cut -d= -f2- || true
}

st_set() {
    local tmp
    mkdir -p "$STATE_DIR"
    tmp=$(mktemp "$STATE_DIR/.state.XXXXXX")
    [[ -f "$STATE_FILE" ]] && grep -v "^$1=" "$STATE_FILE" > "$tmp"
    printf '%s=%s\n' "$1" "$2" >> "$tmp"
    mv -f "$tmp" "$STATE_FILE"
    sync "$STATE_FILE" 2>/dev/null || true
}

st_clear() { rm -f "$STATE_FILE"; }

# ── etapas ────────────────────────────────────────────────────────────────────
#
# Cada etapa tem: id | descrição | função que executa | função que valida.
# Uma etapa marcada como concluída só é pulada se a validação ainda passar.
#
STEPS_COMMON=(
    "legacy|Limpeza de configurações antigas do Axxon|do_legacy|chk_legacy"
    "repair|Reparo de pacotes interrompidos|do_repair|chk_repair"
    "base|Dependências do instalador (wget, gnupg)|do_base|chk_base"
    "key|Chave GPG do repositório Axxon|do_key|chk_key"
    "sources|Repositório Axxon e prioridades do apt|do_sources|chk_sources"
    "update|Atualização da lista de pacotes|do_update|chk_update"
    "version|Versão do Axxon One e dependências|do_version|chk_version"
    "download|Download dos pacotes|do_download|chk_download"
    "install|Instalação do Axxon One|do_install|chk_install"
)
STEPS_SERVER=("service|Serviço axxon-one ativo|do_service|chk_service")

steps_for_type() {
    STEPS=("${STEPS_COMMON[@]}")
    [[ "$TYPE" == "server" ]] && STEPS+=("${STEPS_SERVER[@]}")
    return 0
}

package_name() { [[ "$TYPE" == "server" ]] && echo "axxon-one" || echo "axxon-one-client"; }

pkg_installed() {
    [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" == "installed" ]]
}

# repair — conclui configurações de pacotes interrompidas (queda de energia, Ctrl+C)
do_repair() {
    export DEBIAN_FRONTEND=noninteractive
    run dpkg --configure -a || return 1
    run "${APT[@]}" --fix-broken install
}
chk_repair() { [[ -z "$(dpkg --audit 2>/dev/null)" ]]; }

# base — somente o necessário para importar a chave do repositório
readonly BASE_PKGS=(ca-certificates wget gnupg)
do_base() {
    export DEBIAN_FRONTEND=noninteractive
    retry 3 15 run "${APT[@]}" update || return 1
    retry 3 15 run "${APT[@]}" install --no-install-recommends "${BASE_PKGS[@]}"
}
chk_base() {
    local p
    for p in "${BASE_PKGS[@]}"; do pkg_installed "$p" || return 1; done
}

# legacy — entradas do repositório Axxon fora do arquivo gerenciado e chave antiga
# do apt-key, deixadas por instaladores anteriores. Geram conflito de Signed-By.
legacy_sources() {
    grep -rlsE "^[^#]*${REPO_HOST//./\\.}" /etc/apt/sources.list /etc/apt/sources.list.d/ |
        grep -vxF "$SOURCES_FILE" || true
}
do_legacy() {
    local f stamp
    stamp=$(date +%Y%m%d-%H%M%S)
    mkdir -p "$BACKUP_DIR"
    while read -r f; do
        [[ -n "$f" ]] || continue
        cp -a "$f" "$BACKUP_DIR/$(basename "$f").$stamp"
        if [[ "$f" == /etc/apt/sources.list ]]; then
            sed -i -E "/^[^#]*${REPO_HOST//./\\.}/ s/^/# desativado pelo instalador Axxon: /" "$f"
        else
            rm -f "$f"
        fi
        info "  Entrada antiga removida: $f (backup em $BACKUP_DIR)"
    done < <(legacy_sources)
    # O arquivo gerenciado é sempre regerado na etapa "sources"
    if [[ -f "$SOURCES_FILE" ]] && ! grep -q "signed-by=$KEYRING" "$SOURCES_FILE"; then
        cp -a "$SOURCES_FILE" "$BACKUP_DIR/$(basename "$SOURCES_FILE").$stamp"
        rm -f "$SOURCES_FILE"
        info "  Lista antiga removida: $SOURCES_FILE"
    fi
    if [[ -f "$LEGACY_KEY" ]]; then
        mv -f "$LEGACY_KEY" "$BACKUP_DIR/$(basename "$LEGACY_KEY").$stamp"
        info "  Chave antiga removida: $LEGACY_KEY"
    fi
    return 0
}
chk_legacy() {
    [[ -z "$(legacy_sources)" && ! -f "$LEGACY_KEY" ]] || return 1
    [[ ! -f "$SOURCES_FILE" ]] || grep -q "signed-by=$KEYRING" "$SOURCES_FILE"
}

# key — chave em keyring dedicado (apt-key está obsoleto no Ubuntu 24.04)
do_key() {
    local tmp
    tmp=$(mktemp -d)
    if ! retry 5 10 wget -q -T 30 -O "$tmp/key.asc" "$KEY_URL"; then
        rm -rf "$tmp"; err "Não foi possível baixar a chave: $KEY_URL"; return 1
    fi
    if ! gpg --batch --quiet --show-keys "$tmp/key.asc" >/dev/null 2>&1; then
        rm -rf "$tmp"; err "O arquivo baixado não é uma chave GPG válida."; return 1
    fi
    install -d -m 0755 "$(dirname "$KEYRING")"
    gpg --batch --yes --dearmor -o "$tmp/key.gpg" "$tmp/key.asc" &&
        install -m 0644 "$tmp/key.gpg" "$KEYRING"
    local rc=$?
    rm -rf "$tmp"
    return $rc
}
chk_key() { [[ -s "$KEYRING" ]] && gpg --batch --quiet --show-keys "$KEYRING" >/dev/null 2>&1; }

# sources — além dos componentes da documentação (stable main e stretch
# backports/main), o Ubuntu 24.04 precisa de:
#   • buster backports/main → libicu63 (axxon-one-core) e mono 6.12 (client 3.2+)
#   • stretch backports/mono-6_4 → mono 6.4, versão exata exigida pelo client 3.1
# As prioridades evitam que pacotes Debian do repositório Axxon substituam os
# do Ubuntu: só pacotes axxon-* têm preferência. O mono exato exigido pelo
# client é fixado à parte, na etapa "version" ($MONO_PREFS_FILE).
expected_sources() {
    local opt="[signed-by=$KEYRING]"
    cat <<EOF
# Gerenciado pelo instalador Axxon One (SEESTEC) — não edite manualmente
deb $opt $REPO_URL stable main
deb $opt $REPO_URL stretch backports/main backports/mono-6_4
deb $opt $REPO_URL buster backports/main
EOF
}
expected_prefs() {
    cat <<EOF
# Gerenciado pelo instalador Axxon One (SEESTEC) — não edite manualmente
Package: *
Pin: origin "$REPO_HOST"
Pin-Priority: 100

Package: axxon-* aksusbd
Pin: origin "$REPO_HOST"
Pin-Priority: 500
EOF
}
do_sources() {
    expected_sources > "$SOURCES_FILE.tmp" && mv -f "$SOURCES_FILE.tmp" "$SOURCES_FILE" &&
        chmod 0644 "$SOURCES_FILE" || return 1
    expected_prefs > "$PREFS_FILE.tmp" && mv -f "$PREFS_FILE.tmp" "$PREFS_FILE" &&
        chmod 0644 "$PREFS_FILE"
}
chk_sources() {
    [[ "$(cat "$SOURCES_FILE" 2>/dev/null)" == "$(expected_sources)" ]] &&
        [[ "$(cat "$PREFS_FILE" 2>/dev/null)" == "$(expected_prefs)" ]]
}

# update — apt update precisa terminar sem erros nos repositórios
do_update() {
    export DEBIAN_FRONTEND=noninteractive
    local out
    out=$(mktemp)
    if ! retry 3 20 run "${APT[@]}" update > "$out"; then
        cat "$out"; rm -f "$out"; return 1
    fi
    cat "$out"
    if grep -qE '^(W|E): .*(axxonsoft|NO_PUBKEY|Signed-By)' "$out"; then
        rm -f "$out"; err "O apt reportou problemas no repositório Axxon (veja acima)."; return 1
    fi
    rm -f "$out"
    chk_update || { err "Pacote $(package_name) não encontrado no repositório."; return 1; }
}
chk_update() {
    local cand
    cand=$(apt-cache policy "$(package_name)" 2>/dev/null | awk '/Candidate:/ {print $2}')
    [[ -n "$cand" && "$cand" != "(none)" ]]
}

# version — escolhe a versão e monta a lista exata de pacotes a instalar.
#
# Server e Client dependem do mesmo axxon-one-core com versão exata. Instalar
# o pacote sem versão traria a mais recente do repositório e atualizaria o core
# do outro componente já instalado (ou o removeria). Por isso:
#   • --version informado → essa versão;
#   • axxon-one-core instalado → a mesma versão dele;
#   • nada instalado → a mais recente.
# Os pacotes principais já instalados entram na lista na mesma versão, de modo
# que uma troca de versão atualiza Server e Client juntos.
installed_version() {
    pkg_installed "$1" || return 1
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null
}

resolve_version() {
    local v
    if [[ -n "$VERSION" ]]; then
        printf '%s\n' "$VERSION"
    elif v=$(installed_version axxon-one-core) && [[ -n "$v" ]]; then
        printf '%s\n' "$v"
    else
        apt-cache policy "$(package_name)" 2>/dev/null | awk '/Candidate:/ {print $2}'
    fi
}

# Campo Depends/Pre-Depends de PACOTE=VERSÃO, uma dependência por linha
pkg_depends() {
    apt-cache show "$1=$2" 2>/dev/null |
        awk '/^$/ {exit} /^(Pre-)?Depends:/ {sub(/^[^:]*: */, ""); print}' |
        tr ',' '\n' | sed -E 's/^ +//; s/ *\|.*//'
}

# Pacotes principais a instalar: o escolhido + os já instalados
target_mains() {
    local p
    printf '%s\n' "$(package_name)"
    for p in "${MAIN_PKGS[@]}"; do
        [[ "$p" != "$(package_name)" ]] && pkg_installed "$p" && printf '%s\n' "$p"
    done
    return 0
}

# Fecho das dependências axxon-* com versão exata (= VERSÃO)
pkg_closure() {
    local v="$1" p d
    local -a queue
    local -A seen=()
    mapfile -t queue < <(target_mains)
    while ((${#queue[@]})); do
        p="${queue[0]}"; queue=("${queue[@]:1}")
        [[ -n "${seen[$p]:-}" ]] && continue
        seen[$p]=1
        printf '%s\n' "$p"
        while read -r d; do
            [[ -n "$d" && -z "${seen[$d]:-}" ]] && queue+=("$d")
        done < <(pkg_depends "$p" "$v" | awk -v v="$v" '$1 ~ /^axxon-/ && $2 == "(=" && $3 == v ")" {print $1}')
    done
}

# Versão exata do mono exigida pelo client (vazio se não houver client)
mono_version_for() {
    local v="$1" p
    for p in $(st_get specs_pkgs); do
        pkg_depends "$p" "$v" | awk '$1 == "mono-runtime" && $2 == "(=" {sub(/\)$/, "", $3); print $3; exit}'
    done | head -n1
}

expected_mono_prefs() {
    cat <<EOF
# Gerenciado pelo instalador Axxon One (SEESTEC) — não edite manualmente
# Versão exata do mono exigida pelo Axxon One Client $2
Package: /mono/ ca-certificates-mono
Pin: version $1
Pin-Priority: 1001
EOF
}

do_version() {
    local v cur p mono sim
    local -a pkgs specs
    v=$(resolve_version)
    if [[ -z "$v" || "$v" == "(none)" ]]; then
        err "Não foi possível determinar a versão do Axxon One a instalar."; return 1
    fi
    if ! apt-cache show "$(package_name)=$v" >/dev/null 2>&1; then
        err "$(package_name) $v não está disponível no repositório Axxon."
        printf '      Versões disponíveis: %s\n' \
            "$(apt-cache madison "$(package_name)" | awk '{print $3}' | xargs)" >&2
        cur=$(installed_version axxon-one-core || true)
        [[ -n "$cur" && -z "$VERSION" ]] &&
            printf '      O Axxon One %s já instalado define a versão. Para atualizar tudo junto, use --version.\n' "$cur" >&2
        return 1
    fi

    cur=$(installed_version axxon-one-core || true)
    if [[ -n "$cur" && "$cur" != "$v" ]]; then
        warn "Axxon One instalado: $cur — versão escolhida: $v."
        warn "Pacotes que serão trocados de versão: $(target_mains | xargs)"
        confirm "Trocar a versão do Axxon One instalado para $v?" N || return 1
    fi

    mapfile -t pkgs < <(pkg_closure "$v")
    specs=()
    for p in "${pkgs[@]}"; do specs+=("$p=$v"); done
    st_set specs_pkgs "${pkgs[*]}"

    # mono: fixa a versão exata exigida pelo client (se ele fizer parte da instalação)
    mono=$(mono_version_for "$v")
    if [[ -n "$mono" ]]; then
        expected_mono_prefs "$mono" "$v" > "$MONO_PREFS_FILE.tmp" &&
            mv -f "$MONO_PREFS_FILE.tmp" "$MONO_PREFS_FILE" && chmod 0644 "$MONO_PREFS_FILE" || return 1
        info "  mono fixado em $mono ($MONO_PREFS_FILE)"
    fi

    # Simulação: nenhum pacote axxon pode ser removido ou mudar de versão fora do plano
    if ! sim=$(apt-get -s install "${specs[@]}" 2>&1); then
        printf '%s\n' "$sim" | tail -n 30 >&2
        err "O apt não consegue resolver a instalação de: ${specs[*]}"; return 1
    fi
    _log "simulação: $(printf '%s\n' "$sim" | grep -E '^(Inst|Remv)' | grep -c .) operações"
    if printf '%s\n' "$sim" | grep -E '^Remv axxon-'; then
        err "A instalação removeria pacotes Axxon (acima). Operação cancelada."; return 1
    fi
    # "Inst PACOTE [atual] (nova ...)": um pacote axxon já instalado só pode ir
    # para a versão escolhida. Novos sem versão casada (drivers/detector pack) são aceitos.
    local name newv extra=""
    while read -r name newv; do
        [[ "$newv" == "$v" ]] && continue
        pkg_installed "$name" && extra+=" $name→$newv"
    done < <(printf '%s\n' "$sim" | sed -nE 's/^Inst (axxon-[^ ]+) .*\(([^ ]+) .*/\1 \2/p')
    if [[ -n "$extra" ]]; then
        err "A instalação alteraria pacotes Axxon fora do plano:$extra"; return 1
    fi

    st_set version "$v"
    st_set specs "${specs[*]}"
    info "  Versão: $v — pacotes: ${specs[*]}"
}
chk_version() {
    local v mono
    v=$(st_get version)
    [[ -n "$v" && "$v" == "$(resolve_version)" && -n "$(st_get specs)" ]] || return 1
    # Lista ainda corresponde aos pacotes principais instalados
    local p
    for p in $(target_mains); do
        [[ " $(st_get specs_pkgs) " == *" $p "* ]] || return 1
    done
    mono=$(mono_version_for "$v")
    [[ -z "$mono" ]] || [[ "$(cat "$MONO_PREFS_FILE" 2>/dev/null)" == "$(expected_mono_prefs "$mono" "$v")" ]]
}

# Lista "pacote=versão" definida na etapa "version"
pkg_specs() { st_get specs; }

# download — baixa tudo antes de instalar; se a conexão cair, o apt reaproveita
# os arquivos já baixados (inclusive parciais) na próxima execução
do_download() {
    export DEBIAN_FRONTEND=noninteractive
    local -a specs
    read -ra specs <<<"$(pkg_specs)"
    ((${#specs[@]})) || return 1
    retry 5 20 run "${APT[@]}" install --download-only "${specs[@]}"
}
# Concluído quando não resta nenhum .deb a baixar (ou o pacote já está instalado)
chk_download() {
    local uris
    local -a specs
    read -ra specs <<<"$(pkg_specs)"
    ((${#specs[@]})) || return 1
    uris=$(apt-get -qq --print-uris install "${specs[@]}" 2>/dev/null) || return 1
    [[ -z "$uris" ]]
}

# install
preseed_debconf() {
    [[ "$TYPE" == "server" && -n "$DOMAIN" ]] || return 0
    printf 'axxon-one axxon-one/domain string %s\n' "$DOMAIN" | debconf-set-selections
}
do_install() {
    local -a specs
    read -ra specs <<<"$(pkg_specs)"
    ((${#specs[@]})) || return 1
    preseed_debconf || return 1
    if $ASSUME_YES || ! has_tty; then
        export DEBIAN_FRONTEND=noninteractive
        retry 2 10 run "${APT[@]}" install "${specs[@]}" || return 1
    else
        echo
        info "O instalador do Axxon One fará algumas perguntas de configuração."
        info "Em caso de dúvida, mantenha o valor padrão (Enter)."
        [[ "$TYPE" == "server" ]] &&
            info "O domínio pode ficar em branco e ser definido no Client na primeira conexão."
        echo
        unset DEBIAN_FRONTEND
        run_tty "${APT[@]}" install "${specs[@]}" || return 1
    fi
    export DEBIAN_FRONTEND=noninteractive
    chk_install
}
chk_install() {
    local v p
    v=$(st_get version)
    [[ -n "$v" ]] || return 1
    for p in $(st_get specs_pkgs); do
        [[ "$(installed_version "$p")" == "$v" ]] || return 1
    done
    [[ -z "$(dpkg --audit 2>/dev/null)" ]]
}

# service (server)
do_service() {
    run systemctl daemon-reload
    run systemctl enable axxon-one.service || return 1
    systemctl is-active --quiet axxon-one.service || run systemctl start axxon-one.service || return 1
    local waited=0
    info "  Aguardando o serviço axxon-one ficar ativo (até ${SERVICE_TIMEOUT}s)..."
    until systemctl is-active --quiet axxon-one.service; do
        if ((waited >= SERVICE_TIMEOUT)) || systemctl is-failed --quiet axxon-one.service; then
            run systemctl status --no-pager axxon-one.service
            run journalctl -u axxon-one.service -n 50 --no-pager
            return 1
        fi
        sleep 5; ((waited += 5))
    done
}
chk_service() {
    systemctl is-enabled --quiet axxon-one.service 2>/dev/null &&
        systemctl is-active --quiet axxon-one.service
}

# ── execução das etapas ───────────────────────────────────────────────────────
CURRENT_STEP=""

run_steps() {
    local total=${#STEPS[@]} i=0 entry id label fn chk
    for entry in "${STEPS[@]}"; do
        IFS='|' read -r id label fn chk <<<"$entry"
        ((i++))
        if [[ "$(st_get "step_$id")" == "done" ]] && "$chk" >/dev/null 2>&1; then
            printf '%s  [→] %d/%d %s — já concluída%s\n' "$C_YLW" "$i" "$total" "$label" "$C_RST"
            continue
        fi
        echo
        info "━━ Etapa $i/$total: $label"
        CURRENT_STEP="$id"
        st_set "step_$id" "running"
        if "$fn" && "$chk"; then
            st_set "step_$id" "done"
            ok "$label"
        else
            st_set "step_$id" "failed"
            st_set "failed_at" "$id"
            echo
            err "Falha na etapa $i/$total: $label"
            printf '      Detalhes no log: %s\n' "$LOG_FILE" >&2
            printf '      Corrija o problema e execute o instalador novamente — ele retoma desta etapa.\n\n' >&2
            exit 1
        fi
    done
    CURRENT_STEP=""
}

show_progress() {
    local entry id label fn chk status mark
    echo
    printf '%s  Instalação anterior encontrada: Axxon One %s%s\n' "$C_BLD" "${TYPE^^}" "$C_RST"
    for entry in "${STEPS[@]}"; do
        IFS='|' read -r id label fn chk <<<"$entry"
        status=$(st_get "step_$id")
        case "$status" in
            done)    mark="${C_GRN}✓${C_RST}" ;;
            failed)  mark="${C_RED}✗${C_RST}" ;;
            running) mark="${C_YLW}…${C_RST}" ;;
            *)       mark="○" ;;
        esac
        printf '    %s  %s\n' "$mark" "$label"
    done
    echo
}

on_interrupt() {
    echo
    [[ -n "$CURRENT_STEP" ]] && st_set "step_$CURRENT_STEP" "failed"
    err "Instalação interrompida pelo usuário."
    printf '      Execute o instalador novamente para retomar de onde parou.\n\n' >&2
    exit 130
}

# ── menu ──────────────────────────────────────────────────────────────────────
choose_type() {
    has_tty || die "Nenhum tipo informado e sem terminal interativo." "Use --server ou --client."
    local opt
    while true; do
        cat <<EOF

  ╔════════════════════════════════════════╗
  ║     AXXON ONE — Instalador Linux       ║
  ╠════════════════════════════════════════╣
  ║  1) Server                             ║
  ║  2) Client                             ║
  ║  3) Sair                               ║
  ╚════════════════════════════════════════╝
EOF
        read -rp "  Escolha o tipo de instalação [1-3]: " opt || exit 1
        case "$opt" in
            1) TYPE="server" ;;
            2) TYPE="client" ;;
            3) echo; info "Instalação cancelada."; exit 0 ;;
            *) warn "Opção inválida."; continue ;;
        esac
        confirm "Confirma a instalação do Axxon One ${C_BLD}${TYPE^^}${C_RST}?" && return 0
    done
}

# Decide entre retomar, recomeçar ou iniciar uma nova instalação
resolve_state() {
    local saved_type completed
    saved_type=$(st_get type)
    completed=$(st_get completed)

    if $RESET; then
        st_clear
        saved_type=""
    fi

    if [[ -n "$saved_type" && "$completed" != "yes" ]]; then
        if [[ -n "$TYPE" && "$TYPE" != "$saved_type" ]]; then
            die "Existe uma instalação do ${saved_type^^} não concluída." \
                "Retome com --$saved_type ou descarte o checkpoint com --reset."
        fi
        TYPE="$saved_type"
        steps_for_type
        show_progress
        if ! confirm "Retomar a instalação de onde parou?" S; then
            confirm "Descartar o progresso e recomeçar do zero?" N || exit 0
            st_clear
        fi
    else
        [[ -n "$TYPE" ]] || choose_type
        if [[ "$completed" == "yes" && "$saved_type" == "$TYPE" ]]; then
            info "O Axxon One ${TYPE^^} já foi instalado por este instalador — revalidando etapas."
        else
            st_clear
        fi
    fi

    st_set type "$TYPE"
    st_set completed "no"
    # --version vale também para as retomadas seguintes
    if [[ -n "$VERSION" ]]; then
        st_set requested_version "$VERSION"
    else
        VERSION=$(st_get requested_version)
    fi
    steps_for_type
}

# ── remoção ───────────────────────────────────────────────────────────────────
do_remove() {
    local pkgs
    pkgs=$(dpkg-query -W -f='${db:Status-Status} ${Package}\n' 'axxon-*' 2>/dev/null |
        awk '$1 != "not-installed" {print $2}' | xargs || true)
    echo
    info "Serão removidos: ${pkgs:-(nenhum pacote axxon instalado)}"
    info "Também: $SOURCES_FILE, $PREFS_FILE, $MONO_PREFS_FILE, $KEYRING e o checkpoint."
    confirm "Confirma a remoção?" N || exit 0
    export DEBIAN_FRONTEND=noninteractive
    if [[ -n "$pkgs" ]]; then
        systemctl stop axxon-one.service >/dev/null 2>&1 || true
        # shellcheck disable=SC2086
        run "${APT[@]}" purge $pkgs || die "Falha ao remover os pacotes (veja $LOG_FILE)."
    fi
    rm -f "$SOURCES_FILE" "$PREFS_FILE" "$MONO_PREFS_FILE" "$KEYRING"
    st_clear
    run "${APT[@]}" update >/dev/null || true
    ok "Axxon One removido."
    info "Dependências que ficaram sem uso podem ser removidas com: sudo apt autoremove"
}

# ── resumo final ──────────────────────────────────────────────────────────────
summary() {
    local pkg ver
    pkg=$(package_name)
    ver=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)
    echo
    printf '%s══════════════════════════════════════════════════════%s\n' "$C_GRN" "$C_RST"
    printf '%s  Axxon One %s %s instalado com sucesso!%s\n' "$C_GRN$C_BLD" "${TYPE^^}" "$ver" "$C_RST"
    printf '%s══════════════════════════════════════════════════════%s\n' "$C_GRN" "$C_RST"
    if [[ "$TYPE" == "server" ]]; then
        local base
        base=$(grep -m1 -oP '^NGP_PORT_BASE=\K[0-9]+' /opt/AxxonSoft/AxxonOne/instance.conf 2>/dev/null || echo 20111)
        printf '  Serviço  : axxon-one (%s)\n' "$(systemctl is-active axxon-one.service)"
        printf '  Endereço : %s\n' "$(hostname -I 2>/dev/null | xargs)"
        printf '  Portas   : TCP %s a %s\n' "$base" "$((base + 100))"
        printf '  Comandos : sudo systemctl {status|restart|stop} axxon-one\n'
        printf '  Reconfig.: sudo dpkg-reconfigure axxon-one\n'
    else
        printf '  Abra o "Axxon One Client" pelo menu de aplicativos (não execute como root).\n'
        printf '  Idioma/logs: sudo dpkg-reconfigure axxon-one-client\n'
        printf '  O Client deve ter a mesma versão do Server ao qual se conecta.\n'
    fi
    printf '  Log      : %s\n\n' "$LOG_FILE"
}

# ── principal ─────────────────────────────────────────────────────────────────
main() {
    ORIG_ARGS="$*"
    parse_args "$@"
    check_os
    ensure_root "$@"
    acquire_lock
    init_log
    trap on_interrupt INT TERM

    if $REMOVE; then
        do_remove
        exit 0
    fi

    check_arch
    resolve_state
    [[ "$TYPE" == "server" ]] && check_systemd
    check_disk
    check_network

    info "Instalando Axxon One ${TYPE^^} — Ubuntu $(. /etc/os-release && echo "$VERSION_ID")"
    run_steps

    st_set completed "yes"
    st_set completed_at "$(date '+%F %T')"
    summary
}

main "$@"
