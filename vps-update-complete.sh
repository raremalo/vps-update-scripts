#!/bin/bash
# vps-update-complete.sh
# VPS Update-Skript mit vollständigem Backup inkl. Anwendungsdaten
# Features: Backup-Integration, Coolify-optimierte Start-Reihenfolge, Soketi-Support, 
#          Intelligente Volume-Sicherung, Datenbank-Dumps

set -euo pipefail

# =====================================
# Konfiguration
# =====================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="/var/log/vps-update.log"
LOCKFILE="/var/run/vps-update.lock"

# Backup-Konfiguration
BACKUP_ENABLED=${VPS_UPDATE_BACKUP_ENABLED:-true}
BACKUP_DIR=${VPS_UPDATE_BACKUP_DIR:-/var/backups/vps-updates}
BACKUP_DOCKER_VOLUMES=${VPS_UPDATE_BACKUP_DOCKER_VOLUMES:-false}
BACKUP_DATABASES=${VPS_UPDATE_BACKUP_DATABASES:-true}
BACKUP_KEEP_DAYS=${VPS_UPDATE_KEEP_BACKUPS:-7}
MIN_FREE_SPACE_MB=${VPS_UPDATE_MIN_FREE_SPACE_MB:-500}
MAX_VOLUME_SIZE_MB=${VPS_UPDATE_MAX_VOLUME_SIZE_MB:-1000}

# =====================================
# Hilfsfunktionen
# =====================================
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOGFILE"
}

# Prüffunktionen für Compose/Container
has_compose_project() {
    docker compose config >/dev/null 2>&1
}

has_compose_service() {
    local svc="$1"
    docker compose config --services 2>/dev/null | grep -qx "$svc"
}

has_container() {
    local name="$1"
    docker ps -a --format '{{.Names}}' | grep -qx "$name"
}

cleanup() {
    rm -f "$LOCKFILE"
}

trap cleanup EXIT

get_free_space_mb() {
    local path="${1:-/}"
    df -m "$path" | awk 'NR==2 {print $4}'
}

get_volume_size_mb() {
    local volume="$1"
    local size=$(docker volume inspect "$volume" --format '{{.Mountpoint}}' 2>/dev/null | xargs du -sm 2>/dev/null | cut -f1)
    echo "${size:-0}"
}

# =====================================
# Backup-Funktionen
# =====================================
backup_databases() {
    local backup_path="$1"
    
    log "INFO" "Sichere Datenbanken..."
    mkdir -p "$backup_path/databases"
    
    # PostgreSQL Backups
    for container in $(docker ps --format '{{.Names}}' | grep -E '(postgres|postgresql|pg)'); do
        log "INFO" "Sichere PostgreSQL: $container"
        docker exec "$container" pg_dumpall -U postgres 2>/dev/null | \
            gzip > "$backup_path/databases/${container}_postgres_$(date +%Y%m%d_%H%M%S).sql.gz" || \
            log "WARNING" "Konnte PostgreSQL $container nicht sichern"
    done
    
    # MySQL/MariaDB Backups
    for container in $(docker ps --format '{{.Names}}' | grep -E '(mysql|mariadb)'); do
        log "INFO" "Sichere MySQL/MariaDB: $container"
        docker exec "$container" mysqldump --all-databases --single-transaction 2>/dev/null | \
            gzip > "$backup_path/databases/${container}_mysql_$(date +%Y%m%d_%H%M%S).sql.gz" || \
            log "WARNING" "Konnte MySQL $container nicht sichern"
    done
    
    # Redis Backups
    for container in $(docker ps --format '{{.Names}}' | grep -E '(redis)'); do
        log "INFO" "Sichere Redis: $container"
        docker exec "$container" redis-cli BGSAVE 2>/dev/null || true
        sleep 2
        docker cp "$container:/data/dump.rdb" "$backup_path/databases/${container}_redis_$(date +%Y%m%d_%H%M%S).rdb" 2>/dev/null || \
            log "WARNING" "Konnte Redis $container nicht sichern"
    done
    
    # Coolify-spezifische Datenbank
    if docker ps | grep -q "coolify-db"; then
        log "INFO" "Sichere Coolify-Datenbank..."
        docker exec coolify-db pg_dumpall -U postgres 2>/dev/null | \
            gzip > "$backup_path/databases/coolify_db_$(date +%Y%m%d_%H%M%S).sql.gz" || \
            log "WARNING" "Konnte Coolify-DB nicht sichern"
    fi
}

