#!/usr/bin/env bash
# vps-update-auto.sh
# Intelligentes VPS Update-Skript das automatisch Coolify oder Dokploy erkennt
# Version 2.1

set -euo pipefail

# =====================================
# Konfiguration
# =====================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="/var/log/vps-update.log"
LOCKFILE="/var/run/vps-update.lock"

# Apt-Lock: Maximale Wartezeit in Sekunden (Standard: 5 Minuten)
APT_LOCK_WAIT="${APT_LOCK_WAIT:-300}"
APT_LOCK_INTERVAL=10

# Log-Rotation: Maximale Loggröße in Bytes (Standard: 1MB)
LOG_MAX_SIZE="${LOG_MAX_SIZE:-1048576}"

# Reboot: Countdown in Sekunden (Standard: 60)
REBOOT_DELAY="${REBOOT_DELAY:-60}"

# Reboot: Tage, ab denen ein ausstehender Reboot den Lauf als nicht
# erfolgreich meldet (gleiche Schwelle wie in vps-status). Rebootet wird
# dadurch NICHT — das Terminal-Gate bleibt unangetastet.
REBOOT_OVERDUE_DAYS="${REBOOT_OVERDUE_DAYS:-7}"

# Disk: Mindestfreier Speicher in MB (Standard: 500MB)
DISK_MIN_FREE_MB="${DISK_MIN_FREE_MB:-500}"

# Docker Cleanup: Alte Images älter als X Tage entfernen (Standard: 30)
DOCKER_CLEANUP_DAYS="${DOCKER_CLEANUP_DAYS:-30}"

# Docker Cleanup: dangling Volumes löschen ist Opt-in (Standard: false = nur messen)
DOCKER_PRUNE_VOLUMES="${DOCKER_PRUNE_VOLUMES:-false}"

# Docker Cleanup: Freiplatz-Warnschwelle auf dem Dateisystem von /var/lib/docker.
# Unterschreitet der freie Platz PCT Prozent ODER MB Megabyte, endet der Lauf
# mit Exit ≠ 0 — gestaffelt über DISK_MIN_FREE_MB, das den Lauf ganz abbricht.
DOCKER_PRUNE_WARN_FREE_PCT="${DOCKER_PRUNE_WARN_FREE_PCT:-10}"
DOCKER_PRUNE_WARN_FREE_MB="${DOCKER_PRUNE_WARN_FREE_MB:-5120}"

# Wird automatisch erkannt
DEPLOYMENT_SYSTEM=""
DEPLOYMENT_PATH=""

# Swarm-Erkennung
IS_SWARM=false

# Dokploy Swarm Service-Namen
DOKPLOY_SVC_POSTGRES=""
DOKPLOY_SVC_REDIS=""
DOKPLOY_SVC_MAIN=""
DOKPLOY_SVC_TRAEFIK=""
declare -A DOKPLOY_SVC_REPLICAS

# Laufzeit-Tracking
SECONDS=0
PHASE_START=0

# =====================================
# Farben
# =====================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# =====================================
# Hilfsfunktionen
# =====================================
log() {
    local level="$1"
    shift
    local color=""
    case "$level" in
        INFO)    color="$BLUE" ;;
        SUCCESS) color="$GREEN" ;;
        WARNING) color="$YELLOW" ;;
        ERROR)   color="$RED" ;;
        PHASE)   color="$CYAN" ;;
    esac
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo -e "${color}${msg}${NC}" | tee -a "$LOGFILE"
}

phase_start() {
    PHASE_START=$SECONDS
}

phase_end() {
    local name="$1"
    local duration=$(( SECONDS - PHASE_START ))
    local mins=$(( duration / 60 ))
    local secs=$(( duration % 60 ))
    if [[ $mins -gt 0 ]]; then
        log "PHASE" "⏱ ${name}: ${mins}m ${secs}s"
    else
        log "PHASE" "⏱ ${name}: ${secs}s"
    fi
}

format_duration() {
    local total=$1
    local mins=$(( total / 60 ))
    local secs=$(( total % 60 ))
    if [[ $mins -gt 0 ]]; then
        echo "${mins}m ${secs}s"
    else
        echo "${secs}s"
    fi
}

rotate_log() {
    if [[ -f "$LOGFILE" ]] && [[ $(stat -c%s "$LOGFILE" 2>/dev/null || stat -f%z "$LOGFILE" 2>/dev/null) -gt "$LOG_MAX_SIZE" ]]; then
        local backup="${LOGFILE}.$(date '+%Y%m%d%H%M%S')"
        mv "$LOGFILE" "$backup"
        gzip "$backup" 2>/dev/null || true
        # Nur die letzten 3 rotierten Logs behalten
        ls -t "${LOGFILE}."*.gz 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
        log "INFO" "Log rotiert"
    fi
}

# Von diesem Lauf NEU gesetzte APT-Holds (Differenz zum Vorzustand aus
# apt-mark showhold). Der EXIT-Trap gibt genau diese Menge wieder frei;
# vorher gehaltene Pakete bleiben unangetastet.
APT_HOLDS_ADDED=""

release_apt_holds() {
    if [[ -n "$APT_HOLDS_ADDED" ]]; then
        # Wortaufspaltung der Paketliste ist gewollt
        # shellcheck disable=SC2086
        if apt-mark unhold $APT_HOLDS_ADDED >/dev/null 2>&1; then
            log "INFO" "APT-Holds wieder freigegeben: ${APT_HOLDS_ADDED}"
        else
            log "WARNING" "APT-Holds nicht freigegeben (bleiben gesetzt): ${APT_HOLDS_ADDED}"
        fi
        APT_HOLDS_ADDED=""
    fi
}

cleanup() {
    release_apt_holds
    rm -f "$LOCKFILE"
}

emergency_restart() {
    log "ERROR" "⚠ Fehler aufgetreten — starte Container als Notfall-Maßnahme neu..."
    start_deployment_stack || true
    start_other_containers || true
    log "WARNING" "Container wurden nach Fehler neu gestartet"
}

trap cleanup EXIT

# =====================================
# Docker Compose Erkennung
# =====================================
DOCKER_COMPOSE=""
detect_docker_compose() {
    if docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE="docker-compose"
    else
        log "WARNING" "Weder 'docker compose' noch 'docker-compose' gefunden (nur docker start verfügbar)"
    fi
    [[ -n "$DOCKER_COMPOSE" ]] && log "INFO" "Docker Compose: $DOCKER_COMPOSE"
}

