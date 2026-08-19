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
- 🧠 **LLM-Wiki-Schema (v2)**: `AGENTS.md` (OpenCode/Codex) und `CLAUDE.md` (Claude Code)
  im Vault-Root definieren die Regeln für Ingest / Query / Lint (nach Karpathys Gist)
  – inkl. **Confidence-Scoring, Supersession, Self-Healing-Lint, Typed Relationships,
  Privacy-Filter und Digest** (Erweiterungen aus "LLM Wiki v2" von rohitg00)
  – funktioniert mit beliebigen KI-Agenten
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
   ├── pending.md  ← Inbox: neue Quellen (automatisch gepflegt)
   ├── index.md    ← Katalog aller Seiten
   ├── log.md      ← append-only Chronik
   ├── AGENTS.md   ← Schema für OpenCode / Codex (Ingest/Query/Lint)
   ├── CLAUDE.md   ← Schema für Claude Code
   ├── .meta/      ← interner Verarbeitungsstand (ingested.txt)
   └── .stignore   ← Syncthing: .git wird nicht synchronisiert
   ```
8. **Inbox (Pending)**: `pending.md` je Vault + stündlicher Cron, der neue Quellen
   aus `raw/` automatisch als To-do-Liste einträgt
9. **Backups + Automation**: Git-Auto-Commit (alle 2h), optionale tägliche
   autonome Wartung (Lint/Digest per KI-Agent-Cron, standardmäßig deaktiviert)
10. **Abschluss**: zeigt Syncthing-URL, Zugangsdaten, Server-Device-ID, Folder-IDs und
    eine vollständige Geräte-Anleitung (liegt im Container unter `/root/DEVICE-SETUP.md`,
    Abruf mit `pct pull <VMID> /root/DEVICE-SETUP.md .`)

## Nach der Installation – Geräte anbinden

### Was der Installer am Ende ausgibt

Zum Abschluss zeigt das Script:

- **Syncthing-Web-UI-URL**: `http://<Container-IP>:8384` (mit User/Passwort)
  – hier verwaltest du Geräte und Ordner des Servers
- **Server-Device-ID** und die **IDs beider Folder** (`work` / `private`)
- eine **Kurzfassung** mit den nächsten Schritten
- die **vollständige Anleitung** (`/root/DEVICE-SETUP.md`, Abruf auch per
  `pct pull <VMID> /root/DEVICE-SETUP.md .`)

### Wie dein Vault auf deine Geräte kommt (die "geteilte Ordner"-Frage)

Es gibt **keine einzelne Vault-URL** – und das ist beabsichtigt. Syncthing
synchronisiert Ordner direkt **Gerät-zu-Gerät** (ähnlich wie Git). Der Server
ist der immer-auf-Knoten: Web-UI auf Port `8384`, Übertragungen auf Port `22000`.

Sobald du auf einem Gerät einmal die **Device-IDs ausgetauscht** und den
Folder per **"Ordner teilen"** verbunden hast, erscheint der Vault dort als
ganz **normaler lokaler Ordner**. Obsidian öffnet genau diesen Ordner
("Ordner als Vault öffnen"). Alles Schreiben passiert lokal, Syncthing
hält alle Geräte automatisch auf demselben Stand – das ist das Syncthing-
Modell, nicht ein Cloud-Link.

Kurzfassung pro Gerät:

```text
1. Syncthing installieren und starten
2. Gerät + Server gegenseitig hinzufügen (Server-Device-ID; optional Adresse tcp://<IP>:22000)
3. Auf dem Server "Ordner teilen" → work ODER private mit dem Gerät teilen
4. Der Vault liegt nun lokal → in Obsidian als Vault öffnen
```

## Work / Private-Trennung

- Zwei **komplett getrennte** Vaults und Syncthing-Folders – sie mischen sich nie.
- **Arbeitsgeräte** teilen nur `work`, **private Geräte** nur `private`.
  Dadurch liegen private Dateien physisch nie auf einem Arbeitsgerät.
- Der Server hält beide Vaults (z. B. für Backups) – er sollte entsprechend geschützt sein.

## KI-Agenten anbinden (OpenCode, Claude Code, Codex, ...)

Das Herz des Patterns: **ein LLM-Agent pflegt das Wiki**, du kuratierst Quellen.
Jeder Vault enthält dafür zwei Schema-Dateien, die der jeweilige Agent beim
Start automatisch liest:

