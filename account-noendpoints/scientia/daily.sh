#!/bin/bash
set -Eeuo pipefail

#######################################
# Variables (SIN CAMBIOS)
#######################################
date=$(date "+%Y-%m-%d_%H-%M-%S")
start_time=$(date +%s)

BACKUP_DIR="/home/ubuntu/backups/daily"
ZIP_FILE="$BACKUP_DIR/scientia_every-1-days_${date}.zip"
EVIDENCE_FILE="$BACKUP_DIR/scientia_evidence.txt"

BACKUP_URL="https://scientia.trial360.site/web/database/backup"
MASTER_PWD="h1Cp)/b6hjldl5x[d687"
DB_NAME="prod-scientia-odoo"

S3_DEST="s3://backups-trial360/scientia/daily/"

WEBHOOK_URL="https://defaultabb3ef5786a0471b9edc8cd878fbbc.b7.environment.api.powerplatform.com:443/powerautomate/automations/direct/workflows/7a2bb4721715434ca186d52deb831715/triggers/manual/paths/invoke?api-version=1&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=DtolxmIipRoEvgwGuI5a63QqFoSDj0Jg79rOcIVdTRQ"

#######################################
# Helpers
#######################################
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  echo "$s"
}

#######################################
# ✅ Función para enviar Adaptive Card
#######################################
send_adaptive_card() {
  local title message
  title="$(json_escape "$1")"
  message="$(json_escape "$2")"

  curl -sS --max-time 10 -X POST \
    -H "Content-Type: application/json" \
    -d "{
      \"type\": \"AdaptiveCard\",
      \"version\": \"1.0\",
      \"body\": [
        {
          \"type\": \"TextBlock\",
          \"text\": \"$title\",
          \"weight\": \"Bolder\",
          \"size\": \"Medium\"
        },
        {
          \"type\": \"TextBlock\",
          \"text\": \"$message\",
          \"wrap\": true
        }
      ]
    }" \
    "$WEBHOOK_URL" >/dev/null || true
}

#######################################
# Error handler (NO limpia daily)
#######################################
on_error() {
  local code=$?
  end_time=$(date +%s)
  duration=$((end_time - start_time))

  send_adaptive_card "❌ Backup FALLÓ" \
"Base de datos: $DB_NAME
Código: $code
Línea: $LINENO
Comando: $BASH_COMMAND
Duración: ${duration}s"

  log "ERROR línea $LINENO: $BASH_COMMAND"
  exit "$code"
}
trap on_error ERR

#######################################
# Inicio
#######################################
send_adaptive_card "🚀 Backup iniciado" \
"Base de datos: $DB_NAME
Fecha: $date
Servidor: SCIENTIA
Destino: $S3_DEST"

log "Iniciando backup vía endpoint Odoo"

#######################################
# Backup vía endpoint Odoo
#######################################
log "Solicitando backup a Odoo"
curl -f -X POST \
  -F "master_pwd=$MASTER_PWD" \
  -F "name=$DB_NAME" \
  -F "backup_format=zip" \
  -o "$ZIP_FILE" \
  "$BACKUP_URL"

#######################################
# Validar ZIP
#######################################
if [[ ! -s "$ZIP_FILE" ]]; then
  log "ERROR: ZIP no generado o vacío"
  exit 2
fi

#######################################
# Evidencia
#######################################
ls -lh "$BACKUP_DIR" > "$EVIDENCE_FILE"

#######################################
# Subir a S3
#######################################
log "Subiendo backup a S3"
aws s3 sync "$BACKUP_DIR" "$S3_DEST"

#######################################
# Notificación éxito
#######################################
end_time=$(date +%s)
duration=$((end_time - start_time))
backup_size=$(du -h "$ZIP_FILE" | cut -f1)

send_adaptive_card "✅ Backup finalizado" \
"Base de datos: $DB_NAME
Archivo: $(basename "$ZIP_FILE")
Tamaño: $backup_size
Duración: ${duration}s
Destino: AWS S3"

#######################################
# ✅ LIMPIEZA TOTAL DE daily
#######################################
log "Limpiando completamente $BACKUP_DIR"
sudo find "$BACKUP_DIR" -mindepth 1 -exec rm -rf -- {} +
log "Carpeta daily limpiada correctamente"

log "Proceso finalizado correctamente"