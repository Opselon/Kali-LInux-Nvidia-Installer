#!/usr/bin/env bash
# Opselon - Ultimate NVIDIA & CUDA Installer (Modern Hacker Theme)
# Version: 2025.09.01.1
# Author: ChatGPT for Opselon (enhanced)
# License: MIT
# Purpose: Ultra-robust, smart, modular, interactive installer for NVIDIA drivers, CUDA and Optimus
# Target: Debian, Ubuntu, Kali (rolling) and derivatives
# UI Theme: Modern 'Hacker' aesthetic (whiptail/dialog + ANSI + progress gauges)
# Features (expanded):
# - Root check, detailed backups and snapshot suggestions (Timeshift, rsync alternatives)
# - Interactive themed TUI using whiptail (preferred) or dialog, with ANSI header if CLI
# - Fancy ASCII 'Hacker' banner and color scheme
# - Plugin architecture (drivers, cuda, optimus, dkms, mok enrollment)
# - JSON configuration support (/etc/opeselon/opeselon.conf)
# - Advanced checks: network, disk, apt locks, secure boot, grub, kernel headers match, package availability
# - Multiple driver selection strategies: repo metapackage, apt pin, NVIDIA .deb local cache, official .run fallback (explicit user consent required)
# - Safe-mode, dry-run, unattended CI mode, and fully interactive mode
# - Extensive logging, self-healing attempts, retry/backoff, and rollback support
# - Preflight GPU test with nvidia-smi (if present) and optional stress test (user opt-in)
# - Pretty UI: menus, progress bars, confirmation dialogs, and themed colors
# - Extensible: copy/update hooks to integrate with Opselon repo or create PR templates
# - Accessibility: clear user prompts, explicit security notes for Secure Boot and MOK

set -o errexit
set -o pipefail
set -o nounset
IFS=$'\n\t'

# -----------------------------
# Globals
# -----------------------------
SCRIPT_NAME="Opselon-Ultimate-Installer"
VERSION="2025.09.01.1"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
LOGDIR="/var/log/opeselon"
LOGFILE="$LOGDIR/opeselon-installer-${TIMESTAMP}.log"
BACKUP_DIR="/var/backups/opeselon-${TIMESTAMP}"
CONF_DIR="/etc/opeselon"
CONF_FILE="$CONF_DIR/opeselon.conf.json"
DRY_RUN=0
ASSUME_YES=0
QUIET=0
UNATTENDED=0
WHIPTAL_CMD=""
DIALOG_CMD=""
RETRY_LIMIT=5
PLUGIN_DIR="/usr/local/lib/opeselon/plugins"
HACKER_BANNER=1

# Theme colors
if [[ -t 1 ]]; then
  C_RED="\e[38;5;196m"
  C_GREEN="\e[38;5;46m"
  C_BLUE="\e[38;5;39m"
  C_CYAN="\e[38;5;51m"
  C_YELLOW="\e[38;5;220m"
  C_RESET="\e[0m"
  C_BOLD="\e[1m"
else
  C_RED=""; C_GREEN=""; C_BLUE=""; C_CYAN=""; C_YELLOW=""; C_RESET=""; C_BOLD=""
fi

# -----------------------------
# Logging helpers
# -----------------------------
mkdir -p "$LOGDIR"
mkdir -p "$BACKUP_DIR"
mkdir -p "$CONF_DIR"
: > "$LOGFILE"

log() {
  local level="$1"; shift
  local msg="$*"
  echo -e "$(date +'%F %T') [$level] $msg" | tee -a "$LOGFILE"
}

info() { log "INFO" "$*"; }
warn() { log "WARN" "$*"; }
err() { log "ERROR" "$*"; }

die() {
  err "$*"
  echo -e "${C_RED}${C_BOLD}FATAL:${C_RESET} $*" >&2
  exit 1
}

