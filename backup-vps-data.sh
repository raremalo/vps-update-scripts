#!/usr/bin/env bash
# backup-vps-data.sh
# Standalone Backup-Skript für VPS-Daten
# Features: Datenbank-Backups, Volume-Sicherung, Konfigurations-Export, Remote-Backup-Support

set -euo pipefail

# =====================================
# Konfiguration
# =====================================
SCRIPT_NAME="VPS Backup"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/vps-data}"
BACKUP_TEMP="/tmp/vps-backup-$$"
LOGFILE="${BACKUP_DIR}/backup.log"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="vps-backup-${TIMESTAMP}"

# Backup-Optionen
BACKUP_SYSTEM="${BACKUP_SYSTEM:-true}"
BACKUP_DOCKER="${BACKUP_DOCKER:-true}"
BACKUP_DATABASES="${BACKUP_DATABASES:-true}"
BACKUP_VOLUMES="${BACKUP_VOLUMES:-true}"
BACKUP_CONFIGS="${BACKUP_CONFIGS:-true}"
COMPRESS_BACKUP="${COMPRESS_BACKUP:-true}"
ENCRYPT_BACKUP="${ENCRYPT_BACKUP:-false}"
ENCRYPTION_KEY="${ENCRYPTION_KEY:-}"

# Retention
KEEP_LOCAL_DAYS="${KEEP_LOCAL_DAYS:-7}"
KEEP_REMOTE_DAYS="${KEEP_REMOTE_DAYS:-30}"

# Remote Backup (optional)
REMOTE_BACKUP="${REMOTE_BACKUP:-false}"
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-}"
REMOTE_PATH="${REMOTE_PATH:-}"

# Limits
MAX_BACKUP_SIZE_GB="${MAX_BACKUP_SIZE_GB:-10}"
MIN_FREE_SPACE_GB="${MIN_FREE_SPACE_GB:-1}"
MAX_VOLUME_SIZE_MB="${MAX_VOLUME_SIZE_MB:-500}"

# =====================================
# Farben
# =====================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =====================================
# Logging
# =====================================
log() {
    local level="$1"
    shift
    local message="$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOGFILE"
    
    case "$level" in
        SUCCESS) echo -e "${GREEN}✓${NC} $message" ;;
        ERROR)   echo -e "${RED}✗${NC} $message" ;;
        WARNING) echo -e "${YELLOW}!${NC} $message" ;;
        INFO)    echo -e "${BLUE}ℹ${NC} $message" ;;
    esac
}

# =====================================
# Cleanup
# =====================================
cleanup() {
    if [[ -d "$BACKUP_TEMP" ]]; then
        log "INFO" "Räume temporäre Dateien auf..."
        rm -rf "$BACKUP_TEMP"
    fi
}

trap cleanup EXIT

# =====================================
# Hilfsfunktionen
# =====================================
check_requirements() {
    local missing_tools=()
    
    # Prüfe benötigte Tools
    for tool in docker tar gzip; do
        if ! command -v $tool &> /dev/null; then
            missing_tools+=($tool)
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log "ERROR" "Fehlende Tools: ${missing_tools[*]}"
        exit 1
    fi
    
    # Prüfe Root-Rechte
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "Dieses Skript muss als root ausgeführt werden"
        exit 1
    fi
}

check_disk_space() {
    local path="$1"
    local required_gb="${2:-1}"
    
    local available_gb=$(df -BG "$path" | awk 'NR==2 {print $4}' | sed 's/G//')
    
    if [[ $available_gb -lt $required_gb ]]; then
        log "ERROR" "Nicht genug Speicherplatz: ${available_gb}GB verfügbar, ${required_gb}GB benötigt"
        return 1
    fi
    
    log "INFO" "Speicherplatz OK: ${available_gb}GB verfügbar"
    return 0
}

get_backup_size() {
    local path="$1"
    if [[ -e "$path" ]]; then
        du -sh "$path" | cut -f1
    else
        echo "0"
    fi
}