| Agent              | Datei im Vault | Hinweis |
|--------------------|----------------|---------|
| OpenCode           | `AGENTS.md`    | Agent im Vault-Ordner starten |
| Codex / Codex CLI  | `AGENTS.md`    | wird automatisch eingelesen |
| Claude Code        | `CLAUDE.md`    | wird automatisch eingelesen |
| Andere Agenten     | `AGENTS.md`    | versteht AGENTS.md i.d.R. nativ; sonst Vault-Ordner als Kontext angeben |

### So startest du deinen Agenten

Der Agent läuft ganz normal auf einem Gerät **in dem synchronisierten Vault-Ordner**
(also demselben Ordner, den Obsidian als Vault öffnet):

```bash
# Work-Vault (z.B. auf deinem PC)
cd <dein-syncthing-ordner>/work

# OpenCode
opencode

# Claude Code
claude

# Codex CLI
codex
```

Ohne CLI, für beliebige Agenten: einfach den Vault-Ordner als Projekt/Arbeitsverzeichnis
oder Kontext angeben – die `AGENTS.md`/`CLAUDE.md` sagt dem Agenten, wie die
Struktur ist und welche Workflows gelten.

> Du kannst den Agenten auch direkt auf dem Server ausführen (per SSH):
> `cd /srv/vaults/work && opencode` – egal wo er läuft, der Vault ist über
> Syncthing immer aktuell.

### Was die Agenten tun (aus der AGENTS.md/CLAUDE.md)

- **Ingest**: Quelle ablegen → der Agent liest, schreibt wiki-Seiten,
  aktualisiert `index.md` und `log.md`, verknüpft Querverweise
- **Query**: Fragen gegen das Wiki beantworten, wertvolle Antworten wieder
  als neue Seiten ablegen (das Wissen kompoundiert!)
- **Lint**: Widersprüche finden und auflösen, verwaiste Seiten, veraltete Claims,
  Qualitätsprobleme – und selbst heilen, was heilbar ist (self-healing)

Tipp: Mit dem **Obsidian Web Clipper** lassen sich Webartikel direkt als `.md`
in `raw/` ablegen – so bleibt der Ingest-Workflow denkbar einfach.

## Qualitätssicherung (Erweiterungen aus "LLM Wiki v2")