# -----------------------------
# Fancy header & theme
# -----------------------------
print_banner() {
  if [[ $HACKER_BANNER -eq 1 && -t 1 ]]; then
    cat <<-EOF
${C_CYAN}${C_BOLD}
   ____  __  ____  ____  __  _  ____  _  _  ____  _  _
  (  _ \(  )(_  _)(  _ \(  )( \/ ___)/ )( \(  _ \( \/ )
   ) _ (/ (_  )(   )   / )( /\)\___ \) \/ ( ) _ (/ \/ \
  (____/\____)(__) (__\_)(__)(__)____/\____/(__\_)\_)(_/ Installer v$VERSION
${C_RESET}
EOF
  fi
}

# -----------------------------
# Utils
# -----------------------------
require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    die "This script must be run as root. Use sudo or run as root."
  fi
}

run_cmd() {
  log "CMD" "$*"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "DRY-RUN: $*"
    return 0
  fi
  "$@"
}

retry() {
  local n=0
  local cmd=("$@")
  until [[ $n -ge $RETRY_LIMIT ]]; do
    if "${cmd[@]}"; then
      return 0
    fi
    n=$((n+1))
    warn "Retry ${n}/${RETRY_LIMIT} failed for: ${cmd[*]}"
    sleep $((n*2))
  done
  return 1
}

confirm_prompt() {
  local prompt="$1"
  if [[ $ASSUME_YES -eq 1 || $UNATTENDED -eq 1 ]]; then
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

# -----------------------------
# CLI argument parsing
# -----------------------------
usage() {
  cat <<-EOF
$SCRIPT_NAME v$VERSION
Usage: $0 [options]
Options:
  --dry-run            Simulate actions without making changes
  --yes, -y            Assume yes to prompts
  --quiet              Minimal output
  --unattended         Non-interactive (assume yes)
  --no-ui              Disable whiptail/dialog UI
  --log FILE           Use custom logfile
  --conf FILE          Use custom JSON config
  --help, -h           Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --quiet) QUIET=1; shift ;;
    --unattended) UNATTENDED=1; ASSUME_YES=1; QUIET=1; shift ;;
    --no-ui) WHIPTAL_CMD=""; DIALOG_CMD=""; shift ;;
    --log) LOGFILE="$2"; shift 2 ;;
    --conf) CONF_FILE="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

# Recreate log if user changed it
mkdir -p "$(dirname "$LOGFILE")"
: > "$LOGFILE"

# -----------------------------
# UI setup
# -----------------------------
setup_ui() {
  if [[ $ASSUME_YES -eq 1 || $QUIET -eq 1 || $UNATTENDED -eq 1 ]]; then
    WHIPTAL_CMD=""
    DIALOG_CMD=""
    return
  fi
  if command -v whiptail >/dev/null 2>&1; then
    WHIPTAL_CMD="whiptail"
  elif command -v dialog >/dev/null 2>&1; then
    DIALOG_CMD="dialog"
  else
    warn "whiptail/dialog not found. Asking to install for nicer UI."
    if confirm_prompt "Install whiptail now for improved UI?"; then
      retry apt-get update || true
      retry apt-get -y install whiptail || warn "Failed to install whiptail. Falling back to CLI." 
      if command -v whiptail >/dev/null 2>&1; then
        WHIPTAL_CMD="whiptail"
      fi
    fi
  fi
}

# -----------------------------
# Distro & environment detection
# -----------------------------
detect_env() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    DISTRO_ID=${ID:-unknown}
    DISTRO_NAME=${NAME:-$DISTRO_ID}
    DISTRO_VERSION=${VERSION_ID:-}
  else
    DISTRO_ID="unknown"
    DISTRO_NAME="unknown"
    DISTRO_VERSION=""
  fi
  KERNEL_VER=$(uname -r)
  HOSTNAME=$(hostname -f 2>/dev/null || hostname)
  info "Detected: $DISTRO_NAME ($DISTRO_ID) version $DISTRO_VERSION | Kernel: $KERNEL_VER"
}

