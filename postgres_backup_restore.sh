#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# postgres_backup_restore.sh — PostgreSQL backup helper with optional S3 push
# Author: Omar Haris · Repo: github.com/omar-haris/postgresql-backup-restore-utility
# -----------------------------------------------------------------------------
# Runs on any modern Linux & any PostgreSQL version (uses client tools only)
# This edition auto‑installs any missing tooling (pg client, awscli, etc.)
# across the major Linux distributions (Debian/Ubuntu, RHEL/CentOS/Fedora,
# Arch/Manjaro, openSUSE, Alpine). Root privileges (or sudo) are required
# for package installation; otherwise the script will fall back to the old
# behaviour and abort.
# -----------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

##############################################
# Default Configuration — override with flags
##############################################
# Source DB (backup)
SRC_HOST="127.0.0.1"
SRC_PORT="5432"
SRC_USER="postgres"
SRC_DB="mydb"
SRC_PASSWORD="changeme"

# Local backup directory
BACKUP_DIR="/home/backups"

# Optional restore
RESTORE_ENABLE="false"
DEST_HOST="192.168.1.99"
DEST_PORT="5432"
DEST_USER="postgres"
DEST_DB="mydb_restore"
DEST_PASSWORD="changeme"

# Optional S3 upload
S3_UPLOAD_ENABLE="false"
S3_BUCKET="my-bucket"
S3_PREFIX=""
AWS_CLI_BIN="aws"

##############################################
# Helpers
##############################################
log(){ printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# Detect package manager + install package list (space‑separated);
# accepts generic package names and tries dist‑specific fallbacks when needed.
install_packages(){
  local pkgs=("$@")
  local sudo=""
  [[ $EUID -ne 0 ]] && sudo="sudo"

  # Determine package manager
  if command -v apt-get &>/dev/null; then
    $sudo apt-get update -y
    $sudo apt-get install -y "${pkgs[@]}"
  elif command -v dnf &>/dev/null; then
    $sudo dnf install -y "${pkgs[@]}"
  elif command -v yum &>/dev/null; then
    $sudo yum install -y "${pkgs[@]}"
  elif command -v pacman &>/dev/null; then
    $sudo pacman -Sy --noconfirm "${pkgs[@]}"
  elif command -v zypper &>/dev/null; then
    $sudo zypper --non-interactive install "${pkgs[@]}"
  elif command -v apk &>/dev/null; then
    $sudo apk add --no-cache "${pkgs[@]}"
  else
    log "Unable to determine package manager — please install ${pkgs[*]} manually."
    return 1
  fi
}

# Map an executable to one or more candidate package names.
# Usage: package_for_bin pg_dump -> echoes pkg list
package_for_bin(){
  case "$1" in
    pg_dump|pg_restore|psql|createdb)
      # provide multiple fallbacks; first one that exists in repo wins
      echo "postgresql-client postgresql-client-common postgresql";;
    aws)
      echo "awscli";;
    *)
      echo "";;
  esac
}

