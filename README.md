# VPS Update Script Suite

Eine professionelle Lösung für automatisierte Updates von Ubuntu 24.04 LTS Servern mit Docker und Coolify.

## 📋 Übersicht

Diese Script-Suite bietet:
- **vps-update.sh**: Hauptskript für System-Updates mit Docker/Coolify-Integration
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

### Manueller Update
```bash
sudo vps-update
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