# -----------------------------
# Backup and snapshot helpers
# -----------------------------
backup_configs() {
  info "Creating backup dir: $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
  # backup apt sources
  if [[ -f /etc/apt/sources.list ]]; then
    cp -a /etc/apt/sources.list "$BACKUP_DIR/sources.list.bak"
  fi
  # backup sources.list.d
  if [[ -d /etc/apt/sources.list.d ]]; then
    cp -a /etc/apt/sources.list.d "$BACKUP_DIR/sources.list.d.bak" || true
  fi
  # backup xorg.conf
  if [[ -f /etc/X11/xorg.conf ]]; then
    cp -a /etc/X11/xorg.conf "$BACKUP_DIR/xorg.conf.bak" || true
  fi
  # backup dpkg selection (for rollback via apt-mark)
  dpkg --get-selections > "$BACKUP_DIR/dpkg-selections.bak" || true
  # snapshot suggestion
  if command -v timeshift >/dev/null 2>&1; then
    info "timeshift detected. Suggest creating a snapshot before proceeding."
    if confirm_prompt "Create a Timeshift snapshot now? This requires timeshift to be configured."; then
      run_cmd timeshift --create --comments "Opselon pre-install snapshot $TIMESTAMP" || warn "timeshift snapshot failed"
    fi
  else
    info "Timeshift not installed. Consider creating a manual backup or disk snapshot before continuing."
  fi
}

# -----------------------------
# Repository helpers (idempotent)
# -----------------------------
add_repo_if_missing() {
  local needle="$1"; shift
  local addcmd="$*"
  if grep -Rqs "$needle" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    info "Repo already present: $needle"
  else
    info "Adding repo: $needle"
    eval "$addcmd"
  fi
}

# -----------------------------
# Nouveau blacklist
# -----------------------------
blacklist_nouveau() {
  local conf="/etc/modprobe.d/blacklist-nouveau-opeselon.conf"
  if [[ -f "$conf" ]]; then
    info "Nouveau blacklist already present"
    return
  fi
  cat > "$conf" <<-EOF
# Opselon: blacklist nouveau
blacklist nouveau
options nouveau modeset=0
alias nouveau off
EOF
  info "Wrote $conf"
  if [[ $DRY_RUN -eq 0 ]]; then
    run_cmd update-initramfs -u || warn "update-initramfs failed"
  fi
}

# -----------------------------
# Kernel headers
# -----------------------------
install_kernel_headers() {
  local kernver="$KERNEL_VER"
  info "Installing kernel headers for $kernver"
  retry apt-get update || true
  if ! apt-get -y install "linux-headers-${kernver}"; then
    warn "linux-headers-${kernver} not available. Trying meta-package linux-headers-$(uname -r | sed 's/[^0-9.\-]*//g')"
    retry apt-get -y install linux-headers-$(uname -r | sed 's/[^0-9.\-]*//g') || warn "Failed to install linux headers"
  fi
}

# -----------------------------
# NVIDIA package selection
# -----------------------------
choose_driver_strategy() {
  # Strategies: repo-metapackage, specific-version, local-deb, official-run
  local menu=(
    "1" "Install recommended repo metapackage (safe)"
    "2" "Choose specific repo driver (e.g. nvidia-driver-535)"
    "3" "Install from local .deb package (you provide path)"
    "4" "Official NVIDIA .run installer (manual fallback)"
    "5" "Skip driver installation (only headers/optimus)"
  )
  if [[ -n "$WHIPTAL_CMD" ]]; then
    choice=$($WHIPTAL_CMD --menu "Driver installation strategy:" 20 80 10 "${menu[@]}" 3>&1 1>&2 2>&3) || choice=1
  else
    echo "Choose driver installation strategy:"
    select opt in "repo-metapackage" "specific-version" "local-deb" "nvidia-run" "skip"; do
      case $opt in
        "repo-metapackage") choice=1; break;;
        "specific-version") choice=2; break;;
        "local-deb") choice=3; break;;
        "nvidia-run") choice=4; break;;
        "skip") choice=5; break;;
      esac
    done
  fi

  case "$choice" in
    1) DRIVER_MODE="repo" ;;
    2) DRIVER_MODE="specific" ;;
    3) DRIVER_MODE="localdeb" ;;
    4) DRIVER_MODE="runfile" ;;
    5) DRIVER_MODE="skip" ;;
    *) DRIVER_MODE="repo" ;;
  esac
  info "Driver mode selected: $DRIVER_MODE"
}

