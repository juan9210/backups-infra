#!/bin/bash
set -Eeuo pipefail

############################
# Variables (NO CAMBIADAS)
############################
date=$(date "+%Y-%m-%d_%H-%M-%S")
start_time=$(date +%s)

ODOO_USER="postgres"
DB_NAME="cevaxin"
BACKUP_DIR="/home/ubuntu/backups/monthly"
ZIP_FILE="cevaxin_every-1-months_${date}.zip"

WEBHOOK_URL="https://defaultabb3ef5786a0471b9edc8cd878fbbc.b7.environment.api.powerplatform.com:443/powerautomate/automations/direct/workflows/7a2bb4721715434ca186d52deb831715/triggers/manual/paths/invoke?api-version=1&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=DtolxmIipRoEvgwGuI5a63QqFoSDj0Jg79rOcIVdTRQ"

RDS_HOST="cevaxin-instance-1.cyp2wb66kbx8.us-east-1.rds.amazonaws.com"
ODOO_SERVICE="instance-d23edcb3-bc34-4c0a-b264-41ef29a3e20d"
FILESTORE_SRC="/opt/odoo/data_dir/filestore/cevaxin/"
EVIDENCE_FILE="/home/ubuntu/backups/monthly/cevaxin_evidence.txt"
S3_DEST="s3://backups-cevaxin/cevaxin-13/monthly/"

############################
# Helpers
############################
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  echo "$s"
}

send_adaptive_card() {
  local title message
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
# Error handler (NO limpia monthly)
#######################################
on_error() {
  local code=$?
  end_time=$(date +%s)
  duration=$((end_time - start_time))

  send_adaptive_card "❌ Backup FALLÓ" \
"Base de datos: $DB_NAME
Servidor: cevaxin 13 monthly RDS
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
Servidor: cevaxin 13 monthly RDS
Destino: $S3_DEST"

log "Iniciando backup $DB_NAME"

#######################################
# Reinicio del servicio
#######################################
log "Reiniciando servicio: $ODOO_SERVICE"
sudo service "$ODOO_SERVICE" restart

#######################################
# Dump DB
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
# Limpieza intermedia (dump + filestore)
#######################################
sudo rm -f "$BACKUP_DIR/dump.sql"
sudo rm -rf "$BACKUP_DIR/filestore"

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
# Notificación éxito
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
# ✅ LIMPIEZA TOTAL DE monthly (REAL)
# solo si TODO salió bien
#######################################
log "Limpiando completamente $BACKUP_DIR"
sudo find "$BACKUP_DIR" -mindepth 1 -exec rm -rf -- {} +
log "Carpeta monthly limpiada correctamente"

#######################################
# Reinicio final del servicio
#######################################
log "Reiniciando servicio: $ODOO_SERVICE"
sudo service "$ODOO_SERVICE" restart

log "Proceso finalizado correctamente"
