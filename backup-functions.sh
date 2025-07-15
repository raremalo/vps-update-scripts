#!/usr/bin/env bash
# ==============================================================
# Backup-Funktionen für VPS-Update-Script
# ==============================================================

# Konfigurierbare Variablen
BACKUP_DIR="${VPS_UPDATE_BACKUP_DIR:-/var/backups/vps-updates}"
BACKUP_DOCKER_VOLUMES="${VPS_UPDATE_BACKUP_DOCKER_VOLUMES:-false}"
MIN_FREE_SPACE_MB="${VPS_UPDATE_MIN_FREE_SPACE_MB:-500}"

# Funktion: Backup-Verzeichnis erstellen und prüfen
create_backup_dir() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="${BACKUP_DIR}/${timestamp}"
    
    # Prüfe Schreibrechte
    if [[ ! -w "${BACKUP_DIR%/*}" ]]; then
        err "Keine Schreibrechte für Backup-Verzeichnis: ${BACKUP_DIR%/*}"
        return 1
    fi
    
    # Erstelle Backup-Verzeichnis
    if ! mkdir -p "$backup_path"; then
        err "Konnte Backup-Verzeichnis nicht erstellen: $backup_path"
        return 1
    fi
    
    echo "$backup_path"
}

# Funktion: Freien Speicherplatz prüfen (robust)
check_free_space() {
    local path="${1:-/}"
    
    # Sicherstellen, dass das Verzeichnis existiert, bevor wir es prüfen
    if ! mkdir -p "$path"; then
        err "Konnte Pfad für Speicherplatzprüfung nicht erstellen: $path"
        return 1
    fi
    
    local free_space_mb
    free_space_mb=$(df -m "$path" | awk 'NR==2 {print $4}')
    
    if [[ -z "$free_space_mb" ]] || [[ ! "$free_space_mb" =~ ^[0-9]+$ ]]; then
        err "Konnte freien Speicherplatz nicht ermitteln."
        return 1
    fi

    if [[ $free_space_mb -lt $MIN_FREE_SPACE_MB ]]; then
        err "Unzureichender Speicherplatz: ${free_space_mb}MB frei (benötigt: ${MIN_FREE_SPACE_MB}MB)"
        return 1
    fi
    
    log "Freier Speicherplatz: ${free_space_mb}MB" "$BLUE"
    return 0
}

# Funktion: dpkg-Paketliste sichern
backup_dpkg_packages() {
    local backup_path="$1"
    local dpkg_file="${backup_path}/dpkg-selections.txt"
    
    log "Sichere dpkg-Paketliste ..." "$BLUE"
    
    if dpkg --get-selections > "$dpkg_file" 2>/dev/null; then
        log "✓ dpkg-Paketliste gesichert: $dpkg_file" "$GREEN"
        # Zusätzlich installierte Pakete mit Versionen speichern
        dpkg -l | grep "^ii" > "${backup_path}/dpkg-installed-versions.txt" 2>/dev/null || true
        return 0
    else
        err "✗ Fehler beim Sichern der dpkg-Paketliste"
        return 1
    fi
}