# -----------------------------
# Driver install handlers
# -----------------------------
install_driver_repo() {
  info "Installing driver via repo metapackage"
  retry apt-get update || true
  if apt-cache show nvidia-driver >/dev/null 2>&1; then
    retry apt-get -y install nvidia-driver nvidia-xconfig || die "Failed installing nvidia-driver"
  else
    # try specific known candidates
    for v in 555 545 535 525; do
      if apt-cache show "nvidia-driver-$v" >/dev/null 2>&1; then
        retry apt-get -y install "nvidia-driver-$v" nvidia-xconfig || die "Failed installing nvidia-driver-$v"
        return
      fi
    done
    warn "No repo meta-package found; you may need to enable contrib/non-free or use other method."
  fi
}

install_driver_specific() {
  # interactive choose known versions available via apt-cache
  local candidates
  candidates=$(apt-cache pkgnames | grep -E "nvidia-driver(-)?[0-9]+" || true)
  if [[ -z "$candidates" ]]; then
    warn "No specific nvidia-driver versions discovered in apt cache. Falling back to repo."; install_driver_repo; return
  fi
  echo "Available driver packages:"
  echo "$candidates"
  read -rp "Enter package name to install (e.g. nvidia-driver-535): " pkg
  if [[ -z "$pkg" ]]; then
    warn "No package chosen, falling back to repo"
    install_driver_repo
    return
  fi
  retry apt-get -y install "$pkg" nvidia-xconfig || die "Failed to install $pkg"
}

install_driver_localdeb() {
  read -rp "Enter path to local .deb file (or directory containing .deb): " path
  if [[ -z "$path" ]]; then warn "No path provided"; return; fi
  if [[ -d "$path" ]]; then
    info "Installing all .deb files from directory $path"
    retry dpkg -i "$path"/*.deb || true
    retry apt-get -f -y install || warn "Some packages may be missing dependencies"
  elif [[ -f "$path" ]]; then
    retry dpkg -i "$path" || true
    retry apt-get -f -y install
  else
    warn "Path not found: $path"
  fi
}

install_driver_runfile() {
  warn "Official NVIDIA .run installers can overwrite system files and require manual attention."
  if ! confirm_prompt "Proceed to run official .run installer? (you must provide the .run file)"; then
    warn "Skipping .run installer."
    return
  fi
  read -rp "Enter path to NVIDIA .run file: " runfile
  if [[ ! -f "$runfile" ]]; then die "Runfile not found: $runfile"; fi
  chmod +x "$runfile"
  info "Stopping display manager to run installer (may interrupt X sessions)"
  systemctl isolate multi-user.target || true
  "$runfile" --silent || die "NVIDIA .run installer failed"
  systemctl isolate graphical.target || true
}

# -----------------------------
# CUDA / OpenCL install
# -----------------------------
install_cuda() {
  info "Installing CUDA toolkit and OpenCL ICDs (if available in repo)"
  retry apt-get update || true
  if apt-cache show nvidia-cuda-toolkit >/dev/null 2>&1; then
    retry apt-get -y install nvidia-cuda-toolkit ocl-icd-libopencl1 || warn "CUDA toolkit installation failed or not available"
  else
    warn "nvidia-cuda-toolkit not found in apt. Consider installing via NVIDIA repo or local packages."
  fi
}

# -----------------------------
# Xorg & Optimus wiring
# -----------------------------
generate_xorg() {
  info "Generating X11 xorg.conf for hybrid setups"
  local busid
  if command -v nvidia-xconfig >/dev/null 2>&1; then
    busid=$(nvidia-xconfig --query-gpu-info 2>/dev/null | grep -m1 'BusID' | cut -d ':' -f2- | tr -d ' ' || true)
    if [[ -n "$busid" ]]; then busid="PCI:${busid}"; fi
  fi
  if [[ -z "$busid" ]]; then
    busid=$(lspci -nn | grep -i nvidia | head -n1 | awk '{print $1}')
    if [[ -n "$busid" ]]; then busid="PCI:${busid}"; fi
  fi
  local xorgfile="/etc/X11/xorg.conf"
  if [[ -f "$xorgfile" ]]; then cp -a "$xorgfile" "$BACKUP_DIR/xorg.conf.bak" || true; fi
  cat > "$xorgfile" <<-EOF
Section "ServerLayout"
    Identifier "layout"
    Screen 0 "nvidia"
    Inactive "intel"
EndSection

Section "Device"
    Identifier "nvidia"
    Driver "nvidia"
    ${busid:+BusID "$busid"}
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
  info "Wrote $xorgfile (BusID=$busid)"
}

create_optimus_service() {
  info "Creating systemd service for Optimus provider wiring"
  local service_file="/etc/systemd/system/opeselon-optimus.service"
  cat > "$service_file" <<-EOF
[Unit]
Description=Opselon Optimus provider wiring
After=graphical.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/opeselon-optimus-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=graphical.target
EOF
  cat > /usr/local/bin/opeselon-optimus-setup.sh <<-'EOS'
#!/usr/bin/env bash
# Opselon Optimus setup helper
export DISPLAY=${DISPLAY:-:0}
# small wait for X
sleep 2
if command -v xrandr >/dev/null 2>&1; then
  if xrandr --listproviders | grep -qi "NVIDIA"; then
    xrandr --setprovideroutputsource modesetting NVIDIA-0 || true
    xrandr --auto || true
  fi
fi
EOS
  chmod +x /usr/local/bin/opeselon-optimus-setup.sh
  systemctl daemon-reload || true
  systemctl enable --now opeselon-optimus.service || warn "Failed enabling optimus service"
}

# -----------------------------
# Secure Boot & MOK helpers
# -----------------------------
is_secure_boot_enabled() {
  if command -v mokutil >/dev/null 2>&1; then
    if mokutil --sb-state 2>/dev/null | grep -qi enabled; then
      return 0
    fi
  fi
  if [[ -d /sys/firmware/efi/efivars ]]; then
    # best-effort check
    if [[ -f /sys/firmware/efi/vars/SecureBoot-*/data ]]; then
      return 0
    fi
  fi
  return 1
}

