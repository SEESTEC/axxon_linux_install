#!/bin/bash

set -euo pipefail

# ── formatação ────────────────────────────────────────────────────────────────
bold() { printf '\033[1m%s\033[0m' "$*"; }
red()  { printf '\033[0;31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
info() { printf '\033[0;36m%s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m%s\033[0m\n' "$*"; }

abort() {
    echo
    red "Instalação encerrada."
    echo
    exit 0
}

# Retorna 0 = sim | 1 = não | exit = qualquer outra tecla
confirm() {
    local ans
    read -rp "$(bold "$1") [S/N ou qualquer outra tecla para sair]: " ans
    case "$ans" in
        [Ss]) return 0 ;;
        [Nn]) return 1 ;;
        *)    abort ;;
    esac
}

# ── sistema de checkpoint ─────────────────────────────────────────────────────
#
# Arquivo: /var/tmp/axxon_install.checkpoint
# Diretório de instalação persistente: /var/tmp/axxon_install/
#
# Se o download ou qualquer passo for interrompido, execute o script novamente
# com conexão estável — o installer lê o checkpoint e retoma de onde parou.
#
CKPT_FILE="/var/tmp/axxon_install.checkpoint"
INSTALL_DIR="/var/tmp/axxon_install"
ZIP_FILE="$INSTALL_DIR/axxon-one.zip"
PKG_DIR="$INSTALL_DIR/axxon"
LOG_FILE="/var/tmp/axxon_install.log"

# Grava ou atualiza uma chave no checkpoint (operação atômica via tmp)
ckpt_set() {
    local key="$1" val="$2"
    mkdir -p "$(dirname "$CKPT_FILE")"
    touch "$CKPT_FILE"
    local tmp; tmp=$(mktemp)
    grep -v "^${key}=" "$CKPT_FILE" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    mv "$tmp" "$CKPT_FILE"
}

# Lê o valor de uma chave do checkpoint
ckpt_get() {
    grep "^${1}=" "$CKPT_FILE" 2>/dev/null | cut -d= -f2- || true
}

# Marca um passo como concluído
ckpt_done() {
    ckpt_set "$1" "done"
    grn "  [✓] ${2:-$1}"
}

# Retorna 0 se o passo já foi concluído
ckpt_is_done() {
    [[ -f "$CKPT_FILE" ]] && grep -qxF "${1}=done" "$CKPT_FILE" 2>/dev/null
}

# Avisa que o passo foi pulado (já concluído)
ckpt_skip() {
    warn "  [→] ${2:-$1} — já concluído, pulando."
}

# Remove checkpoint e diretório de instalação (chamado ao final com sucesso)
ckpt_clear() {
    rm -f "$CKPT_FILE"
    rm -rf "$INSTALL_DIR"
}

# Exibe o status dos passos em um quadro
_ckpt_row() {
    local step="$1" label="$2" type_filter="${3:-}"
    # pula passos exclusivos de um tipo se o tipo salvo for diferente
    if [[ -n "$type_filter" ]]; then
        local saved_type; saved_type=$(ckpt_get TYPE)
        [[ "$saved_type" == "$type_filter" ]] || return 0
    fi
    if ckpt_is_done "$step"; then
        printf "║  ✓  %-46s ║\n" "$label"
    else
        printf "║  ○  %-46s ║\n" "$label"
    fi
}

ckpt_show_status() {
    local saved_type; saved_type=$(ckpt_get TYPE)
    local saved_version; saved_version=$(ckpt_get VERSION)
    echo
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║      AXXON ONE — Instalação Anterior Detectada       ║"
    echo "╠══════════════════════════════════════════════════════╣"
    printf "║  Tipo    : %-41s ║\n" "${saved_type:-?}"
    printf "║  Versão  : %-41s ║\n" "${saved_version:-?}"
    echo "║                                                      ║"
    echo "║  Progresso dos passos:                               ║"
    _ckpt_row apt_update       "Atualização do sistema"
    _ckpt_row bashrc           "Aliases no .bashrc"
    _ckpt_row download_zip     "Download do pacote Axxon"
    _ckpt_row extract_zip      "Extração do pacote"
    _ckpt_row setup_repo       "Repositório e chave GPG"
    _ckpt_row install_pkgs     "Instalação dos pacotes .deb"
    _ckpt_row download_scripts "Scripts screenREC"          "client"
    _ckpt_row cleanup_config   "Retenção de gravações"      "client"
    _ckpt_row setup_autostart  "Autostart screenREC"        "client"
    _ckpt_row setup_samba      "Servidor Samba"             "client"
    _ckpt_row save_sudo_pass   "Credencial sudo"            "client"
    _ckpt_row force_xorg       "Desabilitar Wayland"        "client"
    _ckpt_row disable_network  "Desabilitar rede externa"
    echo "╚══════════════════════════════════════════════════════╝"
    echo
}

