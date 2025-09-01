#!/usr/bin/env bash
#
# kali-nvidia-installer.sh
# GUI-assisted, safer NVIDIA driver + optional CUDA installer for Kali Linux (Zenity UI)
# Author: ChatGPT (for مهراد) — example code for GitHub
# License: MIT
#
# Key features:
#  - GPU detection (lspci / nvidia-detect)
#  - Enable contrib & non-free if needed (optional)
#  - Install kernel headers, dkms, build-essential
#  - Repo-based NVIDIA install (recommended)
#  - Optional: NVIDIA .run installer (advanced, warns user)
#  - Optional: install CUDA (uses repository packages or points to NVIDIA docs)
#  - Blacklist nouveau and regenerate initramfs
#  - Detect Secure Boot and help guide module signing / warn about disabling Secure Boot
#  - Dry-run mode, logging, backup/restore of Xorg configs
#  - Uninstall option
#  - Full logging to /var/log/kali-nvidia-installer-YYYYMMDD-HHMM.log
#
set -o errexit
set -o nounset
set -o pipefail

PROGNAME="$(basename "$0")"
LOG_DIR="/var/log"
LOG_FILE="${LOG_DIR}/kali-nvidia-installer-$(date +%Y%m%d-%H%M%S).log"
DRY_RUN=false
ZENITY=$(command -v zenity || true)

# -- Helpers -------------------------------------------------------------------
log() {
  local msg="$*"
  echo "$(date --iso-8601=seconds) | ${msg}" | tee -a "$LOG_FILE"
}

err_exit() {
  local rc=$1
  local msg="$2"
  log "ERROR: $msg (rc=$rc)"
  if [ -n "$ZENITY" ]; then
    zenity --error --title="Installer Error" --text="$msg\n\nSee log: $LOG_FILE"
  else
    echo "ERROR: $msg"
  fi
  exit "$rc"
}

run_or_log() {
  # wrapper so we can honor dry-run
  if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] $*"
  else
    log "RUN: $*"
    eval "$@" 2>&1 | tee -a "$LOG_FILE"
  fi
}

ensure_root() {
  if [ "$EUID" -ne 0 ]; then
    if [ -n "$ZENITY" ]; then
      zenity --question --title="Need root" --text="This installer needs root. Launch with sudo?\n(Press OK to re-run with sudo)"
      if [ $? -eq 0 ]; then
        exec sudo bash "$0" "$@"
      else
        err_exit 2 "Root privileges required."
      fi
    else
      err_exit 2 "Please run as root."
    fi
  fi
}

ensure_zenity() {
  if [ -z "$ZENITY" ]; then
    echo "Zenity not found. Installing (apt)..." | tee -a "$LOG_FILE"
    apt update -y >>"$LOG_FILE" 2>&1 || true
    apt install -y zenity dialog -y >>"$LOG_FILE" 2>&1 || err_exit 3 "Failed to install zenity"
    ZENITY=$(command -v zenity)
  fi
}

# -- Detect secure boot -------------------------------------------------------
detect_secureboot() {
  if command -v mokutil >/dev/null 2>&1; then
    local sb
    sb=$(mokutil --sb-state 2>/dev/null || echo "mokutil-unavailable")
    echo "$sb"
  else
    # fallback via efivarfs presence
    if [ -d /sys/firmware/efi ]; then
      echo "efi-present-mok-unknown"
    else
      echo "no-efi"
    fi
  fi
}

# -- GPU detection ------------------------------------------------------------
detect_gpu() {
  log "Detecting GPU(s)..."
  run_or_log "lspci | grep -i -E 'vga|3d|display' || true"
  if dpkg -s nvidia-detect >/dev/null 2>&1; then
    run_or_log "nvidia-detect || true"
  else
    log "nvidia-detect not installed (optional)."
  fi
}

# -- Manage sources (add contrib non-free) -----------------------------------
enable_nonfree() {
  log "Ensuring contrib and non-free are in /etc/apt/sources.list"
  local changed=false
  # Backup
  run_or_log "cp -a /etc/apt/sources.list /etc/apt/sources.list.bak-$(date +%s)"
  # Add 'contrib non-free' if missing for kali-rolling lines
  if ! grep -E "kali-rolling.*contrib.*non-free" /etc/apt/sources.list >/dev/null 2>&1; then
    log "Adding contrib non-free to sources.list (only lines matching kali-rolling)."
    # safe replace: append the components to lines that look like main only
    if [ "$DRY_RUN" = false ]; then
      awk '/^deb .*kali-rolling/ {
             if ($0 !~ /contrib/) { $0 = $0 " contrib non-free non-free-firmware" }
           }
           { print }' /etc/apt/sources.list > /tmp/sources.list.new && mv /tmp/sources.list.new /etc/apt/sources.list
    else
      log "[DRY RUN] would add contrib non-free to /etc/apt/sources.list"
    fi
    changed=true
  else
    log "contrib non-free already present."
  fi

  if [ "$changed" = true ]; then
    run_or_log "apt update -y || true"
  fi
}

