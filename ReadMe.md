# Kali NVIDIA Installer (enhanced)

**A safer, GUI-assisted NVIDIA driver installer for Kali Linux — developed from and compatible with the Opselon project.**

This repository bundles a user-friendly Zenity GUI shell script that helps you install NVIDIA proprietary drivers (and optional CUDA) on Kali Linux. It prefers the package-managed approach (recommended) while offering an advanced `.run` installer path, robust safety checks, dry-run mode, logging, and Secure Boot guidance.

---

## Table of contents

* [Features](#features)
* [Why use this script](#why-use-this-script)
* [Prerequisites](#prerequisites)
* [Installation (quick)](#installation-quick)
* [Usage (GUI)](#usage-gui)
* [Commands / Options (headless)](#commands--options-headless)
* [Advanced options](#advanced-options)
* [Uninstall](#uninstall)
* [Troubleshooting](#troubleshooting)
* [Security considerations](#security-considerations)
* [CI / Linting](#ci--linting)
* [Contributing](#contributing)
* [Credits & License](#credits--license)

---

## Features

* GPU detection (`lspci`, optional `nvidia-detect`)
* Safe repo management: suggests/enables `contrib` and `non-free` components when necessary
* Installs prerequisites: kernel headers, `dkms`, `build-essential`, `pciutils`, `wget`, `curl`, etc.
* Repo-based NVIDIA driver install (recommended): `nvidia-driver`, `nvidia-kernel-dkms`, `nvidia-utils`
* Optional: NVIDIA `.run` installer flow (advanced users) with clear warnings
* Optional: `nvidia-cuda-toolkit` installation
* Blacklists Nouveau and updates `initramfs`
* Detects Secure Boot state and shows module-signing options
* Dry-run mode (preview commands without applying them)
* Logging to `/var/log/kali-nvidia-installer-YYYYMMDD-HHMMSS.log`
* Uninstall / purge helper that attempts to restore Nouveau
* Zenity GUI for interactive use; auto-installs Zenity if missing

---

## Why use this script

Installing NVIDIA drivers can be painful when kernel headers are missing, Secure Boot blocks modules, or the system relies on `apt` for kernel module updates. This script:

* Prioritizes the Debian/Kali package-managed approach (DKMS + apt) to reduce breakage on kernel updates
* Adds safety features (dry-run, logging, backups) for confident use
* Provides an advanced `.run` option when repo packages are insufficient

---

## Prerequisites

* Kali Linux (kali-rolling recommended)
* `bash` (GNU bash)
* `sudo` (or run as root)
* Internet connection for `apt` and optional downloads
* `zenity` (script will install it if missing)

---

## Installation (quick)

Clone the repo (or download the script) and run as root:

```bash
git clone https://github.com/<your-user>/kali-nvidia-installer.git
cd kali-nvidia-installer
chmod +x kali-nvidia-installer.sh
sudo ./kali-nvidia-installer.sh
```

> The script will request root privileges via `sudo` if not run as root.

---

## Usage (GUI)

On run the script shows a Zenity menu with options such as:

* Detect GPU
* Enable `contrib` & `non-free`
* Install prerequisites (headers, DKMS)
* Blacklist Nouveau & update initramfs
* Install NVIDIA (repo, recommended)
* Install NVIDIA (.run, advanced)
* Install CUDA (repos)
* Verify (`nvidia-smi`)
* Uninstall (purge)
* Show Secure Boot info
* Toggle Dry-run

Follow the dialogs for step-by-step guidance. The script logs all operations to `/var/log` for auditing.

---

## Commands / Options (headless)

The script is primarily GUI-driven. For headless or scripted workflows, you can read the script and run the commands shown in dry-run mode. To enable dry-run from the menu: select \*\*Toggle Dry