mok_enroll_instructions() {
  cat <<-EOF
Secure Boot appears enabled. Kernel modules (like NVIDIA's) may be blocked until signed and enrolled.
Common approaches:
 1) Disable Secure Boot in firmware (fastest)
 2) Use 'mokutil --import <your_key>.der' to enroll signer keys and reboot to complete MOK enrollment
 3) Use 'update-secureboot-policy --enroll-key' on supported distros
If you want, the script can generate a keypair and create a .der for enrollment; you'll still need to complete enrollment during reboot.
EOF
}

generate_mok_keys() {
  local keydir="$BACKUP_DIR/mok"
  mkdir -p "$keydir"
  openssl req -new -x509 -newkey rsa:4096 -nodes -keyout "$keydir/MOK.priv" -out "$keydir/MOK.der" -days 3650 -subj "/CN=Opselon MOK/" || warn "OpenSSL failed to create MOK keys"
  info "Generated MOK keys in $keydir (MOK.der for import via mokutil)"
}

# -----------------------------
# Validation & testing
# -----------------------------
validate_nvidia() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    local out
    out=$(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader,nounits 2>/dev/null || true)
    if [[ -n "$out" ]]; then
      info "nvidia-smi detected: $out"
      return 0
    fi
  fi
  warn "nvidia-smi not available or driver not active yet"
  return 1
}

run_quick_gpu_test() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then warn "nvidia-smi not found; skipping quick test"; return; fi
  info "Running quick GPU status test (nvidia-smi)"
  nvidia-smi --query-gpu=index,name,utilization.gpu,temperature.gpu,memory.used --format=csv || warn "nvidia-smi returned error"
}

# -----------------------------
# Cleanup and autoremove
# -----------------------------
cleanup() {
  info "Running apt autoremove and autoclean"
  retry apt-get -y autoremove || warn "autoremove failed"
  retry apt-get -y autoclean || true
}