# =====================================
# Auto-Detection
# =====================================
detect_deployment_system() {
    log "INFO" "Erkenne Deployment-System..."
    
    # Prüfe auf Coolify
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "coolify"; then
        DEPLOYMENT_SYSTEM="coolify"
        
        local coolify_paths=(
            "/data/coolify/source"
            "/opt/coolify/source"
            "/root/coolify/source"
        )
        
        for path in "${coolify_paths[@]}"; do
            if [[ -d "$path" ]] && [[ -f "$path/docker-compose.yml" ]]; then
                DEPLOYMENT_PATH="$path"
                break
            fi
        done
        
        log "SUCCESS" "✓ Coolify erkannt"
        [[ -n "$DEPLOYMENT_PATH" ]] && log "INFO" "  Pfad: $DEPLOYMENT_PATH"
        return 0
    fi
    
    # Prüfe auf Dokploy
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qi "dokploy"; then
        DEPLOYMENT_SYSTEM="dokploy"
        
        # Prüfe Docker Swarm
        local swarm_state
        swarm_state=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "inactive")
        if [[ "$swarm_state" == "active" ]]; then
            IS_SWARM=true
            log "INFO" "  Docker Swarm erkannt"
        fi
        
        local dokploy_paths=(
            "/etc/dokploy"
            "/opt/dokploy"
            "/var/lib/dokploy"
            "/root/dokploy"
        )
        
        for path in "${dokploy_paths[@]}"; do
            if [[ -d "$path" ]] && [[ -f "$path/docker-compose.yml" ]]; then
                DEPLOYMENT_PATH="$path"
                break
            fi
        done
        
        # Erkenne Swarm-Services oder Container-Namen
        detect_dokploy_services
        
        log "SUCCESS" "✓ Dokploy erkannt (Swarm: $IS_SWARM)"
        [[ -n "$DEPLOYMENT_PATH" ]] && log "INFO" "  Pfad: $DEPLOYMENT_PATH"
        return 0
    fi
    
    log "WARNING" "Kein bekanntes Deployment-System gefunden (Coolify/Dokploy)"
    DEPLOYMENT_SYSTEM="none"
}

# =====================================
# Voraussetzungen prüfen
# =====================================
check_prerequisites() {
    # Root-Check
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "Dieses Skript muss als root ausgeführt werden"
        exit 1
    fi

    # Atomic lock
    exec 9>"$LOCKFILE"
    flock -n 9 || { log "ERROR" "Script läuft bereits (Lock: $LOCKFILE)"; exit 1; }
    
    # Log-Rotation
    rotate_log
    
    # Docker Compose erkennen
    detect_docker_compose

    # Erkenne Deployment-System
    detect_deployment_system
}

# =====================================
# Disk Space Check
# =====================================
check_disk_space() {
    phase_start
    log "INFO" "Prüfe freien Speicherplatz..."
    
    local root_free
    root_free=$(df -BM / | awk 'NR==2 {gsub(/M/,""); print $4}')
    
    if [[ $root_free -lt $DISK_MIN_FREE_MB ]]; then
        log "ERROR" "Nur ${root_free}MB frei auf / (Minimum: ${DISK_MIN_FREE_MB}MB)"
        log "ERROR" "Update abgebrochen — zu wenig Speicherplatz!"
        return 1
    fi
    
    log "SUCCESS" "✓ ${root_free}MB frei auf / (Minimum: ${DISK_MIN_FREE_MB}MB)"
    
    # /var prüfen (separates Volume möglich)
    local var_free
    var_free=$(df -BM /var | awk 'NR==2 {gsub(/M/,""); print $4}')
    if [[ $var_free -lt 200 ]]; then
        log "WARNING" "Nur ${var_free}MB frei auf /var — apt könnte Probleme haben"
    fi
    
    phase_end "Disk Space Check"
}

# =====================================
# Docker-Container stoppen
# =====================================
stop_docker_containers() {
    phase_start
    
    log "INFO" "Stoppe Docker-Container..."
    
    case "$DEPLOYMENT_SYSTEM" in
        coolify)
            stop_coolify_containers
            ;;
        dokploy)
            stop_dokploy_containers
            ;;
        *)
            stop_generic_containers
            ;;
    esac
    
    log "SUCCESS" "Container gestoppt"
    phase_end "Container stoppen"
}

stop_coolify_containers() {
    log "INFO" "Stoppe Coolify-Container in korrekter Reihenfolge..."
    
    # 1. Proxy
    docker stop coolify-proxy 2>/dev/null || true
    sleep 2
    
    # 2. Hauptcontainer
    docker stop coolify 2>/dev/null || true
    sleep 2
    
    # 3. Soketi (Realtime)
    docker stop coolify-realtime 2>/dev/null || true
    sleep 2
    
    # 4. Datenbank und Redis
    docker stop coolify-redis 2>/dev/null || true
    docker stop coolify-db 2>/dev/null || true
    sleep 2
}

stop_dokploy_containers() {
    log "INFO" "Stoppe Dokploy in korrekter Reihenfolge..."
    
    if [[ "$IS_SWARM" == "true" ]]; then
        # Docker Swarm: Scale auf 0
        [[ -n "$DOKPLOY_SVC_TRAEFIK" ]] && { log "INFO" "Stoppe $DOKPLOY_SVC_TRAEFIK..."; docker service scale "$DOKPLOY_SVC_TRAEFIK=0" 2>/dev/null || true; }
        sleep 2
        [[ -n "$DOKPLOY_SVC_MAIN" ]] && { log "INFO" "Stoppe $DOKPLOY_SVC_MAIN..."; docker service scale "$DOKPLOY_SVC_MAIN=0" 2>/dev/null || true; }
        sleep 2
        [[ -n "$DOKPLOY_SVC_REDIS" ]] && { log "INFO" "Stoppe $DOKPLOY_SVC_REDIS..."; docker service scale "$DOKPLOY_SVC_REDIS=0" 2>/dev/null || true; }
        [[ -n "$DOKPLOY_SVC_POSTGRES" ]] && { log "INFO" "Stoppe $DOKPLOY_SVC_POSTGRES..."; docker service scale "$DOKPLOY_SVC_POSTGRES=0" 2>/dev/null || true; }
        sleep 3
    else
        # Regulärer Docker
        docker stop dokploy-traefik 2>/dev/null || true
        sleep 2
        docker stop dokploy 2>/dev/null || true
        sleep 2
        docker stop dokploy-redis 2>/dev/null || true
        docker stop dokploy-postgres 2>/dev/null || true
        sleep 2
    fi
}

