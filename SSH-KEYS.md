# SSH-Key-Zuordnung VPS-Flotte (verifiziert 2026-10-22)

> **Status: feststehend.** Jeder Host hat genau einen funktionierenden Key,
> am 22.10.2026 BatchMode-verifiziert. Diese Tabelle ist die Quelle der
> Wahrheit — `~/.ssh/config` ist danach gebaut (Backup:
> `~/.ssh/config.bak-2026-10-22-keymap`).

## Zuordnung

| Alias | Host / Port | Login | Key | 1Password-Name |
|---|---|---|---|---|
| `lorini` | 202.61.242.230:2222 | shogun | `~/.ssh/id_ed25519` (Datei) | — (ansible@ralflorini) |
| `vmd185359` | 31.220.81.151:2222 | shogun | `~/.ssh/id_ed25519` (Datei) | — |
| `vmd202656` | 169.58.100.36:2223 | shogun | `~/.ssh/vmd202656_shogun.pub` | „SSH-Key shogun VPS 6" |
| `vmd183199` | 213.199.41.105:22 | shogun | `~/.ssh/vmd183199.pub` | „SSH-Key VPS vmd183199" |
| `vmd168223` | 95.111.238.95:22 | shogun | `~/.ssh/vmd168223.pub` | „Shogun SSH Key vpsvmd168223" |
| `vmd168223-alt` | 95.111.238.95:2222 | shogun | `~/.ssh/vmd168223.pub` | dito |
| `vmd168223-root` | 95.111.238.95:22 | **root** | `~/.ssh/vmd168223.pub` | dito |
| `vmd168409` | 161.97.88.214:2222 | shogun | `~/.ssh/vmd168409_shogun.pub` | „SSH-Key shogun@vmd168409 mailcow" |
| `vmd168409-root` | 161.97.88.214:2222 | **root** | `~/.ssh/vmd168409_root.pub` | „SSH-Key root@vmd168409 mailcow" |
| `git.brillenwerk.org` | :2223 | git | `~/.ssh/gitea_ed25519.pub` | „Gitea SSH-Key" |

## Warum .pub-Dateien als IdentityFile

Die privaten Keys der 1Password-Einträge liegen nur im Agent
(`Host *` → `IdentityAgent` in `~/.ssh/config`). Zeigt `IdentityFile` auf
die `.pub`, bietet SSH gezielt genau diesen einen Key an — der Agent liefert
die Signatur. Das ist der einzige Weg, bei 11 Agent-Keys unter
`MaxAuthTries 6` sicher anzukommen.

## Wichtige Randbedingungen

- **`IdentitiesOnly=no` ist verboten.** Der Agent bietet 11 Keys an, sshd
  bricht nach 6 Versuchen ab ("Too many authentication failures") UND
  bestraft die Quell-IP — am 22.10. führte ein Probe-Sturm gegen vmd183199
  zu kex-Resets (Quell-IP-Sperre ~10–60 min).
- **Docker-Zugriff** geht nur über root: `vmd168223-root` (shogun dort ohne
  docker-Gruppe und ohne sudo) und `vmd168409-root` (shogun sieht docker
  dort nicht). Brightbean läuft auf vmd168223 → Deploys/Wartung über
  `vmd168223-root`.
- **lorini root**: existiert (Agent-Key „Netcup Server Lorini root & Shogun"),
  noch ohne Alias — bei Bedarf anlegen wie vmd168223-root.
- Neuer Host? Key in 1Password anlegen, `.pub` exportieren
  (`SSH_AUTH_SOCK=<agent> ssh-add -L`), Block in `~/.ssh/config` +
  Zeile hier, BatchMode-Test, Datum dieser Datei aktualisieren.

## Änderungshistorie

- 2026-10-22: Vollständige Verifikation aller Aliasse; `.pub` für vmd168223
  und vmd183199 angelegt; Alias `vmd168223-root` neu; Header-Mapping in
  `~/.ssh/config` aktualisiert. Auslöser: wiederholtes Key-Rätselraten
  (u. a. Brightbean-Ordner, Deploy-Ziel vmd168223).