# =====================================
# System-Backup
# =====================================
backup_system_info() {
    log "INFO" "Sichere System-Informationen..."
    
    local sys_dir="$BACKUP_TEMP/system"
    mkdir -p "$sys_dir"
    
    # System-Info
    {
        echo "=== VPS System Backup ==="
        echo "Timestamp: $TIMESTAMP"
        echo "Hostname: $(hostname -f)"
        echo "IP: $(ip -4 addr show | grep inet | grep -v 127.0.0.1 | awk '{print $2}' | head -1)"
        echo "Kernel: $(uname -r)"
        echo "OS: $(lsb_release -ds 2>/dev/null || cat /etc/*release | head -1)"
        echo ""
        echo "=== Hardware ==="
        echo "CPU: $(nproc) cores"
        echo "RAM: $(free -h | awk 'NR==2{print $2}')"
        echo "Disk: $(df -h / | awk 'NR==2{print $2}')"
    } > "$sys_dir/system-info.txt"
    
    # Paketliste
    dpkg --get-selections > "$sys_dir/packages.txt"
    apt list --installed > "$sys_dir/apt-installed.txt" 2>/dev/null
    
    # Netzwerk-Konfiguration
    ip addr show > "$sys_dir/network-interfaces.txt"
    ss -tulpn > "$sys_dir/network-ports.txt" 2>/dev/null
    
    # Cron-Jobs
    crontab -l > "$sys_dir/crontab-root.txt" 2>/dev/null || true
    
    # Systemd Services
    systemctl list-units --state=running > "$sys_dir/systemd-running.txt"
    
    log "SUCCESS" "System-Informationen gesichert"
}

# =====================================
# Docker-Backup
# =====================================
backup_docker_configs() {
    log "INFO" "Sichere Docker-Konfigurationen..."
    
    local docker_dir="$BACKUP_TEMP/docker"
    mkdir -p "$docker_dir"
    
    # Container-Konfigurationen
    docker ps -a --format json > "$docker_dir/containers.json"
    
    # Detaillierte Container-Configs
    mkdir -p "$docker_dir/container-configs"
    for container in $(docker ps -a --format '{{.Names}}'); do
        docker inspect "$container" > "$docker_dir/container-configs/${container}.json" 2>/dev/null || true
    done
    
    # Docker-Compose Files finden und sichern
    mkdir -p "$docker_dir/compose-files"
    while read -r compose_file; do
        if [[ -f "$compose_file" ]]; then
            local backup_name=$(echo "$compose_file" | tr '/' '_')
            cp "$compose_file" "$docker_dir/compose-files/${backup_name}"
        fi
    done < <(find / -xdev -maxdepth 5 -name "docker-compose*.yml" -o -name "docker-compose*.yaml" 2>/dev/null)
    
    # Docker Networks
    docker network ls --format json > "$docker_dir/networks.json"
    
    # Docker Volumes Liste
    docker volume ls --format json > "$docker_dir/volumes.json"
    
    log "SUCCESS" "Docker-Konfigurationen gesichert"
}

# =====================================
# Datenbank-Backup
# =====================================
backup_databases() {
    log "INFO" "Starte Datenbank-Backups..."
    
    local db_dir="$BACKUP_TEMP/databases"
    mkdir -p "$db_dir"
    
    # PostgreSQL
    for container in $(docker ps --format '{{.Names}}' | grep -E '(postgres|postgresql|pg)'); do
        log "INFO" "Sichere PostgreSQL: $container"
        
        # Versuche verschiedene Benutzernamen
        for user in postgres root admin; do
            if docker exec "$container" psql -U "$user" -c '\l' &>/dev/null; then
                docker exec "$container" pg_dumpall -U "$user" 2>/dev/null | \
                    gzip > "$db_dir/${container}_postgres.sql.gz" && \
                    log "SUCCESS" "PostgreSQL $container gesichert" && break
            fi
        done
    done
    
    # MySQL/MariaDB
    for container in $(docker ps --format '{{.Names}}' | grep -E '(mysql|mariadb)'); do
        log "INFO" "Sichere MySQL/MariaDB: $container"
        
        # Hole Root-Passwort aus Umgebungsvariablen
        local root_pass=$(docker exec "$container" printenv MYSQL_ROOT_PASSWORD 2>/dev/null || echo "")
        
        if [[ -n "$root_pass" ]]; then
            docker exec -e MYSQL_PWD="$root_pass" "$container" mysqldump -uroot --all-databases --single-transaction 2>/dev/null | \
                gzip > "$db_dir/${container}_mysql.sql.gz" && \
                log "SUCCESS" "MySQL $container gesichert"
        else
            docker exec "$container" mysqldump -uroot --all-databases --single-transaction 2>/dev/null | \
                gzip > "$db_dir/${container}_mysql.sql.gz" 2>/dev/null && \
                log "SUCCESS" "MySQL $container gesichert (ohne Passwort)"
        fi
    done
    
    # MongoDB
    for container in $(docker ps --format '{{.Names}}' | grep -E '(mongo|mongodb)'); do
        log "INFO" "Sichere MongoDB: $container"
        docker exec "$container" mongodump --archive 2>/dev/null | \
            gzip > "$db_dir/${container}_mongodb.gz" && \
            log "SUCCESS" "MongoDB $container gesichert"
    done
    
    # Redis
    for container in $(docker ps --format '{{.Names}}' | grep -E '(redis)'); do
        log "INFO" "Sichere Redis: $container"
        
        # Trigger BGSAVE
        docker exec "$container" redis-cli BGSAVE 2>/dev/null || true
        sleep 3
        
        # Kopiere dump.rdb
        docker cp "$container:/data/dump.rdb" "$db_dir/${container}_redis.rdb" 2>/dev/null && \
            log "SUCCESS" "Redis $container gesichert"
    done
    
    # Coolify-spezifische DB
    if docker ps --format '{{.Names}}' | grep -qx "coolify-db"; then
        log "INFO" "Sichere Coolify-Datenbank..."
        docker exec coolify-db pg_dumpall -U postgres 2>/dev/null | \
            gzip > "$db_dir/coolify_database.sql.gz" && \
            log "SUCCESS" "Coolify-Datenbank gesichert"
    fi
    
    log "SUCCESS" "Datenbank-Backups abgeschlossen"
}