stop_generic_containers() {
    log "INFO" "Stoppe alle Docker-Container..."
    local containers
    containers=$(docker ps -q)
    if [[ -n "$containers" ]]; then
        docker stop $containers 2>/dev/null || true
    fi
}

# =====================================
# apt mit Lock-Retry
# =====================================
wait_for_apt_lock() {
    local waited=0
    while fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
          fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
          fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        
        if [[ $waited -ge $APT_LOCK_WAIT ]]; then
            log "ERROR" "Apt-Lock konnte nach ${APT_LOCK_WAIT}s nicht erhalten werden"
            return 1
        fi
        
        log "INFO" "Warte auf apt-Lock... (${waited}/${APT_LOCK_WAIT}s)"
        sleep "$APT_LOCK_INTERVAL"
        waited=$((waited + APT_LOCK_INTERVAL))
    done
    log "INFO" "Apt-Lock verfügbar"
}

update_system() {
    phase_start
    
    log "INFO" "Starte System-Updates..."
    
    # Warte auf apt-Lock
    wait_for_apt_lock || return 1
    
    # Update Paketlisten
    log "INFO" "Aktualisiere Paketlisten..."
    apt-get update || {
        log "ERROR" "apt-get update fehlgeschlagen"
        return 1
    }
    
    # Liste aktualisierbarer Pakete
    local upgradable
    upgradable=$(apt list --upgradable 2>/dev/null | grep -v "^Listing" || true)
    
    if [[ -z "$upgradable" ]]; then
        log "INFO" "Keine Paket-Updates verfügbar"
        phase_end "System-Update (keine Updates)"
        return 0
    fi
    
    # Zeige was aktualisiert wird
    local pkg_count
    pkg_count=$(echo "$upgradable" | wc -l)
    log "INFO" "${pkg_count} Pakete werden aktualisiert:"
    echo "$upgradable" | while read -r line; do
        log "INFO" "  → $line"
    done
    
    # Halte problematische Pakete zurück — nur für die Dauer dieses Laufs.
    # Vermerkt wird, was vorher NICHT gehalten war; der EXIT-Trap gibt genau
    # das wieder frei. Ein vom Administrator gesetzter Hold steht im
    # Vorzustand und bleibt damit unangetastet.
    log "INFO" "Halte problematische Pakete zurück..."
    local holds_before pkg
    holds_before=$(apt-mark showhold 2>/dev/null || true)
    for pkg in snapd ubuntu-advantage-tools; do
        grep -qx "$pkg" <<<"$holds_before" || APT_HOLDS_ADDED="${APT_HOLDS_ADDED}${APT_HOLDS_ADDED:+ }${pkg}"
    done
    apt-mark hold snapd ubuntu-advantage-tools 2>/dev/null || true
    
    # Führe Updates durch (nur upgrade, kein dist-upgrade)
    log "INFO" "Führe Paket-Updates durch..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" || {
        log "ERROR" "apt-get upgrade fehlgeschlagen"
        return 1
    }
    
    # Aufräumen
    log "INFO" "Räume alte Pakete auf..."
    apt-get autoremove -y
    apt-get autoclean
    
    log "SUCCESS" "System-Updates abgeschlossen (${pkg_count} Pakete aktualisiert)"
    phase_end "System-Update (${pkg_count} Pakete)"
}

# =====================================
# Docker Cleanup
# =====================================

# Freiplatz-Schwelle: reine Prüf-Logik, ohne Docker testbar.
# Argumente: <frei_mb> <gesamt_mb> <warn_pct> <warn_mb>
# Rückgabe 0 = Schwelle unterschritten, der Lauf soll als nicht erfolgreich enden.
prune_free_space_low() {
    local free_mb=$1 size_mb=$2 warn_pct=$3 warn_mb=$4
    local free_pct=$(( free_mb * 100 / size_mb ))
    [[ $free_pct -lt $warn_pct || $free_mb -lt $warn_mb ]]
}

