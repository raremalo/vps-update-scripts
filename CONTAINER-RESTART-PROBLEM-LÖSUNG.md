# Container Restart Problem - Analyse und Lösung

## Problem-Analyse basierend auf script.txt

Die `script.txt` zeigt das Hauptproblem deutlich auf:

### Symptome aus script.txt:
1. **Alle Container gestoppt nach Neustart**
   ```
   CONTAINER ID   IMAGE     COMMAND   CREATED   STATUS    PORTS     NAMES
   ```
   → Keine laufenden Container nach Docker-Neustart

2. **Fehlende Restart Policies**
   ```
   "RestartPolicy": {
       "Name": "",
       "MaximumRetryCount": 0
   }
   ```
   → Container haben keine automatische Restart-Konfiguration

3. **Manuelle Start-Versuche schlagen fehl**
   ```
   docker start coolify coolify-db coolify-redis coolify-realtime coolify-proxy
   "docker start" requires at least 1 argument.
   ```
   → Syntax-Fehler beim manuellen Starten mehrerer Container

4. **Health Check Probleme**
   ```
   "Health": {
       "Status": "unhealthy",
       "Log": [
           {
               "Start": "2024-12-19T13:32:39.486963417Z",
               "End": "2024-12-19T13:33:09.571133709Z",
               "ExitCode": 124,
               "Output": "Health check exceeded timeout (30s)"
           }
       ]
   }
   ```
   → Coolify Container hat Health Check Timeouts

## Betroffene Container aus script.txt:

### Universelle Container-Erkennung:

Die Lösung funktioniert jetzt **automatisch für alle Container** auf jedem Server, ohne spezifische Container-Namen zu benötigen.

### Intelligente Container-Kategorisierung:

**Priorität 1 - Datenbanken (zuerst starten):**
- Container mit Namen-Mustern: `postgres`, `postgresql`, `mysql`, `mariadb`, `mongo`, `redis`, `db`
- Beispiele: `coolify-db`, `postgres-xyz`, `redis-cache`

**Priorität 2 - Coolify Core:**
- Container mit exaktem Namen: `coolify`

**Priorität 3 - Coolify Services:**
- Container mit Präfix: `coolify-*`
- Beispiele: `coolify-realtime`, `coolify-proxy`

**Priorität 4 - Proxies/Load Balancer:**
- Container mit Namen-Mustern: `proxy`, `nginx`, `traefik`, `haproxy`
- Beispiele: `app-proxy`, `nginx-lb`

**Priorität 5 - Anwendungen (zuletzt starten):**
- Alle anderen Container
- Beispiele: `listmonk-xyz`, `n8n-abc`, `custom-app`

## Lösung

### 1. Restart Policies konfigurieren
```bash
./fix-all-container-restart-policies.sh
```

**Was das Script macht:**
- **Automatische Erkennung:** Findet alle vorhandenen Container
- **Universelle Konfiguration:** Setzt alle Container auf `restart: unless-stopped`
- **Intelligente Prüfung:** Überspringt bereits konfigurierte Container
- **Detaillierte Statistik:** Zeigt Erfolg/Fehler-Report mit Zahlen
- **Server-unabhängig:** Funktioniert auf jedem Server ohne Anpassung

### 2. Container manuell starten (falls nötig)
```bash
./start-all-containers.sh
```

**Was das Script macht:**
- **Intelligente Erkennung:** Kategorisiert Container automatisch nach Namen-Mustern
- **Prioritäts-basierter Start:** Startet Container in optimaler Reihenfolge:
  1. Datenbanken (postgres, mysql, redis, etc.)
  2. Coolify Core (coolify)
  3. Coolify Services (coolify-*)
  4. Proxies (nginx, traefik, *-proxy)
  5. Anwendungen (alle anderen)
- **Dependency-Management:** Vermeidet Start-Probleme durch korrekte Reihenfolge
- **Universell:** Funktioniert mit beliebigen Container-Namen
- **Detailliertes Monitoring:** Zeigt Status und Health-Checks

### 3. Verbesserte Haupt-Scripts

Die bestehenden Scripts wurden erweitert:

#### `ensure-docker-autostart.sh`
- ✅ Wartezeit für Docker-Initialisierung
- ✅ Detaillierter Status-Report
- ✅ Bessere Fehlerbehandlung

#### `vps-update.sh` & `vps-update-with-backup.sh`
- ✅ Restart-Policy-Konfiguration nach Docker-Neustart
- ✅ Doppelte Absicherung der Autostart-Konfiguration

#### `ensure-coolify-projects-autostart.sh`
- ✅ Robustere Policy-Prüfung
- ✅ Vermeidung redundanter Konfigurationen
- ✅ Besseres Logging

## Verwendung

### Sofortige Problemlösung:
```bash
# 1. Restart Policies setzen
sudo ./fix-all-container-restart-policies.sh

# 2. Container starten
sudo ./start-all-containers.sh

# 3. Autostart testen
sudo systemctl restart docker
sudo docker ps -a
```

### Präventive Maßnahmen:
```bash
# Bei System-Updates verwenden:
sudo ./vps-update-with-backup.sh

# Oder ohne Backup:
sudo ./vps-update.sh
```

## Erwartetes Ergebnis

Nach der Konfiguration sollten:
1. ✅ Alle Container `restart: unless-stopped` haben
2. ✅ Container automatisch nach Docker-Neustart starten
3. ✅ System-Updates keine Container-Ausfälle verursachen
4. ✅ Manuelle Eingriffe nicht mehr nötig sein

## Verifikation

```bash
# Restart Policies prüfen
docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.RestartPolicy}}"

# Autostart testen
sudo systemctl restart docker
sleep 10
docker ps

# Health Status prüfen
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

## Troubleshooting

Falls Container nicht starten:
1. Logs prüfen: `docker logs <container-name>`
2. Health Checks prüfen: `docker inspect <container-name> | grep -A 10 Health`
3. Dependencies prüfen: Datenbank-Container zuerst starten
4. Ports prüfen: `netstat -tulpn | grep <port>`

---

**Erstellt:** $(date)
**Basierend auf:** script.txt Analyse
**Scripts:** fix-all-container-restart-policies.sh, start-all-containers.sh