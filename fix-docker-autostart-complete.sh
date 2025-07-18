#!/usr/bin/env bash
# ==============================================================
# Complete Docker Autostart Fix
# Master-Script zur vollständigen Lösung des Container-Restart Problems
# Basierend auf script.txt Analyse
# ==============================================================

set -euo pipefail

# Farben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${2-}${1}${NC}"; }

# Script-Verzeichnis ermitteln
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_banner() {
    log "\n╔══════════════════════════════════════════════════════════════╗" "$CYAN"
    log "║                Docker Autostart Complete Fix                ║" "$CYAN"
    log "║              Lösung für Container Restart Problem           ║" "$CYAN"
    log "║                  Basierend auf script.txt                   ║" "$CYAN"
    log "╚══════════════════════════════════════════════════════════════╝" "$CYAN"
}

show_menu() {
    log "\nVerfügbare Optionen:" "$BLUE"
    log "1) 🔧 Restart Policies konfigurieren (Hauptproblem lösen)" "$YELLOW"
    log "2) 🚀 Alle Container starten" "$YELLOW"
    log "3) 🔄 Komplette Lösung (1 + 2)" "$YELLOW"
    log "4) 📊 Status anzeigen" "$YELLOW"
    log "5) 🧪 Autostart testen" "$YELLOW"
    log "6) 📖 Dokumentation anzeigen" "$YELLOW"
    log "0) ❌ Beenden" "$YELLOW"
    echo
}

fix_restart_policies() {
    log "\n🔧 Konfiguriere Restart Policies..." "$GREEN"
    if [[ -f "$SCRIPT_DIR/fix-all-container-restart-policies.sh" ]]; then
        bash "$SCRIPT_DIR/fix-all-container-restart-policies.sh"
    else
        log "❌ fix-all-container-restart-policies.sh nicht gefunden!" "$RED"
        return 1
    fi
}

start_all_containers() {
    log "\n🚀 Starte alle Container..." "$GREEN"
    if [[ -f "$SCRIPT_DIR/start-all-containers.sh" ]]; then
        bash "$SCRIPT_DIR/start-all-containers.sh"
    else
        log "❌ start-all-containers.sh nicht gefunden!" "$RED"
        return 1
    fi
}