docker_cleanup() {
    phase_start

    # Konfigurationsfehler: WARNING und überspringen, kein failed-Lauf
    if [[ ! "$DOCKER_CLEANUP_DAYS" =~ ^[1-9][0-9]*$ ]]; then
        log "WARNING" "DOCKER_CLEANUP_DAYS='${DOCKER_CLEANUP_DAYS}' ist keine positive Zahl - Docker Cleanup übersprungen"
        phase_end "Docker Cleanup (übersprungen)"
        return 0
    fi

    # Docker-Filter erwarten Stunden, die Konfiguration ist in Tagen
    local DOCKER_CLEANUP_HOURS=$(( DOCKER_CLEANUP_DAYS * 24 ))

    log "INFO" "Räume Docker auf (Images älter als ${DOCKER_CLEANUP_DAYS} Tage)..."
    
    # Dangling Images (ungetaggt)
    local dangling_count
    dangling_count=$(docker images -f "dangling=true" -q | wc -l)
    if [[ $dangling_count -gt 0 ]]; then
        log "INFO" "  Entferne ${dangling_count} ungetagte Images..."
        docker image prune -f >/dev/null 2>&1 || true
    fi
    
    # Alte Images
    local reclaimed
    reclaimed=$(docker image prune -a --filter "until=${DOCKER_CLEANUP_HOURS}h" -f 2>/dev/null | grep "Total reclaimed space" || true)
    if [[ -n "$reclaimed" ]]; then
        log "SUCCESS" "  $reclaimed"
    else
        log "INFO" "  Keine alten Images zum Entfernen"
    fi
    
    # Build Cache
    docker builder prune -f --filter "until=${DOCKER_CLEANUP_HOURS}h" >/dev/null 2>&1 || true
    
    # Volumes (nur dangling, keine aktiven!) — Löschen ist Opt-in: Coolify und
    # Dokploy erzeugen dangling Volumes laufend, und ob eines davon noch
    # gebraucht wird, kann dieses Skript nicht wissen. Default: nur messen.
    local dangling_volumes vol_size
    dangling_volumes=$(docker volume ls -f "dangling=true" -q | wc -l | tr -d ' ')
    vol_size=$(docker system df --format '{{.Type}}|{{.Reclaimable}}' 2>/dev/null | awk -F'|' '$1 == "Local Volumes" {print $2}')
    if [[ "$DOCKER_PRUNE_VOLUMES" == "true" ]]; then
        if [[ $dangling_volumes -gt 0 ]]; then
            log "INFO" "  Entferne ${dangling_volumes} ungenutzte Volumes..."
            if ! docker volume prune -f >/dev/null 2>&1; then
                log "WARNING" "  Volume-Prune fehlgeschlagen"
            fi
        fi
    else
        log "INFO" "  ${dangling_volumes} dangling Volumes (freigebbar: ${vol_size:-unbekannt}) — Löschen ist Opt-in"
        log "INFO" "  Zum Aufräumen DOCKER_PRUNE_VOLUMES=true setzen (Volume-Prune beim nächsten Lauf)"
    fi
    
    # Docker Disk Usage Summary
    local docker_disk
    docker_disk=$(docker system df --format '{{.Type}}: {{.Size}}' 2>/dev/null || true)
    if [[ -n "$docker_disk" ]]; then
        log "INFO" "  Docker Speicherverbrauch:"
        echo "$docker_disk" | while read -r line; do
            log "INFO" "    $line"
        done
    fi

    # Freiplatz auf dem Dateisystem von /var/lib/docker — der EINZIGE Grund,
    # aus dem dieser Schritt den Lauf als nicht erfolgreich meldet. Die Anzahl
    # dangling Volumes eskaliert bewusst nicht: ihr Wachstum ist mit dem
    # Opt-in-Default beabsichtigt, eine Bestandsschwelle wäre Dauerrauschen.
    local cleanup_rc=0 fs_line fs_size_mb fs_free_mb
    fs_line=$(df -BM /var/lib/docker 2>/dev/null | awk 'NR==2 {gsub(/M/,""); print $2, $4}')
    fs_size_mb=${fs_line%% *}
    fs_free_mb=${fs_line##* }
    if [[ "$fs_size_mb" =~ ^[0-9]+$ && "$fs_free_mb" =~ ^[0-9]+$ && $fs_size_mb -gt 0 ]] \
        && prune_free_space_low "$fs_free_mb" "$fs_size_mb" "$DOCKER_PRUNE_WARN_FREE_PCT" "$DOCKER_PRUNE_WARN_FREE_MB"; then
        log "WARNING" "  Nur ${fs_free_mb}MB frei auf dem Docker-Dateisystem (Schwelle: ${DOCKER_PRUNE_WARN_FREE_PCT}% oder ${DOCKER_PRUNE_WARN_FREE_MB}MB)"
        cleanup_rc=1
    fi

    phase_end "Docker Cleanup"
    return $cleanup_rc
}

# =====================================
# Container starten
# =====================================
start_deployment_stack() {
    phase_start
    
    case "$DEPLOYMENT_SYSTEM" in
        coolify)
            start_coolify_stack
            ;;
        dokploy)
            start_dokploy_stack
            ;;
        *)
            log "INFO" "Kein Deployment-System erkannt, überspringe..."
            ;;
    esac
    
    phase_end "Deployment-Stack starten"
}

start_coolify_stack() {
    log "INFO" "Starte Coolify-Stack in korrekter Reihenfolge..."
    
    # docker start bevorzugt — vermeidet compose-Validierungsfehler
    # Container existieren bereits, müssen nur gestartet werden
    log "INFO" "Starte Datenbank und Redis..."
    docker start coolify-db coolify-redis 2>/dev/null || true
    sleep 10
    
    log "INFO" "Starte Soketi (Realtime Service)..."
    docker start coolify-realtime 2>/dev/null || true
    sleep 10
    
    log "INFO" "Starte Coolify Hauptservice..."
    docker start coolify 2>/dev/null || true
    sleep 10
    
    log "INFO" "Starte Coolify Proxy..."
    docker start coolify-proxy 2>/dev/null || true
    sleep 5
    
    # Verifizierung
    verify_coolify_services
}

verify_coolify_services() {
    log "INFO" "Verifiziere Coolify-Services..."
    
    local all_ok=true
    
    if docker ps --format '{{.Names}}' | grep -qx "coolify-db"; then
        log "SUCCESS" "✓ Coolify Database läuft"
    else
        log "WARNING" "✗ Coolify Database läuft nicht!"
        all_ok=false
    fi

    if docker ps --format '{{.Names}}' | grep -qx "coolify-redis"; then
        log "SUCCESS" "✓ Coolify Redis läuft"
    else
        log "WARNING" "✗ Coolify Redis läuft nicht!"
        all_ok=false
    fi

    if docker ps --format '{{.Names}}' | grep -qx "coolify-realtime"; then
        log "SUCCESS" "✓ Coolify Soketi (Realtime) läuft"
    else
        log "WARNING" "✗ Coolify Soketi läuft nicht!"
        all_ok=false
    fi

    if docker ps --format '{{.Names}}' | grep -qx "coolify"; then
        log "SUCCESS" "✓ Coolify Hauptservice läuft"
    else
        log "ERROR" "✗ Coolify Hauptservice läuft nicht!"
        all_ok=false
    fi

    if docker ps --format '{{.Names}}' | grep -qx "coolify-proxy"; then
        log "SUCCESS" "✓ Coolify Proxy läuft"
    else
        log "WARNING" "✗ Coolify Proxy läuft nicht!"
        all_ok=false
    fi
    
    [[ "$all_ok" == true ]] && log "SUCCESS" "Coolify-Stack vollständig gestartet"
}

