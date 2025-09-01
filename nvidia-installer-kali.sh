
# --- Script Configuration and Constants -------------------------------------
set -o errexit
set -o nounset
set -o pipefail

readonly PROGNAME="$(basename "$0")"
readonly LOG_DIR="/var/log"
readonly LOG_FILE="${LOG_DIR}/kali-nvidia-installer-$(date +%Y%m%d-%H%M%S).log"
readonly MIN_DISK_SPACE_GB=5       # Minimum free space required for base install
readonly MIN_DISK_SPACE_CUDA_GB=20 # Minimum free space if CUDA is selected
readonly REQUIRED_REPO="kali-rolling"

ZENITY=$(command -v zenity || true)

# --- ASCII Art Banner --------------------------------------------------------
readonly BANNER="
    __   __   __    __     __  .__   __.  _______ .__   __. .___________. _______ .______
   |  | |  | |  |  |  |   |  | |  \\ |  | |   ____||  \\ |  | |           ||   ____||   _  \\
   |  | |  | |  |  |  |   |  | |   \\|  | |  |__   |   \\|  | \`---|  |----\`|  |__   |  |_)  |
.--.  | |  | |  |  |  |   |  | |  . \`  | |   __|  |  . \`  |     |  |     |   __|  |      /
|  \`--' | |  \`--'  |   |  \`--'  | |  |\\   | |  |____ |  |\\   |     |  |     |  |____ |  |\\  \\----.
 \______/   \\______/     \\______/  |__| \\__| |_______||__| \\__|     |__|     |_______|| _| \`._____|
        - K A L I   L I N U X   L E V I A T H A N   E D I T I O N -
"

# --- Core Helper Functions ----------------------------------------------------

# Centralized logging function.
log() {
    local msg="$*"
    echo "$(date --iso-8601=seconds) | ${PROGNAME}: ${msg}" | tee -a "$LOG_FILE"
}

# Centralized error handling and exit function.
err_exit() {
    local msg="$1"
    log "FATAL ERROR: $msg"
    [ -n "$ZENITY" ] && zenity --error --title="Installer Critical Error" --width=500 --text="A critical error occurred and the installer must exit:\n\n<b>$msg</b>\n\nPlease check the log file for exhaustive details:\n<b>$LOG_FILE</b>"
    exit 1
}

# Run a command, log it, and exit if it fails.
run_or_die() {
    log "EXEC: $*"
    if ! "$@" >>"$LOG_FILE" 2>&1; then
        err_exit "The command '$*' failed. Check the log file for details."
    fi
    log "SUCCESS: $*"
}

# Run a long-running command with a graphical progress bar.
run_with_progress() {
    local title="$1"
    shift
    log "EXEC (Progress): $*"
    # The subshell and pipe require checking PIPESTATUS to get the real exit code.
    ( "$@" 2>&1 | tee -a "$LOG_FILE" ) | zenity --progress --title="$title" --text="Running: $*...\n\n(This may take some time. See log for detailed output.)" --pulsate --auto-close --auto-kill --width=700
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        err_exit "The command '$*' failed during a progress operation. Check the log."
    fi
    log "SUCCESS: $*"
}

# Standardized function for Yes/No questions.
user_confirm() {
    local question_text="$1"
    local title="$2:- Confirmation"
    zenity --question --title="$title" --width=450 --text="$question_text"
}

# --- Pre-Flight System Analysis Suite -----------------------------------------

_check_root() {
    log "Verifying root privileges..."
    [ "$EUID" -eq 0 ] || err_exit "This script requires root privileges. Please run with sudo or as root."
}

_check_zenity() {
    log "Verifying Zenity is installed..."
    if [ -z "$ZENITY" ]; then
        log "Zenity not found. Attempting emergency installation via apt-get..."
        apt-get update -y
        apt-get install -y zenity || err_exit "Failed to auto-install Zenity. Please install it manually ('sudo apt install zenity') and re-run."
        ZENITY=$(command -v zenity)
        log "Zenity installed successfully."
    fi
}

_check_internet() {
    log "Verifying internet connectivity..."
    if ! ping -c 2 8.8.8.8 >/dev/null 2>&1; then
        err_exit "No internet connection detected. This installer needs to download packages."
    fi
}

_check_apt_lock() {
    log "Verifying APT is not locked..."
    if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
        err_exit "APT is locked by another process. Please close any other package managers (e.g., Synaptic, apt in another terminal) and try again."
    fi
}

_check_gpu_presence() {
    log "Scanning for NVIDIA GPU..."
    if ! lspci | grep -q -i 'vga.*nvidia'; then
        log "Warning: No NVIDIA GPU detected via lspci."
        user_confirm "No NVIDIA GPU was automatically detected.\n\nThis is highly unusual. Proceeding may not be useful.\n\nDo you want to continue anyway?" "Hardware Check" \
            || err_exit "Installation canceled by user. No NVIDIA GPU detected."
    fi
}

_check_secure_boot() {
    log "Checking Secure Boot status..."
    if mokutil --sb-state 2>/dev/null | grep -q enabled; then
        log "Warning: Secure Boot is enabled."
        zenity --warning --title="Security Warning: Secure Boot Enabled" --width=600 --text="<b>Secure Boot is ACTIVE on this system.</b>\n\nThe NVIDIA driver modules that this script builds (via DKMS) are <b>not cryptographically signed</b> by default. Therefore, they will be <b>BLOCKED</b> from loading by the kernel, and the driver will fail to start.\n\n<b>Your Options:</b>\n1. <b>(Recommended)</b> Exit now, reboot into your UEFI/BIOS, disable Secure Boot, and run this installer again.\n2. Proceed anyway if you are an advanced user who plans to sign the modules manually (MOK)."
        user_confirm "Do you understand the risks and wish to continue with Secure Boot enabled?" "Secure Boot Warning" \
            || err_exit "Installation canceled by user due to Secure Boot."
    fi
}

_check_virtual_machine() {
    log "Checking for virtualization environment..."
    local vm
    vm=$(systemd-detect-virt)
    if [ "$vm" != "none" ]; then
        log "Warning: Virtual machine environment '$vm' detected."
        user_confirm "This script has detected it is running inside a virtual machine (<b>$vm</b>).\n\nInstalling NVIDIA drivers in a VM is a complex topic that usually requires GPU Passthrough (IOMMU) to be configured correctly on the host.\n\nStandard installation will likely fail or have no effect. Do you want to proceed at your own risk?" "Virtualization Detected" \
            || err_exit "Installation canceled by user due to VM environment."
    fi
}

_check_disk_space() {
    log "Checking available disk space..."
    local free_space_kb
    free_space_kb=$(df / --output=avail | tail -n 1)
    local free_space_gb=$((free_space_kb / 1024 / 1024))
    if [ "$free_space_gb" -lt "$MIN_DISK_SPACE_GB" ]; then
        err_exit "Insufficient disk space. You have only ${free_space_gb}GB free, but at least ${MIN_DISK_SPACE_GB}GB is required."
    fi
    log "Disk space check passed (${free_space_gb}GB available)."
}

_check_kali_repo() {
    log "Checking for 'kali-rolling' repository..."
    if ! grep -q "^deb .*$REQUIRED_REPO" /etc/apt/sources.list /etc/apt/sources.list.d/*; then
        err_exit "The required '$REQUIRED_REPO' repository is not configured in your APT sources. This script is designed for Kali Rolling."
    fi
}

# Master function to run all pre-flight checks in sequence.
run_all_pre_flight_checks() {
    log "--- Starting Pre-Flight System Analysis Suite ---"
    (
        echo "0"; echo "# Initializing..."
        _check_root
        _check_zenity
        echo "10"; echo "# Checking Internet Connection..."
        _check_internet
        echo "20"; echo "# Checking APT Locks..."
        _check_apt_lock
        echo "35"; echo "# Scanning for NVIDIA Hardware..."
        _check_gpu_presence
        echo "50"; echo "# Checking Secure Boot Status..."
        _check_secure_boot
        echo "65"; echo "# Detecting Virtualization..."
        _check_virtual_machine
        echo "80"; echo "# Analyzing Disk Space..."
        _check_disk_space
        echo "90"; echo "# Verifying Kali Repository..."
        _check_kali_repo
        echo "100"; echo "# All checks passed."
        sleep 1
    ) | zenity --progress --title="System Pre-flight Analysis" --auto-close --width=600
    log "--- System Analysis Complete. All systems nominal. ---"
}

# --- "Philosopher's Guide" Installation Process -----------------------------

# Step 1: System Upgrade
step_1_system_upgrade() {
    zenity --info --title="Installation - Step 1/5" --width=600 --text="<b>Step 1: Full System Synchronization</b>\n\nThe most critical first step, as per official Kali documentation, is to ensure your system is completely up-to-date. This synchronizes your installed kernel with the available kernel headers, preventing build errors.\n\nThis involves two commands:\n1. <b>apt update</b> - Refreshes the list of available packages.\n2. <b>apt full-upgrade</b> - Upgrades all packages, handling dependencies intelligently.\n\nThis process can take a significant amount of time."
    run_with_progress "Updating package lists (apt update)..." apt-get update -y
    run_with_progress "Performing full system upgrade (apt full-upgrade)..." apt-get full-upgrade -y
}

# Step 2: Reboot Check
step_2_reboot_check() {
    if [ -f /var/run/reboot-required ]; then
        log "Reboot required after system upgrade."
        zenity --info --title="Installation - Action Required" --width=500 --text="The system upgrade has installed a new Linux kernel.\n\nA <b>reboot is now mandatory</b> to boot into this new kernel. The driver installation can only proceed once this is done.\n\nThe installer will now prompt you to reboot."
        if user_confirm "Click 'Yes' to reboot now.\nClick 'No' to cancel the entire installation." "Reboot Required"; then
            log "Rebooting system to load new kernel."
            reboot
            exit 0
        else
            err_exit "Reboot was declined. Cannot safely continue the installation."
        fi
    fi
    log "No reboot required after upgrade."
}

# Step 3: Install Kernel Headers
step_3_install_headers() {
    zenity --info --title="Installation - Step 2/5" --width=600 --text="<b>Step 2: Installing Kernel Headers</b>\n\nThe NVIDIA driver is not a simple application; it's a kernel module. To be loaded by the Linux kernel, it must be compiled specifically for the *exact* version of the kernel you are running.\n\nThis step installs the 'linux-headers' package, which provides the necessary source code and build tools (DKMS - Dynamic Kernel Module Support) to compile the NVIDIA module."
    local kernel_version
    kernel_version=$(uname -r)
    log "Target kernel version is $kernel_version."
    run_with_progress "Installing linux-headers-$kernel_version..." apt-get install -y "linux-headers-$kernel_version"
}

# Step 4: Install NVIDIA Drivers
step_4_install_drivers() {
    zenity --info --title="Installation - Step 3/5" --width=600 --text="<b>Step 3: Installing the NVIDIA Driver</b>\n\nNow we will install the core NVIDIA packages from the Kali repository.\n\n- <b>nvidia-driver:</b> The main proprietary driver.\n- <b>nvidia-kernel-dkms:</b> This will trigger the automatic compilation of the kernel module you need.\n\nDuring this step, the installer will also automatically create a file to blacklist the default open-source 'nouveau' driver, preventing conflicts."
    run_with_progress "Installing nvidia-driver and dkms module..." apt-get install -y nvidia-driver nvidia-kernel-dkms
}

# Step 5: Optional CUDA Installation
step_5_install_cuda_optional() {
    zenity --info --title="Installation - Step 4/5" --width=600 --text="<b>Step 4 (Optional): Install NVIDIA CUDA Toolkit</b>\n\nCUDA allows the GPU to be used for general-purpose computing, dramatically accelerating tasks like password cracking (Hashcat), machine learning, and scientific computing.\n\n<b>Warning:</b> The CUDA toolkit is a <b>very large</b> download (many gigabytes). Only install this if you specifically need it."
    if user_confirm "Do you want to install the NVIDIA CUDA Toolkit?" "Optional Installation"; then
        log "User chose to install CUDA."
        _check_disk_space_for_cuda
        run_with_progress "Installing CUDA Toolkit (nvidia-cuda-toolkit)..." apt-get install -y nvidia-cuda-toolkit
    else
        log "User skipped CUDA installation."
    fi
}

_check_disk_space_for_cuda() {
    log "Checking disk space for CUDA..."
    local free_space_kb
    free_space_kb=$(df / --output=avail | tail -n 1)
    local free_space_gb=$((free_space_kb / 1024 / 1024))
    if [ "$free_space_gb" -lt "$MIN_DISK_SPACE_CUDA_GB" ]; then
        err_exit "Insufficient disk space for CUDA. You have ${free_space_gb}GB free, but at least ${MIN_DISK_SPACE_CUDA_GB}GB is recommended."
    fi
    log "CUDA disk space check passed (${free_space_gb}GB available)."
}

# Step 6: Final Reboot
step_6_final_reboot_prompt() {
    log "Installation process has completed."
    zenity --info --title="Installation - Step 5/5" --width=500 --text="<b>Installation Complete!</b>\n\nThe NVIDIA driver and all related components have been successfully installed and compiled.\n\nA final reboot is required to unload the old 'nouveau' driver and load the new 'nvidia' driver into the kernel.\n\nAfter rebooting, you can run the 'Verify Installation' option from this script's main menu."
    if user_confirm "Click 'Yes' to reboot the system now.\nClick 'No' to reboot later manually." "Final Reboot"; then
        log "Rebooting to finalize installation."
        reboot
    fi
}

# Master installation orchestrator function
leviathan_install() {
    log "--- Initiating Leviathan Installation Process ---"
    if ! user_confirm "You are about to begin the fully automated NVIDIA driver installation. This will upgrade your entire system and install new drivers.\n\nIt is highly recommended to close all other applications.\n\nDo you wish to proceed?" "Confirm Installation"; then
        log "User aborted installation at confirmation."
        return
    fi

    run_all_pre_flight_checks
    step_1_system_upgrade
    step_2_reboot_check
    step_3_install_headers
    step_4_install_drivers
    step_5_install_cuda_optional
    step_6_final_reboot_prompt
    log "--- Leviathan Installation Process Finished ---"
}

# --- Deep Dive Verification Suite -------------------------------------------

comprehensive_verification() {
    log "--- Starting Deep Dive Verification Suite ---"
    local report="<b>Leviathan Installation Verification Report:</b>\n\n"
    local all_ok=true

    # 1. DKMS Status
    log "Verifying DKMS status..."
    if dkms status 2>/dev/null | grep -q 'nvidia.*installed'; then
        report+="✅ <b>DKMS Module:</b> OK\n   - The 'nvidia' module is successfully built and installed via DKMS.\n\n"
    else
        report+="❌ <b>DKMS Module:</b> FAILED\n   - The 'nvidia' module was NOT found or failed to build in DKMS. This is a critical error.\n\n"
        all_ok=false
    fi

    # 2. Kernel Module Loaded
    log "Verifying kernel module is loaded..."
    if lsmod | grep -q '^nvidia '; then
        report+="✅ <b>Kernel Driver:</b> OK\n   - The 'nvidia' kernel module is currently loaded and active.\n\n"
    else
        report+="❌ <b>Kernel Driver:</b> FAILED\n   - The 'nvidia' module is NOT loaded. This could be due to Secure Boot or a build error. Check 'dmesg' for errors.\n\n"
        all_ok=false
    fi

    # 3. NVIDIA SMI Tool
    log "Verifying nvidia-smi functionality..."
    if command -v nvidia-smi &>/dev/null && smi_output=$(nvidia-smi 2>&1); then
        report+="✅ <b>NVIDIA System Management Interface (nvidia-smi):</b> OK\n   - The command is working and communicating with the driver.\n\n<tt>$smi_output</tt>\n\n"
    else
        report+="❌ <b>NVIDIA System Management Interface (nvidia-smi):</b> FAILED\n   - The 'nvidia-smi' command failed to execute. This indicates a severe driver loading issue.\n\n"
        all_ok=false
    fi

    # 4. OpenGL Rendering
    log "Verifying OpenGL rendering..."
    if ! command -v glxinfo &>/dev/null; then
        if user_confirm "'glxinfo' command not found. This tool is needed to verify OpenGL acceleration. It's part of the 'mesa-utils' package.\n\nInstall it now?" "Missing Tool"; then
            run_with_progress "Installing mesa-utils..." apt-get install -y mesa-utils
        fi
    fi
    if command -v glxinfo &>/dev/null; then
        if glxinfo -B | grep -q "OpenGL renderer string.*NVIDIA"; then
            report+="✅ <b>OpenGL Acceleration:</b> OK\n   - The system is correctly using the NVIDIA GPU for OpenGL rendering.\n\n"
        else
            report+="❌ <b>OpenGL Acceleration:</b> FAILED\n   - The system is NOT using the NVIDIA GPU for OpenGL. It may be falling back to software rendering.\n\n"
            all_ok=false
        fi
    else
        report+="⚠️ <b>OpenGL Acceleration:</b> UNKNOWN\n   - Could not perform check because 'glxinfo' is not available.\n\n"
    fi


    if [ "$all_ok" = true ]; then
        zenity --info --title="Verification Passed" --width=800 --height=600 --text="<span size='large'><b>All checks passed. Your NVIDIA driver appears to be fully operational.</b></span>\n\n$report"
    else
        zenity --error --title="Verification Failed" --width=800 --height=600 --text="<span size='large' color='red'><b>One or more verification checks failed!</b></span>\n\n$report\n\nPlease review the errors above and consult the log file for detailed troubleshooting information:\n<b>$LOG_FILE</b>"
    fi
}

# --- Uninstallation and About Dialogs ---------------------------------------

uninstall_nvidia() {
    if ! user_confirm "This will completely <b>PURGE</b> all NVIDIA packages from your system and attempt to restore the default 'nouveau' driver.\n\nAre you absolutely sure you want to proceed?" "Confirm Uninstallation"; then
        log "Uninstall canceled by user."
        return
    fi
    log "--- Starting Full NVIDIA Driver Purge ---"
    run_with_progress "Purging all nvidia-* packages..." apt-get remove --purge -y '~nnvidia-.*'
    run_with_progress "Cleaning up orphaned dependencies..." apt-get autoremove -y
    log "Removing leftover configuration files."
    run_or_die rm -f /etc/modprobe.d/nvidia-installer-disable-nouveau.conf
    run_with_progress "Updating initramfs to restore nouveau..." update-initramfs -u

    zenity --info --title="Uninstall Complete" --text="All NVIDIA components have been purged.\nA reboot is now required to load the default video driver."
    if user_confirm "Reboot now?" "Reboot Required"; then
        reboot
    fi
}

show_about_dialog() {
    zenity --info --title="About This Installer" --width=700 --text="<b>Kali NVIDIA Installer - Leviathan Edition</b>\n\nThis script provides an extremely robust, safe, and guided process for installing NVIDIA's proprietary drivers on Kali Linux, following official best practices.\n\n<b>Key Features:</b>\n- <b>Exhaustive Pre-Flight Analysis:</b> Checks everything from disk space and Secure Boot to virtualization before starting.\n- <b>Philosopher's Guide:</b> Explains every step of the installation process with detailed dialogs.\n- <b>Deep Dive Verification:</b> A multi-point check to ensure the driver is not just installed, but fully functional.\n- <b>Error Resilience:</b> Fails gracefully with clear error messages if any step goes wrong.\n- <b>Comprehensive Logging:</b> Every action is recorded in <b>$LOG_FILE</b>."
}

# --- Main Menu and Script Entrypoint -----------------------------------------

main_menu() {
    echo "$BANNER" # Also print banner to terminal
    local choice
    choice=$(zenity --list --title="Kali NVIDIA Installer - Leviathan Edition" --text="$BANNER\nWelcome. Please select an action." --height=500 --width=800 \
        --column="Action" --column="Description" \
        "Start Leviathan Installation" "The fully automated, guided process to install, update, and configure the drivers." \
        "Deep Dive Verification Suite" "Run a comprehensive check to see if your drivers are installed and working correctly." \
        "Purge All NVIDIA Drivers" "Completely uninstall all NVIDIA components and return to the default driver." \
        "View Log File" "Open the detailed log file for the current session for troubleshooting." \
        "About This Installer" "Information about the features and purpose of this script." \
        "Exit" "Close the application.")

    case "$choice" in
        "Start Leviathan Installation") leviathan_install ;;
        "Deep Dive Verification Suite") comprehensive_verification ;;
        "Purge All NVIDIA Drivers") uninstall_nvidia ;;
        "View Log File")
            xdg-open "$LOG_FILE" 2>/dev/null || zenity --text-info --filename="$LOG_FILE" --title="Log File" --width=900 --height=700
            ;;
        "About This Installer") show_about_dialog ;;
        *)
            log "User selected exit or closed the dialog. Shutting down."
            exit 0
            ;;
    esac
}

# --- Script Entrypoint ---
# Initialize log file
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
log "--- Kali NVIDIA Leviathan Installer session started ---"

# Ensure core dependencies are met before showing the main menu for the first time
_check_root
_check_zenity

# Main application loop
while true; do
    main_menu
done