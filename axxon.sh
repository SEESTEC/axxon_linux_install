#!/usr/bin/env bash
#
# Axxon One — comandos de terminal (SEESTEC)
# Instalado como /usr/local/bin/axxon pelo install.sh e pelo webpanel.sh.
#
# Uso: axxon [--help]
#
# Lista os comandos de terminal do Axxon One instalados nesta máquina (Server,
# Client, painel web e instalador), com versão e estado de cada parte.

set -uo pipefail

readonly AXXON_HELP_VERSION="1.0.0"
readonly REPO_RAW="https://raw.githubusercontent.com/SEESTEC/axxon_linux_install/main"

if [[ -t 1 ]]; then
    B=$'\033[1m' D=$'\033[2m' G=$'\033[0;32m' Y=$'\033[0;33m' R=$'\033[0;31m' C=$'\033[0;36m' N=$'\033[0m'
else
    B="" D="" G="" Y="" R="" C="" N=""
fi

installed() { [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" == installed ]]; }
version()   { dpkg-query -W -f='${Version}' "$1" 2>/dev/null; }
title()     { printf '\n%s%s%s %s\n' "$B" "$1" "$N" "${2:-}"; }
cmd()       { printf '  %s%-46s%s %s\n' "$C" "$1" "$N" "$2"; }
note()      { printf '  %s%s%s\n' "$D" "$1" "$N"; }
state() {
    case "$1" in
        active) printf '%sativo%s' "$G" "$N" ;;
        inactive|failed) printf '%s%s%s' "$R" "$1" "$N" ;;
        *) printf '%s%s%s' "$Y" "${1:-?}" "$N" ;;
    esac
}

usage_short() {
    cat <<EOF
Uso: axxon [--help]

Lista os comandos de terminal do Axxon One nesta máquina.
  -h, --help, help   esta lista (padrão)
  -v, --version      versão desta ajuda
EOF
}

show() {
    printf '%sAxxon One — comandos de terminal%s %s(axxon --help · v%s)%s\n' "$B" "$N" "$D" "$AXXON_HELP_VERSION" "$N"

    # ── Server ────────────────────────────────────────────────────────────────
    if installed axxon-one; then
        title "Server" "$(version axxon-one) — serviço $(state "$(systemctl is-active axxon-one 2>/dev/null)")"
        cmd "sudo systemctl status axxon-one"        "estado do serviço"
        cmd "sudo systemctl restart axxon-one"       "reinicia o Server"
        cmd "sudo systemctl stop|start axxon-one"    "para / inicia"
        cmd "sudo journalctl -u axxon-one -n 100"    "últimas linhas do log do serviço"
        cmd "sudo dpkg-reconfigure axxon-one"        "domínio, portas e logs"
        note "Logs: /opt/AxxonSoft/AxxonOne/Logs   ·   Web Client: http://localhost:8000"
    else
        title "Server" "${D}(não instalado — sudo bash install.sh --server)${N}"
    fi

    # ── Client ────────────────────────────────────────────────────────────────
    if installed axxon-one-client; then
        title "Client" "$(version axxon-one-client)"
        cmd "AxxonOne"                                "abre o Client (como usuário comum, não root)"
        cmd "sudo dpkg-reconfigure axxon-one-client"  "logs do Client"
        cmd "sudo bash install.sh --client --language CULT" "idioma padrão (pt-BR, en, es...)"
        note "Logs: ~/.local/share/AxxonSoft/AxxonOne/Logs   ·   o Client deve ter a versão do Server"
    else
        title "Client" "${D}(não instalado — sudo bash install.sh --client)${N}"
    fi

    # ── Painel web ────────────────────────────────────────────────────────────
    if [[ -x /usr/local/bin/axxon-webpanel && -f /etc/axxon-webpanel/webpanel.conf ]]; then
        local url
        # o arquivo é gravado com escapes de shell (printf %q): lido pelo próprio shell
        # shellcheck source=/dev/null
        url=$( (. /etc/axxon-webpanel/webpanel.conf 2>/dev/null; printf '%s' "${URL:-}") )
        title "Painel web" "— $(state "$(systemctl is-active axxon-webpanel 2>/dev/null)")${url:+ — ${D}$url${N}}"
        cmd "axxon-web  |  axxon-dashboard"          "troca a página (pergunta e testa a URL)"
        cmd "axxon-webpanel url URL"                  "troca a página direto"
        cmd "axxon-webpanel status"                   "serviços, vídeo e câmera"
        cmd "axxon-webpanel restart"                  "recarrega a página"
        cmd "axxon-webpanel logs"                     "log dos serviços"
        cmd "sudo axxon-webpanel remove"              "remove o painel"
        note "Ajustes: /etc/axxon-webpanel/webpanel.conf   ·   sem senha para o grupo axxonweb"
    else
        title "Painel web" "${D}(não instalado — sudo bash webpanel.sh, com o Server instalado)${N}"
    fi

    # ── Instalador ────────────────────────────────────────────────────────────
    title "Instalador" "${D}(github.com/SEESTEC/axxon_linux_install)${N}"
    cmd "wget $REPO_RAW/install.sh" ""
    cmd "sudo bash install.sh --help"             "todas as opções"
    cmd "sudo bash install.sh --server|--client"  "instala / revalida"
    cmd "sudo bash install.sh --version VER"      "troca a versão (Server e Client juntos)"
    cmd "sudo bash install.sh --webpanel-url URL" "Server com painel web"
    cmd "sudo bash install.sh --reset|--remove"   "refaz do zero / remove tudo"
    cmd "sudo bash webpanel.sh --help"            "painel web à parte"
    note "Log: /var/log/axxon-install.log   ·   checkpoint: /var/lib/axxon-install/state"

    # ── Aliases do usuário (só os nomes: definições podem conter senhas) ─────
    local names
    names=$(grep -hoE "^[[:space:]]*alias[[:space:]]+axxon[A-Za-z0-9_.-]*=" "$HOME/.bashrc" "$HOME/.bash_aliases" 2>/dev/null |
        sed -E 's/^[[:space:]]*alias[[:space:]]+//; s/=$//' | sort -u | xargs)
    if [[ -n "$names" ]]; then
        title "Seus aliases" "${D}(~/.bashrc)${N}"
        printf '  %s%s%s\n' "$C" "${names// /, }" "$N"
    fi
    echo
}

case "${1:-}" in
    ""|-h|--help|help) show ;;
    -v|--version)      echo "axxon $AXXON_HELP_VERSION" ;;
    *)                 usage_short >&2; printf '\nOpção desconhecida: %s\n' "$1" >&2; exit 1 ;;
esac