start_dokploy_stack() {
    log "INFO" "Starte Dokploy-Stack in korrekter Reihenfolge..."
    
    if [[ "$IS_SWARM" == "true" ]]; then
        # Docker Swarm: Scale Services hoch
        local replicas
        
        # 1. PostgreSQL
        if [[ -n "$DOKPLOY_SVC_POSTGRES" ]]; then
            replicas="${DOKPLOY_SVC_REPLICAS[$DOKPLOY_SVC_POSTGRES]:-1}"
            log "INFO" "Starte PostgreSQL ($DOKPLOY_SVC_POSTGRES)..."
            docker service scale "$DOKPLOY_SVC_POSTGRES=$replicas" 2>/dev/null || true
            sleep 10
        fi
        
        # 2. Redis
        if [[ -n "$DOKPLOY_SVC_REDIS" ]]; then
            replicas="${DOKPLOY_SVC_REPLICAS[$DOKPLOY_SVC_REDIS]:-1}"
            log "INFO" "Starte Redis ($DOKPLOY_SVC_REDIS)..."
            docker service scale "$DOKPLOY_SVC_REDIS=$replicas" 2>/dev/null || true
            sleep 5
        fi
        
        # 3. Hauptservice
        if [[ -n "$DOKPLOY_SVC_MAIN" ]]; then
            replicas="${DOKPLOY_SVC_REPLICAS[$DOKPLOY_SVC_MAIN]:-1}"
            log "INFO" "Starte Dokploy Hauptservice ($DOKPLOY_SVC_MAIN)..."
            docker service scale "$DOKPLOY_SVC_MAIN=$replicas" 2>/dev/null || true
            sleep 25
        fi
        
        # 4. Traefik
        if [[ -n "$DOKPLOY_SVC_TRAEFIK" ]]; then
            replicas="${DOKPLOY_SVC_REPLICAS[$DOKPLOY_SVC_TRAEFIK]:-1}"
            log "INFO" "Starte Traefik ($DOKPLOY_SVC_TRAEFIK)..."
            docker service scale "$DOKPLOY_SVC_TRAEFIK=$replicas" 2>/dev/null || true
            sleep 5
        fi
    else
        # Regulärer Docker
        log "INFO" "Starte PostgreSQL und Redis..."
        docker start dokploy-postgres dokploy-redis 2>/dev/null || true
        sleep 10
        
        log "INFO" "Starte Dokploy Hauptservice..."
        docker start dokploy 2>/dev/null || true
        sleep 10
        
        log "INFO" "Starte Traefik Proxy..."
        docker start dokploy-traefik 2>/dev/null || true
        sleep 5
    fi
    
    # Verifizierung
    verify_dokploy_services
}

verify_dokploy_services() {
    log "INFO" "Verifiziere Dokploy-Services..."
    
    local all_ok=true
    
    if [[ "$IS_SWARM" == "true" ]]; then
        # Swarm: Prüfe Replicas-Spalte
        verify_swarm_svc "$DOKPLOY_SVC_POSTGRES" "PostgreSQL" all_ok
        verify_swarm_svc "$DOKPLOY_SVC_REDIS" "Redis" all_ok
        verify_swarm_svc "$DOKPLOY_SVC_MAIN" "Dokploy" all_ok
        verify_swarm_svc "$DOKPLOY_SVC_TRAEFIK" "Traefik" all_ok
    else
        # Regulär: Pattern-Match auf Container-Namen
        if docker ps --format '{{.Names}}' | grep -q "dokploy.*postgres"; then
            log "SUCCESS" "✓ Dokploy PostgreSQL läuft"
        else
            log "WARNING" "✗ Dokploy PostgreSQL läuft nicht!"
            all_ok=false
        fi

        if docker ps --format '{{.Names}}' | grep -q "dokploy.*redis"; then
            log "SUCCESS" "✓ Dokploy Redis läuft"
        else
            log "WARNING" "✗ Dokploy Redis läuft nicht!"
            all_ok=false
        fi

        if docker ps --format '{{.Names}}' | grep -qE 'dokploy\.[0-9' | grep -qvE '(postgres|redis|traefik)'; then
            log "SUCCESS" "✓ Dokploy Hauptservice läuft"
        else
            log "ERROR" "✗ Dokploy Hauptservice läuft nicht!"
            all_ok=false
        fi

        if docker ps --format '{{.Names}}' | grep -q "dokploy-traefik"; then
            log "SUCCESS" "✓ Traefik Proxy läuft"
        else
            log "WARNING" "✗ Traefik Proxy läuft nicht!"
            all_ok=false
        fi
    fi
    
    [[ "$all_ok" == true ]] && log "SUCCESS" "Dokploy-Stack vollständig gestartet"
}

start_other_containers() {
    phase_start
    
    log "INFO" "Starte andere Container mit Restart-Policy..."
    
    local system_prefix
    case "$DEPLOYMENT_SYSTEM" in
        coolify) system_prefix="coolify" ;;
        dokploy) system_prefix="dokploy" ;;
        *) system_prefix="nonexistent" ;;
    esac
    
    docker ps -a --format '{{.Names}}\t{{.State}}' | grep -v "^${system_prefix}" | while IFS=$'\t' read -r name state; do
        if [[ "$state" != "running" ]] && [[ -n "$name" ]]; then
            local restart_policy
            restart_policy=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$name" 2>/dev/null || echo "")
            
            if [[ "$restart_policy" == "always" ]] || [[ "$restart_policy" == "unless-stopped" ]]; then
                log "INFO" "Starte Container: $name"
                docker start "$name" 2>/dev/null || log "WARNING" "Konnte $name nicht starten"
            fi
        fi
    done
    
    log "SUCCESS" "Andere Container gestartet"
    phase_end "Andere Container starten"
}

# =====================================
# Docker Health Check
# =====================================
check_container_health() {
    phase_start
    
    log "INFO" "Prüfe Container-Gesundheit..."
    
    local unhealthy_found=false
    
    # Prüfe alle laufenden Container auf Health-Status
    while IFS=$'\t' read -r name health; do
        if [[ -z "$name" ]]; then
            continue
        fi
        
        case "$health" in
            "healthy")
                log "SUCCESS" "  ✓ $name: healthy"
                ;;
            "unhealthy")
                log "ERROR" "  ✗ $name: UNHEALTHY!"
                unhealthy_found=true
                # Zeige Logs des unhealthy Containers
                local last_logs
                last_logs=$(docker logs --tail 5 "$name" 2>&1 || true)
                if [[ -n "$last_logs" ]]; then
                    log "ERROR" "    Letzte Logs:"
                    echo "$last_logs" | while read -r line; do
                        log "ERROR" "      $line"
                    done
                fi
                ;;
            "starting")
                log "WARNING" "  ⏳ $name: noch am Starten..."
                ;;
            "")
                # Kein Healthcheck definiert — Container-Status prüfen
                local running
                running=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo "false")
                if [[ "$running" == "true" ]]; then
                    log "INFO" "  • $name: läuft (kein Healthcheck)"
                fi
                ;;
        esac
    done < <(docker ps --format '{{.Names}}\t{{.Status}}' | \
        sed -E 's/(.*)Up [0-9]+ .*\(health: ([a-z]+)\)/\1\t\2/' | \
        while IFS=$'\t' read -r name health; do
            # Extrahiere Health aus Status-Feld falls vorhanden
            echo -e "$name\t$health"
        done)
    
    # Einfachere Alternative: docker inspect für Health
    while read -r name; do
        [[ -z "$name" ]] && continue
        local health
        health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name" 2>/dev/null || true)
        if [[ -n "$health" ]]; then
            case "$health" in
                healthy)   log "SUCCESS" "  ✓ $name: healthy" ;;
                unhealthy) log "ERROR" "  ✗ $name: UNHEALTHY!"; unhealthy_found=true ;;
                starting)  log "WARNING" "  ⏳ $name: startet..." ;;
            esac
        fi
    done < <(docker ps --format '{{.Names}}')
    
    if [[ "$unhealthy_found" == true ]]; then
        log "ERROR" "⚠ Ein oder mehrere Container sind unhealthy!"
    else
        log "SUCCESS" "Alle Container sind gesund"
    fi
    
    phase_end "Health Check"
}