Das generierte Schema baut auf Karpathys v1 auf und übernimmt die Mechaniken,
die [rohitg00s "LLM Wiki v2"](https://gist.github.com/rohitg00/2067ab416f7bbe447c1977edaaa681e2)
aus dem Betrieb mit `agentmemory` beigesteuert hat – damit das Wiki nicht "verrottet":

- **Confidence-Scoring**: Jede wiki-Seite trägt im Frontmatter `confidence`, `sources`,
  `last_confirmed`. Der Agent schätzt die Zuverlässigkeit ein und `lint` senkt sie,
  wenn nichts die Behauptung kürzlich bestätigt hat.
- **Supersession**: Neue Informationen markieren die alte Seite als `superseded_by`
  (statt sie zu überschreiben oder zu löschen) – Versionierung für Wissen.
- **Self-Healing-Lint**: Der Lint-Pass repariert Verwaiste, fehlende Links und
  unstrukturierte Seiten automatisch und löst Widersprüche (Quell-Alter + Autorität + Belege).
- **Typed Relationships**: `relationships: [{relation, target}]` mit Typen wie
  `uses`, `depends-on`, `contradicts`, `supersedes` – der Agent kann bei
  Beziehungsfragen den Graphen durchlaufen statt nur zu suchen.
- **Privacy-Filter**: Beim Ingest werden API-Keys, Tokens, Passwörter und PII
  entfernt; `log.md` dient als Audit-Trail aller Änderungen.
- **Digest/Kristallisation**: Abgeschlossene Recherche-/Debug-Sessions werden zu
  komprimierten `digest`-Seiten (Frage, Erkenntnisse, Lehren) verdichtet.

Alles ist modular – wer's schlank will, nutzt nur v1. Die v2-Mechaniken stecken
bewusst in der Schema-Datei (`AGENTS.md`/`CLAUDE.md`) und lassen sich bei Bedarf
an- und ausbauen.

## Täglicher Workflow & Automatisierung

So sieht der alltägliche Ablauf aus – der Agent verdaut die Informationen, die
immer wieder dazukommen, in einem festen Kreislauf:

```text
CAPTURE → INBOX → INGEST → PFLEGE
  │         │        │        │
  │         │        │        └─ Lint + Digest (manuell ODER autonom)
  │         │        └────────── Agent ordnet ein: Confidence, Relationships,
  │         │                     wiki-Seiten, index.md, log.md
  │         └─────────────────── pending.md listet offene Quellen (stündlich)
  └───────────────────────────── Quelle in raw/ ablegen (Web Clipper, PDF, Datei)
```

1. **Capture (du):** Neue Quelle ablegen – Artikel per Obsidian Web Clipper
   (wird als `.md` + lokale Bilder gespeichert), PDF oder Notiz direkt in `raw/`.
2. **Inbox (automatisch):** Der Cron-Job `track-pending.sh` (stündlich) vergleicht
   `raw/` mit `.meta/ingested.txt` und schreibt neue, unverarbeitete Dateien als
   Checkboxen in `pending.md`. In Obsidian siehst du jederzeit, was wartet.
3. **Ingest (du + Agent):** Du startest den Agenten im Vault und sagst
   `Ingest alle offenen Punkte aus pending.md`. Der Agent liest die Quellen,
   extrahiert Entities, vergibt Confidence, schreibt/aktualisiert wiki-Seiten,
   `index.md` und `log.md`, und trägt die Dateinamen in `.meta/ingested.txt` ein –
   danach verschwinden sie automatisch aus `pending.md`.
4. **Pflege (periodisch):** `Führe Lint aus` findet Widersprüche, verwaiste Seiten
   und Stale Claims und heilt, was heilbar ist. Nach großen Sessions einen
   Digest anlegen lassen (Kristallisation).
5. **Autonom (optional):** Soll der Server ohne Zutun täglich um 03:15
   Lint + Digest fahren, installierst du deinen Agenten zusätzlich im Container
   und aktivierst es mit einem Befehl:

   ```bash
   # im Container (ggf. Docker/Komplett-Install nötig, z. B. opencode):
   curl -fsSL https://opencode.ai/install | bash
   touch /etc/secondbrain/autonomous        # aktiviert den täglichen Cron
   tail -f /var/log/secondbrain-maintain.log
   ```

   Ingest bleibt bewusst **manuell** – Kuratieren und Ausrichten soll am Menschen
   hängen (wie von Karpathy empfohlen); nur die Wartung (Lint/Digest) ist
   automatisierbar. Der Cron erkennt automatisch, welcher Agent installiert ist
   (opencode / claude / codex) und nutzt dessen Headless-Modus.

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

**v2-Erweiterungen:** Das Schema übernimmt zudem Mechanismen aus
**rohitg00s "LLM Wiki v2"** (["LLM Wiki v2"](https://gist.github.com/rohitg00/2067ab416f7bbe447c1977edaaa681e2),
Confidence-Scoring, Supersession, Self-Healing-Lint, Typed Relationships,
Privacy-Filter, Digest), das die Erfahrungen aus
[agentmemory](https://github.com/rohitg00/agentmemory) dokumentiert.
Auch dieses Gist steht ohne explizite Lizenz – wir übernehmen keine Texte,
sondern setzen die Ideen als eigene Schema-Regeln um.

**Script-Stil:** Der Installer folgt dem Stil der Proxmox-Community-Install-Scripts
([community-scripts](https://github.com/community-scripts/ProxmoxVE) / ursprünglich tteck).

**KI-Agenten:** Als Wiki-Maintainer kommen beliebige AGENTS.md-/CLAUDE.md-fähige
Agenten in Frage, z. B. [OpenCode](https://opencode.ai) (open-source),
[Claude Code](https://docs.anthropic.com/en/docs/claude-code) oder
[OpenAI Codex](https://developers.openai.com/codex/). Die Schema-Dateien in
den Vaults legen fest, wie sie arbeiten.

**Obsidian & Syncthing** sind unabhängige Open-Source-Projekte:
[obsidian.md](https://obsidian.md) · [syncthing.net](https://syncthing.net)

---

*Dieses Projekt ist nicht mit Obsidian, Syncthing, Proxmox oder Andrej Karpathy verbunden
oder von diesen gesponsert. Alle Markennamen gehören ihren jeweiligen Inhabern.*
