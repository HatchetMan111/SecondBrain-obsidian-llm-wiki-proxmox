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

INSTALLER_VERSION="2.5.0"

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
  msg_info "Installer-Version: ${INSTALLER_VERSION}"
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
  msg_ok "Proxmox VE erkannt: $(pveversion | awk '{print $1}')"
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

  local vm_id hostname ct_ip net_conf gw ns bridge storage disk_size disk_int ram cores sshkey sync_user sync_pass

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
    if [[ "$ct_ip" != */* ]]; then
      msg_error "Statische IP muss CIDR-Notation enthalten (z.B. 192.168.1.100/24), aktuell: $ct_ip"
      exit 1
    fi
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

  # --- Eingaben validieren (bevor pct create laeuft) ---
  case "$vm_id" in
    ''|*[!0-9]*) msg_error "Ungueltige Container-ID: $vm_id (nur Ziffern)."; exit 1 ;;
  esac
  if [ -z "$hostname" ]; then
    msg_error "Hostname darf nicht leer sein (nur [a-z0-9-])."
    exit 1
  fi
  case "$ram" in
    ''|*[!0-9]*) msg_error "RAM muss eine Zahl sein (MB)."; exit 1 ;;
  esac
  case "$cores" in
    ''|*[!0-9]*) msg_error "CPU-Cores muss eine Zahl sein."; exit 1 ;;
  esac
  if [[ ! "$disk_size" =~ ^[0-9]+[GMK]?$ ]]; then
    msg_error "Ungueltige Disk-Groesse: $disk_size (Beispiel: 16G)."
    exit 1
  fi
  disk_int=$(echo "$disk_size" | tr -cd '0-9')
  if [ "$disk_int" != "$disk_size" ]; then
    msg_warn "Disk-Groesse '${disk_size}' -> nur Zahl '${disk_int}' wird an pct uebergeben (Directory-Storage vertraegt kein 'G')."
  fi
  if [ -n "$sshkey" ] && [ ! -f "$sshkey" ]; then
    msg_error "SSH-Key-Datei nicht gefunden: $sshkey"
    exit 1
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
    net_conf="name=eth0,bridge=${bridge},ip=${ct_ip}"
    if [ -n "$gw" ]; then
      net_conf+=",gw=${gw}"
    else
      msg_warn "Kein Gateway angegeben - Container wird ohne Gateway angelegt (nur lokale Netze erreichbar)."
    fi
    if [ -z "$ns" ]; then
      msg_warn "Kein Nameserver angegeben - DNS-Aufloesung im Container wird nicht funktionieren."
    fi
  fi

  # --- Container anlegen ---
  msg_info "Lege Container $vm_id an (Hostname: $hostname) ..."
  local ssh_args=()
  if [ -n "$sshkey" ]; then
    ssh_args=(--ssh-public-keys "$sshkey")
  fi

  pct_output=$(pct create "$vm_id" "$template" \
    --hostname "$hostname" \
    --storage "$storage" \
    --rootfs "${storage}:${disk_int}" \
    --memory "$ram" \
    --cores "$cores" \
    --net0 "$net_conf" \
    ${ns:+--nameserver "$ns"} \
    --unprivileged 1 \
    "${ssh_args[@]}" \
    --start 1 \
    --description "SecondBrain (LLM-Wiki nach Karpathy): Syncthing + Obsidian-Vaults (work/private)" \
    2>&1) || {
      msg_error "pct create fehlgeschlagen. Ausgabe von pct:"
      echo -e "${RED}${pct_output}${RESET}"
      msg_error "Haeufige Ursachen:"
      msg_error "  - Disk-Groesse mit Einheit (16G) bei Directory-Storage wie 'local'"
      msg_error "  - Statische IP ohne CIDR/Netzmaske"
      msg_error "  - Gateway/Nameserver absichtlich leer gelassen"
      msg_error "  - VMID $vm_id ist evtl. belegt oder defekt (siehe obige Ausgabe)"
      msg_error "  - Storage '${storage}' hat keinen rootdir/pct-Speicherplatz"
      msg_error "  - Template-Datei fehlt trotz Download"
      pct destroy "$vm_id" --purge >/dev/null 2>&1 || true
      exit 1
    }

  msg_info "Warte auf Container-Start ..."
  local ct_ready=""
  for _ in $(seq 1 30); do
    if pct exec "$vm_id" -- true >/dev/null 2>&1; then
      ct_ready="1"
      break
    fi
    sleep 2
  done
  if [ -z "$ct_ready" ]; then
    msg_error "Container $vm_id ist nach 60s nicht erreichbar. Bitte pruefen:"
    msg_error "  pct status $vm_id        (Status muss 'running' sein)"
    msg_error "  pct start $vm_id"
    msg_error "  pct config $vm_id | grep net0"
    exit 1
  fi

  # --- Setup-Script + Parameter in den Container uebertragen (via pct push) ---
  msg_info "Uebertrage Einrichtungsscript in den Container ..."
  # Inneres Einrichtungsscript wird als Base64-Block eingebettet. Das funktioniert auch
  # bei 'bash -c "$(wget ...)"', wo \$0 nur den Namen 'bash' liefert (keine Datei!).
  # Nach Aenderungen am INNER_SETUP-Block neu generieren:
  #   awk '/^# ===== INNER_SETUP_START =====$/{f=1;next} /^# ===== INNER_SETUP_END =====$/{f=0} f' install-obsidian-llm-wiki.sh | tee /tmp/inner.sh && base64 -w0 /tmp/inner.sh
  local tmp_inner tmp_env
  tmp_inner=$(mktemp)
  tmp_env=$(mktemp)
  printf '%s' 'IyEvdXNyL2Jpbi9lbnYgYmFzaApzZXQgLWV1byBwaXBlZmFpbAoKIyBzaGVsbGNoZWNrIGRpc2FibGU9U0MxMDkxCnNvdXJjZSAvcm9vdC9zZXR1cC5lbnYKCmV4cG9ydCBERUJJQU5fRlJPTlRFTkQ9bm9uaW50ZXJhY3RpdmUKQ1RfU1lOQ19VU0VSPSJzeW5jdGhpbmciClZBVUxUX0JBU0U9Ii9zcnYvdmF1bHRzIgpDT05GSUdfSE9NRT0iL2hvbWUvc3luY3RoaW5nLy5jb25maWcvc3luY3RoaW5nIgoKIyBEdWJpb3VzLW93bmVyc2hpcC1TcGVycmUgZnVlciBhbGxlIE51dHplciBhdXMgKGdpdCA+PSAyLjM1IHZlcmxhbmd0IGRhcywKIyB3ZW5uIFJlcG8tL0F1ZnJ1Zi1Vc2VyIHVudGVyc2NoaWVkbGljaCBzaW5kLCB6LkIuIFd1cnplbC1TY2FmZm9sZGluZykuCmdpdCBjb25maWcgLS1nbG9iYWwgLS1hZGQgc2FmZS5kaXJlY3RvcnkgJyonIDI+L2Rldi9udWxsIHx8IHRydWUKCmVjaG8gIj4+PiBbMS84XSBhcHQgdXBkYXRlIgpmb3IgXyBpbiAkKHNlcSAxIDEwKTsgZG8KICBpZiBhcHQtZ2V0IHVwZGF0ZSAteSA+L2Rldi9udWxsIDI+JjE7IHRoZW4KICAgIGJyZWFrCiAgZmkKICBzbGVlcCA1CmRvbmUKCmVjaG8gIj4+PiBbMi84XSBQYWtldGUgaW5zdGFsbGllcmVuIgphcHQtZ2V0IGluc3RhbGwgLXkgLS1uby1pbnN0YWxsLXJlY29tbWVuZHMgY3VybCBnaXQganEgc3luY3RoaW5nIGFwYWNoZTItdXRpbHMgY3JvbiA+L2Rldi9udWxsCgplY2hvICI+Pj4gWzMvOF0gU3luY3RoaW5nLUJlbnV0emVyIGFubGVnZW4iCmlmICEgaWQgLXUgIiRDVF9TWU5DX1VTRVIiID4vZGV2L251bGwgMj4mMTsgdGhlbgogIHVzZXJhZGQgLXIgLW0gLWQgL2hvbWUvc3luY3RoaW5nIC1zIC91c3Ivc2Jpbi9ub2xvZ2luICIkQ1RfU1lOQ19VU0VSIgpmaQoKZWNobyAiPj4+IFs0LzhdIFZhdWx0LVZlcnplaWNobmlzc2UgYW5sZWdlbiAod29yayAvIHByaXZhdGUpIgpta2RpciAtcCAiJFZBVUxUX0JBU0Uvd29yay9yYXciICIkVkFVTFRfQkFTRS93b3JrL3dpa2kiCm1rZGlyIC1wICIkVkFVTFRfQkFTRS9wcml2YXRlL3JhdyIgIiRWQVVMVF9CQVNFL3ByaXZhdGUvd2lraSIKY2hvd24gLVIgIiRDVF9TWU5DX1VTRVIiOiIkQ1RfU1lOQ19VU0VSIiAiJFZBVUxUX0JBU0UiCgplY2hvICI+Pj4gWzUvOF0gU3luY3RoaW5nLUtvbmZpZ3VyYXRpb24gZ2VuZXJpZXJlbiIKbWtkaXIgLXAgIiRDT05GSUdfSE9NRSIKc3luY3RoaW5nIGdlbmVyYXRlIC0taG9tZT0iJENPTkZJR19IT01FIiA+L2Rldi9udWxsCmNob3duIC1SICIkQ1RfU1lOQ19VU0VSIjoiJENUX1NZTkNfVVNFUiIgL2hvbWUvc3luY3RoaW5nCgpta2RpciAtcCAiL2V0Yy9zeXN0ZW1kL3N5c3RlbS9zeW5jdGhpbmdAc3luY3RoaW5nLnNlcnZpY2UuZCIKY2F0ID4gL2V0Yy9zeXN0ZW1kL3N5c3RlbS9zeW5jdGhpbmdAc3luY3RoaW5nLnNlcnZpY2UuZC9vdmVycmlkZS5jb25mIDw8J0VPRicKW1NlcnZpY2VdClJlYWRXcml0ZVBhdGhzPS9zcnYvdmF1bHRzCkVPRgpzeXN0ZW1jdGwgZGFlbW9uLXJlbG9hZAoKc3lzdGVtY3RsIGVuYWJsZSBzeW5jdGhpbmdAc3luY3RoaW5nLnNlcnZpY2UgPi9kZXYvbnVsbCAyPiYxIHx8IHRydWUKc3lzdGVtY3RsIHN0YXJ0IHN5bmN0aGluZ0BzeW5jdGhpbmcuc2VydmljZQoKQVBJX0tFWT0kKGdyZXAgLW9QICcoPzw9PGFwaWtleT4pW148XSsnICIkQ09ORklHX0hPTUUvY29uZmlnLnhtbCIpCkRFVklDRV9JRD0kKGdyZXAgLW9QICc8ZGV2aWNlIGlkPSJcS1teIl0rJyAiJENPTkZJR19IT01FL2NvbmZpZy54bWwiIHwgaGVhZCAtMSkKCmVjaG8gIj4+PiBbNi84XSBXYXJ0ZSBhdWYgU3luY3RoaW5nLUFQSSAuLi4iCmZvciBfIGluICQoc2VxIDEgMzApOyBkbwogIGlmIGN1cmwgLXNmIC1IICJYLUFQSS1LZXk6ICRBUElfS0VZIiBodHRwOi8vMTI3LjAuMC4xOjgzODQvcmVzdC9zeXN0ZW0vdmVyc2lvbiA+L2Rldi9udWxsIDI+JjE7IHRoZW4KICAgIGJyZWFrCiAgZmkKICBzbGVlcCAyCmRvbmUKCiMgV2ViLVVJOiBBdXRoICsgTEFOLVp1Z3JpZmYKQkNSWVBUPSQoaHRwYXNzd2QgLW5iQiAtQyAxMCAiJFNZTkNfR1VJX1VTRVIiICIkU1lOQ19HVUlfUEFTUyIgMj4vZGV2L251bGwgfCBjdXQgLWQ6IC1mMikKWyAtbiAiJEJDUllQVCIgXSB8fCBCQ1JZUFQ9JChodHBhc3N3ZCAtbmJCICIkU1lOQ19HVUlfVVNFUiIgIiRTWU5DX0dVSV9QQVNTIiB8IGN1dCAtZDogLWYyKQoKY2F0ID4gL3RtcC9ndWkuanNvbiA8PEVPRgp7CiAgImVuYWJsZWQiOiB0cnVlLAogICJhZGRyZXNzIjogIjAuMC4wLjA6ODM4NCIsCiAgInVzZXIiOiAiJFNZTkNfR1VJX1VTRVIiLAogICJwYXNzd29yZCI6ICIkQkNSWVBUIiwKICAidXNlVExTIjogZmFsc2UsCiAgInNlbmRCYXNpY0F1dGhQcm9tcHQiOiBmYWxzZSwKICAiaW5zZWN1cmVBZG1pbkFjY2VzcyI6IGZhbHNlLAogICJhcGlLZXkiOiAiJEFQSV9LRVkiCn0KRU9GCmN1cmwgLXMgLW8gL2Rldi9udWxsIC1IICJYLUFQSS1LZXk6ICRBUElfS0VZIiAtWCBQVVQgLWQgQC90bXAvZ3VpLmpzb24gXAogIGh0dHA6Ly8xMjcuMC4wLjE6ODM4NC9yZXN0L2NvbmZpZy9ndWkKCiMgU3luY3RoaW5nLUZvbGRlcnM6IHdvcmsgKyBwcml2YXRlIChtaXQgU3RhZ2dlcmVkIEZpbGUgVmVyc2lvbmluZykKOiA+IC9yb290L2ZvbGRlci1pZHMudHh0CgphZGRfZm9sZGVyKCkgewogIGxvY2FsIGxhYmVsPSIkMSIgcGF0aD0iJDIiIGZpZAogIGZpZD0kKGNhdCAvcHJvYy9zeXMva2VybmVsL3JhbmRvbS91dWlkKQogIGNhdCA+IC90bXAvZm9sZGVyLmpzb24gPDxFT0YKewogICJpZCI6ICIkZmlkIiwKICAibGFiZWwiOiAiJGxhYmVsIiwKICAicGF0aCI6ICIkcGF0aCIsCiAgInR5cGUiOiAic2VuZHJlY2VpdmUiLAogICJyZXNjYW5JbnRlcnZhbFMiOiA2MCwKICAiZnNXYXRjaGVyRW5hYmxlZCI6IHRydWUsCiAgImZzV2F0Y2hlckRlbGF5UyI6IDEwLAogICJpZ25vcmVQZXJtcyI6IHRydWUsCiAgImF1dG9Ob3JtYWxpemUiOiB0cnVlLAogICJkZXZpY2VzIjogWyB7ICJkZXZpY2VJRCI6ICIkREVWSUNFX0lEIiB9IF0sCiAgInZlcnNpb25pbmciOiB7CiAgICAidHlwZSI6ICJzdGFnZ2VyZWQiLAogICAgInBhcmFtcyI6IHsgImNsZWFuSW50ZXJ2YWwiOiAzNjAwLCAibWF4QWdlIjogMjU5MjAwMCwgIm1heFZlcnNpb25zIjogNSB9CiAgfQp9CkVPRgogIGN1cmwgLXMgLW8gL2Rldi9udWxsIC1IICJYLUFQSS1LZXk6ICRBUElfS0VZIiAtWCBQT1NUIC1kIEAvdG1wL2ZvbGRlci5qc29uIFwKICAgIGh0dHA6Ly8xMjcuMC4wLjE6ODM4NC9yZXN0L2NvbmZpZy9mb2xkZXJzCiAgcHJpbnRmICclczolc1xuJyAiJGxhYmVsIiAiJGZpZCIgPj4gL3Jvb3QvZm9sZGVyLWlkcy50eHQKfQoKYWRkX2ZvbGRlciAid29yayIgIiRWQVVMVF9CQVNFL3dvcmsiCmFkZF9mb2xkZXIgInByaXZhdGUiICIkVkFVTFRfQkFTRS9wcml2YXRlIgoKc3lzdGVtY3RsIHJlc3RhcnQgc3luY3RoaW5nQHN5bmN0aGluZy5zZXJ2aWNlCgplY2hvICI+Pj4gWzcvOF0gVmF1bHQtU2NhZmZvbGRpbmcgKyBHaXQtVmVyc2lvbmllcnVuZyIKc2NhZmZvbGRfdmF1bHQoKSB7CiAgbG9jYWwgdj0iJDEiCiAgbG9jYWwgYmFzZT0iJFZBVUxUX0JBU0UvJHYiCgogIGNhdCA+ICIkYmFzZS9pbmRleC5tZCIgPDwnRU9GJwojIEluZGV4Cgo+IERpZXNlciBJbmRleCB3aXJkIHZvbSBMTE0tV2lraS1NYWludGFpbmVyIChPcGVuQ29kZSkgZ2VwZmxlZ3QuCgojIyBXaWtpCgpfTm9jaCBrZWluZSBTZWl0ZW4uIE5hY2ggZGVtIGVyc3RlbiBJbmdlc3QgbGVndCBkZXIgTExNIGhpZXIgZGllIEFydGlrZWwgYW4uXwoKIyMgU3RydWt0dXIKCi0gYHJhdy9gIC0gaW1tdXRhYmxlIFF1ZWxsZW4gKGFwcGVuZC1vbmx5KQotIGB3aWtpL2AgLSBMTE0tZ2VuZXJpZXJ0ZSBTZWl0ZW4gKGVudGl0aWVzLCBjb25jZXB0cywgc3ludGhlc2lzKQpFT0YKCiAgY2F0ID4gIiRiYXNlL2xvZy5tZCIgPDwnRU9GJwojIExvZwoKPiBBcHBlbmQtb25seSBDaHJvbmlrLiBGb3JtYXQ6IGAjIyBbWVlZWS1NTS1ERF0gb3BlcmF0aW9uIHwgVGl0ZWxgCj4gKG51dHpiYXIgbWl0OiBgZ3JlcCAiXiMjIFxbIiBsb2cubWQgfCB0YWlsIC01YCkKCkVPRgoKICBjYXQgPiAiJGJhc2UvQUdFTlRTLm1kIiA8PCdFT0YnCiMgQUdFTlRTLm1kIC0gTExNLVdpa2ktU2NoZW1hIHYyIChPcGVuQ29kZSkKCkR1IGJpc3QgZGVyIFdpa2ktTWFpbnRhaW5lciBkaWVzZXMgVmF1bHRzIG5hY2ggZGVtIExMTS1XaWtpLVBhdHRlcm4gdm9uCkFuZHJlaiBLYXJwYXRoeSAodjEpIG1pdCBkZW4gRXJ3ZWl0ZXJ1bmdlbiBhdXMgIkxMTSBXaWtpIHYyIiB2b24gcm9oaXRnMDAKKENvbmZpZGVuY2UsIFN1cGVyc2Vzc2lvbiwgU2VsZi1IZWFsaW5nLUxpbnQsIFR5cGVkIFJlbGF0aW9uc2hpcHMpLgpEdSBzY2hyZWlic3QgdW5kIHBmbGVnc3QgZGFzIFdpa2k7IGRlciBOdXR6ZXIga3VyYXRpZXJ0IFF1ZWxsZW4gdW5kIFJpY2h0dW5nLgoKIyMgU3RydWt0dXIKCi0gYHJhdy9gIC0gaW1tdXRhYmxlIFF1ZWxsZW4sIGFwcGVuZC1vbmx5LiBOaWUgYmVhcmJlaXRlbi4KLSBgd2lraS9gIC0gdm9uIGRpciBnZXBmbGVndGUgTWFya2Rvd24tU2VpdGVuIChlbnRpdGllcywgY29uY2VwdHMsIGRlY2lzaW9ucywgZGlnZXN0cykuCi0gYHBlbmRpbmcubWRgIC0gYXV0b21hdGlzY2ggZ2VwZmxlZ3RlIEluYm94OiBuZXVlIFF1ZWxsZW4gYXVzIGByYXcvYAogIHdhcnRlbiBoaWVyIGF1ZiBJbmdlc3QgKHdpcmQgc3R1ZW5kbGljaCBha3R1YWxpc2llcnQpLgotIGBpbmRleC5tZGAgLSBLYXRhbG9nIGFsbGVyIHdpa2ktU2VpdGVuLCBiZWkgamVkZW0gSW5nZXN0IGFrdHVhbGlzaWVyZW4uCi0gYGxvZy5tZGAgLSBhcHBlbmQtb25seSBDaHJvbmlrIFVORCBBdWRpdC1UcmFpbCAoc2llaGUgdW50ZW4pLgotIGAubWV0YS9pbmdlc3RlZC50eHRgIC0gRGF0ZWluYW1lbiBkZXIgYmVyZWl0cyB2ZXJhcmJlaXRldGVuIFF1ZWxsZW4KICAoZWluZSBwcm8gWmVpbGUpLiBOYWNoIGRlbSBJbmdlc3QgZWludHJhZ2VuLCBkYW1pdCBkaWUgUXVlbGxlIGF1cwogIGBwZW5kaW5nLm1kYCB2ZXJzY2h3aW5kZXQuCgojIyBGcm9udG1hdHRlci1Lb252ZW50aW9uIChqZWRlIHdpa2ktU2VpdGUpCgogICAgdGl0bGUsIHR5cGUgKGVudGl0eXxjb25jZXB0fGRlY2lzaW9ufGRpZ2VzdCksIHN1bW1hcnksCiAgICBzb3VyY2VzOiBbXSwgY29uZmlkZW5jZTogMC4wLTEuMCwgbGFzdF9jb25maXJtZWQ6IFlZWVktTU0tREQsCiAgICBzdXBlcnNlZGVzOiBbXSwgc3VwZXJzZWRlZF9ieTogW10sCiAgICByZWxhdGlvbnNoaXBzOiBbe3JlbGF0aW9uLCB0YXJnZXR9XQoKUmVsYXRpb25zdHlwZW46IHVzZXMsIGRlcGVuZHMtb24sIGNvbnRyYWRpY3RzLCBzdXBlcnNlZGVzLCBjYXVzZWQsIGZpeGVkLgoKIyMgT3BlcmF0aW9uZW4KCiMjIyBJbmdlc3QKMS4gUXVlbGxlIGxlc2VuLiBWb3IgZGVtIFNjaHJlaWJlbiBTRU5TSUJMRSBEQVRFTiBlbnRmZXJuZW4gKEFQSS1LZXlzLAogICBUb2tlbnMsIFBhc3N3b2VydGVyLCBQSUkpIC0gbmllIGlucyBXaWtpIHVlYmVybmVobWVuLgoyLiBLZXJuLVRha2Vhd2F5cyBrdXJ6IG1pdCBkZW0gTnV0emVyIGJlc3ByZWNoZW4uCjMuIEVudGl0aWVzIGV4dHJhaGllcmVuIChQZXJzb24vUHJvamVrdC9MaWJyYXJ5L0tvbnplcHQvRGF0ZWkvRW50c2NoZWlkdW5nKQogICBtaXQgVHlwLCBBdHRyaWJ1dGVuIHVuZCBCZXppZWh1bmdlbi4KNC4gWnVzYW1tZW5mYXNzdW5ncy1TZWl0ZSArIEVudGl0eS0vQ29uY2VwdC1TZWl0ZW4gc2NocmVpYmVuL2FrdHVhbGlzaWVyZW4uCjUuIENvbmZpZGVuY2UgdmVyZ2ViZW46IEFuemFobCBRdWVsbGVuICsgQWt0dWFsaXRhZXQgKyBXaWRlcnNwcnVlY2hlLgo2LiBgaW5kZXgubWRgIGFrdHVhbGlzaWVyZW4uCjcuIERhdGVpbmFtZSBkZXIgUXVlbGxlIGluIGAubWV0YS9pbmdlc3RlZC50eHRgIGVpbnRyYWdlbiAoZWluZSBwcm8gWmVpbGUpIC0KICAgZGFuYWNoIHZlcnNjaHdpbmRldCBzaWUgYXV0b21hdGlzY2ggYXVzIGBwZW5kaW5nLm1kYC4KOC4gRWludHJhZyBpbiBgbG9nLm1kYCBhbmZ1ZWdlbi4KCiMjIyBRdWVyeQotIFp1ZXJzdCBgaW5kZXgubWRgLCBkYW5uIGRpZSByZWxldmFudGVuIFNlaXRlbi4KLSBBbnR3b3J0ZW4gbWl0IFF1ZWxsZW52ZXJ3ZWlzZW4gKGBbW3F1ZWxsZV1dYCkgZm9ybXVsaWVyZW4uCi0gV2VydHZvbGxlIEFudHdvcnRlbiBhbHMgbmV1ZSBgd2lraS9gLVNlaXRlIGFibGVnZW4gKEtvbXBlbmRpdW0hKS4KLSBCZWkgQmV6aWVodW5nc2ZyYWdlbiAoIldhcyBoYWVuZ3Qgdm9uIFggYWI/IikgdWViZXIgZGllCiAgYHJlbGF0aW9uc2hpcHNgLUVpbnRyYWVnZSB3YW5kZXJuLCBuaWNodCBudXIgU3RpY2h3b3J0c3VjaGUuCgojIyMgU3VwZXJzZXNzaW9uCi0gTmV1ZSBJbmZvIHdpZGVyc3ByaWNodC9ha3R1YWxpc2llcnQgYWx0ZTogTkVVRSBTZWl0ZSBzY2hyZWliZW4sIGFsdGUKICBTZWl0ZSBtaXQgYHN1cGVyc2VkZWRfYnk6IFtbbmV1ZV1dYCBtYXJraWVyZW4gKG5pY2h0IGxvZXNjaGVuKSwKICBpbiBgbG9nLm1kYCB2ZXJtZXJrZW4gKHdhbm4vd2FydW0pLgoKIyMjIExpbnQgKGhlYWx0aCBjaGVjaywgc2VsZi1oZWFsaW5nKQpSZWdlbG1hZXNzaWcgYXVzZnVlaHJlbjoKLSBXaWRlcnNwcnVlY2hlIGZpbmRlbiBVTkQgYXVmbG9lc2VuIChRdWVsbC1BbHRlciwgUXVlbGwtQXV0b3JpdGFldCwKICBBbnphaGwgQmVsZWdlKTsgZGVyIE51dHplciBrYW5uIHVlYmVyc3RpbW1lbi4KLSBTdXBlcnNlZGVkL3N0YWxlIENsYWltcyBtYXJraWVyZW4uCi0gVmVyd2Fpc3RlIFNlaXRlbiB2ZXJsaW5rZW4gb2RlciBhbHMgb3JwaGFuIGZsYWdnZW4uCi0gRmVobGVuZGUgVmVybGlua3VuZ2VuIHJlcGFyaWVyZW4uCi0gUmV0ZW50aW9uOiBTZWl0ZW4gb2huZSBCZXN0YWV0aWd1bmcgPjkwIFRhZ2UgZnVlciBSZXZpZXcgZmxhZ2dlbgogIChuaWNodCBsb2VzY2hlbiEpLgotIFF1YWxpdGFldDogdW5zdHJ1a3R1cmllcnRlL3Vua29udGllcnRlIFNlaXRlbiB1ZWJlcmFyYmVpdGVuLgotIERhdGVubHVlY2tlbiB2b3JzY2hsYWdlbiwgZGllIHBlciBXZWJzdWNoZSBmdWVsbGJhciBzaW5kLgoKIyMjIERpZ2VzdCAvIEtyaXN0YWxsaXNhdGlvbgpOYWNoIGFiZ2VzY2hsb3NzZW5lciBSZWNoZXJjaGUtL0RlYnVnZ2luZy1TZXNzaW9uIGVpbmVuIERpZ2VzdCBhbmxlZ2VuOgpGcmFnZSwgRXJrZW5udG5pc3NlLCBiZXRlaWxpZ3RlIERhdGVpZW4vRW50aXRpZXMsIExlaHJlbi4gTGVocmVuIGFscwpTdGFuZGFsb25lLUZha3RlbiBpbnMgV2lraSB1ZWJlcm5laG1lbi4KCiMjIEtvbnZlbnRpb25lbgoKLSBLZWluIGByYXcvYCBhZW5kZXJuLiBLZWluZSBHZWhlaW1uaXNzZSBpbnMgV2lraS4KLSBgbG9nLm1kYCA9IEF1ZGl0LVRyYWlsOiBqZWRlciBJbmdlc3QvTGludC9TdXBlcnNlc3Npb24gbWl0IFplaXRzdGVtcGVsCiAgdW5kIEdydW5kLiBGb3JtYXQ6IGAjIyBbWVlZWS1NTS1ERF0gb3BlcmF0aW9uIHwgVGl0ZWxgCi0gV2VubiB1bnNpY2hlcjogbGllYmVyIGZyYWdlbiBhbHMgcmF0ZW4uCkVPRgoKICBjYXQgPiAiJGJhc2UvQ0xBVURFLm1kIiA8PCdFT0YnCiMgQ0xBVURFLm1kIC0gRXJpbm5lcnVuZyBmdWVyIENsYXVkZSBDb2RlCgpEaWVzZXIgVmF1bHQgZm9sZ3QgZGVtIExMTS1XaWtpLVBhdHRlcm4gdm9uIEFuZHJlaiBLYXJwYXRoeSAodjEpIG1pdCBkZW4KRXJ3ZWl0ZXJ1bmdlbiBhdXMgIkxMTSBXaWtpIHYyIiB2b24gcm9oaXRnMDAgKENvbmZpZGVuY2UsIFN1cGVyc2Vzc2lvbiwKU2VsZi1IZWFsaW5nLUxpbnQpLiBEYXMgdm9sbHN0YWVuZGlnZSBTY2hlbWEgc3RlaHQgaW4gQUdFTlRTLm1kIC0gbGllcwplcyB1bmQgaGFuZGxlIG5hY2ggZGVzc2VuIFJlZ2Vsbi4KCiMjIEtlcm5yZWdlbG4KCi0gYHJhdy9gIGlzdCBpbW11dGFibGUgKGFwcGVuZC1vbmx5KSwgbmllIGJlYXJiZWl0ZW4uCi0gV2lraS1TZWl0ZW4gaW4gYHdpa2kvYCBzY2hyZWliZW4sIG1pdCBGcm9udG1hdHRlciB1bmQgUXVlbGxlbnZlcndlaXNlbi4KLSBgaW5kZXgubWRgIGJlaSBqZWRlbSBJbmdlc3QgYWt0dWFsaXNpZXJlbiwgYGxvZy5tZGAtRWludHJhZyBhbmZ1ZWdlbi4KLSBJbmdlc3QgLyBRdWVyeSAvIExpbnQgZ2VuYXUgd2llIGluIEFHRU5UUy5tZCBiZXNjaHJpZWJlbiBkdXJjaGZ1ZWhyZW4uCkVPRgoKICBjYXQgPiAiJGJhc2UvLmdpdGlnbm9yZSIgPDwnRU9GJwoudHJhc2gvCi5vYnNpZGlhbi93b3Jrc3BhY2UqCkVPRgoKICBta2RpciAtcCAiJGJhc2UvLm1ldGEiCiAgOiA+ICIkYmFzZS8ubWV0YS9pbmdlc3RlZC50eHQiCiAgY2F0ID4gIiRiYXNlLy5zdGlnbm9yZSIgPDwnRU9GJwouZ2l0LwpFT0YKICBjYXQgPiAiJGJhc2UvcGVuZGluZy5tZCIgPDwnRU9GJwojIFBlbmRpbmctSW5ib3gKCl9Ob2NoIGtlaW5lIFF1ZWxsZW4uIE5ldWUgRGF0ZWllbiBpbiBgcmF3L2Agd2VyZGVuIGhpZXIgYXV0b21hdGlzY2ggZ2VsaXN0ZXQuXwpFT0YKCiAgY2hvd24gLVIgIiRDVF9TWU5DX1VTRVIiOiIkQ1RfU1lOQ19VU0VSIiAiJGJhc2UiCiAgcnVuX2FzX3N5bmMoKSB7CiAgICBzdSAtcyAvYmluL2Jhc2ggIiRDVF9TWU5DX1VTRVIiIC1jICIkMSIKICB9CiAgaWYgISBydW5fYXNfc3luYyAiY2QgJyRiYXNlJyAmJiBnaXQgaW5pdCAtcSI7IHRoZW4KICAgIGVjaG8gIj4+PiBHSVQtSU5JVC1GRUhMRVIgaW4gJGJhc2U6IgogICAgbHMgLWxhICIkYmFzZSIKICAgIGdpdCAtLXZlcnNpb24KICAgIGV4aXQgMQogIGZpCiAgcnVuX2FzX3N5bmMgImNkICckYmFzZScgJiYgZ2l0IGNvbmZpZyB1c2VyLm5hbWUgT2JzaWRpYW4gJiYgZ2l0IGNvbmZpZyB1c2VyLmVtYWlsIG9ic2lkaWFuQGxvY2FsIgogIHJ1bl9hc19zeW5jICJjZCAnJGJhc2UnICYmIGdpdCBhZGQgLUEiCiAgaWYgWyAtbiAiJChydW5fYXNfc3luYyAiY2QgJyRiYXNlJyAmJiBnaXQgc3RhdHVzIC0tcG9yY2VsYWluIikiIF07IHRoZW4KICAgIGlmICEgcnVuX2FzX3N5bmMgImNkICckYmFzZScgJiYgZ2l0IGNvbW1pdCAtcW0gJ0luaXRpYWwnIjsgdGhlbgogICAgICBlY2hvICI+Pj4gR0lULUNPTU1JVC1GRUhMRVIgaW4gJGJhc2U6IgogICAgICBydW5fYXNfc3luYyAiY2QgJyRiYXNlJyAmJiBnaXQgc3RhdHVzIiB8fCB0cnVlCiAgICAgIHJ1bl9hc19zeW5jICJjZCAnJGJhc2UnICYmIGxzIC1sYSIgfHwgdHJ1ZQogICAgICBleGl0IDEKICAgIGZpCiAgICBlY2hvICI+Pj4gR2l0LUluaXRpYWwtQ29tbWl0IGluICRiYXNlIG9rLiIKICBlbHNlCiAgICBlY2hvICI+Pj4gSGlud2VpczogaW4gJGJhc2UgZ2lidCBlcyBuaWNodHMgenUgY29tbWl0dGVuIChuby1vcCkuIgogIGZpCn0KCnNjYWZmb2xkX3ZhdWx0ICJ3b3JrIgpzY2FmZm9sZF92YXVsdCAicHJpdmF0ZSIKCmNob3duIC1SICIkQ1RfU1lOQ19VU0VSIjoiJENUX1NZTkNfVVNFUiIgIiRWQVVMVF9CQVNFIgoKY2F0ID4gL3Vzci9sb2NhbC9iaW4vdmF1bHQtZ2l0LWNvbW1pdCA8PCdFT0YnCiMhL2Jpbi9iYXNoCmZvciB2IGluIHdvcmsgcHJpdmF0ZTsgZG8KICBkPS9zcnYvdmF1bHRzLyR2CiAgWyAtZCAiJGQvLmdpdCIgXSB8fCBjb250aW51ZQogIGlmIFsgLW4gIiQoZ2l0IC1DICIkZCIgc3RhdHVzIC0tcG9yY2VsYWluKSIgXTsgdGhlbgogICAgZ2l0IC1DICIkZCIgYWRkIC1BCiAgICBnaXQgLUMgIiRkIiBjb21taXQgLXFtICJhdXRvOiAkKGRhdGUgJyslWS0lbS0lZCAlSDolTScpIgogIGZpCmRvbmUKRU9GCmNobW9kICt4IC91c3IvbG9jYWwvYmluL3ZhdWx0LWdpdC1jb21taXQKCmNhdCA+IC9ldGMvY3Jvbi5kL3ZhdWx0LWdpdCA8PCdFT0YnCjAgKi8yICogKiAqIHJvb3QgL3Vzci9sb2NhbC9iaW4vdmF1bHQtZ2l0LWNvbW1pdCA+L2Rldi9udWxsIDI+JjEKRU9GCgpjYXQgPiAvdXNyL2xvY2FsL2Jpbi90cmFjay1wZW5kaW5nLnNoIDw8J0VPRicKIyEvYmluL2Jhc2gKIyBQZW5kaW5nLUluYm94IGplIFZhdWx0IGFrdHVhbGlzaWVyZW46IGxpc3RldCBuZXVlIERhdGVpZW4gYXVzIHJhdy8sCiMgZGllIG5vY2ggbmljaHQgaW4gLm1ldGEvaW5nZXN0ZWQudHh0IHN0ZWhlbi4KZm9yIHYgaW4gd29yayBwcml2YXRlOyBkbwogIGRpcj0vc3J2L3ZhdWx0cy8kdgogIFsgLWQgIiRkaXIvcmF3IiBdIHx8IGNvbnRpbnVlCiAgc3RhdGU9IiRkaXIvLm1ldGEvaW5nZXN0ZWQudHh0IgogIFsgLWYgIiRzdGF0ZSIgXSB8fCA6ID4gIiRzdGF0ZSIKICB0bXA9IiQobWt0ZW1wKSIKICA6ID4gIiR0bXAiCiAgd2hpbGUgSUZTPSByZWFkIC1yIC1kICcnIGY7IGRvCiAgICBiYXNlPSIkKGJhc2VuYW1lICIkZiIpIgogICAgaWYgISBncmVwIC1xeEYgLS0gIiRiYXNlIiAiJHN0YXRlIiAyPi9kZXYvbnVsbDsgdGhlbgogICAgICBwcmludGYgLS0gJy0gWyBdICVzICBfKGVudGRlY2t0OiAlcylfXG4nICIkYmFzZSIgIiQoZGF0ZSArJUYpIiA+PiAiJHRtcCIKICAgIGZpCiAgZG9uZSA8IDwoZmluZCAiJGRpci9yYXciIC1tYXhkZXB0aCAxIC10eXBlIGYgLXByaW50MCB8IHNvcnQgLXopCiAgaWYgWyAtcyAiJHRtcCIgXTsgdGhlbgogICAgeyBwcmludGYgIiMgUGVuZGluZy1JbmJveFxuXG5OZXVlIFF1ZWxsZW4gaW4gXGByYXcvXGAgd2FydGVuIGF1ZiBJbmdlc3Q6XG5cbiI7IGNhdCAiJHRtcCI7IH0gPiAiJGRpci9wZW5kaW5nLm1kIgogIGVsc2UKICAgIHByaW50ZiAiIyBQZW5kaW5nLUluYm94XG5cbl9BbGxlIFF1ZWxsZW4gdmVyYXJiZWl0ZXQgLSBuaWNodHMgenUgdHVuLl9cbiIgPiAiJGRpci9wZW5kaW5nLm1kIgogIGZpCiAgcm0gLWYgIiR0bXAiCiAgY2hvd24gc3luY3RoaW5nOnN5bmN0aGluZyAiJGRpci9wZW5kaW5nLm1kIiAiJGRpci8ubWV0YS9pbmdlc3RlZC50eHQiIDI+L2Rldi9udWxsIHx8IHRydWUKZG9uZQpFT0YKY2htb2QgK3ggL3Vzci9sb2NhbC9iaW4vdHJhY2stcGVuZGluZy5zaAoKY2F0ID4gL3Vzci9sb2NhbC9iaW4vc2Vjb25kYnJhaW4tbWFpbnRhaW4tY3JvbiA8PCdFT0YnCiMhL2Jpbi9iYXNoCiMgT3B0aW9uYWxlIHRhZWdsaWNoZSBXYXJ0dW5nOiBMaW50ICsgRGlnZXN0IGR1cmNoIGVpbmVuIEtJLUFnZW50ZW4uCiMgQWt0aXZpZXJlbjogdG91Y2ggL2V0Yy9zZWNvbmRicmFpbi9hdXRvbm9tb3VzICAgKEFnZW50IG11c3MgaW0gQ29udGFpbmVyIGluc3RhbGxpZXJ0IHNlaW4pCkxPRz0vdmFyL2xvZy9zZWNvbmRicmFpbi1tYWludGFpbi5sb2cKYWdlbnQ9IiIKZm9yIGMgaW4gb3BlbmNvZGUgY2xhdWRlIGNvZGV4OyBkbwogIGlmIGNvbW1hbmQgLXYgIiRjIiA+L2Rldi9udWxsIDI+JjE7IHRoZW4gYWdlbnQ9IiRjIjsgYnJlYWs7IGZpCmRvbmUKWyAtbiAiJGFnZW50IiBdIHx8IGV4aXQgMApmb3IgdiBpbiB3b3JrIHByaXZhdGU7IGRvCiAgZGlyPS9zcnYvdmF1bHRzLyR2CiAgWyAtZCAiJGRpci8uZ2l0IiBdIHx8IGNvbnRpbnVlCiAgY2QgIiRkaXIiIHx8IGNvbnRpbnVlCiAgZWNobyAiPT09ICQoZGF0ZSAnKyVZLSVtLSVkICVIOiVNJykgOiAkdiB2aWEgJGFnZW50ID09PSIgPj4gIiRMT0ciCiAgY2FzZSAiJGFnZW50IiBpbgogICAgb3BlbmNvZGUpIG9wZW5jb2RlIHJ1biAiRnVlaHJlIExpbnQgdW5kIG9wdGlvbmFsIGVpbmVuIERpZ2VzdCBnZW1hZXNzIEFHRU5UUy5tZCBhdXMuIFByb3Rva29sbGllcmUgZGllIEFlbmRlcnVuZ2VuLiIgPj4gIiRMT0ciIDI+JjEgOzsKICAgIGNsYXVkZSkgICBjbGF1ZGUgLXAgIkZ1ZWhyZSBMaW50IHVuZCBvcHRpb25hbCBlaW5lbiBEaWdlc3QgZ2VtYWVzcyBDTEFVREUubWQgYXVzLiBQcm90b2tvbGxpZXJlIGRpZSBBZW5kZXJ1bmdlbi4iID4+ICIkTE9HIiAyPiYxIDs7CiAgICBjb2RleCkgICAgY29kZXggZXhlYyAiRnVlaHJlIExpbnQgdW5kIG9wdGlvbmFsIGVpbmVuIERpZ2VzdCBnZW1hZXNzIEFHRU5UUy5tZCBhdXMuIFByb3Rva29sbGllcmUgZGllIEFlbmRlcnVuZ2VuLiIgPj4gIiRMT0ciIDI+JjEgOzsKICBlc2FjCmRvbmUKRU9GCmNobW9kICt4IC91c3IvbG9jYWwvYmluL3NlY29uZGJyYWluLW1haW50YWluLWNyb24KCmNhdCA+IC9ldGMvY3Jvbi5kL3NlY29uZGJyYWluLW1haW50YWluIDw8J0VPRicKIyBTdHVlbmRsaWNoOiBQZW5kaW5nLUluYm94IGFrdHVhbGlzaWVyZW4gKGtlaW4gVG9rZW4tVmVyYnJhdWNoKS4KNyAqICogKiAqIHJvb3QgL3Vzci9sb2NhbC9iaW4vdHJhY2stcGVuZGluZy5zaCA+L2Rldi9udWxsIDI+JjEKIyBPcHRpb25hbCB0YWVnbGljaCAwMzoxNTogYXV0byBMaW50L0RpZ2VzdCBkdXJjaCBLSS1BZ2VudC4KIyBBa3RpdmllcmVuIG1pdDogdG91Y2ggL2V0Yy9zZWNvbmRicmFpbi9hdXRvbm9tb3VzCjE1IDMgKiAqICogcm9vdCB0ZXN0IC1mIC9ldGMvc2Vjb25kYnJhaW4vYXV0b25vbW91cyAmJiAvdXNyL2xvY2FsL2Jpbi9zZWNvbmRicmFpbi1tYWludGFpbi1jcm9uID4vZGV2L251bGwgMj4mMQpFT0YKCmVjaG8gIj4+PiBbOC84XSBHZXLDpHRlLUFubGVpdHVuZyBzY2hyZWliZW4iCklQX0FERFI9JChob3N0bmFtZSAtSSB8IGF3ayAne3ByaW50ICQxfScpCgpjYXQgPiAvcm9vdC9ERVZJQ0UtU0VUVVAubWQgPDxFT0YKIyBTZWNvbmRCcmFpbiAtIEdlcsOkdGUtRWlucmljaHR1bmcKCiMjIFp1Z2FuZ3NkYXRlbiAvIElEcwoKLSBTZXJ2ZXItSVA6ICAgICAgICBcYCRJUF9BRERSXGAKLSBTeW5jdGhpbmctV2ViLVVJOiBcYGh0dHA6Ly8kSVBfQUREUjo4Mzg0XGAgIChVc2VyOiBcYCRTWU5DX0dVSV9VU0VSXGApCi0gU2VydmVyLURldmljZS1JRDogXGAkREVWSUNFX0lEXGAKLSBTeW5jdGhpbmctRm9sZGVycyAoU2VydmVyKToKRU9GCndoaWxlIElGUz06IHJlYWQgLXIgbGFiZWwgZmlkOyBkbwogIGVjaG8gIi0gXGAkbGFiZWxcYCAtPiBcYCRmaWRcYCIgPj4gL3Jvb3QvREVWSUNFLVNFVFVQLm1kCmRvbmUgPCAvcm9vdC9mb2xkZXItaWRzLnR4dAoKY2F0ID4+IC9yb290L0RFVklDRS1TRVRVUC5tZCA8PEVPRgoKRGllIFZhdWx0cyBsaWVnZW4gYXVmIGRlbSBTZXJ2ZXIgdW50ZXI6Ci0gV29yazogICAgL3Nydi92YXVsdHMvd29yawotIFByaXZhdGU6IC9zcnYvdmF1bHRzL3ByaXZhdGUKCkplZGVyIFZhdWx0IGhhdCBkaWUgU3RydWt0dXI6IHJhdy8gKFF1ZWxsZW4pLCB3aWtpLyAoTExNLVNlaXRlbiksCmluZGV4Lm1kLCBsb2cubWQsIEFHRU5UUy5tZCAoU2NoZW1hIGZ1ZXIgT3BlbkNvZGUvQ29kZXgpLCBDTEFVREUubWQKKFNjaGVtYSBmdWVyIENsYXVkZSBDb2RlKS4KCiMjIFdpZSBkZWluIFZhdWx0IGF1ZiBkZWluZSBHZXJhZXRlIGtvbW10CgpFcyBnaWJ0IGtlaW5lICJWYXVsdC1VUkwiOiBTeW5jdGhpbmcgc3luY2hyb25pc2llcnQgT3JkbmVyIGRpcmVrdApHZXJhZXQtenUtR2VyYWV0IChhZWhubGljaCB3aWUgR2l0LVJlcG9zKS4gRGVyIFNlcnZlciBpc3QgZGFiZWkgZGVyCmltbWVyLWF1Zi1Lbm90ZW46CgotIFdlYi1VSSAoU2VydmVyKTogIGh0dHA6Ly8kSVBfQUREUjo4Mzg0ICAgLSBoaWVyIHZlcndhbHRlc3QgZHUgR2VyYWV0ZSB1bmQgRm9sZGVyCi0gU3luYy1Qb3J0OiAgICAgICAgdGNwOi8vJElQX0FERFI6MjIwMDAgICAtIGhpZXIgbGF1ZmVuIGRpZSBVZWJlcnRyYWd1bmdlbgoKU29iYWxkIGR1ICgxKSBkZWluIEdlcmFldCBwZXIgRGV2aWNlLUlEIHZlcmJ1bmRlbiB1bmQgKDIpIGRlbiBPcmRuZXIgYXVmCmRlbSBTZXJ2ZXIgbWl0IGRlaW5lbSBHZXJhZXQgZ2V0ZWlsdCBoYXN0LCBlcnNjaGVpbnQgZGVyIFZhdWx0IGF1ZiBkZWluZW0KR2VyYWV0IGFscyBnYW56IG5vcm1hbGVyIGxva2FsZXIgT3JkbmVyLiBEaWVzZW4gb2VmZm5lc3QgZHUgaW4gT2JzaWRpYW4KKCJPcmRuZXIgYWxzIFZhdWx0IG9lZmZuZW4iKSAtIGRlcnNlbGJlIE9yZG5lciwgZGVuIGF1Y2ggZGVpbiBLSS1BZ2VudApsaWVzdCB1bmQgc2NocmVpYnQuCgojIyBHcnVuZHByaW56aXAgZGVyIFRyZW5udW5nCgpBcmJlaXRzZ2VyYWV0ZSB0ZWlsZW4gTlVSIGRlbiBGb2xkZXIgIndvcmsiLCBwcml2YXRlIEdlcmFldGUgTlVSIGRlbgpGb2xkZXIgInByaXZhdGUiLiBEZXIgU2VydmVyIGjDpGx0IGJlaWRlLiBTbyBsYW5kZXQgcHJpdmF0ZXIgSW5oYWx0IG5pZQphdWYgZWluZW0gQXJiZWl0c2dlcmFldCB1bmQgdW1nZWtlaHJ0LgoKLS0tCgojIyAxKSBEZXNrdG9wIChXaW5kb3dzIC8gTGludXggLyBNYWMpCgoxLiBTeW5jdGhpbmcgaW5zdGFsbGllcmVuIChodHRwczovL3N5bmN0aGluZy5uZXQpIHVuZCBzdGFydGVuLgoyLiBXZWItVUkgZGVpbmVzIEdlcmFldHMgb2VmZm5lbiAoaHR0cDovLzEyNy4wLjAuMTo4Mzg0KS4KMy4gIlJlbW90ZS1HZXJhZXQgaGluenVmdWVnZW4iOiBTZXJ2ZXItRGV2aWNlLUlEIG9iZW4gZWludHJhZ2VuLgogICBUaXBwOiBBbHMgQWRyZXNzZSBvcHRpb25hbCBcYHRjcDovLyRJUF9BRERSOjIyMDAwXGAgZWludHJhZ2VuLCBkYW1pdAogICBkaWUgVmVyYmluZHVuZyBvaG5lIERpc2NvdmVyeSBzb2ZvcnQgYXVmZ2ViYXV0IHdpcmQuCjQuIEF1ZiBkZW0gU0VSVkVSIChXZWItVUkgaHR0cDovLyRJUF9BRERSOjgzODQpOgogICAtICJSZW1vdGUtR2VyYWV0IGhpbnp1ZnVlZ2VuIiAtPiBEZXZpY2UtSUQgZGVpbmVzIEdlcmFldHMgZWludHJhZ2VuLgogICAtIERpZSBHZXJhZXRlIG11ZXNzZW4gc2ljaCBnZWdlbnNlaXRpZyBrZW5uZW4gdW5kIGRpZSBWZXJiaW5kdW5nIGFremVwdGllcmVuLgo1LiBBdWYgZGVtIFNlcnZlcjogIk9yZG5lciB0ZWlsZW4iIC0+IGRlbiBwYXNzZW5kZW4gRm9sZGVyICh3b3JrIE9ERVIgcHJpdmF0ZSkKICAgbWl0IGRlaW5lbSBHZXJhZXQgdGVpbGVuLgo2LiBBdWYgZGVpbmVtIEdlcmFldDogRGVyIGdldGVpbHRlIE9yZG5lciB3aXJkIGFuZ2VsZWd0LiBGZXJ0aWcuCgojIyAyKSBBbmRyb2lkCgoxLiAiU3luY3RoaW5nIiBhdXMgZGVtIFBsYXkgU3RvcmUgaW5zdGFsbGllcmVuLgoyLiBHbGVpY2hlcyBWZXJmYWhyZW4gd2llIERlc2t0b3A6IEdlcsOkdCArIFNlcnZlciB2ZXJiaW5kZW4gKERldmljZS1JRHMKICAgdGF1c2NoZW4pLCBkZW4gcGFzc2VuZGVuIE9yZG5lciAod29yay9wcml2YXRlKSB0ZWlsZW4uCjMuIEluIFN5bmN0aGluZyBkZW4gU3luYy1PcmRuZXIgYW4gZWluZW4gZ3V0IGVycmVpY2hiYXJlbiBPcnQgbGVnZW4KICAgKHouQi4gL3N0b3JhZ2UvZW11bGF0ZWQvMC9TeW5jLy4uLikuCgojIyAzKSBpT1MgLyBpUGFkT1MgKGlQaG9uZSAvIGlQYWQpCgppT1MgaGF0IGtlaW4gbmF0aXZlcyBTeW5jdGhpbmcuIExvZXN1bmc6ICJNw7ZiaXVzIFN5bmMiIChBcHAgU3RvcmUsClN5bmN0aGluZy1rb21wYXRpYmVsKS4KMS4gTcO2Yml1cyBTeW5jIGluc3RhbGxpZXJlbi4KMi4gU2VydmVyIGFscyBSZW1vdGUtR2VyYWV0IGhpbnp1ZnVlZ2VuIChTZXJ2ZXItRGV2aWNlLUlEKS4KMy4gQXVmIGRlbSBTZXJ2ZXIgZGVuIHBhc3NlbmRlbiBPcmRuZXIgbWl0IGRpZXNlbSBHZXJhZXQgdGVpbGVuLgo0LiBNw7ZiaXVzIFN5bmMgaW4gIk9uIE15IGlQaG9uZSIgc3luY2hyb25pc2llcmVuIGxhc3Nlbi4KNS4gT2JzaWRpYW4gaW5zdGFsbGllcmVuIHVuZCBkaWVzZW4gbG9rYWxlbiBPcmRuZXIgYWxzIFZhdWx0IG9lZmZuZW4uCgojIyA0KSBPYnNpZGlhbiBudXR6ZW4KCjEuIE9ic2lkaWFuIGluc3RhbGxpZXJlbiAoRGVza3RvcCBvZGVyIG1vYmlsKS4KMi4gIk9yZG5lciBhbHMgVmF1bHQgb2VmZm5lbiIgdW5kIGRlbiBzeW5jaHJvbmlzaWVydGVuIE9yZG5lciB3YWVobGVuLgozLiBPYnNpZGlhbiBsaWVzdC9zY2hyZWlidCBsb2thbDsgU3luY3RoaW5nIGjDpGx0IGFsbGUgR2VyYWV0ZSArIFNlcnZlcgogICBhdWYgZGVtc2VsYmVuIFN0YW5kLiBBdWNoIG1vYmlsIGthbm5zdCBkdSBzY2hyZWliZW4gLSBlcyB3aXJkCiAgIHp1cnVlY2tzeW5jaHJvbmlzaWVydC4KCiMjIDUpIExMTS1NYWludGFpbmVyIChPcGVuQ29kZSkKCkRhcyBIZXJ6IGRlcyBQYXR0ZXJuczogZGVyIEFnZW50IHBmbGVndCBkYXMgV2lraSwgZHUga3VyYXRpZXJzdCBRdWVsbGVuLgoKMS4gQXVmIGVpbmVtIEdlcmFldCAob2RlciB2aWEgU1NIIGF1ZiBkZW4gU2VydmVyKSBpbiBkZW4gVmF1bHQgd2VjaHNlbG46CiAgIFxgY2QgL3Nydi92YXVsdHMvd29ya1xgICAgKG9kZXIgXGAuLi4vcHJpdmF0ZVxgKQoyLiBBZ2VudCBzdGFydGVuIChvcGVuY29kZSAvIGNsYXVkZSAvIGNvZGV4KS4gRGllIFxgQUdFTlRTLm1kXGAgYnp3LgogICBcYENMQVVERS5tZFxgIGltIFZhdWx0LVJvb3QgZGVmaW5pZXJlbiBkaWUgUmVnZWxuLgozLiBRdWVsbGVuIGVpbmZhY2ggaW4gXGByYXcvXGAgYWJsZWdlbiAoei5CLiBtaXQgZGVtIE9ic2lkaWFuIFdlYiBDbGlwcGVyKSAtCiAgIHVuZCBkZW0gQWdlbnQgZWluZmFjaCBzYWdlbjogIkluZ2VzdCBkaWUgb2ZmZW5lbiBQdW5rdGUgYXVzIHBlbmRpbmcubWQiLgoKIyMgNikgVGFlZ2xpY2hlciBXb3JrZmxvdyAtIHdpZSBvcmRuZXQgZGVyIEFnZW50IG5ldWUgSW5mb3MgenU/CgpEZXIgS3JlaXNsYXVmOiBDQVBUVVJFIC0+IElOQk9YIC0+IElOR0VTVCAtPiBQRkxFR0UKCjEuIENBUFRVUkUgKGR1KTogTmV1ZSBRdWVsbGUgYWJsZWdlbiAtIEFydGlrZWwgcGVyIE9ic2lkaWFuIFdlYiBDbGlwcGVyCiAgIChzcGVpY2hlcnQgYWxzIC5tZCksIFBERiBvZGVyIERhdGVpIGVpbmZhY2ggaW4gXGByYXcvXGAgemllaGVuLgoyLiBJTkJPWCAoYXV0b21hdGlzY2gsIHN0dWVuZGxpY2gpOiBcYHRyYWNrLXBlbmRpbmcuc2hcYCBsaXN0ZXQgbmV1ZSBEYXRlaWVuCiAgIGF1cyBcYHJhdy9cYCBpbiBcYHBlbmRpbmcubWRcYCAoYWxzIENoZWNrYm94ZW4pLiBJbiBPYnNpZGlhbiBzaWVoc3QgZHUKICAgamVkZXJ6ZWl0LCB3YXMgbm9jaCB3YXJ0ZXQuCjMuIElOR0VTVCAoZHUgKyBBZ2VudCk6IEFnZW50IGltIFZhdWx0IHN0YXJ0ZW4gdW5kIHNhZ2VuOgogICAiSW5nZXN0IGFsbGUgb2ZmZW5lbiBQdW5rdGUgYXVzIHBlbmRpbmcubWQiLiBEZXIgQWdlbnQgbGllc3QgZGllIFF1ZWxsZW4sCiAgIG9yZG5ldCBzaWUgZWluIChDb25maWRlbmNlLCBSZWxhdGlvbnNoaXBzKSwgc2NocmVpYnQvYWt0dWFsaXNpZXJ0CiAgIHdpa2ktU2VpdGVuICsgXGBpbmRleC5tZFxgICsgXGBsb2cubWRcYCB1bmQgdHJhZWd0IGRpZSBEYXRlaW5hbWVuIGluCiAgIFxgLm1ldGEvaW5nZXN0ZWQudHh0XGAgZWluLiBEYW5hY2ggdmVyc2Nod2luZGVuIHNpZSBhdXMgXGBwZW5kaW5nLm1kXGAuCjQuIFBGTEVHRSAocGVyaW9kaXNjaCk6ICJGdWVocmUgTGludCBhdXMiIC0gZGVyIEFnZW50IGZpbmRldCBXaWRlcnNwcnVlY2hlLAogICB2ZXJ3YWlzdGUgU2VpdGVuLCBTdGFsZSBDbGFpbXMgdW5kIGhlaWx0LCB3YXMgaGVpbGJhciBpc3QuIE5hY2ggZ3Jvc3NlbgogICBTZXNzaW9ucyBlaW5lbiBEaWdlc3QgYW5sZWdlbiBsYXNzZW4uCjUuIEFVVE9OT00gKG9wdGlvbmFsKTogU29sbCBkZXIgU2VydmVyIHNlbGJzdCB0YWVnbGljaCB1bSAwMzoxNSBMaW50K0RpZ2VzdAogICBmYWhyZW4gKG9obmUgZGFzcyBkdSBzdGFydGVzdCksIGluc3RhbGxpZXJlIGRlaW5lbiBBZ2VudGVuIFpVU0FFVFpMSUNICiAgIGltIENvbnRhaW5lciAoei5CLiBcYGN1cmwgLWZzU0wgaHR0cHM6Ly9vcGVuY29kZS5haS9pbnN0YWxsIHwgYmFzaFxgKSB1bmQ6CiAgICAgdG91Y2ggL2V0Yy9zZWNvbmRicmFpbi9hdXRvbm9tb3VzCiAgIExvZzogL3Zhci9sb2cvc2Vjb25kYnJhaW4tbWFpbnRhaW4ubG9nCgojIyA3KSBCYWNrdXBzCgpNZWhyZXJlIFNjaGljaHRlbiBha3RpdjoKCjEuIFN5bmN0aGluZyAiU3RhZ2dlcmVkIEZpbGUgVmVyc2lvbmluZyIgKDMwIFRhZ2UpIC0gaXN0IGJlcmVpdHMgcHJvCiAgIEZvbGRlciBha3RpdmllcnQ6IGdlbG9lc2NodGUvdWViZXJzY2hyaWViZW5lIERhdGVpZW4gc2luZCBpbSBXZWItVUkKICAgdW50ZXIgT3JkbmVyIC0+ICJWZXJzaW9uaWVydW5nIiB3aWVkZXJoZXJzdGVsbGJhci4KMi4gR2l0LUF1dG8tQ29tbWl0IGFsbGUgMmggamUgVmF1bHQgKENyb246IC9ldGMvY3Jvbi5kL3ZhdWx0LWdpdCkuCiAgIEhpc3RvcnkgYW5zZWhlbjogXGBnaXQgLUMgL3Nydi92YXVsdHMvd29yayBsb2cgLS1vbmVsaW5lXGAuCjMuIFByb3htb3gtQmFja3VwIGRlcyBDb250YWluZXJzIChaRlMtU25hcHNob3RzKSAtIGF1ZiBkZW0gSE9TVCBhbmxlZ2VuOgogICBcYHZ6ZHVtcCA8Vk1JRD4gLS1tb2RlIHNuYXBzaG90IC0tY29tcHJlc3MgenN0ZFxgCiAgIG9kZXIgYmVzc2VyOiBCYWNrdXAtSm9iIGluIGRlciBQcm94bW94LUdVSSB1bnRlcgogICAiRGF0YWNlbnRlciAtPiBCYWNrdXBzIiBlaW5yaWNodGVuIChNb2RlOiBzbmFwc2hvdCwgenN0ZCkuCkVPRgoKY2htb2QgNjQ0IC9yb290L0RFVklDRS1TRVRVUC5tZAoKZWNobyAiPj4+IEVpbnJpY2h0dW5nIGFiZ2VzY2hsb3NzZW4uIgo=' | base64 -d > "$tmp_inner"
  printf 'SYNC_GUI_USER=%q\nSYNC_GUI_PASS=%q\n' "$sync_user" "$sync_pass" > "$tmp_env"
  if ! pct push "$vm_id" "$tmp_inner" /root/inner-setup.sh 2>"${tmp_inner}.err"; then
    msg_error "Uebertragung inner-setup.sh fehlgeschlagen:"
    cat "${tmp_inner}.err"
    msg_error "Tipp: pct status $vm_id, danach erneut ausfuehren."
    rm -f "$tmp_inner" "$tmp_env" "${tmp_inner}.err"
    exit 1
  fi
  if ! pct push "$vm_id" "$tmp_env" /root/setup.env 2>"${tmp_inner}.err"; then
    msg_error "Uebertragung setup.env fehlgeschlagen:"
    cat "${tmp_inner}.err"
    rm -f "$tmp_inner" "$tmp_env" "${tmp_inner}.err"
    exit 1
  fi
  rm -f "$tmp_inner" "$tmp_env" "${tmp_inner}.err"

  # --- Setup ausfuehren ---
  msg_info "Richte Container ein (Syncthing, Vaults, Backups) - das dauert einige Minuten ..."
  if ! pct exec "$vm_id" -- bash /root/inner-setup.sh; then
    msg_error "Einrichtung im Container fehlgeschlagen."
    msg_error "Tipp: pct enter $vm_id   und dann:  bash /root/inner-setup.sh"
    msg_error "      (Vaults liegen unter /srv/vaults/work und /srv/vaults/private)"
    exit 1
  fi

  # --- Abschluss ---
  local ct_ip_final
  ct_ip_final=$(pct exec "$vm_id" -- sh -c "hostname -I | awk '{print \$1}'" 2>/dev/null | tr -d '\n')
  [ -n "$ct_ip_final" ] || ct_ip_final="$ct_ip"
  if [ -z "$ct_ip_final" ] || [ "$ct_ip_final" = "dhcp" ]; then
    msg_warn "Keine Container-IP gefunden - pruefe das Netzwerk:"
    msg_warn "  pct config $vm_id | grep net0"
    msg_warn "  pct exec $vm_id -- ip a"
    msg_warn "  (Statische IP mit CIDR beim naechsten Lauf verwenden, falls kein DHCP existiert)"
  fi

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
  pct exec "$vm_id" -- cat /root/DEVICE-SETUP.md 2>/dev/null || {
    msg_warn "DEVICE-SETUP.md im Container fehlt (Setup evtl. unvollstaendig)."
    msg_warn "Zugangsdaten/Anleitung liegen unter /root/DEVICE-SETUP.md."
  }
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