create_backup() {
    if [[ "$BACKUP_ENABLED" != "true" ]]; then
        log "INFO" "Backup ist deaktiviert (VPS_UPDATE_BACKUP_ENABLED=false)"
        return 0
    fi
    
    log "INFO" "Erstelle vollständiges Backup vor Update..."
    
    # Prüfe freien Speicherplatz
    local free_space=$(get_free_space_mb "$BACKUP_DIR")
    if [[ $free_space -lt $MIN_FREE_SPACE_MB ]]; then
        log "ERROR" "Nicht genug Speicherplatz für Backup (${free_space}MB < ${MIN_FREE_SPACE_MB}MB)"
        return 1
    fi
    
    # Erstelle Backup-Verzeichnis
    local backup_name="backup-$(date +%Y%m%d_%H%M%S)"
    local backup_path="${BACKUP_DIR}/${backup_name}"
    mkdir -p "$backup_path"
    
    # 1. System-Informationen
    log "INFO" "Sichere System-Informationen..."
    {
        echo "=== VPS Backup ==="
        echo "Datum: $(date)"
        echo "Hostname: $(hostname)"
        echo "Kernel: $(uname -r)"
        echo "Distribution: $(lsb_release -d 2>/dev/null || echo 'Unbekannt')"
        echo ""
        echo "=== Docker Info ==="
        docker version 2>/dev/null || echo "Docker nicht installiert"
        echo ""
        echo "=== Disk Usage ==="
        df -h
        echo ""
        echo "=== Memory ==="
        free -h
    } > "$backup_path/system-info.txt"
    
    # 2. APT-Pakete und Quellen
    log "INFO" "Sichere APT-Konfiguration..."
    dpkg --get-selections > "$backup_path/dpkg-selections.txt"
    apt list --installed > "$backup_path/apt-installed.txt" 2>/dev/null
    mkdir -p "$backup_path/apt-sources"
    cp -r /etc/apt/sources.list* "$backup_path/apt-sources/" 2>/dev/null || true
    
    # 3. Docker-Container-Konfigurationen
    log "INFO" "Sichere Docker-Container-Konfigurationen..."
    mkdir -p "$backup_path/docker"
    docker ps -a --format json > "$backup_path/docker/containers.json"
    for container in $(docker ps -a --format '{{.Names}}'); do
        docker inspect "$container" > "$backup_path/docker/${container}-inspect.json" 2>/dev/null || true
    done
    
    # 4. Coolify-spezifische Konfiguration
    if [[ -d "/data/coolify" ]]; then
        log "INFO" "Sichere Coolify-Konfiguration..."
        mkdir -p "$backup_path/coolify"
        cp -r /data/coolify/source/.env* "$backup_path/coolify/" 2>/dev/null || true
        cp -r /data/coolify/source/docker-compose* "$backup_path/coolify/" 2>/dev/null || true
    fi
    
    # 5. Datenbank-Backups
    if [[ "$BACKUP_DATABASES" == "true" ]]; then
        backup_databases "$backup_path"
    fi
    
    # 6. Docker Volumes (kritische Daten)
    if [[ "$BACKUP_DOCKER_VOLUMES" == "true" ]]; then
        log "INFO" "Sichere Docker Volumes..."
        mkdir -p "$backup_path/docker-volumes"
        
        # Liste kritischer Volumes
        local critical_volumes=(
            "coolify-db"
            "coolify-redis"
            "coolify-data"
        )
        
        # Sichere kritische Volumes
        for volume in "${critical_volumes[@]}"; do
            if docker volume inspect "$volume" &>/dev/null; then
                local volume_size=$(get_volume_size_mb "$volume")
                if [[ $volume_size -lt $MAX_VOLUME_SIZE_MB ]]; then
                    log "INFO" "Sichere Volume: $volume (${volume_size}MB)"
                    docker run --rm -v "$volume:/data" -v "$backup_path/docker-volumes:/backup" \
                        alpine tar czf "/backup/${volume}.tar.gz" -C /data . 2>/dev/null || \
                        log "WARNING" "Konnte Volume $volume nicht sichern"
                else
                    log "INFO" "Überspringe großes Volume: $volume (${volume_size}MB)"
                fi
            fi
        done
        
        # Erstelle Volume-Manifest
        docker volume ls --format json > "$backup_path/docker-volumes/volumes-manifest.json"
    fi
    
    # 7. Erstelle Restore-Guide
    cat > "$backup_path/RESTORE_GUIDE.txt" << EOF
=== VPS Restore Guide ===

Dieses Backup wurde erstellt am: $(date)

Wiederherstellung:

1. System-Pakete wiederherstellen:
   dpkg --set-selections < dpkg-selections.txt
   apt-get dselect-upgrade

2. PostgreSQL wiederherstellen:
   gunzip -c databases/postgres_*.sql.gz | docker exec -i [container] psql -U postgres

3. MySQL wiederherstellen:
   gunzip -c databases/mysql_*.sql.gz | docker exec -i [container] mysql -uroot -p

4. Redis wiederherstellen:
   docker cp databases/[container]_redis_*.rdb [container]:/data/dump.rdb
   docker exec [container] redis-cli SHUTDOWN SAVE

5. Docker Volumes wiederherstellen:
   docker run --rm -v [volume]:/data -v \$(pwd):/backup alpine tar xzf /backup/[volume].tar.gz -C /data

6. Coolify wiederherstellen:
   cp -r coolify/.env* /data/coolify/source/
   cd /data/coolify/source
   docker compose down
   docker compose up -d

Wichtig: Führen Sie die Wiederherstellung in der angegebenen Reihenfolge durch!
EOF
    
    # 8. Komprimiere gesamtes Backup
    log "INFO" "Komprimiere Backup..."
    cd "$BACKUP_DIR"
    tar czf "${backup_name}.tar.gz" "$backup_name/"
    rm -rf "$backup_name/"
    
    # 9. Alte Backups aufräumen
    log "INFO" "Räume alte Backups auf (behalte ${BACKUP_KEEP_DAYS} Tage)..."
    find "$BACKUP_DIR" -name "backup-*.tar.gz" -mtime +$BACKUP_KEEP_DAYS -delete || true
    
    log "SUCCESS" "Vollständiges Backup erstellt: ${BACKUP_DIR}/${backup_name}.tar.gz"
    log "INFO" "Backup-Größe: $(du -h "${BACKUP_DIR}/${backup_name}.tar.gz" | cut -f1)"
}

