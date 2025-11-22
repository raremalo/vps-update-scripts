# VPS Update Scripts für Dokploy

Angepasste Version der Coolify VPS Update Scripts, optimiert für Dokploy.

## 📋 Übersicht

Diese Scripts wurden von den Coolify-optimierten VPS Update Scripts angepasst und berücksichtigen die spezifischen Unterschiede von Dokploy:

### Hauptunterschiede Coolify vs. Dokploy

| Feature | Coolify | Dokploy |
|---------|---------|---------|
| Hauptcontainer | `coolify` | `dokploy` |
| Datenbank | `coolify-db` | `dokploy-postgres` |
| Cache | `coolify-redis` | `dokploy-redis` |
| Realtime Service | `coolify-realtime` (Soketi) | ❌ Nicht vorhanden |
| Proxy | `coolify-proxy` | `dokploy-traefik` (Traefik) |
| Standard-Pfad | `/data/coolify/source` | `/etc/dokploy` (oder `/opt/dokploy`) |

### ⚠️ Wichtige Anpassungen

1. **Kein Soketi**: Dokploy benötigt keinen separaten Realtime-Service
2. **Vereinfachte Start-Reihenfolge**: DB → Redis → Dokploy → Traefik
3. **Automatische Pfad-Erkennung**: Script sucht nach docker-compose.yml in verschiedenen Pfaden
4. **Traefik statt eigenem Proxy**: Verwendet Traefik als Reverse-Proxy

## 📁 Enthaltene Dateien

```
vps-update-dokploy.sh                  # Haupt-Update-Script
ensure-docker-autostart-dokploy.sh     # Autostart nach Reboot
docker-autostart-dokploy.service       # Systemd Service für Autostart
README-DOKPLOY.md                      # Diese Datei
```

## 🚀 Installation

### 1. Scripts auf den Server kopieren

```bash
# Von deinem lokalen System
scp vps-update-dokploy.sh root@dein-server:/usr/local/bin/
scp ensure-docker-autostart-dokploy.sh root@dein-server:/usr/local/lib/vps-script/
scp docker-autostart-dokploy.service root@dein-server:/etc/systemd/system/
```

### 2. Verzeichnisse erstellen (auf dem Server)

```bash
sudo mkdir -p /usr/local/lib/vps-script
sudo mkdir -p /var/log
```

### 3. Scripts ausführbar machen

```bash
sudo chmod +x /usr/local/bin/vps-update-dokploy.sh
sudo chmod +x /usr/local/lib/vps-script/ensure-docker-autostart-dokploy.sh
```

### 4. Systemd Service aktivieren (für Autostart nach Reboot)

```bash
sudo systemctl daemon-reload
sudo systemctl enable docker-autostart-dokploy.service
```

### 5. Testen (optional aber empfohlen)

```bash
# Test des Autostart-Scripts
sudo /usr/local/lib/vps-script/ensure-docker-autostart-dokploy.sh

# Logs anschauen
tail -f /var/log/docker-autostart.log
```

## 💻 Verwendung

### Manuelles Update durchführen

```bash
sudo /usr/local/bin/vps-update-dokploy.sh
```

### Was macht das Script?

1. **Voraussetzungen prüfen**: Root-Rechte, Lock-File, Dokploy-Pfad
2. **Container stoppen**: In korrekter Reihenfolge (Traefik → Dokploy → Redis → PostgreSQL)
3. **System updaten**: `apt-get update`, `upgrade`, `dist-upgrade`
4. **Dokploy starten**: In korrekter Reihenfolge (PostgreSQL → Redis → Dokploy → Traefik)
5. **Andere Container starten**: Alle mit Restart-Policy
6. **Reboot prüfen**: Falls Kernel-Update, automatischer Neustart nach 30 Sek

### Logs anschauen

```bash
# Update-Logs
tail -f /var/log/vps-update.log

# Autostart-Logs
tail -f /var/log/docker-autostart.log

# Oder mit journalctl
journalctl -u docker-autostart-dokploy.service -f
```

## 🔄 Nach Server-Neustart

