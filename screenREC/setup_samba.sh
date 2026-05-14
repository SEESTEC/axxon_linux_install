#!/bin/bash

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

red()  { printf '\033[0;31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
info() { printf '\033[0;36m%s\033[0m\n' "$*"; }

# Script roda como root (via sudo bash); SUDO_USER aponta para o usuário real
real_user="${SUDO_USER:-$USER}"
real_home=$(getent passwd "$real_user" | cut -d: -f6)
hostname_short=$(hostname -s)

echo
info "Instalando e configurando servidor Samba (compartilhamento REC_SHARE)..."
echo

# ── 1. instalar pacotes ───────────────────────────────────────────────────────
info "Instalando pacotes Samba e zenity..."
apt-get install -y samba samba-common-bin zenity || \
    apt-get install -y samba samba-common-bin
grn "  Pacotes instalados."

# ── 2. selecionar disco para REC_SHARE ───────────────────────────────────────
#
# Lê discos reais montados (exclui loop, boot, proc, sys, snap, tmpfs).
# Com 1 disco: usa-o direto sem dialog.
# Com múltiplos: abre radiolist zenity; fallback para menu numerado no terminal.
#
choose_disk() {
    local -a mp_list=() dev_list=() size_list=() avail_list=()

    while IFS=" " read -r mp dev size avail; do
        # excluir pontos de sistema / snaps / loop
        [[ "$mp" =~ ^(/boot|/proc|/sys|/run|/dev|/snap|/var/snap|/tmp) ]] && continue
        mp_list+=("$mp")
        dev_list+=("$dev")
        size_list+=("$size")
        avail_list+=("$avail")
    done < <(
        df -h 2>/dev/null \
            | grep '^/dev/' \
            | grep -v '^/dev/loop' \
            | awk '{print $6, $1, $2, $4}' \
            | sort
    )

    # Nenhum disco detectado → home
    if [[ ${#mp_list[@]} -eq 0 ]]; then
        echo "$real_home"
        return 0
    fi

    # Único disco → sem dialog
    if [[ ${#mp_list[@]} -eq 1 ]]; then
        grn "  Disco detectado: ${mp_list[0]}  [${dev_list[0]}  livre: ${avail_list[0]}]"
        echo "${mp_list[0]}"
        return 0
    fi

    # Múltiplos discos ─────────────────────────────────────────────────────────
    info "  ${#mp_list[@]} discos detectados. Aguardando seleção..."
    echo

    # Montar args para zenity --radiolist
    local -a zargs=()
    local first=true
    for idx in "${!mp_list[@]}"; do
        local radio="FALSE"
        [[ "$first" == "true" ]] && { radio="TRUE"; first=false; }
        zargs+=("$radio" "${mp_list[$idx]}" "${dev_list[$idx]}" "${size_list[$idx]}" "${avail_list[$idx]}")
    done

    # Tentar zenity (precisa de sessão gráfica ativa)
    if command -v zenity &>/dev/null && [[ -n "${DISPLAY:-}" ]]; then
        local chosen
        chosen=$(sudo -u "$real_user" \
            env DISPLAY="${DISPLAY}" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$real_user")/bus" \
            zenity --list \
                --radiolist \
                --print-column=2 \
                --title="Axxon One — Disco para REC_SHARE" \
                --text="Selecione o disco onde as gravações serão armazenadas:" \
                --column="" \
                --column="Ponto de montagem" \
                --column="Dispositivo" \
                --column="Tamanho" \
                --column="Disponível" \
                --width=660 \
                --height=360 \
                "${zargs[@]}" 2>/dev/null) || true

        if [[ -n "$chosen" ]]; then
            echo "$chosen"
            return 0
        fi
        # Usuário cancelou → fallback terminal
        info "  Seleção cancelada. Usando menu no terminal."
        echo
    fi

    # Fallback: menu numerado no terminal
    info "Discos disponíveis:"
    for idx in "${!mp_list[@]}"; do
        printf "  %d) %-20s  %s  total: %s  livre: %s\n" \
            "$((idx+1))" "${mp_list[$idx]}" "${dev_list[$idx]}" \
            "${size_list[$idx]}" "${avail_list[$idx]}"
    done
    echo
    local choice
    read -rp "  Número do disco [1]: " choice
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#mp_list[@]} )); then
        echo "${mp_list[$((choice-1))]}"
    else
        echo "${mp_list[0]}"
    fi
}

chosen_mp=$(choose_disk)

# Determinar share_dir: para / e /home usa o home do usuário; demais → raiz do disco
if [[ "$chosen_mp" == "/" || "$chosen_mp" == "/home" || "$chosen_mp" == "/home/$real_user" ]]; then
    share_dir="$real_home/REC_SHARE"
else
    share_dir="${chosen_mp}/REC_SHARE"
fi

grn "  Caminho escolhido para REC_SHARE: $share_dir"
echo

# ── 3. criar diretório e ajustar permissões ───────────────────────────────────
mkdir -p "$share_dir"
chown "${real_user}:${real_user}" "$share_dir"
chmod 755 "$share_dir"
grn "  Diretório criado: $share_dir"

# ── 4. backup do smb.conf ─────────────────────────────────────────────────────
if [[ ! -f /etc/samba/smb.conf.bak ]]; then
    cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
    grn "  Backup criado: /etc/samba/smb.conf.bak"
fi

# ── 5. adicionar / atualizar seção [REC_SHARE] ───────────────────────────────
if grep -q '^\[REC_SHARE\]' /etc/samba/smb.conf; then
    # Atualiza somente o path dentro da seção [REC_SHARE] via awk
    awk -v newpath="   path = ${share_dir}" '
        /^\[REC_SHARE\]/          { in_s=1 }
        /^\[/ && !/^\[REC_SHARE\]/ { in_s=0 }
        in_s && /^[[:space:]]*path[[:space:]]*=/ { print newpath; next }
        { print }
    ' /etc/samba/smb.conf > /tmp/_smb.conf && mv /tmp/_smb.conf /etc/samba/smb.conf
    grn "  Seção [REC_SHARE] atualizada com novo caminho."
else
    tee -a /etc/samba/smb.conf > /dev/null << EOF

[REC_SHARE]
   comment = Gravações Axxon One — ${real_user}
   path = ${share_dir}
   browseable = yes
   read only = no
   guest ok = no
   valid users = ${real_user}
   create mask = 0664
   directory mask = 0775
   force user = ${real_user}
EOF
    grn "  Seção [REC_SHARE] adicionada ao /etc/samba/smb.conf"
fi

# ── 6. coletar senha Samba (aplicada depois que smbd inicializar) ─────────────
echo
info "Defina a senha Samba para o usuário '${real_user}':"
info "(usada para acessar \\\\${hostname_short}\\REC_SHARE na rede local)"
echo

samba_pass1=""
samba_pass2=""
while true; do
    read -rsp "  Senha Samba: " samba_pass1
    echo
    read -rsp "  Confirme a senha: " samba_pass2
    echo
    if [[ "$samba_pass1" == "$samba_pass2" ]]; then
        break
    fi
    red "  As senhas não coincidem. Tente novamente."
    echo
done

# ── 7. firewall ───────────────────────────────────────────────────────────────
if ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow samba
    grn "  ufw: regra Samba adicionada"
fi

# ── 8. validar smb.conf antes de reiniciar ────────────────────────────────────
info "Validando smb.conf..."
if ! testparm -s /etc/samba/smb.conf > /dev/null 2>&1; then
    red "ERRO: smb.conf com sintaxe inválida. Restaurando backup..."
    [[ -f /etc/samba/smb.conf.bak ]] && cp /etc/samba/smb.conf.bak /etc/samba/smb.conf
    testparm -s /etc/samba/smb.conf 2>&1 | head -20
    exit 1
fi
grn "  smb.conf validado."

# ── 9. habilitar e iniciar serviços ───────────────────────────────────────────
info "Habilitando e iniciando smbd e nmbd..."
systemctl enable smbd
systemctl enable nmbd
systemctl restart smbd
systemctl restart nmbd

# Verificar se os serviços subiram de fato
sleep 2
for svc in smbd nmbd; do
    if ! systemctl is-active --quiet "$svc"; then
        red "ERRO: serviço $svc não iniciou."
        systemctl status "$svc" --no-pager -l >&2 || true
        exit 1
    fi
done
grn "  Serviços smbd e nmbd habilitados e ativos."

# ── 10. registrar senha Samba após serviço inicializado ──────────────────────
info "Registrando usuário '${real_user}' no banco Samba..."
printf '%s\n%s\n' "$samba_pass1" "$samba_pass1" | smbpasswd -s -a "$real_user"
grn "  Senha Samba confirmada para '${real_user}'"

echo
grn "Samba configurado com sucesso!"
echo "  Acesso na rede: \\\\${hostname_short}\\REC_SHARE"
echo "  Usuário:        ${real_user}"
echo "  Diretório:      ${share_dir}"
echo