show_status() {
    log "\n📊 Aktueller Container Status:" "$GREEN"
    
    if ! docker info &>/dev/null; then
        log "❌ Docker läuft nicht!" "$RED"
        return 1
    fi
    
    # Container-Anzahl prüfen
    CONTAINER_COUNT=$(docker ps -a --format '{{.Names}}' | wc -l)
    if [[ $CONTAINER_COUNT -eq 0 ]]; then
        log "ℹ️  Keine Container gefunden." "$YELLOW"
        return 0
    fi
    
    log "\nContainer Übersicht ($CONTAINER_COUNT Container):" "$BLUE"
    printf "%-40s %-15s %-20s %-15s\n" "CONTAINER" "STATUS" "RESTART POLICY" "HEALTH"
    printf "%-40s %-15s %-20s %-15s\n" "$(printf '%0.s-' {1..40})" "$(printf '%0.s-' {1..15})" "$(printf '%0.s-' {1..20})" "$(printf '%0.s-' {1..15})"
    
    # Container nach Typ kategorisieren und anzeigen
    declare -A CONTAINER_TYPES
    CONTAINER_TYPES["database"]=0
    CONTAINER_TYPES["coolify"]=0
    CONTAINER_TYPES["proxy"]=0
    CONTAINER_TYPES["application"]=0
    
    docker ps -a --format '{{.Names}}' | while read -r name; do
        if [[ -n "$name" ]]; then
            STATUS=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || echo "unknown")
            RESTART_POLICY=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$name" 2>/dev/null || echo "unknown")
            HEALTH=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-check{{end}}' "$name" 2>/dev/null || echo "unknown")
            
            # Farbkodierung für Status
            case "$STATUS" in
                "running") STATUS_COLOR="$GREEN" ;;
                "exited") STATUS_COLOR="$RED" ;;
                *) STATUS_COLOR="$YELLOW" ;;
            esac
            
            case "$RESTART_POLICY" in
                "unless-stopped"|"always") POLICY_COLOR="$GREEN" ;;
                "no"|"none"|"unknown"|""|"") POLICY_COLOR="$RED" ;;
                *) POLICY_COLOR="$YELLOW" ;;
            esac
            
            printf "%-40s ${STATUS_COLOR}%-15s${NC} ${POLICY_COLOR}%-20s${NC} %-15s\n" "$name" "$STATUS" "$RESTART_POLICY" "$HEALTH"
        fi
    done
    
    # Zusammenfassung
    TOTAL=$(docker ps -a --format '{{.Names}}' | wc -l)
    RUNNING=$(docker ps --format '{{.Names}}' | wc -l)
    STOPPED=$((TOTAL - RUNNING))
    
    # Restart Policy Statistik
    UNLESS_STOPPED=$(docker ps -a --format '{{.Names}}' | xargs -I {} docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' {} 2>/dev/null | grep -c "unless-stopped" || echo "0")
    ALWAYS=$(docker ps -a --format '{{.Names}}' | xargs -I {} docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' {} 2>/dev/null | grep -c "always" || echo "0")
    NO_POLICY=$(docker ps -a --format '{{.Names}}' | xargs -I {} docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' {} 2>/dev/null | grep -cE "^$|^none$|^no$" || echo "0")
    
    log "\n📈 Zusammenfassung:" "$BLUE"
    log "   Gesamt: $TOTAL Container" "$CYAN"
    log "   Laufend: $RUNNING Container" "$GREEN"
    log "   Gestoppt: $STOPPED Container" "$([ $STOPPED -eq 0 ] && echo "$GREEN" || echo "$RED")"
    log "\n🔄 Restart Policies:" "$BLUE"
    log "   unless-stopped: $UNLESS_STOPPED Container" "$GREEN"
    log "   always: $ALWAYS Container" "$GREEN"
    log "   keine Policy: $NO_POLICY Container" "$([ $NO_POLICY -eq 0 ] && echo "$GREEN" || echo "$RED")"
}

test_autostart() {
    log "\n🧪 Teste Docker Autostart..." "$GREEN"
    log "⚠️  WARNUNG: Dies startet Docker neu!" "$YELLOW"
    read -p "Fortfahren? (j/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[JjYy]$ ]]; then
        log "Starte Docker neu..." "$BLUE"
        systemctl restart docker
        
        log "Warte auf Docker-Initialisierung..." "$BLUE"
        sleep 10
        
        log "Prüfe Container-Status..." "$BLUE"
        show_status
        
        RUNNING_COUNT=$(docker ps --format '{{.Names}}' | wc -l)
        if [[ $RUNNING_COUNT -gt 0 ]]; then
            log "\n✅ Autostart funktioniert! $RUNNING_COUNT Container laufen." "$GREEN"
        else
            log "\n❌ Autostart Problem! Keine Container laufen." "$RED"
            log "Führe 'Komplette Lösung' aus." "$YELLOW"
        fi
    else
        log "Test abgebrochen." "$YELLOW"
    fi
}

show_documentation() {
    log "\n📖 Dokumentation:" "$GREEN"
    if [[ -f "$SCRIPT_DIR/CONTAINER-RESTART-PROBLEM-LÖSUNG.md" ]]; then
        log "Öffne Dokumentation..." "$BLUE"
        if command -v less &>/dev/null; then
            less "$SCRIPT_DIR/CONTAINER-RESTART-PROBLEM-LÖSUNG.md"
        elif command -v more &>/dev/null; then
            more "$SCRIPT_DIR/CONTAINER-RESTART-PROBLEM-LÖSUNG.md"
        else
            cat "$SCRIPT_DIR/CONTAINER-RESTART-PROBLEM-LÖSUNG.md"
        fi
    else
        log "❌ Dokumentation nicht gefunden!" "$RED"
        log "Erstelle mit: cat > CONTAINER-RESTART-PROBLEM-LÖSUNG.md" "$YELLOW"
    fi
}

# Hauptprogramm
main() {
    # Root-Rechte prüfen
    if [[ $EUID -ne 0 ]]; then
        log "❌ Dieses Script benötigt Root-Rechte!" "$RED"
        log "Starte mit: sudo $0" "$YELLOW"
        exit 1
    fi
    
    show_banner
    
    while true; do
        show_menu
        read -p "Wähle eine Option (0-6): " choice
        
        case $choice in
            1)
                fix_restart_policies
                ;;
            2)
                start_all_containers
                ;;
            3)
                log "\n🔄 Führe komplette Lösung aus..." "$GREEN"
                fix_restart_policies
                echo
                start_all_containers
                ;;
            4)
                show_status
                ;;
            5)
                test_autostart
                ;;
            6)
                show_documentation
                ;;
            0)
                log "\n👋 Auf Wiedersehen!" "$GREEN"
                exit 0
                ;;
            *)
                log "❌ Ungültige Auswahl!" "$RED"
                ;;
        esac
        
        echo
        read -p "Drücke Enter um fortzufahren..." -r
    done
}

# Script starten
main "$@"