# ── verificação de conexão ────────────────────────────────────────────────────
checkConnection() {
    i=1;
    while ! ping -c 1 -W 1 8.8.8.8 > /dev/null 2>&1; do
        echo -ne "\r\033[KPor favor, conecte-se à internet para seguir. \e[1;90mPressione \"x\" para encerrar\e[0m ou \e[1maguarde até re-estabelecer conexão [tentativa(s): $i]\e[0m";
        ((i++));
        read -t 1 -n 1 key;
        if [[ "$key" == 'x' ]]; then
            echo -e "\nCancelado pelo usuário";
            exit 1;
        fi
        sleep 3;
        if [[ ${#i} -eq 60 ]]; then
            echo -e "\nLimite de tempo excedido, conecte-se à internet antes de executar o script";
            exit 1;
        elif ping -c 1 -W 1 8.8.8.8 > /dev/null 2>&1; then
            echo -e "\nConexão estabelecida com sucesso!";
            return 0;
        fi
    done
    return 0;
}

# ── log de instalação ─────────────────────────────────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'printf "\n[%s] === Instalação encerrada (exit: %s) ===\n" "$(date +"%F %T")" "$?"' EXIT
printf '[%s] === Instalação iniciada ===\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"

checkConnection;

# ── leitura de SO (verificação adiada — depende da versão escolhida) ──────────
os_id=$(grep '^ID=' /etc/os-release | cut -d= -f2)
os_version=$(grep '^VERSION_ID=' /etc/os-release | tr -d '"' | cut -d= -f2)

# ── leitura / retomada de checkpoint ─────────────────────────────────────────
type=""
version=""
_resuming=false

if [[ -f "$CKPT_FILE" ]] && grep -q "^TYPE=" "$CKPT_FILE" 2>/dev/null; then
    ckpt_show_status

    echo "  Uma instalação anterior foi encontrada."
    echo "  Deseja retomar de onde parou? (N = iniciar do zero)"
    echo
    if confirm "Retomar instalação?"; then
        _resuming=true
        type=$(ckpt_get TYPE)
        version=$(ckpt_get VERSION)
        info "Retomando: Axxon One $version ($type)."
        echo
    else
        info "Descartando checkpoint anterior e iniciando do zero..."
        ckpt_clear
    fi
fi

# ── menus de tipo e versão ────────────────────────────────────────────────────
choose_type() {
    local opt
    while true; do
        echo
        echo "╔════════════════════════════════════════╗"
        echo "║     AXXON ONE — Instalador Linux       ║"
        echo "╠════════════════════════════════════════╣"
        echo "║  1) Server                             ║"
        echo "║  2) Client                             ║"
        echo "║  3) Sair                               ║"
        echo "╚════════════════════════════════════════╝"
        read -rp "Escolha o tipo de instalação [1-3]: " opt
        case "$opt" in
            1) type="server"; return ;;
            2) type="client"; return ;;
            3) abort ;;
            *) echo; red "Opção inválida. Tente novamente." ;;
        esac
    done
}

choose_version() {
    local opt
    while true; do
        echo
        echo "╔════════════════════════════════════════╗"
        echo "║     AXXON ONE — Versão                 ║"
        echo "╠════════════════════════════════════════╣"
        echo "║  1) Axxon One 2.0  (build 2.0.14.79)   ║"
        echo "║  2) Axxon One 3.0  (build 3.0.0.46)    ║"
        echo "║  3) Sair                               ║"
        echo "╚════════════════════════════════════════╝"
        read -rp "Escolha a versão [1-3]: " opt
        case "$opt" in
            1) version="2.0"; return ;;
            2) version="3.0"; return ;;
            3) abort ;;
            *) echo; red "Opção inválida. Tente novamente." ;;
        esac
    done
}

if [[ "$_resuming" == false ]]; then
    while true; do
        choose_type
        confirm "Confirma instalação do tipo $(bold "$type")?" && break
    done

    while true; do
        choose_version
        confirm "Confirma versão $(bold "$version")?" && break
    done

    # Salva tipo e versão no checkpoint logo após confirmação
    mkdir -p "$INSTALL_DIR"
    ckpt_set "TYPE"    "$type"
    ckpt_set "VERSION" "$version"
fi

# ── verificação de SO por versão ──────────────────────────────────────────────
required_os="$( [[ "$version" == "2.0" ]] && echo "20.04" || echo "24.04" )"
if [[ "$os_id" != "ubuntu" || "$os_version" != "$required_os" ]]; then
    echo
    red "Sistema operacional incompatível: $os_id $os_version"
    echo "  Axxon One $version requer Ubuntu ${required_os} LTS."
    echo
    exit 1
fi

# ── URLs de download ──────────────────────────────────────────────────────────
declare -A URLS=(
    ["server_2.0"]="https://dl.axxonsoft.com/software/Axxon-One/Axxon-One/2.0.14.79/linux-amd64-server.zip"
    ["client_2.0"]="https://dl.axxonsoft.com/software/Axxon-One/Axxon-One/2.0.14.79/linux-amd64-client.zip"
    ["server_3.0"]="https://dl.axxonsoft.com/software/Axxon-One/Axxon-One/3.0.0.46/linux-amd64-server.zip"
    ["client_3.0"]="https://dl.axxonsoft.com/software/Axxon-One/Axxon-One/3.0.0.46/linux-amd64-client.zip"
)
url="${URLS[${type}_${version}]}"

