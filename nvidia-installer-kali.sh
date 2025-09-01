#!/usr/bin/env bash
#
# kali-nvidia-installer-gargantuan.sh
#
# An exceptionally detailed, robust, and user-centric GUI-driven NVIDIA Driver Installation Suite for Kali Linux.
# This "Gargantuan Edition" provides a "Philosopher's Guide" approach, explaining every step in exhaustive
# detail, performing a vast array of pre-flight system analysis checks, and verifying the installation
# with a deep-dive diagnostic suite. It is designed for maximum clarity, safety, and user control.
#
# License: MIT
#

# --- Script Configuration and Constants -------------------------------------
# These settings control the script's behavior.
# set -o errexit: Exit immediately if a command exits with a non-zero status.
# set -o nounset: Treat unset variables as an error when substituting.
# set -o pipefail: The return value of a pipeline is the status of the last command to exit with a non-zero status.
set -o errexit
set -o nounset
set -o pipefail

# --- Read-Only Global Variables ---
readonly PROGNAME="$(basename "$0")"
readonly LOG_DIR="/var/log"
readonly LOG_FILE="${LOG_DIR}/kali-nvidia-installer-$(date +%Y%m%d-%H%M%S).log"
readonly MIN_DISK_SPACE_GB=5       # Minimum free space in GB required for a base driver installation.
readonly MIN_DISK_SPACE_CUDA_GB=20 # Minimum free space in GB required if the CUDA toolkit is also selected.
readonly REQUIRED_REPO="kali-rolling" # The script is designed for and verifies the presence of this repository.

# --- ANSI Color Codes for Enhanced Terminal Output ---
readonly COLOR_RESET="\033[0m"
readonly COLOR_RED="\033[0;31m"
readonly COLOR_GREEN="\033[0;32m"
readonly COLOR_YELLOW="\033[0;33m"
readonly COLOR_BLUE="\033[0;34m"
readonly COLOR_CYAN="\033[0;36m"
readonly COLOR_BOLD="\033[1m"

# --- Global Mutable Variables ---
# The path to the Zenity executable will be stored here.
ZENITY=$(command -v zenity || true)

