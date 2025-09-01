#!/usr/bin/env bash
#
# kali-nvidia-installer-leviathan.sh
#
# An exceptionally intelligent, safe, and GUI-driven NVIDIA Driver Installation Suite for Kali Linux.
# This project elevates the original Opselon installer to a new level of robustness and user experience,
# automating the entire official process from 0 to 100. It performs deep system analysis, explains
# every action, and verifies its success with a comprehensive diagnostic suite.
#
# License: MIT
#

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

# ANSI color codes for terminal output
readonly COLOR_RESET="\033[0m"
readonly COLOR_RED="\033[0;31m"
readonly COLOR_GREEN="\033[0;32m"
readonly COLOR_YELLOW="\033[0;33m"
readonly COLOR_BLUE="\033[0;34m"
readonly COLOR_CYAN="\033[0;36m"
readonly COLOR_BOLD="\033[1m"

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

# Centralized logging function with terminal colorization.
log() {
    local msg="$*"
    local timestamp
    timestamp=$(date --iso-8601=seconds)
    local log_prefix_file="${timestamp} | ${PROGNAME}: " # Prefix for the log file
    local log_prefix_term="${timestamp} | ${COLOR_BOLD}${PROGNAME}:${COLOR_RESET} " # Prefix for terminal, with color
    local terminal_output=""

    # Determine color and format for terminal output based on message type.
    if [[ "$msg" == FATAL* || "$msg" == ERROR* ]]; then
        terminal_output="${COLOR_RED}${log_prefix_term}${COLOR_BOLD}${msg}${COLOR_RESET}"
    elif [[ "$msg" == SUCCESS* ]]; then
        terminal_output="${COLOR_GREEN}${log_prefix_term}${COLOR_BOLD}${msg}${COLOR_RESET}"
    elif [[ "$msg" == EXEC* ]]; then
        terminal_output="${COLOR_CYAN}${log_prefix_term}${COLOR_BOLD}${msg}${COLOR_RESET}"
    elif [[ "$msg" == "Warning:"* ]]; then
        terminal_output="${COLOR_YELLOW}${log_prefix_term}${msg}${COLOR_RESET}"
    elif [[ "$msg" == "---"* ]]; then # Section headers
        terminal_output="${COLOR_BLUE}${log_prefix_term}${COLOR_BOLD}${msg}${COLOR_RESET}"
    else # General informational messages
        terminal_output="${log_prefix_term}${msg}${COLOR_RESET}"
    fi

    # Log to file (always plain text for consistency and easier parsing).
    echo "${log_prefix_file}${msg}" | tee -a "$LOG_FILE"
    # Print to terminal with color for immediate feedback.
    echo -e "${terminal_output}"
}

# Centralized error handling and exit function. Displays a detailed Zenity error.
err_exit() {
    local msg="$1"
    log "FATAL ERROR: $msg"
    # Enhance the Zenity error message with more detail and color.
    [ -n "$ZENITY" ] && zenity --error --title="Installer Critical Error" --width=550 --height=200 \
        --text="<span size='large' color='red'><b>Installer Aborted!</b></span>\n\nA critical error occurred:\n\n<b>$msg</b>\n\nThis prevents the NVIDIA driver installation from proceeding safely.\n\nPlease review the log file for comprehensive details and troubleshooting steps:\n<b>$LOG_FILE</b>"
    exit 1
}

# Run a command, log it, and exit if it fails. Ensures all output goes to log.
run_or_die() {
    log "EXEC: $*"
    # Redirect both stdout and stderr of the command to the log file, and check its exit status.
    if ! "$@" >>"$LOG_FILE" 2>&1; then
        # If the command fails, call err_exit which will display a Zenity error.
        err_exit "The command '$*' failed. Check the log file for details."
    fi
    log "SUCCESS: $*"
}

