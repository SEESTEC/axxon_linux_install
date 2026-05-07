#!/bin/bash

set -euo pipefail

# ── formatação ────────────────────────────────────────────────────────────────
bold() { printf '\033[1m%s\033[0m' "$*"; }
red()  { printf '\033[0;31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
info() { printf '\033[0;36m%s\033[0m\n' "$*"; }

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

# ── verificação de SO ─────────────────────────────────────────────────────────
os_id=$(grep '^ID=' /etc/os-release | cut -d= -f2)
os_version=$(grep '^VERSION_ID=' /etc/os-release | tr -d '"' | cut -d= -f2)

if [[ "$os_id" != "ubuntu" || "$os_version" != "24.04" ]]; then
    echo
    red "Sistema operacional incompatível: $os_id $os_version"
    echo "  Este script requer Ubuntu 24.04 LTS."
    echo
    exit 1
fi

# ── menu tipo ─────────────────────────────────────────────────────────────────
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

# ── menu versão ───────────────────────────────────────────────────────────────
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

# ── seleção ───────────────────────────────────────────────────────────────────
type=""
version=""

while true; do
    choose_type
    confirm "Confirma instalação do tipo $(bold "$type")?" && break
done

while true; do
    choose_version
    confirm "Confirma versão $(bold "$version")?" && break
done

# ── URLs de download ──────────────────────────────────────────────────────────
declare -A URLS=(
    ["server_2.0"]="https://dl.axxonsoft.com/software/Axxon-One/Axxon-One/2.0.14.79/linux-amd64-server.zip"
    ["client_2.0"]="https://dl.axxonsoft.com/software/Axxon-One/Axxon-One/2.0.14.79/linux-amd64-client.zip"
    ["server_3.0"]="https://dl.axxonsoft.com/software/Axxon-One/Axxon-One/3.0.0.46/linux-amd64-server.zip"
    ["client_3.0"]="https://dl.axxonsoft.com/software/Axxon-One/Axxon-One/3.0.0.46/linux-amd64-client.zip"
)
url="${URLS[${type}_${version}]}"

# ── atualização e dependências ────────────────────────────────────────────────
echo
info "Atualizando sistema e instalando dependências..."
echo
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl unzip wget

# ── aliases e banner de login no ~/.bashrc ────────────────────────────────────
if ! grep -q "SEESTEC - ENGENHARIA E TECNOLOGIA" ~/.bashrc; then
    cat >> ~/.bashrc << BASHRC

# SEESTEC - ENGENHARIA E TECNOLOGIA
alias axxon-start="sudo systemctl start axxon-one"
alias axxon-stop="sudo systemctl stop axxon-one"
alias axxon-restart="sudo systemctl restart axxon-one"
alias axxon-status="sudo systemctl status axxon-one"

echo "
---------- AXXON ONE ${type^^} - ${version} ----------
--------- IPV4: \$(hostname -I)
--------- HOST:
\$(hostnamectl)
"
BASHRC
fi

# ── download ──────────────────────────────────────────────────────────────────
echo
info "Baixando Axxon One ${version} ${type}..."
echo "  URL: $url"
echo

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

zip_file="$tmp_dir/axxon-one.zip"
curl -L --progress-bar -o "$zip_file" "$url"

# ── extração ──────────────────────────────────────────────────────────────────
echo
info "Extraindo pacote..."
unzip -q "$zip_file" -d "$tmp_dir/axxon"

# ── repositório e GPG compartilhados ──────────────────────────────────────────
setup_repo() {
    if [[ ! -f /etc/apt/sources.list.d/axxonsoft.list ]]; then
        info "Configurando repositório Axxon..."
        echo 'deb http://download.axxonsoft.com/debian-repository buster main backports/main' \
            | sudo tee -a /etc/apt/sources.list.d/axxonsoft.list > /dev/null
        echo 'deb http://download.axxonsoft.com/debian-repository stretch backports/main' \
            | sudo tee -a /etc/apt/sources.list.d/axxonsoft.list > /dev/null
        echo 'deb http://download.axxonsoft.com/debian-repository stable main' \
            | sudo tee -a /etc/apt/sources.list.d/axxonsoft.list > /dev/null
    fi

    if [[ ! -f /etc/apt/trusted.gpg.d/axxonsoft.gpg ]]; then
        info "Importando chave GPG do repositório Axxon..."
        wget --quiet -O - "http://download.axxonsoft.com/debian-repository/info@axxonsoft.com.gpg.key" \
            | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/axxonsoft.gpg
        sudo apt-get update -q
    fi
}

# ── instalação server ─────────────────────────────────────────────────────────
install_server() {
    local pkg_dir="$1"

    setup_repo

    # Expandir globs com nullglob para evitar passagem de literal quando não há .deb
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

    # 1ª passagem: drivers-pack e detector-pack
    info "Instalando drivers e detectores..."
    sudo dpkg -i "${driver_debs[@]}" || sudo apt-get install -fy

    # 2ª passagem: core depois server (dependência explícita entre eles)
    info "Instalando Axxon One Core e Server..."
    sudo dpkg -i "${core_debs[@]}"   || sudo apt-get install -fy
    sudo dpkg -i "${server_debs[@]}" || sudo apt-get install -fy
}

# ── instalação client ─────────────────────────────────────────────────────────
install_client() {
    local pkg_dir="$1"

    setup_repo

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

    # Mono: remover versão do sistema e instalar do repositório Axxon (stretch)
    info "Preparando dependências Mono..."
    sudo apt-get purge -y 'mono-*' 'libmono-*' 2>/dev/null || true
    sudo apt-get autoremove -y
    sudo apt-get install -y mono-complete -t stretch

    # 1ª passagem: binários do client
    info "Instalando Axxon One Client (binários)..."
    sudo dpkg -i "${bin_debs[@]}"    || sudo apt-get install -fy

    # 2ª passagem: pacote principal do client
    info "Instalando Axxon One Client..."
    sudo dpkg -i "${client_debs[@]}" || sudo apt-get install -fy
}

# ── despacho ──────────────────────────────────────────────────────────────────
if [[ "$type" == "server" ]]; then
    install_server "$tmp_dir/axxon"
elif [[ "$type" == "client" ]]; then
    install_client "$tmp_dir/axxon"
fi

# ── conclusão ─────────────────────────────────────────────────────────────────
echo
grn "Axxon One ${version} ${type^^} instalado com sucesso!"
echo "  Reinicie o terminal para ativar os aliases (axxon-start, axxon-stop...)."
echo