# Ensure required executables exist; attempt auto‑install otherwise.
ensure_bins(){
  local missing=()
  for bin in "$@"; do
    if ! command -v "$bin" &>/dev/null; then
      missing+=("$bin")
    fi
  done

  [[ ${#missing[@]} -eq 0 ]] && return 0

  log "Missing tools detected: ${missing[*]} — attempting to install…"
  local pkgs=()
  for m in "${missing[@]}"; do
    mapfile -t add_pkgs < <(package_for_bin "$m")
    pkgs+=("${add_pkgs[@]}")
  done
  # Deduplicate list (shell‑portable)
  pkgs=($(printf '%s\n' "${pkgs[@]}" | awk '!seen[$0]++'))

  if install_packages "${pkgs[@]}"; then
    log "Installation complete — rechecking binaries…"
    for bin in "${missing[@]}"; do
      command -v "$bin" &>/dev/null || { log "Fatal: $bin still missing after install"; exit 1; }
    done
  else
    log "Package installation failed. Aborting."
    exit 1
  fi
}

show_help(){ cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Actions (mix & match):
  -h, --help                 Show this help and exit
  -r, --restore              After dumping, restore to destination server
  -s, --s3-upload            After dumping, copy dump file to S3 (see flags below)

Common overrides:
  -b, --backup-dir DIR       Local folder for dumps [\$BACKUP_DIR]

Source overrides:
      --src-host HOST        Source host [\$SRC_HOST]
      --src-port PORT        Source port [\$SRC_PORT]
      --src-user USER        Source user [\$SRC_USER]
      --src-db   DB          Source database [\$SRC_DB]
      --src-pass PASS        Source password [\$SRC_PASSWORD]

Destination overrides (restore):
      --dest-host HOST       Destination host [\$DEST_HOST]
      --dest-port PORT       Destination port [\$DEST_PORT]
      --dest-user USER       Destination user [\$DEST_USER]
      --dest-db   DB         Destination database [\$DEST_DB]
      --dest-pass PASS       Destination password [\$DEST_PASSWORD]

S3 overrides (upload):
      --s3-bucket  NAME      Bucket name [\$S3_BUCKET]
      --s3-prefix  PREFIX    Key prefix (folder) [\$S3_PREFIX]
      --aws-cli    PATH      aws CLI binary [\$AWS_CLI_BIN]

Examples:
  Backup with defaults:               $(basename "$0")
  Backup into /srv/pg:                $(basename "$0") -b /srv/pg
  Backup + restore:                   $(basename "$0") -r --dest-db staging
  Backup + S3 upload:                 $(basename "$0") -s --s3-bucket nightly-dumps
  All three steps in one go:          $(basename "$0") -r -s \
                                           --dest-host 10.0.0.6 \
                                           --s3-prefix prod/
EOF
}

##############################################
# Core functions
##############################################
backup(){
  log "Starting backup of $SRC_DB@$SRC_HOST:$SRC_PORT …"
  
  # Create backup directory with error handling
  if ! mkdir -p "$BACKUP_DIR"; then
    log "Error: Cannot create backup directory: $BACKUP_DIR"
    exit 1
  fi
  
  local ts="$(date '+%Y%m%d_%H%M%S')"
  local file="${SRC_DB}_${ts}.dump"
  
  # Run pg_dump with error handling
  if ! PGPASSWORD="$SRC_PASSWORD" pg_dump -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" \
      -F c -b -v -f "$BACKUP_DIR/$file" "$SRC_DB"; then
    log "Error: pg_dump failed for database $SRC_DB"
    exit 1
  fi
  
  # Verify backup file was created and has content
  if [[ ! -f "$BACKUP_DIR/$file" ]]; then
    log "Error: Backup file was not created: $BACKUP_DIR/$file"
    exit 1
  fi
  
  if [[ ! -s "$BACKUP_DIR/$file" ]]; then
    log "Error: Backup file is empty: $BACKUP_DIR/$file"
    exit 1
  fi
  
  log "Backup complete: $BACKUP_DIR/$file"
  echo "$file"
}

restore(){
  local file="$1"
  local backup_path="$BACKUP_DIR/$file"
  
  # Validate backup file exists
  if [[ ! -f "$backup_path" ]]; then
    log "Error: Backup file not found: $backup_path"
    exit 1
  fi
  
  log "Restoring $file → $DEST_DB@$DEST_HOST:$DEST_PORT …"
  
  # Test connection first
  if ! PGPASSWORD="$DEST_PASSWORD" psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" \
       -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
    log "Error: Cannot connect to destination database server"
    exit 1
  fi
  
  # Check if database exists with better query
  local db_exists
  db_exists=$(PGPASSWORD="$DEST_PASSWORD" psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" \
    -d postgres -tAc "SELECT COUNT(*) FROM pg_database WHERE datname = '$DEST_DB';")
  
  if [[ "$db_exists" == "0" ]]; then
    log "Creating destination database $DEST_DB …"
    if ! PGPASSWORD="$DEST_PASSWORD" createdb -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" "$DEST_DB"; then
      log "Error: Failed to create database $DEST_DB"
      exit 1
    fi
  fi
  
  # Run pg_restore with error handling
  if ! PGPASSWORD="$DEST_PASSWORD" pg_restore -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" \
      -d "$DEST_DB" -c -v "$backup_path"; then
    log "Error: pg_restore failed for database $DEST_DB"
    exit 1
  fi
  
  log "Restore complete."
}

s3_upload(){
  local file="$1"
  local backup_path="$BACKUP_DIR/$file"
  
  # Validate backup file exists
  if [[ ! -f "$backup_path" ]]; then
    log "Error: Backup file not found for S3 upload: $backup_path"
    exit 1
  fi
  
  ensure_bins "$AWS_CLI_BIN"
  
  local key="$S3_PREFIX${file}"
  # ensure trailing slash in prefix if non-empty
  [[ -n "$S3_PREFIX" && "${S3_PREFIX: -1}" != "/" ]] && key="${S3_PREFIX}/$file"
  
  log "Uploading $file to s3://$S3_BUCKET/$key …"
  
  # Test AWS CLI access first
  if ! "$AWS_CLI_BIN" sts get-caller-identity >/dev/null 2>&1; then
    log "Error: AWS CLI authentication failed. Check your credentials."
    exit 1
  fi
  
  # Upload with error handling
  if ! "$AWS_CLI_BIN" s3 cp "$backup_path" "s3://$S3_BUCKET/$key" --only-show-errors; then
    log "Error: S3 upload failed"
    exit 1
  fi
  
  log "S3 upload complete."
}

##############################################
# Argument parser
##############################################
parse_args(){
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) show_help; exit 0;;
      -r|--restore) RESTORE_ENABLE="true"; shift;;
      -s|--s3-upload) S3_UPLOAD_ENABLE="true"; shift;;
      -b|--backup-dir) 
        [[ $# -lt 2 ]] && { echo "Missing argument for $1"; exit 1; }
        BACKUP_DIR="$2"; shift 2;;
      --src-host) 
        [[ $# -lt 2 ]] && { echo "Missing argument for $1"; exit 1; }
        SRC_HOST="$2"; shift 2;;
      --src-port) 
        [[ $# -lt 2 ]] && { echo "Missing argument for $1"; exit 1; }
        SRC_PORT="$2"; shift 2;;
      --src-user) 
        [[ $# -lt 2 ]] && { echo "Missing argument for $1"; exit 1; }
        SRC_USER="$2"; shift 2;;
      --src-db) 
        [[ $# -lt 2 ]] && { echo "Missing argument for $1"; exit 1; }
        SRC_DB="$2"; shift 2;;
      --src-pass|--src-password) 
        [[ $# -lt 2 ]] && { echo "Missing argument for $1"; exit 1; }
        SRC_PASSWORD="$2"; shift 2;;
      --dest-host) 
        [[ $# -lt 2 ]] && { echo "Missing argument for $1"; exit 1; }
        DEST_HOST="$2"; shift 2;;
      --dest-port) 
        [[ $# -lt 2 ]] && { echo "Missing argument for $1"; exit 1; }
        DEST_PORT="$2"; shift 2;;
      --dest-user) 
        [[ $# -lt 2 ]] && { echo "Missing argument for $1"; exit 1; }
        DEST_USER="$2"; shift 2;;
      --dest-db) 
        [[ $# -lt 2 ]] && { echo "Missing argument for $1"; exit 1; }
        DEST_DB="$2"; shift 2;;
      --dest-pass|--dest-password) 
        [[ $# -lt 2 ]] && { echo "Missing argument for $1"; exit 1; }
        DEST_PASSWORD="$2"; shift 2;;
      --s3-bucket) 
        [[ $# -lt 2 ]] && { echo "Missing argument for $1"; exit 1; }
        S3_BUCKET="$2"; shift 2;;
      --s3-prefix) 
        [[ $# -lt 2 ]] && { echo "Missing argument for $1"; exit 1; }
        S3_PREFIX="$2"; shift 2;;
      --aws-cli) 
        [[ $# -lt 2 ]] && { echo "Missing argument for $1"; exit 1; }
        AWS_CLI_BIN="$2"; shift 2;;
      --) shift; break;;
      -*) echo "Unknown option: $1"; show_help; exit 1;;
      *)  break;;
    esac
  done
}

##############################################
# Main
##############################################
main(){
  parse_args "$@"

  # Build minimal tool list; aws only if needed (we'll still auto‑install lazily in s3_upload)
  bins=(pg_dump pg_restore psql createdb)
  ensure_bins "${bins[@]}"

  local dump_file
  dump_file=$(backup)

  if [[ ${RESTORE_ENABLE,,} == true ]]; then
    restore "$dump_file"
  else
    log "Restore disabled — skipping."
  fi

  if [[ ${S3_UPLOAD_ENABLE,,} == true ]]; then
    s3_upload "$dump_file"
  else
    log "S3 upload disabled — skipping."
  fi

  log "All done."
}

main "$@"