# Run a long-running command with a graphical progress bar and detailed feedback.
run_with_progress() {
    local title="$1"
    shift
    log "EXEC (Progress): $*"
    # Capture command output (stdout & stderr), tee it to the log file, and pipe it to Zenity for progress display.
    # PIPESTATUS[0] checks the exit status of the command itself, before the pipe.
    # --auto-close is removed to keep the dialog open after completion.
    ( "$@" 2>&1 | tee -a "$LOG_FILE" ) | zenity --progress --title="$title" --text="<b><span color='blue'>Task:</span> $title</b>\n\nRunning: <i>$*</i>\n\n<span color='gray'>(This operation may take some time. The dialog will remain open until this task is complete. For real-time, detailed output, please consult the log file.)</span>" --pulsate --auto-kill --width=700
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        # If the command failed, trigger a critical error exit.
        err_exit "The command '$*' failed during a progress operation. Check the log."
    fi
    log "SUCCESS: $*"
}

# Standardized function for asking Yes/No confirmation questions.
user_confirm() {
    local question_text="$1"
    local title="$2:- Confirmation"
    # Use Pango markup for better readability in the confirmation dialog.
    zenity --question --title="$title" --width=500 --height=180 \
        --text="<span size='large'><b>$title</b></span>\n\n$question_text\n\n<span color='gray'><i>(Please review carefully before confirming.)</i></span>"
}

# --- Pre-Flight System Analysis Suite -----------------------------------------

# Checks if the script is being run with root privileges.
_check_root() {
    log "Verifying root privileges..."
    if [ "$EUID" -ne 0 ]; then
        # If not root, exit with a clear message. The script requires root.
        err_exit "This script requires root privileges. Please run with sudo or as root."
    fi
    log "Root privileges confirmed."
}

# Checks if Zenity is installed and attempts to install it if missing.
_check_zenity() {
    log "Verifying Zenity availability..."
    if [ -z "$ZENITY" ]; then
        log "Zenity not found. Attempting emergency installation via apt-get..."
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
            err_exit "Zenity installation reported success, but the 'zenity' command is still not found. Cannot continue without GUI."
        fi
        log "Zenity installed successfully. Proceeding with the script."
    fi
    log "Zenity is available."
}

# Checks for a stable internet connection.
_check_internet() {
    log "Verifying internet connectivity..."
    # Ping a reliable IP address (like Google's DNS) twice.
    if ! ping -c 2 8.8.8.8 >/dev/null 2>&1; then
        # If ping fails, exit with an informative error.
        err_exit "No internet connection detected. This installer requires an active internet connection to download packages and updates. Please check your network configuration."
    fi
    log "Internet connection confirmed."
}

# Checks if the APT package manager is currently locked by another process.
_check_apt_lock() {
    log "Verifying APT package manager is not locked..."
    # Check for dpkg and apt list locks.
    if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
        # If locks are found, inform the user and exit.
        err_exit "APT is locked by another process. Please close any other package managers (e.g., Synaptic, another terminal running 'apt', or unattended-upgrades) and try again."
    fi
    log "APT is not locked."
}

# Scans the system for the presence of an NVIDIA GPU.
_check_gpu_presence() {
    log "Scanning system for NVIDIA GPU..."
    # Use lspci to search for VGA controller entries related to NVIDIA.
    if ! lspci | grep -q -i 'vga.*nvidia'; then
        log "Warning: No NVIDIA GPU was automatically detected via 'lspci'."
        # If no GPU is found, ask the user for confirmation before proceeding.
        if ! user_confirm "No NVIDIA GPU was automatically detected using 'lspci'.\n\nThis is highly unusual for an NVIDIA driver installation and proceeding might be unproductive.\n\nDo you wish to continue anyway at your own risk?" "Hardware Check Warning"; then
            err_exit "Installation canceled by user. No NVIDIA GPU detected."
        fi
    else
        log "NVIDIA GPU detected successfully."
    fi
}

