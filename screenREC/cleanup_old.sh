#!/bin/bash
set -uo pipefail

# cleanup_old.sh — Remove arquivos .zip de gravação com mais de 45 dias
# Executado automaticamente pelo cron às 05:00 (horário do host).
# Registrado automaticamente pelo screenREC.sh na 1ª execução.
#
# ══════════════════════════════════════════════════════════════════════════════
# CONFIGURAÇÃO DO CRON — REFERÊNCIA
# ══════════════════════════════════════════════════════════════════════════════
#
# Entrada criada pelo screenREC.sh:
#   0 5 * * * /caminho/para/cleanup_old.sh >> /tmp/screenrec_cleanup.log 2>&1
#
# Verificar se foi registrado:
#   crontab -l | grep cleanup_old
#
# Testar manualmente:
#   bash ~/screenREC/cleanup_old.sh
#
# LOG:
#   cat /tmp/screenrec_cleanup.log
#   tail -f /tmp/screenrec_cleanup.log
#   grep "ALERTA\|Removido\|ERRO" /tmp/screenrec_cleanup.log
#
# ══════════════════════════════════════════════════════════════════════════════

MAX_DAYS=45      # dias de retenção dos arquivos .zip
WARN_USAGE=85    # % de uso do disco que aciona alerta no log
LOG="/tmp/screenrec_cleanup.log"

_log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

# Resolve home via UID — $HOME e $USER não são confiáveis no contexto do cron
HOME_DIR=$(getent passwd "$(id -u)" | cut -d: -f6)

# Determinar REC_BASE: lê path do smb.conf se disponível; fallback para ~/REC_SHARE
_rec_base() {
    if [[ -f /etc/samba/smb.conf ]]; then
        local path
        path=$(awk '
            /^\[REC_SHARE\]/              { in_s=1; next }
            /^\[/ && !/^\[REC_SHARE\]/    { in_s=0 }
            in_s && /path[[:space:]]*=/   {
                gsub(/.*=[[:space:]]*/,"")
                gsub(/[[:space:]]*$/,"")
                print; exit
            }
        ' /etc/samba/smb.conf 2>/dev/null)
        [[ -n "$path" ]] && { echo "$path"; return 0; }
    fi
    echo "${HOME_DIR}/REC_SHARE"
}

REC_BASE=$(_rec_base)

_log "==== Limpeza iniciada ===="
_log "Diretório : $REC_BASE"
_log "Critério  : arquivos .zip com mais de $MAX_DAYS dias"

if [[ ! -d "$REC_BASE" ]]; then
    _log "AVISO: diretório '$REC_BASE' não encontrado. Nada a limpar."
    _log "==== Limpeza concluída ===="
    exit 0
fi

# ── encontrar e remover .zip antigos ─────────────────────────────────────────
removed=0
freed_kb=0

while IFS= read -r zip_file; do
    [[ -f "$zip_file" ]] || continue
    size_kb=$(du -k "$zip_file" 2>/dev/null | cut -f1)
    size_kb="${size_kb:-0}"

    if rm -rf "$zip_file" 2>/dev/null; then
        _log "  Removido : $(basename "$zip_file")  (${size_kb} KB)"
        removed=$(( removed + 1 ))
        freed_kb=$(( freed_kb + size_kb ))
    else
        _log "  ERRO     : não foi possível remover '$(basename "$zip_file")'"
    fi
done < <(find "$REC_BASE" -maxdepth 1 -name "*.zip" -mtime +"$MAX_DAYS" 2>/dev/null | sort)

if [[ $removed -eq 0 ]]; then
    _log "Nenhum arquivo elegível para remoção (todos com menos de $MAX_DAYS dias)."
else
    freed_mb=$(( freed_kb / 1024 ))
    _log "$removed arquivo(s) removido(s) — espaço liberado: ~${freed_mb} MB."
fi

# ── verificar uso do disco após limpeza ──────────────────────────────────────
disk_usage=$(df "$REC_BASE" 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}')

if [[ -n "$disk_usage" ]] && (( disk_usage >= WARN_USAGE )); then
    remaining=$(find "$REC_BASE" -maxdepth 1 -name "*.zip" 2>/dev/null | wc -l)
    disk_info=$(df -h "$REC_BASE" 2>/dev/null | awk 'NR==2 {print "usado "$3" / "$2" ("$5")"}')

    _log "ALERTA: disco com ${disk_usage}% de uso após limpeza."
    _log "ALERTA: ${remaining} ZIP(s) ainda retido(s) — ${disk_info}."
    _log "ALERTA: considere aumentar a capacidade de armazenamento."

    # Notificação gráfica — funciona apenas se houver sessão X11 ativa no momento
    if command -v notify-send &>/dev/null && [[ -n "${DISPLAY:-}" ]]; then
        notify-send \
            --urgency=critical \
            --icon=drive-harddisk \
            "REC_SHARE — Armazenamento crítico (${disk_usage}%)" \
            "${disk_info}\nZIPs retidos: ${remaining}\nDiretório: ${REC_BASE}" \
            2>/dev/null || true
    fi
fi

_log "==== Limpeza concluída ===="