Das Autostart-Script läuft automatisch nach jedem Reboot und:

1. Wartet auf Docker-Service (max. 60 Sekunden)
2. Startet Dokploy-Stack in korrekter Reihenfolge
3. Verifiziert, dass alle Services laufen
4. Startet andere Container mit Restart-Policy
5. Schreibt Status in Log-Datei

## 🛡️ Sicherheit & Best Practices

### Vor dem ersten Update

```bash
# 1. Snapshot bei deinem VPS-Provider erstellen
# 2. Teste das Script auf einem Test-Server (falls möglich)
# 3. Prüfe ob alle Container laufen
docker ps

# 4. Führe Update durch
sudo /usr/local/bin/vps-update-dokploy.sh
```

### Nach dem Update

```bash
# Prüfe Container-Status
docker ps

# Prüfe Dokploy-Dienste
curl -I http://localhost:3000

# Logs prüfen
tail -f /var/log/vps-update.log
```

## 🔧 Troubleshooting

### Dokploy startet nicht

```bash
# Manuelle Container-Reihenfolge
docker start dokploy-postgres
sleep 5
docker start dokploy-redis
sleep 5
docker start dokploy
sleep 5
docker start dokploy-traefik

# Logs anschauen
docker logs dokploy
docker logs dokploy-postgres
```

### Script findet Dokploy nicht

Das Script sucht automatisch in folgenden Pfaden nach `docker-compose.yml`:
- `/etc/dokploy`
- `/opt/dokploy`
- `/var/lib/dokploy`
- `/root/dokploy`

Falls Dokploy woanders installiert ist:

```bash
# Finde docker-compose.yml
find / -name "docker-compose.yml" -path "*dokploy*" 2>/dev/null

# Passe DOKPLOY_PATH im Script an (Zeile 12)
```

### Services starten nicht automatisch nach Reboot

```bash
# Prüfe systemd Service
systemctl status docker-autostart-dokploy.service

# Teste manuell
sudo /usr/local/lib/vps-script/ensure-docker-autostart-dokploy.sh

# Logs prüfen
journalctl -u docker-autostart-dokploy.service -n 50
```

## 📊 Vergleich mit Coolify-Script

### Was wurde entfernt?

- ❌ Soketi/Realtime-Service Start/Stop
- ❌ Spezifische Soketi-Wartezeiten
- ❌ Coolify-spezifische Pfade

### Was wurde angepasst?

- ✅ Container-Namen (dokploy statt coolify)
- ✅ Service-Reihenfolge (ohne Soketi)
- ✅ Automatische Pfad-Erkennung
- ✅ Traefik statt Coolify-Proxy

### Was ist gleich geblieben?

- ✅ Grundlegende Update-Logik
- ✅ Lock-File Mechanismus
- ✅ Logging-System
- ✅ Reboot-Erkennung
- ✅ Restart-Policy Handling

## 📝 Anpassungen & Erweiterungen

### Backup hinzufügen (optional)

Falls du das Backup-Feature aus dem Coolify-Script brauchst, kannst du es hinzufügen:

```bash
# Vor stop_docker_containers() einfügen:
create_backup() {
    log "INFO" "Erstelle Backup..."
    # Backup-Logik hier
}

# In main() Funktion hinzufügen:
create_backup  # vor stop_docker_containers
```

### E-Mail-Benachrichtigungen (optional)

```bash
# Nach check_reboot_required() einfügen:
send_notification() {
    echo "VPS Update abgeschlossen auf $(hostname)" | \
        mail -s "VPS Update" deine@email.com
}
```

## 🆘 Support

Bei Problemen:

1. Logs prüfen: `/var/log/vps-update.log` und `/var/log/docker-autostart.log`
2. Container-Status: `docker ps -a`
3. Systemd-Status: `systemctl status docker-autostart-dokploy.service`
4. Manuell debuggen: Führe einzelne Funktionen aus dem Script manuell aus

## 📄 Lizenz

Angepasst von den Coolify VPS Update Scripts.
Frei verwendbar für deine Server-Infrastruktur.