# Checks the Secure Boot status and warns the user if it's enabled.
_check_secure_boot() {
    log "Checking Secure Boot status..."
    # Use mokutil to query the Secure Boot state.
    if mokutil --sb-state 2>/dev/null | grep -q enabled; then
        log "Warning: Secure Boot is enabled."
        # Display a detailed warning to the user explaining the implications.
        zenity --warning --title="Security Alert: Secure Boot Enabled" --width=600 --height=280 \
            --text="<span size='large' color='red'><b>Security Alert: Secure Boot is ACTIVE!</b></span>\n\nThe NVIDIA driver modules that this script compiles (using DKMS) are <b>not cryptographically signed</b> by default. Because of this, the kernel will <b>block</b> them from loading when Secure Boot is enabled, preventing the NVIDIA driver from functioning.\n\n<b>Recommended Action:</b>\n1. Exit this installer now.\n2. Reboot your computer and enter your UEFI/BIOS settings.\n3. Disable the 'Secure Boot' option.\n4. Reboot back into Kali and re-run this installer.\n\n<span color='orange'><b>Alternative for Advanced Users:</b></span> You may proceed if you are an advanced user planning to manually sign the NVIDIA kernel modules with your own Machine Owner Key (MOK) after they are built."
        # Ask for user confirmation to proceed despite the warning.
        if ! user_confirm "Do you understand the risks associated with Secure Boot and wish to continue anyway?" "Secure Boot Confirmation"; then
            err_exit "Installation canceled by user due to Secure Boot being enabled."
        fi
    else
        log "Secure Boot is disabled or not supported. Proceeding without Secure Boot warning."
    fi
}

# Checks if the script is running inside a virtual machine environment.
_check_virtual_machine() {
    log "Checking for virtualization environment..."
    local vm
    # Use systemd-detect-virt to identify the virtualization type.
    vm=$(systemd-detect-virt)
    if [ "$vm" != "none" ]; then
        log "Warning: Virtual machine environment '$vm' detected."
        # Inform the user about potential issues with VMs and GPU passthrough.
        zenity --warning --title="Virtual Machine Detected" --width=550 --height=250 \
            --text="<span size='large' color='orange'><b>Virtual Machine Detected</b></span>\n\nThis script has detected that it is running inside a virtual machine environment (<b>$vm</b>).\n\nInstalling NVIDIA drivers within a VM is a complex topic that typically requires specific GPU Passthrough (IOMMU) configuration on the host system, which is beyond the scope of this installer.\n\nStandard driver installation within a VM will likely fail or have no effect on your virtual graphics performance.\n\nDo you wish to proceed with the installation at your own risk?" "Virtualization Warning"
        # If the user cancels, exit.
        if [ $? -ne 0 ]; then
            err_exit "Installation canceled by user due to detected VM environment."
        fi
    else
        log "Not running in a virtual machine environment."
    fi
}

# Checks if there is sufficient free disk space on the root partition.
_check_disk_space() {
    log "Checking available disk space on '/' ..."
    # Get available space in kilobytes and convert to gigabytes.
    local free_space_kb
    free_space_kb=$(df / --output=avail | tail -n 1)
    local free_space_gb=$((free_space_kb / 1024 / 1024))

    # Check against the minimum requirement for base installation.
    if [ "$free_space_gb" -lt "$MIN_DISK_SPACE_GB" ]; then
        err_exit "Insufficient disk space. You have only ${free_space_gb}GB free, but at least ${MIN_DISK_SPACE_GB}GB is required for the NVIDIA driver installation and its dependencies."
    fi
    log "Disk space check passed: ${free_space_gb}GB available on root partition."
}

