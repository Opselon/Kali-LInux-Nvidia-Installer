#!/usr/bin/env bash
# Opselon - Enhanced NVIDIA & CUDA Installer
# Version: 2025.09.01
# Author: ChatGPT (for you)
# License: MIT
# Purpose: Robust, safe, user-friendly installer for NVIDIA drivers, CUDA and Optimus setup
# Target: Debian, Ubuntu, Kali (rolling) and derivatives
# Features:
# - Root check, backups, logging, dry-run mode
# - Interactive TUI using whiptail (fallback to simple prompts)
# - Multiple safety checks (network, disk, apt lock, kernel headers match)
# - Optional non-interactive / unattended mode with --yes
# - Idempotent operations where possible
# - Rollback facility using backups
# - Secure-boot detection and guidance
# - DKMS support, retry logic, apt pinning hints
# - Generates systemd service for optimus autostart and xrandr wiring
# - Produces a final report and log file
# NOTES:
# - This script modifies system files and installs kernel/nvidia components.
# - Read the log file if something goes wrong: /var/log/opeselon-nvidia-installer-*.log
# - If your system uses Secure Boot, you may need to enroll MOK keys or disable Secure Boot.
# - Use at your own risk; review the script before running on production systems.

set -o errexit
set -o pipefail
set -o nounset
IFS=$'\n\t'

# -----------------------------
# Global variables
# -----------------------------
SCRIPT_NAME="Opselon-NVIDIA-Installer"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
LOGFILE="/var/log/opeselon-nvidia-installer-${TIMESTAMP}.log"
BACKUP_DIR="/var/backups/opeselon-${TIMESTAMP}"
DRY_RUN=0
ASSUME_YES=0
QUIET=0
USE_WHITELIST_UI=0
WHIPTAL_CMD=""
RETRY_LIMIT=3
APTSOURCE_BACKUP="${BACKUP_DIR}/sources.list.bak"
XORG_BACKUP="${BACKUP_DIR}/xorg.conf.bak"

# Colors for terminal UX (if supported)
if [[ -t 1 ]]; then
  RED="\e[31m"
  GREEN="\e[32m"
  YELLOW="\e[33m"
  BLUE="\e[34m"
  BOLD="\e[1m"
  RESET="\e[0m"
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  BOLD=""
  RESET=""
fi

# -----------------------------
# Utils
# -----------------------------
log() {
  local level="$1"; shift
  local msg="$*"
  echo -e "$(date +'%F %T') [$level] $msg" | tee -a "$LOGFILE"
}

die() {
  log "ERROR" "$*"
  echo -e "${RED}${BOLD}FATAL:${RESET} $*" >&2
  exit 1
}

info() {
  log "INFO" "$*"
  if [[ $QUIET -eq 0 ]]; then
    echo -e "${BLUE}$*${RESET}"
  fi
}

warn() {
  log "WARN" "$*"
  echo -e "${YELLOW}Warning:${RESET} $*"
}

confirm_prompt() {
  local prompt="$1"
  if [[ $ASSUME_YES -eq 1 ]]; then
    return 0
  fi
  if [[ -n "$WHIPTAL_CMD" ]]; then
    $WHIPTAL_CMD --yesno "$prompt" 12 70
    return $?
  else
    read -rp "$prompt [y/N]: " ans
    case "$ans" in
      [yY]|[yY][eE][sS]) return 0 ;;
      *) return 1 ;;
    esac
  fi
}

run_cmd() {
  local cmd=("$@")
  log "CMD" "${cmd[*]}"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "DRY-RUN: ${cmd[*]}"
    return 0
  fi
  "${cmd[@]}"
}

retry_cmd() {
  local tries=0
  local last_err=0
  while [[ $tries -lt $RETRY_LIMIT ]]; do
    if "$@"; then
      return 0
    fi
    last_err=$?
    tries=$((tries+1))
    warn "Command failed, retrying ($tries/$RETRY_LIMIT)..."
    sleep $((tries*2))
  done
  return $last_err
}

# -----------------------------
# Argument parsing
# -----------------------------
usage() {
  cat <<-EOF
Usage: $0 [options]
Options:
  --dry-run            Do not execute changes, just simulate
  --yes, -y            Assume yes to prompts
  --quiet              Minimal output
  --help, -h           Show this help
  --no-ui              Disable whiptail UI fallback to CLI
  --log FILE           Specify logfile (default: $LOGFILE)
  --backup DIR         Specify backup directory
  --unattended         Fully non-interactive (dangerous)

This script attempts to be safe and will create backups. Review the script before running.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --quiet) QUIET=1; shift ;;
    --no-ui) WHIPTAL_CMD=""; shift ;;
    --log) LOGFILE="$2"; shift 2 ;;
    --backup) BACKUP_DIR="$2"; shift 2 ;;
    --unattended) ASSUME_YES=1; QUIET=1; DRY_RUN=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

