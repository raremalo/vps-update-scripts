# Quick Start Guide

Schnellanleitung für die Installation der VPS Update Scripts.

## 🚀 1-Minute Installation (Auto-Detection)

**Für Server mit Coolify ODER Dokploy - das Script erkennt automatisch!**

```bash
# Als root auf dem VPS Server:

# 1. Verzeichnisse erstellen
mkdir -p /usr/local/lib/vps-script

# 2. Scripts herunterladen
curl -o /usr/local/bin/vps-update-auto.sh \
  https://raw.githubusercontent.com/raremalo/vps-update-scripts/main/vps-update-auto.sh

curl -o /usr/local/lib/vps-script/ensure-docker-autostart-auto.sh \
  https://raw.githubusercontent.com/raremalo/vps-update-scripts/main/ensure-docker-autostart-auto.sh

curl -o /etc/systemd/system/docker-autostart-auto.service \
  https://raw.githubusercontent.com/raremalo/vps-update-scripts/main/docker-autostart-auto.service

# 3. Ausführbar machen
chmod +x /usr/local/bin/vps-update-auto.sh
chmod +x /usr/local/lib/vps-script/ensure-docker-autostart-auto.sh

# 4. Autostart aktivieren
systemctl daemon-reload
systemctl enable docker-autostart-auto.service

# 5. Testen
/usr/local/bin/vps-update-auto.sh
```

## ✅ Fertig!

Das war's! Dein Server ist jetzt bereit für automatische Updates.

## 📝 Verwendung

```bash
# VPS Update durchführen
sudo /usr/local/bin/vps-update-auto.sh

# Logs anschauen
tail -f /var/log/vps-update.log
```

## 🔄 Automatische Updates (Optional)

```bash
# Wöchentlich Sonntag um 2 Uhr
echo "0 2 * * 0 /usr/local/bin/vps-update-auto.sh >> /var/log/vps-update-cron.log 2>&1" | crontab -
```

## 🆘 Hilfe

Bei Problemen siehe [README.md](README.md) oder [Troubleshooting-Sektion](README.md#troubleshooting).