# =====================================
# Security Check
# =====================================
security_check() {
    phase_start
    
    log "INFO" "=== Security Quick Check ==="
    
    # 1. Fehlgeschlagene SSH-Logins (letzte 24h)
    local ssh_failed=0
    if [[ -f /var/log/auth.log ]]; then
        ssh_failed=$(grep -c "Failed password" /var/log/auth.log 2>/dev/null || echo "0")
    elif journalctl --version >/dev/null 2>&1; then
        ssh_failed=$(journalctl -u sshd --since "24 hours ago" --no-pager 2>/dev/null | grep -c "Failed password" || echo "0")
    fi
    
    if [[ $ssh_failed -gt 100 ]]; then
        log "WARNING" "🔒 ${ssh_failed} fehlgeschlagene SSH-Logins in den letzten 24h"
    elif [[ $ssh_failed -gt 0 ]]; then
        log "INFO" "🔒 ${ssh_failed} fehlgeschlagene SSH-Logins (normal)"
    else
        log "SUCCESS" "🔒 Keine fehlgeschlagenen SSH-Logins"
    fi
    
    # 2. Aktive SSH-Sessions
    local ssh_sessions
    ssh_sessions=$(who 2>/dev/null | wc -l || echo "0")
    log "INFO" "👤 ${ssh_sessions} aktive Session(s)"
    
    # 3. Offene Ports (nur wichtige)
    log "INFO" "🔍 Offene Ports:"
    if command -v ss >/dev/null 2>&1; then
        ss -tlnp 2>/dev/null | grep "LISTEN" | awk '{print $4, $6}' | sed 's/.*://' | sort -un | while read -r port; do
            local service
            service=$(ss -tlnp 2>/dev/null | grep ":${port} " | head -1 | grep -oP 'users:\(\("\K[^"]+' || echo "unknown")
            log "INFO" "    :${port} (${service})"
        done
    fi
    
    # 4. UFW Status
    if command -v ufw >/dev/null 2>&1; then
        local ufw_status
        ufw_status=$(ufw status 2>/dev/null | head -1 || true)
        if echo "$ufw_status" | grep -q "active"; then
            log "SUCCESS" "🛡 Firewall (UFW): aktiv"
        else
            log "WARNING" "🛡 Firewall (UFW): INAKTIV"
        fi
    fi
    
    # 5. Letzter Login
    local last_login
    last_login=$(last -1 root 2>/dev/null | head -1 || true)
    if [[ -n "$last_login" ]]; then
        log "INFO" "🔑 Letzter root-Login: $last_login"
    fi
    
    phase_end "Security Check"
}

# =====================================
# Reboot prüfen
# =====================================
# KEEP IN SYNC: verify_ssh_before_reboot() existiert in allen 7 Update-Skripten
# (vps-update-auto.sh, vps-update-complete.sh, coolify/, dokploy/, vps-update.sh,
# vps-update-with-backup.sh, vps-update-simple.sh) — bei Änderungen ALLE pflegen.
verify_ssh_before_reboot() {
    log "INFO" "=== SSH Pre-Flight Prüfung (vor Reboot) ==="

    # sshd-Binary im PATH? (cron/systemd haben evtl. kein /usr/sbin)
    command -v sshd >/dev/null 2>&1 || {
        log "ERROR" "sshd nicht im PATH — Reboot BLOCKIERT."
        log "ERROR" "Reparatur: Pfad prüfen oder /usr/sbin/sshd nutzen."
        return 1
    }

    # 1. sshd -t: Config-Syntax gültig? (short-circuit vor -T)
    if ! sshd -t >/dev/null 2>&1; then
        log "ERROR" "sshd-Config ungültig (sshd -t ≠ 0) — Reboot BLOCKIERT."
        log "ERROR" "Manuelle Prüfung: sshd -t"
        return 1
    fi

    # 2. sshd -T: effektiven Port ermitteln (auto-detect, NICHT hartkodiert 22)
    local ssh_ports
    if ! ssh_ports=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -u); then
        log "ERROR" "sshd -T fehlgeschlagen — Reboot BLOCKIERT."
        return 1
    fi
    [[ -n "$ssh_ports" ]] || {
        log "ERROR" "Kein SSH-Port via sshd -T ermittelbar — Reboot BLOCKIERT."
        return 1
    }

    # 3. Lauscher-Check: jeder SSH-Port aktiv? (reuse ss -tlnp-Idiom :786-793)
    local listening
    listening=$(ss -tlnp 2>/dev/null | grep "LISTEN" | awk '{print $4}' | sed 's/.*://' | sort -un)
    local p
    for p in $ssh_ports; do
        grep -qx "$p" <<<"$listening" || {
            log "ERROR" "SSH-Port ${p} lauscht nicht — Reboot BLOCKIERT."
            log "ERROR" "Reparatur: systemctl status ssh.socket ssh.service"
            return 1
        }
    done

    # 4. ssh.socket is-enabled (Boot-Persistenz), String-Dispatch + ssh.service-Fallback
    local socket_state svc_state
    socket_state=$(systemctl is-enabled ssh.socket 2>/dev/null) || true
    case "$socket_state" in
        enabled|static) : ;;
        disabled|masked|not-found|"")
            svc_state=$(systemctl is-enabled ssh.service 2>/dev/null) || true
            case "$svc_state" in
                enabled|static)
                    log "INFO" "ssh.socket='${socket_state:-<leer>}' — ssh.service='${svc_state}' übernimmt Boot-Persistenz (OK)." ;;
                *)
                    log "ERROR" "ssh.socket='${socket_state:-<leer>}' und ssh.service='${svc_state:-<leer>}' — Reboot BLOCKIERT."
                    log "ERROR" "Reparatur: systemctl enable ssh.socket  ODER  systemctl enable ssh.service"
                    return 1 ;;
            esac ;;
        *)
            log "ERROR" "ssh.socket: unbekannter Zustand '${socket_state}' — Reboot BLOCKIERT."
            return 1 ;;
    esac

    log "SUCCESS" "SSH Pre-Flight OK (Port(s): $(echo "$ssh_ports" | tr '\n' ' '))"
    return 0
}

