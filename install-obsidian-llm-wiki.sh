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

INSTALLER_VERSION="2.6.0"

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
  printf '%s' 'IyEvdXNyL2Jpbi9lbnYgYmFzaApzZXQgLWV1byBwaXBlZmFpbAoKIyBzaGVsbGNoZWNrIGRpc2FibGU9U0MxMDkxCnNvdXJjZSAvcm9vdC9zZXR1cC5lbnYKCmV4cG9ydCBERUJJQU5fRlJPTlRFTkQ9bm9uaW50ZXJhY3RpdmUKQ1RfU1lOQ19VU0VSPSJzeW5jdGhpbmciClZBVUxUX0JBU0U9Ii9zcnYvdmF1bHRzIgpDT05GSUdfSE9NRT0iL2hvbWUvc3luY3RoaW5nLy5jb25maWcvc3luY3RoaW5nIgoKIyBEdWJpb3VzLW93bmVyc2hpcC1TcGVycmUgZnVlciBhbGxlIE51dHplciBhdXMgKGdpdCA+PSAyLjM1IHZlcmxhbmd0IGRhcywKIyB3ZW5uIFJlcG8tL0F1ZnJ1Zi1Vc2VyIHVudGVyc2NoaWVkbGljaCBzaW5kLCB6LkIuIFd1cnplbC1TY2FmZm9sZGluZykuCmdpdCBjb25maWcgLS1nbG9iYWwgLS1hZGQgc2FmZS5kaXJlY3RvcnkgJyonIDI+L2Rldi9udWxsIHx8IHRydWUKCmVjaG8gIj4+PiBbMS84XSBhcHQgdXBkYXRlIgpmb3IgXyBpbiAkKHNlcSAxIDEwKTsgZG8KICBpZiBhcHQtZ2V0IHVwZGF0ZSAteSA+L2Rldi9udWxsIDI+JjE7IHRoZW4KICAgIGJyZWFrCiAgZmkKICBzbGVlcCA1CmRvbmUKCmVjaG8gIj4+PiBbMi84XSBQYWtldGUgaW5zdGFsbGllcmVuIgphcHQtZ2V0IGluc3RhbGwgLXkgLS1uby1pbnN0YWxsLXJlY29tbWVuZHMgY3VybCBnaXQganEgc3luY3RoaW5nIGFwYWNoZTItdXRpbHMgY3JvbiA+L2Rldi9udWxsCgplY2hvICI+Pj4gWzMvOF0gU3luY3RoaW5nLUJlbnV0emVyIGFubGVnZW4iCmlmICEgaWQgLXUgIiRDVF9TWU5DX1VTRVIiID4vZGV2L251bGwgMj4mMTsgdGhlbgogIHVzZXJhZGQgLXIgLW0gLWQgL2hvbWUvc3luY3RoaW5nIC1zIC91c3Ivc2Jpbi9ub2xvZ2luICIkQ1RfU1lOQ19VU0VSIgpmaQoKZWNobyAiPj4+IFs0LzhdIFZhdWx0LVZlcnplaWNobmlzc2UgYW5sZWdlbiAod29yayAvIHByaXZhdGUpIgpta2RpciAtcCAiJFZBVUxUX0JBU0Uvd29yay9yYXciICIkVkFVTFRfQkFTRS93b3JrL3dpa2kiCm1rZGlyIC1wICIkVkFVTFRfQkFTRS9wcml2YXRlL3JhdyIgIiRWQVVMVF9CQVNFL3ByaXZhdGUvd2lraSIKY2hvd24gLVIgIiRDVF9TWU5DX1VTRVIiOiIkQ1RfU1lOQ19VU0VSIiAiJFZBVUxUX0JBU0UiCgplY2hvICI+Pj4gWzUvOF0gU3luY3RoaW5nLUtvbmZpZ3VyYXRpb24gZ2VuZXJpZXJlbiIKbWtkaXIgLXAgIiRDT05GSUdfSE9NRSIKc3luY3RoaW5nIGdlbmVyYXRlIC0taG9tZT0iJENPTkZJR19IT01FIiA+L2Rldi9udWxsCmNob3duIC1SICIkQ1RfU1lOQ19VU0VSIjoiJENUX1NZTkNfVVNFUiIgL2hvbWUvc3luY3RoaW5nCgpta2RpciAtcCAiL2V0Yy9zeXN0ZW1kL3N5c3RlbS9zeW5jdGhpbmdAc3luY3RoaW5nLnNlcnZpY2UuZCIKY2F0ID4gL2V0Yy9zeXN0ZW1kL3N5c3RlbS9zeW5jdGhpbmdAc3luY3RoaW5nLnNlcnZpY2UuZC9vdmVycmlkZS5jb25mIDw8J0VPRicKW1NlcnZpY2VdClJlYWRXcml0ZVBhdGhzPS9zcnYvdmF1bHRzCkVPRgpzeXN0ZW1jdGwgZGFlbW9uLXJlbG9hZAoKc3lzdGVtY3RsIGVuYWJsZSBzeW5jdGhpbmdAc3luY3RoaW5nLnNlcnZpY2UgPi9kZXYvbnVsbCAyPiYxIHx8IHRydWUKc3lzdGVtY3RsIHN0YXJ0IHN5bmN0aGluZ0BzeW5jdGhpbmcuc2VydmljZQoKQVBJX0tFWT0kKGdyZXAgLW9QICcoPzw9PGFwaWtleT4pW148XSsnICIkQ09ORklHX0hPTUUvY29uZmlnLnhtbCIpCkRFVklDRV9JRD0kKGdyZXAgLW9QICc8ZGV2aWNlIGlkPSJcS1teIl0rJyAiJENPTkZJR19IT01FL2NvbmZpZy54bWwiIHwgaGVhZCAtMSkKCmVjaG8gIj4+PiBbNi84XSBXYXJ0ZSBhdWYgU3luY3RoaW5nLUFQSSAuLi4iCmZvciBfIGluICQoc2VxIDEgMzApOyBkbwogIGlmIGN1cmwgLXNmIC1IICJYLUFQSS1LZXk6ICRBUElfS0VZIiBodHRwOi8vMTI3LjAuMC4xOjgzODQvcmVzdC9zeXN0ZW0vdmVyc2lvbiA+L2Rldi9udWxsIDI+JjE7IHRoZW4KICAgIGJyZWFrCiAgZmkKICBzbGVlcCAyCmRvbmUKCiMgV2ViLVVJOiBBdXRoICsgTEFOLVp1Z3JpZmYKQkNSWVBUPSQoaHRwYXNzd2QgLW5iQiAtQyAxMCAiJFNZTkNfR1VJX1VTRVIiICIkU1lOQ19HVUlfUEFTUyIgMj4vZGV2L251bGwgfCBjdXQgLWQ6IC1mMikKWyAtbiAiJEJDUllQVCIgXSB8fCBCQ1JZUFQ9JChodHBhc3N3ZCAtbmJCICIkU1lOQ19HVUlfVVNFUiIgIiRTWU5DX0dVSV9QQVNTIiB8IGN1dCAtZDogLWYyKQojIEFjaHR1bmc6IGh0cGFzc3dkIGxpZWZlcnQgJyQyeSQnIChPcGVuQlNELVZhcmlhbnRlKS4gR28tYmNyeXB0IGluIFN5bmN0aGluZwojIGFremVwdGllcnQgZGFzIG5pY2h0IHp1dmVybGFlc3NpZyAtPiBkZXNoYWxiIGF1ZiAnJDJhJCcgbm9ybWFsaXNpZXJlbi4KQkNSWVBUPSQocHJpbnRmICclcycgIiRCQ1JZUFQiIHwgc2VkICdzL15cJDJ5XCQvXCQyYVwkLycpCgpjYXQgPiAvdG1wL2d1aS5qc29uIDw8RU9GCnsKICAiZW5hYmxlZCI6IHRydWUsCiAgImFkZHJlc3MiOiAiMC4wLjAuMDo4Mzg0IiwKICAidXNlciI6ICIkU1lOQ19HVUlfVVNFUiIsCiAgInBhc3N3b3JkIjogIiRCQ1JZUFQiLAogICJ1c2VUTFMiOiBmYWxzZSwKICAic2VuZEJhc2ljQXV0aFByb21wdCI6IGZhbHNlLAogICJpbnNlY3VyZUFkbWluQWNjZXNzIjogZmFsc2UsCiAgImFwaUtleSI6ICIkQVBJX0tFWSIKfQpFT0YKY3VybCAtcyAtbyAvZGV2L251bGwgLUggIlgtQVBJLUtleTogJEFQSV9LRVkiIC1YIFBVVCAtZCBAL3RtcC9ndWkuanNvbiBcCiAgaHR0cDovLzEyNy4wLjAuMTo4Mzg0L3Jlc3QvY29uZmlnL2d1aQoKIyBMb2dpbiBzb2ZvcnQgdmVyaWZpemllcmVuLCBkYW1pdCBlaW4gZmFsc2NoZXIgQmNyeXB0LUhhc2ggbmljaHQgZXJzdCB2b20KIyBVc2VyIGFscyAia29tbWUgbmljaHQgaW5zIFdlYi1VSSIgZW50ZGVja3Qgd2lyZC4KR1VJX1RFU1Q9IiIKZm9yIF8gaW4gMSAyIDMgNCA1IDYgNyA4OyBkbwogIEdVSV9URVNUPSQoY3VybCAtcyAtbyAvZGV2L251bGwgLXcgJyV7aHR0cF9jb2RlfScgLXUgIiRTWU5DX0dVSV9VU0VSIjoiJFNZTkNfR1VJX1BBU1MiIFwKICAgIGh0dHA6Ly8xMjcuMC4wLjE6ODM4NC9yZXN0L3N5c3RlbS9zdGF0dXMgMj4vZGV2L251bGwgfHwgdHJ1ZSkKICBbICIkR1VJX1RFU1QiID0gIjIwMCIgXSAmJiBicmVhawogIHNsZWVwIDIKZG9uZQppZiBbICIkR1VJX1RFU1QiICE9ICIyMDAiIF07IHRoZW4KICBlY2hvICI+Pj4gV0FSTlVORzogV2ViLVVJLUxvZ2luIGRlcnplaXQgbmljaHQgbW9lZ2xpY2ggKEhUVFAgJHtHVUlfVEVTVDota2VpbmUgQW50d29ydH0pLiIKICBlY2hvICI+Pj4gU2V0emUgSGFzaCBlcm5ldXQgdW5kIHN0YXJ0ZSBTeW5jdGhpbmcgbmV1IC4uLiIKICBzZWQgLWkgInN8PHBhc3N3b3JkPi4qPC9wYXNzd29yZD58PHBhc3N3b3JkPiRCQ1JZUFQ8L3Bhc3N3b3JkPnwiICIkQ09ORklHX0hPTUUvY29uZmlnLnhtbCIKICBzeXN0ZW1jdGwgcmVzdGFydCBzeW5jdGhpbmdAc3luY3RoaW5nLnNlcnZpY2UKICBzbGVlcCA0CiAgR1VJX1RFU1Q9JChjdXJsIC1zIC1vIC9kZXYvbnVsbCAtdyAnJXtodHRwX2NvZGV9JyAtdSAiJFNZTkNfR1VJX1VTRVIiOiIkU1lOQ19HVUlfUEFTUyIgXAogICAgaHR0cDovLzEyNy4wLjAuMTo4Mzg0L3Jlc3Qvc3lzdGVtL3N0YXR1cyAyPi9kZXYvbnVsbCB8fCB0cnVlKQpmaQppZiBbICIkR1VJX1RFU1QiID0gIjIwMCIgXTsgdGhlbgogIGVjaG8gIj4+PiBXZWItVUktTG9naW4gdmVyaWZpemllcnQgKFVzZXI6ICRTWU5DX0dVSV9VU0VSKS4iCmVsc2UKICBlY2hvICI+Pj4gRkVITEVSOiBXZWItVUktTG9naW4gd2VpdGVyaGluIG5pY2h0IG1vZWdsaWNoIChIVFRQICR7R1VJX1RFU1Q6LWtlaW5lIEFudHdvcnR9KS4iCiAgZWNobyAiPj4+IE1hbnVlbGw6IHBjdCBlbnRlciA8Q1RJRD4sIGRhbm4gaW4gJENPTkZJR19IT01FL2NvbmZpZy54bWwgZGFzIGd1aS1QYXNzd29ydCBzZXR6ZW4uIgpmaQoKIyBTeW5jdGhpbmctRm9sZGVyczogd29yayArIHByaXZhdGUgKG1pdCBTdGFnZ2VyZWQgRmlsZSBWZXJzaW9uaW5nKQo6ID4gL3Jvb3QvZm9sZGVyLWlkcy50eHQKCmFkZF9mb2xkZXIoKSB7CiAgbG9jYWwgbGFiZWw9IiQxIiBwYXRoPSIkMiIgZmlkCiAgZmlkPSQoY2F0IC9wcm9jL3N5cy9rZXJuZWwvcmFuZG9tL3V1aWQpCiAgY2F0ID4gL3RtcC9mb2xkZXIuanNvbiA8PEVPRgp7CiAgImlkIjogIiRmaWQiLAogICJsYWJlbCI6ICIkbGFiZWwiLAogICJwYXRoIjogIiRwYXRoIiwKICAidHlwZSI6ICJzZW5kcmVjZWl2ZSIsCiAgInJlc2NhbkludGVydmFsUyI6IDYwLAogICJmc1dhdGNoZXJFbmFibGVkIjogdHJ1ZSwKICAiZnNXYXRjaGVyRGVsYXlTIjogMTAsCiAgImlnbm9yZVBlcm1zIjogdHJ1ZSwKICAiYXV0b05vcm1hbGl6ZSI6IHRydWUsCiAgImRldmljZXMiOiBbIHsgImRldmljZUlEIjogIiRERVZJQ0VfSUQiIH0gXSwKICAidmVyc2lvbmluZyI6IHsKICAgICJ0eXBlIjogInN0YWdnZXJlZCIsCiAgICAicGFyYW1zIjogeyAiY2xlYW5JbnRlcnZhbCI6IDM2MDAsICJtYXhBZ2UiOiAyNTkyMDAwLCAibWF4VmVyc2lvbnMiOiA1IH0KICB9Cn0KRU9GCiAgY3VybCAtcyAtbyAvZGV2L251bGwgLUggIlgtQVBJLUtleTogJEFQSV9LRVkiIC1YIFBPU1QgLWQgQC90bXAvZm9sZGVyLmpzb24gXAogICAgaHR0cDovLzEyNy4wLjAuMTo4Mzg0L3Jlc3QvY29uZmlnL2ZvbGRlcnMKICBwcmludGYgJyVzOiVzXG4nICIkbGFiZWwiICIkZmlkIiA+PiAvcm9vdC9mb2xkZXItaWRzLnR4dAp9CgphZGRfZm9sZGVyICJ3b3JrIiAiJFZBVUxUX0JBU0Uvd29yayIKYWRkX2ZvbGRlciAicHJpdmF0ZSIgIiRWQVVMVF9CQVNFL3ByaXZhdGUiCgpzeXN0ZW1jdGwgcmVzdGFydCBzeW5jdGhpbmdAc3luY3RoaW5nLnNlcnZpY2UKCmVjaG8gIj4+PiBbNy84XSBWYXVsdC1TY2FmZm9sZGluZyArIEdpdC1WZXJzaW9uaWVydW5nIgpzY2FmZm9sZF92YXVsdCgpIHsKICBsb2NhbCB2PSIkMSIKICBsb2NhbCBiYXNlPSIkVkFVTFRfQkFTRS8kdiIKCiAgY2F0ID4gIiRiYXNlL2luZGV4Lm1kIiA8PCdFT0YnCiMgSW5kZXgKCj4gRGllc2VyIEluZGV4IHdpcmQgdm9tIExMTS1XaWtpLU1haW50YWluZXIgKE9wZW5Db2RlKSBnZXBmbGVndC4KCiMjIFdpa2kKCl9Ob2NoIGtlaW5lIFNlaXRlbi4gTmFjaCBkZW0gZXJzdGVuIEluZ2VzdCBsZWd0IGRlciBMTE0gaGllciBkaWUgQXJ0aWtlbCBhbi5fCgojIyBTdHJ1a3R1cgoKLSBgcmF3L2AgLSBpbW11dGFibGUgUXVlbGxlbiAoYXBwZW5kLW9ubHkpCi0gYHdpa2kvYCAtIExMTS1nZW5lcmllcnRlIFNlaXRlbiAoZW50aXRpZXMsIGNvbmNlcHRzLCBzeW50aGVzaXMpCkVPRgoKICBjYXQgPiAiJGJhc2UvbG9nLm1kIiA8PCdFT0YnCiMgTG9nCgo+IEFwcGVuZC1vbmx5IENocm9uaWsuIEZvcm1hdDogYCMjIFtZWVlZLU1NLUREXSBvcGVyYXRpb24gfCBUaXRlbGAKPiAobnV0emJhciBtaXQ6IGBncmVwICJeIyMgXFsiIGxvZy5tZCB8IHRhaWwgLTVgKQoKRU9GCgogIGNhdCA+ICIkYmFzZS9BR0VOVFMubWQiIDw8J0VPRicKIyBBR0VOVFMubWQgLSBMTE0tV2lraS1TY2hlbWEgdjIgKE9wZW5Db2RlKQoKRHUgYmlzdCBkZXIgV2lraS1NYWludGFpbmVyIGRpZXNlcyBWYXVsdHMgbmFjaCBkZW0gTExNLVdpa2ktUGF0dGVybiB2b24KQW5kcmVqIEthcnBhdGh5ICh2MSkgbWl0IGRlbiBFcndlaXRlcnVuZ2VuIGF1cyAiTExNIFdpa2kgdjIiIHZvbiByb2hpdGcwMAooQ29uZmlkZW5jZSwgU3VwZXJzZXNzaW9uLCBTZWxmLUhlYWxpbmctTGludCwgVHlwZWQgUmVsYXRpb25zaGlwcykuCkR1IHNjaHJlaWJzdCB1bmQgcGZsZWdzdCBkYXMgV2lraTsgZGVyIE51dHplciBrdXJhdGllcnQgUXVlbGxlbiB1bmQgUmljaHR1bmcuCgojIyBTdHJ1a3R1cgoKLSBgcmF3L2AgLSBpbW11dGFibGUgUXVlbGxlbiwgYXBwZW5kLW9ubHkuIE5pZSBiZWFyYmVpdGVuLgotIGB3aWtpL2AgLSB2b24gZGlyIGdlcGZsZWd0ZSBNYXJrZG93bi1TZWl0ZW4gKGVudGl0aWVzLCBjb25jZXB0cywgZGVjaXNpb25zLCBkaWdlc3RzKS4KLSBgcGVuZGluZy5tZGAgLSBhdXRvbWF0aXNjaCBnZXBmbGVndGUgSW5ib3g6IG5ldWUgUXVlbGxlbiBhdXMgYHJhdy9gCiAgd2FydGVuIGhpZXIgYXVmIEluZ2VzdCAod2lyZCBzdHVlbmRsaWNoIGFrdHVhbGlzaWVydCkuCi0gYGluZGV4Lm1kYCAtIEthdGFsb2cgYWxsZXIgd2lraS1TZWl0ZW4sIGJlaSBqZWRlbSBJbmdlc3QgYWt0dWFsaXNpZXJlbi4KLSBgbG9nLm1kYCAtIGFwcGVuZC1vbmx5IENocm9uaWsgVU5EIEF1ZGl0LVRyYWlsIChzaWVoZSB1bnRlbikuCi0gYC5tZXRhL2luZ2VzdGVkLnR4dGAgLSBEYXRlaW5hbWVuIGRlciBiZXJlaXRzIHZlcmFyYmVpdGV0ZW4gUXVlbGxlbgogIChlaW5lIHBybyBaZWlsZSkuIE5hY2ggZGVtIEluZ2VzdCBlaW50cmFnZW4sIGRhbWl0IGRpZSBRdWVsbGUgYXVzCiAgYHBlbmRpbmcubWRgIHZlcnNjaHdpbmRldC4KCiMjIEZyb250bWF0dGVyLUtvbnZlbnRpb24gKGplZGUgd2lraS1TZWl0ZSkKCiAgICB0aXRsZSwgdHlwZSAoZW50aXR5fGNvbmNlcHR8ZGVjaXNpb258ZGlnZXN0KSwgc3VtbWFyeSwKICAgIHNvdXJjZXM6IFtdLCBjb25maWRlbmNlOiAwLjAtMS4wLCBsYXN0X2NvbmZpcm1lZDogWVlZWS1NTS1ERCwKICAgIHN1cGVyc2VkZXM6IFtdLCBzdXBlcnNlZGVkX2J5OiBbXSwKICAgIHJlbGF0aW9uc2hpcHM6IFt7cmVsYXRpb24sIHRhcmdldH1dCgpSZWxhdGlvbnN0eXBlbjogdXNlcywgZGVwZW5kcy1vbiwgY29udHJhZGljdHMsIHN1cGVyc2VkZXMsIGNhdXNlZCwgZml4ZWQuCgojIyBPcGVyYXRpb25lbgoKIyMjIEluZ2VzdAoxLiBRdWVsbGUgbGVzZW4uIFZvciBkZW0gU2NocmVpYmVuIFNFTlNJQkxFIERBVEVOIGVudGZlcm5lbiAoQVBJLUtleXMsCiAgIFRva2VucywgUGFzc3dvZXJ0ZXIsIFBJSSkgLSBuaWUgaW5zIFdpa2kgdWViZXJuZWhtZW4uCjIuIEtlcm4tVGFrZWF3YXlzIGt1cnogbWl0IGRlbSBOdXR6ZXIgYmVzcHJlY2hlbi4KMy4gRW50aXRpZXMgZXh0cmFoaWVyZW4gKFBlcnNvbi9Qcm9qZWt0L0xpYnJhcnkvS29uemVwdC9EYXRlaS9FbnRzY2hlaWR1bmcpCiAgIG1pdCBUeXAsIEF0dHJpYnV0ZW4gdW5kIEJlemllaHVuZ2VuLgo0LiBadXNhbW1lbmZhc3N1bmdzLVNlaXRlICsgRW50aXR5LS9Db25jZXB0LVNlaXRlbiBzY2hyZWliZW4vYWt0dWFsaXNpZXJlbi4KNS4gQ29uZmlkZW5jZSB2ZXJnZWJlbjogQW56YWhsIFF1ZWxsZW4gKyBBa3R1YWxpdGFldCArIFdpZGVyc3BydWVjaGUuCjYuIGBpbmRleC5tZGAgYWt0dWFsaXNpZXJlbi4KNy4gRGF0ZWluYW1lIGRlciBRdWVsbGUgaW4gYC5tZXRhL2luZ2VzdGVkLnR4dGAgZWludHJhZ2VuIChlaW5lIHBybyBaZWlsZSkgLQogICBkYW5hY2ggdmVyc2Nod2luZGV0IHNpZSBhdXRvbWF0aXNjaCBhdXMgYHBlbmRpbmcubWRgLgo4LiBFaW50cmFnIGluIGBsb2cubWRgIGFuZnVlZ2VuLgoKIyMjIFF1ZXJ5Ci0gWnVlcnN0IGBpbmRleC5tZGAsIGRhbm4gZGllIHJlbGV2YW50ZW4gU2VpdGVuLgotIEFudHdvcnRlbiBtaXQgUXVlbGxlbnZlcndlaXNlbiAoYFtbcXVlbGxlXV1gKSBmb3JtdWxpZXJlbi4KLSBXZXJ0dm9sbGUgQW50d29ydGVuIGFscyBuZXVlIGB3aWtpL2AtU2VpdGUgYWJsZWdlbiAoS29tcGVuZGl1bSEpLgotIEJlaSBCZXppZWh1bmdzZnJhZ2VuICgiV2FzIGhhZW5ndCB2b24gWCBhYj8iKSB1ZWJlciBkaWUKICBgcmVsYXRpb25zaGlwc2AtRWludHJhZWdlIHdhbmRlcm4sIG5pY2h0IG51ciBTdGljaHdvcnRzdWNoZS4KCiMjIyBTdXBlcnNlc3Npb24KLSBOZXVlIEluZm8gd2lkZXJzcHJpY2h0L2FrdHVhbGlzaWVydCBhbHRlOiBORVVFIFNlaXRlIHNjaHJlaWJlbiwgYWx0ZQogIFNlaXRlIG1pdCBgc3VwZXJzZWRlZF9ieTogW1tuZXVlXV1gIG1hcmtpZXJlbiAobmljaHQgbG9lc2NoZW4pLAogIGluIGBsb2cubWRgIHZlcm1lcmtlbiAod2Fubi93YXJ1bSkuCgojIyMgTGludCAoaGVhbHRoIGNoZWNrLCBzZWxmLWhlYWxpbmcpClJlZ2VsbWFlc3NpZyBhdXNmdWVocmVuOgotIFdpZGVyc3BydWVjaGUgZmluZGVuIFVORCBhdWZsb2VzZW4gKFF1ZWxsLUFsdGVyLCBRdWVsbC1BdXRvcml0YWV0LAogIEFuemFobCBCZWxlZ2UpOyBkZXIgTnV0emVyIGthbm4gdWViZXJzdGltbWVuLgotIFN1cGVyc2VkZWQvc3RhbGUgQ2xhaW1zIG1hcmtpZXJlbi4KLSBWZXJ3YWlzdGUgU2VpdGVuIHZlcmxpbmtlbiBvZGVyIGFscyBvcnBoYW4gZmxhZ2dlbi4KLSBGZWhsZW5kZSBWZXJsaW5rdW5nZW4gcmVwYXJpZXJlbi4KLSBSZXRlbnRpb246IFNlaXRlbiBvaG5lIEJlc3RhZXRpZ3VuZyA+OTAgVGFnZSBmdWVyIFJldmlldyBmbGFnZ2VuCiAgKG5pY2h0IGxvZXNjaGVuISkuCi0gUXVhbGl0YWV0OiB1bnN0cnVrdHVyaWVydGUvdW5rb250aWVydGUgU2VpdGVuIHVlYmVyYXJiZWl0ZW4uCi0gRGF0ZW5sdWVja2VuIHZvcnNjaGxhZ2VuLCBkaWUgcGVyIFdlYnN1Y2hlIGZ1ZWxsYmFyIHNpbmQuCgojIyMgRGlnZXN0IC8gS3Jpc3RhbGxpc2F0aW9uCk5hY2ggYWJnZXNjaGxvc3NlbmVyIFJlY2hlcmNoZS0vRGVidWdnaW5nLVNlc3Npb24gZWluZW4gRGlnZXN0IGFubGVnZW46CkZyYWdlLCBFcmtlbm50bmlzc2UsIGJldGVpbGlndGUgRGF0ZWllbi9FbnRpdGllcywgTGVocmVuLiBMZWhyZW4gYWxzClN0YW5kYWxvbmUtRmFrdGVuIGlucyBXaWtpIHVlYmVybmVobWVuLgoKIyMgS29udmVudGlvbmVuCgotIEtlaW4gYHJhdy9gIGFlbmRlcm4uIEtlaW5lIEdlaGVpbW5pc3NlIGlucyBXaWtpLgotIGBsb2cubWRgID0gQXVkaXQtVHJhaWw6IGplZGVyIEluZ2VzdC9MaW50L1N1cGVyc2Vzc2lvbiBtaXQgWmVpdHN0ZW1wZWwKICB1bmQgR3J1bmQuIEZvcm1hdDogYCMjIFtZWVlZLU1NLUREXSBvcGVyYXRpb24gfCBUaXRlbGAKLSBXZW5uIHVuc2ljaGVyOiBsaWViZXIgZnJhZ2VuIGFscyByYXRlbi4KRU9GCgogIGNhdCA+ICIkYmFzZS9DTEFVREUubWQiIDw8J0VPRicKIyBDTEFVREUubWQgLSBFcmlubmVydW5nIGZ1ZXIgQ2xhdWRlIENvZGUKCkRpZXNlciBWYXVsdCBmb2xndCBkZW0gTExNLVdpa2ktUGF0dGVybiB2b24gQW5kcmVqIEthcnBhdGh5ICh2MSkgbWl0IGRlbgpFcndlaXRlcnVuZ2VuIGF1cyAiTExNIFdpa2kgdjIiIHZvbiByb2hpdGcwMCAoQ29uZmlkZW5jZSwgU3VwZXJzZXNzaW9uLApTZWxmLUhlYWxpbmctTGludCkuIERhcyB2b2xsc3RhZW5kaWdlIFNjaGVtYSBzdGVodCBpbiBBR0VOVFMubWQgLSBsaWVzCmVzIHVuZCBoYW5kbGUgbmFjaCBkZXNzZW4gUmVnZWxuLgoKIyMgS2VybnJlZ2VsbgoKLSBgcmF3L2AgaXN0IGltbXV0YWJsZSAoYXBwZW5kLW9ubHkpLCBuaWUgYmVhcmJlaXRlbi4KLSBXaWtpLVNlaXRlbiBpbiBgd2lraS9gIHNjaHJlaWJlbiwgbWl0IEZyb250bWF0dGVyIHVuZCBRdWVsbGVudmVyd2Vpc2VuLgotIGBpbmRleC5tZGAgYmVpIGplZGVtIEluZ2VzdCBha3R1YWxpc2llcmVuLCBgbG9nLm1kYC1FaW50cmFnIGFuZnVlZ2VuLgotIEluZ2VzdCAvIFF1ZXJ5IC8gTGludCBnZW5hdSB3aWUgaW4gQUdFTlRTLm1kIGJlc2NocmllYmVuIGR1cmNoZnVlaHJlbi4KRU9GCgogIGNhdCA+ICIkYmFzZS8uZ2l0aWdub3JlIiA8PCdFT0YnCi50cmFzaC8KLm9ic2lkaWFuL3dvcmtzcGFjZSoKRU9GCgogIG1rZGlyIC1wICIkYmFzZS8ubWV0YSIKICA6ID4gIiRiYXNlLy5tZXRhL2luZ2VzdGVkLnR4dCIKICBjYXQgPiAiJGJhc2UvLnN0aWdub3JlIiA8PCdFT0YnCi5naXQvCkVPRgogIGNhdCA+ICIkYmFzZS9wZW5kaW5nLm1kIiA8PCdFT0YnCiMgUGVuZGluZy1JbmJveAoKX05vY2gga2VpbmUgUXVlbGxlbi4gTmV1ZSBEYXRlaWVuIGluIGByYXcvYCB3ZXJkZW4gaGllciBhdXRvbWF0aXNjaCBnZWxpc3RldC5fCkVPRgoKICBjaG93biAtUiAiJENUX1NZTkNfVVNFUiI6IiRDVF9TWU5DX1VTRVIiICIkYmFzZSIKICBydW5fYXNfc3luYygpIHsKICAgIHN1IC1zIC9iaW4vYmFzaCAiJENUX1NZTkNfVVNFUiIgLWMgIiQxIgogIH0KICBpZiAhIHJ1bl9hc19zeW5jICJjZCAnJGJhc2UnICYmIGdpdCBpbml0IC1xIjsgdGhlbgogICAgZWNobyAiPj4+IEdJVC1JTklULUZFSExFUiBpbiAkYmFzZToiCiAgICBscyAtbGEgIiRiYXNlIgogICAgZ2l0IC0tdmVyc2lvbgogICAgZXhpdCAxCiAgZmkKICBydW5fYXNfc3luYyAiY2QgJyRiYXNlJyAmJiBnaXQgY29uZmlnIHVzZXIubmFtZSBPYnNpZGlhbiAmJiBnaXQgY29uZmlnIHVzZXIuZW1haWwgb2JzaWRpYW5AbG9jYWwiCiAgcnVuX2FzX3N5bmMgImNkICckYmFzZScgJiYgZ2l0IGFkZCAtQSIKICBpZiBbIC1uICIkKHJ1bl9hc19zeW5jICJjZCAnJGJhc2UnICYmIGdpdCBzdGF0dXMgLS1wb3JjZWxhaW4iKSIgXTsgdGhlbgogICAgaWYgISBydW5fYXNfc3luYyAiY2QgJyRiYXNlJyAmJiBnaXQgY29tbWl0IC1xbSAnSW5pdGlhbCciOyB0aGVuCiAgICAgIGVjaG8gIj4+PiBHSVQtQ09NTUlULUZFSExFUiBpbiAkYmFzZToiCiAgICAgIHJ1bl9hc19zeW5jICJjZCAnJGJhc2UnICYmIGdpdCBzdGF0dXMiIHx8IHRydWUKICAgICAgcnVuX2FzX3N5bmMgImNkICckYmFzZScgJiYgbHMgLWxhIiB8fCB0cnVlCiAgICAgIGV4aXQgMQogICAgZmkKICAgIGVjaG8gIj4+PiBHaXQtSW5pdGlhbC1Db21taXQgaW4gJGJhc2Ugb2suIgogIGVsc2UKICAgIGVjaG8gIj4+PiBIaW53ZWlzOiBpbiAkYmFzZSBnaWJ0IGVzIG5pY2h0cyB6dSBjb21taXR0ZW4gKG5vLW9wKS4iCiAgZmkKfQoKc2NhZmZvbGRfdmF1bHQgIndvcmsiCnNjYWZmb2xkX3ZhdWx0ICJwcml2YXRlIgoKY2hvd24gLVIgIiRDVF9TWU5DX1VTRVIiOiIkQ1RfU1lOQ19VU0VSIiAiJFZBVUxUX0JBU0UiCgpjYXQgPiAvdXNyL2xvY2FsL2Jpbi92YXVsdC1naXQtY29tbWl0IDw8J0VPRicKIyEvYmluL2Jhc2gKZm9yIHYgaW4gd29yayBwcml2YXRlOyBkbwogIGQ9L3Nydi92YXVsdHMvJHYKICBbIC1kICIkZC8uZ2l0IiBdIHx8IGNvbnRpbnVlCiAgaWYgWyAtbiAiJChnaXQgLUMgIiRkIiBzdGF0dXMgLS1wb3JjZWxhaW4pIiBdOyB0aGVuCiAgICBnaXQgLUMgIiRkIiBhZGQgLUEKICAgIGdpdCAtQyAiJGQiIGNvbW1pdCAtcW0gImF1dG86ICQoZGF0ZSAnKyVZLSVtLSVkICVIOiVNJykiCiAgZmkKZG9uZQpFT0YKY2htb2QgK3ggL3Vzci9sb2NhbC9iaW4vdmF1bHQtZ2l0LWNvbW1pdAoKY2F0ID4gL2V0Yy9jcm9uLmQvdmF1bHQtZ2l0IDw8J0VPRicKMCAqLzIgKiAqICogcm9vdCAvdXNyL2xvY2FsL2Jpbi92YXVsdC1naXQtY29tbWl0ID4vZGV2L251bGwgMj4mMQpFT0YKCmNhdCA+IC91c3IvbG9jYWwvYmluL3RyYWNrLXBlbmRpbmcuc2ggPDwnRU9GJwojIS9iaW4vYmFzaAojIFBlbmRpbmctSW5ib3ggamUgVmF1bHQgYWt0dWFsaXNpZXJlbjogbGlzdGV0IG5ldWUgRGF0ZWllbiBhdXMgcmF3LywKIyBkaWUgbm9jaCBuaWNodCBpbiAubWV0YS9pbmdlc3RlZC50eHQgc3RlaGVuLgpmb3IgdiBpbiB3b3JrIHByaXZhdGU7IGRvCiAgZGlyPS9zcnYvdmF1bHRzLyR2CiAgWyAtZCAiJGRpci9yYXciIF0gfHwgY29udGludWUKICBzdGF0ZT0iJGRpci8ubWV0YS9pbmdlc3RlZC50eHQiCiAgWyAtZiAiJHN0YXRlIiBdIHx8IDogPiAiJHN0YXRlIgogIHRtcD0iJChta3RlbXApIgogIDogPiAiJHRtcCIKICB3aGlsZSBJRlM9IHJlYWQgLXIgLWQgJycgZjsgZG8KICAgIGJhc2U9IiQoYmFzZW5hbWUgIiRmIikiCiAgICBpZiAhIGdyZXAgLXF4RiAtLSAiJGJhc2UiICIkc3RhdGUiIDI+L2Rldi9udWxsOyB0aGVuCiAgICAgIHByaW50ZiAtLSAnLSBbIF0gJXMgIF8oZW50ZGVja3Q6ICVzKV9cbicgIiRiYXNlIiAiJChkYXRlICslRikiID4+ICIkdG1wIgogICAgZmkKICBkb25lIDwgPChmaW5kICIkZGlyL3JhdyIgLW1heGRlcHRoIDEgLXR5cGUgZiAtcHJpbnQwIHwgc29ydCAteikKICBpZiBbIC1zICIkdG1wIiBdOyB0aGVuCiAgICB7IHByaW50ZiAiIyBQZW5kaW5nLUluYm94XG5cbk5ldWUgUXVlbGxlbiBpbiBcYHJhdy9cYCB3YXJ0ZW4gYXVmIEluZ2VzdDpcblxuIjsgY2F0ICIkdG1wIjsgfSA+ICIkZGlyL3BlbmRpbmcubWQiCiAgZWxzZQogICAgcHJpbnRmICIjIFBlbmRpbmctSW5ib3hcblxuX0FsbGUgUXVlbGxlbiB2ZXJhcmJlaXRldCAtIG5pY2h0cyB6dSB0dW4uX1xuIiA+ICIkZGlyL3BlbmRpbmcubWQiCiAgZmkKICBybSAtZiAiJHRtcCIKICBjaG93biBzeW5jdGhpbmc6c3luY3RoaW5nICIkZGlyL3BlbmRpbmcubWQiICIkZGlyLy5tZXRhL2luZ2VzdGVkLnR4dCIgMj4vZGV2L251bGwgfHwgdHJ1ZQpkb25lCkVPRgpjaG1vZCAreCAvdXNyL2xvY2FsL2Jpbi90cmFjay1wZW5kaW5nLnNoCgpjYXQgPiAvdXNyL2xvY2FsL2Jpbi9zZWNvbmRicmFpbi1tYWludGFpbi1jcm9uIDw8J0VPRicKIyEvYmluL2Jhc2gKIyBPcHRpb25hbGUgdGFlZ2xpY2hlIFdhcnR1bmc6IExpbnQgKyBEaWdlc3QgZHVyY2ggZWluZW4gS0ktQWdlbnRlbi4KIyBBa3RpdmllcmVuOiB0b3VjaCAvZXRjL3NlY29uZGJyYWluL2F1dG9ub21vdXMgICAoQWdlbnQgbXVzcyBpbSBDb250YWluZXIgaW5zdGFsbGllcnQgc2VpbikKTE9HPS92YXIvbG9nL3NlY29uZGJyYWluLW1haW50YWluLmxvZwphZ2VudD0iIgpmb3IgYyBpbiBvcGVuY29kZSBjbGF1ZGUgY29kZXg7IGRvCiAgaWYgY29tbWFuZCAtdiAiJGMiID4vZGV2L251bGwgMj4mMTsgdGhlbiBhZ2VudD0iJGMiOyBicmVhazsgZmkKZG9uZQpbIC1uICIkYWdlbnQiIF0gfHwgZXhpdCAwCmZvciB2IGluIHdvcmsgcHJpdmF0ZTsgZG8KICBkaXI9L3Nydi92YXVsdHMvJHYKICBbIC1kICIkZGlyLy5naXQiIF0gfHwgY29udGludWUKICBjZCAiJGRpciIgfHwgY29udGludWUKICBlY2hvICI9PT0gJChkYXRlICcrJVktJW0tJWQgJUg6JU0nKSA6ICR2IHZpYSAkYWdlbnQgPT09IiA+PiAiJExPRyIKICBjYXNlICIkYWdlbnQiIGluCiAgICBvcGVuY29kZSkgb3BlbmNvZGUgcnVuICJGdWVocmUgTGludCB1bmQgb3B0aW9uYWwgZWluZW4gRGlnZXN0IGdlbWFlc3MgQUdFTlRTLm1kIGF1cy4gUHJvdG9rb2xsaWVyZSBkaWUgQWVuZGVydW5nZW4uIiA+PiAiJExPRyIgMj4mMSA7OwogICAgY2xhdWRlKSAgIGNsYXVkZSAtcCAiRnVlaHJlIExpbnQgdW5kIG9wdGlvbmFsIGVpbmVuIERpZ2VzdCBnZW1hZXNzIENMQVVERS5tZCBhdXMuIFByb3Rva29sbGllcmUgZGllIEFlbmRlcnVuZ2VuLiIgPj4gIiRMT0ciIDI+JjEgOzsKICAgIGNvZGV4KSAgICBjb2RleCBleGVjICJGdWVocmUgTGludCB1bmQgb3B0aW9uYWwgZWluZW4gRGlnZXN0IGdlbWFlc3MgQUdFTlRTLm1kIGF1cy4gUHJvdG9rb2xsaWVyZSBkaWUgQWVuZGVydW5nZW4uIiA+PiAiJExPRyIgMj4mMSA7OwogIGVzYWMKZG9uZQpFT0YKY2htb2QgK3ggL3Vzci9sb2NhbC9iaW4vc2Vjb25kYnJhaW4tbWFpbnRhaW4tY3JvbgoKY2F0ID4gL2V0Yy9jcm9uLmQvc2Vjb25kYnJhaW4tbWFpbnRhaW4gPDwnRU9GJwojIFN0dWVuZGxpY2g6IFBlbmRpbmctSW5ib3ggYWt0dWFsaXNpZXJlbiAoa2VpbiBUb2tlbi1WZXJicmF1Y2gpLgo3ICogKiAqICogcm9vdCAvdXNyL2xvY2FsL2Jpbi90cmFjay1wZW5kaW5nLnNoID4vZGV2L251bGwgMj4mMQojIE9wdGlvbmFsIHRhZWdsaWNoIDAzOjE1OiBhdXRvIExpbnQvRGlnZXN0IGR1cmNoIEtJLUFnZW50LgojIEFrdGl2aWVyZW4gbWl0OiB0b3VjaCAvZXRjL3NlY29uZGJyYWluL2F1dG9ub21vdXMKMTUgMyAqICogKiByb290IHRlc3QgLWYgL2V0Yy9zZWNvbmRicmFpbi9hdXRvbm9tb3VzICYmIC91c3IvbG9jYWwvYmluL3NlY29uZGJyYWluLW1haW50YWluLWNyb24gPi9kZXYvbnVsbCAyPiYxCkVPRgoKZWNobyAiPj4+IFs4LzhdIEdlcsOkdGUtQW5sZWl0dW5nIHNjaHJlaWJlbiIKSVBfQUREUj0kKGhvc3RuYW1lIC1JIHwgYXdrICd7cHJpbnQgJDF9JykKCmNhdCA+IC9yb290L0RFVklDRS1TRVRVUC5tZCA8PEVPRgojIFNlY29uZEJyYWluIC0gR2Vyw6R0ZS1FaW5yaWNodHVuZwoKIyMgWnVnYW5nc2RhdGVuIC8gSURzCgotIFNlcnZlci1JUDogICAgICAgIFxgJElQX0FERFJcYAotIFN5bmN0aGluZy1XZWItVUk6IFxgaHR0cDovLyRJUF9BRERSOjgzODRcYCAgKFVzZXI6IFxgJFNZTkNfR1VJX1VTRVJcYCkKLSBTZXJ2ZXItRGV2aWNlLUlEOiBcYCRERVZJQ0VfSURcYAotIFN5bmN0aGluZy1Gb2xkZXJzIChTZXJ2ZXIpOgpFT0YKd2hpbGUgSUZTPTogcmVhZCAtciBsYWJlbCBmaWQ7IGRvCiAgZWNobyAiLSBcYCRsYWJlbFxgIC0+IFxgJGZpZFxgIiA+PiAvcm9vdC9ERVZJQ0UtU0VUVVAubWQKZG9uZSA8IC9yb290L2ZvbGRlci1pZHMudHh0CgpjYXQgPj4gL3Jvb3QvREVWSUNFLVNFVFVQLm1kIDw8RU9GCgpEaWUgVmF1bHRzIGxpZWdlbiBhdWYgZGVtIFNlcnZlciB1bnRlcjoKLSBXb3JrOiAgICAvc3J2L3ZhdWx0cy93b3JrCi0gUHJpdmF0ZTogL3Nydi92YXVsdHMvcHJpdmF0ZQoKSmVkZXIgVmF1bHQgaGF0IGRpZSBTdHJ1a3R1cjogcmF3LyAoUXVlbGxlbiksIHdpa2kvIChMTE0tU2VpdGVuKSwKaW5kZXgubWQsIGxvZy5tZCwgQUdFTlRTLm1kIChTY2hlbWEgZnVlciBPcGVuQ29kZS9Db2RleCksIENMQVVERS5tZAooU2NoZW1hIGZ1ZXIgQ2xhdWRlIENvZGUpLgoKIyMgV2llIGRlaW4gVmF1bHQgYXVmIGRlaW5lIEdlcmFldGUga29tbXQKCkVzIGdpYnQga2VpbmUgIlZhdWx0LVVSTCI6IFN5bmN0aGluZyBzeW5jaHJvbmlzaWVydCBPcmRuZXIgZGlyZWt0CkdlcmFldC16dS1HZXJhZXQgKGFlaG5saWNoIHdpZSBHaXQtUmVwb3MpLiBEZXIgU2VydmVyIGlzdCBkYWJlaSBkZXIKaW1tZXItYXVmLUtub3RlbjoKCi0gV2ViLVVJIChTZXJ2ZXIpOiAgaHR0cDovLyRJUF9BRERSOjgzODQgICAtIGhpZXIgdmVyd2FsdGVzdCBkdSBHZXJhZXRlIHVuZCBGb2xkZXIKLSBTeW5jLVBvcnQ6ICAgICAgICB0Y3A6Ly8kSVBfQUREUjoyMjAwMCAgIC0gaGllciBsYXVmZW4gZGllIFVlYmVydHJhZ3VuZ2VuCgpTb2JhbGQgZHUgKDEpIGRlaW4gR2VyYWV0IHBlciBEZXZpY2UtSUQgdmVyYnVuZGVuIHVuZCAoMikgZGVuIE9yZG5lciBhdWYKZGVtIFNlcnZlciBtaXQgZGVpbmVtIEdlcmFldCBnZXRlaWx0IGhhc3QsIGVyc2NoZWludCBkZXIgVmF1bHQgYXVmIGRlaW5lbQpHZXJhZXQgYWxzIGdhbnogbm9ybWFsZXIgbG9rYWxlciBPcmRuZXIuIERpZXNlbiBvZWZmbmVzdCBkdSBpbiBPYnNpZGlhbgooIk9yZG5lciBhbHMgVmF1bHQgb2VmZm5lbiIpIC0gZGVyc2VsYmUgT3JkbmVyLCBkZW4gYXVjaCBkZWluIEtJLUFnZW50CmxpZXN0IHVuZCBzY2hyZWlidC4KCiMjIEdydW5kcHJpbnppcCBkZXIgVHJlbm51bmcKCkFyYmVpdHNnZXJhZXRlIHRlaWxlbiBOVVIgZGVuIEZvbGRlciAid29yayIsIHByaXZhdGUgR2VyYWV0ZSBOVVIgZGVuCkZvbGRlciAicHJpdmF0ZSIuIERlciBTZXJ2ZXIgaMOkbHQgYmVpZGUuIFNvIGxhbmRldCBwcml2YXRlciBJbmhhbHQgbmllCmF1ZiBlaW5lbSBBcmJlaXRzZ2VyYWV0IHVuZCB1bWdla2VocnQuCgotLS0KCiMjIDEpIERlc2t0b3AgKFdpbmRvd3MgLyBMaW51eCAvIE1hYykKCjEuIFN5bmN0aGluZyBpbnN0YWxsaWVyZW4gKGh0dHBzOi8vc3luY3RoaW5nLm5ldCkgdW5kIHN0YXJ0ZW4uCjIuIFdlYi1VSSBkZWluZXMgR2VyYWV0cyBvZWZmbmVuIChodHRwOi8vMTI3LjAuMC4xOjgzODQpLgozLiAiUmVtb3RlLUdlcmFldCBoaW56dWZ1ZWdlbiI6IFNlcnZlci1EZXZpY2UtSUQgb2JlbiBlaW50cmFnZW4uCiAgIFRpcHA6IEFscyBBZHJlc3NlIG9wdGlvbmFsIFxgdGNwOi8vJElQX0FERFI6MjIwMDBcYCBlaW50cmFnZW4sIGRhbWl0CiAgIGRpZSBWZXJiaW5kdW5nIG9obmUgRGlzY292ZXJ5IHNvZm9ydCBhdWZnZWJhdXQgd2lyZC4KNC4gQXVmIGRlbSBTRVJWRVIgKFdlYi1VSSBodHRwOi8vJElQX0FERFI6ODM4NCk6CiAgIC0gIlJlbW90ZS1HZXJhZXQgaGluenVmdWVnZW4iIC0+IERldmljZS1JRCBkZWluZXMgR2VyYWV0cyBlaW50cmFnZW4uCiAgIC0gRGllIEdlcmFldGUgbXVlc3NlbiBzaWNoIGdlZ2Vuc2VpdGlnIGtlbm5lbiB1bmQgZGllIFZlcmJpbmR1bmcgYWt6ZXB0aWVyZW4uCjUuIEF1ZiBkZW0gU2VydmVyOiAiT3JkbmVyIHRlaWxlbiIgLT4gZGVuIHBhc3NlbmRlbiBGb2xkZXIgKHdvcmsgT0RFUiBwcml2YXRlKQogICBtaXQgZGVpbmVtIEdlcmFldCB0ZWlsZW4uCjYuIEF1ZiBkZWluZW0gR2VyYWV0OiBEZXIgZ2V0ZWlsdGUgT3JkbmVyIHdpcmQgYW5nZWxlZ3QuIEZlcnRpZy4KCiMjIDIpIEFuZHJvaWQKCjEuICJTeW5jdGhpbmciIGF1cyBkZW0gUGxheSBTdG9yZSBpbnN0YWxsaWVyZW4uCjIuIEdsZWljaGVzIFZlcmZhaHJlbiB3aWUgRGVza3RvcDogR2Vyw6R0ICsgU2VydmVyIHZlcmJpbmRlbiAoRGV2aWNlLUlEcwogICB0YXVzY2hlbiksIGRlbiBwYXNzZW5kZW4gT3JkbmVyICh3b3JrL3ByaXZhdGUpIHRlaWxlbi4KMy4gSW4gU3luY3RoaW5nIGRlbiBTeW5jLU9yZG5lciBhbiBlaW5lbiBndXQgZXJyZWljaGJhcmVuIE9ydCBsZWdlbgogICAoei5CLiAvc3RvcmFnZS9lbXVsYXRlZC8wL1N5bmMvLi4uKS4KCiMjIDMpIGlPUyAvIGlQYWRPUyAoaVBob25lIC8gaVBhZCkKCmlPUyBoYXQga2VpbiBuYXRpdmVzIFN5bmN0aGluZy4gTG9lc3VuZzogIk3DtmJpdXMgU3luYyIgKEFwcCBTdG9yZSwKU3luY3RoaW5nLWtvbXBhdGliZWwpLgoxLiBNw7ZiaXVzIFN5bmMgaW5zdGFsbGllcmVuLgoyLiBTZXJ2ZXIgYWxzIFJlbW90ZS1HZXJhZXQgaGluenVmdWVnZW4gKFNlcnZlci1EZXZpY2UtSUQpLgozLiBBdWYgZGVtIFNlcnZlciBkZW4gcGFzc2VuZGVuIE9yZG5lciBtaXQgZGllc2VtIEdlcmFldCB0ZWlsZW4uCjQuIE3DtmJpdXMgU3luYyBpbiAiT24gTXkgaVBob25lIiBzeW5jaHJvbmlzaWVyZW4gbGFzc2VuLgo1LiBPYnNpZGlhbiBpbnN0YWxsaWVyZW4gdW5kIGRpZXNlbiBsb2thbGVuIE9yZG5lciBhbHMgVmF1bHQgb2VmZm5lbi4KCiMjIDQpIE9ic2lkaWFuIG51dHplbgoKMS4gT2JzaWRpYW4gaW5zdGFsbGllcmVuIChEZXNrdG9wIG9kZXIgbW9iaWwpLgoyLiAiT3JkbmVyIGFscyBWYXVsdCBvZWZmbmVuIiB1bmQgZGVuIHN5bmNocm9uaXNpZXJ0ZW4gT3JkbmVyIHdhZWhsZW4uCjMuIE9ic2lkaWFuIGxpZXN0L3NjaHJlaWJ0IGxva2FsOyBTeW5jdGhpbmcgaMOkbHQgYWxsZSBHZXJhZXRlICsgU2VydmVyCiAgIGF1ZiBkZW1zZWxiZW4gU3RhbmQuIEF1Y2ggbW9iaWwga2FubnN0IGR1IHNjaHJlaWJlbiAtIGVzIHdpcmQKICAgenVydWVja3N5bmNocm9uaXNpZXJ0LgoKIyMgNSkgTExNLU1haW50YWluZXIgKE9wZW5Db2RlKQoKRGFzIEhlcnogZGVzIFBhdHRlcm5zOiBkZXIgQWdlbnQgcGZsZWd0IGRhcyBXaWtpLCBkdSBrdXJhdGllcnN0IFF1ZWxsZW4uCgoxLiBBdWYgZWluZW0gR2VyYWV0IChvZGVyIHZpYSBTU0ggYXVmIGRlbiBTZXJ2ZXIpIGluIGRlbiBWYXVsdCB3ZWNoc2VsbjoKICAgXGBjZCAvc3J2L3ZhdWx0cy93b3JrXGAgICAob2RlciBcYC4uLi9wcml2YXRlXGApCjIuIEFnZW50IHN0YXJ0ZW4gKG9wZW5jb2RlIC8gY2xhdWRlIC8gY29kZXgpLiBEaWUgXGBBR0VOVFMubWRcYCBiencuCiAgIFxgQ0xBVURFLm1kXGAgaW0gVmF1bHQtUm9vdCBkZWZpbmllcmVuIGRpZSBSZWdlbG4uCjMuIFF1ZWxsZW4gZWluZmFjaCBpbiBcYHJhdy9cYCBhYmxlZ2VuICh6LkIuIG1pdCBkZW0gT2JzaWRpYW4gV2ViIENsaXBwZXIpIC0KICAgdW5kIGRlbSBBZ2VudCBlaW5mYWNoIHNhZ2VuOiAiSW5nZXN0IGRpZSBvZmZlbmVuIFB1bmt0ZSBhdXMgcGVuZGluZy5tZCIuCgojIyA2KSBUYWVnbGljaGVyIFdvcmtmbG93IC0gd2llIG9yZG5ldCBkZXIgQWdlbnQgbmV1ZSBJbmZvcyB6dT8KCkRlciBLcmVpc2xhdWY6IENBUFRVUkUgLT4gSU5CT1ggLT4gSU5HRVNUIC0+IFBGTEVHRQoKMS4gQ0FQVFVSRSAoZHUpOiBOZXVlIFF1ZWxsZSBhYmxlZ2VuIC0gQXJ0aWtlbCBwZXIgT2JzaWRpYW4gV2ViIENsaXBwZXIKICAgKHNwZWljaGVydCBhbHMgLm1kKSwgUERGIG9kZXIgRGF0ZWkgZWluZmFjaCBpbiBcYHJhdy9cYCB6aWVoZW4uCjIuIElOQk9YIChhdXRvbWF0aXNjaCwgc3R1ZW5kbGljaCk6IFxgdHJhY2stcGVuZGluZy5zaFxgIGxpc3RldCBuZXVlIERhdGVpZW4KICAgYXVzIFxgcmF3L1xgIGluIFxgcGVuZGluZy5tZFxgIChhbHMgQ2hlY2tib3hlbikuIEluIE9ic2lkaWFuIHNpZWhzdCBkdQogICBqZWRlcnplaXQsIHdhcyBub2NoIHdhcnRldC4KMy4gSU5HRVNUIChkdSArIEFnZW50KTogQWdlbnQgaW0gVmF1bHQgc3RhcnRlbiB1bmQgc2FnZW46CiAgICJJbmdlc3QgYWxsZSBvZmZlbmVuIFB1bmt0ZSBhdXMgcGVuZGluZy5tZCIuIERlciBBZ2VudCBsaWVzdCBkaWUgUXVlbGxlbiwKICAgb3JkbmV0IHNpZSBlaW4gKENvbmZpZGVuY2UsIFJlbGF0aW9uc2hpcHMpLCBzY2hyZWlidC9ha3R1YWxpc2llcnQKICAgd2lraS1TZWl0ZW4gKyBcYGluZGV4Lm1kXGAgKyBcYGxvZy5tZFxgIHVuZCB0cmFlZ3QgZGllIERhdGVpbmFtZW4gaW4KICAgXGAubWV0YS9pbmdlc3RlZC50eHRcYCBlaW4uIERhbmFjaCB2ZXJzY2h3aW5kZW4gc2llIGF1cyBcYHBlbmRpbmcubWRcYC4KNC4gUEZMRUdFIChwZXJpb2Rpc2NoKTogIkZ1ZWhyZSBMaW50IGF1cyIgLSBkZXIgQWdlbnQgZmluZGV0IFdpZGVyc3BydWVjaGUsCiAgIHZlcndhaXN0ZSBTZWl0ZW4sIFN0YWxlIENsYWltcyB1bmQgaGVpbHQsIHdhcyBoZWlsYmFyIGlzdC4gTmFjaCBncm9zc2VuCiAgIFNlc3Npb25zIGVpbmVuIERpZ2VzdCBhbmxlZ2VuIGxhc3Nlbi4KNS4gQVVUT05PTSAob3B0aW9uYWwpOiBTb2xsIGRlciBTZXJ2ZXIgc2VsYnN0IHRhZWdsaWNoIHVtIDAzOjE1IExpbnQrRGlnZXN0CiAgIGZhaHJlbiAob2huZSBkYXNzIGR1IHN0YXJ0ZXN0KSwgaW5zdGFsbGllcmUgZGVpbmVuIEFnZW50ZW4gWlVTQUVUWkxJQ0gKICAgaW0gQ29udGFpbmVyICh6LkIuIFxgY3VybCAtZnNTTCBodHRwczovL29wZW5jb2RlLmFpL2luc3RhbGwgfCBiYXNoXGApIHVuZDoKICAgICB0b3VjaCAvZXRjL3NlY29uZGJyYWluL2F1dG9ub21vdXMKICAgTG9nOiAvdmFyL2xvZy9zZWNvbmRicmFpbi1tYWludGFpbi5sb2cKCiMjIDcpIEJhY2t1cHMKCk1laHJlcmUgU2NoaWNodGVuIGFrdGl2OgoKMS4gU3luY3RoaW5nICJTdGFnZ2VyZWQgRmlsZSBWZXJzaW9uaW5nIiAoMzAgVGFnZSkgLSBpc3QgYmVyZWl0cyBwcm8KICAgRm9sZGVyIGFrdGl2aWVydDogZ2Vsb2VzY2h0ZS91ZWJlcnNjaHJpZWJlbmUgRGF0ZWllbiBzaW5kIGltIFdlYi1VSQogICB1bnRlciBPcmRuZXIgLT4gIlZlcnNpb25pZXJ1bmciIHdpZWRlcmhlcnN0ZWxsYmFyLgoyLiBHaXQtQXV0by1Db21taXQgYWxsZSAyaCBqZSBWYXVsdCAoQ3JvbjogL2V0Yy9jcm9uLmQvdmF1bHQtZ2l0KS4KICAgSGlzdG9yeSBhbnNlaGVuOiBcYGdpdCAtQyAvc3J2L3ZhdWx0cy93b3JrIGxvZyAtLW9uZWxpbmVcYC4KMy4gUHJveG1veC1CYWNrdXAgZGVzIENvbnRhaW5lcnMgKFpGUy1TbmFwc2hvdHMpIC0gYXVmIGRlbSBIT1NUIGFubGVnZW46CiAgIFxgdnpkdW1wIDxWTUlEPiAtLW1vZGUgc25hcHNob3QgLS1jb21wcmVzcyB6c3RkXGAKICAgb2RlciBiZXNzZXI6IEJhY2t1cC1Kb2IgaW4gZGVyIFByb3htb3gtR1VJIHVudGVyCiAgICJEYXRhY2VudGVyIC0+IEJhY2t1cHMiIGVpbnJpY2h0ZW4gKE1vZGU6IHNuYXBzaG90LCB6c3RkKS4KRU9GCgpjaG1vZCA2NDQgL3Jvb3QvREVWSUNFLVNFVFVQLm1kCgplY2hvICI+Pj4gRWlucmljaHR1bmcgYWJnZXNjaGxvc3Nlbi4iCg==' | base64 -d > "$tmp_inner"
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