# =====================================
# Volume-Backup
# =====================================
backup_docker_volumes() {
    log "INFO" "Sichere Docker Volumes..."
    
    local vol_dir="$BACKUP_TEMP/volumes"
    mkdir -p "$vol_dir"
    
    # Kritische Volumes definieren
    local critical_patterns=(
        "db"
        "data"
        "config"
        "coolify"
        "postgres"
        "mysql"
        "mongo"
        "redis"
    )
    
    # Volumes zum Überspringen
    local skip_patterns=(
        "cache"
        "tmp"
        "temp"
        "log"
        "_build"
    )
    
    for volume in $(docker volume ls -q); do
        local skip=false
        
        # Prüfe ob Volume übersprungen werden soll
        for pattern in "${skip_patterns[@]}"; do
            if [[ "$volume" == *"$pattern"* ]]; then
                skip=true
                break
            fi
        done
        
        if [[ "$skip" == "true" ]]; then
            log "INFO" "Überspringe Volume: $volume"
            continue
        fi
        
        # Prüfe Volume-Größe
        local mount_point=$(docker volume inspect "$volume" --format '{{.Mountpoint}}')
        if [[ -d "$mount_point" ]]; then
            local size_mb=$(du -sm "$mount_point" 2>/dev/null | cut -f1)
            
            if [[ $size_mb -gt $MAX_VOLUME_SIZE_MB ]]; then
                log "WARNING" "Volume $volume zu groß (${size_mb}MB > ${MAX_VOLUME_SIZE_MB}MB)"
                continue
            fi
            
            log "INFO" "Sichere Volume: $volume (${size_mb}MB)"
            
            # Backup mit Alpine Container
            docker run --rm \
                -v "$volume:/source:ro" \
                -v "$vol_dir:/backup" \
                alpine tar czf "/backup/${volume}.tar.gz" -C /source . 2>/dev/null && \
                log "SUCCESS" "Volume $volume gesichert"
        fi
    done
    
    log "SUCCESS" "Volume-Backups abgeschlossen"
}