check_reboot_required() {
    log "INFO" "Prüfe ob Neustart erforderlich..."
    
    if [[ -f /var/run/reboot-required ]]; then
        log "WARNING" "=== NEUSTART ERFORDERLICH ==="
        log "WARNING" "Gründe:"
        while read -r pkg; do
            log "WARNING" "  - $pkg"
        done < <(cat /var/run/reboot-required.pkgs 2>/dev/null)
        
        # Prüfe ob wir in einem Terminal laufen (nicht cron)
        if [[ -t 0 ]]; then
            # SSH Pre-Flight: reboot-safe? Sonst blockieren (SUCCESS-mit-Caveat).
            if ! verify_ssh_before_reboot; then
                log "ERROR" "Reboot wegen SSH-Pre-Flight blockiert — System bleibt oben."
                log "ERROR" "SSH reparieren, dann manuell: reboot"
                return 0
            fi
            log "INFO" "Neustart in ${REBOOT_DELAY} Sekunden... (Ctrl+C zum Abbrechen)"
            sleep "$REBOOT_DELAY"
            log "INFO" "Starte Neustart..."
            reboot
        else
            log "WARNING" "Automatischer Reboot übersprungen (kein Terminal)"
            log "WARNING" "Bitte manuell neustarten: reboot"
            # Überfälligkeit eskaliert über den Rückgabewert: main() fängt ihn
            # per RUN_RC ab (A3-0), alle Folgeschritte laufen weiter, die Unit
            # geht auf failed. Portables find wie in vps-status — die
            # Entscheidung hängt nicht an GNU stat.
            if [[ -n "$(find /var/run/reboot-required -maxdepth 0 -mtime +"$REBOOT_OVERDUE_DAYS" -print 2>/dev/null)" ]]; then
                log "WARNING" "Reboot steht seit mehr als ${REBOOT_OVERDUE_DAYS} Tagen aus — Lauf wird als nicht erfolgreich gemeldet"
                return 1
            fi
        fi
    else
        log "INFO" "Kein Neustart erforderlich"
    fi
}

# Erkenne Dokploy Swarm-Services
# shellcheck disable=SC2317
detect_dokploy_services() {
    if [[ "$IS_SWARM" != "true" ]]; then
        return 0
    fi
    
    local all_services
    all_services=$(docker service ls --format '{{.Name}}' 2>/dev/null | grep -i "dokploy" || true)
    
    [[ -z "$all_services" ]] && { log "WARNING" "Keine Dokploy-Swarm-Services gefunden"; return 0; }
    
    # Mappe Services zu Rollen
    DOKPLOY_SVC_POSTGRES=$(echo "$all_services" | grep -iE 'postgres' | head -1) || true
    DOKPLOY_SVC_REDIS=$(echo "$all_services" | grep -iE 'redis' | head -1) || true
    DOKPLOY_SVC_TRAEFIK=$(echo "$all_services" | grep -iE 'traefik' | head -1) || true
    DOKPLOY_SVC_MAIN=$(echo "$all_services" | grep -viE '(postgres|redis|traefik)' | head -1) || true
    
    log "INFO" "Swarm-Services erkannt:"
    [[ -n "$DOKPLOY_SVC_POSTGRES" ]] && log "INFO" "  PostgreSQL: $DOKPLOY_SVC_POSTGRES" || log "WARNING" "  PostgreSQL: NICHT GEFUNDEN"
    [[ -n "$DOKPLOY_SVC_REDIS" ]] && log "INFO" "  Redis: $DOKPLOY_SVC_REDIS" || log "WARNING" "  Redis: NICHT GEFUNDEN"
    [[ -n "$DOKPLOY_SVC_MAIN" ]] && log "INFO" "  Hauptservice: $DOKPLOY_SVC_MAIN" || log "WARNING" "  Hauptservice: NICHT GEFUNDEN"
    [[ -n "$DOKPLOY_SVC_TRAEFIK" ]] && log "INFO" "  Traefik: $DOKPLOY_SVC_TRAEFIK" || log "WARNING" "  Traefik: NICHT GEFUNDEN"
    
    # Speichere aktuelle Replika-Zahlen
    for svc in $DOKPLOY_SVC_POSTGRES $DOKPLOY_SVC_REDIS $DOKPLOY_SVC_MAIN $DOKPLOY_SVC_TRAEFIK; do
        [[ -z "$svc" ]] && continue
        local replicas
        replicas=$(docker service ls --format '{{.Name}} {{.Replicas}}' 2>/dev/null | grep "^${svc} " | awk '{print $2}' | cut -d'/' -f2 || echo "1")
        DOKPLOY_SVC_REPLICAS["$svc"]="${replicas:-1}"
    done
}

# Verifiziere Swarm-Service
# shellcheck disable=SC2317
verify_swarm_svc() {
    local service="$1"
    local label="$2"
    # $3 is nameref to all_ok (bash 4.3+)
    local -n _all_ok="$3"
    
    [[ -z "$service" ]] && return 0
    
    local replicas_info
    replicas_info=$(docker service ls --format '{{.Name}} {{.Replicas}}' 2>/dev/null | grep "^${service} " || true)
    
    if [[ -n "$replicas_info" ]]; then
        local current desired
        current=$(echo "$replicas_info" | awk '{print $2}' | cut -d'/' -f1)
        desired=$(echo "$replicas_info" | awk '{print $2}' | cut -d'/' -f2)
        
        if [[ "$current" == "$desired" ]] && [[ "$current" -gt 0 ]]; then
            log "SUCCESS" "✓ $label ($service) läuft ($current/$desired)"
        else
            log "WARNING" "✗ $label ($service) nicht vollständig ($current/$desired)"
            _all_ok=false
            # Diagnose
            docker service ps "$service" --format "table {{.Name}}\t{{.CurrentState}}\t{{.Error}}" 2>/dev/null | head -5 | tee -a "$LOGFILE" || true
        fi
    else
        log "WARNING" "✗ $label ($service) nicht gefunden"
        _all_ok=false
    fi
}

