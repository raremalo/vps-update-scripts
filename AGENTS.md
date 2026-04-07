<!-- Generated: 2026-04-07 | Updated: 2026-04-07 -->

# VPS Update Script Suite

## Purpose
Automated VPS server maintenance toolkit for Ubuntu 24.04 LTS with Docker, Coolify, and Dokploy support. Provides update scripts, backup solutions, Docker container management, and autostart configuration with auto-detection of the deployment system in use.

## Key Files

| File | Description |
|------|-------------|
| `vps-update.sh` | Core update script v2.0 for Ubuntu + Coolify + Docker |
| `vps-update-complete.sh` | Extended update with full backup incl. database dumps and volume snapshots |
| `vps-update-simple.sh` | Minimal update without backup for quick maintenance |
| `vps-update-with-backup.sh` | Update v2.2 with integrated backup via `backup-functions.sh` |
| `vps-update-auto.sh` | Auto-detecting update script that routes to Coolify or Dokploy logic |
| `installvps-update.sh` | Installer v3.0 with auto-detection, deploys scripts to `/usr/local/bin` and sets up systemd timers |
| `backup-vps-data.sh` | Standalone backup with DB dumps, volume snapshots, remote backup, and optional encryption |
| `backup-functions.sh` | Shared backup function library (sourced by other scripts) |
| `vps-status.sh` | Quick system status check (updates, reboot, Docker) |
| `ensure-docker-autostart.sh` | Docker autostart configuration with Coolify start order |
| `ensure-docker-autostart-auto.sh` | Auto-detecting autostart script for Coolify/Dokploy |
| `ensure-coolify-projects-autostart.sh` | Coolify project-level autostart management |
| `fix-all-container-restart-policies.sh` | Sets restart policies on all containers |
| `fix-docker-autostart-complete.sh` | Master fix script for container restart problems |
| `start-all-containers.sh` | Intelligent container start with priority ordering |
| `debug-container-restart.sh` | Diagnostic tool for container restart policy issues |
| `test-backup.sh` | Test suite for backup functions |
| `CONTAINER-RESTART-PROBLEM-LÖSUNG.md` | Documentation of container restart problem and solution |

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `coolify/` | Coolify-specific scripts with Soketi startup ordering (see `coolify/AGENTS.md`) |
| `dokploy/` | Dokploy-specific scripts with Traefik integration (see `dokploy/AGENTS.md`) |
| `logs/` | Local log output directory (empty, runtime-generated) |

## For AI Agents

### Working In This Directory

- All scripts are Bash (`#!/usr/bin/env bash` or `#!/bin/bash`) targeting Ubuntu 24.04 LTS
- Scripts use `set -euo pipefail` — strict error handling is mandatory
- Language: comments and user-facing output are in **German**
- Color codes (`RED`, `GREEN`, `YELLOW`, `BLUE`, `NC`) are used consistently for terminal output
- Lock files (`/tmp/vps_update.lock` or `/var/run/vps-update.lock`) prevent concurrent execution
- Logging goes to `/var/log/vps-updates/` or `/var/log/vps-update.log`
- Scripts require root (`EUID -eq 0` check at startup)

### Container Start Order (Critical)

**Coolify:** `coolify-db` → `coolify-redis` → `coolify-realtime` (Soketi) → `coolify` → `coolify-proxy`
**Dokploy:** `dokploy-postgres` → `dokploy-redis` → `dokploy` → `dokploy-traefik`

Soketi (`coolify-realtime`) must start BEFORE the Coolify main container — this is the most common failure point.

### Testing Requirements

- Run `test-backup.sh` after modifying backup functions
- Test autostart scripts by simulating reboot: `systemctl restart docker-autostart-*.service`
- Always verify container order after modifying start/stop logic

### Common Patterns

- `log()` / `err()` wrapper functions for colored+logged output
- `cleanup()` trap on EXIT removes lock files
- Docker compose helpers: `has_compose_project()`, `has_compose_service()`, `has_container()`
- Environment variable overrides with defaults: `${VAR:-default}`
- Auto-detection pattern: check `docker ps -a` output for container name patterns

## Dependencies

### External

- `docker` / `docker compose` — container runtime
- `apt-get` — Ubuntu package management
- `systemd` / `systemctl` — service and timer management
- `rsync` — used for remote backups
- `gpg` — optional backup encryption

<!-- MANUAL: Any manually added notes below this line are preserved on regeneration -->