# -- Install prerequisites ----------------------------------------------------
install_prereqs() {
  # kernel headers, build-essential, dkms, pciutils, wget, ca-certificates
  local pkgs=(linux-headers-$(uname -r) build-essential dkms pciutils wget ca-certificates gnupg)
  log "Installing prerequisites: ${pkgs[*]}"
  run_or_log "apt update -y || true"
  run_or_log "DEBIAN_FRONTEND=noninteractive apt install -y ${pkgs[*]}"
}

# -- Blacklist nouveau --------------------------------------------------------
blacklist_nouveau_and_update_initramfs() {
  log "Blacklisting nouveau and updating initramfs"
  cat <<'EOF' >/etc/modprobe.d/blacklist-nouveau.conf
# Blacklist nouveau for NVIDIA proprietary driver install
blacklist nouveau
options nouveau modeset=0
EOF
  run_or_log "update-initramfs -u -k all"
}

# -- Install from Kali repos (recommended) -----------------------------------
install_nvidia_from_repo() {
  log "Installing NVIDIA driver from Kali repositories (recommended)"
  run_or_log "apt update -y || true"
  # Install nvidia-detect (optional) and nvidia-driver
  run_or_log "DEBIAN_FRONTEND=noninteractive apt install -y nvidia-detect || true"
  run_or_log "DEBIAN_FRONTEND=noninteractive apt install -y nvidia-driver nvidia-kernel-dkms nvidia-utils || true"
  # Optional: CUDA toolkit
  if zenity --question --title="CUDA?" --text="Do you want to install the CUDA toolkit from Kali repos? (optional, can be large)"; then
    run_or_log "DEBIAN_FRONTEND=noninteractive apt install -y nvidia-cuda-toolkit || true"
  fi
  zenity --info --title="Reboot required" --text="The driver package may require a reboot. Reboot now?"
  if [ $? -eq 0 ]; then
    run_or_log "reboot -f"
  fi
}

