#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# postgres_backup_restore.sh — PostgreSQL backup helper with optional S3 push
# Author: Omar Haris · Repo: github.com/omar-haris/postgresql-backup-restore-utility
# -----------------------------------------------------------------------------
# Runs on any modern Linux & any PostgreSQL version (uses client tools only)
# This edition auto‑installs any missing tooling (pg client, s3cmd, etc.)
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
S3_ENDPOINT=""     # Custom S3 endpoint (for MinIO, etc.)
S3_ACCESS_KEY=""   # AWS Access Key ID
S3_SECRET_KEY=""   # AWS Secret Access Key

# Optional cleanup
CLEANUP_LOCAL_ENABLE="false"
CLEANUP_S3_ENABLE="false"
CLEANUP_LOCAL_RETENTION=""    # e.g., "24h"
CLEANUP_S3_RETENTION=""       # e.g., "24h"

# Operation modes
BACKUP_ONLY="false"        # Only create backup (skip restore and S3)
RESTORE_ONLY="false"       # Only restore from latest existing backup or specified file
S3_ONLY="false"           # Only upload latest existing backup to S3
CLEANUP_ONLY="false"      # Only run cleanup operations (skip backup/restore/S3)
RESTORE_FILE=""           # Specific file to restore (optional)
RESTORE_FROM_S3="false"   # Restore from S3 instead of local
CLEANUP_ONLY="false"      # Only run cleanup operations (local and S3)

##############################################
# Helpers
##############################################
log(){ printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

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
    s3cmd)
      echo "s3cmd";;
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
    # Use read instead of mapfile for better compatibility
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] && pkgs+=("$pkg")
    done < <(package_for_bin "$m")
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

# Parse time duration string (e.g., "24h") to seconds
# Only accepts whole numbers with 'h' (hours) suffix
parse_duration_to_seconds(){
  local duration="$1"
  
  # Validate format: digits followed by h
  if [[ ! "$duration" =~ ^[0-9]+h$ ]]; then
    log "Error: Invalid duration format '$duration'. Use format like '24h' (whole numbers only)"
    return 1
  fi
  
  local number="${duration%h}"
  
  # Validate number is positive
  if [[ "$number" -eq 0 ]]; then
    log "Error: Duration must be greater than 0"
    return 1
  fi
  
  echo $((number * 3600))  # hours to seconds
}

# Safe cleanup of local backup files older than specified duration
cleanup_local(){
  local retention="$1"
  
  if [[ -z "$retention" ]]; then
    log "Error: No retention period specified for local cleanup"
    return 1
  fi
  
  local seconds
  if ! seconds=$(parse_duration_to_seconds "$retention"); then
    return 1
  fi
  
  log "Starting local cleanup: removing files older than $retention from $BACKUP_DIR"
  
  # Validate backup directory exists
  if [[ ! -d "$BACKUP_DIR" ]]; then
    log "Warning: Backup directory $BACKUP_DIR does not exist, skipping local cleanup"
    return 0
  fi
  
  # Find and remove files older than specified time
  # Use find with -name pattern to only target dump files, and -type f for safety
  local deleted_count=0
  local total_count=0
  local cutoff_time=$(($(date +%s) - seconds))
  
  while IFS= read -r -d '' file; do
    ((total_count++)) || true
    local filename=$(basename "$file")
    local file_mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo "0")
    
    # Additional safety: only delete files matching our dump pattern
    if [[ "$filename" =~ ^[a-zA-Z0-9_]+_[0-9]{8}_[0-9]{6}\.dump$ ]]; then
      if [[ "$file_mtime" -lt "$cutoff_time" ]]; then
        log "Deleting old backup: $filename ($(date -d "@$file_mtime" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$file_mtime" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'unknown date'))"
        if rm "$file"; then
          ((deleted_count++)) || true
        else
          log "Warning: Failed to delete $file"
        fi
      fi
    else
      log "Skipping non-dump file: $filename"
    fi
  done < <(find "$BACKUP_DIR" -name "*.dump" -type f -print0 2>/dev/null)
  
  log "Local cleanup complete: $deleted_count/$total_count eligible files removed"
}

