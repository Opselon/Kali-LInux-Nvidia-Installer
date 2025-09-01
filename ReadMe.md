# Kali NVIDIA Installer - The Leviathan Edition

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shellcheck](https://img.shields.io/badge/Shell-Checked-green)](https://www.shellcheck.net/)
[![Kali Linux](https://img.shields.io/badge/OS-Kali_Linux-blue.svg)](https://www.kali.org/)

An exceptionally intelligent, safe, and GUI-driven NVIDIA Driver Installation Suite for Kali Linux. This project elevates the original Opselon installer to a new level of robustness and user experience, automating the entire official process from 0 to 100.

This is not just a script; it's a guided, self-aware system management tool that performs a deep system analysis, explains every action it takes, and verifies its own success with a comprehensive diagnostic suite.

<br>

![image](https://github.com/user-attachments/assets/1f94852c-47fc-4e4b-9e4a-57934ca44d03)



## Key Features of the Leviathan Edition

The Leviathan Edition is a complete rewrite focusing on intelligence and safety:

*   🚀 **One-Click "Leviathan Install"**: A fully automated, "fire-and-forget" option that executes the entire official Kali installation procedure in the correct sequence.
*   🛡️ **Exhaustive Pre-Flight System Analysis**: Before touching your system, the script runs a suite of critical checks:
    *   **Virtual Machine Detection**: Warns you if running in VirtualBox, VMWare, or QEMU.
    *   **Secure Boot Status**: Detects if Secure Boot is enabled and explains why it will block the driver.
    *   **Disk Space Analysis**: Ensures you have enough space for the drivers (and the massive CUDA toolkit).
    *   **Hardware Verification**: Confirms an NVIDIA GPU is actually present in your system.
    *   **System Health**: Checks for internet connectivity, `apt` locks, and the correct `kali-rolling` repository.
*   🧠 **Intelligent & Self-Aware**:
    *   Automatically detects when a **reboot is required** after a kernel upgrade and manages it for you.
    *   Follows the official Kali documentation precisely for maximum stability.
*   🔎 **"Deep Dive" Verification Suite**: After installation, it runs a multi-point inspection to confirm everything is working perfectly:
    *   Checks **DKMS** build status.
    *   Verifies the `nvidia` kernel module is loaded.
    *   Confirms `nvidia-smi` is communicating with the driver.
    *   Tests **OpenGL acceleration** via `glxinfo` to ensure the graphics stack is fully functional.
*   📖 **The Philosopher's Guide UI**: Every major step is explained with a detailed graphical dialog, telling you *what* is happening, *why* it's necessary, and what to expect.
*   ✨ **Clean, Atomic Uninstaller**: A powerful purge utility to completely remove all traces of NVIDIA and safely restore the default Nouveau driver.

## Why Use This Edition?

The standard NVIDIA installation on Kali can be brittle. A mismatched kernel header, an overlooked Secure Boot setting, or an improper sequence of commands can lead to a black screen or a broken driver stack.

This Leviathan script solves these problems by acting as an expert system administrator, guiding you through a flawless installation. **It anticipates problems before they happen.**

## Prerequisites

*   **Kali Linux** (`kali-rolling` is required and verified by the script).
*   **Root privileges** (`sudo` is required, and the script will handle it).
*   **A stable internet connection**.
*   **`zenity`** for the GUI (the script will auto-install it if missing).

## One-Command Installation

To download and run the installer in a single, convenient command, open a terminal and execute the following.

> **Security Warning**: This method pipes a script from the internet directly into a root shell. This is a common practice for installers but carries a security risk. We recommend you inspect the script's source code before running.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Opselon/Kali-LInux-Nvidia-Installer/main/kali-nvidia-installer-leviathan.sh)"
```
*(Note: Please replace the URL above with the raw URL to your final script file.)*

## Usage (The Guided GUI)

The Leviathan Edition is designed for simplicity. Forget the manual steps.

1.  Run the script using the one-command installation above.
2.  You will be greeted by the main menu.
3.  For a complete, worry-free installation, simply select:
    *   **`Start Leviathan Installation`**
4.  The script will take over, performing all system analysis, upgrades, and installations. It will prompt you with clear explanations and choices along the way.
5.  After the final reboot, you can run the script again and select **`Deep Dive Verification Suite`** to get a full report on your new, fully functional NVIDIA driver.

### Main Menu Options Explained

*   **`Start Leviathan Installation`**: The primary, all-in-one function. Highly recommended for all users.
*   **`Deep Dive Verification Suite`**: A powerful diagnostic tool to run after installation to check that everything is working at every level.
*   **`Purge All NVIDIA Drivers`**: A robust uninstaller that cleans your system and restores the default video driver.
*   **`View Log File`**: Opens the detailed log file (`/var/log/kali-nvidia-installer-*.log`) for troubleshooting.
*   **`About This Installer`**: Displays information about the script's advanced features.

## Troubleshooting

If you encounter any issues, your first step should be to **check the log file**. The Leviathan script provides extremely detailed logs of every command it runs and the output it receives.

1.  Run the script and select `View Log File`.
2.  Look for any lines marked with `ERROR` or `FAILED`.
3.  Common issues include:
    *   **Secure Boot Enabled**: The verification will fail because the kernel refuses to load the unsigned `nvidia` module. You must disable Secure Boot in your computer's UEFI/BIOS.
    *   **Network Interruption**: A failed download during the `apt` process can halt the installation. Ensure your connection is stable.
    *   **Out-of-Date System**: If you skip the `full-upgrade` step, the kernel headers may not match your running kernel. The Leviathan install prevents this, but manual operations might not.

## Credits & License

This script represents a massive enhancement and logical evolution of the work started in the [Opselon/Kali-LInux-Nvidia-Installer](https://github.com/Opselon/Kali-LInux-Nvidia-Installer) project. It stands on the shoulders of that foundation to deliver a next-generation experience.

Licensed under the **MIT License**. See the `LICENSE` file for details.