# =====================================
# Update-Funktionen
# =====================================
check_prerequisites() {
    # Root-Check
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "Dieses Skript muss als root ausgeführt werden"
        exit 1
    fi

    # Lock-File Check
    if [[ -f "$LOCKFILE" ]]; then
        log "ERROR" "Update läuft bereits (Lockfile: $LOCKFILE)"
        exit 1
    fi
    
    touch "$LOCKFILE"
}

stop_docker_containers() {
    log "INFO" "Stoppe Docker-Container..."
    
    # Coolify-spezifische Reihenfolge
    if docker ps | grep -q coolify; then
        log "INFO" "Coolify erkannt - stoppe in korrekter Reihenfolge..."
        
        # Stoppe zuerst Projekte und Proxy
        docker stop coolify-proxy 2>/dev/null || true
        
        # Dann Hauptcontainer
        docker stop coolify 2>/dev/null || true
        
        # Dann Soketi
        docker stop coolify-realtime 2>/dev/null || true
        
        # Zuletzt Datenbank und Redis
        docker stop coolify-redis 2>/dev/null || true
        docker stop coolify-db 2>/dev/null || true
    fi
    
    # Stoppe alle anderen Container
    local containers=$(docker ps -q)
    if [[ -n "$containers" ]]; then
        log "INFO" "Stoppe verbleibende Container..."
        docker stop $containers || true
    fi
    
    log "SUCCESS" "Alle Container gestoppt"
}

update_system() {
    log "INFO" "Starte System-Updates..."
    
    # Update Paketlisten
    apt-get update || {
        log "ERROR" "apt-get update fehlgeschlagen"
        return 1
    }
    
    # Halte problematische Pakete zurück
    log "INFO" "Halte problematische Pakete zurück..."
    apt-mark hold snapd ubuntu-advantage-tools 2>/dev/null || true
    
    # Führe Updates durch
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || {
        log "ERROR" "apt-get upgrade fehlgeschlagen"
        return 1
    }
    
    # Kernel-Updates
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y || {
        log "ERROR" "apt-get dist-upgrade fehlgeschlagen"
        return 1
    }
    
    # Aufräumen
    apt-get autoremove -y
    apt-get autoclean
    
    log "SUCCESS" "System-Updates abgeschlossen"
}