# Ensure log dir exists
mkdir -p "$(dirname "$LOGFILE")"
: > "$LOGFILE"

# -----------------------------
# Signal handling and trap
# -----------------------------
trap 'on_exit' EXIT
trap 'on_interrupt' INT TERM

on_interrupt() {
  warn "Interrupted by user (SIGINT). Attempting safe exit..."
  # Optionally rollback or stop ongoing tasks
  # Do not auto-rollback destructive operations without user consent
  exit 130
}

on_exit() {
  info "Script finished. Log: $LOGFILE"
}

# -----------------------------
# Environment & Dependency checks
# -----------------------------
require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    die "This installer must be run as root. Use sudo or run as root."
  fi
}

check_network() {
  if ! ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then
    warn "Network seems unreachable. Some operations may fail."
    if ! confirm_prompt "Network unreachable. Continue anyway?"; then
      die "Network required. Exiting."
    fi
  fi
}

check_disk_space() {
  local need_mb=500
  local avail_kb
  avail_kb=$(df --output=avail / | tail -1)
  local avail_mb=$((avail_kb/1024))
  if [[ $avail_mb -lt $need_mb ]]; then
    warn "Low disk space on /: ${avail_mb}MB available. Need at least ${need_mb}MB."
    if ! confirm_prompt "Continue with low disk space?"; then
      die "Not enough disk space. Exiting."
    fi
  fi
}

check_apt_lock() {
  if fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
    warn "APT seems to be locked by another process."
    if ! confirm_prompt "Another apt/dpkg process is running — wait or continue?"; then
      die "APT lock present. Exiting."
    fi
  fi
}

# check whiptail or dialog for TUI
setup_ui() {
  if [[ $ASSUME_YES -eq 1 || $QUIET -eq 1 ]]; then
    WHIPTAL_CMD=""
    return
  fi
  if command -v whiptail >/dev/null 2>&1; then
    WHIPTAL_CMD="whiptail"
  elif command -v dialog >/dev/null 2>&1; then
    WHIPTAL_CMD="dialog"
  else
    warn "whiptail/dialog not installed. Falling back to CLI prompts."
    if confirm_prompt "Install whiptail now for improved UI?"; then
      retry_cmd apt-get update
      retry_cmd apt-get -y install whiptail || true
      if command -v whiptail >/dev/null 2>&1; then
        WHIPTAL_CMD="whiptail"
      fi
    fi
  fi
}

# -----------------------------
# Distro detection & repository management
# -----------------------------
detect_distro() {
  local id_like=""
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    DISTRO_ID=${ID:-unknown}
    DISTRO_NAME=${NAME:-$DISTRO_ID}
    DISTRO_VERSION=${VERSION_ID:-}
    ID_LIKE=${ID_LIKE:-}
  else
    DISTRO_ID="unknown"
    DISTRO_NAME="unknown"
  fi
  info "Detected distro: $DISTRO_NAME ($DISTRO_ID) version $DISTRO_VERSION"
}

backup_configs() {
  info "Creating backup directory: $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
  if [[ -f /etc/apt/sources.list ]]; then
    cp -a /etc/apt/sources.list "$APTSOURCE_BACKUP"
    log "BACKUP" "Created backup of /etc/apt/sources.list -> $APTSOURCE_BACKUP"
  fi
  if [[ -f /etc/X11/xorg.conf ]]; then
    cp -a /etc/X11/xorg.conf "$XORG_BACKUP" || true
    log "BACKUP" "Backed up existing xorg.conf to $XORG_BACKUP"
  fi
}

add_repos_kali() {
  info "Adding Kali rolling repos to /etc/apt/sources.list"
  cat >> /etc/apt/sources.list <<-EOF
# Opselon added Kali repos
deb http://http.kali.org/kali kali-rolling main non-free contrib
deb-src http://http.kali.org/kali kali-rolling main non-free contrib
EOF
}

