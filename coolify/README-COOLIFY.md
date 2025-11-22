# VPS Update Scripts für Coolify

Coolify-optimierte VPS Update Scripts mit **Soketi-Support**.

## ⚠️ Wichtig: Soketi/Realtime Service

Coolify benötigt den **Soketi (Realtime) Service**, der **VOR** dem Coolify-Hauptcontainer starten muss. Diese Scripts gewährleisten die korrekte Start-Reihenfolge.

## 🔄 Korrekte Start-Reihenfolge

```
1. coolify-db (PostgreSQL)
2. coolify-redis (Cache)
3. coolify-realtime (Soketi) ⭐ WICHTIG: Muss VOR Coolify starten!
4. coolify (Hauptcontainer)
5. coolify-proxy (Reverse Proxy)
```

## 📁 Enthaltene Dateien

- `vps-update-coolify.sh` - Haupt-Update-Script
- `ensure-docker-autostart-coolify.sh` - Autostart nach Reboot
- `docker-autostart-coolify.service` - Systemd Service
- `README-COOLIFY.md` - Diese Datei

## 🚀 Installation

```bash
# Auf dem VPS Server als root:

# Verzeichnis erstellen
mkdir -p /usr/local/lib/vps-script

# Scripts herunterladen
curl -o /usr/local/bin/vps-update-coolify.sh \
  https://raw.githubusercontent.com/raremalo/vps-update-scripts/main/coolify/vps-update-coolify.sh

curl -o /usr/local/lib/vps-script/ensure-docker-autostart-coolify.sh \
  https://raw.githubusercontent.com/raremalo/vps-update-scripts/main/coolify/ensure-docker-autostart-coolify.sh

curl -o /etc/systemd/system/docker-autostart-coolify.service \
  https://raw.githubusercontent.com/raremalo/vps-update-scripts/main/coolify/docker-autostart-coolify.service

# Ausführbar machen
chmod +x /usr/local/bin/vps-update-coolify.sh
chmod +x /usr/local/lib/vps-script/ensure-docker-autostart-coolify.sh

# Systemd Service aktivieren
systemctl daemon-reload
systemctl enable docker-autostart-coolify.service
```

## 💻 Verwendung

### VPS Update durchführen

```bash
sudo /usr/local/bin/vps-update-coolify.sh
```

### Was macht das Script?

1. **Prüft Voraussetzungen** - Root-Rechte, Lock-File, Coolify-Installation
2. **Stoppt Container** - In umgekehrter Reihenfolge (Proxy → Coolify → Soketi → Redis → DB)
3. **Aktualisiert System** - `apt-get update`, `upgrade`, `dist-upgrade`
4. **Startet Coolify** - In korrekter Reihenfolge (DB → Redis → **Soketi** → Coolify → Proxy)
5. **Verifiziert Services** - Prüft dass alle Container laufen
6. **Startet andere Container** - Alle mit Restart-Policy
7. **Prüft Reboot** - Falls Kernel-Update: Automatischer Neustart nach 30 Sek

## 🔍 Soketi-Probleme beheben

Falls Soketi nicht startet:

```bash
# Soketi-Status prüfen
docker logs coolify-realtime

# Soketi manuell starten
docker start coolify-db coolify-redis
sleep 10
docker start coolify-realtime
sleep 10
docker start coolify
sleep 5
docker start coolify-proxy

# Überprüfen ob Soketi läuft
docker ps | grep coolify-realtime
```

## 📊 Coolify-spezifische Container

| Container | Zweck | Kritisch |
|-----------|-------|----------|
| `coolify-db` | PostgreSQL Datenbank | ✅ Ja |
| `coolify-redis` | Cache/Queue | ✅ Ja |
| `coolify-realtime` | Soketi (Realtime/WebSocket) | ⭐ **KRITISCH** |
| `coolify` | Haupt-Anwendung | ✅ Ja |
| `coolify-proxy` | Reverse Proxy | ⚠️ Wichtig |

## 🔧 Troubleshooting

### Coolify funktioniert nicht nach Update

```bash
# 1. Prüfe ob Soketi läuft (häufigste Fehlerquelle!)
docker ps | grep coolify-realtime

# 2. Falls Soketi nicht läuft, manuell starten:
docker start coolify-realtime
sleep 10
docker restart coolify

# 3. Logs prüfen
docker logs coolify
docker logs coolify-realtime
```

### Soketi startet nicht

```bash
# Datenbank zuerst prüfen
docker ps | grep coolify-db
docker logs coolify-db

# Redis prüfen
docker ps | grep coolify-redis
docker logs coolify-redis

# Soketi neu starten
docker restart coolify-realtime
docker logs -f coolify-realtime
```

### Services starten nicht automatisch nach Reboot

```bash
# Service-Status prüfen
systemctl status docker-autostart-coolify.service

# Logs anschauen
journalctl -u docker-autostart-coolify.service -n 50

# Service neu starten
systemctl restart docker-autostart-coolify.service
```

## 📝 Logs

```bash
# Update-Logs
tail -f /var/log/vps-update.log

# Autostart-Logs  
tail -f /var/log/docker-autostart.log

# Coolify-Logs
docker logs -f coolify

# Soketi-Logs
docker logs -f coolify-realtime
```

## 🛡️ Best Practices

### Vor dem Update

1. VPS Snapshot erstellen
2. Coolify-Datenbank sichern
3. Prüfen dass alle Container laufen: `docker ps`

### Nach dem Update

1. Container-Status prüfen: `docker ps`
2. **Soketi verifizieren**: `docker ps | grep coolify-realtime`
3. Coolify Web-Interface testen
4. Logs prüfen: `tail -f /var/log/vps-update.log`

## 🔗 Links

- [Coolify Dokumentation](https://coolify.io/docs)
- [Hauptrepository](https://github.com/raremalo/vps-update-scripts)

---

**⚠️ Hinweis:** Wenn du mehrere Server mit verschiedenen Systemen (Coolify UND Dokploy) hast, verwende das Auto-Detection Script aus dem Hauptverzeichnis!