# =====================================
# Konfigurations-Backup
# =====================================
backup_configs() {
    log "INFO" "Sichere Konfigurationsdateien..."
    
    local conf_dir="$BACKUP_TEMP/configs"
    mkdir -p "$conf_dir"
    
    # Wichtige Konfigurationsdateien
    local config_files=(
        "/etc/ssh/sshd_config"
        "/etc/nginx/nginx.conf"
        "/etc/apache2/apache2.conf"
        "/etc/systemd/system/docker-autostart.service"
        "/root/.bashrc"
        "/root/.profile"
    )
    
    for file in "${config_files[@]}"; do
        if [[ -f "$file" ]]; then
            local backup_name=$(echo "$file" | tr '/' '_')
            cp "$file" "$conf_dir/${backup_name}" 2>/dev/null && \
                log "INFO" "Gesichert: $file"
        fi
    done
    
    # Nginx Sites
    if [[ -d "/etc/nginx/sites-available" ]]; then
        cp -r /etc/nginx/sites-available "$conf_dir/nginx-sites" 2>/dev/null
    fi
    
    # Coolify-Konfiguration
    if [[ -d "/data/coolify" ]]; then
        log "INFO" "Sichere Coolify-Konfiguration..."
        mkdir -p "$conf_dir/coolify"
        
        # .env Dateien
        while read -r env_file; do
            local backup_name=$(echo "$env_file" | tr '/' '_')
            cp "$env_file" "$conf_dir/coolify/${backup_name}"
        done < <(find /data/coolify -name ".env*" -type f 2>/dev/null)

        # docker-compose Dateien
        while read -r compose_file; do
            local backup_name=$(echo "$compose_file" | tr '/' '_')
            cp "$compose_file" "$conf_dir/coolify/${backup_name}"
        done < <(find /data/coolify -name "docker-compose*.yml" -o -name "docker-compose*.yaml" 2>/dev/null)
    fi
    
    log "SUCCESS" "Konfigurationsdateien gesichert"
}

