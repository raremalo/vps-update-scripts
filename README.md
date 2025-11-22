# VPS Update Script Suite

Eine professionelle Lösung für automatisierte Updates von Ubuntu 24.04 LTS Servern mit Docker und Coolify.

## 📋 Übersicht

Diese erweiterte Script-Suite bietet:

### Update-Skripte
- **vps-update.sh**: Standard Update-Skript mit Docker/Coolify-Integration
- **vps-update-complete.sh**: Erweitertes Update mit vollständigem Backup inkl. Datenbanken
- **vps-update-simple.sh**: Vereinfachtes Update ohne Backup für schnelle Updates
- **vps-update-with-backup.sh**: Update mit integrierter Backup-Funktion

### Backup-Lösungen
- **backup-vps-data.sh**: Standalone Backup mit Datenbank-Dumps, Remote-Support und Verschlüsselung
- **backup-functions.sh**: Backup-Funktionsbibliothek für Integration

### Docker-Management
- **ensure-docker-autostart.sh**: Erweiterte Docker-Autostart-Konfiguration mit Health Checks
- **ensure-coolify-projects-autostart.sh**: Coolify-Projekt-Autostart-Management
- **fix-all-container-restart-policies.sh**: Universelle Restart-Policy-Konfiguration
- **start-all-containers.sh**: Intelligenter Container-Start mit Prioritäten

### Utilities
- **installvps-update.sh**: Automatisches Installations- und Konfigurationsskript
- **vps-status.sh**: Quick-Status-Check für System und Services

## 🚀 Installation

```bash
# Repository klonen oder Dateien herunterladen
git clone <repository-url>
cd vps_script

# Installationsskript ausführen
sudo ./installvps-update.sh
```

## 📖 Features

### Hauptfunktionen
- ✅ Sichere Docker/Coolify-Behandlung während Updates
- ✅ Intelligente Reboot-Erkennung
- ✅ Automatische Log-Rotation
- ✅ Lock-File-Mechanismus gegen parallele Ausführungen
- ✅ Konfigurierbare Paket-Holds (snapd, ubuntu-advantage-tools, etc.)

### Neue Features (v3.0.0)
- 🔥 **Erweiterte Backup-Funktionen**: Datenbank-Dumps, Remote-Backup, Verschlüsselung
- 🔥 **System Health Checks**: Memory, Disk, Network-Monitoring
- 🔥 **Soketi-Support**: Verbesserte Coolify Real-time Service Integration
- 🔥 **Intelligente Volume-Sicherung**: Größenlimits und kritische Volume-Priorisierung
- 🔥 **Restore-Guides**: Automatisch generierte Wiederherstellungsanleitungen

### Sicherheit
- Root-Berechtigungsprüfung
- Konfigurierbares Docker-Stop-Timeout
- Erhaltung bestehender Konfigurationsdateien

### Logging
- Strukturierte Logs in `/var/log/vps-updates/`
- Farbcodierte Terminal-Ausgabe
- Automatische Log-Rotation (30 Tage)

## ⚙️ Konfiguration

### Umgebungsvariablen
```bash
export VPS_UPDATE_LOG_DIR="/custom/log/path"    # Standard: /var/log/vps-updates
export DOCKER_STOP_TIMEOUT="60"                 # Standard: 30 Sekunden
```

### Systemd Timer (empfohlen)
Das Installationsskript richtet automatisch einen Systemd-Timer ein:
- **Ausführung**: Jeden Sonntag um 02:00 Uhr
- **Randomisierung**: ±30 Minuten zur Lastverteilung

Timer-Status prüfen:
```bash
systemctl status vps-update.timer
systemctl list-timers vps-update.timer
```

### Alternative: Cron
Falls Systemd-Timer nicht gewünscht:
```bash
0 2 * * 0 /usr/local/bin/vps-update
```

## 🔧 Verwendung

### Update-Varianten

#### Standard Update
```bash
sudo vps-update.sh
```

#### Vollständiges Update mit erweitertem Backup
```bash
sudo vps-update-complete.sh
```

#### Schnelles Update ohne Backup
```bash
sudo vps-update-simple.sh
```

### Standalone Backup
```bash
# Vollständiges Backup mit Datenbanken
sudo backup-vps-data.sh

# Mit Remote-Backup
REMOTE_BACKUP=true REMOTE_HOST=backup.server.com sudo backup-vps-data.sh
```

### System-Status prüfen
```bash
sudo vps-status.sh
```

### Logs anzeigen
```bash
# Letztes Update-Log
ls -t /var/log/vps-updates/vps_update_*.log | head -1 | xargs cat

# Alle Logs
ls /var/log/vps-updates/
```

## 🐛 Fehlerbehebung

### Lock-File-Fehler
```bash
# Wenn Script hängt und Lock-File zurückbleibt:
sudo rm /tmp/vps_update.lock
```

### Docker startet nicht
```bash
# Manueller Docker-Neustart
sudo systemctl restart docker
sudo systemctl restart coolify
```

## 📝 TODO / Verbesserungsvorschläge

- [ ] E-Mail-Benachrichtigungen bei Fehlern
- [ ] Backup-Funktion vor kritischen Updates
- [ ] Dry-Run-Modus
- [ ] Web-Dashboard für Update-Historie
- [ ] Slack/Discord-Integration

## 📄 Lizenz

[Ihre Lizenz hier]

## 👥 Beiträge

Contributions sind willkommen! Bitte erstellen Sie einen Pull Request oder Issue.
