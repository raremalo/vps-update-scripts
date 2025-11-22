#!/usr/bin/env bash
# ==============================================================
# Test-Skript für VPS-Update Backup-Funktionen
# ==============================================================

set -euo pipefail

# Farben
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log() { echo -e "${2-}${1}${NC}"; }
err() { log "$*" "$RED"; }

# Test-Umgebung vorbereiten
TEST_DIR="/tmp/vps-backup-test"
export VPS_UPDATE_BACKUP_DIR="$TEST_DIR/backups"
export VPS_UPDATE_MIN_FREE_SPACE_MB="10"
export VPS_UPDATE_KEEP_BACKUPS="3"

log "======== VPS-Backup Test gestartet ========" "$GREEN"
log "Test-Verzeichnis: $TEST_DIR" "$BLUE"

# Cleanup von vorherigen Tests
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"

# Backup-Funktionen laden
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/backup-functions.sh" ]]; then
    source "$SCRIPT_DIR/backup-functions.sh"
else
    err "backup-functions.sh nicht gefunden!"
    exit 1
fi

# Test 1: Backup-Verzeichnis erstellen
log "\nTest 1: Backup-Verzeichnis erstellen" "$YELLOW"
backup_path=$(create_backup_dir)
if [[ -d $backup_path ]]; then
    log "✓ Backup-Verzeichnis erfolgreich erstellt: $backup_path" "$GREEN"
else
    err "✗ Fehler beim Erstellen des Backup-Verzeichnisses"
fi

# Test 2: Speicherplatz prüfen
log "\nTest 2: Speicherplatz-Prüfung" "$YELLOW"
if check_free_space "$TEST_DIR"; then
    log "✓ Speicherplatz-Prüfung erfolgreich" "$GREEN"
else
    err "✗ Speicherplatz-Prüfung fehlgeschlagen"
fi

# Test 3: System-Info Backup
log "\nTest 3: System-Info Backup" "$YELLOW"
if backup_system_info "$backup_path"; then
    if [[ -f "$backup_path/system-info.txt" ]]; then
        log "✓ System-Info erfolgreich gesichert" "$GREEN"
        log "  Inhalt (erste 5 Zeilen):" "$BLUE"
        head -n 5 "$backup_path/system-info.txt" | sed 's/^/    /'
    fi
else
    err "✗ System-Info Backup fehlgeschlagen"
fi

# Test 4: Mock dpkg-Daten erstellen und sichern
log "\nTest 4: dpkg-Backup (Mock-Daten)" "$YELLOW"
# Simuliere dpkg-Ausgabe für Test
mkdir -p "$TEST_DIR/mock"
cat > "$TEST_DIR/mock/dpkg-selections.txt" <<EOF
bash					install
curl					install
docker-ce				install
EOF

# Temporär dpkg umleiten für Test
dpkg() {
    if [[ "$1" == "--get-selections" ]]; then
        cat "$TEST_DIR/mock/dpkg-selections.txt"
    else
        command dpkg "$@"
    fi
}
export -f dpkg

if backup_dpkg_packages "$backup_path"; then
    if [[ -f "$backup_path/dpkg-selections.txt" ]]; then
        log "✓ dpkg-Paketliste erfolgreich gesichert" "$GREEN"
        log "  Anzahl Pakete: $(wc -l < "$backup_path/dpkg-selections.txt")" "$BLUE"
    fi
else
    err "✗ dpkg-Backup fehlgeschlagen"
fi

# Test 5: Vollständiges Backup
log "\nTest 5: Vollständiges Backup durchführen" "$YELLOW"
if perform_backup; then
    log "✓ Vollständiges Backup erfolgreich" "$GREEN"
    
    # Zeige Backup-Struktur
    log "\nBackup-Struktur:" "$BLUE"
    find "$VPS_UPDATE_BACKUP_DIR" -type f | sort | sed 's/^/    /'
else
    err "✗ Vollständiges Backup fehlgeschlagen"
fi

# Test 6: Mehrere Backups erstellen für Cleanup-Test
log "\nTest 6: Backup-Cleanup testen" "$YELLOW"
for i in {1..5}; do
    sleep 1  # Unterschiedliche Zeitstempel
    perform_backup >/dev/null 2>&1
done

backup_count=$(find "$VPS_UPDATE_BACKUP_DIR" -maxdepth 1 -type d -name "[0-9]*_[0-9]*" | wc -l)
log "  Anzahl Backups nach 5 Durchläufen: $backup_count" "$BLUE"

if [[ $backup_count -eq 3 ]]; then
    log "✓ Backup-Cleanup funktioniert (nur 3 Backups behalten)" "$GREEN"
else
    err "✗ Backup-Cleanup fehlerhaft (erwartet: 3, gefunden: $backup_count)"
fi

# Test 7: Fehlende Berechtigungen simulieren
log "\nTest 7: Fehlerbehandlung bei fehlenden Berechtigungen" "$YELLOW"
chmod 000 "$VPS_UPDATE_BACKUP_DIR" 2>/dev/null || true
export VPS_UPDATE_BACKUP_DIR="/root/no-access-test"

if ! create_backup_dir 2>/dev/null; then
    log "✓ Fehlerbehandlung bei fehlenden Berechtigungen funktioniert" "$GREEN"
else
    err "✗ Fehlerbehandlung nicht korrekt"
fi

# Cleanup
log "\nAufräumen..." "$YELLOW"
rm -rf "$TEST_DIR"

log "\n======== VPS-Backup Test abgeschlossen ========" "$GREEN"
log "Hinweis: Dies war ein Test mit Mock-Daten." "$YELLOW"
log "Für einen vollständigen Test auf einem echten System," "$YELLOW"
log "führen Sie das Skript als root aus." "$YELLOW"
