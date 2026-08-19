#!/usr/bin/env bash
# =====================================================================
#  SecondBrain Installer fuer Proxmox VE
#  Obsidian Vaults + Syncthing nach dem LLM-Wiki-Pattern (Karpathy)
#  Work und Private werden als zwei getrennte Vaults gefuehrt.
#
#  Repo: https://github.com/HatchetMan111/SecondBrain-obsidian-llm-wiki-proxmox
#
#  Ausfuehren (auf dem Proxmox-Host, als root):
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/SecondBrain-obsidian-llm-wiki-proxmox/main/install-obsidian-llm-wiki.sh)"
# =====================================================================
# shellcheck disable=SC2154,SC1090,SC2016,SC2317

set -euo pipefail

# ---------------------------------------------------------------------
# Farben / Ausgaben
# ---------------------------------------------------------------------
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[36m"
RESET="\e[0m"

msg_info()  { echo -e "${BLUE}[INFO]${RESET} $*"; }
msg_ok()    { echo -e "${GREEN}[ OK ]${RESET} $*"; }
msg_warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
msg_error() { echo -e "${RED}[FEHLER]${RESET} $*"; }

header() {
  clear
  cat <<"EOF"
==========================================================
  SecondBrain Installer (LLM-Wiki-Pattern nach Karpathy)
  Obsidian-Vaults + Syncthing auf Proxmox VE (LXC)
  Work & Private - getrennte Vaults
==========================================================
EOF
}

# ---------------------------------------------------------------------
# Pruefungen
# ---------------------------------------------------------------------
root_check() {
  if [ "$(id -u)" -ne 0 ]; then
    msg_error "Bitte als root ausfuehren (z.B. sudo -i)."
    exit 1
  fi
}

pve_check() {
  if [ ! -x /usr/bin/pveversion ]; then
    msg_error "Dieses Script muss direkt auf dem Proxmox-Host ausgefuehrt werden."
    exit 1
  fi
  msg_ok "Proxmox VE erkannt: $(pveversion | awk '{print $2}')"
}

# ---------------------------------------------------------------------
# Parameterabfragen (whiptail)
# ---------------------------------------------------------------------
default_vmid() {
  pvesh get /cluster/nextid 2>/dev/null | tr -d '\n'
}

detect_storage() {
  local st
  st=$(pvesm status -content rootdir 2>/dev/null | awk '$2=="zfspool" && $3=="active" {print $1; exit}')
  if [ -z "$st" ]; then
    st=$(pvesm status -content rootdir 2>/dev/null | awk '$3=="active" {print $1; exit}')
  fi
  [ -n "$st" ] || st="local"
  echo "$st"
}

detect_bridge() {
  local b=""
  for c in /sys/class/net/vmbr*; do
    if [ -e "$c" ]; then
      b=$(basename "$c")
      break
    fi
  done
  [ -n "$b" ] || b="vmbr0"
  echo "$b"
}

prompt_whiptail() {
  local title="$1" text="$2" default="$3" result
  if result=$(whiptail --title "$title" --inputbox "$text" 12 70 "$default" 3>&1 1>&2 2>&3); then
    echo "$result"
  else
    msg_error "Abbruch durch Benutzer."
    exit 1
  fi
}

# ---------------------------------------------------------------------
# Hauptprogramm
# ---------------------------------------------------------------------
main() {
  header
  root_check
  pve_check

  local vm_id hostname ct_ip net_conf gw ns bridge storage disk_size ram cores sshkey sync_user sync_pass

  vm_id=$(prompt_whiptail "Container-ID" "Container-ID (VMID):" "$(default_vmid)")
  hostname=$(prompt_whiptail "Hostname" "Hostname des Containers:" "obsidian")
  hostname=$(echo "$hostname" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')

  bridge=$(detect_bridge)
  bridge=$(prompt_whiptail "Netzwerk-Bridge" "Netzwerk-Bridge:" "$bridge")

  ct_ip=$(prompt_whiptail "IP-Adresse" "IP-Adresse + CIDR des Containers (leer = DHCP):\nBeispiel: 192.168.1.100/24" "dhcp")
  if [ "$ct_ip" = "dhcp" ] || [ -z "$ct_ip" ]; then
    ct_ip="dhcp"
    gw=""
    ns=""
  else
    gw=$(prompt_whiptail "Gateway" "Gateway (z.B. 192.168.1.1):" "")
    ns=$(prompt_whiptail "Nameserver" "Nameserver (z.B. 1.1.1.1):" "1.1.1.1")
  fi

  storage=$(detect_storage)
  storage=$(prompt_whiptail "Storage" "Storage fuer Container-Disk (ZFS empfohlen):" "$storage")
  disk_size=$(prompt_whiptail "Disk" "Disk-Groesse (z.B. 16G):" "16G")
  ram=$(prompt_whiptail "RAM (MB)" "RAM in MB:" "2048")
  cores=$(prompt_whiptail "CPU-Cores" "Anzahl CPU-Cores:" "2")

  sshkey=$(prompt_whiptail "SSH-Key (optional)" "Pfad zum oeffentlichen SSH-Schluessel (leer = kein):" "")

  sync_user=$(prompt_whiptail "Syncthing-Web-UI User" "Benutzername fuer das Syncthing-Web-UI:" "syncthing")

  if sync_pass=$(whiptail --title "Syncthing-Web-UI Passwort" --passwordbox "Passwort fuer das Syncthing-Web-UI:" 10 60 "" 3>&1 1>&2 2>&3); then
    :
  else
    msg_error "Abbruch durch Benutzer."
    exit 1
  fi
  if [ -z "$sync_pass" ]; then
    sync_pass=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 14 || true)
    msg_warn "Kein Passwort eingegeben - zufaellig generiert: $sync_pass"
  fi

  # --- Container existiert bereits? ---
  if pct status "$vm_id" >/dev/null 2>&1; then
    msg_error "Container mit ID $vm_id existiert bereits."
    exit 1
  fi

  # --- Template ermitteln / herunterladen ---
  local template_store template_name
  template_store=$(pvesm status -content vztmpl 2>/dev/null | awk '$3=="active" {print $1; exit}')
  [ -n "$template_store" ] || template_store="local"

  template_name=$(pveam available -section system 2>/dev/null | grep -oE 'debian-12-standard_[0-9.]+-[0-9]+_amd64\.tar\.(zst|xz)' | sort -u | tail -1)
  if [ -z "$template_name" ]; then
    msg_warn "Konnte Template-Liste nicht laden - versuche pveam update ..."
    pveam update >/dev/null 2>&1 || true
    template_name=$(pveam available -section system 2>/dev/null | grep -oE 'debian-12-standard_[0-9.]+-[0-9]+_amd64\.tar\.(zst|xz)' | sort -u | tail -1)
  fi
  if [ -z "$template_name" ]; then
    msg_error "Debian-12-Template konnte nicht ermittelt werden. Kein Internetzugang?"
    exit 1
  fi

  if ! pveam list "$template_store" 2>/dev/null | grep -q "$template_name"; then
    msg_info "Lade Template $template_name herunter ..."
    pveam download "$template_store" "$template_name" >/dev/null 2>&1 || {
      msg_error "Template-Download fehlgeschlagen."
      exit 1
    }
  fi
  local template="${template_store}:vztmpl/${template_name}"

  # --- Netzwerk-Konfig ---
  local net_conf
  if [ "$ct_ip" = "dhcp" ]; then
    net_conf="name=eth0,bridge=${bridge},ip=dhcp"
  else
    net_conf="name=eth0,bridge=${bridge},ip=${ct_ip},gw=${gw}"
  fi

  # --- Container anlegen ---
  msg_info "Lege Container $vm_id an (Hostname: $hostname) ..."
  local ssh_args=()
  if [ -n "$sshkey" ]; then
    ssh_args=(--ssh-public-keys "$sshkey")
  fi

  pct create "$vm_id" "$template" \
    --hostname "$hostname" \
    --storage "$storage" \
    --rootfs "${storage}:${disk_size}" \
    --memory "$ram" \
    --cores "$cores" \
    --net0 "$net_conf" \
    ${ns:+--nameserver "$ns"} \
    --unprivileged 1 \
    "${ssh_args[@]}" \
    --start 1 \
    --description "SecondBrain (LLM-Wiki nach Karpathy): Syncthing + Obsidian-Vaults (work/private)" \
    >/dev/null 2>&1 || {
      msg_error "pct create fehlgeschlagen."
      exit 1
    }

  msg_info "Warte auf Container-Start ..."
  for _ in $(seq 1 30); do
    if pct exec "$vm_id" -- true >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  # --- Setup-Script + Parameter in den Container uebertragen ---
  msg_info "Uebertrage Einrichtungsscript in den Container ..."
  awk '/^# ===== INNER_SETUP_START =====$/{f=1;next} /^# ===== INNER_SETUP_END =====$/{f=0} f' "$0" \
    | pct exec "$vm_id" -- tee /root/inner-setup.sh >/dev/null

  printf 'SYNC_GUI_USER=%q\nSYNC_GUI_PASS=%q\n' "$sync_user" "$sync_pass" \
    | pct exec "$vm_id" -- tee /root/setup.env >/dev/null

  # --- Setup ausfuehren ---
  msg_info "Richte Container ein (Syncthing, Vaults, Backups) - das dauert einige Minuten ..."
  if ! pct exec "$vm_id" -- bash /root/inner-setup.sh; then
    msg_error "Einrichtung im Container fehlgeschlagen."
    exit 1
  fi

  # --- Abschluss ---
  local ct_ip_final
  ct_ip_final=$(pct exec "$vm_id" -- sh -c "hostname -I | awk '{print \$1}'" 2>/dev/null | tr -d '\n')
  [ -n "$ct_ip_final" ] || ct_ip_final="$ct_ip"

  clear
  msg_ok "Fertig! Container $vm_id ($hostname) laeuft."
  msg_ok "Syncthing-Web-UI:  http://${ct_ip_final}:8384   (User: ${sync_user})"
  echo
  msg_ok "So verbindest du jetzt dein erstes Geraet (Kurzfassung):"
  msg_ok "  1) Syncthing auf dem Geraet installieren und starten"
  msg_ok "  2) Geraet + Server gegenseitig hinzufuegen: unter 'Add Remote Device'"
  msg_ok "     die Server-Device-ID unten eintragen (auf dem Server dein Geraet bestaetigen)"
  msg_ok "  3) Auf dem Server: 'Ordner teilen' - work ODER private mit deinem Geraet teilen"
  msg_ok "  4) Der Vault erscheint lokal als normaler Ordner -> in Obsidian als"
  msg_ok "     'Ordner als Vault oeffnen' auswaehlen (und ein KI-Agent kann dort arbeiten)"
  echo
  msg_info "Details, Zugangsdaten und Geraete-Anleitung:"
  echo
  pct exec "$vm_id" -- cat /root/DEVICE-SETUP.md
  echo
  msg_info "Die Anleitung liegt auch im Container unter /root/DEVICE-SETUP.md"
  msg_info "Auszug auf dem Host:  pct pull $vm_id /root/DEVICE-SETUP.md ."
}

: <<'INNER_BLOCK'
# ===== INNER_SETUP_START =====
#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source /root/setup.env

export DEBIAN_FRONTEND=noninteractive
CT_SYNC_USER="syncthing"
VAULT_BASE="/srv/vaults"
CONFIG_HOME="/home/syncthing/.config/syncthing"

echo ">>> [1/8] apt update"
for _ in $(seq 1 10); do
  if apt-get update -y >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

echo ">>> [2/8] Pakete installieren"
apt-get install -y --no-install-recommends curl git jq syncthing apache2-utils cron >/dev/null

echo ">>> [3/8] Syncthing-Benutzer anlegen"
if ! id -u "$CT_SYNC_USER" >/dev/null 2>&1; then
  useradd -r -m -d /home/syncthing -s /usr/sbin/nologin "$CT_SYNC_USER"
fi

echo ">>> [4/8] Vault-Verzeichnisse anlegen (work / private)"
mkdir -p "$VAULT_BASE/work/raw" "$VAULT_BASE/work/wiki"
mkdir -p "$VAULT_BASE/private/raw" "$VAULT_BASE/private/wiki"
chown -R "$CT_SYNC_USER":"$CT_SYNC_USER" "$VAULT_BASE"

echo ">>> [5/8] Syncthing-Konfiguration generieren"
mkdir -p "$CONFIG_HOME"
syncthing generate --home="$CONFIG_HOME" >/dev/null
chown -R "$CT_SYNC_USER":"$CT_SYNC_USER" /home/syncthing

mkdir -p "/etc/systemd/system/syncthing@syncthing.service.d"
cat > /etc/systemd/system/syncthing@syncthing.service.d/override.conf <<'EOF'
[Service]
ReadWritePaths=/srv/vaults
EOF
systemctl daemon-reload

systemctl enable syncthing@syncthing.service >/dev/null 2>&1 || true
systemctl start syncthing@syncthing.service

API_KEY=$(grep -oP '(?<=<apikey>)[^<]+' "$CONFIG_HOME/config.xml")
DEVICE_ID=$(grep -oP '<device id="\K[^"]+' "$CONFIG_HOME/config.xml" | head -1)

echo ">>> [6/8] Warte auf Syncthing-API ..."
for _ in $(seq 1 30); do
  if curl -sf -H "X-API-Key: $API_KEY" http://127.0.0.1:8384/rest/system/version >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# Web-UI: Auth + LAN-Zugriff
BCRYPT=$(htpasswd -nbB -C 10 "$SYNC_GUI_USER" "$SYNC_GUI_PASS" 2>/dev/null | cut -d: -f2)
[ -n "$BCRYPT" ] || BCRYPT=$(htpasswd -nbB "$SYNC_GUI_USER" "$SYNC_GUI_PASS" | cut -d: -f2)

cat > /tmp/gui.json <<EOF
{
  "enabled": true,
  "address": "0.0.0.0:8384",
  "user": "$SYNC_GUI_USER",
  "password": "$BCRYPT",
  "useTLS": false,
  "sendBasicAuthPrompt": false,
  "insecureAdminAccess": false,
  "apiKey": "$API_KEY"
}
EOF
curl -s -o /dev/null -H "X-API-Key: $API_KEY" -X PUT -d @/tmp/gui.json \
  http://127.0.0.1:8384/rest/config/gui

# Syncthing-Folders: work + private (mit Staggered File Versioning)
: > /root/folder-ids.txt

add_folder() {
  local label="$1" path="$2" fid
  fid=$(cat /proc/sys/kernel/random/uuid)
  cat > /tmp/folder.json <<EOF
{
  "id": "$fid",
  "label": "$label",
  "path": "$path",
  "type": "sendreceive",
  "rescanIntervalS": 60,
  "fsWatcherEnabled": true,
  "fsWatcherDelayS": 10,
  "ignorePerms": true,
  "autoNormalize": true,
  "devices": [ { "deviceID": "$DEVICE_ID" } ],
  "versioning": {
    "type": "staggered",
    "params": { "cleanInterval": 3600, "maxAge": 2592000, "maxVersions": 5 }
  }
}
EOF
  curl -s -o /dev/null -H "X-API-Key: $API_KEY" -X POST -d @/tmp/folder.json \
    http://127.0.0.1:8384/rest/config/folders
  printf '%s:%s\n' "$label" "$fid" >> /root/folder-ids.txt
}

add_folder "work" "$VAULT_BASE/work"
add_folder "private" "$VAULT_BASE/private"

systemctl restart syncthing@syncthing.service

echo ">>> [7/8] Vault-Scaffolding + Git-Versionierung"
scaffold_vault() {
  local v="$1"
  local base="$VAULT_BASE/$v"

  cat > "$base/index.md" <<'EOF'
# Index

> Dieser Index wird vom LLM-Wiki-Maintainer (OpenCode) gepflegt.

## Wiki

_Noch keine Seiten. Nach dem ersten Ingest legt der LLM hier die Artikel an._

## Struktur

- `raw/` - immutable Quellen (append-only)
- `wiki/` - LLM-generierte Seiten (entities, concepts, synthesis)
EOF

  cat > "$base/log.md" <<'EOF'
# Log

> Append-only Chronik. Format: `## [YYYY-MM-DD] operation | Titel`
> (nutzbar mit: `grep "^## \[" log.md | tail -5`)

EOF

  cat > "$base/AGENTS.md" <<'EOF'
# AGENTS.md - LLM-Wiki-Schema v2 (OpenCode)

Du bist der Wiki-Maintainer dieses Vaults nach dem LLM-Wiki-Pattern von
Andrej Karpathy (v1) mit den Erweiterungen aus "LLM Wiki v2" von rohitg00
(Confidence, Supersession, Self-Healing-Lint, Typed Relationships).
Du schreibst und pflegst das Wiki; der Nutzer kuratiert Quellen und Richtung.

## Struktur

- `raw/` - immutable Quellen, append-only. Nie bearbeiten.
- `wiki/` - von dir gepflegte Markdown-Seiten (entities, concepts, decisions, digests).
- `pending.md` - automatisch gepflegte Inbox: neue Quellen aus `raw/`
  warten hier auf Ingest (wird stuendlich aktualisiert).
- `index.md` - Katalog aller wiki-Seiten, bei jedem Ingest aktualisieren.
- `log.md` - append-only Chronik UND Audit-Trail (siehe unten).
- `.meta/ingested.txt` - Dateinamen der bereits verarbeiteten Quellen
  (eine pro Zeile). Nach dem Ingest eintragen, damit die Quelle aus
  `pending.md` verschwindet.

## Frontmatter-Konvention (jede wiki-Seite)

    title, type (entity|concept|decision|digest), summary,
    sources: [], confidence: 0.0-1.0, last_confirmed: YYYY-MM-DD,
    supersedes: [], superseded_by: [],
    relationships: [{relation, target}]

Relationstypen: uses, depends-on, contradicts, supersedes, caused, fixed.

## Operationen

### Ingest
1. Quelle lesen. Vor dem Schreiben SENSIBLE DATEN entfernen (API-Keys,
   Tokens, Passwoerter, PII) - nie ins Wiki uebernehmen.
2. Kern-Takeaways kurz mit dem Nutzer besprechen.
3. Entities extrahieren (Person/Projekt/Library/Konzept/Datei/Entscheidung)
   mit Typ, Attributen und Beziehungen.
4. Zusammenfassungs-Seite + Entity-/Concept-Seiten schreiben/aktualisieren.
5. Confidence vergeben: Anzahl Quellen + Aktualitaet + Widersprueche.
6. `index.md` aktualisieren.
7. Dateiname der Quelle in `.meta/ingested.txt` eintragen (eine pro Zeile) -
   danach verschwindet sie automatisch aus `pending.md`.
8. Eintrag in `log.md` anfuegen.

### Query
- Zuerst `index.md`, dann die relevanten Seiten.
- Antworten mit Quellenverweisen (`[[quelle]]`) formulieren.
- Wertvolle Antworten als neue `wiki/`-Seite ablegen (Kompendium!).
- Bei Beziehungsfragen ("Was haengt von X ab?") ueber die
  `relationships`-Eintraege wandern, nicht nur Stichwortsuche.

### Supersession
- Neue Info widerspricht/aktualisiert alte: NEUE Seite schreiben, alte
  Seite mit `superseded_by: [[neue]]` markieren (nicht loeschen),
  in `log.md` vermerken (wann/warum).

### Lint (health check, self-healing)
Regelmaessig ausfuehren:
- Widersprueche finden UND aufloesen (Quell-Alter, Quell-Autoritaet,
  Anzahl Belege); der Nutzer kann ueberstimmen.
- Superseded/stale Claims markieren.
- Verwaiste Seiten verlinken oder als orphan flaggen.
- Fehlende Verlinkungen reparieren.
- Retention: Seiten ohne Bestaetigung >90 Tage fuer Review flaggen
  (nicht loeschen!).
- Qualitaet: unstrukturierte/unkontierte Seiten ueberarbeiten.
- Datenluecken vorschlagen, die per Websuche fuellbar sind.

### Digest / Kristallisation
Nach abgeschlossener Recherche-/Debugging-Session einen Digest anlegen:
Frage, Erkenntnisse, beteiligte Dateien/Entities, Lehren. Lehren als
Standalone-Fakten ins Wiki uebernehmen.

## Konventionen

- Kein `raw/` aendern. Keine Geheimnisse ins Wiki.
- `log.md` = Audit-Trail: jeder Ingest/Lint/Supersession mit Zeitstempel
  und Grund. Format: `## [YYYY-MM-DD] operation | Titel`
- Wenn unsicher: lieber fragen als raten.
EOF

  cat > "$base/CLAUDE.md" <<'EOF'
# CLAUDE.md - Erinnerung fuer Claude Code

Dieser Vault folgt dem LLM-Wiki-Pattern von Andrej Karpathy (v1) mit den
Erweiterungen aus "LLM Wiki v2" von rohitg00 (Confidence, Supersession,
Self-Healing-Lint). Das vollstaendige Schema steht in AGENTS.md - lies
es und handle nach dessen Regeln.

## Kernregeln

- `raw/` ist immutable (append-only), nie bearbeiten.
- Wiki-Seiten in `wiki/` schreiben, mit Frontmatter und Quellenverweisen.
- `index.md` bei jedem Ingest aktualisieren, `log.md`-Eintrag anfuegen.
- Ingest / Query / Lint genau wie in AGENTS.md beschrieben durchfuehren.
EOF

  cat > "$base/.gitignore" <<'EOF'
.trash/
.obsidian/workspace*
EOF

  mkdir -p "$base/.meta"
  : > "$base/.meta/ingested.txt"
  cat > "$base/.stignore" <<'EOF'
.git/
EOF
  cat > "$base/pending.md" <<'EOF'
# Pending-Inbox

_Noch keine Quellen. Neue Dateien in `raw/` werden hier automatisch gelistet._
EOF

  git -C "$base" init -q
  git -C "$base" config user.name "Obsidian"
  git -C "$base" config user.email "obsidian@local"
  git -C "$base" add -A
  git -C "$base" commit -qm "Initial"
}

scaffold_vault "work"
scaffold_vault "private"

chown -R "$CT_SYNC_USER":"$CT_SYNC_USER" "$VAULT_BASE"

cat > /usr/local/bin/vault-git-commit <<'EOF'
#!/bin/bash
for v in work private; do
  d=/srv/vaults/$v
  [ -d "$d/.git" ] || continue
  if [ -n "$(git -C "$d" status --porcelain)" ]; then
    git -C "$d" add -A
    git -C "$d" commit -qm "auto: $(date '+%Y-%m-%d %H:%M')"
  fi
done
EOF
chmod +x /usr/local/bin/vault-git-commit

cat > /etc/cron.d/vault-git <<'EOF'
0 */2 * * * root /usr/local/bin/vault-git-commit >/dev/null 2>&1
EOF

cat > /usr/local/bin/track-pending.sh <<'EOF'
#!/bin/bash
# Pending-Inbox je Vault aktualisieren: listet neue Dateien aus raw/,
# die noch nicht in .meta/ingested.txt stehen.
for v in work private; do
  dir=/srv/vaults/$v
  [ -d "$dir/raw" ] || continue
  state="$dir/.meta/ingested.txt"
  [ -f "$state" ] || : > "$state"
  tmp="$(mktemp)"
  : > "$tmp"
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    if ! grep -qxF -- "$base" "$state" 2>/dev/null; then
      printf -- '- [ ] %s  _(entdeckt: %s)_\n' "$base" "$(date +%F)" >> "$tmp"
    fi
  done < <(find "$dir/raw" -maxdepth 1 -type f -print0 | sort -z)
  if [ -s "$tmp" ]; then
    { printf "# Pending-Inbox\n\nNeue Quellen in \`raw/\` warten auf Ingest:\n\n"; cat "$tmp"; } > "$dir/pending.md"
  else
    printf "# Pending-Inbox\n\n_Alle Quellen verarbeitet - nichts zu tun._\n" > "$dir/pending.md"
  fi
  rm -f "$tmp"
  chown syncthing:syncthing "$dir/pending.md" "$dir/.meta/ingested.txt" 2>/dev/null || true
done
EOF
chmod +x /usr/local/bin/track-pending.sh

cat > /usr/local/bin/secondbrain-maintain-cron <<'EOF'
#!/bin/bash
# Optionale taegliche Wartung: Lint + Digest durch einen KI-Agenten.
# Aktivieren: touch /etc/secondbrain/autonomous   (Agent muss im Container installiert sein)
LOG=/var/log/secondbrain-maintain.log
agent=""
for c in opencode claude codex; do
  if command -v "$c" >/dev/null 2>&1; then agent="$c"; break; fi
done
[ -n "$agent" ] || exit 0
for v in work private; do
  dir=/srv/vaults/$v
  [ -d "$dir/.git" ] || continue
  cd "$dir" || continue
  echo "=== $(date '+%Y-%m-%d %H:%M') : $v via $agent ===" >> "$LOG"
  case "$agent" in
    opencode) opencode run "Fuehre Lint und optional einen Digest gemaess AGENTS.md aus. Protokolliere die Aenderungen." >> "$LOG" 2>&1 ;;
    claude)   claude -p "Fuehre Lint und optional einen Digest gemaess CLAUDE.md aus. Protokolliere die Aenderungen." >> "$LOG" 2>&1 ;;
    codex)    codex exec "Fuehre Lint und optional einen Digest gemaess AGENTS.md aus. Protokolliere die Aenderungen." >> "$LOG" 2>&1 ;;
  esac