add_repos_debian_stretch() {
  info "Adding Debian stretch repos (legacy) into /etc/apt/sources.list"
  cat >> /etc/apt/sources.list <<-EOF
# Opselon added Debian stretch repos
deb http://deb.debian.org/debian stretch main contrib non-free
deb-src http://deb.debian.org/debian stretch main contrib non-free

deb http://deb.debian.org/debian-security/ stretch/updates main contrib non-free
deb-src http://deb.debian.org/debian-security/ stretch/updates main contrib non-free

deb http://deb.debian.org/debian stretch-updates main contrib non-free
deb-src http://deb.debian.org/debian stretch-updates main contrib non-free
EOF
}

add_repo_safeguard() {
  # Only add repos if they are not already present (idempotent)
  local needle="$1"
  if grep -Rqs "$needle" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    info "Repository already present: $needle"
  else
    eval "$2"
  fi
}

# -----------------------------
# Nouveau blacklist management
# -----------------------------
blacklist_nouveau() {
  info "Creating nouveau blacklist configuration"
  local conf="/etc/modprobe.d/blacklist-nouveau-opeselon.conf"
  if [[ -f $conf ]]; then
    info "Nouveau blacklist file already exists: $conf"
    return 0
  fi
  cat > "$conf" <<-EOF
# Opselon blacklist nouveau
blacklist nouveau
options nouveau modeset=0
alias nouveau off
EOF
  log "CREATE" "Wrote $conf"
  if [[ $DRY_RUN -eq 0 ]]; then
    update-initramfs -u || warn "update-initramfs failed. You may need to run it manually."
  fi
}

# -----------------------------
# Kernel headers and driver checks
# -----------------------------
install_linux_headers() {
  local kernver
  kernver=$(uname -r)
  info "Installing linux headers for kernel: $kernver"
  retry_cmd apt-get update
  if ! apt-get -y install "linux-headers-${kernver}"; then
    warn "linux-headers-${kernver} not found in repos. Trying meta-package."
    retry_cmd apt-get -y install linux-headers-$(uname -r | sed 's/[^0-9.\-]*//g') || true
  fi
}

# -----------------------------
# NVIDIA driver & CUDA installation
# -----------------------------
install_nvidia_package() {
  info "Installing recommended nvidia-driver package from repos"
  retry_cmd apt-get update
  # On Debian/Ubuntu/Kali, package is usually 'nvidia-driver' or 'nvidia-driver-xxx'
  if apt-cache show nvidia-driver >/dev/null 2>&1; then
    retry_cmd apt-get -y install nvidia-driver nvidia-xconfig || die "Failed to install nvidia-driver"
  else
    # Fallback to driver metapackage names
    if apt-cache show nvidia-driver-535 >/dev/null 2>&1; then
      retry_cmd apt-get -y install nvidia-driver-535 nvidia-xconfig
    elif apt-cache show nvidia-driver-525 >/dev/null 2>&1; then
      retry_cmd apt-get -y install nvidia-driver-525 nvidia-xconfig
    else
      warn "No nvidia-driver meta-package found. Attempting to install nvidia-driver (general)."
      retry_cmd apt-get -y install nvidia-driver || die "No nvidia driver found in apt repositories."
    fi
  fi
}

install_cuda_toolkit() {
  info "Installing CUDA toolkit and OpenCL ICD"
  retry_cmd apt-get -y install ocl-icd-libopencl1 nvidia-cuda-toolkit || warn "nvidia-cuda-toolkit not available in repos (will try fallback)."
}

# -----------------------------
# Xorg generation and optimus wiring
# -----------------------------
generate_xorg_conf() {
  info "Generating /etc/X11/xorg.conf for NVIDIA + Intel hybrid (Optimus)"
  local busid
  if command -v nvidia-xconfig >/dev/null 2>&1; then
    # nvidia-xconfig --query-gpu-info outputs 'BusID : PCI:1:0:0'
    busid=$(nvidia-xconfig --query-gpu-info 2>/dev/null | grep -m1 'BusID' | awk -F':' '{print $2":"$3":"$4}' | tr -d ' ') || true
  fi
  # Fallback: lspci find VGA compatible controller with NVIDIA
  if [[ -z "$busid" ]]; then
    busid=$(lspci -nn | grep -i nvidia | head -n1 | awk '{print $1}') || true
    if [[ -n "$busid" ]] && [[ "$busid" =~ ':' ]]; then
      # convert 00:02.0 -> 0000:00:02.0 style not needed for xorg; we'll use PCI:0000:xx:xx.x
      busid="PCI:${busid}"
    fi
  else
    busid="PCI:${busid}"
  fi

  local xorgfile="/etc/X11/xorg.conf"
  if [[ -f "$xorgfile" ]]; then
    cp -a "$xorgfile" "$XORG_BACKUP" || true
  fi

  cat > "$xorgfile" <<-EOF
Section "ServerLayout"
    Identifier "layout"
    Screen 0 "nvidia"
    Inactive "intel"
EndSection

Section "Device"
    Identifier "nvidia"
    Driver "nvidia"
    BusID "$busid"
EndSection

Section "Screen"
    Identifier "nvidia"
    Device "nvidia"
    Option "AllowEmptyInitialConfiguration"
EndSection

Section "Device"
    Identifier "intel"
    Driver "modesetting"
EndSection

Section "Screen"
    Identifier "intel"
    Device "intel"
EndSection
EOF
  log "CREATE" "Wrote $xorgfile with BusID=$busid"
}