# --- ASCII Art Banner --------------------------------------------------------
readonly BANNER="
    __   __   __    __     __  .__   __.  _______ .__   __. .___________. _______ .______
   |  | |  | |  |  |  |   |  | |  \\ |  | |   ____||  \\ |  | |           ||   ____||   _  \\
   |  | |  | |  |  |  |   |  | |   \\|  | |  |__   |   \\|  | \`---|  |----\`|  |__   |  |_)  |
.--.  | |  | |  |  |  |   |  | |  . \`  | |   __|  |  . \`  |     |  |     |   __|  |      /
|  \`--' | |  \`--'  |   |  \`--'  | |  |\\   | |  |____ |  |\\   |     |  |     |  |____ |  |\\  \\----.
 \______/   \\______/     \\______/  |__| \\__| |_______||__| \\__|     |__|     |_______|| _| \`._____|
        - K A L I   L I N U X   G A R G A N T U A N   E D I T I O N -
"

# --- Core Helper Functions ----------------------------------------------------

# Centralized logging function with terminal colorization.
# All script output, whether informational, an error, or a success message, should pass through here.
log() {
    local msg="$*"
    local timestamp
    timestamp=$(date --iso-8601=seconds)
    local log_prefix_file="${timestamp} | ${PROGNAME}: " # Prefix for the log file (plain text)
    local log_prefix_term="${timestamp} | ${COLOR_BOLD}${PROGNAME}:${COLOR_RESET} " # Prefix for terminal (with color)
    local terminal_output=""

    # Determine color and format for terminal output based on the message content.
    if [[ "$msg" == FATAL* || "$msg" == ERROR* ]]; then
        terminal_output="${COLOR_RED}${log_prefix_term}${COLOR_BOLD}${msg}${COLOR_RESET}"
    elif [[ "$msg" == SUCCESS* ]]; then
        terminal_output="${COLOR_GREEN}${log_prefix_term}${COLOR_BOLD}${msg}${COLOR_RESET}"
    elif [[ "$msg" == EXEC* ]]; then
        terminal_output="${COLOR_CYAN}${log_prefix_term}${COLOR_BOLD}${msg}${COLOR_RESET}"
    elif [[ "$msg" == "Warning:"* ]]; then
        terminal_output="${COLOR_YELLOW}${log_prefix_term}${msg}${COLOR_RESET}"
    elif [[ "$msg" == "---"* ]]; then # Section headers for visual separation
        terminal_output="${COLOR_BLUE}${log_prefix_term}${COLOR_BOLD}${msg}${COLOR_RESET}"
    else # General informational messages
        terminal_output="${log_prefix_term}${msg}${COLOR_RESET}"
    fi

    # Log to file (always plain text for consistency and easier parsing by other tools).
    echo "${log_prefix_file}${msg}" | tee -a "$LOG_FILE"
    # Print the colorized message to the terminal for immediate, readable feedback.
    echo -e "${terminal_output}"
}

# Centralized error handling and exit function. Displays a detailed Zenity error.
# This function is the single point of failure for the script.
err_exit() {
    local msg="$1"
    log "FATAL ERROR: $msg"
    # Enhance the Zenity error message with more detail, color, and clear instructions.
    [ -n "$ZENITY" ] && zenity --error --title="Installer Critical Error" --width=600 --height=250 \
        --text="<span size='x-large' color='red'><b>Installer Aborted!</b></span>\n\nA critical and unrecoverable error has occurred:\n\n<b>$msg</b>\n\nThis issue prevents the NVIDIA driver installation from proceeding safely. The script has been terminated to prevent any potential damage to your system.\n\nPlease review the log file for comprehensive technical details and troubleshooting steps. The log file contains the full command outputs that led to this failure.\n\n<b>Log File Location:</b>\n<b>$LOG_FILE</b>"
    exit 1
}

# Run a command, log it, and exit if it fails. Ensures all output goes to the log file.
run_or_die() {
    log "EXEC: $*"
    # Redirect both stdout and stderr of the command to the log file, and check its exit status.
    if ! "$@" >>"$LOG_FILE" 2>&1; then
        # If the command fails, call err_exit which will display a Zenity error and terminate the script.
        err_exit "The command '$*' failed to execute successfully. Please check the log file for the exact error message."
    fi
    log "SUCCESS: The command '$*' completed successfully."
}

# Run a long-running command with a graphical progress bar and detailed feedback.
run_with_progress() {
    local title="$1"
    shift
    log "EXEC (Progress): $*"
    # The subshell and pipe require checking PIPESTATUS to get the real exit code of the executed command.
    # --auto-close is REMOVED to keep the dialog open after completion, allowing the user to see the result.
    ( "$@" 2>&1 | tee -a "$LOG_FILE" ) | zenity --progress --title="$title" --text="<b><span color='blue'>Task in Progress:</span> $title</b>\n\nExecuting command: <i>$*</i>\n\n<span color='gray'>(This operation may take some time. The dialog will remain open until the task is complete. For real-time, detailed output, please consult the log file.)</span>" --pulsate --auto-kill --width=750
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        # If the command failed, trigger a critical error exit.
        err_exit "The command '$*' failed during a progress operation. Please check the log for detailed error output."
    fi
    log "SUCCESS: The progress task '$title' completed successfully."
}

# Standardized function for asking Yes/No confirmation questions with detailed text.
user_confirm() {
    local question_text="$1"
    local title="$2:- Confirmation"
    # Use Pango markup for better readability and emphasis in the confirmation dialog.
    zenity --question --title="$title" --width=550 --height=200 \
        --text="<span size='large'><b>$title</b></span>\n\n$question_text\n\n<span color='gray'><i>(Please review this information carefully before confirming. This action may be irreversible.)</i></span>"
}

# --- Pre-Flight System Analysis Suite -----------------------------------------
# This suite of functions verifies that the system is in a state where installation can safely proceed.

# Checks if the script is being run with root privileges.
_check_root() {
    log "Verifying root privileges..."
    if [ "$EUID" -ne 0 ]; then
        # If not root, exit with a clear message. The script requires root for package management and system configuration.
        err_exit "This script requires root privileges to manage packages and system files. Please run it using 'sudo' or as the root user."
    fi
    log "SUCCESS: Root privileges confirmed."
}

# Checks if Zenity is installed and attempts to install it if missing.
_check_zenity() {
    log "Verifying Zenity availability..."
    if [ -z "$ZENITY" ]; then
        log "Warning: Zenity (GUI tool) not found. Attempting emergency installation via apt-get..."
        # Update package list before trying to install.
        if ! apt-get update -y >>"$LOG_FILE" 2>&1; then
            log "Warning: 'apt-get update' failed during Zenity check. Proceeding with installation attempt, but it might fail."
        fi
        # Attempt to install zenity and dialog packages.
        if ! apt-get install -y zenity dialog >>"$LOG_FILE" 2>&1; then
            # If installation fails, exit with a clear message.
            err_exit "Failed to auto-install Zenity and dialog. Please install them manually ('sudo apt install zenity dialog') and re-run the script."
        fi
        # Re-verify Zenity path after installation.
        ZENITY=$(command -v zenity)
        if [ -z "$ZENITY" ]; then
            err_exit "Zenity installation reported success, but the 'zenity' command is still not found in the system's PATH. Cannot continue without a GUI."
        fi
        log "SUCCESS: Zenity installed successfully. Proceeding with the script."
    fi
    log "SUCCESS: Zenity is available."
}

# Checks for a stable internet connection.
_check_internet() {
    log "Verifying internet connectivity..."
    # Ping a reliable, fast-responding IP address (Cloudflare's DNS) twice.
    if ! ping -c 2 1.1.1.1 >/dev/null 2>&1; then
        # If ping fails, exit with an informative error.
        err_exit "No internet connection detected. This installer requires an active and stable internet connection to download packages and updates. Please check your network configuration and firewall rules."
    fi
    log "SUCCESS: Internet connection confirmed."
}

# Checks if the APT package manager is currently locked by another process.
_check_apt_lock() {
    log "Verifying APT package manager is not locked..."
    # Check for the presence of dpkg and apt list lock files.
    if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
        # If locks are found, inform the user and exit to prevent conflicts.
        err_exit "APT is locked by another process. This could be Synaptic, another terminal running 'apt', or an automatic update process. Please close the other package manager and try again."
    fi
    log "SUCCESS: APT is not locked."
}

# Scans the system for the presence of an NVIDIA GPU.
_check_gpu_presence() {
    log "Scanning system for NVIDIA GPU hardware..."
    # Use lspci to search for VGA compatible controller entries related to NVIDIA Corporation.
    if ! lspci | grep -q -i 'vga.*nvidia'; then
        log "Warning: No NVIDIA GPU was automatically detected via 'lspci'."
        # If no GPU is found, this is a major red flag. Ask the user for confirmation before proceeding.
        if ! user_confirm "No NVIDIA GPU was automatically detected using 'lspci'.\n\nThis is highly unusual for a system intended for NVIDIA driver installation. Proceeding will likely be unproductive and may lead to unexpected issues.\n\nDo you wish to continue anyway at your own risk?" "Hardware Check Warning"; then
            err_exit "Installation canceled by user. No NVIDIA GPU was detected."
        fi
    else
        log "SUCCESS: NVIDIA GPU hardware detected successfully."
    fi
}

# Checks the Secure Boot status and warns the user if it's enabled.
_check_secure_boot() {
    log "Checking Secure Boot status..."
    # Use mokutil to query the Secure Boot state from the EFI firmware.
    if mokutil --sb-state 2>/dev/null | grep -q enabled; then
        log "Warning: Secure Boot is enabled on this system."
        # Display a detailed, multi-part warning to the user explaining the critical implications.
        zenity --warning --title="Security Alert: Secure Boot Enabled" --width=650 --height=320 \
            --text="<span size='x-large' color='red'><b>Security Alert: Secure Boot is ACTIVE!</b></span>\n\n<b>What this means:</b> Your system's firmware is configured to only load cryptographically signed kernel modules. The NVIDIA driver modules that this script compiles (using a system called DKMS) are <b>not signed</b> by default.\n\n<b>The Consequence:</b> The Linux kernel will <b>REFUSE to load</b> the unsigned NVIDIA driver. The installation will seem to succeed, but the driver will not work, and you may be left with a black screen or low-resolution display.\n\n<b>Recommended Action:</b>\n1. Exit this installer now.\n2. Reboot your computer and enter your UEFI/BIOS settings (usually by pressing F2, F12, or Del during startup).\n3. Find and <b>DISABLE</b> the 'Secure Boot' option.\n4. Save changes, reboot back into Kali, and re-run this installer.\n\n<span color='orange'><b>Alternative for Advanced Users:</b></span> You may proceed if you are an advanced user who plans to manually sign the NVIDIA kernel modules with your own Machine Owner Key (MOK) after they are built. This is a complex process."
        # Ask for user confirmation to proceed despite this critical warning.
        if ! user_confirm "Do you fully understand the implications of Secure Boot and wish to continue with the installation anyway?" "Secure Boot Confirmation"; then
            err_exit "Installation canceled by user due to Secure Boot being enabled."
        fi
    else
        log "SUCCESS: Secure Boot is disabled or not supported. This is the correct state for this installation method."
    fi
}

# Checks if the script is running inside a virtual machine environment.
_check_virtual_machine() {
    log "Checking for virtualization environment..."
    local vm
    # Use systemd-detect-virt to identify the virtualization technology.
    vm=$(systemd-detect-virt)
    if [ "$vm" != "none" ]; then
        log "Warning: Virtual machine environment '$vm' detected."
        # Inform the user about potential issues with VMs and GPU passthrough, as standard driver installation is usually ineffective.
        zenity --warning --title="Virtual Machine Detected" --width=600 --height=280 \
            --text="<span size='large' color='orange'><b>Virtual Machine Environment Detected</b></span>\n\nThis script has detected that it is running inside a virtual machine (<b>$vm</b>).\n\nInstalling proprietary NVIDIA drivers inside a standard VM is typically ineffective and not recommended. For the drivers to work, you usually need a complex hardware configuration called <b>GPU Passthrough (IOMMU)</b>, which involves dedicating the physical GPU to the VM from the host machine.\n\nStandard driver installation within a VM will likely fail to improve graphical performance and may cause instability.\n\nDo you understand these limitations and wish to proceed at your own risk?" "Virtualization Warning"
        # If the user cancels, exit the script.
        if [ $? -ne 0 ]; then
            err_exit "Installation canceled by user due to the detected virtual machine environment."
        fi
    else
        log "SUCCESS: Not running in a virtual machine environment."
    fi
}

# Checks if there is sufficient free disk space on the root partition.
_check_disk_space() {
    log "Checking available disk space on the root partition ('/')..."
    # Get available space in kilobytes and convert to gigabytes for easier comparison.
    local free_space_kb
    free_space_kb=$(df / --output=avail | tail -n 1)
    local free_space_gb=$((free_space_kb / 1024 / 1024))

    # Check against the minimum requirement for a base installation.
    if [ "$free_space_gb" -lt "$MIN_DISK_SPACE_GB" ]; then
        err_exit "Insufficient disk space. You have only ${free_space_gb}GB free on the root partition, but at least ${MIN_DISK_SPACE_GB}GB is required for the NVIDIA driver installation and its dependencies."
    fi
    log "SUCCESS: Disk space check passed: ${free_space_gb}GB available on the root partition."
}

# Verifies that the system is configured to use the 'kali-rolling' repository.
_check_kali_repo() {
    log "Verifying that the 'kali-rolling' repository is enabled..."
    # Check all files in /etc/apt/sources.list and /etc/apt/sources.list.d/ for lines matching the official kali-rolling repository format.
    if ! grep -q "^deb .*$REQUIRED_REPO" /etc/apt/sources.list /etc/apt/sources.list.d/*; then
        # If not found, exit with a specific error message.
        err_exit "The required '$REQUIRED_REPO' repository is not configured in your APT sources. This script is designed specifically for Kali Rolling to ensure package compatibility. Please ensure your system is correctly set up with the 'kali-rolling' repository enabled."
    fi
    log "SUCCESS: 'kali-rolling' repository is confirmed as enabled."
}

# NEW CHECK: Verifies that essential command-line tools are available.
_check_required_tools() {
    log "Verifying that essential command-line tools are installed..."
    local missing_tools=""
    for tool in curl wget lspci mokutil; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+="$tool "
        fi
    done
    if [ -n "$missing_tools" ]; then
        err_exit "The following required tools are missing: $missing_tools. Please install them using 'sudo apt install $missing_tools' and re-run the script."
    fi
    log "SUCCESS: All essential command-line tools are present."
}

# NEW CHECK: Checks the current graphical session type (X11 vs Wayland).
_check_session_type() {
    log "Checking graphical session type (X11 vs. Wayland)..."
    local session_type
    session_type=${XDG_SESSION_TYPE:-"unknown"}
    if [ "$session_type" = "wayland" ]; then
        log "Warning: Wayland graphical session detected."
        zenity --warning --title="Session Type Warning: Wayland Detected" --width=600 --height=250 \
            --text="<span size='large' color='orange'><b>Wayland Session Detected</b></span>\n\nYou are currently running a <b>Wayland</b> graphical session. While NVIDIA's support for Wayland is improving, the most stable and feature-complete experience is still typically found on the traditional <b>X11 (X.Org)</b> session.\n\nYou may encounter graphical glitches, screen recording issues, or other compatibility problems on Wayland.\n\n<b>Recommendation:</b>\nFor the best results, it is recommended to log out, select the '<b>GNOME on Xorg</b>' or similar X11 session from the login screen's gear icon, and then run this installer again."
        if ! user_confirm "Do you want to continue the installation under the current Wayland session despite the potential issues?" "Wayland Session Confirmation"; then
            err_exit "Installation canceled by user to switch to an X11 session."
        fi
    elif [ "$session_type" = "x11" ]; then
        log "SUCCESS: X11 graphical session detected. This is the recommended environment."
    else
        log "Warning: Could not definitively determine session type. Proceeding with caution."
    fi
}

# Master function to run all pre-flight checks sequentially with progress feedback.
# **THIS IS THE FUNCTION THAT WAS FIXED TO NOT AUTO-CLOSE.**
run_all_pre_flight_checks() {
    log "--- Starting Comprehensive Pre-Flight System Analysis Suite ---"
    # Use a Zenity progress bar to show the progress of all checks.
    (
        echo "0"; echo "# Initializing Analysis..."
        sleep 1
        _check_root
        echo "5"; echo "# Verifying Zenity GUI..."
        sleep 1
        _check_zenity
        echo "15"; echo "# Checking Internet Connection..."
        sleep 1
        _check_internet
        echo "25"; echo "# Checking APT Package Manager Locks..."
        sleep 1
        _check_apt_lock
        echo "35"; echo "# Verifying Essential Tools..."
        sleep 1
        _check_required_tools
        echo "45"; echo "# Scanning for NVIDIA Hardware..."
        sleep 1
        _check_gpu_presence
        echo "60"; echo "# Checking Secure Boot Status..."
        sleep 1
        _check_secure_boot
        echo "70"; echo "# Detecting Virtualization Environment..."
        sleep 1
        _check_virtual_machine
        echo "80"; echo "# Analyzing Available Disk Space..."
        sleep 1
        _check_disk_space
        echo "90"; echo "# Verifying Kali Repository Configuration..."
        sleep 1
        _check_kali_repo
        echo "95"; echo "# Checking Graphical Session Type..."
        sleep 1
        _check_session_type
        echo "100"; echo "# All pre-flight checks completed successfully. System appears ready."
        sleep 2 # Pause to let the user see the 100% status.
    ) | zenity --progress --title="System Pre-flight Analysis" --width=700 --height=150 --no-cancel

    # After the progress bar finishes, show a summary dialog that the user must acknowledge.
    # This solves the "auto close" issue and confirms the results.
    zenity --info --title="Pre-Flight Analysis Complete" --width=500 \
        --text="<span size='large' color='green'><b>System Analysis Successful!</b></span>\n\nAll pre-flight checks have passed.\n\nYour system appears to be in a suitable state for the NVIDIA driver installation to begin.\n\nClick 'OK' to proceed to the installation summary."
    log "--- System Analysis Complete. All systems are nominal. ---"
}

# --- Installation Process Functions ---

# NEW FUNCTION: Display a final summary and get the last confirmation before modifying the system.
display_pre_installation_summary() {
    log "Displaying pre-installation summary for final user confirmation."
    local summary_text="<span size='large'><b>Pre-Installation Summary & Final Confirmation</b></span>\n\nYou are about to begin the system modification phase. The following actions will be performed:\n\n<b>1. Full System Upgrade:</b>\n   - Run 'apt update' and 'apt full-upgrade' to ensure your system is current.\n\n<b>2. Kernel Header Installation:</b>\n   - Install the necessary 'linux-headers' for your specific kernel version.\n\n<b>3. NVIDIA Driver Installation:</b>\n   - Install the 'nvidia-driver' and 'nvidia-kernel-dkms' packages.\n   - Automatically blacklist the default 'nouveau' driver.\n\n<b>4. Optional CUDA Toolkit:</b>\n   - You will be asked if you want to install the large 'nvidia-cuda-toolkit' package.\n\n<b>5. Reboots:</b>\n   - The system may require one or more reboots to complete the process.\n\n<span color='red'><b>This is the point of no return.</b> Once you click 'Yes', the script will start making changes to your system.</span>"

    if ! user_confirm "$summary_text" "Point of No Return"; then
        err_exit "Installation canceled by user at the final confirmation summary."
    fi
    log "User has given final confirmation to proceed with system modifications."
}

# Step 1: Perform a full system upgrade.
step_1_system_upgrade() {
    # Provide a detailed explanation of the importance of this step.
    zenity --info --title="Installation - Step 1/5: System Synchronization" --width=700 --height=320 \
        --text="<span size='large'><b>Step 1: Full System Synchronization</b></span>\n\nAs per the official Kali Linux documentation, the most critical first step is to ensure your entire system is up-to-date. This synchronizes your installed Linux kernel with the available kernel headers and ensures all packages are at their latest versions.\n\nThis step is vital for a stable driver build and prevents a wide range of potential compatibility issues.\n\n<b>Actions Being Performed:</b>\n1. <b>apt update</b>: Fetches the latest package information from all enabled repositories.\n2. <b>apt full-upgrade</b>: Upgrades all installed packages to their latest versions, intelligently handling dependencies and potentially installing new kernels or removing obsolete packages.\n\n<span color='orange'><b>Important Note:</b> This process can take a significant amount of time, depending on your system's current state and internet speed. Please be patient and do not interrupt it. The progress dialog will remain open until the task is fully complete.</span>"
    # Execute the upgrade commands with progress indication.
    run_with_progress "Updating package lists (apt update)..." apt-get update -y
    run_with_progress "Performing full system upgrade (apt full-upgrade)..." apt-get full-upgrade -y
}

# Step 2: Check if a reboot is required after the system upgrade.
step_2_reboot_check() {
    # Check for the existence of the reboot-required flag file, which is a standard Debian/Kali mechanism.
    if [ -f /var/run/reboot-required ]; then
        log "Reboot is required after system upgrade, as indicated by /var/run/reboot-required."
        # Inform the user that a reboot is mandatory for the new kernel to be loaded.
        zenity --info --title="Installation - Action Required: Reboot" --width=600 --height=250 \
            --text="<span size='large'><b>Reboot is Mandatory!</b></span>\n\nThe system upgrade you just completed has installed a new Linux kernel or other critical system components.\n\nA <b>reboot is now absolutely necessary</b> to boot into this new kernel. The NVIDIA driver installation can only proceed once the system is running the kernel for which it will be built.\n\nThe installer will now prompt you to reboot.\n\n<span color='red'>Proceeding without a reboot will almost certainly lead to driver installation failure or a non-functional system.</span>"
        # Ask for user confirmation to reboot.
        if user_confirm "Click 'Yes' to reboot the system now.\nClick 'No' to cancel the entire installation process." "Mandatory Reboot"; then
            log "User confirmed reboot to load new kernel. System will now restart."
            # Initiate reboot and exit the script. The script's job is done for this session.
            reboot
            exit 0 # Script will terminate after reboot command is issued.
        else
            # If the user declines the mandatory reboot, we cannot safely continue.
            err_exit "Reboot was declined. Cannot safely continue the NVIDIA driver installation without a system reboot."
        fi
    else
        log "No reboot required after system upgrade. Proceeding to the next step."
    fi
}

# Step 3: Install necessary kernel headers and DKMS.
step_3_install_headers() {
    # Explain the role of kernel headers and DKMS in a more detailed, educational way.
    zenity --info --title="Installation - Step 2/5: Kernel Headers & DKMS" --width=700 --height=320 \
        --text="<span size='large'><b>Step 2: Installing Kernel Headers and DKMS</b></span>\n\nThe NVIDIA driver is a kernel module, meaning it runs at the core level of the operating system. For this to work, it must be compiled specifically for your running Linux kernel version.\n\nThis step installs the essential components for this compilation:\n- <b>linux-headers-$(uname -r):</b> These are like the 'blueprints' for your kernel. They provide the source code and build tools that allow new modules (like the NVIDIA driver) to be correctly compiled and linked against your exact kernel.\n- <b>dkms (Dynamic Kernel Module Support):</b> This is a crucial framework that acts like a 'smart assistant'. It automatically recompiles the NVIDIA kernel module whenever the Linux kernel itself is updated in the future. This ensures your driver continues to work seamlessly after system updates.\n\nThese packages are foundational for a stable, self-maintaining NVIDIA driver installation."
    local kernel_version
    kernel_version=$(uname -r)
    log "Target kernel version identified as: $kernel_version."
    # Install the specific headers for the running kernel and the DKMS framework.
    run_with_progress "Installing Linux Headers (linux-headers-$(uname -r)) and DKMS..." apt-get install -y "linux-headers-$(uname -r)" dkms
}

# Step 4: Install the NVIDIA driver packages from the repository.
step_4_install_drivers() {
    # Explain the core driver installation process with more clarity on what each package does.
    zenity --info --title="Installation - Step 3/5: NVIDIA Driver Installation" --width=700 --height=320 \
        --text="<span size='large'><b>Step 3: Installing the NVIDIA Driver Packages</b></span>\n\nNow, we will install the main proprietary NVIDIA driver components directly from the official Kali Linux repositories. This is the recommended and most stable method.\n\n<b>Packages Being Installed:</b>\n- <b>nvidia-driver:</b> This is the core proprietary NVIDIA graphics driver package, containing the OpenGL libraries and other essential components.\n- <b>nvidia-kernel-dkms:</b> This package is the 'engine' of the installation. When installed, it triggers the DKMS framework to automatically compile the NVIDIA kernel module for your current kernel version using the headers we just installed.\n\n<b>Automatic System Configuration:</b>\nDuring this installation, the system's package manager will also automatically create a configuration file to <b>blacklist</b> the default open-source 'nouveau' driver. This is a critical step to prevent conflicts between the two drivers, which could lead to system instability.\n\n<span color='blue'>The installer will now download and install these essential components.</span>"
    # Execute the driver installation commands.
    run_with_progress "Installing nvidia-driver and nvidia-kernel-dkms..." apt-get install -y nvidia-driver nvidia-kernel-dkms
}

# Step 5: Optionally install the NVIDIA CUDA Toolkit.
step_5_install_cuda_optional() {
    # Explain the purpose and size of CUDA with more examples.
    zenity --info --title="Installation - Step 4/5: Optional CUDA Toolkit" --width=700 --height=320 \
        --text="<span size='large'><b>Step 4 (Optional): Install NVIDIA CUDA Toolkit</b></span>\n\nThe NVIDIA CUDA Toolkit is a parallel computing platform and programming model that allows the GPU (Graphics Processing Unit) to be used for general-purpose processing. This can dramatically accelerate tasks that can be broken down into parallel operations.\n\nThis is essential for applications in fields such as:\n- <b>Penetration Testing:</b> Password cracking with tools like Hashcat or John the Ripper.\n- <b>Data Science:</b> Machine Learning and Deep Learning frameworks like TensorFlow and PyTorch.\n- <b>Content Creation:</b> Video rendering and scientific simulations.\n\n<span color='orange'><b>Important Warning:</b> The CUDA Toolkit is a <b>very large</b> download, often several gigabytes in size. Only install this if you specifically require GPU computing capabilities for your work. Installing it unnecessarily will consume significant disk space and download time.</span>"
    # Ask the user if they want to install CUDA.
    if user_confirm "Do you specifically need to use your GPU for parallel computing tasks (like machine learning or password cracking)?\n\nIf yes, select 'Yes' to install the NVIDIA CUDA Toolkit. If you are unsure, it is safe to select 'No'." "Optional CUDA Installation"; then
        log "User has chosen to install the CUDA Toolkit."
        # Perform a disk space check specifically for CUDA if the user agrees.
        _check_disk_space_for_cuda
        # Install the CUDA package.
        run_with_progress "Installing CUDA Toolkit (nvidia-cuda-toolkit)... This may take a very long time." apt-get install -y nvidia-cuda-toolkit
    else
        log "User skipped CUDA installation. Proceeding without the CUDA Toolkit."
    fi
}

# Helper function to check disk space specifically for CUDA installation.
_check_disk_space_for_cuda() {
    log "Checking available disk space for the large CUDA installation..."
    local free_space_kb
    free_space_kb=$(df / --output=avail | tail -n 1)
    local free_space_gb=$((free_space_kb / 1024 / 1024))
    # Check against the higher requirement for CUDA.
    if [ "$free_space_gb" -lt "$MIN_DISK_SPACE_CUDA_GB" ]; then
        err_exit "Insufficient disk space for CUDA. You have ${free_space_gb}GB free, but at least ${MIN_DISK_SPACE_CUDA_GB}GB is recommended for the CUDA toolkit and its associated libraries."
    fi
    log "SUCCESS: Disk space check passed for CUDA: ${free_space_gb}GB available on the root partition."
}

# Step 6: Prompt the user for a final reboot to activate the driver.
step_6_final_reboot_prompt() {
    log "NVIDIA driver installation process has completed all installation steps."
    # Inform the user that a reboot is needed for the new driver to become active.
    zenity --info --title="Installation - Step 5/5: Final Reboot Required" --width=600 --height=280 \
        --text="<span size='x-large'><b>Installation Complete!</b></span>\n\nThe NVIDIA driver and all necessary components have been successfully installed and compiled for your system.\n\nA final reboot is required to complete the process. This will unload the old 'nouveau' driver from memory and load the newly installed proprietary 'nvidia' driver into the kernel.\n\nAfter your system has rebooted, you can re-run this installer and select the '<b>Deep Dive Verification Suite</b>' option from the main menu to perform a comprehensive check and confirm that everything is working correctly.\n\n<span color='blue'>Thank you for using the Kali NVIDIA Gargantuan Installer! Your system is now ready for enhanced graphics performance.</span>"
    # Ask if the user wants to reboot now.
    if user_confirm "A system reboot is required to activate the new NVIDIA driver.\n\nClick 'Yes' to reboot the system now.\nClick 'No' to perform the reboot manually later." "Final Reboot Prompt"; then
        log "User confirmed final reboot. The system will now restart."
        # Initiate reboot.
        reboot
    else
        log "User chose to reboot manually later. The script will now return to the main menu."
    fi
}

# Master function to orchestrate the entire Gargantuan installation process.
leviathan_install() {
    log "--- Initiating Gargantuan Installation Process ---"
    # Initial confirmation before starting the entire process.
    if ! user_confirm "You are about to begin the fully automated NVIDIA driver installation process.\n\nThis process will perform a full system upgrade, install new drivers, and may require one or more reboots.\n\nIt is highly recommended to close all other applications and save your work before proceeding.\n\nDo you wish to proceed with the Gargantuan Installation?" "Confirm Full Installation"; then
        log "User aborted the Gargantuan installation process at the initial confirmation."
        return # Exit the function if user cancels, returning to the main menu.
    fi

    # Run all pre-flight checks first. This ensures the system is ready for modification.
    run_all_pre_flight_checks

    # Display the pre-installation summary and get the final go-ahead.
    display_pre_installation_summary

    # Execute the installation steps sequentially, guiding the user through each phase.
    step_1_system_upgrade
    step_2_reboot_check
    step_3_install_headers
    step_4_install_drivers
    step_5_install_cuda_optional
    step_6_final_reboot_prompt
    log "--- Gargantuan Installation Process Finished ---"
}

# --- Deep Dive Verification Suite Functions ---

# Performs a comprehensive set of checks to verify driver installation and functionality.
comprehensive_verification() {
    log "--- Starting Deep Dive Verification Suite ---"
    local report="<b>Gargantuan Installation Verification Report:</b>\n\n"
    local all_ok=true # Flag to track overall success

    # Check 1: DKMS Status - Verifies if the NVIDIA module is registered and built.
    log "Verifying DKMS status for the NVIDIA module..."
    if dkms status 2>/dev/null | grep -q 'nvidia.*installed'; then
        # If found and installed, append a success message to the report.
        report+="✅ <b>DKMS Module Status:</b> <span color='green'>OK</span>\n   - The 'nvidia' module is successfully registered and built via DKMS.\n\n"
    else
        # If not found or failed to build, append a failure message and set overall_ok to false.
        report+="❌ <b>DKMS Module Status:</b> <span color='red'>FAILED</span>\n   - The 'nvidia' module was NOT found or failed to build in DKMS. This is a critical issue.\n   - If you recently rebooted, DKMS might still be building. Check the log for details.\n\n"
        all_ok=false
    fi

    # Check 2: Kernel Module Loaded - Verifies if the 'nvidia' module is active in the running kernel.
    log "Verifying if the NVIDIA kernel module is loaded into the kernel..."
    if lsmod | grep -q '^nvidia '; then
        # If loaded, append a success message.
        report+="✅ <b>Kernel Driver Status:</b> <span color='green'>OK</span>\n   - The 'nvidia' kernel module is currently loaded and active.\n\n"
    else
        # If not loaded, indicate a potential problem and set overall_ok to false.
        report+="❌ <b>Kernel Driver Status:</b> <span color='red'>FAILED</span>\n   - The 'nvidia' module is NOT loaded. This could be due to Secure Boot issues, a build error, or a failure to reboot after installation.\n   - Check the 'dmesg' command output for specific kernel loading errors.\n\n"
        all_ok=false
    fi

    # Check 3: NVIDIA SMI Tool - Verifies if nvidia-smi command works and reports GPU status.
    log "Verifying nvidia-smi tool functionality and communication with the driver..."
    local smi_output
    # Attempt to run nvidia-smi and capture its output.
    if command -v nvidia-smi &>/dev/null && smi_output=$(nvidia-smi 2>&1); then
        # If successful, append the output to the report.
        report+="✅ <b>NVIDIA SMI Tool:</b> <span color='green'>OK</span>\n   - The 'nvidia-smi' command is working and successfully communicating with the driver.\n\n<tt>${smi_output}</tt>\n\n"
    else
        # If nvidia-smi fails, indicate an error.
        report+="❌ <b>NVIDIA SMI Tool:</b> <span color='red'>FAILED</span>\n   - The 'nvidia-smi' command failed to execute or reported an error.\n   - This usually indicates a severe driver loading or compatibility issue.\n\n"
        all_ok=false
    fi

    # Check 4: OpenGL Rendering - Verifies if the system is using the NVIDIA GPU for graphics.
    log "Verifying OpenGL rendering is being handled by the NVIDIA GPU..."
    # First, check if glxinfo is available; if not, offer to install it.
    if ! command -v glxinfo &>/dev/null; then
        log "'glxinfo' command not found. Offering to install 'mesa-utils'."
        # Offer to install mesa-utils, which provides glxinfo.
        if user_confirm "'glxinfo' command not found. This tool is needed to verify OpenGL acceleration.\nIt's part of the 'mesa-utils' package.\n\nDo you want to install 'mesa-utils' now?" "Missing Tool: glxinfo"; then
            run_with_progress "Installing mesa-utils..." apt-get install -y mesa-utils
        fi
    fi
    # Now, perform the check if glxinfo is available.
    if command -v glxinfo &>/dev/null; then
        # Grep the output for "NVIDIA" to confirm it's being used as the renderer.
        if glxinfo -B | grep -q "OpenGL renderer string.*NVIDIA"; then
            # Success: NVIDIA GPU is reported as the renderer.
            report+="✅ <b>OpenGL Acceleration:</b> <span color='green'>OK</span>\n   - The system is correctly reporting the NVIDIA GPU as the OpenGL renderer.\n\n"
        else
            # Failure: System might be falling back to software rendering or a different GPU.
            report+="❌ <b>OpenGL Acceleration:</b> <span color='red'>FAILED</span>\n   - The system is NOT correctly reporting the NVIDIA GPU for OpenGL rendering.\n   - This might mean the driver isn't loaded, or a fallback driver (like Mesa or Nouveau) is in use.\n\n"
            all_ok=false
        fi
    else
        # Warning if glxinfo is still not available.
        report+="⚠️ <b>OpenGL Acceleration:</b> <span color='orange'>UNKNOWN</span>\n   - Could not perform the check because 'glxinfo' is unavailable.\n\n"
    fi

    # Display the final verification report to the user.
    if [ "$all_ok" = true ]; then
        # If all checks passed, show a success dialog.
        zenity --info --title="Verification Successful" --width=800 --height=600 \
            --text="<span size='x-large' color='green'><b>All major checks passed successfully!</b></span>\n\nYour NVIDIA driver appears to be fully installed and operational.\n\n<b>Verification Summary:</b>\n$report"
    else
        # If any check failed, show an error dialog with the detailed report.
        zenity --error --title="Verification Failed" --width=800 --height=600 \
            --text="<span size='x-large' color='red'><b>One or more verification checks failed!</b></span>\n\n$report\n\nPlease review the errors above and consult the log file for detailed troubleshooting information and potential solutions.\n<b>Log File Location: $LOG_FILE</b>"
    fi
}

# --- Uninstallation and About Dialogs ---

# Uninstalls all NVIDIA-related packages and attempts to restore the Nouveau driver.
uninstall_nvidia() {
    # Ask for strong confirmation before proceeding with a destructive action like uninstallation.
    if ! user_confirm "This action will completely <b>PURGE</b> all NVIDIA packages from your system.\nIt will also attempt to restore the default 'nouveau' open-source driver.\n\nA reboot will be required afterward to load the correct driver.\n\nAre you absolutely certain you want to proceed with the uninstallation?" "Confirm NVIDIA Driver Uninstallation"; then
        log "User canceled the NVIDIA driver uninstallation process."
        return # Exit the function if user cancels, returning to the main menu.
    fi
    log "--- Starting Full NVIDIA Driver Purge ---"
    # Purge all packages matching the nvidia pattern to ensure a clean removal.
    run_with_progress "Purging all NVIDIA packages from the system..." apt-get remove --purge -y '~nnvidia-.*'
    # Clean up any orphaned dependencies that might remain after the purge.
    run_with_progress "Cleaning up orphaned dependencies..." apt-get autoremove -y
    log "Removing any leftover NVIDIA configuration files..."
    # Remove any specific blacklist files created by the installer to re-enable nouveau.
    run_or_die rm -f /etc/modprobe.d/nvidia-installer-disable-nouveau.conf
    # Update the initramfs to ensure Nouveau is properly configured for the next boot.
    run_with_progress "Updating initramfs to restore the Nouveau driver..." update-initramfs -u

    # Inform the user about completion and the need for a reboot.
    zenity --info --title="Uninstallation Complete" --width=550 \
        --text="<span size='large'><b>NVIDIA Driver Uninstallation Successful</b></span>\n\nAll NVIDIA components have been purged from your system.\n\nA reboot is now required to load the default 'nouveau' video driver.\n\nThank you for using the Gargantuan Installer!"
    # Ask for reboot confirmation.
    if user_confirm "A reboot is required to activate the restored default driver.\n\nReboot now?" "Reboot Required After Uninstall"; then
        reboot
    fi
}

# Displays an informative "About" dialog for the script.
show_about_dialog() {
    zenity --info --title="About This Installer - Gargantuan Edition" --width=800 --height=450 \
        --text="<span size='x-large'><b>Kali NVIDIA Installer - Gargantuan Edition</b></span>\n\nThis script is an exceptionally robust, safe, and user-centric tool designed for installing NVIDIA's proprietary drivers on Kali Linux.\n\nIt meticulously follows the official Kali Linux documentation and provides a guided, transparent installation experience, automating the entire process from pre-flight checks to deep-dive verification.\n\n<b>Key Features:</b>\n- 🚀 <b>Fully Automated 'Gargantuan Install'</b>: Handles all steps from system upgrade to driver verification, making the complex process simple.\n- 🛡️ <b>Exhaustive Pre-Flight Analysis</b>: Detects potential issues like Secure Boot, Wayland sessions, VM environments, insufficient disk space, and hardware presence before any changes are made.\n- 📖 <b>'Philosopher's Guide' UI</b>: Detailed explanations for every action taken by the script, ensuring you understand the 'what' and 'why' of each step.\n- 🔎 <b>Deep Dive Verification Suite</b>: Confirms driver functionality at multiple levels, including DKMS status, kernel module loading, `nvidia-smi` communication, and OpenGL rendering.\n- ✨ <b>Clean Uninstaller</b>: Safely removes all NVIDIA components and reliably restores the default 'nouveau' driver.\n- 🌈 <b>Enhanced Terminal & GUI Feedback</b>: Leverages color-coded messages and informative, non-auto-closing Zenity dialogs for a superior user experience.\n- 📝 <b>Comprehensive & Detailed Logging</b>: All operations, commands, and their outputs are meticulously recorded in <b>$LOG_FILE</b> for easy troubleshooting and auditing.\n\nThis project is a significant enhancement and evolution inspired by the foundational work in the Opselon/Kali-LInux-Nvidia-Installer repository."
}

# --- Main Menu and Script Entrypoint ---

# Displays the main menu for user interaction.
main_menu() {
    # Print the ASCII banner to the terminal for visual appeal and to identify the script version.
    echo -e "$BANNER"
    local choice
    # Present the main options to the user via a Zenity list dialog with detailed descriptions.
    choice=$(zenity --list --title="Kali NVIDIA Installer - Gargantuan Edition" --text="$BANNER\n<span size='large'>Welcome to the Kali NVIDIA Installer - Gargantuan Edition.</span>\n\nPlease select an action from the list below to manage your NVIDIA drivers." --height=550 --width=900 \
        --column="Action" --column="Description" \
        "Start Gargantuan Installation" "The ultimate, fully automated, and guided process to install, update, and configure your NVIDIA drivers." \
        "Deep Dive Verification Suite" "Run a comprehensive diagnostic suite to confirm if your NVIDIA drivers are installed correctly and are fully functional." \
        "Purge All NVIDIA Drivers" "Completely uninstall all NVIDIA components, revert system changes, and restore the default 'nouveau' driver." \
        "View Log File" "Open the detailed log file for the current session for troubleshooting and auditing purposes." \
        "About This Installer" "Display information about the script's advanced features, purpose, and development." \
        "Exit" "Close the application and exit the installer.")

    # Process the user's selection from the main menu.
    case "$choice" in
        "Start Gargantuan Installation") leviathan_install ;; # Note: Renamed function in my local copy for consistency
        "Deep Dive Verification Suite") comprehensive_verification ;;
        "Purge All NVIDIA Drivers") uninstall_nvidia ;;
        "View Log File")
            # Attempt to open the log file with the default application (e.g., gedit, kate) or show it in Zenity as a fallback.
            if ! xdg-open "$LOG_FILE" 2>/dev/null; then
                zenity --text-info --filename="$LOG_FILE" --title="Log File Viewer" --width=900 --height=700
            fi
            ;;
        "About This Installer") show_about_dialog ;;
        *)
            # If the user selects Exit or closes the dialog, log the action and exit gracefully.
            log "User selected exit or closed the dialog. Shutting down the installer."
            exit 0
            ;;
    esac
}

# --- Script Entrypoint ---
# This is where the script execution begins.

# Initialize the log file directory and the log file itself upon script start.
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
log "--- Kali NVIDIA Gargantuan Installer session started ---"

# Perform initial critical checks before displaying the main menu.
# This ensures that essential dependencies like root privileges and Zenity are met.
_check_root
_check_zenity

# Enter the main application loop to display the menu and handle user actions continuously.
# The script will remain in this loop until the user chooses to exit.
while true; do
    main_menu
done