show_final_status() {
    log "INFO" "=== Finale Status ==="
    if [[ "$IS_SWARM" == "true" ]]; then
        docker service ls --format "table {{.Name}}\t{{.Replicas}}\t{{.Image}}" 2>/dev/null | grep -E "(dokploy|NAME)" | tee -a "$LOGFILE" || true
    fi
    # awk statt head: ein head mit Zeilenlimit schliesst die Pipe, `docker ps`
    # erhaelt SIGPIPE und endet mit 141. Unter `set -o pipefail` wird 141 zum
    # Status der Pipeline, `set -e` beendet daraufhin das Skript — und zwar VOR
    # security_check, check_reboot_required und show_summary.
    # Ausgeloest ab 20 Containern (Kopfzeile + N > 20). Auf lorini (22 Container)
    # fiel dadurch wochenlang die Reboot-Meldung aus, obwohl Kernel-Updates
    # installiert und reboot-pflichtig waren.
    # `|| true` waere die naheliegende Alternative, maskiert aber auch echte
    # docker-Fehler (gemessen: Exit 3 -> 0). awk liest die Eingabe vollstaendig,
    # erzeugt kein SIGPIPE und laesst echte Fehler weiterhin durch.
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | awk 'NR<=20' | tee -a "$LOGFILE"
}

# =====================================
# Update Summary
# =====================================
show_summary() {
    local total_duration=$SECONDS
    
    log "INFO" "========================================="
    log "INFO" "📊 UPDATE-ZUSAMMENFASSUNG"
    log "INFO" "========================================="
    log "INFO" "Server:     $(hostname)"
    log "INFO" "System:     ${DEPLOYMENT_SYSTEM^^}"
    log "INFO" "Dauer:      $(format_duration $total_duration)"
    log "INFO" "Kernel:     $(uname -r)"
    
    # Uptime
    local uptime_str
    uptime_str=$(uptime -p 2>/dev/null || echo "unbekannt")
    log "INFO" "Uptime:     $uptime_str"
    
    # Disk Usage
    local disk_used disk_total disk_pct
    disk_used=$(df -h / | awk 'NR==2 {print $3}')
    disk_total=$(df -h / | awk 'NR==2 {print $2}')
    disk_pct=$(df -h / | awk 'NR==2 {print $5}')
    log "INFO" "Disk:       ${disk_used} / ${disk_total} (${disk_pct} belegt)"
    
    # Memory
    local mem_used mem_total
    mem_used=$(free -h | awk '/Mem:/ {print $3}')
    mem_total=$(free -h | awk '/Mem:/ {print $2}')
    log "INFO" "RAM:        ${mem_used} / ${mem_total}"
    
    # Docker Container
    local running total
    running=$(docker ps -q | wc -l)
    total=$(docker ps -a -q | wc -l)
    log "INFO" "Container:  ${running}/${total} laufen"
    
    log "INFO" "========================================="
}

# =====================================
# Hauptprogramm
# =====================================
main() {
    log "INFO" "========================================="
    log "INFO" "VPS Auto-Update v2.1 gestartet"
    log "INFO" "========================================="
    log "INFO" "Datum: $(date)"
    log "INFO" "Server: $(hostname)"
    log "INFO" "Kernel: $(uname -r)"

    # Rückgabewert-Propagation: Teilschritte melden Fehler über RUN_RC,
    # ohne unter set -e den Lauf zwischen Stoppen und Starten abzubrechen
    local RUN_RC=0
    local RUN_RC_STEPS=""

    # Voraussetzungen prüfen & System erkennen
    check_prerequisites
    
    log "INFO" "Erkanntes System: ${DEPLOYMENT_SYSTEM^^}"
    [[ -n "$DEPLOYMENT_PATH" ]] && log "INFO" "Pfad: $DEPLOYMENT_PATH"
    
    # Disk Space Check
    if ! check_disk_space; then
        log "ERROR" "Abbruch: Nicht genug Speicherplatz"
        exit 1
    fi
    
    # Docker-Container stoppen
    stop_docker_containers
    
    # System aktualisieren (mit Error-Recovery)
    if ! update_system; then
        log "ERROR" "System-Update fehlgeschlagen — starte Container als Notfall-Maßnahme neu..."
        emergency_restart
        show_final_status
        log "ERROR" "VPS Auto-Update mit Fehlern abgebrochen"
        exit 1
    fi
    
    # Docker Cleanup — niemals nackt: return ≠ 0 darf die Folgeschritte
    # (Container-Start!) nicht abwürgen
    docker_cleanup || { RUN_RC=$?; RUN_RC_STEPS+=" docker_cleanup"; }

    # Deployment-Stack starten
    start_deployment_stack
    
    # Andere Container starten
    start_other_containers
    
    # Docker Health Check
    check_container_health
    
    # Status anzeigen
    show_final_status
    
    # Security Check
    security_check
    
    # Reboot prüfen — niemals nackt (siehe docker_cleanup)
    check_reboot_required || { RUN_RC=$?; RUN_RC_STEPS+=" check_reboot_required"; }

    # Zusammenfassung
    show_summary
    
    if [[ $RUN_RC -eq 0 ]]; then
        log "SUCCESS" "========================================="
        log "SUCCESS" "VPS Auto-Update abgeschlossen"
        log "SUCCESS" "Gesamtdauer: $(format_duration $SECONDS)"
        log "SUCCESS" "========================================="
    else
        log "WARNING" "========================================="
        log "WARNING" "VPS Auto-Update beendet, Teilschritt nicht erfolgreich:${RUN_RC_STEPS}"
        log "WARNING" "Gesamtdauer: $(format_duration $SECONDS)"
        log "WARNING" "========================================="
    fi

    return $RUN_RC
}

# Skript ausführen
main "$@"