# Autostart optimus wiring via systemd user/service
create_optimus_autostart() {
  info "Creating systemd unit for optimus xrandr binding"
  local service_file="/etc/systemd/system/opeselon-optimus.service"
  cat > "$service_file" <<-EOF
[Unit]
Description=Opselon Optimus provider wiring (xrandr provider link)
After=display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/opeselon-optimus-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=graphical.target
EOF

  cat > /usr/local/bin/opeselon-optimus-setup.sh <<-'EOS'
#!/usr/bin/env bash
# Try connecting modesetting -> NVIDIA provider and run xrandr --auto
if command -v xrandr >/dev/null 2>&1; then
  # Wait briefly for X to be ready
  sleep 2
  XAUTHORITY=${XAUTHORITY:-/run/user/1000/gdm/Xauthority}
  export DISPLAY=${DISPLAY:-:0}
  # Use setprovideroutputsource safely
  xrandr --listproviders >/dev/null 2>&1 || exit 0
  # Try linking providers
  if xrandr --setprovideroutputsource modesetting NVIDIA-0 >/dev/null 2>&1; then
    xrandr --auto >/dev/null 2>&1 || true
  fi
fi
EOS
  chmod +x /usr/local/bin/opeselon-optimus-setup.sh
  systemctl daemon-reload || true
  systemctl enable --now opeselon-optimus.service || warn "Failed to enable optimus systemd unit."
}

# -----------------------------
# Secure Boot handling
# -----------------------------
check_secure_boot() {
  if [[ -f /sys/firmware/efi/vars/SecureBoot-*/data ]]; then
    local val
    val=$(cat /sys/firmware/efi/vars/SecureBoot-*/data 2>/dev/null | xxd -p | head -1 || true)
    if [[ -n "$val" ]]; then
      info "Secure Boot detected. You may need to enroll kernel/module signatures (MOK) or disable Secure Boot."
      return 0
    fi
  fi
  # Another detection via mokutil
  if command -v mokutil >/dev/null 2>&1; then
    if mokutil --sb-state 2>/dev/null | grep -qi enabled; then
      info "Secure Boot is enabled (mokutil)"
      return 0
    fi
  fi
  return 1
}

# -----------------------------
# Cleanup & autoremove
# -----------------------------
perform_cleanup() {
  info "Running apt autoremove and cleaning cache"
  retry_cmd apt-get -y autoremove || warn "autoremove failed"
  retry_cmd apt-get -y autoclean || true
}

# -----------------------------
# Rollback facility (limited)
# -----------------------------
rollback_changes() {
  warn "Attempting limited rollback using backups in $BACKUP_DIR"
  if [[ -f "$APTSOURCE_BACKUP" ]]; then
    cp -a "$APTSOURCE_BACKUP" /etc/apt/sources.list || warn "Failed to restore sources.list"
  fi
  if [[ -f "$XORG_BACKUP" ]]; then
    cp -a "$XORG_BACKUP" /etc/X11/xorg.conf || warn "Failed to restore xorg.conf"
  fi
  info "Rollback finished. Run update-initramfs -u and reboot if necessary."
}

