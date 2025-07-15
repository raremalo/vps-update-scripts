# VPS-Update Backup-Funktion

## Übersicht

Die Backup-Funktion wurde entwickelt, um vor System-Updates automatisch wichtige Systemkonfigurationen und Docker-Informationen zu sichern. Dies ermöglicht eine schnelle Wiederherstellung im Falle von Problemen nach einem Update.

## Features

### Automatische Backups von:
- **System-Informationen**: Hostname, Kernel, Distribution, Speicher, Services
- **dpkg-Paketliste**: Alle installierten Pakete und deren Versionen
- **APT-Sources**: Paketquellen (`/etc/apt/sources.list` und `/etc/apt/sources.list.d/`)
- **Docker-Konfigurationen**: 
  - Container-Liste und detaillierte Inspektionen
  - Docker-Compose-Dateien
  - Netzwerke und Images
- **Docker-Volumes** (optional): Backup von Docker-Volumes

### Sicherheitsfeatures:
- Prüfung auf ausreichenden Speicherplatz vor dem Backup
- Prüfung der Schreibrechte
- Automatische Bereinigung alter Backups
- Strukturierte Logs mit Zeitstempel

## Konfiguration

Die Backup-Funktion wird über Umgebungsvariablen konfiguriert:

```bash
# Backup-Verzeichnis (Standard: /var/backups/vps-updates)
export VPS_UPDATE_BACKUP_DIR="/pfad/zum/backup/verzeichnis"

# Backup aktivieren/deaktivieren (Standard: true)
export VPS_UPDATE_BACKUP_ENABLED="true"

# Docker-Volume-Backup aktivieren (Standard: false)
export VPS_UPDATE_BACKUP_DOCKER_VOLUMES="true"

# Minimaler freier Speicherplatz in MB (Standard: 500)
export VPS_UPDATE_MIN_FREE_SPACE_MB="1000"

# Maximale Größe eines Docker-Volumes für Backup in MB (Standard: 100)
export VPS_UPDATE_MAX_VOLUME_SIZE_MB="200"

# Anzahl der aufzubewahrenden Backups (Standard: 5)
export VPS_UPDATE_KEEP_BACKUPS="10"
```

## Installation

1. Kopieren Sie beide Skripte auf Ihren Server:
   ```bash
   scp backup-functions.sh vps-update-with-backup.sh root@ihr-server:/root/
   ```

2. Machen Sie die Skripte ausführbar:
   ```bash
   chmod +x backup-functions.sh vps-update-with-backup.sh
   ```

3. Optional: Ersetzen Sie das bestehende Update-Skript:
   ```bash
   mv vps-update.sh vps-update-original.sh
   mv vps-update-with-backup.sh vps-update.sh
   ```

## Verwendung

### Manueller Start mit Standard-Einstellungen:
```bash
./vps-update.sh
```

### Mit angepassten Einstellungen:
```bash
VPS_UPDATE_BACKUP_DIR="/mnt/backups" \
VPS_UPDATE_BACKUP_DOCKER_VOLUMES="true" \
./vps-update.sh
```

### Nur Backup ohne Update ausführen:
```bash
# Source die Backup-Funktionen
source ./backup-functions.sh

# Führe nur das Backup aus
perform_backup
```

## Backup-Struktur

Ein Backup erstellt folgende Verzeichnisstruktur:

```
/var/backups/vps-updates/
└── 20240115_143022/
    ├── README.txt                    # Backup-Übersicht und Wiederherstellungshinweise
    ├── system-info.txt               # System-Informationen
    ├── dpkg-selections.txt           # dpkg-Paketliste
    ├── dpkg-installed-versions.txt   # Installierte Pakete mit Versionen
    ├── apt-sources/                  # APT-Paketquellen
    │   ├── sources.list
    │   ├── docker.list
    │   └── apt-keys.asc
    ├── docker/                       # Docker-Konfigurationen
    │   ├── container-list.txt
    │   ├── inspect-container1.json
    │   ├── inspect-container2.json
    │   ├── networks.txt
    │   ├── images.txt
    │   └── compose-_opt_coolify-docker-compose.yml
    └── docker-volumes/               # Docker-Volume-Backups (optional)
        ├── volume-list.txt
        ├── volume1.tar.gz
        └── volume2.tar.gz
```

## Wiederherstellung

### dpkg-Pakete wiederherstellen:
```bash
cd /var/backups/vps-updates/20240115_143022/
dpkg --set-selections < dpkg-selections.txt
apt-get dselect-upgrade
```

### APT-Sources wiederherstellen:
```bash
cd /var/backups/vps-updates/20240115_143022/
cp -r apt-sources/* /etc/apt/
apt-get update
```

### Docker-Container anhand der Backups neu erstellen:
```bash
cd /var/backups/vps-updates/20240115_143022/docker/
# Nutzen Sie die inspect-*.json Dateien als Referenz für:
# - Container-Konfigurationen
# - Environment-Variablen
# - Volume-Mounts
# - Netzwerk-Einstellungen
```

### Docker-Volumes wiederherstellen:
```bash
cd /var/backups/vps-updates/20240115_143022/docker-volumes/
docker volume create volume1
tar -xzf volume1.tar.gz -C /var/lib/docker/volumes/volume1/_data/
```

## Systemvoraussetzungen

- Ubuntu 20.04 LTS oder neuer (getestet mit 24.04 LTS)
- Root-Rechte
- Bash 4.0 oder neuer
- Mindestens 500MB freier Speicherplatz (konfigurierbar)
- Standard-Tools: `dpkg`, `apt`, `tar`, `df`, `du`
- Optional: Docker für Docker-Backups

## Troubleshooting

### Backup schlägt fehl: "Unzureichender Speicherplatz"
- Prüfen Sie den freien Speicherplatz mit `df -h`
- Reduzieren Sie die Anzahl der aufbewahrten Backups
- Verwenden Sie ein anderes Backup-Verzeichnis mit mehr Platz

### Docker-Volume-Backup dauert zu lange
- Deaktivieren Sie das Volume-Backup: `VPS_UPDATE_BACKUP_DOCKER_VOLUMES="false"`
- Oder erhöhen Sie das Größenlimit: `VPS_UPDATE_MAX_VOLUME_SIZE_MB="500"`

### Keine Schreibrechte
- Stellen Sie sicher, dass das Skript als root läuft
- Prüfen Sie die Berechtigungen des Backup-Verzeichnisses

## Sicherheitshinweise

- Backups enthalten möglicherweise sensitive Daten (Docker-Umgebungsvariablen, Konfigurationen)
- Stellen Sie sicher, dass das Backup-Verzeichnis angemessen geschützt ist (Berechtigungen 700)
- Übertragen Sie Backups nur über sichere Verbindungen
- Löschen Sie alte Backups regelmäßig oder nutzen Sie die automatische Bereinigung

## Integration in Cron

Für automatische Updates mit Backup:

```bash
# Wöchentliches Update mit Backup (Sonntags um 3 Uhr)
echo "0 3 * * 0 root /root/vps-update.sh >> /var/log/vps-update-cron.log 2>&1" >> /etc/crontab
```

## Changelog

### Version 1.0 (2024-01-15)
- Initiale Version
- Backup von System-Informationen, dpkg, APT-Sources und Docker
- Optionales Docker-Volume-Backup
- Automatische Bereinigung alter Backups
- Umfassende Fehlerbehandlung und Logging
