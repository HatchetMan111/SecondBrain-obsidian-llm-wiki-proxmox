# SecondBrain – Obsidian + Syncthing auf Proxmox (LLM-Wiki-Pattern)

![ShellCheck](https://github.com/HatchetMan111/SecondBrain-obsidian-llm-wiki-proxmox/actions/workflows/shellcheck.yml/badge.svg)
![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)

Ein **Second Brain** nach dem **LLM-Wiki-Pattern** von Andrej Karpathy – gehostet auf
**Proxmox VE**. Der Installer legt einen LXC-Container an, richtet **Syncthing** für
die Synchronisation ein und erzeugt zwei getrennte Obsidian-Vaults: **Work** und
**Private**.

Das Besondere am LLM-Wiki-Pattern: Du sammelst Quellen, und ein LLM-Agent (z.B.
**OpenCode**) pflegt daraus eine verlinkte, sich ständig weiterentwickelnde Wissensdatenbank –
mit Seiten, Querverweisen, Index und einer Lint-Pass gegen Widersprüche. Obsidian ist
dabei die "IDE", der LLM der "Programmierer", das Wiki die "Codebasis".

## Features

- 🚀 **Ein Befehl-Install**: erstellt Container, installiert Syncthing, legt die Vault-Struktur an
- 📁 **Zwei getrennte Vaults**: `work` und `private` – als getrennte Syncthing-Folder, sodass
  privater Inhalt nie auf Arbeitsgeräten landet (und umgekehrt)
- 🔄 **Syncthing**: jeder Vault hat auf jedem Gerät eine lokale Kopie, offline nutzbar,
  Konflikte werden gelöst (Staggered File Versioning 30 Tage)
- 🧠 **LLM-Wiki-Schema**: `AGENTS.md` im Vault-Root definiert für OpenCode die Regeln für
  Ingest / Query / Lint (nach Karpathys Gist)
- 💾 **Mehrfach-Backups**: Syncthing-Versionierung, Git-Auto-Commit (alle 2h) je Vault,
  ZFS-Snapshots über den Proxmox-Backup-Job
- 📱 **Alle Geräte**: Windows, Linux, macOS, Android (Syncthing-App) und iOS (Möbius Sync)

## Architektur

```
Proxmox VE Host
└── LXC-Container "obsidian" (Debian 12, unprivileged, auf ZFS)
    ├── /srv/vaults/work/       ── Syncthing-Folder "work"
    ├── /srv/vaults/private/    ── Syncthing-Folder "private"
    ├── Syncthing (immer an, GUI auf http://<IP>:8384)
    ├── Git-Auto-Commit-Cron (alle 2h je Vault)
    └── Proxmox VZDump-Backup (ZFS-Snapshot)

Geräte (im LAN):
├── Windows / Linux / macOS : Syncthing + Obsidian (lokal)
├── Android                 : Syncthing-App + Obsidian
└── iOS / iPadOS            : Möbius Sync + Obsidian
     (Arbeitsgeräte teilen nur "work", private Geräte nur "private")
```

> **Hinweis**: "Obsidian als Server" gibt es nicht – Obsidian ist eine lokale App.
> Der Server hostet die Vaults + Syncthing, Obsidian läuft nativ auf jedem Gerät und
> greift auf die lokale Syncthing-Kopie zu. Das ist die robusteste Architektur.

## Voraussetzungen

- **Proxmox VE** (7.x oder neuer), als Root per SSH erreichbar
- **ZFS-Storage** empfohlen (für Snapshots) – falls nicht vorhanden, wählt das Script einen anderen Storage
- Internetzugang auf dem Host (für Template-Download und Paketinstallation im Container)
- Dein Proxmox-Host und deine Geräte im selben **LAN** (Zugriff von außen ist absichtlich nicht eingerichtet)

## Schnellstart

Auf dem Proxmox-Host (als root) ausführen:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/SecondBrain-obsidian-llm-wiki-proxmox/main/install-obsidian-llm-wiki.sh)"
```

oder mit curl:

```bash
bash -c "$(curl -sL https://raw.githubusercontent.com/HatchetMan111/SecondBrain-obsidian-llm-wiki-proxmox/main/install-obsidian-llm-wiki.sh)"
```

Das Script fragt die Parameter per Dialog ab (VMID, Hostname, IP, Storage, Disk, RAM,
Cores, SSH-Key optional, Syncthing-Benutzer/-Passwort). Alle Werte haben sinnvolle
Standardwerte – nur auf "Enter" zu drücken funktioniert.

## Was das Script Schritt für Schritt macht

1. **Prüfungen**: läuft auf einem Proxmox-Host? als root?
2. **Parameter**: whiptail-Dialoge mit Defaults
3. **Template**: lädt das aktuelle `debian-12-standard`-Template automatisch
4. **Container**: `pct create` – unprivilegiert, auf ZFS (oder gewähltem Storage)
5. **Software**: installiert Syncthing, Git, curl, jq, cron im Container
6. **Syncthing**: eigener Benutzer + systemd-Dienst, Web-UI mit Auth auf `0.0.0.0:8384`,
   beide Folders `work`/`private` vorkonfiguriert (inkl. Staggered File Versioning)
7. **Vaults**: legt für `work` und `private` je die Karpathy-Struktur an:
   ```
   <vault>/
   ├── raw/        ← immutable Quellen (append-only)
   ├── wiki/       ← LLM-generierte Seiten
   ├── index.md    ← Katalog aller Seiten
   ├── log.md      ← append-only Chronik
   ├── AGENTS.md   ← Schema für OpenCode (Ingest/Query/Lint)
   └── .gitignore
   ```
8. **Backups**: Git-Init je Vault + Auto-Commit-Cron (alle 2h)
9. **Abschluss**: zeigt Syncthing-URL, Zugangsdaten, Server-Device-ID, Folder-IDs und
   eine vollständige Geräte-Anleitung (liegt im Container unter `/root/DEVICE-SETUP.md`,
   Abruf mit `pct pull <VMID> /root/DEVICE-SETUP.md .`)

## Nach der Installation – Geräte anbinden

Die komplette Anleitung wird beim Install-Abschluss ausgegeben. Kurzfassung:

1. **Syncthing auf dem Gerät** installieren (Desktop: https://syncthing.net,
   Android: Syncthing-App, iOS: Möbius Sync).
2. **Gerät ↔ Server verbinden**: beide müssen sich gegenseitig als Remote-Gerät
   hinzufügen (Device-IDs austauschen) und die Verbindung bestätigen.
3. **Ordner teilen**: auf dem Server den passenden Folder (`work` ODER `private`)
   mit dem Gerät teilen.
4. **Obsidian**: "Ordner als Vault öffnen" und den synchronisierten Ordner wählen.

## Work / Private-Trennung

- Zwei **komplett getrennte** Vaults und Syncthing-Folders – sie mischen sich nie.
- **Arbeitsgeräte** teilen nur `work`, **private Geräte** nur `private`.
  Dadurch liegen private Dateien physisch nie auf einem Arbeitsgerät.
- Der Server hält beide Vaults (z. B. für Backups) – er sollte entsprechend geschützt sein.

## LLM-Maintainer mit OpenCode

Das Herz des Patterns – der LLM pflegt das Wiki, du kuratierst Quellen:

```bash
# auf einem Gerät oder via SSH auf dem Server
cd /srv/vaults/work        # oder .../private
opencode
```

Die `AGENTS.md` im Vault-Root definiert die drei Operationen:

- **Ingest**: Quelle ablegen → OpenCode liest, schreibt wiki-Seiten, aktualisiert Index und Log
- **Query**: Fragen gegen das Wiki beantworten, Antworten wieder als Seiten ablegen (Kompendium!)
- **Lint**: Widersprüche, verwaiste Seiten, veraltete Claims finden

Tipp: Mit dem **Obsidian Web Clipper** lassen sich Webartikel direkt als `.md` in `raw/`
ablegen – so bleibt der Ingest-Workflow denkbar einfach.

## Backups

Drei unabhängige Schichten:

1. **Syncthing "Staggered File Versioning"** (30 Tage, aktiviert) – gelöschte/überschriebene
   Dateien sind im Syncthing-Web-UI wiederherstellbar.
2. **Git-Auto-Commit** (alle 2h) je Vault – History ansehen mit
   `git -C /srv/vaults/work log --oneline`.
3. **Proxmox-Backup** (ZFS-Snapshot): Backup-Job unter *Datacenter → Backups* anlegen
   oder direkt `vzdump <VMID> --mode snapshot --compress zstd`.

## Lizenz & Danksagungen

**Lizenz:** MIT (siehe [LICENSE](LICENSE)). Copyright © 2026 HatchetMan111.

**Idee & Muster:** Dieses Projekt implementiert das *LLM-Wiki-Pattern* von
**Andrej Karpathy** – veröffentlicht als öffentliches Gist
(["LLM Wiki"](https://gist.github.com/karpathy/442a6bf555914e8939891c11519de94f)).
Das Gist beschreibt die Idee (drei Ebenen: raw sources / wiki / schema; Operationen:
Ingest, Query, Lint; Index & Log). Dieses Repo setzt das Muster für Proxmox + Syncthing +
Obsidian um. Karpathys Gist steht unter keiner expliziten Lizenz; wir übernehmen keinen
Text, sondern referenzieren das Pattern und verdanken ihm die Architektur.

**Script-Stil:** Der Installer folgt dem Stil der Proxmox-Community-Install-Scripts
([community-scripts](https://github.com/community-scripts/ProxmoxVE) / ursprünglich tteck).

**LLM-Agent:** Empfohlener Wiki-Maintainer ist [OpenCode](https://opencode.ai), ein
Open-Source-Tool. Andere AGENTS.md-fähige Agenten (z. B. Codex) funktionieren ebenfalls.

**Obsidian & Syncthing** sind unabhängige Open-Source-Projekte:
[obsidian.md](https://obsidian.md) · [syncthing.net](https://syncthing.net)

---

*Dieses Projekt ist nicht mit Obsidian, Syncthing, Proxmox oder Andrej Karpathy verbunden
oder von diesen gesponsert. Alle Markennamen gehören ihren jeweiligen Inhabern.*
