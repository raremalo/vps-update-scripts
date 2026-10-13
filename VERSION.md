# VPS Script Collection - Version History


## vps-update-auto.sh v2.2 - Apt-Lock Pre-Flight & Lock-Diagnose (2026-10-04, Review-Fixes 2026-10-13)

**Vorfall** (Mailcow-Host): Der Lauf stoppte erst ALLE Container und wartete
dann 300s vergeblich auf den apt-Lock — gehalten von einem anderen Prozess
(typisch: `unattended-upgrades`). Ergebnis: 5:40 min Mail-Downtime, Abbruch
ohne Update, Notfall-Restart.

- **Apt-Lock-Prüfung VOR dem Container-Stopp**: Ist der Lock länger als
  `APT_LOCK_WAIT` (Default 300s) belegt, endet der Lauf mit Exit 1, bevor
  irgendein Container angefasst wird — keine Downtime mehr im Warteloop.
- **Lock-Inhaber-Diagnose**: `wait_for_apt_lock` protokolliert beim ersten
  Warten und beim Timeout, welcher Prozess die apt/dpkg-Locks hält
  (PID, User, Laufzeit) — statt nur "Lock konnte nicht erhalten werden".
- **Root-Check vor dem Banner**: Aufruf ohne sudo erzeugt keine
  tee-Fehlermeldungen mehr auf `/var/log/vps-update.log`;
  `--check-ssh-only` bleibt bewusst ohne root aufrufbar.
- **Review-Fixes (Codex gpt-6-astra, 13.10.2026, REQUEST CHANGES)**:
  - B1 (MAJOR): `fuser` meldet denselben Prozess mehrfach, wenn er mehrere
    Lock-Dateien hält (Regelfall); `ps -p 4242 4242 -o …` stirbt auf
    procps an "process ID list syntax error" → Diagnose still leer.
    Fix: PIDs splitten, deduplizieren, als EINE kommagetrennte, quotierte
    `-p`-Liste übergeben; Regex-Gate gegen Müll-Eingaben.
  - B2 (MINOR): Historischer Rot-Beweis (`TEST_LOGIC_TARGET` auf Stand vor
    v2.2) starb beim Extrahieren der neuen Funktionen, bevor Assertionen
    liefen. Fix: `extract_fn_optional` mit No-Op-Fallback; nachgewiesen
    6 rot / 1 grün gegen `5bfbfd4`.
- **Tests**: Neue Fallgruppe `apt-lock` in `tools/test-logic.sh`
  (Lock-Zustände inkl. Doppel-/Mehrfach-PID + main()-Reihenfolge; Suite
  42/42). ps-Stub erzwingt jetzt den Argumentvertrag (`-p CSV -o fmt`,
  keine Duplikate) und diskriminiert die Mutation nachweislich.

## Version 3.0.0 - Enterprise Backup & Advanced Monitoring (2024-12-19)

### 🚀 Major Release - Professional VPS Management Suite

#### New Scripts Added:
- **`backup-vps-data.sh`** - Standalone enterprise backup solution
  - Automatic database dumps (PostgreSQL, MySQL, MongoDB, Redis)
  - Remote backup support via SCP
  - OpenSSL encryption support
  - Intelligent volume backup with size limits
  - Auto-generated restore scripts
  
- **`vps-update-simple.sh`** - Lightweight update alternative
  - No backup overhead for quick updates
  - Interactive reboot confirmation
  - Colored terminal output for better UX

#### Enhanced Scripts:
- **`ensure-docker-autostart.sh`** - Extended monitoring capabilities
  - Soketi port verification (Port 6001)
  - System health checks (Memory, Disk, Network)
  - Detailed container start verification
  - Error handling with line tracking

- **`vps-update-complete.sh`** - Full-featured update with backup
  - Integrated database backups
  - Critical volume prioritization
  - Compressed backup archives
  - Restore guide generation

#### Key Improvements:
- ✅ **Enterprise Backup**: Database dumps, remote sync, encryption
- ✅ **Health Monitoring**: System resource checks before operations
- ✅ **Soketi Support**: Improved Coolify real-time service handling
- ✅ **Flexible Updates**: Choose between simple, standard, or complete updates
- ✅ **Better Recovery**: Auto-generated restore guides with step-by-step instructions

### 📊 Statistics:
- **4 new scripts added**
- **2 scripts significantly enhanced**
- **2,539 lines of new code**
- **Extended backup capabilities**
- **Professional monitoring features**

---

## Version 2.0.0 - Universal Docker Container Management (2024-12-19)

### 🚀 Major Features Added

#### New Scripts:
- **`fix-all-container-restart-policies.sh`** - Universal restart policy management
- **`start-all-containers.sh`** - Intelligent priority-based container startup
- **`fix-docker-autostart-complete.sh`** - Master script with interactive menu
- **`CONTAINER-RESTART-PROBLEM-LÖSUNG.md`** - Comprehensive documentation

#### Key Improvements:
- ✅ **Universal Compatibility**: No hardcoded container names - works on any server
- ✅ **Automatic Detection**: Intelligent container discovery and categorization
- ✅ **Priority-Based Startup**: Containers start in optimal order (DB → Core → Services → Proxies → Apps)
- ✅ **Detailed Statistics**: Comprehensive monitoring and reporting
- ✅ **Enhanced Error Handling**: Robust failure detection and recovery

### 🔧 Updated Scripts:
- **`ensure-docker-autostart.sh`** - Better initialization and status display
- **`ensure-coolify-projects-autostart.sh`** - More robust policy checks
- **`vps-update.sh`** - Added restart policy configuration after Docker restart
- **`vps-update-with-backup.sh`** - Added restart policy configuration after Docker restart

### 🐛 Problem Solved:
**Issue**: Docker containers not restarting automatically after system reboot
- Missing `restart: unless-stopped` policies
- Manual container start failures
- Coolify health check timeouts
- Dependency order issues

**Solution**: Complete automation with intelligent container management

### 📊 Statistics:
- **8 files changed**
- **686 insertions, 10 deletions**
- **4 new executable scripts**
- **1 comprehensive documentation file**

### 🎯 Usage:
```bash
# Master script with menu:
sudo ./fix-docker-autostart-complete.sh

# Individual scripts:
sudo ./fix-all-container-restart-policies.sh
sudo ./start-all-containers.sh
```

### 🔄 Compatibility:
- Works on any server with Docker
- Automatically detects all containers
- No configuration required
- Universal container name patterns

---

## Version 1.x.x - Previous Versions

### Initial VPS Management Scripts:
- Basic Docker management
- Coolify project handling
- VPS update procedures
- Backup functionality

---

**Commit Hash**: 4b8e9c7  
**Branch**: main  
**Author**: AI Assistant  
**Date**: 2024-12-19