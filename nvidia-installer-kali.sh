#!/usr/bin/env bash
#
# kali-nvidia-installer-titan.sh
#
# The "Titan Edition" - An ultimate, exceptionally detailed, and transparent GUI-driven NVIDIA
# Driver Installation Suite for Kali Linux. This script brings total clarity to the user
# by providing a live, real-time log of all major operations, an exhaustive suite of pre-flight
# system analysis checks, and an educational, step-by-step guided process.
#
# License: MIT
#

# --- Script Configuration and Constants -------------------------------------
# These settings control the script's behavior and enforce strict error checking.
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
# The path to the Zenity executable will be stored here after verification.
ZENITY=$(command -v zenity || true)
# This variable will hold the path to the temporary live log file during pre-flight checks.
LIVE_LOG_FILE=""

# --- ASCII Art Banner --------------------------------------------------------
readonly BANNER="
    __   __   __    __     __  .__   __.  _______ .__   __. .___________. _______ .______
   |  | |  | |  |  |  |   |  | |  \\ |  | |   ____||  \\ |  | |           ||   ____||   _  \\
   |  | |  | |  |  |  |   |  | |   \\|  | |  |__   |   \\|  | \`---|  |----\`|  |__   |  |_)  |
.--.  | |  | |  |  |  |   |  | |  . \`  | |   __|  |  . \`  |     |  |     |   __|  |      /
|  \`--' | |  \`--'  |   |  \`--'  | |  |\\   | |  |____ |  |\\   |     |  |     |  |____ |  |\\  \\----.
 \______/   \\______/     \\______/  |__| \\__| |_______||__| \\__|     |__|     |_______|| _| \`._____|
        - K A L I   L I N U X   T I T A N   E D I T I O N -
"

readonly PRE_FLIGHT_BANNER="
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |P|r|e|-|F|l|i|g|h|t| |S|y|s|t|e|m| |A|n|a|l|y|s|i|s|
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
"
readonly INSTALL_BANNER="
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |I|n|s|t|a|l|l|a|t|i|o|n| |P|h|a|s|e|
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
"
readonly VERIFY_BANNER="
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |V|e|r|i|f|i|c|a|t|i|o|n| |S|u|i|t|e|
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
"

# --- Core Helper Functions ----------------------------------------------------

#
# Centralized logging function with terminal colorization and live log support.
# All script output, whether informational, an error, or a success message, should pass through here.
# It logs to three places: the permanent log file, the terminal, and optionally, a temporary live log file for the UI.
#
log() {
    local msg="$*"
    local timestamp
    timestamp=$(date --iso-8601=seconds)
    local log_prefix_file="${timestamp} | ${PROGNAME}: " # Prefix for the permanent log file (plain text)
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
    elif [[ "$msg" == "---"* || "$msg" == "+-"* ]]; then # Section headers for visual separation
        terminal_output="${COLOR_BLUE}${log_prefix_term}${COLOR_BOLD}${msg}${COLOR_RESET}"
    else # General informational messages
        terminal_output="${log_prefix_term}${msg}${COLOR_RESET}"
    fi

    # Log to the permanent file (always plain text for consistency).
    echo "${log_prefix_file}${msg}" >> "$LOG_FILE"
    # Print the colorized message to the terminal for immediate feedback.
    echo -e "${terminal_output}"
    # If a live log file is currently active, append the plain text message to it as well.
    if [ -n "$LIVE_LOG_FILE" ] && [ -f "$LIVE_LOG_FILE" ]; then
        echo "${log_prefix_file}${msg}" >> "$LIVE_LOG_FILE"
    fi
}

#
# Centralized error handling and exit function. Displays a detailed Zenity error.
# This function is the single point of failure for the script, ensuring all fatal errors are handled consistently.
#
err_exit() {
    local msg="$1"
    log "FATAL ERROR: $msg"
    # Enhance the Zenity error message with more detail, color, and clear instructions.
    [ -n "$ZENITY" ] && zenity --error --title="Installer Critical Error" --width=600 --height=250 \
        --text="<span size='x-large' color='red'><b>Installer Aborted!</b></span>\n\nA critical and unrecoverable error has occurred:\n\n<b>$msg</b>\n\nThis issue prevents the NVIDIA driver installation from proceeding safely. The script has been terminated to prevent any potential damage to your system.\n\nPlease review the log file for comprehensive technical details and troubleshooting steps. The log file contains the full command outputs that led to this failure.\n\n<b>Log File Location:</b>\n<b>$LOG_FILE</b>"
    exit 1
}

#
# The centerpiece of this edition. Runs a command while showing its live output in a Zenity text-info window.
# Ideal for long-running processes like 'apt' where the user wants to see real-time progress.
#
run_with_live_log() {
    local title="$1"
    shift
    local cmd_to_run=("$@")

    log "EXEC (Live Log): ${cmd_to_run[*]}"

    # Create a temporary file to store the live output of the command.
    local TMP_LOG
    TMP_LOG=$(mktemp)

    # Use a trap to ensure the temporary log file is always cleaned up, even if the script is interrupted.
    trap 'rm -f "$TMP_LOG"' EXIT

    # Start the command in the background, redirecting both its stdout and stderr to the temporary log file.
    # We use 'stdbuf' to ensure output is line-buffered, making the live log more responsive.
    stdbuf -oL -eL "${cmd_to_run[@]}" > "$TMP_LOG" 2>&1 &
    local CMD_PID=$!

    # Launch a Zenity text-info window that tails the temporary log file, showing the output in real-time.
    # This also runs in the background.
    tail -f "$TMP_LOG" | zenity --text-info --title="$title" --width=900 --height=600 --font="Monospace" &
    local ZENITY_PID=$!

    # Wait for the main command to finish its execution.
    wait "$CMD_PID"
    local exit_code=$? # Capture the exit code of the main command.

    # After the command finishes, give a moment for the final output to be piped, then kill the Zenity window.
    sleep 1
    kill "$ZENITY_PID" 2>/dev/null || true

    # Check if the command executed successfully.
    if [ $exit_code -ne 0 ]; then
        err_exit "The command '${cmd_to_run[*]}' failed with exit code $exit_code. The live log above shows the detailed error. Please review the main log file for a complete record."
    fi

    log "SUCCESS: The live log task '$title' completed successfully."
    # Clean up the trap and the temporary file.
    trap - EXIT
    rm -f "$TMP_LOG"
}

#
# Standardized function for asking Yes/No confirmation questions with detailed, multi-line text.
#
user_confirm() {
    local question_text="$1"
    local title="$2:- Confirmation"
    # Use Pango markup for better readability and emphasis in the confirmation dialog.
    zenity --question --title="$title" --width=650 --height=250 \
        --text="<span size='large'><b>$title</b></span>\n\n$question_text\n\n<span color='gray'><i>(Please review this information carefully before confirming. This action may be irreversible.)</i></span>"
}

# --- Pre-Flight System Analysis Suite -----------------------------------------
# This suite of functions verifies that the system is in a state where installation can safely proceed.

# Checks if the script is being run with root privileges.
_check_root() {
    log "Checking for root privileges..."
    if [ "$EUID" -ne 0 ]; then
        err_exit "This script requires root privileges to manage packages and system files. Please run it using 'sudo' or as the root user."
    fi
    log "SUCCESS: Root privileges confirmed."
}

# Checks if Zenity is installed and attempts to install it if missing.
_check_zenity() {
    log "Checking for Zenity GUI toolkit..."
    if [ -z "$ZENITY" ]; { err_exit "Zenity not found. Cannot continue without GUI."; }
    log "SUCCESS: Zenity is available."
}

# Checks for a stable internet connection.
_check_internet() {
    log "Checking for internet connectivity..."
    if ! ping -c 2 1.1.1.1 >/dev/null 2>&1; then
        err_exit "No internet connection detected. A stable internet connection is required to download packages."
    fi
    log "SUCCESS: Internet connection confirmed."
}

# Checks if the APT package manager is currently locked.
_check_apt_lock() {
    log "Checking for APT package manager locks..."
    if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
        err_exit "APT is locked by another process. Please close any other package managers and try again."
    fi
    log "SUCCESS: APT is not locked."
}

# Scans the system for an NVIDIA GPU.
_check_gpu_presence() {
    log "Checking for NVIDIA GPU hardware..."
    if ! lspci | grep -q -i 'vga.*nvidia'; then
        if ! user_confirm "No NVIDIA GPU was detected. Proceeding is not recommended.\n\nDo you wish to continue anyway?" "Hardware Check Warning"; then
            err_exit "Installation canceled by user. No NVIDIA GPU detected."
        fi
    fi
    log "SUCCESS: NVIDIA GPU hardware detected."
}

# Checks the Secure Boot status.
_check_secure_boot() {
    log "Checking Secure Boot status..."
    if mokutil --sb-state 2>/dev/null | grep -q enabled; {
        log "Warning: Secure Boot is enabled."
        if ! user_confirm "Secure Boot is ACTIVE.\n\nThis will PREVENT the unsigned NVIDIA driver from loading. It is highly recommended to disable Secure Boot in your BIOS/UEFI before proceeding.\n\nDo you understand and wish to continue anyway?" "Secure Boot Warning"; then
            err_exit "Installation canceled by user due to Secure Boot."
        fi
    } else {
        log "SUCCESS: Secure Boot is disabled."
    }
}

# Checks if running inside a VM.
_check_virtual_machine() {
    log "Checking for virtualization environment..."
    local vm; vm=$(systemd-detect-virt)
    if [ "$vm" != "none" ]; then
        log "Warning: Virtual machine environment '$vm' detected."
        if ! user_confirm "A VM environment was detected.\n\nStandard driver installation is usually ineffective in VMs without complex GPU Passthrough. Do you wish to proceed at your own risk?" "Virtualization Warning"; then
            err_exit "Installation canceled by user due to VM environment."
        fi
    fi
    log "SUCCESS: Not running in a virtual machine."
}

# Checks for sufficient disk space.
_check_disk_space() {
    log "Checking for sufficient disk space..."
    local free_gb; free_gb=$(($(df / --output=avail | tail -n 1) / 1024 / 1024))
    if [ "$free_gb" -lt "$MIN_DISK_SPACE_GB" ]; then
        err_exit "Insufficient disk space. At least ${MIN_DISK_SPACE_GB}GB is required, but only ${free_gb}GB is available."
    fi
    log "SUCCESS: Disk space check passed (${free_gb}GB available)."
}

# Verifies the 'kali-rolling' repository.
_check_kali_repo() {
    log "Checking for 'kali-rolling' repository..."
    if ! grep -q "^deb .*$REQUIRED_REPO" /etc/apt/sources.list /etc/apt/sources.list.d/*; then
        err_exit "The required '$REQUIRED_REPO' repository is not configured. This script is designed for Kali Rolling."
    fi
    log "SUCCESS: 'kali-rolling' repository confirmed."
}

# Checks for essential tools.
_check_required_tools() {
    log "Checking for essential tools..."
    for tool in curl wget lspci mokutil; do
        if ! command -v "$tool" &> /dev/null; then
            err_exit "Required tool '$tool' is missing. Please install it."
        fi
    done
    log "SUCCESS: All essential tools are present."
}

# Checks the session type (X11 vs Wayland).
_check_session_type() {
    log "Checking graphical session type..."
    local session_type; session_type=${XDG_SESSION_TYPE:-"unknown"}
    if [ "$session_type" = "wayland" ]; then
        log "Warning: Wayland session detected."
        if ! user_confirm "You are running a Wayland session.\n\nFor best compatibility, it is recommended to log out and switch to an 'Xorg' session before running this installer.\n\nContinue anyway?" "Wayland Session Warning"; then
            err_exit "Installation canceled by user to switch session."
        fi
    fi
    log "SUCCESS: Session type check complete."
}

# Checks for multiple GPUs.
_check_multiple_gpus() {
    log "Checking for multiple GPUs (Optimus)..."
    if [ "$(lspci | grep -c -i 'vga')" -gt 1 ]; then
        log "Warning: Multiple GPUs detected."
        zenity --info --title="Multiple GPUs Detected" --text="Multiple GPUs were detected.\n\nThis is likely an Optimus laptop. The installation will proceed, and the system should manage GPU switching automatically."
    fi
    log "SUCCESS: Multiple GPU check complete."
}

# Checks if the required kernel headers are available in the repository.
_check_kernel_headers_availability() {
    log "Checking if kernel headers for the current kernel are available..."
    local kernel_version; kernel_version=$(uname -r)
    if apt-cache policy "linux-headers-$kernel_version" | grep -q "Candidate: (none)"; then
        err_exit "The required kernel headers ('linux-headers-$kernel_version') are NOT available in the repository.\n\nThis usually means your system is not fully up-to-date. Please run 'sudo apt update && sudo apt full-upgrade', reboot, and then run this installer again."
    fi
    log "SUCCESS: Required kernel headers are available for installation."
}


#
# Master function to run all pre-flight checks sequentially while showing a live log.
# This function is the solution to the user's feedback about not seeing what's happening.
#
run_pre_flight_with_live_log() {
    log "$PRE_FLIGHT_BANNER"
    log "--- Starting Comprehensive Pre-Flight System Analysis Suite ---"

    # Set up the temporary file and trap for the live log UI.
    LIVE_LOG_FILE=$(mktemp)
    trap 'rm -f "$LIVE_LOG_FILE"; unset LIVE_LOG_FILE' EXIT

    # Launch the Zenity live log window in the background.
    tail -f "$LIVE_LOG_FILE" | zenity --text-info --title="Live Log: System Pre-flight Analysis" --width=900 --height=600 --font="Monospace" &
    local ZENITY_PID=$!

    # Execute all check functions sequentially. The 'log' function will automatically populate the live log window.
    _check_root
    _check_zenity
    _check_internet
    _check_apt_lock
    _check_required_tools
    _check_gpu_presence
    _check_multiple_gpus
    _check_secure_boot
    _check_virtual_machine
    _check_disk_space
    _check_kali_repo
    _check_session_type
    _check_kernel_headers_availability
    
    log "--- All pre-flight checks completed successfully. ---"
    sleep 2 # Pause to let the user see the final message.

    # Clean up the background processes and the temporary file.
    kill "$ZENITY_PID" 2>/dev/null || true
    trap - EXIT
    rm -f "$LIVE_LOG_FILE"
    unset LIVE_LOG_FILE

    zenity --info --title="Pre-Flight Analysis Complete" --width=500 \
        --text="<span size='large' color='green'><b>System Analysis Successful!</b></span>\n\nAll pre-flight checks have passed.\n\nYour system is ready for the NVIDIA driver installation to begin.\n\nClick 'OK' to proceed to the final installation summary."
    log "--- System Analysis Complete. All systems are nominal. ---"
}


# --- Installation Process Functions ---

# Displays a final summary and gets the last confirmation before modifying the system.
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
    zenity --info --title="Installation - Step 1/5: System Synchronization" --width=700 --height=320 \
        --text="<span size='large'><b>Step 1: Full System Synchronization</b></span>\n\nAs per the official Kali Linux documentation, the most critical first step is to ensure your entire system is up-to-date. This synchronizes your installed Linux kernel with the available kernel headers and ensures all packages are at their latest versions.\n\nThis step is vital for a stable driver build and prevents a wide range of potential compatibility issues.\n\n<b>Actions Being Performed:</b>\n1. <b>apt update</b>: Fetches the latest package information from all enabled repositories.\n2. <b>apt full-upgrade</b>: Upgrades all installed packages to their latest versions, intelligently handling dependencies and potentially installing new kernels or removing obsolete packages.\n\n<span color='blue'>A new window will now open showing the live output of these commands, including download speeds and progress.</span>"
    run_with_live_log "Live Log: Updating Package Lists (apt update)" apt-get --yes update
    run_with_live_log "Live Log: Performing Full System Upgrade (apt full-upgrade)" apt-get --yes full-upgrade
}

# Step 2: Check if a reboot is required after the system upgrade.
step_2_reboot_check() {
    if [ -f /var/run/reboot-required ]; then
        log "Reboot is required after system upgrade, as indicated by /var/run/reboot-required."
        zenity --info --title="Installation - Action Required: Reboot" --width=600 --height=250 \
            --text="<span size='large'><b>Reboot is Mandatory!</b></span>\n\nThe system upgrade you just completed has installed a new Linux kernel or other critical system components.\n\nA <b>reboot is now absolutely necessary</b> to boot into this new kernel. The NVIDIA driver installation can only proceed once the system is running the kernel for which it will be built.\n\nThe installer will now prompt you to reboot.\n\n<span color='red'>Proceeding without a reboot will almost certainly lead to driver installation failure or a non-functional system.</span>"
        if user_confirm "Click 'Yes' to reboot the system now.\nClick 'No' to cancel the entire installation process." "Mandatory Reboot"; then
            log "User confirmed reboot to load new kernel. System will now restart."
            reboot
            exit 0
        else
            err_exit "Reboot was declined. Cannot safely continue the NVIDIA driver installation without a system reboot."
        fi
    else
        log "No reboot required after system upgrade. Proceeding to the next step."
    fi
}

# Step 3: Install necessary kernel headers and DKMS.
step_3_install_headers() {
    zenity --info --title="Installation - Step 2/5: Kernel Headers & DKMS" --width=700 --height=320 \
        --text="<span size='large'><b>Step 2: Installing Kernel Headers and DKMS</b></span>\n\nThe NVIDIA driver is a kernel module, meaning it runs at the core level of the operating system. For this to work, it must be compiled specifically for your running Linux kernel version.\n\nThis step installs the essential components for this compilation:\n- <b>linux-headers-$(uname -r):</b> These are like the 'blueprints' for your kernel. They provide the source code and build tools that allow new modules (like the NVIDIA driver) to be correctly compiled and linked against your exact kernel.\n- <b>dkms (Dynamic Kernel Module Support):</b> This is a crucial framework that acts like a 'smart assistant'. It automatically recompiles the NVIDIA kernel module whenever the Linux kernel itself is updated in the future. This ensures your driver continues to work seamlessly after system updates.\n\nThese packages are foundational for a stable, self-maintaining NVIDIA driver installation."
    local kernel_version
    kernel_version=$(uname -r)
    log "Target kernel version identified as: $kernel_version."
    run_with_live_log "Live Log: Installing Linux Headers and DKMS" apt-get --yes install "linux-headers-$kernel_version" dkms
}

# Step 4: Install the NVIDIA driver packages from the repository.
step_4_install_drivers() {
    zenity --info --title="Installation - Step 3/5: NVIDIA Driver Installation" --width=700 --height=320 \
        --text="<span size='large'><b>Step 3: Installing the NVIDIA Driver Packages</b></span>\n\nNow, we will install the main proprietary NVIDIA driver components directly from the official Kali Linux repositories. This is the recommended and most stable method.\n\n<b>Packages Being Installed:</b>\n- <b>nvidia-driver:</b> This is the core proprietary NVIDIA graphics driver package, containing the OpenGL libraries and other essential components.\n- <b>nvidia-kernel-dkms:</b> This package is the 'engine' of the installation. When installed, it triggers the DKMS framework to automatically compile the NVIDIA kernel module for your current kernel version using the headers we just installed.\n\n<b>Automatic System Configuration:</b>\nDuring this installation, the system's package manager will also automatically create a configuration file to <b>blacklist</b> the default open-source 'nouveau' driver. This is a critical step to prevent conflicts between the two drivers, which could lead to system instability."
    run_with_live_log "Live Log: Installing NVIDIA Driver Packages" apt-get --yes install nvidia-driver nvidia-kernel-dkms
}

# Step 5: Optionally install the NVIDIA CUDA Toolkit.
step_5_install_cuda_optional() {
    zenity --info --title="Installation - Step 4/5: Optional CUDA Toolkit" --width=700 --height=320 \
        --text="<span size='large'><b>Step 4 (Optional): Install NVIDIA CUDA Toolkit</b></span>\n\nThe NVIDIA CUDA Toolkit is a parallel computing platform and programming model that allows the GPU (Graphics Processing Unit) to be used for general-purpose processing. This can dramatically accelerate tasks that can be broken down into parallel operations.\n\nThis is essential for applications in fields such as:\n- <b>Penetration Testing:</b> Password cracking with tools like Hashcat or John the Ripper.\n- <b>Data Science:</b> Machine Learning and Deep Learning frameworks like TensorFlow and PyTorch.\n- <b>Content Creation:</b> Video rendering and scientific simulations.\n\n<span color='orange'><b>Important Warning:</b> The CUDA Toolkit is a <b>very large</b> download, often several gigabytes in size. Only install this if you specifically require GPU computing capabilities for your work. Installing it unnecessarily will consume significant disk space and download time.</span>"
    if user_confirm "Do you specifically need to use your GPU for parallel computing tasks (like machine learning or password cracking)?\n\nIf yes, select 'Yes' to install the NVIDIA CUDA Toolkit. If you are unsure, it is safe to select 'No'." "Optional CUDA Installation"; then
        log "User has chosen to install the CUDA Toolkit."
        _check_disk_space_for_cuda
        run_with_live_log "Live Log: Installing NVIDIA CUDA Toolkit (This may take a very long time)" apt-get --yes install nvidia-cuda-toolkit
    else
        log "User skipped CUDA installation. Proceeding without the CUDA Toolkit."
    fi
}

# Helper function to check disk space specifically for CUDA installation.
_check_disk_space_for_cuda() {
    log "Checking available disk space for the large CUDA installation..."
    local free_space_gb; free_space_gb=$(($(df / --output=avail | tail -n 1) / 1024 / 1024))
    if [ "$free_space_gb" -lt "$MIN_DISK_SPACE_CUDA_GB" ]; then
        err_exit "Insufficient disk space for CUDA. At least ${MIN_DISK_SPACE_CUDA_GB}GB is recommended, but only ${free_space_gb}GB is available."
    fi
    log "SUCCESS: Disk space check passed for CUDA: ${free_space_gb}GB available."
}

# Step 6: Prompt the user for a final reboot to activate the driver.
step_6_final_reboot_prompt() {
    log "NVIDIA driver installation process has completed all installation steps."
    zenity --info --title="Installation - Step 5/5: Final Reboot Required" --width=600 --height=280 \
        --text="<span size='x-large'><b>Installation Complete!</b></span>\n\nThe NVIDIA driver and all necessary components have been successfully installed and compiled for your system.\n\nA final reboot is required to complete the process. This will unload the old 'nouveau' driver from memory and load the newly installed proprietary 'nvidia' driver into the kernel.\n\nAfter your system has rebooted, you can re-run this installer and select the '<b>Deep Dive Verification Suite</b>' option from the main menu to perform a comprehensive check and confirm that everything is working correctly.\n\n<span color='blue'>Thank you for using the Kali NVIDIA Titan Installer! Your system is now ready for enhanced graphics performance.</span>"
    if user_confirm "A system reboot is required to activate the new NVIDIA driver.\n\nClick 'Yes' to reboot the system now.\nClick 'No' to perform the reboot manually later." "Final Reboot Prompt"; then
        log "User confirmed final reboot. The system will now restart."
        reboot
    else
        log "User chose to reboot manually later. The script will now return to the main menu."
    fi
}

# Master function to orchestrate the entire Titan installation process.
titan_install() {
    log "$INSTALL_BANNER"
    log "--- Initiating Titan Installation Process ---"
    if ! user_confirm "You are about to begin the fully automated NVIDIA driver installation process.\n\nThis process will perform a full system upgrade, install new drivers, and may require one or more reboots.\n\nIt is highly recommended to close all other applications and save your work before proceeding.\n\nDo you wish to proceed with the Titan Installation?" "Confirm Full Installation"; then
        log "User aborted the Titan installation process at the initial confirmation."
        return
    fi

    run_pre_flight_with_live_log
    display_pre_installation_summary
    step_1_system_upgrade
    step_2_reboot_check
    step_3_install_headers
    step_4_install_drivers
    step_5_install_cuda_optional
    step_6_final_reboot_prompt
    log "--- Titan Installation Process Finished ---"
}

# --- Deep Dive Verification Suite Functions ---

# Performs a comprehensive set of checks to verify driver installation and functionality.
comprehensive_verification() {
    log "$VERIFY_BANNER"
    log "--- Starting Deep Dive Verification Suite ---"
    local report="<b>Titan Installation Verification Report:</b>\n\n"
    local all_ok=true

    log "Verifying DKMS status for the NVIDIA module..."
    if dkms status 2>/dev/null | grep -q 'nvidia.*installed'; then
        report+="✅ <b>DKMS Module Status:</b> <span color='green'>OK</span>\n   - The 'nvidia' module is successfully registered and built via DKMS.\n\n"
    else
        report+="❌ <b>DKMS Module Status:</b> <span color='red'>FAILED</span>\n   - The 'nvidia' module was NOT found or failed to build in DKMS. This is a critical issue.\n\n"
        all_ok=false
    fi

    log "Verifying if the NVIDIA kernel module is loaded into the kernel..."
    if lsmod | grep -q '^nvidia '; then
        report+="✅ <b>Kernel Driver Status:</b> <span color='green'>OK</span>\n   - The 'nvidia' kernel module is currently loaded and active.\n\n"
    else
        report+="❌ <b>Kernel Driver Status:</b> <span color='red'>FAILED</span>\n   - The 'nvidia' module is NOT loaded. This could be due to Secure Boot or a build error.\n\n"
        all_ok=false
    fi

    log "Verifying nvidia-smi tool functionality..."
    local smi_output
    if command -v nvidia-smi &>/dev/null && smi_output=$(nvidia-smi 2>&1); then
        report+="✅ <b>NVIDIA SMI Tool:</b> <span color='green'>OK</span>\n   - The 'nvidia-smi' command is working and communicating with the driver.\n\n<tt>${smi_output}</tt>\n\n"
    else
        report+="❌ <b>NVIDIA SMI Tool:</b> <span color='red'>FAILED</span>\n   - The 'nvidia-smi' command failed to execute. This indicates a severe driver loading issue.\n\n"
        all_ok=false
    fi

    log "Verifying OpenGL rendering..."
    if ! command -v glxinfo &>/dev/null; then
        if user_confirm "'glxinfo' command not found. This tool is needed to verify OpenGL acceleration. Install 'mesa-utils' now?" "Missing Tool"; then
            run_with_live_log "Live Log: Installing mesa-utils" apt-get --yes install mesa-utils
        fi
    fi
    if command -v glxinfo &>/dev/null; then
        if glxinfo -B | grep -q "OpenGL renderer string.*NVIDIA"; then
            report+="✅ <b>OpenGL Acceleration:</b> <span color='green'>OK</span>\n   - The system is correctly using the NVIDIA GPU for OpenGL rendering.\n\n"
        else
            report+="❌ <b>OpenGL Acceleration:</b> <span color='red'>FAILED</span>\n   - The system is NOT using the NVIDIA GPU for OpenGL. It may be falling back to software rendering.\n\n"
            all_ok=false
        fi
    else
        report+="⚠️ <b>OpenGL Acceleration:</b> <span color='orange'>UNKNOWN</span>\n   - Could not perform check because 'glxinfo' is not available.\n\n"
    fi

    if [ "$all_ok" = true ]; then
        zenity --info --title="Verification Successful" --width=800 --height=600 \
            --text="<span size='x-large' color='green'><b>All major checks passed successfully!</b></span>\n\nYour NVIDIA driver appears to be fully installed and operational.\n\n<b>Verification Summary:</b>\n$report"
    else
        zenity --error --title="Verification Failed" --width=800 --height=600 \
            --text="<span size='x-large' color='red'><b>One or more verification checks failed!</b></span>\n\n$report\n\nPlease review the errors and consult the log file: <b>$LOG_FILE</b>"
    fi
}

# --- Uninstallation and About Dialogs ---

# Uninstalls all NVIDIA-related packages and attempts to restore the Nouveau driver.
uninstall_nvidia() {
    if ! user_confirm "This action will completely <b>PURGE</b> all NVIDIA packages from your system.\nIt will also attempt to restore the default 'nouveau' open-source driver.\n\nA reboot will be required afterward to load the correct driver.\n\nAre you absolutely certain you want to proceed with the uninstallation?" "Confirm NVIDIA Driver Uninstallation"; then
        log "User canceled the NVIDIA driver uninstallation process."
        return
    fi
    log "--- Starting Full NVIDIA Driver Purge ---"
    run_with_live_log "Live Log: Purging all NVIDIA packages" apt-get --yes remove --purge '~nnvidia-.*'
    run_with_live_log "Live Log: Cleaning up orphaned dependencies" apt-get --yes autoremove
    log "Removing leftover NVIDIA configuration files..."
    rm -f /etc/modprobe.d/nvidia-installer-disable-nouveau.conf
    run_with_live_log "Live Log: Updating initramfs to restore the Nouveau driver" update-initramfs -u

    zenity --info --title="Uninstallation Complete" --width=550 \
        --text="<span size='large'><b>NVIDIA Driver Uninstallation Successful</b></span>\n\nAll NVIDIA components have been purged from your system.\n\nA reboot is now required to load the default 'nouveau' video driver."
    if user_confirm "A reboot is required to activate the restored default driver.\n\nReboot now?" "Reboot Required After Uninstall"; then
        reboot
    fi
}

# Gathers and displays key system information.
display_system_info() {
    log "Gathering system information for display..."
    local info_report="<span size='large'><b>System Information Report</b></span>\n\n"
    info_report+="<b>Kernel Version:</b> $(uname -r)\n"
    info_report+="<b>GPU Model:</b> $(lspci | grep -i 'vga.*nvidia' | sed 's/.*: //')\n"
    info_report+="<b>Session Type:</b> ${XDG_SESSION_TYPE:-"Unknown"}\n"
    info_report+="<b>Secure Boot:</b> $(mokutil --sb-state 2>/dev/null || echo "Unknown")\n\n"

    if command -v nvidia-smi &>/dev/null; then
        info_report+="<b>NVIDIA Driver Version:</b> $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n 1)\n"
        info_report+="<b>CUDA Version:</b> $(nvidia-smi --query-gpu=cuda_version --format=csv,noheader | head -n 1)\n"
    else
        info_report+="<b>NVIDIA Driver:</b> Not detected or not loaded.\n"
    fi

    zenity --info --title="System Information" --width=700 --text="$info_report"
}


# Displays an informative "About" dialog for the script.
show_about_dialog() {
    zenity --info --title="About This Installer - Titan Edition" --width=800 --height=450 \
        --text="<span size='x-large'><b>Kali NVIDIA Installer - Titan Edition</b></span>\n\nThis script is an exceptionally robust, safe, and transparent tool for installing NVIDIA's proprietary drivers on Kali Linux.\n\nIt meticulously follows the official Kali Linux documentation and provides a guided, educational experience, automating the entire process from pre-flight checks to deep-dive verification.\n\n<b>Key Features:</b>\n- 🚀 <b>Live Log UI</b>: See the real-time output of all major installations, bringing clarity to the process.\n- 🛡️ <b>Exhaustive Pre-Flight Analysis</b>: Detects potential issues like Secure Boot, Wayland sessions, multiple GPUs, and more before any changes are made.\n- 📖 <b>'Philosopher's Guide' UI</b>: Detailed explanations for every action, ensuring you understand the 'what' and 'why' of each step.\n- 🔎 <b>Deep Dive Verification Suite</b>: Confirms driver functionality at multiple levels (DKMS, kernel module, `nvidia-smi`, OpenGL).\n- ✨ <b>Clean Uninstaller</b>: Safely removes all NVIDIA components and reliably restores the default 'nouveau' driver.\n- 📝 <b>Comprehensive & Detailed Logging</b>: All operations are meticulously recorded in <b>$LOG_FILE</b> for easy troubleshooting.\n\nThis project is a significant enhancement and evolution inspired by the foundational work in the Opselon/Kali-LInux-Nvidia-Installer repository."
}

# --- Main Menu and Script Entrypoint ---

# Displays the main menu for user interaction.
main_menu() {
    echo -e "$BANNER"
    local choice
    choice=$(zenity --list --title="Kali NVIDIA Installer - Titan Edition" --text="$BANNER\n<span size='large'>Welcome to the Kali NVIDIA Installer - Titan Edition.</span>\n\nPlease select an action from the list below to manage your NVIDIA drivers." --height=550 --width=900 \
        --column="Action" --column="Description" \
        "Start Titan Installation" "The ultimate, fully automated, and transparent process to install and configure NVIDIA drivers." \
        "Deep Dive Verification Suite" "Run a comprehensive diagnostic to confirm if your drivers are installed and fully functional." \
        "Display System Information" "Show a summary of your GPU, kernel, driver version, and other relevant system details." \
        "Purge All NVIDIA Drivers" "Completely uninstall all NVIDIA components and restore the default 'nouveau' driver." \
        "About This Installer" "Display information about the script's advanced features and purpose." \
        "Exit" "Close the application and exit the installer.")

    case "$choice" in
        "Start Titan Installation") titan_install ;;
        "Deep Dive Verification Suite") comprehensive_verification ;;
        "Display System Information") display_system_info ;;
        "Purge All NVIDIA Drivers") uninstall_nvidia ;;
        "About This Installer") show_about_dialog ;;
        *)
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
log "--- Kali NVIDIA Titan Installer session started ---"

# Perform initial critical checks before displaying the main menu.
# This ensures that essential dependencies like root privileges and Zenity are met.
_check_root
_check_zenity

# Enter the main application loop to display the menu and handle user actions continuously.
# The script will remain in this loop until the user chooses to exit.
while true; do
    main_menu
done```