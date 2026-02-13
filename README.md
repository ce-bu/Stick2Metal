# Stick2Metal - Ubuntu 24.04 Offline Installer Builder

Creates a bootable USB/ISO installer that clones a pre-built Ubuntu 24.04 system image to target PCs. Works completely **offline** - no internet required on target machines.

## Overview

Stick2Metal uses a two-stage build process:
1. **Packer** builds a fully-configured Ubuntu 24.04 UEFI system image with all software pre-installed
2. **ISO Builder** packages the image into a bootable installer that can be written to USB

## Features

- **Fully offline installation**: All packages pre-installed, no network required on target
- **UEFI boot**: Modern UEFI firmware support with GPT partitioning
- **LVM storage**: Root filesystem on LVM for flexibility
- **Automatic or manual installation**: Boot menu options for both modes
- **Automatic disk detection**: Selects largest non-USB disk as target
- **UUID regeneration**: Each installed system gets unique filesystem UUIDs
- **Network auto-configuration**: DHCP on all ethernet interfaces

### Pre-installed Software

| Category | Packages |
|----------|----------|
| **Desktop** | XFCE4, LightDM, Xorg |
| **Editor** | VS Code (with Rust Analyzer, CodeLLDB, Even Better TOML, HC Zenburn theme) |
| **Development** | GCC, G++, Make, CMake, Git, Rust toolchain |
| **Virtualization** | QEMU/KVM, Virt-Manager, Podman, Buildah |
| **Networking** | Wireshark, tcpdump, nmap, netcat, iperf3, mtr, iftop |
| **Disk Tools** | ncdu, duf, squashfs-tools, GParted, LVM2, mdadm, cryptsetup, smartmontools, nvme-cli |
| **Graphics** | Mesa drivers, Vulkan, VA-API (Intel/AMD) |
| **Browser** | Brave |
| **Utilities** | Vim, htop, OpenSSH, Atril (PDF), Gedit |

## Prerequisites

### Install Packer
```bash
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
sudo apt-get update && sudo apt-get install packer
```

### Install QEMU, OVMF, and ISO Tools
```bash
sudo apt-get install -y qemu-system-x86 qemu-utils ovmf xorriso squashfs-tools gzip wget
```

## Usage

### Step 1: Build the Packer Image

Initialize Packer plugins (first time only):
```bash
packer init .
```

Build the base system image:
```bash
./build.sh
```

This creates `output/ubuntu-24.04-autoinstall` (~10-15GB) with all packages pre-installed. The build takes 30-60 minutes depending on your system and network speed. A QEMU window will open showing the installation progress.

### Step 2: Build the Installer ISO

```bash
sudo ./build-installer-iso.sh
```

This downloads Ubuntu 24.04.3 Server ISO (if not present), compresses the Packer image, and creates `ubuntu-installer.iso` (~5-6GB).

### Step 3: Write to USB Drive

```bash

sudo dd if=ubuntu-installer.iso of=/dev/sdX bs=64M status=progress oflag=sync
```

Replace `/dev/sdX` with your USB device (use `lsblk` to identify).

## Boot Options

When booting from the installer USB, you'll see three options:

1. **Automatic Install** - Formats the largest non-USB disk automatically (**DANGEROUS** - no confirmation!)
2. **Manual Install** - Boots to shell, run `sudo /cdrom/installer/install.sh` manually
3. **Ubuntu Server Installer** - Original Ubuntu installer (requires internet)

## Installation Process

The installer performs these steps:

1. Detects and selects target disk (largest non-USB disk)
2. Clones the compressed system image to target
3. Expands partitions to use full disk
4. Regenerates filesystem UUIDs
5. Updates fstab with new UUIDs
6. Regenerates initramfs (critical for boot)
7. Reinstalls GRUB bootloader
8. Configures network for DHCP
9. Sets hostname (auto-generated or prompted)

## Default Credentials

| | |
|---|---|
| **Username** | `ubuser` |
| **Password** | `ubuser` |

## Testing with QEMU

Test the installer ISO in a VM before deploying to real hardware:

```bash
# Run the installer (boots from ISO)
./test-vm.sh

# In the live environment, run:
sudo /cdrom/installer/install.sh

# After installation, boot the installed system:
./test-vm.sh --boot

# SSH into the VM (after boot):
ssh -p 2222 ubuser@localhost

# Clean up test files:
./test-vm.sh --clean
```

## Customization

### Autoinstall Configuration
Edit `http/user-data` to modify the base system:
- Username/password
- Hostname
- Keyboard layout
- Disk partitioning scheme (EFI + Boot + LVM)
- Network configuration

### Pre-installed Software
Edit `ubuntu.pkr.hcl` provisioners to add/remove packages installed in the golden image.

### Installer Behavior
Edit `build-installer-iso.sh` to modify:
- Target disk selection logic
- Post-install configuration
- Network settings

## Disk Layout

The installed system uses this partition scheme:

| Partition | Size | Type | Mount Point |
|-----------|------|------|-------------|
| EFI System | 512MB | FAT32 | /boot/efi |
| Boot | 1GB | ext4 | /boot |
| LVM PV | Remaining | LVM | - |
| └─ vg0/root | 100% of VG | ext4 | / |