# =====================================
# Backup-Kompression
# =====================================
create_archive() {
    log "INFO" "Erstelle Backup-Archiv..."
    
    cd "$BACKUP_TEMP"
    
    # Erstelle Manifest
    {
        echo "=== VPS Backup Manifest ==="
        echo "Created: $(date)"
        echo "Hostname: $(hostname)"
        echo ""
        echo "=== Contents ==="
        find . -type d -maxdepth 2 | sort
        echo ""
        echo "=== File Count ==="
        find . -type f | wc -l
        echo ""
        echo "=== Total Size ==="
        du -sh .
    } > MANIFEST.txt
    
    # Erstelle Restore-Script
    cat > RESTORE.sh << 'EOF'
#!/bin/bash
# VPS Backup Restore Script
# Automatisch generiert

set -e

echo "=== VPS Backup Restore ==="
echo "Dieses Script hilft bei der Wiederherstellung"
echo ""

# Funktion zum Wiederherstellen von Datenbanken
restore_databases() {
    echo "Stelle Datenbanken wieder her..."
    
    # PostgreSQL
    for file in databases/*_postgres.sql.gz; do
        if [[ -f "$file" ]]; then
            container=$(basename "$file" | sed 's/_postgres.sql.gz//')
            echo "Restore PostgreSQL: $container"
            gunzip -c "$file" | docker exec -i "$container" psql -U postgres
        fi
    done
    
    # MySQL
    for file in databases/*_mysql.sql.gz; do
        if [[ -f "$file" ]]; then
            container=$(basename "$file" | sed 's/_mysql.sql.gz//')
            echo "Restore MySQL: $container"
            gunzip -c "$file" | docker exec -i "$container" mysql -uroot
        fi
    done
}

# Funktion zum Wiederherstellen von Volumes
restore_volumes() {
    echo "Stelle Docker Volumes wieder her..."
    
    for file in volumes/*.tar.gz; do
        if [[ -f "$file" ]]; then
            volume=$(basename "$file" .tar.gz)
            echo "Restore Volume: $volume"
            docker run --rm -v "$volume:/restore" -v "$(pwd):/backup:ro" \
                alpine tar xzf "/backup/volumes/$(basename "$file")" -C /restore
        fi
    done
}

# Hauptmenü
echo "Was möchten Sie wiederherstellen?"
echo "1) Datenbanken"
echo "2) Docker Volumes"
echo "3) Alles"
echo "4) Beenden"

read -p "Auswahl: " choice

case $choice in
    1) restore_databases ;;
    2) restore_volumes ;;
    3) restore_databases && restore_volumes ;;
    4) exit 0 ;;
    *) echo "Ungültige Auswahl" ;;
esac

echo "Wiederherstellung abgeschlossen!"
EOF
    
    chmod +x RESTORE.sh
    
    # Komprimiere Backup
    local archive_name="${BACKUP_DIR}/${BACKUP_NAME}.tar.gz"
    
    if [[ "$COMPRESS_BACKUP" == "true" ]]; then
        log "INFO" "Komprimiere Backup..."
        tar czf "$archive_name" . || {
            log "ERROR" "Kompression fehlgeschlagen"
            return 1
        }
    else
        log "INFO" "Erstelle unkomprimiertes Archiv..."
        tar cf "${BACKUP_DIR}/${BACKUP_NAME}.tar" . || {
            log "ERROR" "Archivierung fehlgeschlagen"
            return 1
        }
        archive_name="${BACKUP_DIR}/${BACKUP_NAME}.tar"
    fi
    
    # Verschlüsselung (optional)
    if [[ "$ENCRYPT_BACKUP" == "true" ]] && [[ -n "$ENCRYPTION_KEY" ]]; then
        log "INFO" "Verschlüssele Backup..."
        openssl enc -aes-256-cbc -salt -in "$archive_name" -out "${archive_name}.enc" -k "$ENCRYPTION_KEY" && \
            rm "$archive_name" && \
            archive_name="${archive_name}.enc"
    fi
    
    local backup_size=$(get_backup_size "$archive_name")
    log "SUCCESS" "Backup erstellt: $archive_name (Größe: $backup_size)"
    
    echo "$archive_name"
}

# =====================================
# Remote Backup
# =====================================
upload_to_remote() {
    local local_file="$1"
    
    if [[ "$REMOTE_BACKUP" != "true" ]]; then
        return 0
    fi
    
    if [[ -z "$REMOTE_HOST" ]] || [[ -z "$REMOTE_USER" ]] || [[ -z "$REMOTE_PATH" ]]; then
        log "WARNING" "Remote-Backup konfiguriert aber Verbindungsdaten fehlen"
        return 1
    fi
    
    log "INFO" "Lade Backup auf Remote-Server hoch..."
    
    if scp "$local_file" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/" 2>/dev/null; then
        log "SUCCESS" "Backup auf Remote-Server übertragen"
        
        # Alte Remote-Backups löschen
        ssh "${REMOTE_USER}@${REMOTE_HOST}" \
            "find ${REMOTE_PATH} -name 'vps-backup-*.tar.gz*' -mtime +${KEEP_REMOTE_DAYS} -delete" 2>/dev/null || true
    else
        log "ERROR" "Remote-Upload fehlgeschlagen"
        return 1
    fi
}

# =====================================
# Cleanup alte Backups
# =====================================
cleanup_old_backups() {
    log "INFO" "Räume alte Backups auf..."
    
    # Lokale Backups
    find "$BACKUP_DIR" -name "vps-backup-*.tar.gz*" -mtime +$KEEP_LOCAL_DAYS -delete 2>/dev/null && \
        log "SUCCESS" "Alte lokale Backups gelöscht (älter als ${KEEP_LOCAL_DAYS} Tage)"
    
    # Liste verbleibende Backups
    log "INFO" "Verbleibende Backups:"
    ls -lh "$BACKUP_DIR"/vps-backup-*.tar.gz* 2>/dev/null | tail -5
}

# =====================================
# Hauptprogramm
# =====================================
main() {
    echo ""
    echo "========================================="
    echo "     $SCRIPT_NAME"
    echo "========================================="
    echo ""
    
    log "INFO" "=== Backup gestartet ==="
    
    # Vorbereitung
    check_requirements
    check_disk_space "$BACKUP_DIR" "$MIN_FREE_SPACE_GB"

    # Erstelle temporäres Backup-Verzeichnis
    mkdir -p "$BACKUP_TEMP"
    mkdir -p "$BACKUP_DIR"

    # Backup-Schritte
    if [[ "$BACKUP_SYSTEM" == "true" ]]; then
        backup_system_info
    fi

    if [[ "$BACKUP_DOCKER" == "true" ]]; then
        backup_docker_configs
    fi

    if [[ "$BACKUP_DATABASES" == "true" ]]; then
        backup_databases
    fi

    if [[ "$BACKUP_VOLUMES" == "true" ]]; then
        backup_docker_volumes
    fi

    if [[ "$BACKUP_CONFIGS" == "true" ]]; then
        backup_configs
    fi

    # Archiv erstellen (inkl. Kompression und Verschlüsselung)
    local archive_file
    archive_file=$(create_archive)

    # Alte Backups aufräumen
    cleanup_old_backups

    # Remote-Backup
    if [[ "$REMOTE_BACKUP" == "true" ]]; then
        upload_to_remote "$archive_file"
    fi

    log "SUCCESS" "=== Backup abgeschlossen: $archive_file ==="
    echo ""
}

main "$@"