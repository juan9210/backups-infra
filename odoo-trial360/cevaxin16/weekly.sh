#!/bin/bash
set -Eeuo pipefail

#######################################
# Variables (SIN CAMBIOS)
#######################################
date=$(date "+%Y-%m-%d_%H-%M-%S")
start_time=$(date +%s)

ODOO_USER="postgres"
DB_NAME="cevaxin16"
BACKUP_DIR="/mnt/backups/weekly"
ZIP_FILE="cevaxin_every-1-weeks_${date}.zip"

RDS_HOST="cevaxin-instance-1.cyp2wb66kbx8.us-east-1.rds.amazonaws.com"
FILESTORE_SRC="/home/odoo/.local/share/Odoo/filestore/cevaxin16/"
EVIDENCE_FILE="$BACKUP_DIR/cevaxin16.txt"
S3_DEST="s3://backups-cevaxin/cevaxin-16/weekly/"

WEBHOOK_URL="https://integraitsas.webhook.office.com/webhookb2/1ba8d5d1-5094-46ec-a19f-9b268ac313fc@abb3ef57-86a0-471b-9edc-8cd878fbbcb7/IncomingWebhook/8fb6636f47b940f9b368e9cd3c782e4b/a4e12f57-4499-48a6-b597-f28e3bed906c/V2XVYFdEhw2eSUO8uyT3P0cctU9GqBdyJX6RPbxe8tag81"

#######################################
# Helpers
#######################################
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  echo "$s"
}

#######################################
# Teams Adaptive Card
#######################################
send_adaptive_card() {
  local title
  local message

  title="$(json_escape "$1")"
  message="$(json_escape "$2")"

  curl -sS --max-time 10 -X POST \
    -H "Content-Type: application/json" \
    -d "{
      \"type\":\"AdaptiveCard\",
      \"version\":\"1.0\",
      \"body\":[
        {\"type\":\"TextBlock\",\"text\":\"$title\",\"weight\":\"Bolder\",\"size\":\"Medium\"},
        {\"type\":\"TextBlock\",\"text\":\"$message\",\"wrap\":true}
      ]
    }" \
    "$WEBHOOK_URL" >/dev/null || true
}

#######################################
# Error handler (NO limpia weekly)
#######################################
on_error() {
  local code=$?
  end_time=$(date +%s)
  duration=$((end_time - start_time))

  send_adaptive_card "❌ Backup FALLÓ" \
"Base de datos: $DB_NAME
Servidor: cevaxin16 weekly RDS
Código: $code
Línea: $LINENO
Duración: ${duration}s"

  exit "$code"
}
trap on_error ERR

#######################################
# Inicio
#######################################
send_adaptive_card "🚀 Backup iniciado" \
"Base de datos: $DB_NAME
Fecha: $date
Servidor: cevaxin16 weekly RDS"

log "Iniciando backup de $DB_NAME"

#######################################
# Dump de base de datos
#######################################
log "Ejecutando pg_dump"
sudo pg_dump \
  -U "$ODOO_USER" \
  -h "$RDS_HOST" \
  -Fp \
  --no-owner \
  --no-privileges \
  "$DB_NAME" > "$BACKUP_DIR/dump.sql"

[[ -s "$BACKUP_DIR/dump.sql" ]] || { log "ERROR: dump.sql vacío"; exit 2; }

#######################################
# Filestore
#######################################
log "Copiando filestore"
sudo cp -r "$FILESTORE_SRC" "$BACKUP_DIR/filestore"

[[ -d "$BACKUP_DIR/filestore" ]] || { log "ERROR: filestore no copiado"; exit 3; }

#######################################
# ZIP
#######################################
cd "$BACKUP_DIR"
log "Comprimiendo backup"
sudo zip -r "$ZIP_FILE" dump.sql filestore >/dev/null

#######################################
# Tamaño
#######################################
backup_size=$(du -h "$BACKUP_DIR/$ZIP_FILE" | cut -f1)

#######################################
# Evidencia
#######################################
ls -lh "$BACKUP_DIR" > "$EVIDENCE_FILE"

#######################################
# Subir a S3 (SIN sudo)
#######################################
log "Subiendo backup a S3"
aws s3 sync "$BACKUP_DIR" "$S3_DEST"

#######################################
# Notificación de éxito
#######################################
end_time=$(date +%s)
duration=$((end_time - start_time))

send_adaptive_card "✅ Backup finalizado" \
"Base de datos: $DB_NAME
Archivo: $ZIP_FILE
Tamaño: $backup_size
Duración: ${duration}s
Destino: AWS S3"

#######################################
# ✅ LIMPIEZA TOTAL DE LA CARPETA weekly
# (solo si todo salió bien)
#######################################
log "Limpiando completamente $BACKUP_DIR"
sudo rm -rf "${BACKUP_DIR:?}/"*
log "Carpeta weekly limpiada correctamente"

log "Proceso finalizado correctamente"