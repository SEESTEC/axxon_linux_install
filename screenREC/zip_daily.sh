#!/bin/bash
set -uo pipefail

# Executado pelo cron às 06:00 — zipa a pasta de gravações do dia anterior
# e a remove, deixando apenas o .zip em /home/$USER/REC_SHARE
#
# ══════════════════════════════════════════════════════════════════════════════
# CONFIGURAÇÃO DO CRON — LEIA ANTES DE USAR
# ══════════════════════════════════════════════════════════════════════════════
#
# 1. PERMISSÕES
#    O script deve ser executável pelo usuário que roda o cron:
#      chmod +x /caminho/para/zip_daily.sh
#    As gravações em ~/REC_SHARE devem pertencer ao mesmo usuário:
#      ls -la ~/REC_SHARE/
#
# 2. INSTALAÇÃO AUTOMÁTICA (via screenREC.sh)
#    O screenREC.sh instala a entrada no cron automaticamente na 1ª execução.
#    Para verificar se foi registrado:
#      crontab -l | grep zip_daily
#
# 3. INSTALAÇÃO MANUAL
#    Execute: crontab -e
#    Adicione (ajuste o caminho absoluto):
#      0 6 * * * /caminho/absoluto/para/zip_daily.sh >> /tmp/screenrec_zip.log 2>&1
#
#    IMPORTANTE: use sempre o caminho ABSOLUTO — o cron não conhece $PATH do usuário.
#
# 4. AMBIENTE DO CRON
#    O cron executa com ambiente mínimo. $HOME, $USER e $DISPLAY podem não estar
#    definidos conforme o esperado. Este script resolve o diretório home via
#    `getent passwd $(id -u)` (baseado no UID), evitando dependência de $HOME/$USER.
#
# 5. LOG
#    Toda saída vai para /tmp/screenrec_zip.log. Para acompanhar:
#      cat /tmp/screenrec_zip.log        # histórico completo
#      tail -f /tmp/screenrec_zip.log    # monitoramento em tempo real
#
# 6. POSSÍVEIS PROBLEMAS E SOLUÇÕES
#
#    "zip: command not found"
#      → O script instala zip automaticamente via sudo apt-get.
#        Se falhar, instale manualmente: sudo apt-get install -y zip
#
#    "Nenhuma pasta encontrada para YYYY-MM-DD"
#      → Confirme que screenREC.sh rodou no dia anterior.
#        Verifique o serial number usado:
#          cat /sys/class/dmi/id/product_serial
#          head -c 12 /etc/machine-id   (fallback)
#        Liste as pastas existentes:
#          ls ~/REC_SHARE/
#
#    Cron não executa / silencioso
#      → Verifique se o serviço cron está ativo:
#          systemctl status cron
#      → Liste as entradas registradas:
#          crontab -l
#      → Teste a execução manual para verificar erros:
#          bash /caminho/para/zip_daily.sh
#
#    "Permission denied" ao zipar ou remover
#      → As pastas devem pertencer ao usuário do crontab.
#          chown -R $USER:$USER ~/REC_SHARE/
#
#    zip incompleto (arquivo corrompido)
#      → A pasta NÃO é removida se o zip falhar (proteção implementada).
#        Verifique espaço em disco: df -h ~/REC_SHARE
#
# 7. VERIFICAR EXECUÇÃO BEM-SUCEDIDA
#      grep "Concluído" /tmp/screenrec_zip.log
#
# ══════════════════════════════════════════════════════════════════════════════

# ── serial number (mesma lógica do screenREC.sh) ──────────────────────────────
SERIAL=$(cat /sys/class/dmi/id/product_serial 2>/dev/null | tr -d ' \n')
if [[ -z "$SERIAL" || "$SERIAL" == "None" || "$SERIAL" == "ToBeFilledByO.E.M." ]]; then
    SERIAL=$(head -c 12 /etc/machine-id)
fi

# Resolve o home via UID — $HOME e $USER não são confiáveis no contexto do cron
HOME_DIR=$(getent passwd "$(id -u)" | cut -d: -f6)
REC_BASE="${HOME_DIR}/REC_SHARE"
YESTERDAY=$(date -d yesterday '+%Y-%m-%d')

if ! command -v zip > /dev/null 2>&1; then
    sudo apt-get install -y zip > /dev/null 2>&1
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
done < <(find "$REC_BASE" -maxdepth 1 -name "${SERIAL}_${YESTERDAY}*" -type d 2>/dev/null | sort)

if [[ $found -eq 0 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Nenhuma pasta de ${YESTERDAY} encontrada em $REC_BASE"
fi