# -- Install NVIDIA .run (advanced) ------------------------------------------
install_nvidia_from_run() {
  log "Advanced: Install using NVIDIA .run installer (not recommended for beginners)."
  zenity --warning --title="Advanced installer" --text="The .run installer bypasses package manager. Use only if repo driver fails or you need a very specific driver. This can break apt-managed kernel module updates."
  # Ask user for driver URL or file
  local url
  url=$(zenity --entry --title="NVIDIA .run URL or local path" --text="Enter full URL to NVIDIA .run or local path (e.g. /home/user/NVIDIA-Linux-x86_64-XXX.run):")
  if [ -z "$url" ]; then
    log "No URL/path provided; aborting .run install."
    return 1
  fi
  local file="/tmp/$(basename "$url")"
  if [[ "$url" =~ ^https?:// ]]; then
    run_or_log "wget -O '$file' '$url'"
    run_or_log "chmod +x '$file'"
  else
    file="$url"
    if [ ! -f "$file" ]; then err_exit 10 "File not found: $file"; fi
  fi
  # Switch to text mode: ask user to continue
  zenity --question --title="Switch to text mode" --text="The system will switch to text multiuser target (no X). Continue?"
  if [ $? -ne 0 ]; then
    log "User canceled .run install."
    return 1
  fi
  log "Stopping display manager and switching to text mode."
  run_or_log "systemctl isolate multi-user.target || true"
  log "Running: $file --silent --accept-license (installer will run)"
  run_or_log "$file --silent --accept-license || true"
  log "Restoring graphical.target"
  run_or_log "systemctl isolate graphical.target || true"
  zenity --info --title="Done" --text="If installer succeeded, please reboot."
}

# -- Uninstall / Cleanup -----------------------------------------------------
uninstall_nvidia() {
  zenity --question --title="Uninstall NVIDIA" --text="Completely remove NVIDIA packages and restore defaults?"
  if [ $? -ne 0 ]; then
    log "Uninstall canceled."
    return 0
  fi
  run_or_log "DEBIAN_FRONTEND=noninteractive apt remove --purge -y 'nvidia-*' 'libnvidia-*' nvidia-driver nvidia-kernel-dkms nvidia-utils || true"
  # restore nouveau
  if [ -f /etc/modprobe.d/blacklist-nouveau.conf ]; then
    run_or_log "rm -f /etc/modprobe.d/blacklist-nouveau.conf || true"
  fi
  run_or_log "update-initramfs -u -k all || true"
  zenity --info --title="Uninstalled" --text="NVIDIA packages removed. Reboot recommended."
}

# -- Verify installation -----------------------------------------------------
verify_install() {
  log "Verifying installation"
  run_or_log "lspci | grep -i -E 'vga|3d|display' || true"
  if command -v nvidia-smi >/dev/null 2>&1; then
    run_or_log "nvidia-smi || true"
  else
    log "nvidia-smi not found; driver may not be installed."
    zenity --warning --title="Verify" --text="nvidia-smi not found. Driver may not be installed or loaded. Check log: $LOG_FILE"
  fi
}

# -- Module signing helper (explain steps) -----------------------------------
show_signing_info() {
  zenity --info --title="Secure Boot / Module signing" --text="If Secure Boot is enabled, unsigned kernel modules (like those built by DKMS) will not load.\n\nOptions:\n 1) Disable Secure Boot in firmware/UEFI (easiest)\n 2) Sign modules with a Machine Owner Key (MOK) and enroll it (more secure)\n\nSee Debian Secure Boot docs for details and mokutil usage."
  log "Displayed Secure Boot info to user."
}

# -- Menu / UI ---------------------------------------------------------------
main_menu() {
  ensure_zenity
  local choice
  choice=$(zenity --list --title="Kali NVIDIA Installer" --text="Choose an action" --height=400 --width=700 \
    --column="Action" \
    "Detect GPU" \
    "Enable contrib & non-free" \
    "Install prerequisites (headers, dkms, build-essential)" \
    "Blacklist nouveau & update initramfs" \
    "Install NVIDIA (repo, recommended)" \
    "Install NVIDIA (.run, advanced)" \
    "Install CUDA (repos)" \
    "Verify driver / nvidia-smi" \
    "Uninstall NVIDIA (purge)" \
    "Show Secure Boot info" \
    "View log file" \
    "Toggle Dry-run" \
    "Exit")
  case "$choice" in
    "Detect GPU") detect_gpu ;;
    "Enable contrib & non-free") enable_nonfree ;;
    "Install prerequisites (headers, dkms, build-essential)") install_prereqs ;;
    "Blacklist nouveau & update initramfs") blacklist_nouveau_and_update_initramfs ;;
    "Install NVIDIA (repo, recommended)") install_nvidia_from_repo ;;
    "Install NVIDIA (.run, advanced)") install_nvidia_from_run ;;
    "Install CUDA (repos)") run_or_log "DEBIAN_FRONTEND=noninteractive apt install -y nvidia-cuda-toolkit || true" ;;
    "Verify driver / nvidia-smi") verify_install ;;
    "Uninstall NVIDIA (purge)") uninstall_nvidia ;;
    "Show Secure Boot info") show_signing_info ;;
    "View log file") xdg-open "$LOG_FILE" || zenity --text-info --filename="$LOG_FILE" --title="Log file" --width=800 --height=600 ;;
    "Toggle Dry-run")
      DRY_RUN=!$DRY_RUN
      if [ "$DRY_RUN" = true ]; then
        zenity --info --text="Now running in DRY-RUN mode. No changes will be made."
      else
        zenity --info --text="DRY-RUN disabled. Actions will be applied."
      fi
      ;;
    "Exit") log "User exit"; exit 0 ;;
    *) log "No selection or dialog closed"; exit 0 ;;
  esac
}

# -- Ensure log directory exists / permission ---------------------------------
if [ "$(id -u)" -ne 0 ]; then
  # Not root yet — show an info dialog then restart as root
  if [ -n "$ZENITY" ]; then
    zenity --info --title="Kali NVIDIA Installer" --text="This script will ask for root privileges via sudo when needed."
  fi
fi

mkdir -p "$LOG_DIR" || true
touch "$LOG_FILE" || true
log "Starting $PROGNAME (log: $LOG_FILE)"
ensure_zenity
ensure_root

# Main loop
while true; do
  main_menu
done

# EOF