start_coolify_stack() {
    if [[ ! -d "/data/coolify/source" ]]; then
        log "INFO" "Coolify nicht installiert"
        return 0
    fi
    
    log "INFO" "Starte Coolify-Stack in korrekter Reihenfolge..."
    cd /data/coolify/source

    if has_compose_project; then
        # 1. Datenbank und Cache zuerst
        log "INFO" "Starte Datenbank und Redis..."
        docker compose up -d coolify-db coolify-redis || log "WARNING" "Compose: DB/Redis Start meldete Fehler"
        sleep 10  # Warte auf Initialisierung
        
        # 2. Realtime/Soketi als nächstes (nur wenn als Service vorhanden)
        if has_compose_service "coolify-realtime"; then
            log "INFO" "Starte Realtime-Service (coolify-realtime)..."
            docker compose up -d coolify-realtime || log "WARNING" "Compose: coolify-realtime Start meldete Fehler"
            sleep 5
        elif has_compose_service "soketi"; then
            log "INFO" "Starte Legacy Realtime-Service (soketi)..."
            docker compose up -d soketi || log "WARNING" "Compose: soketi Start meldete Fehler"
            sleep 5
        else
            log "INFO" "Kein Realtime-Service (coolify-realtime/soketi) in Compose gefunden"
        fi
        
        # 3. Hauptcontainer
        log "INFO" "Starte Coolify Hauptcontainer..."
        docker compose up -d coolify || log "WARNING" "Compose: coolify Start meldete Fehler"
        sleep 10
        
        # 4. Proxy zuletzt
        log "INFO" "Starte Coolify Proxy..."
        docker compose up -d coolify-proxy || log "WARNING" "Compose: Proxy Start meldete Fehler"
    else
        # Fallback: Ungültiges Compose-Projekt – Container direkt starten
        log "WARNING" "Compose-Projekt ungültig – starte Container direkt per docker start"
        docker start coolify-db coolify-redis 2>/dev/null || true
        sleep 10
        if has_container "coolify-realtime"; then
            log "INFO" "Starte Container coolify-realtime (Fallback)"
            docker start coolify-realtime 2>/dev/null || true
            sleep 5
        elif has_container "soketi"; then
            log "INFO" "Starte Container soketi (Fallback)"
            docker start soketi 2>/dev/null || true
            sleep 5
        fi
        log "INFO" "Starte Coolify Hauptcontainer (Fallback)"
        docker start coolify 2>/dev/null || true
        sleep 10
        log "INFO" "Starte Coolify Proxy (Fallback)"
        docker start coolify-proxy 2>/dev/null || true
    fi
    
    # Verifiziere, dass alle Services laufen
    sleep 5
    local services=("coolify-db" "coolify-redis" "coolify" "coolify-proxy")
    if has_container "coolify-realtime"; then
        services=("coolify-db" "coolify-redis" "coolify-realtime" "coolify" "coolify-proxy")
    fi
    for service in "${services[@]}"; do
        if docker ps | grep -q "$service"; then
            log "SUCCESS" "✓ $service läuft"
        else
            log "WARNING" "✗ $service läuft nicht!"
        fi
    done
}

start_other_containers() {
    log "INFO" "Starte andere Container mit Autostart..."
    
    docker ps -a --format '{{.Names}}' | grep -v "^coolify" | while read -r container; do
        if [[ -n "$container" ]]; then
            local restart_policy=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$container" 2>/dev/null)
            
            if [[ "$restart_policy" == "always" ]] || [[ "$restart_policy" == "unless-stopped" ]]; then
                log "INFO" "Starte Container: $container"
                docker start "$container" || log "WARNING" "Fehler beim Starten von $container"
            fi
        fi
    done
    
    log "SUCCESS" "Container-Start abgeschlossen"
}

check_reboot_required() {
    if [[ -f /var/run/reboot-required ]]; then
        log "WARNING" "Neustart erforderlich!"
        log "INFO" "Starte Neustart in 30 Sekunden..."
        log "INFO" "Drücken Sie Ctrl+C zum Abbrechen"
        sleep 30
        log "INFO" "Starte Neustart..."
        reboot
    else
        log "INFO" "Kein Neustart erforderlich"
    fi
}

# =====================================
# Hauptprogramm
# =====================================
main() {
    log "INFO" "=== VPS Update mit vollständigem Backup gestartet ==="
    
    # Voraussetzungen prüfen
    check_prerequisites
    
    # Vollständiges Backup erstellen
    create_backup
    
    # Docker-Container stoppen
    stop_docker_containers
    
    # System aktualisieren
    update_system
    
    # Coolify-Stack starten
    start_coolify_stack
    
    # Andere Container starten
    start_other_containers
    
    # Reboot prüfen
    check_reboot_required
    
    log "SUCCESS" "=== VPS Update abgeschlossen ==="
}

# Skript ausführen
main "$@"