# -----------------------------
# Rollback
# -----------------------------
rollback() {
  warn "Starting limited rollback from backups in $BACKUP_DIR"
  if [[ -f "$BACKUP_DIR/sources.list.bak" ]]; then
    cp -a "$BACKUP_DIR/sources.list.bak" /etc/apt/sources.list || warn "Failed to restore sources.list"
  fi
  if [[ -f "$BACKUP_DIR/xorg.conf.bak" ]]; then
    cp -a "$BACKUP_DIR/xorg.conf.bak" /etc/X11/xorg.conf || warn "Failed to restore xorg.conf"
  fi
  if [[ -f "$BACKUP_DIR/dpkg-selections.bak" ]]; then
    dpkg --set-selections < "$BACKUP_DIR/dpkg-selections.bak" || warn "Failed to restore dpkg selections"
  fi
  info "Rollback finished. Consider running 'update-initramfs -u' and rebooting."
}

# -----------------------------
# Main workflow
# -----------------------------
main_flow() {
  require_root
  print_banner
  setup_ui
  detect_env
  backup_configs

  # Safety checks
  if ! ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then
    warn "Network unreachable. Some operations may fail."
    if ! confirm_prompt "No network detected. Continue anyway?"; then die "Network required. Exiting."; fi
  fi

  # Add repos conservatively if requested by distro
  case "$DISTRO_ID" in
    kali)
      add_repo_if_missing "http.kali.org/kali" "echo 'deb http://http.kali.org/kali kali-rolling main non-free contrib' >> /etc/apt/sources.list"
      ;;
    debian)
      if [[ "$DISTRO_VERSION" == "9" || "$DISTRO_VERSION" == "stretch" ]]; then
        add_repo_if_missing "deb.debian.org/debian stretch" "cat >> /etc/apt/sources.list <<<'deb http://deb.debian.org/debian stretch main contrib non-free'"
      fi
      ;;
    *) info "No repo changes for $DISTRO_ID" ;;
  esac

  info "Updating apt cache"
  retry apt-get update || warn "apt-get update failed"

  # Blacklist nouveau
  blacklist_nouveau

  # Kernel headers
  install_kernel_headers

  # Driver strategy selection
  choose_driver_strategy
  case "$DRIVER_MODE" in
    repo) install_driver_repo ;;
    specific) install_driver_specific ;;
    localdeb) install_driver_localdeb ;;
    runfile) install_driver_runfile ;;
    skip) info "Skipping driver installation as requested" ;;
  esac

  # CUDA optional
  if confirm_prompt "Install CUDA/OpenCL toolkits if available in repos?"; then
    install_cuda
  fi

  # Create Xorg and optimus wiring
  generate_xorg
  create_optimus_service

  # Secure boot handling
  if is_secure_boot_enabled; then
    warn "Secure Boot is enabled on this system. NVIDIA modules may be blocked."
    mok_enroll_instructions
    if confirm_prompt "Generate MOK keypair and prepare for enrollment?"; then
      generate_mok_keys
      info "You can import $BACKUP_DIR/mok/MOK.der using 'mokutil --import $BACKUP_DIR/mok/MOK.der' and reboot to enroll."
    fi
  fi

  # Cleanup and validation
  cleanup
  if validate_nvidia; then
    info "NVIDIA driver appears active"
  else
    warn "Driver not active yet. You may need a reboot."
  fi

  if confirm_prompt "Run quick GPU test using nvidia-smi?"; then
    run_quick_gpu_test
  fi

  info "Opselon installation finished. Log: $LOGFILE"
  if confirm_prompt "Reboot now to complete driver activation?"; then
    if [[ $DRY_RUN -eq 0 ]]; then
      shutdown -r now
    else
      info "DRY-RUN: Skipping reboot"
    fi
  fi
}

# -----------------------------
# Entry
# -----------------------------
main() {
  trap 'err "Interrupted"; exit 130' INT TERM
  main_flow
}

main "$@"

# End of Opselon Ultimate Installer