# Safe cleanup of S3 backup files older than specified duration
cleanup_s3(){
  local retention="$1"
  
  if [[ -z "$retention" ]]; then
    log "Error: No retention period specified for S3 cleanup"
    return 1
  fi
  
  local seconds
  if ! seconds=$(parse_duration_to_seconds "$retention"); then
    return 1
  fi
  
  ensure_bins "s3cmd"
  
  log "Starting S3 cleanup: removing files older than $retention from s3://$S3_BUCKET/$S3_PREFIX"
  
  # Prepare s3cmd options
  local s3cmd_opts=()
  if [[ -n "$S3_ENDPOINT" ]]; then
    s3cmd_opts+=("--host=$S3_ENDPOINT" "--host-bucket=$S3_ENDPOINT")
  fi
  
  # Add AWS credentials if specified
  if [[ -n "$S3_ACCESS_KEY" ]]; then
    s3cmd_opts+=("--access_key=$S3_ACCESS_KEY")
  fi
  if [[ -n "$S3_SECRET_KEY" ]]; then
    s3cmd_opts+=("--secret_key=$S3_SECRET_KEY")
  fi
  
  # Test S3 access first
  if ! s3cmd "${s3cmd_opts[@]}" ls "s3://$S3_BUCKET/$S3_PREFIX" >/dev/null 2>&1; then
    log "Error: Cannot access S3 bucket for cleanup. Check credentials and bucket access."
    return 1
  fi
  
  # Calculate cutoff date
  local cutoff_date
  cutoff_date=$(date -d "@$(($(date +%s) - seconds))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || {
    # Fallback for systems without GNU date
    cutoff_date=$(date -r $(($(date +%s) - seconds)) '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || {
      log "Error: Cannot calculate cutoff date for cleanup"
      return 1
    }
  }
  
  log "Cutoff date for S3 cleanup: $cutoff_date"
  
  # List S3 files and parse for cleanup
  local deleted_count=0
  local total_count=0
  
  # Get list of files in S3 with timestamps
  while IFS= read -r line; do
    # Parse s3cmd ls output: date time size key
    if [[ "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}[[:space:]]+[0-9]+[[:space:]]+(.+\.dump)$ ]]; then
      local s3_key="${BASH_REMATCH[1]}"
      local file_date="${line%% *}"
      local file_time=$(echo "$line" | awk '{print $2}')
      local file_datetime="$file_date $file_time"
      local filename=$(basename "$s3_key")
      
      ((total_count++))
      
      # Additional safety: only delete files matching our dump pattern
      if [[ "$filename" =~ ^[a-zA-Z0-9_]+_[0-9]{8}_[0-9]{6}\.dump$ ]]; then
        # Compare dates (this is basic string comparison, works for ISO format)
        if [[ "$file_datetime" < "$cutoff_date" ]]; then
          log "Deleting old S3 backup: $s3_key (created: $file_datetime)"
          if s3cmd "${s3cmd_opts[@]}" del "s3://$S3_BUCKET/$s3_key"; then
            ((deleted_count++))
          else
            log "Warning: Failed to delete s3://$S3_BUCKET/$s3_key"
          fi
        fi
      else
        log "Skipping non-dump file in S3: $filename"
      fi
    fi
  done < <(s3cmd "${s3cmd_opts[@]}" ls "s3://$S3_BUCKET/$S3_PREFIX" 2>/dev/null | grep "\.dump$")
  
  log "S3 cleanup complete: $deleted_count/$total_count eligible files removed"
}

# Find the latest backup file by timestamp for a given database
find_latest_backup(){
  local db_pattern="$1"
  local latest_file=""
  local latest_time=0
  
  # Ensure backup directory exists
  if [[ ! -d "$BACKUP_DIR" ]]; then
    log "Error: Backup directory does not exist: $BACKUP_DIR"
    exit 1
  fi
  
  # Find all matching dump files
  for file in "$BACKUP_DIR"/${db_pattern}_*.dump; do
    [[ -f "$file" ]] || continue
    
    # Extract timestamp from filename (format: dbname_YYYYMMDD_HHMMSS.dump)
    local basename=$(basename "$file" .dump)
    local timestamp=${basename##*_}
    local db_part=${basename%_*}
    local date_part=${db_part##*_}
    
    # Verify we have a valid timestamp format (YYYYMMDD_HHMMSS)
    if [[ $date_part =~ ^[0-9]{8}$ && $timestamp =~ ^[0-9]{6}$ ]]; then
      # Convert timestamp to seconds for comparison (YYYYMMDD_HHMMSS)
      local file_time=$(date -d "${date_part:0:4}-${date_part:4:2}-${date_part:6:2} ${timestamp:0:2}:${timestamp:2:2}:${timestamp:4:2}" +%s 2>/dev/null || echo 0)
      
      if [[ $file_time -gt $latest_time ]]; then
        latest_time=$file_time
        latest_file=$(basename "$file")
      fi
    fi
  done
  
  if [[ -n "$latest_file" ]]; then
    echo "$latest_file"
  else
    log "Error: No backup files found matching pattern: ${db_pattern}_*.dump in $BACKUP_DIR"
    exit 1
  fi
}

# Download a backup file from S3
s3_download(){
  local file="$1"
  local backup_path="$BACKUP_DIR/$file"
  
  ensure_bins "s3cmd"
  
  local key="$S3_PREFIX${file}"
  # ensure trailing slash in prefix if non-empty
  [[ -n "$S3_PREFIX" && "${S3_PREFIX: -1}" != "/" ]] && key="${S3_PREFIX}/$file"
  
  log "Downloading $file from s3://$S3_BUCKET/$key using s3cmd …"
  
  # s3cmd download
  local s3cmd_opts=()
  
  # Add custom endpoint if specified
  if [[ -n "$S3_ENDPOINT" ]]; then
    s3cmd_opts+=("--host=$S3_ENDPOINT" "--host-bucket=$S3_ENDPOINT")
  fi
  
  # Add AWS credentials if specified
  if [[ -n "$S3_ACCESS_KEY" ]]; then
    s3cmd_opts+=("--access_key=$S3_ACCESS_KEY")
  fi
  if [[ -n "$S3_SECRET_KEY" ]]; then
    s3cmd_opts+=("--secret_key=$S3_SECRET_KEY")
  fi
  
  # Test s3cmd access first
  if ! s3cmd "${s3cmd_opts[@]}" ls s3://"$S3_BUCKET"/ >/dev/null 2>&1; then
    log "Error: s3cmd authentication or bucket access failed. Check your credentials and bucket."
    exit 1
  fi
  
  # Create backup directory if it doesn't exist
  if ! mkdir -p "$BACKUP_DIR"; then
    log "Error: Cannot create backup directory: $BACKUP_DIR"
    exit 1
  fi
  
  # Download with error handling
  if ! s3cmd "${s3cmd_opts[@]}" get "s3://$S3_BUCKET/$key" "$backup_path"; then
    log "Error: S3 download failed"
    exit 1
  fi
  
  # Verify downloaded file exists and has content
  if [[ ! -f "$backup_path" ]]; then
    log "Error: Downloaded file was not created: $backup_path"
    exit 1
  fi
  
  if [[ ! -s "$backup_path" ]]; then
    log "Error: Downloaded file is empty: $backup_path"
    exit 1
  fi
  
  log "S3 download complete: $backup_path"
}

# Find the latest backup file in S3 for a given database
find_latest_s3_backup(){
  local db_pattern="$1"
  local latest_file=""
  local latest_time=0
  
  ensure_bins "s3cmd"
  
  # Prepare s3cmd options
  local s3cmd_opts=()
  if [[ -n "$S3_ENDPOINT" ]]; then
    s3cmd_opts+=("--host=$S3_ENDPOINT" "--host-bucket=$S3_ENDPOINT")
  fi
  
  # Add AWS credentials if specified
  if [[ -n "$S3_ACCESS_KEY" ]]; then
    s3cmd_opts+=("--access_key=$S3_ACCESS_KEY")
  fi
  if [[ -n "$S3_SECRET_KEY" ]]; then
    s3cmd_opts+=("--secret_key=$S3_SECRET_KEY")
  fi
  
  # Test S3 access first
  if ! s3cmd "${s3cmd_opts[@]}" ls "s3://$S3_BUCKET/$S3_PREFIX" >/dev/null 2>&1; then
    log "Error: Cannot access S3 bucket. Check credentials and bucket access."
    exit 1
  fi
  
  # List S3 files and find latest
  while IFS= read -r line; do
    # Parse s3cmd ls output: date time size key
    if [[ "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}[[:space:]]+[0-9]+[[:space:]]+(.+\.dump)$ ]]; then
      local s3_key="${BASH_REMATCH[1]}"
      local filename=$(basename "$s3_key")
      
      # Check if this file matches our database pattern
      if [[ "$filename" =~ ^${db_pattern}_[0-9]{8}_[0-9]{6}\.dump$ ]]; then
        # Extract timestamp from filename
        local basename_no_ext="${filename%.dump}"
        local timestamp=${basename_no_ext##*_}
        local db_part=${basename_no_ext%_*}
        local date_part=${db_part##*_}
        
        # Verify we have a valid timestamp format (YYYYMMDD_HHMMSS)
        if [[ $date_part =~ ^[0-9]{8}$ && $timestamp =~ ^[0-9]{6}$ ]]; then
          # Convert timestamp to seconds for comparison
          local file_time=$(date -d "${date_part:0:4}-${date_part:4:2}-${date_part:6:2} ${timestamp:0:2}:${timestamp:2:2}:${timestamp:4:2}" +%s 2>/dev/null || echo 0)
          
          if [[ $file_time -gt $latest_time ]]; then
            latest_time=$file_time
            latest_file="$filename"
          fi
        fi
      fi
    fi
  done < <(s3cmd "${s3cmd_opts[@]}" ls "s3://$S3_BUCKET/$S3_PREFIX" 2>/dev/null | grep "\.dump$")
  
  if [[ -n "$latest_file" ]]; then
    echo "$latest_file"
  else
    log "Error: No backup files found matching pattern: ${db_pattern}_*.dump in s3://$S3_BUCKET/$S3_PREFIX"
    exit 1
  fi
}

show_help(){ cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Operation Modes (choose one):
  [default]                  Create backup, then optionally restore/upload
  --backup-only              Only create backup (skip restore and S3)
  --restore-only             Only restore from latest existing backup or specified file
  --s3-only                  Only upload latest existing backup to S3
  --cleanup-only             Only run cleanup operations (local and S3)

Actions (for default mode):
  -h, --help                 Show this help and exit
  -r, --restore              After dumping, restore to destination server
  -s, --s3-upload            After dumping, copy dump file to S3 (see flags below)
      --cleanup-local TIME   Clean up local backups older than TIME (e.g., 24h)
      --cleanup-s3 TIME      Clean up S3 backups older than TIME (e.g., 24h)

Restore options:
      --restore-file FILE    Restore specific file instead of latest backup
      --restore-from-s3      Restore from S3 instead of local directory

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
      --s3-endpoint URL      Custom S3 endpoint [\$S3_ENDPOINT]
      --s3-access-key KEY    AWS Access Key ID [\$S3_ACCESS_KEY]
      --s3-secret-key KEY    AWS Secret Access Key [\$S3_SECRET_KEY]

Examples:
  Backup with defaults:               $(basename "$0")
  Backup into /srv/pg:                $(basename "$0") -b /srv/pg
  Backup + restore:                   $(basename "$0") -r --dest-db staging
  Backup + S3 upload:                 $(basename "$0") -s --s3-bucket nightly-dumps
  With AWS credentials:
    $(basename "$0") -s --s3-bucket backups \\
      --s3-access-key AKIAIOSFODNN7EXAMPLE \\
      --s3-secret-key wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

  With MinIO endpoint:
    $(basename "$0") -s --s3-bucket test-bucket \\
      --s3-endpoint minio:9000

Operation Mode Examples:
  Create backup only:                 $(basename "$0") --backup-only
  Restore latest backup:              $(basename "$0") --restore-only --dest-db new_staging
  Restore specific file:              $(basename "$0") --restore-only --restore-file mydb_20240125_120000.dump
  Restore from S3:                    $(basename "$0") --restore-only --restore-from-s3 --dest-db staging
  Upload latest to S3:                $(basename "$0") --s3-only --s3-bucket archive
  
  Cleanup local files older than 24h: $(basename "$0") --cleanup-local 24h
  Cleanup S3 files older than 7 days: $(basename "$0") --cleanup-s3 168h
  
  Backup + upload + cleanup:
    $(basename "$0") -s --s3-bucket backups \\
      --cleanup-local 48h --cleanup-s3 168h
      
  All steps + cleanup:
    $(basename "$0") -r -s \\
      --dest-host 10.0.0.6 \\
      --s3-prefix prod/ \\
      --cleanup-local 24h --cleanup-s3 168h

File Selection Logic:
  - Default mode: Always creates a new backup with timestamp
  - --restore-only: Uses latest backup file by timestamp (or specified file)
  - --s3-only: Uses latest backup file by timestamp  
  - Timestamp format: database_YYYYMMDD_HHMMSS.dump
  - --restore-from-s3: Downloads latest backup from S3 for restore
  - --restore-file: Allows specifying exact backup file to restore
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
  # Note: pg_restore -c (clean) may generate warnings when dropping non-existent objects, this is normal
  if ! PGPASSWORD="$DEST_PASSWORD" pg_restore -h "$DEST_HOST" -p "$DEST_PORT" -U "$DEST_USER" \
      -d "$DEST_DB" --if-exists -c -v "$backup_path"; then
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
  
  ensure_bins "s3cmd"
  
  local key="$S3_PREFIX${file}"
  # ensure trailing slash in prefix if non-empty
  [[ -n "$S3_PREFIX" && "${S3_PREFIX: -1}" != "/" ]] && key="${S3_PREFIX}/$file"
  
  log "Uploading $file to s3://$S3_BUCKET/$key using s3cmd …"
  
  # s3cmd upload
  local s3cmd_opts=()
  
  # Add custom endpoint if specified
  if [[ -n "$S3_ENDPOINT" ]]; then
    s3cmd_opts+=("--host=$S3_ENDPOINT" "--host-bucket=$S3_ENDPOINT")
  fi
  
  # Add AWS credentials if specified
  if [[ -n "$S3_ACCESS_KEY" ]]; then
    s3cmd_opts+=("--access_key=$S3_ACCESS_KEY")
  fi
  if [[ -n "$S3_SECRET_KEY" ]]; then
    s3cmd_opts+=("--secret_key=$S3_SECRET_KEY")
  fi
  
  # Test s3cmd access first
  if ! s3cmd "${s3cmd_opts[@]}" ls s3://"$S3_BUCKET"/ >/dev/null 2>&1; then
    log "Error: s3cmd authentication or bucket access failed. Check your credentials and bucket."
    exit 1
  fi
  
  # Upload with error handling
  if ! s3cmd "${s3cmd_opts[@]}" put "$backup_path" "s3://$S3_BUCKET/$key"; then
    log "Error: S3 upload failed"
    exit 1
  fi
  
  log "S3 upload complete."
}

##############################################
# Argument parser
##############################################
parse_args(){
  # Check for mutually exclusive operation modes
  local mode_count=0
  for arg in "$@"; do
    case "$arg" in
      --backup-only|--restore-only|--s3-only|--cleanup-only) ((mode_count++)) || true;;
    esac
  done
  
  if [[ $mode_count -gt 1 ]]; then
    echo "Error: Cannot combine operation modes (--backup-only, --restore-only, --s3-only, --cleanup-only)"
    exit 1
  fi
  
  # Special case: if only cleanup flags are specified, enable cleanup-only mode
  if [[ "$mode_count" -eq 0 ]] && [[ "$CLEANUP_LOCAL_ENABLE" == "true" || "$CLEANUP_S3_ENABLE" == "true" ]]; then
    CLEANUP_ONLY="true"
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) show_help; exit 0;;
      -r|--restore) RESTORE_ENABLE="true"; shift;;
      -s|--s3-upload) S3_UPLOAD_ENABLE="true"; shift;;
      --cleanup-only) CLEANUP_ONLY="true"; shift;;
      --backup-only) BACKUP_ONLY="true"; shift;;
      --restore-only) RESTORE_ONLY="true"; shift;;
      --s3-only) S3_ONLY="true"; shift;;
      --cleanup-only) CLEANUP_ONLY="true"; shift;;
      --restore-file) 
        [[ $# -lt 2 ]] && { echo "Missing argument for $1"; exit 1; }
        RESTORE_FILE="$2"; shift 2;;
      --restore-from-s3) RESTORE_FROM_S3="true"; shift;;
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
      --s3-endpoint) 
        [[ $# -lt 2 ]] && { echo "Missing argument for $1"; exit 1; }
        S3_ENDPOINT="$2"; shift 2;;
      --s3-access-key) 
        [[ $# -lt 2 ]] && { echo "Missing argument for $1"; exit 1; }
        S3_ACCESS_KEY="$2"; shift 2;;
      --s3-secret-key) 
        [[ $# -lt 2 ]] && { echo "Missing argument for $1"; exit 1; }
        S3_SECRET_KEY="$2"; shift 2;;
      --cleanup-local)
        [[ $# -lt 2 ]] && { echo "Missing argument for $1"; exit 1; }
        CLEANUP_LOCAL_ENABLE="true"
        CLEANUP_LOCAL_RETENTION="$2"; shift 2;;
      --cleanup-s3)
        [[ $# -lt 2 ]] && { echo "Missing argument for $1"; exit 1; }
        CLEANUP_S3_ENABLE="true"
        CLEANUP_S3_RETENTION="$2"; shift 2;;
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

  # Define required binaries based on operation mode
  local bins=(pg_dump pg_restore psql createdb)
  
  # Add s3cmd to dependencies if S3 operations are needed
  if [[ "$S3_UPLOAD_ENABLE" == "true" || "$S3_ONLY" == "true" || "$RESTORE_FROM_S3" == "true" ]]; then
    bins+=(s3cmd)
  fi
  
  ensure_bins "${bins[@]}"

  local dump_file=""
  
  # Operation Mode Logic
  if [[ "$CLEANUP_ONLY" == "true" ]]; then
    # Mode: Cleanup-only
    log "Mode: Cleanup-only"
    if [[ "$CLEANUP_LOCAL_ENABLE" == "true" ]]; then
      cleanup_local "$CLEANUP_LOCAL_RETENTION"
    else
      log "Local cleanup disabled — skipping."
    fi

    if [[ "$CLEANUP_S3_ENABLE" == "true" ]]; then
      cleanup_s3 "$CLEANUP_S3_RETENTION"
    else
      log "S3 cleanup disabled — skipping."
    fi
    log "Cleanup-only mode complete."
    
  elif [[ "$BACKUP_ONLY" == "true" ]]; then
    # Mode: Backup-only
    log "Mode: Backup-only"
    dump_file=$(backup)
    log "Backup-only mode complete."
    
  elif [[ "$RESTORE_ONLY" == "true" ]]; then
    # Mode: Restore-only from existing backup
    log "Mode: Restore from existing backup"
    
    # Determine which file to restore
    if [[ -n "$RESTORE_FILE" ]]; then
      # User specified a specific file
      dump_file="$RESTORE_FILE"
      log "Using specified backup file: $dump_file"
    elif [[ "$RESTORE_FROM_S3" == "true" ]]; then
      # Find latest in S3 and download
      dump_file=$(find_latest_s3_backup "$SRC_DB")
      log "Found latest S3 backup: $dump_file"
      s3_download "$dump_file"
    else
      # Find latest local backup
      dump_file=$(find_latest_backup "$SRC_DB")
      log "Using latest local backup: $dump_file"
    fi
    
    restore "$dump_file"
    
  elif [[ "$S3_ONLY" == "true" ]]; then
    # Mode: S3-upload-only from existing backup  
    log "Mode: S3 upload from existing backup"
    
    # Always use latest local backup for S3-only mode
    dump_file=$(find_latest_backup "$SRC_DB")
    log "Using latest local backup for S3 upload: $dump_file"
    s3_upload "$dump_file"
    
  else
    # Mode: Default (Backup + optional restore/upload + cleanup)
    log "Mode: Backup with optional restore/upload"
    dump_file=$(backup)

    # Restore logic
    if [[ "$RESTORE_ENABLE" == "true" ]]; then
      restore "$dump_file"
    else
      log "Restore disabled — skipping."
    fi

    # S3 upload logic  
    if [[ "$S3_UPLOAD_ENABLE" == "true" ]]; then
      s3_upload "$dump_file"
    else
      log "S3 upload disabled — skipping."
    fi
  fi

  # Cleanup operations (run for all modes except backup-only)
  if [[ "$BACKUP_ONLY" != "true" ]]; then
    if [[ "$CLEANUP_LOCAL_ENABLE" == "true" ]]; then
      cleanup_local "$CLEANUP_LOCAL_RETENTION"
    else
      log "Local cleanup disabled — skipping."
    fi

    if [[ "$CLEANUP_S3_ENABLE" == "true" ]]; then
      cleanup_s3 "$CLEANUP_S3_RETENTION"
    else
      log "S3 cleanup disabled — skipping."
    fi
  fi

  log "All done."
}

main "$@"