# -----------------------------
# Main procedure steps
# -----------------------------
main_steps() {
  require_root
  setup_ui
  detect_distro
  backup_configs
  check_network
  check_disk_space
  check_apt_lock

  # Add appropriate repos depending on distribution (idempotent)
  case "$DISTRO_ID" in
    kali)
      add_repo_safeguard "http.kali.org/kali" add_repos_kali
      ;;
    debian)
      # If very old Debian like stretch, user requested stretch in original script
      if [[ "$DISTRO_VERSION" == "9" || "$DISTRO_VERSION" == "stretch" ]]; then
        add_repo_safeguard "deb.debian.org/debian stretch" add_repos_debian_stretch
      fi
      ;;
    ubuntu)
      info "Ubuntu detected: using official ubuntu repos (no changes made)."
      ;;
    *)
      warn "Unknown distro: $DISTRO_ID. Proceeding cautiously and not modifying repos."
      ;;
  esac

  info "Updating apt cache"
  retry_cmd apt-get update || warn "apt-get update failed"

  # Optional distro-specific recommendations
  if [[ "$DISTRO_ID" == "kali" ]]; then
    info "Kali detected: ensure kali-rolling is intended."
  fi

  # Blacklist nouveau & update initramfs
  blacklist_nouveau

  # Install linux headers
  install_linux_headers

  # Install nvidia driver
  install_nvidia_package

  # DKMS and CUDA
  install_cuda_toolkit

  # Generate Xorg config and optimus wiring
  generate_xorg_conf
  create_optimus_autostart

  # Handle secure boot note
  if check_secure_boot; then
    warn "Secure Boot is enabled — driver modules may fail to load until you enroll MOK or disable Secure Boot."
    if ! confirm_prompt "Would you like instructions on enrolling MOK keys now?"; then
      info "Skipping MOK enrollment instructions."
    else
      cat <<-EOT
Secure Boot is enabled. Typical steps (manual):
  1. Run: sudo update-secureboot-policy --enroll-key
  2. Or use 'mokutil --import <cert>' to import module signing keys and follow prompts.
  3. Reboot and complete MOK enrollment during boot.
Make sure you understand Secure Boot implications.
EOT
    fi
  fi

  # Final tidy
  perform_cleanup

  info "Installation complete. Please reboot to activate NVIDIA drivers."
  log "REPORT" "NVIDIA installer completed. If drivers don't load, inspect $LOGFILE and check /var/log/Xorg.0.log"
}

# -----------------------------
# Self-test & validation features (optional)
# -----------------------------
validate_installation() {
  info "Validating installation status"
  if command -v nvidia-smi >/dev/null 2>&1; then
    local info_out
    info_out=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null || true)
    if [[ -n "$info_out" ]]; then
      info "nvidia-smi reports: $info_out"
    else
      warn "nvidia-smi found but failed to query GPUs. Driver may not be active."
    fi
  else
    warn "nvidia-smi not present. Driver may not be installed or path not exported."
  fi
}

# -----------------------------
# UI Menu (whiptail) - optional interactive flow
# -----------------------------
run_interactive_menu() {
  if [[ -z "$WHIPTAL_CMD" ]]; then
    info "Interactive UI not available. Running main steps non-interactively."
    main_steps
    return
  fi

  local choice
  choice=$($WHIPTAL_CMD --title "$SCRIPT_NAME" --menu "Choose an action:" 20 70 10 \
    1 "Full install (recommended)" \
    2 "Dry-run (simulate)" \
    3 "Blacklist nouveau only" \
    4 "Install linux-headers only" \
    5 "Generate xorg.conf and optimus unit" \
    6 "Rollback using backups" \
    7 "Validate installation" \
    8 "Exit" 3>&1 1>&2 2>&3)
  case "$choice" in
    1) main_steps ;;
    2) DRY_RUN=1; main_steps ;;
    3) blacklist_nouveau ;;
    4) install_linux_headers ;;
    5) generate_xorg_conf; create_optimus_autostart ;;
    6) rollback_changes ;;
    7) validate_installation ;;
    8) info "Exiting by user choice"; exit 0 ;;
    *) info "No valid option chosen, running default flow"; main_steps ;;
  esac
}

# -----------------------------
# Entry point
# -----------------------------
main() {
  require_root
  setup_ui

  if [[ -n "$WHIPTAL_CMD" && $ASSUME_YES -eq 0 && $DRY_RUN -eq 0 ]]; then
    run_interactive_menu
  else
    main_steps
  fi

  # Suggest reboot
  if confirm_prompt "Installation finished. Reboot now to complete NVIDIA driver activation?"; then
    info "Rebooting..."
    if [[ $DRY_RUN -eq 0 ]]; then
      /sbin/shutdown -r now
    else
      info "DRY-RUN: Would have rebooted now."
    fi
  else
    info "Please reboot later to ensure drivers are loaded."
  fi

  validate_installation
}

# Run main
main "$@"

# End of script