done
EOF
chmod +x /usr/local/bin/secondbrain-maintain-cron

cat > /etc/cron.d/secondbrain-maintain <<'EOF'
# Stuendlich: Pending-Inbox aktualisieren (kein Token-Verbrauch).
7 * * * * root /usr/local/bin/track-pending.sh >/dev/null 2>&1
# Optional taeglich 03:15: auto Lint/Digest durch KI-Agent.
# Aktivieren mit: touch /etc/secondbrain/autonomous
15 3 * * * root test -f /etc/secondbrain/autonomous && /usr/local/bin/secondbrain-maintain-cron >/dev/null 2>&1
EOF

echo ">>> [8/8] Geräte-Anleitung schreiben"
IP_ADDR=$(hostname -I | awk '{print $1}')

cat > /root/DEVICE-SETUP.md <<EOF
# SecondBrain - Geräte-Einrichtung

## Zugangsdaten / IDs

- Server-IP:        \`$IP_ADDR\`
- Syncthing-Web-UI: \`http://$IP_ADDR:8384\`  (User: \`$SYNC_GUI_USER\`)
- Server-Device-ID: \`$DEVICE_ID\`
- Syncthing-Folders (Server):
EOF
while IFS=: read -r label fid; do
  echo "- \`$label\` -> \`$fid\`" >> /root/DEVICE-SETUP.md
done < /root/folder-ids.txt

cat >> /root/DEVICE-SETUP.md <<EOF

Die Vaults liegen auf dem Server unter:
- Work:    /srv/vaults/work
- Private: /srv/vaults/private

Jeder Vault hat die Struktur: raw/ (Quellen), wiki/ (LLM-Seiten),
index.md, log.md, AGENTS.md (Schema fuer OpenCode/Codex), CLAUDE.md
(Schema fuer Claude Code).

## Wie dein Vault auf deine Geraete kommt

Es gibt keine "Vault-URL": Syncthing synchronisiert Ordner direkt
Geraet-zu-Geraet (aehnlich wie Git-Repos). Der Server ist dabei der
immer-auf-Knoten:

- Web-UI (Server):  http://$IP_ADDR:8384   - hier verwaltest du Geraete und Folder
- Sync-Port:        tcp://$IP_ADDR:22000   - hier laufen die Uebertragungen

Sobald du (1) dein Geraet per Device-ID verbunden und (2) den Ordner auf
dem Server mit deinem Geraet geteilt hast, erscheint der Vault auf deinem
Geraet als ganz normaler lokaler Ordner. Diesen oeffnest du in Obsidian
("Ordner als Vault oeffnen") - derselbe Ordner, den auch dein KI-Agent
liest und schreibt.

## Grundprinzip der Trennung

Arbeitsgeraete teilen NUR den Folder "work", private Geraete NUR den
Folder "private". Der Server hält beide. So landet privater Inhalt nie
auf einem Arbeitsgeraet und umgekehrt.

---

## 1) Desktop (Windows / Linux / Mac)

1. Syncthing installieren (https://syncthing.net) und starten.
2. Web-UI deines Geraets oeffnen (http://127.0.0.1:8384).
3. "Remote-Geraet hinzufuegen": Server-Device-ID oben eintragen.
   Tipp: Als Adresse optional \`tcp://$IP_ADDR:22000\` eintragen, damit
   die Verbindung ohne Discovery sofort aufgebaut wird.
4. Auf dem SERVER (Web-UI http://$IP_ADDR:8384):
   - "Remote-Geraet hinzufuegen" -> Device-ID deines Geraets eintragen.
   - Die Geraete muessen sich gegenseitig kennen und die Verbindung akzeptieren.
5. Auf dem Server: "Ordner teilen" -> den passenden Folder (work ODER private)
   mit deinem Geraet teilen.
6. Auf deinem Geraet: Der geteilte Ordner wird angelegt. Fertig.

## 2) Android

1. "Syncthing" aus dem Play Store installieren.
2. Gleiches Verfahren wie Desktop: Gerät + Server verbinden (Device-IDs
   tauschen), den passenden Ordner (work/private) teilen.
3. In Syncthing den Sync-Ordner an einen gut erreichbaren Ort legen
   (z.B. /storage/emulated/0/Sync/...).

## 3) iOS / iPadOS (iPhone / iPad)

iOS hat kein natives Syncthing. Loesung: "Möbius Sync" (App Store,
Syncthing-kompatibel).
1. Möbius Sync installieren.
2. Server als Remote-Geraet hinzufuegen (Server-Device-ID).
3. Auf dem Server den passenden Ordner mit diesem Geraet teilen.
4. Möbius Sync in "On My iPhone" synchronisieren lassen.
5. Obsidian installieren und diesen lokalen Ordner als Vault oeffnen.

## 4) Obsidian nutzen

1. Obsidian installieren (Desktop oder mobil).
2. "Ordner als Vault oeffnen" und den synchronisierten Ordner waehlen.
3. Obsidian liest/schreibt lokal; Syncthing hält alle Geraete + Server
   auf demselben Stand. Auch mobil kannst du schreiben - es wird
   zuruecksynchronisiert.

## 5) LLM-Maintainer (OpenCode)

Das Herz des Patterns: der Agent pflegt das Wiki, du kuratierst Quellen.

1. Auf einem Geraet (oder via SSH auf den Server) in den Vault wechseln:
   \`cd /srv/vaults/work\`   (oder \`.../private\`)
2. Agent starten (opencode / claude / codex). Die \`AGENTS.md\` bzw.
   \`CLAUDE.md\` im Vault-Root definieren die Regeln.
3. Quellen einfach in \`raw/\` ablegen (z.B. mit dem Obsidian Web Clipper) -
   und dem Agent einfach sagen: "Ingest die offenen Punkte aus pending.md".

## 6) Taeglicher Workflow - wie ordnet der Agent neue Infos zu?

Der Kreislauf: CAPTURE -> INBOX -> INGEST -> PFLEGE

1. CAPTURE (du): Neue Quelle ablegen - Artikel per Obsidian Web Clipper
   (speichert als .md), PDF oder Datei einfach in \`raw/\` ziehen.
2. INBOX (automatisch, stuendlich): \`track-pending.sh\` listet neue Dateien
   aus \`raw/\` in \`pending.md\` (als Checkboxen). In Obsidian siehst du
   jederzeit, was noch wartet.
3. INGEST (du + Agent): Agent im Vault starten und sagen:
   "Ingest alle offenen Punkte aus pending.md". Der Agent liest die Quellen,
   ordnet sie ein (Confidence, Relationships), schreibt/aktualisiert
   wiki-Seiten + \`index.md\` + \`log.md\` und traegt die Dateinamen in
   \`.meta/ingested.txt\` ein. Danach verschwinden sie aus \`pending.md\`.
4. PFLEGE (periodisch): "Fuehre Lint aus" - der Agent findet Widersprueche,
   verwaiste Seiten, Stale Claims und heilt, was heilbar ist. Nach grossen
   Sessions einen Digest anlegen lassen.
5. AUTONOM (optional): Soll der Server selbst taeglich um 03:15 Lint+Digest
   fahren (ohne dass du startest), installiere deinen Agenten ZUSAETZLICH
   im Container (z.B. \`curl -fsSL https://opencode.ai/install | bash\`) und:
     touch /etc/secondbrain/autonomous
   Log: /var/log/secondbrain-maintain.log

## 7) Backups

Mehrere Schichten aktiv:

1. Syncthing "Staggered File Versioning" (30 Tage) - ist bereits pro
   Folder aktiviert: geloeschte/ueberschriebene Dateien sind im Web-UI
   unter Ordner -> "Versionierung" wiederherstellbar.
2. Git-Auto-Commit alle 2h je Vault (Cron: /etc/cron.d/vault-git).
   History ansehen: \`git -C /srv/vaults/work log --oneline\`.
3. Proxmox-Backup des Containers (ZFS-Snapshots) - auf dem HOST anlegen:
   \`vzdump <VMID> --mode snapshot --compress zstd\`
   oder besser: Backup-Job in der Proxmox-GUI unter
   "Datacenter -> Backups" einrichten (Mode: snapshot, zstd).
EOF

chmod 644 /root/DEVICE-SETUP.md

echo ">>> Einrichtung abgeschlossen."
# ===== INNER_SETUP_END =====
INNER_BLOCK

main "$@"