mkdir -p "$INSTALL_DIR"

# ── passo: atualização do sistema e dependências ──────────────────────────────
if ckpt_is_done "apt_update"; then
    ckpt_skip "apt_update" "Atualização do sistema"
else
    echo
    info "Atualizando sistema e instalando dependências..."
    echo
    apt-get update && apt-get upgrade -y
    apt-get install -y unzip wget
    ckpt_done "apt_update" "Atualização do sistema"
fi

# ── passo: aliases e banner de login no ~/.bashrc ─────────────────────────────
if ckpt_is_done "bashrc"; then
    ckpt_skip "bashrc" "Aliases no .bashrc"
else
    _brc_user="${SUDO_USER:-$USER}"
    _brc_home=$(getent passwd "$_brc_user" | cut -d: -f6)
    if ! grep -q "SEESTEC - ENGENHARIA E TECNOLOGIA" "$_brc_home/.bashrc" 2>/dev/null; then
        cat >> "$_brc_home/.bashrc" << BASHRC

# ── SEESTEC - ENGENHARIA E TECNOLOGIA ─────────────────────────────────────────

# Axxon One — controle do serviço
alias axxon-start="sudo systemctl start axxon-one"
alias axxon-stop="sudo systemctl stop axxon-one"
alias axxon-restart="sudo systemctl restart axxon-one"
alias axxon-status="sudo systemctl status axxon-one"

# Identificação e busca de gravações
alias ask-tag="python3 \$HOME/screenREC/ask_tag.py"
alias find-rec="python3 \$HOME/screenREC/find_rec.py"

# screenREC — controle
alias screenREC-start="nohup bash \$HOME/screenREC/screenREC.sh >>/tmp/screenrec.log 2>&1 &"
alias screenREC-stop="pkill -TERM -f screenREC.sh 2>/dev/null; pkill -INT -f 'ffmpeg.*x11grab' 2>/dev/null; echo 'Encerrado.'"
alias screenREC-status="pgrep -fa ffmpeg | grep x11grab || echo 'Nenhuma gravacao ativa.'"
alias screenREC-live="tail -f /tmp/screenrec.log"

# screenREC — log de arquivamento (zip_daily)
alias screenREC-log="cat /tmp/screenrec_zip.log"
alias screenREC-show="tail -f /tmp/screenrec_zip.log"
alias screenREC-ok="grep 'Concluido' /tmp/screenrec_zip.log"
alias screenREC-error="grep 'ERRO' /tmp/screenrec_zip.log"

# screenREC — diagnóstico
alias screenREC-session="set | grep -E 'XDG_SESSION_TYPE|^DISPLAY='"
alias screenREC-monitors="xrandr --listmonitors"
alias screenREC-audio="pactl info"
alias screenREC-audio-list="pactl list short sources"
alias screenREC-audio-test="ffmpeg -f pulse -i default -t 5 /tmp/teste_audio.mp3"
alias screenREC-serial="printf 'DMI: '; cat /sys/class/dmi/id/product_serial 2>/dev/null; printf '\nmachine-id: '; head -c 12 /etc/machine-id; echo"
alias screenREC-folder="ls -la \$HOME/REC_SHARE/"
alias screenREC-autostart="cat \$HOME/.config/autostart/screenREC.desktop"
alias screenREC-cron="crontab -l 2>/dev/null | grep screenREC || echo 'Nenhum cron screenREC registrado.'"
alias screenREC-disk="df -h \$HOME/REC_SHARE"
alias screenREC-cleanup-log="cat /tmp/screenrec_cleanup.log"
alias screenREC-cleanup-show="tail -f /tmp/screenrec_cleanup.log"

# screenREC — configuração
alias screenREC-cleanup-config="bash \$HOME/screenREC/cleanup_old.sh --config"

# Samba — controle e diagnóstico
alias samba-status="systemctl status smbd nmbd"
alias samba-restart="sudo systemctl restart smbd nmbd"
alias samba-users="sudo pdbedit -L"
alias samba-passwd="sudo smbpasswd \$USER"
alias samba-test="smbclient //localhost/REC_SHARE -U \$USER"

echo "
---------- AXXON ONE ${type^^} - ${version} ----------
--------- IPV4: \$(hostname -I)
--------- HOST:
\$(hostnamectl)
\$(sudo systemctl status axxon-one)

# ── SEESTEC - ENGENHARIA E TECNOLOGIA ─────────────────────────────────────────

# Axxon One — controle do serviço
  axxon-start              # inicia o serviço Axxon One
  axxon-stop               # para o serviço Axxon One
  axxon-restart            # reinicia o serviço Axxon One
  axxon-status             # exibe status do serviço Axxon One