# Funktion: APT-Sources sichern
backup_apt_sources() {
    local backup_path="$1"
    local sources_dir="${backup_path}/apt-sources"
    
    log "Sichere APT-Sources ..." "$BLUE"
    
    mkdir -p "$sources_dir"
    
    # Hauptdatei sources.list
    if [[ -f /etc/apt/sources.list ]]; then
        cp -p /etc/apt/sources.list "$sources_dir/" 2>/dev/null || {
            err "✗ Fehler beim Kopieren von sources.list"
            return 1
        }
    fi
    
    # Zusätzliche Sources aus sources.list.d/
    if [[ -d /etc/apt/sources.list.d ]]; then
        cp -rp /etc/apt/sources.list.d/* "$sources_dir/" 2>/dev/null || true
    fi
    
    # APT-Keys sichern
    if command -v apt-key &>/dev/null; then
        apt-key exportall > "${sources_dir}/apt-keys.asc" 2>/dev/null || true
    fi
    
    log "✓ APT-Sources gesichert: $sources_dir" "$GREEN"
    return 0
}

# Funktion: Docker-Container und -Konfiguration sichern
backup_docker_info() {
    local backup_path="$1"
    local docker_dir="${backup_path}/docker"
    
    if ! command -v docker &>/dev/null; then
        log "Docker nicht installiert – überspringe Docker-Backup" "$YELLOW"
        return 0
    fi
    
    log "Sichere Docker-Informationen ..." "$BLUE"
    
    mkdir -p "$docker_dir"
    
    # Container-Liste
    docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" \
        > "${docker_dir}/container-list.txt" 2>/dev/null || {
        err "✗ Fehler beim Abrufen der Container-Liste"
        return 1
    }
    
    # Detaillierte Container-Informationen
    local container_ids=$(docker ps -aq 2>/dev/null || true)
    if [[ -n $container_ids ]]; then
        for container_id in $container_ids; do
            local container_name=$(docker inspect -f '{{.Name}}' "$container_id" 2>/dev/null | sed 's/^\///')
            if [[ -n $container_name ]]; then
                docker inspect "$container_id" > "${docker_dir}/inspect-${container_name}.json" 2>/dev/null || true
            fi
        done
    fi
    
    # Docker-Compose-Dateien sichern (falls vorhanden)
    local compose_files=(
        "/opt/coolify/docker-compose.yml"
        "/opt/coolify/docker-compose.prod.yml"
        "/root/docker-compose.yml"
        "/home/*/docker-compose.yml"
    )
    
    for compose_file in "${compose_files[@]}"; do
        if [[ -f $compose_file ]]; then
            local filename=$(basename "$compose_file")
            local dirname=$(dirname "$compose_file" | sed 's/\//_/g')
            cp -p "$compose_file" "${docker_dir}/compose-${dirname}-${filename}" 2>/dev/null || true
        fi
    done
    
    # Docker-Netzwerke
    docker network ls > "${docker_dir}/networks.txt" 2>/dev/null || true
    
    # Docker-Images
    docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}" \
        > "${docker_dir}/images.txt" 2>/dev/null || true
    
    log "✓ Docker-Informationen gesichert: $docker_dir" "$GREEN"
    return 0
}

# Funktion: Docker-Volumes sichern (optional)
backup_docker_volumes() {
    local backup_path="$1"
    local volumes_dir="${backup_path}/docker-volumes"
    
    if [[ "$BACKUP_DOCKER_VOLUMES" != "true" ]]; then
        log "Docker-Volume-Backup deaktiviert (VPS_UPDATE_BACKUP_DOCKER_VOLUMES != true)" "$YELLOW"
        return 0
    fi
    
    if ! command -v docker &>/dev/null; then
        return 0
    fi
    
    log "Sichere Docker-Volumes ..." "$BLUE"
    
    mkdir -p "$volumes_dir"
    
    # Volume-Liste
    docker volume ls --format "table {{.Name}}\t{{.Driver}}\t{{.Scope}}" \
        > "${volumes_dir}/volume-list.txt" 2>/dev/null || true
    
    # Warnung für große Volumes
    log "WARNUNG: Volume-Backup kann viel Speicherplatz benötigen!" "$YELLOW"
    
    # Volumes exportieren (nur kleine Volumes)
    local max_volume_size_mb="${VPS_UPDATE_MAX_VOLUME_SIZE_MB:-100}"
    local volume_names=$(docker volume ls -q 2>/dev/null || true)
    
    if [[ -n $volume_names ]]; then
        for volume_name in $volume_names; do
            # Prüfe Volume-Größe (grobe Schätzung)
            local volume_path=$(docker volume inspect -f '{{.Mountpoint}}' "$volume_name" 2>/dev/null || true)
            if [[ -n $volume_path ]] && [[ -d $volume_path ]]; then
                local volume_size_mb=$(du -sm "$volume_path" 2>/dev/null | cut -f1 || echo "0")
                
                if [[ $volume_size_mb -le $max_volume_size_mb ]]; then
                    log "  Exportiere Volume $volume_name (${volume_size_mb}MB) ..." "$BLUE"
                    tar -czf "${volumes_dir}/${volume_name}.tar.gz" -C "$volume_path" . 2>/dev/null || {
                        err "  ✗ Fehler beim Exportieren von Volume $volume_name"
                    }
                else
                    log "  ⚠ Volume $volume_name übersprungen (${volume_size_mb}MB > ${max_volume_size_mb}MB)" "$YELLOW"
                fi
            fi
        done
    fi
    
    log "✓ Docker-Volumes gesichert: $volumes_dir" "$GREEN"
    return 0
}