# Verifies that the system is configured to use the 'kali-rolling' repository.
_check_kali_repo() {
    log "Verifying 'kali-rolling' repository is enabled..."
    # Check sources.list and sources.list.d for lines matching the kali-rolling repository.
    if ! grep -q "^deb .*$REQUIRED_REPO" /etc/apt/sources.list /etc/apt/sources.list.d/*; then
        # If not found, exit with an error.
        err_exit "The required '$REQUIRED_REPO' repository is not configured in your APT sources.\nThis script is designed specifically for Kali Rolling. Please ensure your system is correctly set up with the 'kali-rolling' repository enabled."
    fi
    log "'kali-rolling' repository confirmed."
}

# Master function to run all pre-flight checks sequentially with progress feedback.
run_all_pre_flight_checks() {
    log "--- Starting Comprehensive Pre-Flight System Analysis Suite ---"
    # Use a Zenity progress bar to show the progress of all checks.
    (
        echo "0"; echo "# Initializing Analysis..."
        # Execute each check function. If any fails, err_exit will terminate the script.
        _check_root
        echo "5"; echo "# Verifying Zenity GUI..."
        _check_zenity
        echo "15"; echo "# Checking Internet Connection..."
        _check_internet
        echo "25"; echo "# Checking APT Package Manager Locks..."
        _check_apt_lock
        echo "35"; echo "# Scanning for NVIDIA Hardware..."
        _check_gpu_presence
        echo "50"; echo "# Checking Secure Boot Status..."
        _check_secure_boot
        echo "65"; echo "# Detecting Virtualization Environment..."
        _check_virtual_machine
        echo "80"; echo "# Analyzing Available Disk Space..."
        _check_disk_space
        echo "90"; echo "# Verifying Kali Repository Configuration..."
        _check_kali_repo
        echo "100"; echo "# All pre-flight checks completed successfully. System appears ready."
        sleep 1 # Short pause before closing progress dialog
    ) | zenity --progress --title="System Pre-flight Analysis" --width=650 --height=150 --auto-close --auto-kill
    log "--- System Analysis Complete. All systems nominal. ---"
}

# --- "Philosopher's Guide" Installation Process Functions ----------------------

# Step 1: Perform a full system upgrade.
step_1_system_upgrade() {
    # Provide a detailed explanation of the importance of this step.
    zenity --info --title="Installation - Step 1/5: System Synchronization" --width=650 --height=300 \
        --text="<span size='large'><b>Step 1: Full System Synchronization</b></span>\n\nAs per the official Kali Linux documentation, the most critical first step is to ensure your entire system is up-to-date. This synchronizes your installed Linux kernel with the available kernel headers and ensures all packages are at their latest versions.\n\nThis step is vital for a stable driver build and prevents compatibility issues.\n\n<b>Actions Performed:</b>\n1. <b>apt update</b>: Fetches the latest package information from all enabled repositories.\n2. <b>apt full-upgrade</b>: Upgrades all installed packages to their latest versions, intelligently handling dependencies and potentially installing new kernels or removing obsolete packages.\n\n<span color='orange'><b>Important Note:</b> This process can take a significant amount of time, depending on your system's current state and internet speed. Please be patient and do not interrupt it.</span>"
    # Execute the upgrade commands with progress indication.
    run_with_progress "Updating package lists (apt update)..." apt-get update -y
    run_with_progress "Performing full system upgrade (apt full-upgrade)..." apt-get full-upgrade -y
}

# Step 2: Check if a reboot is required after the system upgrade.
step_2_reboot_check() {
    # Check for the existence of the reboot-required flag file.
    if [ -f /var/run/reboot-required ]; then
        log "Reboot required after system upgrade."
        # Inform the user that a reboot is mandatory.
        zenity --info --title="Installation - Action Required: Reboot" --width=550 --height=220 \
            --text="<span size='large'><b>Reboot is Mandatory!</b></span>\n\nThe system upgrade you just completed has installed a new Linux kernel or critical system components.\n\nA <b>reboot is now absolutely necessary</b> to load this new kernel and ensure compatibility with the NVIDIA driver installation that follows.\n\nThe installer will now prompt you to reboot.\n\n<span color='red'>Proceeding without a reboot will almost certainly lead to driver installation failure or a non-functional system.</span>"
        # Ask for user confirmation to reboot.
        if user_confirm "Click 'Yes' to reboot the system now.\nClick 'No' to cancel the entire installation process." "Mandatory Reboot"; then
            log "User confirmed reboot to load new kernel."
            # Initiate reboot and exit the script.
            reboot
            exit 0 # Script will terminate after reboot command
        else
            # If user declines, exit with an error.
            err_exit "Reboot was declined. Cannot safely continue the NVIDIA driver installation without a system reboot."
        fi
    else
        log "No reboot required after system upgrade. Proceeding to the next step."
    fi
}

# Step 3: Install necessary kernel headers and DKMS.
step_3_install_headers() {
    # Explain the role of kernel headers and DKMS.
    zenity --info --title="Installation - Step 2/5: Kernel Headers & DKMS" --width=650 --height=280 \
        --text="<span size='large'><b>Step 2: Installing Kernel Headers and DKMS</b></span>\n\nThe NVIDIA driver is a kernel module, not a standard application. For it to function correctly, it must be compiled specifically for your running Linux kernel version.\n\nThis step installs the essential components for this compilation:\n- <b>linux-headers-$(uname -r):</b> Provides the necessary source code and build tools for your exact kernel version.\n- <b>dkms (Dynamic Kernel Module Support):</b> A crucial framework that automatically recompiles kernel modules (like NVIDIA's) whenever the Linux kernel itself is updated. This ensures your driver stays compatible after kernel upgrades.\n\nThese packages are foundational for a stable, self-maintaining NVIDIA driver installation."
    local kernel_version
    kernel_version=$(uname -r)
    log "Target kernel version identified as: $kernel_version."
    # Install the packages using run_with_progress.
    run_with_progress "Installing Linux Headers (linux-headers-$(uname -r)) and DKMS..." apt-get install -y "linux-headers-$kernel_version" dkms
}

# Step 4: Install the NVIDIA driver packages from the repository.
step_4_install_drivers() {
    # Explain the core driver installation process.
    zenity --info --title="Installation - Step 3/5: NVIDIA Driver Installation" --width=650 --height=300 \
        --text="<span size='large'><b>Step 3: Installing the NVIDIA Driver Packages</b></span>\n\nNow, we install the main proprietary NVIDIA driver components directly from the Kali Linux repositories.\n\n<b>Packages Installed:</b>\n- <b>nvidia-driver:</b> This is the core proprietary NVIDIA graphics driver package.\n- <b>nvidia-kernel-dkms:</b> This package is intelligent; when installed, it triggers DKMS to automatically compile the NVIDIA kernel module specifically for your current kernel version.\n\n<b>Automatic Configuration:</b>\nDuring this installation, the system will also automatically create a configuration file to <b>blacklist</b> the default open-source 'nouveau' driver. This is crucial to prevent conflicts between the two drivers.\n\n<span color='blue'>The installer will now download and install these essential components.</span>"
    # Execute the driver installation commands.
    run_with_progress "Installing nvidia-driver and nvidia-kernel-dkms..." apt-get install -y nvidia-driver nvidia-kernel-dkms
}

# Step 5: Optionally install the NVIDIA CUDA Toolkit.
step_5_install_cuda_optional() {
    # Explain the purpose and size of CUDA.
    zenity --info --title="Installation - Step 4/5: Optional CUDA Toolkit" --width=650 --height=300 \
        --text="<span size='large'><b>Step 4 (Optional): Install NVIDIA CUDA Toolkit</b></span>\n\nThe NVIDIA CUDA Toolkit is a parallel computing platform and programming model developed by NVIDIA. It enables the GPU to be used for general-purpose processing, significantly accelerating tasks that can be parallelized.\n\nThis is essential for applications such as:\n- Password cracking (e.g., Hashcat, John the Ripper with GPU acceleration)\n- Machine Learning and Deep Learning frameworks (TensorFlow, PyTorch)\n- Scientific simulations, data analysis, and video rendering.\n\n<span color='orange'><b>Important Warning:</b> The CUDA Toolkit is a <b>very large</b> download, often several gigabytes in size. Only install this if you specifically require GPU computing capabilities. Installing it unnecessarily will consume significant disk space and download time.</span>"
    # Ask the user if they want to install CUDA.
    if user_confirm "Do you specifically need to use your GPU for parallel computing tasks (like machine learning or password cracking)?\n\nIf yes, select 'Yes' to install the NVIDIA CUDA Toolkit." "Optional CUDA Installation"; then
        log "User chose to install CUDA Toolkit."
        # Perform a disk space check specifically for CUDA if the user agrees.
        _check_disk_space_for_cuda
        # Install the CUDA package.
        run_with_progress "Installing CUDA Toolkit (nvidia-cuda-toolkit)... This may take a very long time." apt-get install -y nvidia-cuda-toolkit
    else
        log "User skipped CUDA installation. Proceeding without CUDA."
    fi
}

# Helper function to check disk space specifically for CUDA installation.
_check_disk_space_for_cuda() {
    log "Checking available disk space for CUDA installation..."
    local free_space_kb
    free_space_kb=$(df / --output=avail | tail -n 1)
    local free_space_gb=$((free_space_kb / 1024 / 1024))
    # Check against the higher requirement for CUDA.
    if [ "$free_space_gb" -lt "$MIN_DISK_SPACE_CUDA_GB" ]; then
        err_exit "Insufficient disk space for CUDA. You have ${free_space_gb}GB free, but at least ${MIN_DISK_SPACE_CUDA_GB}GB is recommended for the CUDA toolkit and its associated libraries."
    fi
    log "Disk space check passed for CUDA: ${free_space_gb}GB available on root partition."
}

# Step 6: Prompt the user for a final reboot to activate the driver.
step_6_final_reboot_prompt() {
    log "NVIDIA driver installation process has completed all installation steps."
    # Inform the user that a reboot is needed for activation.
    zenity --info --title="Installation - Step 5/5: Final Reboot Required" --width=550 --height=250 \
        --text="<span size='large'><b>Installation Complete!</b></span>\n\nThe NVIDIA driver and all necessary components have been successfully installed and compiled for your system.\n\nA final reboot is required to unload the old 'nouveau' driver and load the new 'nvidia' driver into the kernel.\n\nAfter rebooting, you can re-run this installer and select the 'Deep Dive Verification Suite' option from the main menu to confirm everything is working correctly.\n\n<span color='blue'>Thank you for using the Kali NVIDIA Leviathan Installer! Your system is now ready for enhanced graphics performance.</span>"
    # Ask if the user wants to reboot now.
    if user_confirm "A system reboot is required to activate the new NVIDIA driver.\n\nClick 'Yes' to reboot the system now.\nClick 'No' to perform the reboot manually later." "Final Reboot Prompt"; then
        log "User confirmed final reboot."
        # Initiate reboot.
        reboot
    else
        log "User chose to reboot manually later."
    fi
}

# Master function to orchestrate the entire Leviathan installation process.
leviathan_install() {
    log "--- Initiating Leviathan Installation Process ---"
    # Initial confirmation before starting the entire process.
    if ! user_confirm "You are about to begin the fully automated NVIDIA driver installation process.\n\nThis process will perform a full system upgrade, install NVIDIA drivers, and may require one or more reboots.\n\nIt is highly recommended to close all other applications and save your work before proceeding.\n\nDo you wish to proceed with the Leviathan Installation?" "Confirm Full Installation"; then
        log "User aborted the Leviathan installation process at the initial confirmation."
        return # Exit the function if user cancels.
    fi

    # Run all pre-flight checks first. This ensures the system is ready.
    run_all_pre_flight_checks

    # Execute the installation steps sequentially, guiding the user through each phase.
    step_1_system_upgrade
    step_2_reboot_check
    step_3_install_headers
    step_4_install_drivers
    step_5_install_cuda_optional
    step_6_final_reboot_prompt
    log "--- Leviathan Installation Process Finished ---"
}

# --- Deep Dive Verification Suite Functions -----------------------------------

# Performs a comprehensive set of checks to verify driver installation and functionality.
comprehensive_verification() {
    log "--- Starting Deep Dive Verification Suite ---"
    local report="<b>Leviathan Installation Verification Report:</b>\n\n"
    local all_ok=true # Flag to track overall success

    # Check 1: DKMS Status - Verifies if the NVIDIA module is registered and built.
    log "Verifying DKMS status for NVIDIA module..."
    if dkms status 2>/dev/null | grep -q 'nvidia.*installed'; then
        # If found and installed, append a success message to the report.
        report+="✅ <b>DKMS Module Status:</b> OK\n   - The 'nvidia' module is successfully registered and built via DKMS.\n\n"
    else
        # If not found or failed to build, append a failure message and set overall_ok to false.
        report+="❌ <b>DKMS Module Status:</b> FAILED\n   - The 'nvidia' module was NOT found or failed to build in DKMS. This is a critical issue.\n   - If you recently rebooted, DKMS might still be building. Check the log for details.\n\n"
        all_ok=false
    fi

    # Check 2: Kernel Module Loaded - Verifies if the 'nvidia' module is active in the running kernel.
    log "Verifying if NVIDIA kernel module is loaded..."
    if lsmod | grep -q '^nvidia '; then
        # If loaded, append a success message.
        report+="✅ <b>Kernel Driver Status:</b> OK\n   - The 'nvidia' kernel module is currently loaded and active.\n\n"
    else
        # If not loaded, indicate a potential problem and set overall_ok to false.
        report+="❌ <b>Kernel Driver Status:</b> FAILED\n   - The 'nvidia' module is NOT loaded. This could be due to Secure Boot issues, a build error, or a failure to reboot after installation.\n   - Check 'dmesg' output for specific loading errors.\n\n"
        all_ok=false
    fi

    # Check 3: NVIDIA SMI Tool - Verifies if nvidia-smi command works and reports GPU status.
    log "Verifying nvidia-smi tool functionality..."
    local smi_output
    # Attempt to run nvidia-smi and capture its output.
    if command -v nvidia-smi &>/dev/null && smi_output=$(nvidia-smi 2>&1); then
        # If successful, append the output to the report.
        report+="✅ <b>NVIDIA SMI Tool:</b> OK\n   - The 'nvidia-smi' command is working and successfully communicating with the driver.\n\n<tt>${smi_output}</tt>\n\n"
    else
        # If nvidia-smi fails, indicate an error.
        report+="❌ <b>NVIDIA SMI Tool:</b> FAILED\n   - The 'nvidia-smi' command failed to execute or reported an error.\n   - This usually indicates a severe driver loading or compatibility issue.\n\n"
        all_ok=false
    fi

    # Check 4: OpenGL Rendering - Verifies if the system is using the NVIDIA GPU for graphics.
    log "Verifying OpenGL rendering and GPU usage..."
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
        # Grep the output for "NVIDIA" to confirm it's being used.
        if glxinfo -B | grep -q "OpenGL renderer string.*NVIDIA"; then
            # Success: NVIDIA GPU is reported as the renderer.
            report+="✅ <b>OpenGL Acceleration:</b> OK\n   - The system is correctly reporting the NVIDIA GPU as the OpenGL renderer.\n\n"
        else
            # Failure: System might be falling back to software rendering or a different GPU.
            report+="❌ <b>OpenGL Acceleration:</b> FAILED\n   - The system is NOT correctly reporting the NVIDIA GPU for OpenGL rendering.\n   - This might mean the driver isn't loaded, or a fallback driver is in use.\n\n"
            all_ok=false
        fi
    else
        # Warning if glxinfo is still not available.
        report+="⚠️ <b>OpenGL Acceleration:</b> UNKNOWN\n   - Could not perform the check because 'glxinfo' is unavailable.\n\n"
    fi

    # Display the final verification report to the user.
    if [ "$all_ok" = true ]; then
        # If all checks passed, show a success dialog.
        zenity --info --title="Verification Successful" --width=800 --height=600 \
            --text="<span size='large' color='green'><b>All major checks passed!</b></span>\n\nYour NVIDIA driver appears to be fully installed and operational.\n\n<b>Summary:</b>\n$report"
    else
        # If any check failed, show an error dialog with the detailed report.
        zenity --error --title="Verification Failed" --width=800 --height=600 \
            --text="<span size='large' color='red'><b>One or more verification checks failed!</b></span>\n\n$report\n\nPlease review the errors above and consult the log file (<b>$LOG_FILE</b>) for detailed troubleshooting information and potential solutions."
    fi
}

# --- Uninstallation and About Dialogs ---

# Uninstalls all NVIDIA-related packages and attempts to restore the Nouveau driver.
uninstall_nvidia() {
    # Ask for strong confirmation before proceeding with uninstallation.
    if ! user_confirm "This action will completely <b>PURGE</b> all NVIDIA packages from your system.\nIt will also attempt to restore the default 'nouveau' open-source driver.\n\nA reboot will be required afterward to load the correct driver.\n\nAre you absolutely certain you want to proceed with the uninstallation?" "Confirm NVIDIA Driver Uninstallation"; then
        log "User canceled the NVIDIA driver uninstallation process."
        return # Exit if user cancels.
    fi
    log "--- Starting Full NVIDIA Driver Purge ---"
    # Purge all packages matching the nvidia pattern.
    run_with_progress "Purging all NVIDIA packages..." apt-get remove --purge -y '~nnvidia-.*'
    # Clean up any orphaned dependencies that might remain.
    run_with_progress "Cleaning up orphaned dependencies..." apt-get autoremove -y
    log "Removing leftover NVIDIA configuration files..."
    # Remove any specific blacklist files created by the installer.
    run_or_die rm -f /etc/modprobe.d/nvidia-installer-disable-nouveau.conf
    # Update the initramfs to ensure Nouveau is properly configured.
    run_with_progress "Updating initramfs to restore Nouveau driver..." update-initramfs -u

    # Inform the user about completion and the need for a reboot.
    zenity --info --title="Uninstallation Complete" --width=500 \
        --text="<span size='large'><b>NVIDIA Driver Uninstallation Successful</b></span>\n\nAll NVIDIA components have been purged from your system.\n\nA reboot is now required to load the default 'nouveau' video driver.\n\nThank you!"
    # Ask for reboot confirmation.
    if user_confirm "A reboot is required to activate the restored default driver.\n\nReboot now?" "Reboot Required After Uninstall"; then
        reboot
    fi
}

# Displays an informative "About" dialog for the script.
show_about_dialog() {
    zenity --info --title="About This Installer - Leviathan Edition" --width=750 --height=400 \
        --text="<span size='large'><b>Kali NVIDIA Installer - Leviathan Edition</b></span>\n\nThis script is an exceptionally robust, safe, and user-centric tool designed for installing NVIDIA's proprietary drivers on Kali Linux.\n\nIt meticulously follows the official Kali Linux documentation and provides a guided, transparent installation experience, automating the entire process from pre-flight checks to deep-dive verification.\n\n<b>Key Features:</b>\n- 🚀 <b>Fully Automated 'Leviathan Install'</b>: Handles all steps from system upgrade to driver verification, making the complex process simple.\n- 🛡️ <b>Exhaustive Pre-Flight Analysis</b>: Detects potential issues like Secure Boot, VM environments, insufficient disk space, and hardware presence before any changes are made.\n- 📖 <b>'Philosopher's Guide' UI</b>: Detailed explanations for every action taken by the script, ensuring you understand the 'what' and 'why' of each step.\n- 🔎 <b>Deep Dive Verification Suite</b>: Confirms driver functionality at multiple levels, including DKMS status, kernel module loading, `nvidia-smi` communication, and OpenGL rendering.\n- ✨ <b>Clean Uninstaller</b>: Safely removes all NVIDIA components and reliably restores the default 'nouveau' driver.\n- 🌈 <b>Enhanced Terminal & GUI Feedback</b>: Leverages color-coded messages and informative Zenity dialogs for a superior user experience.\n- 📝 <b>Comprehensive & Detailed Logging</b>: All operations, commands, and their outputs are meticulously recorded in <b>$LOG_FILE</b> for easy troubleshooting and auditing.\n\nThis project is a significant enhancement and evolution inspired by the foundational work in the Opselon/Kali-LInux-Nvidia-Installer repository."
}

# --- Main Menu and Script Entrypoint ---

# Displays the main menu for user interaction.
main_menu() {
    # Print the ASCII banner to the terminal for visual appeal.
    echo -e "$BANNER"
    local choice
    # Present the main options to the user via a Zenity list dialog.
    choice=$(zenity --list --title="Kali NVIDIA Installer - Leviathan Edition" --text="$BANNER\n<span size='large'>Welcome to the Kali NVIDIA Installer - Leviathan Edition.</span>\n\nPlease select an action from the list below to manage your NVIDIA drivers." --height=500 --width=850 \
        --column="Action" --column="Description" \
        "Start Leviathan Installation" "The ultimate, fully automated, and guided process to install, update, and configure your NVIDIA drivers." \
        "Deep Dive Verification Suite" "Run a comprehensive diagnostic suite to confirm if your NVIDIA drivers are installed correctly and are fully functional." \
        "Purge All NVIDIA Drivers" "Completely uninstall all NVIDIA components, revert system changes, and restore the default 'nouveau' driver." \
        "View Log File" "Open the detailed log file for the current session for troubleshooting and auditing purposes." \
        "About This Installer" "Display information about the script's advanced features, purpose, and development." \
        "Exit" "Close the application and exit the installer.")

    # Process the user's selection.
    case "$choice" in
        "Start Leviathan Installation") leviathan_install ;;
        "Deep Dive Verification Suite") comprehensive_verification ;;
        "Purge All NVIDIA Drivers") uninstall_nvidia ;;
        "View Log File")
            # Attempt to open the log file with the default application or show it in Zenity if xdg-open fails.
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

# Initialize the log file directory and the log file itself upon script start.
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
log "--- Kali NVIDIA Leviathan Installer session started ---"

# Perform initial critical checks before displaying the main menu.
# This ensures that essential dependencies like root privileges and Zenity are met.
_check_root
_check_zenity

# Enter the main application loop to display the menu and handle user actions continuously.
while true; do
    main_menu
done