# Identificação e busca de gravações
  ask-tag                  # identifica câmera/tag de uma gravação
  find-rec                 # busca gravações por data e hora

# screenREC — controle
  screenREC-start          # inicia gravação de tela em segundo plano
  screenREC-stop           # encerra a gravação de tela
  screenREC-status         # mostra se há gravação ativa
  screenREC-live           # acompanha o log em tempo real

# screenREC — log de arquivamento (zip_daily)
  screenREC-log            # exibe o log de arquivamento
  screenREC-show           # acompanha o log de arquivamento em tempo real
  screenREC-ok             # filtra entradas de sucesso no log
  screenREC-error          # filtra erros no log de arquivamento

# screenREC — diagnóstico
  screenREC-session        # exibe tipo de sessão gráfica (X11/Wayland)
  screenREC-monitors       # lista monitores disponíveis
  screenREC-audio          # exibe informações do servidor de áudio
  screenREC-audio-list     # lista fontes de áudio disponíveis
  screenREC-audio-test     # grava 5s de áudio para teste
  screenREC-serial         # exibe serial DMI e machine-id
  screenREC-folder         # lista arquivos na pasta de gravações
  screenREC-autostart      # exibe configuração de autostart
  screenREC-cron           # exibe crons registrados para screenREC
  screenREC-disk           # mostra espaço em disco da pasta de gravações
  screenREC-cleanup-log    # exibe log de limpeza de gravações antigas
  screenREC-cleanup-show   # acompanha log de limpeza em tempo real

# screenREC — configuração
  screenREC-cleanup-config # define o período de retenção das gravações (.zip)

# Samba — controle e diagnóstico
  samba-status             # exibe status dos serviços Samba
  samba-restart            # reinicia os serviços Samba
  samba-users              # lista usuários Samba
  samba-passwd             # altera senha Samba do usuário atual
  samba-test               # testa conexão Samba local
"
BASHRC
    fi
    ckpt_done "bashrc" "Aliases no .bashrc"
fi

# ── passo: download do pacote Axxon ──────────────────────────────────────────
if ckpt_is_done "download_zip" && [[ -s "$ZIP_FILE" ]]; then
    ckpt_skip "download_zip" "Download do pacote Axxon"
else
    # Reinicia o passo se o arquivo sumiu após ter sido marcado como concluído
    if ckpt_is_done "download_zip" && [[ ! -s "$ZIP_FILE" ]]; then
        warn "Arquivo de download não encontrado. Baixando novamente..."
        ckpt_set "download_zip" "pending"
        ckpt_set "extract_zip"  "pending"
    fi
    echo
    info "Baixando Axxon One ${version} ${type}..."
    echo "  URL: $url"
    echo
    # wget -c retoma o download de onde parou caso o arquivo parcial exista
    wget -c --progress=bar:force:noscroll -O "$ZIP_FILE" "$url"
    [[ -s "$ZIP_FILE" ]] || { red "Download falhou ou arquivo vazio."; exit 1; }
    ckpt_done "download_zip" "Download do pacote Axxon"
fi

# ── passo: extração do pacote ─────────────────────────────────────────────────
if ckpt_is_done "extract_zip" && [[ -d "$PKG_DIR" ]]; then
    ckpt_skip "extract_zip" "Extração do pacote"
else
    echo
    info "Extraindo pacote..."
    rm -rf "$PKG_DIR"
    unzip -q "$ZIP_FILE" -d "$PKG_DIR"
    ckpt_done "extract_zip" "Extração do pacote"
fi

# ── repositório e GPG (compartilhados) ───────────────────────────────────────
setup_repo() {
    if [[ ! -f /etc/apt/sources.list.d/axxonsoft.list ]]; then
        info "Configurando repositório Axxon..."
        echo 'deb http://download.axxonsoft.com/debian-repository buster main backports/main' \
            | tee -a /etc/apt/sources.list.d/axxonsoft.list > /dev/null
        echo 'deb http://download.axxonsoft.com/debian-repository stretch backports/main' \
            | tee -a /etc/apt/sources.list.d/axxonsoft.list > /dev/null
        echo 'deb http://download.axxonsoft.com/debian-repository stable main' \
            | tee -a /etc/apt/sources.list.d/axxonsoft.list > /dev/null
    fi

    if [[ ! -f /etc/apt/trusted.gpg.d/axxonsoft.gpg ]]; then
        info "Importando chave GPG do repositório Axxon..."
        wget --quiet -O - "http://download.axxonsoft.com/debian-repository/info@axxonsoft.com.gpg.key" \
            | gpg --dearmor -o /etc/apt/trusted.gpg.d/axxonsoft.gpg
        apt-get update -q
    fi
}

# ── passo: repositório e GPG ──────────────────────────────────────────────────
if ckpt_is_done "setup_repo"; then
    ckpt_skip "setup_repo" "Repositório e chave GPG"
else
    setup_repo
    ckpt_done "setup_repo" "Repositório e chave GPG"
fi