# Funktion: Systeminfo sichern
backup_system_info() {
    local backup_path="$1"
    local info_file="${backup_path}/system-info.txt"
    
    log "Sichere System-Informationen ..." "$BLUE"
    
    {
        echo "=== System-Informationen ==="
        echo "Hostname: $(hostname)"
        echo "Datum: $(date)"
        echo "Kernel: $(uname -r)"
        echo "Distribution: $(lsb_release -d 2>/dev/null | cut -f2 || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2)"
        echo "Uptime: $(uptime)"
        echo ""
        echo "=== Speicherplatz ==="
        df -h
        echo ""
        echo "=== Arbeitsspeicher ==="
        free -h
        echo ""
        echo "=== Aktive Services ==="
        systemctl list-units --type=service --state=running --no-pager
    } > "$info_file" 2>/dev/null
    
    log "✓ System-Informationen gesichert: $info_file" "$GREEN"
    return 0
}

# Hauptfunktion: Komplettes Backup durchführen
perform_backup() {
    log "======== Starte Backup vor Update ========" "$GREEN"
    
    # Prüfe freien Speicherplatz
    if ! check_free_space "$BACKUP_DIR"; then
        err "Backup abgebrochen wegen unzureichendem Speicherplatz"
        return 1
    fi
    
    # Erstelle Backup-Verzeichnis
    local backup_path=$(create_backup_dir)
    if [[ -z $backup_path ]]; then
        err "Backup abgebrochen – konnte Verzeichnis nicht erstellen"
        return 1
    fi
    
    log "Backup-Verzeichnis: $backup_path" "$BLUE"
    
    # Führe Backups durch
    local backup_success=true
    
    backup_system_info "$backup_path" || backup_success=false
    backup_dpkg_packages "$backup_path" || backup_success=false
    backup_apt_sources "$backup_path" || backup_success=false
    backup_docker_info "$backup_path" || backup_success=false
    backup_docker_volumes "$backup_path" || true  # Optional, Fehler nicht kritisch
    
    # Erstelle README
    cat > "${backup_path}/README.txt" <<EOF
VPS Update Backup
=================
Erstellt: $(date)
Host: $(hostname)

Dieses Backup wurde automatisch vor einem System-Update erstellt.

Inhalt:
- system-info.txt: Allgemeine Systeminformationen
- dpkg-selections.txt: Liste aller installierten Pakete
- dpkg-installed-versions.txt: Installierte Pakete mit Versionen
- apt-sources/: APT-Paketquellen und Schlüssel
- docker/: Docker-Container-Konfigurationen und -Listen
- docker-volumes/: Docker-Volume-Backups (falls aktiviert)

Wiederherstellung:
- dpkg: dpkg --set-selections < dpkg-selections.txt && apt-get dselect-upgrade
- APT-Sources: cp -r apt-sources/* /etc/apt/
- Docker: Nutze die JSON-Dateien als Referenz für die Neuerstellung
EOF
    
    # Setze Berechtigungen
    chmod -R 600 "$backup_path"
    chmod 700 "$backup_path"
    
    if $backup_success; then
        log "======== Backup erfolgreich abgeschlossen ========" "$GREEN"
        log "Backup gespeichert unter: $backup_path" "$BLUE"
        
        # Alte Backups aufräumen (behalte nur die letzten N Backups)
        cleanup_old_backups
        
        return 0
    else
        err "======== Backup mit Fehlern abgeschlossen ========"
        err "Einige Backup-Komponenten konnten nicht gesichert werden"
        return 1
    fi
}

# Funktion: Alte Backups aufräumen
cleanup_old_backups() {
    local keep_backups="${VPS_UPDATE_KEEP_BACKUPS:-5}"
    
    if [[ ! -d $BACKUP_DIR ]]; then
        return 0
    fi
    
    local backup_count=$(find "$BACKUP_DIR" -maxdepth 1 -type d -name "[0-9]*_[0-9]*" | wc -l)
    
    if [[ $backup_count -gt $keep_backups ]]; then
        log "Räume alte Backups auf (behalte die letzten $keep_backups) ..." "$BLUE"
        
        # Lösche die ältesten Backups
        find "$BACKUP_DIR" -maxdepth 1 -type d -name "[0-9]*_[0-9]*" | \
            sort | \
            head -n -"$keep_backups" | \
            while read -r old_backup; do
                log "  Lösche altes Backup: $(basename "$old_backup")" "$YELLOW"
                rm -rf "$old_backup"
            done
    fi
}

# Export der Hauptfunktion
export -f perform_backup