# ── pré-download de dependências (com rede ativa, antes de disable_external_network) ──
predownload_deps() {
    local pkg_dir="$1"

    local -a all_debs
    shopt -s nullglob
    all_debs=("$pkg_dir"/*.deb)
    shopt -u nullglob

    [[ ${#all_debs[@]} -eq 0 ]] && return 0

    info "Pré-baixando dependências para instalação offline..."
    echo

    # Desempacota os .deb — vai falhar na configuração mas registra as deps no dpkg
    dpkg -i "${all_debs[@]}" 2>/dev/null || true

    # Baixa apenas as deps faltantes para o cache local sem instalar nem atualizar
    apt-get install -fy \
        --download-only \
        --no-upgrade \
        2>/dev/null || true

    # Extrai os nomes dos pacotes axxon e purga o estado parcial do dpkg
    # para que a instalação offline parta de um estado limpo
    local pkg_name
    for deb in "${all_debs[@]}"; do
        pkg_name=$(dpkg-deb --field "$deb" Package 2>/dev/null) || continue
        dpkg --purge --force-remove-reinstreq "$pkg_name" 2>/dev/null || true
    done

    grn "  Dependências em cache: /var/cache/apt/archives/"
    echo
}

# ── instalação server (apenas pacotes .deb) ───────────────────────────────────
install_server_pkgs() {
    local pkg_dir="$1"

    local -a driver_debs core_debs server_debs
    shopt -s nullglob
    driver_debs=("$pkg_dir"/axxon-d*.deb)
    core_debs=("$pkg_dir"/axxon-one-core*.deb)
    server_debs=("$pkg_dir"/axxon-one_*.deb)
    shopt -u nullglob

    if [[ ${#driver_debs[@]} -eq 0 ]]; then
        red "Pacotes axxon-d*.deb não encontrados em $pkg_dir."
        red "Verifique se o download foi concluído corretamente."
        exit 1
    fi
    if [[ ${#core_debs[@]} -eq 0 || ${#server_debs[@]} -eq 0 ]]; then
        red "Pacotes axxon-one-core ou axxon-one não encontrados em $pkg_dir."
        exit 1
    fi

    info "Instalando drivers e detectores..."
    dpkg -i "${driver_debs[@]}" || apt-get install -fy --no-upgrade

    info "Instalando Axxon One Core e Server..."
    dpkg -i "${core_debs[@]}"   || apt-get install -fy --no-upgrade
    dpkg -i "${server_debs[@]}" || apt-get install -fy --no-upgrade
}

# ── instalação client (apenas pacotes .deb + mono) ────────────────────────────
install_client_pkgs() {
    local pkg_dir="$1"

    local -a bin_debs client_debs
    shopt -s nullglob
    bin_debs=("$pkg_dir"/axxon-one-client-bin*.deb)
    client_debs=("$pkg_dir"/axxon-one-client_*.deb)
    shopt -u nullglob

    if [[ ${#bin_debs[@]} -eq 0 || ${#client_debs[@]} -eq 0 ]]; then
        red "Pacotes axxon-one-client não encontrados em $pkg_dir."
        red "Verifique se o download foi concluído corretamente."
        exit 1
    fi

    info "Preparando dependências Mono..."
    apt-get purge -y 'mono-*' 'libmono-*' 2>/dev/null || true
    apt-get autoremove -y
    apt-get install -y mono-complete -t stretch

    info "Instalando Axxon One Client (binários)..."
    dpkg -i "${bin_debs[@]}"    || apt-get install -fy --no-upgrade

    info "Instalando Axxon One Client..."
    dpkg -i "${client_debs[@]}" || apt-get install -fy --no-upgrade
}

# ── download scripts companheiros (client only) ──────────────────────────────
download_scripts() {
    local real_user="${SUDO_USER:-$USER}"
    local real_home
    real_home=$(getent passwd "$real_user" | cut -d: -f6)
    local dest="$real_home/screenREC"
    local base_url="https://raw.githubusercontent.com/SEESTEC/axxon_linux_install/main/screenREC"

    info "Baixando scripts companheiros para $dest..."
    echo

    sudo -u "$real_user" mkdir -p "$dest"

    sudo -u "$real_user" wget -c -v -O "$dest/screenREC.sh"    "$base_url/screenREC.sh"
    sudo -u "$real_user" wget -c -v -O "$dest/zip_daily.sh"    "$base_url/zip_daily.sh"
    sudo -u "$real_user" wget -c -v -O "$dest/cleanup_old.sh"  "$base_url/cleanup_old.sh"
    sudo -u "$real_user" wget -c -v -O "$dest/setup_samba.sh"  "$base_url/setup_samba.sh"
    sudo -u "$real_user" wget -c -v -O "$dest/ask_tag.py"      "$base_url/ask_tag.py"
    sudo -u "$real_user" wget -c -v -O "$dest/find_rec.py"     "$base_url/find_rec.py"

    sudo -u "$real_user" chmod +x "$dest/screenREC.sh" "$dest/zip_daily.sh" \
                                   "$dest/cleanup_old.sh" "$dest/setup_samba.sh" \
                                   "$dest/ask_tag.py" "$dest/find_rec.py"

    grn "  screenREC.sh   → $dest/screenREC.sh"
    grn "  zip_daily.sh   → $dest/zip_daily.sh"
    grn "  cleanup_old.sh → $dest/cleanup_old.sh"
    grn "  setup_samba.sh → $dest/setup_samba.sh"
    grn "  ask_tag.py     → $dest/ask_tag.py"
    grn "  find_rec.py    → $dest/find_rec.py"
    echo
}

# ── autostart do screenREC no login (client only) ────────────────────────────
setup_autostart() {
    local real_user="${SUDO_USER:-$USER}"
    local real_home
    real_home=$(getent passwd "$real_user" | cut -d: -f6)
    local script="$real_home/screenREC/screenREC.sh"
    local autostart_dir="$real_home/.config/autostart"

    info "Configurando screenREC para início automático no login..."
    echo

    sudo -u "$real_user" mkdir -p "$autostart_dir"
    sudo -u "$real_user" tee "$autostart_dir/screenREC.desktop" > /dev/null << DESKTOP
[Desktop Entry]
Type=Application
Name=screenREC — Axxon Gravação de Tela
Exec=bash -c 'nohup bash $script >> /tmp/screenrec.log 2>&1 &'
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Terminal=false
DESKTOP

    grn "  Autostart criado: $autostart_dir/screenREC.desktop"
    grn "  Log em: /tmp/screenrec.log"
    echo
}

# ── salvar senha sudo ────────────────────────────────────────────────────────
save_sudo_password() {
    local real_user="${SUDO_USER:-$USER}"
    local real_home
    real_home=$(getent passwd "$real_user" | cut -d: -f6)
    local env_file="$real_home/screenREC/.env"

    echo
    info "Configurando credencial sudo para scripts automatizados..."
    echo

    local pass1 pass2
    while true; do
        read -rsp "  Senha sudo do usuário '$real_user': " pass1
        echo
        read -rsp "  Confirme a senha: " pass2
        echo
        if [[ "$pass1" == "$pass2" ]]; then
            break
        fi
        red "  As senhas não coincidem. Tente novamente."
        echo
    done

    local val
    val=$(printf '%q' "$pass1")
    printf 'SUDO_PASS=%s\n' "$val" | sudo -u "$real_user" tee "$env_file" > /dev/null
    sudo -u "$real_user" chmod 600 "$env_file"

    grn "  Credencial salva em $env_file (600)"
    echo
}

# ── desabilitar wayland / forçar xorg (client only) ───────────────────────────
force_xorg() {
    info "Desabilitando Wayland e forçando Xorg (6 métodos)..."
    echo

    # 1. GDM3 custom.conf — WaylandEnable=false
    local gdm_conf="/etc/gdm3/custom.conf"
    mkdir -p "$(dirname "$gdm_conf")"
    if [[ ! -f "$gdm_conf" ]]; then
        printf '[daemon]\nWaylandEnable=false\n' | tee "$gdm_conf" > /dev/null
    elif grep -q 'WaylandEnable' "$gdm_conf"; then
        sed -i 's/#\?WaylandEnable=.*/WaylandEnable=false/' "$gdm_conf"
    elif grep -q '^\[daemon\]' "$gdm_conf"; then
        sed -i '/^\[daemon\]/a WaylandEnable=false' "$gdm_conf"
    else
        printf '\n[daemon]\nWaylandEnable=false\n' | tee -a "$gdm_conf" > /dev/null
    fi
    grn "  [1/6] $gdm_conf → WaylandEnable=false"

    # 2. udev rule 61-gdm.rules → /dev/null
    ln -sf /dev/null /etc/udev/rules.d/61-gdm.rules
    udevadm control --reload-rules 2>/dev/null || true
    grn "  [2/6] /etc/udev/rules.d/61-gdm.rules → /dev/null"

    # 3. AccountsService — sessão padrão do usuário = ubuntu-xorg
    local real_user="${SUDO_USER:-$USER}"
    local acct_file="/var/lib/AccountsService/users/$real_user"
    mkdir -p /var/lib/AccountsService/users
    if [[ -f "$acct_file" ]]; then
        sed -i '/^Session=/d; /^XSession=/d' "$acct_file"
        if grep -q '^\[User\]' "$acct_file"; then
            sed -i 's/^\[User\]/[User]\nSession=ubuntu-xorg\nXSession=ubuntu/' "$acct_file"
        else
            printf '\n[User]\nSession=ubuntu-xorg\nXSession=ubuntu\n' | tee -a "$acct_file" > /dev/null
        fi
    else
        printf '[User]\nSession=ubuntu-xorg\nXSession=ubuntu\n' | tee "$acct_file" > /dev/null
    fi
    grn "  [3/6] /var/lib/AccountsService/users/$real_user → Session=ubuntu-xorg"

    # 4. /etc/profile.d — variáveis de ambiente globais
    tee /etc/profile.d/99-force-xorg.sh > /dev/null << 'ENVEOF'
export WAYLAND_DISPLAY=""
export GDK_BACKEND=x11
export QT_QPA_PLATFORM=xcb
export XDG_SESSION_TYPE=x11
export DISPLAY="${DISPLAY:-:0}"
ENVEOF
    chmod 644 /etc/profile.d/99-force-xorg.sh
    grn "  [4/6] /etc/profile.d/99-force-xorg.sh → GDK_BACKEND=x11 / QT_QPA_PLATFORM=xcb"

    # 5. Systemd override — injeta variáveis no gdm.service
    mkdir -p /etc/systemd/system/gdm.service.d
    tee /etc/systemd/system/gdm.service.d/disable-wayland.conf > /dev/null << 'SVCEOF'
[Service]
Environment=WAYLAND_DISPLAY=
Environment=XDG_SESSION_TYPE=x11
SVCEOF
    systemctl daemon-reload 2>/dev/null || true
    grn "  [5/6] systemd override gdm.service → WAYLAND_DISPLAY= / XDG_SESSION_TYPE=x11"

    # 6. ~/.xsessionrc — sessão gráfica explícita no nível do usuário
    local real_home
    real_home=$(getent passwd "$real_user" | cut -d: -f6)
    printf 'DESKTOP_SESSION=ubuntu-xorg\nexport XDG_SESSION_TYPE=x11\nexport GDK_BACKEND=x11\n' \
        | sudo -u "$real_user" tee "$real_home/.xsessionrc" > /dev/null
    grn "  [6/6] $real_home/.xsessionrc → DESKTOP_SESSION=ubuntu-xorg"

    echo
    info "Wayland desabilitado por 6 métodos independentes."
    info "REINICIE O SISTEMA para iniciar em sessão Xorg."
    echo
}

# Estado salvo por disable_external_network para uso posterior pelo enable
_disabled_iface=""
_disabled_conn=""
_disabled_gw=""

# ── desabilitar rede externa (DHCP) ──────────────────────────────────────────
disable_external_network() {
    info "Removendo conexão de rede externa (DHCP)..."
    echo

    local ext_iface
    ext_iface=$(ip route get 8.8.8.8 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')

    if [[ -z "$ext_iface" ]]; then
        info "  Nenhuma rota de internet detectada. Nada a desabilitar."
        return 0
    fi

    # Captura o gateway ANTES de remover a rota (necessário para restauração)
    local gw
    gw=$(ip route get 8.8.8.8 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}')

    _disabled_iface="$ext_iface"
    _disabled_gw="$gw"

    # Remove a rota default imediatamente — antes que o NM possa reagir
    sudo ip route del default 2>/dev/null || true

    # Tenta desabilitar via nmcli se disponível
    if command -v nmcli &>/dev/null; then
        local nm_conn
        nm_conn=$(nmcli -t -f NAME,DEVICE connection show --active \
            | awk -F: -v iface="$ext_iface" '$2==iface {print $1; exit}')

        if [[ -n "$nm_conn" ]]; then
            _disabled_conn="$nm_conn"
            sudo nmcli device set "$ext_iface" managed no 2>/dev/null || true
            sudo nmcli connection modify "$nm_conn" connection.autoconnect no 2>/dev/null || true
            sudo nmcli connection down "$nm_conn" 2>/dev/null || true
        else
            warn "  Interface $ext_iface não gerenciada pelo NetworkManager."
        fi
    else
        warn "  nmcli não encontrado. Rota removida via ip route."
    fi

    # Verifica se a rede externa foi de fato desabilitada
    local i=1
    while ping -c 1 -W 1 8.8.8.8 &>/dev/null; do
        echo -ne "\r\033[K  Rede externa ainda ativa. Desconecte manualmente e aguarde. \e[1;90mPressione \"x\" para encerrar\e[0m [tentativa: $i]"
        ((i++))
        read -t 2 -n 1 key
        if [[ "${key:-}" == 'x' ]]; then
            echo
            red "  Encerrado pelo usuário."
            exit 1
        fi
    done
    echo

    grn "  Interface $ext_iface → desconectada"
    echo
}

# ── habilitar rede externa ────────────────────────────────────────────────────
enable_external_network() {
    if [[ -z "$_disabled_iface" ]]; then
        warn "  Nenhuma interface foi desabilitada nesta sessão. Nada a restaurar."
        return 0
    fi

    info "Restaurando conexão de rede externa ('${_disabled_conn:-$_disabled_iface}')..."
    echo

    if command -v nmcli &>/dev/null && [[ -n "$_disabled_conn" ]]; then
        # Reabilita reconexão automática e devolve o device ao NM
        sudo nmcli connection modify "$_disabled_conn" connection.autoconnect yes 2>/dev/null || true
        sudo nmcli device set "$_disabled_iface" managed yes 2>/dev/null || true

        if ! sudo nmcli connection up "$_disabled_conn" 2>/dev/null; then
            warn "  nmcli não ativou '$_disabled_conn'. Tentando restauração manual..."
            sudo ip link set "$_disabled_iface" up 2>/dev/null || true
            [[ -n "$_disabled_gw" ]] && sudo ip route add default via "$_disabled_gw" dev "$_disabled_iface" 2>/dev/null || true
        fi
    else
        # Restauração manual sem nmcli
        sudo ip link set "$_disabled_iface" up 2>/dev/null || true
        [[ -n "$_disabled_gw" ]] && sudo ip route add default via "$_disabled_gw" dev "$_disabled_iface" 2>/dev/null || true
    fi

    # Verifica se a rede externa foi de fato restaurada
    local i=1
    while ! ping -c 1 -W 1 8.8.8.8 &>/dev/null; do
        echo -ne "\r\033[K  Rede externa ainda inativa. Conecte manualmente e aguarde. \e[1;90mPressione \"x\" para encerrar\e[0m [tentativa: $i]"
        ((i++))
        read -t 2 -n 1 key
        if [[ "${key:-}" == 'x' ]]; then
            echo
            red "  Encerrado pelo usuário."
            exit 1
        fi
    done
    echo

    grn "  Conectividade com a rede externa confirmada."
    echo

    # Limpa estado
    _disabled_iface=""
    _disabled_conn=""
    _disabled_gw=""
}

# ── passo: instalação dos pacotes .deb ───────────────────────────────────────
if ckpt_is_done "install_pkgs"; then
    ckpt_skip "install_pkgs" "Instalação dos pacotes .deb"
else
    # Fase 1 — pré-download de deps com rede ativa (antes de desligar)
    if [[ "$type" == "server" ]]; then
        predownload_deps "$PKG_DIR"
    elif [[ "$type" == "client" ]]; then
        predownload_deps "$PKG_DIR"
    fi
    # Fase 2 — instalação offline: deps já estão em /var/cache/apt/archives/
    disable_external_network
    if [[ "$type" == "server" ]]; then
        install_server_pkgs "$PKG_DIR"
    elif [[ "$type" == "client" ]]; then
        install_client_pkgs "$PKG_DIR"
    fi
    enable_external_network
    ckpt_done "install_pkgs" "Instalação dos pacotes .deb"
fi

# ── passos exclusivos do client ───────────────────────────────────────────────
if [[ "$type" == "client" ]]; then

    if ckpt_is_done "download_scripts"; then
        ckpt_skip "download_scripts" "Scripts screenREC"
    else
        download_scripts
        ckpt_done "download_scripts" "Scripts screenREC"
    fi

    if ckpt_is_done "cleanup_config"; then
        ckpt_skip "cleanup_config" "Retenção de gravações"
    else
        real_user="${SUDO_USER:-$USER}"
        real_home=$(getent passwd "$real_user" | cut -d: -f6)
        info "Configurando período de retenção das gravações..."
        sudo -u "$real_user" bash "$real_home/screenREC/cleanup_old.sh" --config
        ckpt_done "cleanup_config" "Retenção de gravações"
    fi

    if ckpt_is_done "setup_autostart"; then
        ckpt_skip "setup_autostart" "Autostart screenREC"
    else
        setup_autostart
        ckpt_done "setup_autostart" "Autostart screenREC"
    fi

    if ckpt_is_done "setup_samba"; then
        ckpt_skip "setup_samba" "Servidor Samba"
    else
        real_user="${SUDO_USER:-$USER}"
        real_home=$(getent passwd "$real_user" | cut -d: -f6)
        bash "$real_home/screenREC/setup_samba.sh"
        ckpt_done "setup_samba" "Servidor Samba"
    fi

    if ckpt_is_done "save_sudo_pass"; then
        ckpt_skip "save_sudo_pass" "Credencial sudo"
    else
        save_sudo_password
        ckpt_done "save_sudo_pass" "Credencial sudo"
    fi

    if ckpt_is_done "force_xorg"; then
        ckpt_skip "force_xorg" "Desabilitar Wayland"
    else
        force_xorg
        ckpt_done "force_xorg" "Desabilitar Wayland"
    fi

fi

# ── passo: desabilitar rede externa ───────────────────────────────────────────
if ckpt_is_done "disable_network"; then
    ckpt_skip "disable_network" "Desabilitar rede externa"
else
    disable_external_network
    ckpt_done "disable_network" "Desabilitar rede externa"
fi

# ── conclusão ─────────────────────────────────────────────────────────────────
echo
grn "Axxon One ${version} ${type^^} instalado com sucesso!"
echo

# Remove checkpoint e diretório temporário após instalação bem-sucedida
ckpt_clear

info "Log completo salvo em: $LOG_FILE"
echo

for ((t = 10 ; t > 0 ; t--)); do
    s=$([[ $t -gt 1 ]] && echo 's' || echo '')
    echo -ne "\r\033[KO sistema será reiniciado em $t segundo$s para aplicação das configurações\e[0m"
    sleep 1
done
echo

reboot
