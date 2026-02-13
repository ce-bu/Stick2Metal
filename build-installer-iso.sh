#!/bin/bash
#
# Build a bootable Live USB Installer that clones the pre-built Packer image
# onto the target PC. This works OFFLINE - no internet required on target.
#
# The installer will:
# 1. Automatically detect and format the target disk
# 2. Clone the pre-built image (with all packages) to the target
# 3. Expand partitions to use full disk
# 4. Regenerate UUIDs and fix boot
# 5. Configure network for DHCP
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Configuration
PACKER_IMAGE="output/ubuntu-24.04-autoinstall"
UBUNTU_ISO_URL="https://releases.ubuntu.com/24.04/ubuntu-24.04.3-live-server-amd64.iso"
UBUNTU_ISO="ubuntu-24.04.3-live-server-amd64.iso"
OUTPUT_ISO="ubuntu-installer.iso"
WORK_DIR="$SCRIPT_DIR/iso-work"
IMAGE_NAME="system.img.gz"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (sudo)"
        exit 1
    fi
}

check_deps() {
    local missing=()
    for cmd in xorriso mksquashfs unsquashfs gzip wget; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing[*]}"
        log_info "Install with: sudo apt-get install -y xorriso squashfs-tools gzip wget"
        exit 1
    fi
}

check_packer_image() {
    if [ ! -f "$PACKER_IMAGE" ]; then
        log_error "Packer image not found: $PACKER_IMAGE"
        log_info "Run './build.sh' first to create the image with Packer"
        exit 1
    fi
    log_info "Found Packer image: $PACKER_IMAGE ($(du -h "$PACKER_IMAGE" | cut -f1))"
}

download_iso() {
    if [ -f "$UBUNTU_ISO" ]; then
        log_info "Ubuntu ISO exists: $UBUNTU_ISO"
    else
        log_info "Downloading Ubuntu 24.04.3 Server ISO..."
        wget -c "$UBUNTU_ISO_URL" -O "$UBUNTU_ISO"
    fi
}

extract_iso() {
    log_info "Extracting Ubuntu ISO..."
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR/iso" "$WORK_DIR/squashfs" "$WORK_DIR/custom"
    
    # Mount and copy ISO contents
    mkdir -p "$WORK_DIR/mnt"
    mount -o loop "$UBUNTU_ISO" "$WORK_DIR/mnt"
    cp -a "$WORK_DIR/mnt/." "$WORK_DIR/iso/"
    umount "$WORK_DIR/mnt"
    rmdir "$WORK_DIR/mnt"
    
    chmod -R u+w "$WORK_DIR/iso"
}

compress_packer_image() {
    log_info "Compressing Packer image (this may take a while)..."
    
    # Zero-fill free space first for better compression (optional, skip if too slow)
    # gzip the image
    if [ ! -f "$WORK_DIR/$IMAGE_NAME" ]; then
        gzip -c -1 "$PACKER_IMAGE" > "$WORK_DIR/$IMAGE_NAME"
    fi
    
    log_info "Compressed image: $(du -h "$WORK_DIR/$IMAGE_NAME" | cut -f1)"
}

create_installer_script() {
    log_info "Creating installer script..."
    
    mkdir -p "$WORK_DIR/iso/installer"
    
    # Copy compressed image
    cp "$WORK_DIR/$IMAGE_NAME" "$WORK_DIR/iso/installer/"
    
    # Copy post-install script for bare metal
    if [ -f "$SCRIPT_DIR/post-install-baremetal.sh" ]; then
        cp "$SCRIPT_DIR/post-install-baremetal.sh" "$WORK_DIR/iso/installer/"
        log_info "Included post-install-baremetal.sh"
    fi
    
    # Create the installer script
    cat > "$WORK_DIR/iso/installer/install.sh" << 'INSTALLER_SCRIPT'
#!/bin/bash
#
# Ubuntu Image Installer - Clones pre-built image to target disk
# Works completely OFFLINE - no internet required
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

# Parse arguments
AUTO_MODE=false
AUTO_HOSTNAME=""
for arg in "$@"; do
    case $arg in
        --auto)
            AUTO_MODE=true
            ;;
        --hostname=*)
            AUTO_HOSTNAME="${arg#*=}"
            ;;
    esac
done

# Find installer directory (works from USB or cdrom)
find_installer_dir() {
    for path in /cdrom/installer /media/*/installer /run/live/medium/installer; do
        if [ -f "$path/system.img.gz" ]; then
            echo "$path"
            return 0
        fi
    done
    # Try to find and mount the installer media
    for dev in /dev/sr0 /dev/cdrom; do
        if [ -b "$dev" ]; then
            mkdir -p /mnt/installer_media
            mount "$dev" /mnt/installer_media 2>/dev/null || continue
            if [ -f "/mnt/installer_media/installer/system.img.gz" ]; then
                echo "/mnt/installer_media/installer"
                return 0
            fi
            umount /mnt/installer_media 2>/dev/null || true
        fi
    done
    return 1
}

INSTALLER_DIR="$(find_installer_dir)"
if [ -z "$INSTALLER_DIR" ]; then
    log_error "Cannot find installer directory with system.img.gz"
    exit 1
fi
IMAGE_FILE="$INSTALLER_DIR/system.img.gz"

# Get list of available disks (excluding USB/CD drives)
get_target_disks() {
    lsblk -dno NAME,SIZE,TYPE,TRAN | grep -E "disk\s+(sata|nvme|ata|scsi|virtio)" | \
        grep -v "$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//' | xargs basename 2>/dev/null || echo 'NONE')"
}

select_target_disk() {
    log_step "Detecting available disks..."
    echo ""
    
    # List all disks
    echo "Available disks:"
    echo "----------------"
    lsblk -dno NAME,SIZE,MODEL,TRAN | grep -E "^(sd|nvme|vd)" | nl -w2 -s") "
    echo ""
    
    # Find boot device (USB/CD we booted from)
    local boot_disk=""
    local live_device=$(findmnt -n -o SOURCE /run/live/medium 2>/dev/null | sed 's/[0-9]*$//' | xargs basename 2>/dev/null || echo "")
    if [ -z "$live_device" ]; then
        live_device=$(findmnt -n -o SOURCE /cdrom 2>/dev/null | sed 's/[0-9]*$//' | xargs basename 2>/dev/null || echo "")
    fi
    boot_disk="$live_device"
    
    # Auto-select largest non-boot, non-USB disk
    local target=""
    local target_size=0
    
    while read -r disk size model tran; do
        # Skip the boot device
        if [ "$disk" = "$boot_disk" ]; then
            log_info "Skipping boot device: $disk"
            continue
        fi
        # In auto mode, prefer non-USB disks (sata, nvme, virtio)
        if [ "$AUTO_MODE" = true ] && [ "$tran" = "usb" ]; then
            log_info "Skipping USB device in auto mode: $disk"
            continue
        fi
        local size_bytes=$(lsblk -bdno SIZE "/dev/$disk" 2>/dev/null || echo 0)
        if [ "$size_bytes" -gt "$target_size" ]; then
            target="$disk"
            target_size="$size_bytes"
        fi
    done < <(lsblk -dno NAME,SIZE,MODEL,TRAN | grep -E "^(sd|nvme|vd)")
    
    if [ -z "$target" ]; then
        log_error "No suitable target disk found!"
        exit 1
    fi
    
    TARGET_DISK="/dev/$target"
    log_info "Selected target disk: $TARGET_DISK ($(lsblk -dno SIZE "$TARGET_DISK"))"
    
    if [ "$AUTO_MODE" = true ]; then
        log_warn "AUTO MODE: Proceeding without confirmation!"
        echo ""
        sleep 3
    else
        echo ""
        echo -e "${RED}WARNING: ALL DATA ON $TARGET_DISK WILL BE DESTROYED!${NC}"
        echo ""
        read -p "Continue with installation? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            log_error "Installation cancelled."
            exit 1
        fi
    fi
}

wipe_target_disk() {
    log_step "Wiping target disk $TARGET_DISK..."
    
    # First, unmount any vg0 mounts (from previous attempts or source image)
    log_info "Cleaning up any existing LVM mounts..."
    umount -R /mnt/target 2>/dev/null || true
    umount /dev/vg0/* 2>/dev/null || true
    umount /dev/mapper/vg0-* 2>/dev/null || true
    
    # Deactivate vg0 if it exists (may be from source image in live environment)
    if vgs vg0 &>/dev/null; then
        log_info "Deactivating existing vg0 volume group..."
        vgchange -an vg0 2>/dev/null || true
    fi
    
    # Unmount any partitions on target
    for part in $(lsblk -no NAME "$TARGET_DISK" | tail -n +2); do
        umount "/dev/$part" 2>/dev/null || true
        swapoff "/dev/$part" 2>/dev/null || true
    done
    
    # Deactivate any LVM on the target disk
    log_info "Removing existing LVM volumes..."
    for vg in $(pvs --noheadings -o vg_name "$TARGET_DISK"* 2>/dev/null | sort -u); do
        vg=$(echo "$vg" | tr -d ' ')
        if [ -n "$vg" ]; then
            log_info "Removing volume group: $vg"
            vgchange -an "$vg" 2>/dev/null || true
            vgremove -f "$vg" 2>/dev/null || true
        fi
    done
    
    # Remove PV signatures
    for part in $(lsblk -no NAME "$TARGET_DISK" | tail -n +2); do
        pvremove -f "/dev/$part" 2>/dev/null || true
    done
    
    # Wipe all filesystem signatures
    log_info "Wiping filesystem signatures..."
    wipefs -a -f "$TARGET_DISK" 2>/dev/null || true
    for part in $(lsblk -no NAME "$TARGET_DISK" | tail -n +2); do
        wipefs -a -f "/dev/$part" 2>/dev/null || true
    done
    
    # Zero out the beginning and end of the disk (GPT headers)
    log_info "Zeroing disk headers..."
    dd if=/dev/zero of="$TARGET_DISK" bs=1M count=10 conv=notrunc 2>/dev/null || true
    
    # Zero GPT backup at end of disk
    local disk_size=$(blockdev --getsize64 "$TARGET_DISK")
    local seek_mb=$(( (disk_size / 1048576) - 10 ))
    if [ "$seek_mb" -gt 10 ]; then
        dd if=/dev/zero of="$TARGET_DISK" bs=1M count=10 seek="$seek_mb" conv=notrunc 2>/dev/null || true
    fi
    
    # Force kernel to re-read partition table
    sync
    partprobe "$TARGET_DISK" 2>/dev/null || true
    sleep 2
    
    log_info "Disk wiped successfully"
}

clone_image() {
    log_step "Cloning system image to $TARGET_DISK..."
    log_info "This will take several minutes..."
    
    # Clone image
    gunzip -c "$IMAGE_FILE" | dd of="$TARGET_DISK" bs=4M status=progress conv=fsync
    
    # Reload partition table
    sync
    partprobe "$TARGET_DISK" 2>/dev/null || true
    sleep 2
    
    # Scan for LVM volumes on the cloned disk
    log_info "Scanning for LVM volumes..."
    pvscan --cache 2>/dev/null || true
    vgscan 2>/dev/null || true
    vgchange -ay vg0 2>/dev/null || true
    sleep 1
}

fix_partitions() {
    log_step "Fixing partition table and expanding to full disk..."
    
    # Determine partition naming scheme (nvme uses p1, sd uses 1)
    if [[ "$TARGET_DISK" == *"nvme"* ]]; then
        PART_PREFIX="${TARGET_DISK}p"
    else
        PART_PREFIX="${TARGET_DISK}"
    fi
    
    # Get partition info
    local efi_part="${PART_PREFIX}1"
    local boot_part="${PART_PREFIX}2"
    local lvm_part="${PART_PREFIX}3"
    
    # Fix GPT to use full disk
    sgdisk -e "$TARGET_DISK" 2>/dev/null || true
    
    # Delete and recreate LVM partition to use remaining space
    local lvm_start=$(sgdisk -i 3 "$TARGET_DISK" 2>/dev/null | grep "First sector" | awk '{print $3}')
    if [ -n "$lvm_start" ]; then
        sgdisk -d 3 "$TARGET_DISK" 2>/dev/null || true
        sgdisk -n 3:${lvm_start}:0 -t 3:8e00 "$TARGET_DISK" 2>/dev/null || true
    fi
    
    partprobe "$TARGET_DISK" 2>/dev/null || true
    sleep 2
    
    # Resize LVM
    log_info "Expanding LVM volumes..."
    pvresize "$lvm_part" 2>/dev/null || true
    lvextend -l +100%FREE /dev/vg0/root 2>/dev/null || true
    
    # Run filesystem check before resize (required after cloning)
    log_info "Checking filesystem before resize..."
    e2fsck -f -y /dev/vg0/root || true
    
    # Now resize the filesystem
    log_info "Resizing root filesystem..."
    resize2fs /dev/vg0/root
}

regenerate_uuids() {
    log_step "Regenerating filesystem UUIDs..."
    
    if [[ "$TARGET_DISK" == *"nvme"* ]]; then
        PART_PREFIX="${TARGET_DISK}p"
    else
        PART_PREFIX="${TARGET_DISK}"
    fi
    
    local efi_part="${PART_PREFIX}1"
    local boot_part="${PART_PREFIX}2"
    
    # Generate new UUIDs
    local new_boot_uuid=$(uuidgen)
    local new_root_uuid=$(uuidgen)
    
    # Run filesystem check on boot partition before changing UUID
    log_info "Checking boot filesystem..."
    e2fsck -f -y "$boot_part" || true
    
    # Change boot partition UUID
    log_info "Setting boot partition UUID: $new_boot_uuid"
    tune2fs -U "$new_boot_uuid" "$boot_part"
    
    # Root was already checked in fix_partitions, change UUID
    log_info "Setting root partition UUID: $new_root_uuid"
    tune2fs -U "$new_root_uuid" /dev/vg0/root
    
    # Sync and refresh block device info
    sync
    blockdev --flushbufs "$boot_part" 2>/dev/null || true
    blockdev --flushbufs /dev/vg0/root 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    sleep 1
    
    # Verify UUIDs were applied by reading them back
    local actual_boot_uuid=$(blkid -s UUID -o value "$boot_part")
    local actual_root_uuid=$(blkid -s UUID -o value /dev/vg0/root)
    log_info "Verified boot UUID: $actual_boot_uuid"
    log_info "Verified root UUID: $actual_root_uuid"
    
    # Get the EFI UUID (FAT32 has volume ID, not UUID - we don't change it)
    local efi_uuid=$(blkid -s UUID -o value "$efi_part")
    log_info "EFI partition UUID: $efi_uuid"
    
    # Update fstab
    log_info "Updating /etc/fstab..."
    mkdir -p /mnt/target
    
    # Ensure vg0 is not already mounted
    if mountpoint -q /mnt/target; then
        log_info "Unmounting existing /mnt/target..."
        umount -R /mnt/target 2>/dev/null || true
    fi
    
    # Activate vg0 if needed
    vgchange -ay vg0 2>/dev/null || true
    sleep 1
    
    mount /dev/vg0/root /mnt/target
    mount "$boot_part" /mnt/target/boot
    mount "$efi_part" /mnt/target/boot/efi
    
    # Create new fstab - use verified UUIDs
    cat > /mnt/target/etc/fstab << FSTAB
# /etc/fstab - Generated by installer
/dev/mapper/vg0-root  /           ext4  defaults  0  1
UUID=$actual_boot_uuid   /boot       ext4  defaults  0  2
UUID=$efi_uuid        /boot/efi   vfat  umask=0077  0  1
FSTAB
    
    log_info "New fstab:"
    cat /mnt/target/etc/fstab
}

configure_network() {
    log_step "Configuring network for DHCP..."
    
    # Create netplan config for DHCP on all ethernet interfaces
    cat > /mnt/target/etc/netplan/00-installer-config.yaml << 'NETPLAN'
network:
  version: 2
  renderer: networkd
  ethernets:
    all-ethernet:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: true
      optional: true
    all-eth:
      match:
        name: "eth*"
      dhcp4: true
      dhcp6: true
      optional: true
NETPLAN
    
    chmod 600 /mnt/target/etc/netplan/00-installer-config.yaml
}

fix_bootloader() {
    log_step "Reinstalling bootloader and regenerating initramfs..."
    
    # Bind mount for chroot
    mount --bind /dev /mnt/target/dev
    mount --bind /dev/pts /mnt/target/dev/pts
    mount --bind /proc /mnt/target/proc
    mount --bind /sys /mnt/target/sys
    mount --bind /run /mnt/target/run
    
    # Reinstall GRUB for UEFI, remove casper, and regenerate initramfs with new UUIDs
    chroot /mnt/target /bin/bash << 'CHROOT_SCRIPT'
# Remove casper and live-boot packages that cause boot issues
echo "Removing live boot packages..."
apt-get purge -y casper lupin-casper 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

# Remove any casper hooks from initramfs
rm -f /usr/share/initramfs-tools/scripts/casper* 2>/dev/null || true
rm -f /usr/share/initramfs-tools/scripts/*/casper* 2>/dev/null || true
rm -rf /usr/share/initramfs-tools/scripts/casper-bottom 2>/dev/null || true

# Disable any casper-related services
systemctl disable casper.service 2>/dev/null || true
systemctl disable casper-md5check.service 2>/dev/null || true
systemctl mask casper.service 2>/dev/null || true
systemctl mask casper-md5check.service 2>/dev/null || true

# Regenerate initramfs with new UUIDs - this is critical!
update-initramfs -u -k all 2>/dev/null || true

# Reinstall GRUB
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck 2>/dev/null || true
update-grub 2>/dev/null || true
CHROOT_SCRIPT
    
    # Sync and cleanup - proper order is important
    sync
    log_info "Unmounting chroot filesystems..."
    
    # First unmount bind mounts in reverse order
    umount -l /mnt/target/run 2>/dev/null || true
    umount -l /mnt/target/sys 2>/dev/null || true
    umount -l /mnt/target/proc 2>/dev/null || true
    umount -l /mnt/target/dev/pts 2>/dev/null || true
    umount -l /mnt/target/dev 2>/dev/null || true
    
    # Then unmount regular mounts
    umount /mnt/target/boot/efi 2>/dev/null || true
    umount /mnt/target/boot 2>/dev/null || true
    umount /mnt/target 2>/dev/null || true
    
    sleep 1
}

set_hostname() {
    log_step "Setting hostname..."
    
    local hostname
    if [ -n "$AUTO_HOSTNAME" ]; then
        hostname="$AUTO_HOSTNAME"
    elif [ "$AUTO_MODE" = true ]; then
        # Generate hostname from MAC address of first ethernet interface
        local mac=$(ip link show | grep -A1 "^[0-9]*: e" | grep ether | awk '{print $2}' | head -1 | tr -d ':' | tail -c 7)
        hostname="ubuntu-${mac:-$(date +%s | tail -c 5)}"
    else
        read -p "Enter hostname for this PC [ubuntu-pc]: " hostname
        hostname=${hostname:-ubuntu-pc}
    fi
    
    log_info "Hostname: $hostname"
    
    # Ensure vg0 is active and not already mounted
    if mountpoint -q /mnt/target 2>/dev/null; then
        umount /mnt/target 2>/dev/null || true
    fi
    vgchange -ay vg0 2>/dev/null || true
    sleep 1
    
    mount /dev/vg0/root /mnt/target
    echo "$hostname" > /mnt/target/etc/hostname
    sed -i "s/127.0.1.1.*/127.0.1.1\t$hostname/" /mnt/target/etc/hosts 2>/dev/null || \
        echo "127.0.1.1	$hostname" >> /mnt/target/etc/hosts
    
    sync
    umount /mnt/target 2>/dev/null || true
    
    # Deactivate LVM to ensure clean state for reboot
    vgchange -an vg0 2>/dev/null || true
}

install_post_scripts() {
    log_step "Installing post-install scripts..."
    
    # Find installer directory (reuse find_installer_dir function)
    local installer_dir
    installer_dir=$(find_installer_dir)
    
    if [ -f "$installer_dir/post-install-baremetal.sh" ]; then
        vgchange -ay vg0 2>/dev/null || true
        sleep 1
        mount /dev/vg0/root /mnt/target
        
        # Copy to user's home directory
        cp "$installer_dir/post-install-baremetal.sh" /mnt/target/home/ubuser/
        chown 1000:1000 /mnt/target/home/ubuser/post-install-baremetal.sh
        chmod +x /mnt/target/home/ubuser/post-install-baremetal.sh
        
        sync
        umount /mnt/target 2>/dev/null || true
        vgchange -an vg0 2>/dev/null || true
        
        log_info "Post-install script copied to /home/ubuser/post-install-baremetal.sh"
    fi
}

main() {
    clear
    echo ""
    echo -e "${CYAN}================================================${NC}"
    echo -e "${CYAN}    Ubuntu System Image Installer${NC}"
    echo -e "${CYAN}================================================${NC}"
    echo ""
    if [ "$AUTO_MODE" = true ]; then
        echo -e "${YELLOW}*** AUTOMATIC INSTALLATION MODE ***${NC}"
        echo ""
    fi
    echo "This installer will clone a pre-configured Ubuntu system"
    echo "to your target disk. No internet connection required."
    echo ""
    echo "Pre-installed software:"
    echo "  - Ubuntu 24.04 Server"
    echo "  - XFCE Desktop"
    echo "  - Build tools (gcc, make, cmake)"
    echo "  - Rust toolchain"
    echo "  - Virtualization tools"
    echo ""
    echo "Default login: ubuser / ubuser"
    echo ""
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "This installer must be run as root!"
        log_info "Run: sudo /cdrom/installer/install.sh"
        exit 1
    fi
    
    # Check image exists
    if [ ! -f "$IMAGE_FILE" ]; then
        log_error "System image not found: $IMAGE_FILE"
        exit 1
    fi
    
    log_info "Image file: $IMAGE_FILE ($(du -h "$IMAGE_FILE" | cut -f1))"
    echo ""
    
    select_target_disk
    wipe_target_disk
    clone_image
    fix_partitions
    regenerate_uuids
    configure_network
    fix_bootloader
    set_hostname
    install_post_scripts
    
    echo ""
    echo -e "${GREEN}================================================${NC}"
    echo -e "${GREEN}    Installation Complete!${NC}"
    echo -e "${GREEN}================================================${NC}"
    echo ""
    echo "You can now reboot and remove the USB drive."
    echo ""
    echo "Default login credentials:"
    echo "  Username: ubuser"
    echo "  Password: ubuser"
    echo ""
    echo "To configure swap (recommended for bare metal):"
    echo "  ./post-install-baremetal.sh"
    echo ""
    
    if [ "$AUTO_MODE" = true ]; then
        log_info "Auto mode: Installation finished. Reboot manually when ready."
        echo ""
        echo "Run 'reboot' to restart the system."
    else
        read -p "Press Enter to reboot, or Ctrl+C to stay in live environment..."
        reboot
    fi
}

main "$@"
INSTALLER_SCRIPT

    chmod +x "$WORK_DIR/iso/installer/install.sh"
}

create_autorun() {
    log_info "Creating auto-run configuration..."
    
    # Create a script that runs on boot to prompt installation
    cat > "$WORK_DIR/iso/installer/autoinstall.sh" << 'AUTORUN'
#!/bin/bash
# Auto-run installer on boot
clear
echo ""
echo "Ubuntu System Installer"
echo "========================"
echo ""
echo "To start the installation, run:"
echo ""
echo "  sudo /cdrom/installer/install.sh"
echo ""
echo "Or for automatic installation (DANGEROUS - formats largest non-USB disk):"
echo ""
echo "  sudo /cdrom/installer/install.sh --auto"
echo ""
AUTORUN
    chmod +x "$WORK_DIR/iso/installer/autoinstall.sh"
    
    # Create a systemd service for automatic installation
    mkdir -p "$WORK_DIR/iso/installer/systemd"
    
    cat > "$WORK_DIR/iso/installer/systemd/auto-installer.service" << 'SERVICE'
[Unit]
Description=Automatic System Installer
After=multi-user.target graphical.target
ConditionKernelCommandLine=autoinstall

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 5
ExecStart=/cdrom/installer/install.sh --auto
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes

[Install]
WantedBy=multi-user.target
SERVICE

    # Create a script to be sourced by casper that sets up the autoinstaller
    mkdir -p "$WORK_DIR/iso/casper/scripts"
    cat > "$WORK_DIR/iso/installer/setup-autoinstall.sh" << 'SETUP'
#!/bin/bash
# This script is run from /etc/rc.local or similar to setup autoinstall
if grep -q "autoinstall" /proc/cmdline; then
    echo "Autoinstall mode detected, starting installer..."
    # Copy and enable the service
    if [ -f /cdrom/installer/systemd/auto-installer.service ]; then
        cp /cdrom/installer/systemd/auto-installer.service /etc/systemd/system/
        systemctl daemon-reload
        systemctl start auto-installer.service
    else
        # Fallback: run directly
        /cdrom/installer/install.sh --auto
    fi
fi
SETUP
    chmod +x "$WORK_DIR/iso/installer/setup-autoinstall.sh"
    
    # Create rc.local hook for casper live system
    cat > "$WORK_DIR/iso/installer/rc.local" << 'RCLOCAL'
#!/bin/bash
# Check for autoinstall mode and run installer
if grep -q "autoinstall" /proc/cmdline; then
    # Wait for system to settle
    sleep 5
    # Run installer in auto mode on tty1
    openvt -c 1 -s -w -- /cdrom/installer/install.sh --auto
fi
exit 0
RCLOCAL
    chmod +x "$WORK_DIR/iso/installer/rc.local"
}

patch_live_filesystem() {
    log_info "Patching live filesystem for autoinstall support..."
    
    # Ubuntu Server live ISO uses layered squashfs
    # We need to patch the installer squashfs that actually boots
    local squashfs=""
    for sq in "$WORK_DIR/iso/casper/ubuntu-server-minimal.ubuntu-server.installer.squashfs" \
              "$WORK_DIR/iso/casper/ubuntu-server-minimal.squashfs"; do
        if [ -f "$sq" ]; then
            squashfs="$sq"
            break
        fi
    done
    
    if [ -z "$squashfs" ]; then
        log_warn "No suitable squashfs found, skipping live filesystem patching"
        return 0
    fi
    
    log_info "Using squashfs: $(basename "$squashfs")"
    
    # Extract squashfs
    log_info "Extracting live filesystem..."
    rm -rf "$WORK_DIR/squashfs-root"
    unsquashfs -d "$WORK_DIR/squashfs-root" "$squashfs"
    
    # Create autoinstall script that will be called from multiple places
    mkdir -p "$WORK_DIR/squashfs-root/usr/local/bin"
    cat > "$WORK_DIR/squashfs-root/usr/local/bin/run-autoinstall" << 'AUTOINSTALL_SCRIPT'
#!/bin/bash
# Run autoinstall if kernel parameter is present
if ! grep -q "autoinstall" /proc/cmdline; then
    exit 0
fi

# Prevent running multiple times
LOCKFILE="/tmp/autoinstall.lock"
if [ -f "$LOCKFILE" ]; then
    exit 0
fi
touch "$LOCKFILE"

# Wait for system to settle and media to mount
sleep 15

# Find installer
INSTALLER=""
for path in /cdrom/installer/install.sh \
            /run/live/medium/installer/install.sh \
            /media/cdrom/installer/install.sh \
            /media/*/installer/install.sh; do
    if [ -f "$path" ]; then
        INSTALLER="$path"
        break
    fi
done

if [ -z "$INSTALLER" ]; then
    echo "ERROR: Cannot find installer. Trying to mount media..."
    # Try to mount cdrom manually
    mkdir -p /cdrom
    for dev in /dev/sr0 /dev/cdrom /dev/sda /dev/sdb; do
        if [ -b "$dev" ]; then
            mount "$dev" /cdrom 2>/dev/null && break
            mount "${dev}1" /cdrom 2>/dev/null && break
        fi
    done
    
    if [ -f /cdrom/installer/install.sh ]; then
        INSTALLER="/cdrom/installer/install.sh"
    fi
fi

if [ -n "$INSTALLER" ]; then
    echo "Starting automatic installation from: $INSTALLER"
    exec "$INSTALLER" --auto
else
    echo "ERROR: Installer not found!"
    echo "Available mounts:"
    mount | grep -E "cdrom|media|live"
    echo ""
    echo "Please run manually: sudo /cdrom/installer/install.sh --auto"
fi
AUTOINSTALL_SCRIPT
    chmod +x "$WORK_DIR/squashfs-root/usr/local/bin/run-autoinstall"
    
    # Add systemd service
    cat > "$WORK_DIR/squashfs-root/etc/systemd/system/auto-installer.service" << 'SERVICE'
[Unit]
Description=Automatic System Installer
After=multi-user.target local-fs.target remote-fs.target
Wants=local-fs.target
ConditionKernelCommandLine=autoinstall

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/run-autoinstall
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes

[Install]
WantedBy=multi-user.target
SERVICE

    # Enable the service
    mkdir -p "$WORK_DIR/squashfs-root/etc/systemd/system/multi-user.target.wants"
    ln -sf /etc/systemd/system/auto-installer.service \
        "$WORK_DIR/squashfs-root/etc/systemd/system/multi-user.target.wants/auto-installer.service"
    
    # Also add to rc.local as fallback
    cat > "$WORK_DIR/squashfs-root/etc/rc.local" << 'RCLOCAL'
#!/bin/bash
/usr/local/bin/run-autoinstall &
exit 0
RCLOCAL
    chmod +x "$WORK_DIR/squashfs-root/etc/rc.local"
    
    # Enable rc-local service
    mkdir -p "$WORK_DIR/squashfs-root/etc/systemd/system/multi-user.target.wants"
    ln -sf /lib/systemd/system/rc-local.service \
        "$WORK_DIR/squashfs-root/etc/systemd/system/multi-user.target.wants/rc-local.service" 2>/dev/null || true
    
    # Add getty autologin with autoinstall for tty1 (as another fallback)
    mkdir -p "$WORK_DIR/squashfs-root/etc/systemd/system/getty@tty1.service.d"
    cat > "$WORK_DIR/squashfs-root/etc/systemd/system/getty@tty1.service.d/override.conf" << 'GETTY'
[Service]
ExecStartPost=-/bin/bash -c 'sleep 5; /usr/local/bin/run-autoinstall'
GETTY

    # Disable subiquity installer services (Ubuntu Server installer)
    log_info "Disabling subiquity installer..."
    
    # Mask the subiquity snap mount to prevent it from loading
    ln -sf /dev/null "$WORK_DIR/squashfs-root/etc/systemd/system/snap-subiquity-6806.mount" 2>/dev/null || true
    
    # Mask all subiquity-related services
    for svc in subiquity.service \
               snap.subiquity.subiquity.service \
               snap.subiquity.subiquity-service.service \
               snap.subiquity.subiquity-server.service \
               snap.subiquity.console-conf.service \
               console-conf.service console-conf@.service; do
        # Mask the service to prevent it from starting
        ln -sf /dev/null "$WORK_DIR/squashfs-root/etc/systemd/system/$svc" 2>/dev/null || true
    done
    
    # Remove subiquity services from wants directories
    rm -f "$WORK_DIR/squashfs-root/etc/systemd/system/"*".wants/subiquity"* 2>/dev/null || true
    rm -f "$WORK_DIR/squashfs-root/etc/systemd/system/"*".wants/snap.subiquity"* 2>/dev/null || true
    rm -f "$WORK_DIR/squashfs-root/etc/systemd/system/"*".wants/snap-subiquity"* 2>/dev/null || true
    rm -f "$WORK_DIR/squashfs-root/etc/systemd/system/"*".wants/console-conf"* 2>/dev/null || true
    rm -f "$WORK_DIR/squashfs-root/etc/systemd/system/snapd.mounts.target.wants/snap-subiquity"* 2>/dev/null || true
    
    # Remove the subiquity snap binary symlink
    rm -f "$WORK_DIR/squashfs-root/snap/bin/subiquity" 2>/dev/null || true
    rm -f "$WORK_DIR/squashfs-root/snap/bin/subiquity.curtin" 2>/dev/null || true
    rm -f "$WORK_DIR/squashfs-root/snap/bin/subiquity.probert" 2>/dev/null || true
    
    # Delete the actual subiquity service files
    rm -f "$WORK_DIR/squashfs-root/etc/systemd/system/snap.subiquity.subiquity-server.service" 2>/dev/null || true
    rm -f "$WORK_DIR/squashfs-root/etc/systemd/system/snap.subiquity.subiquity-service.service" 2>/dev/null || true

    # Repack squashfs
    log_info "Repacking live filesystem..."
    rm -f "$squashfs"
    mksquashfs "$WORK_DIR/squashfs-root" "$squashfs" -comp xz -b 1M -Xbcj x86
    rm -rf "$WORK_DIR/squashfs-root"
    
    log_info "Live filesystem patched successfully"
}

modify_grub() {
    log_info "Modifying GRUB boot menu..."
    
    # Modify GRUB config
    # Key parameters:
    # - systemd.unit=multi-user.target: Boot to shell, not graphical/installer
    # - subiquity.autoinstallpath="": Disable subiquity autoinstall
    # - autoinstall: Our custom parameter for our installer
    cat > "$WORK_DIR/iso/boot/grub/grub.cfg" << 'GRUBCFG'
set timeout=10
set default=0

# Search for the volume containing /casper/vmlinuz and set it as root
search --no-floppy --set=root --file /casper/vmlinuz

menuentry "Automatic Install (formats largest disk)" {
    set gfxpayload=keep
    linux   /casper/vmlinuz boot=casper quiet autoinstall systemd.unit=multi-user.target subiquity.autoinstallpath= ---
    initrd  /casper/initrd
}

menuentry "Manual Install (interactive shell)" {
    set gfxpayload=keep
    linux   /casper/vmlinuz boot=casper quiet systemd.unit=multi-user.target subiquity.autoinstallpath= ---
    initrd  /casper/initrd
}

menuentry "Ubuntu Server Installer (original)" {
    set gfxpayload=keep
    linux   /casper/vmlinuz boot=casper quiet ---
    initrd  /casper/initrd
}

menuentry "Boot from Hard Disk" {
    exit
}
GRUBCFG
}

create_efi_image() {
    log_info "Extracting and patching EFI boot image from source ISO..."
    
    local efi_img="$WORK_DIR/iso/boot/grub/efi.img"
    local efi_mount="$WORK_DIR/efi_mount"
    
    # Extract the EFI partition from the original Ubuntu ISO
    # The EFI partition is appended to the ISO - we need to find its offset
    # Format: appended_partition_2_start_1610304s_size_10160d
    local efi_info=$(xorriso -indev "$UBUNTU_ISO" -report_el_torito as_mkisofs 2>&1 | \
        grep -oP "appended_partition_2_start_\K[0-9]+s_size_[0-9]+d")
    local efi_start_sector=$(echo "$efi_info" | grep -oP "^[0-9]+")
    local efi_size_sectors=$(echo "$efi_info" | grep -oP "size_\K[0-9]+")
    
    if [ -n "$efi_start_sector" ] && [ -n "$efi_size_sectors" ]; then
        log_info "Extracting EFI partition: start=$efi_start_sector sectors (2048-byte), size=$efi_size_sectors sectors (512-byte)"
        # Extract the EFI partition
        # Note: start sector is in ISO 2048-byte sectors, size is in 512-byte sectors
        # Convert size to 2048-byte sectors: ceil(size_512 * 512 / 2048) = ceil(size_512 / 4)
        local efi_count_2k=$(( (efi_size_sectors + 3) / 4 ))
        dd if="$UBUNTU_ISO" of="$efi_img" bs=2048 skip="$efi_start_sector" count="$efi_count_2k" 2>/dev/null
    else
        log_warn "Could not find EFI partition info, creating new EFI image..."
        # Fallback: create a new EFI image
        local efi_size_kb=$(du -sk "$WORK_DIR/iso/EFI" 2>/dev/null | cut -f1)
        local boot_grub_size_kb=$(du -sk "$WORK_DIR/iso/boot/grub" 2>/dev/null | cut -f1)
        local total_size_kb=$(( (efi_size_kb + boot_grub_size_kb + 2048 + 511) / 512 * 512 ))
        
        if [ "$total_size_kb" -lt 8192 ]; then
            total_size_kb=8192
        fi
        
        dd if=/dev/zero of="$efi_img" bs=1K count="$total_size_kb" 2>/dev/null
        mkfs.vfat -F 12 "$efi_img" >/dev/null
        
        mkdir -p "$efi_mount"
        mount -o loop "$efi_img" "$efi_mount"
        cp -a "$WORK_DIR/iso/EFI" "$efi_mount/"
        mkdir -p "$efi_mount/boot/grub"
        cp -a "$WORK_DIR/iso/boot/grub/grub.cfg" "$efi_mount/boot/grub/"
        cp -a "$WORK_DIR/iso/boot/grub/fonts" "$efi_mount/boot/grub/" 2>/dev/null || true
        umount "$efi_mount"
        rmdir "$efi_mount"
    fi
    
    # Now patch the grub.cfg inside the EFI image
    mkdir -p "$efi_mount"
    mount -o loop "$efi_img" "$efi_mount"
    
    # Update grub.cfg in the EFI image
    if [ -d "$efi_mount/boot/grub" ]; then
        cp "$WORK_DIR/iso/boot/grub/grub.cfg" "$efi_mount/boot/grub/grub.cfg"
        log_info "Updated grub.cfg in EFI image"
    else
        mkdir -p "$efi_mount/boot/grub"
        cp "$WORK_DIR/iso/boot/grub/grub.cfg" "$efi_mount/boot/grub/grub.cfg"
    fi
    
    sync
    umount "$efi_mount"
    rmdir "$efi_mount"
    
    log_info "EFI image ready: $(du -h "$efi_img" | cut -f1)"
}

create_iso() {
    log_info "Creating bootable ISO..."
    
    # Extract MBR for hybrid boot
    dd if="$UBUNTU_ISO" bs=1 count=432 of="$WORK_DIR/isohdpfx.bin" 2>/dev/null
    
    # Use the EFI image we created/extracted
    local efi_img="$WORK_DIR/iso/boot/grub/efi.img"
    if [ ! -f "$efi_img" ]; then
        log_error "EFI image not found: $efi_img"
        exit 1
    fi
    
    # Calculate EFI image size in 512-byte sectors for boot-load-size
    local efi_size_bytes=$(stat -c%s "$efi_img")
    local efi_size_sectors=$(( (efi_size_bytes + 511) / 512 ))
    log_info "EFI image: $efi_size_bytes bytes, $efi_size_sectors sectors"
    
    xorriso -as mkisofs \
        -r -V "Ubuntu Installer" \
        -iso-level 3 \
        -o "$OUTPUT_ISO" \
        --grub2-mbr "$WORK_DIR/isohdpfx.bin" \
        --protective-msdos-label \
        -partition_offset 16 \
        --mbr-force-bootable \
        -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "$efi_img" \
        -appended_part_as_gpt \
        -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
        -c '/boot.catalog' \
        -b '/boot/grub/i386-pc/eltorito.img' \
        -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
        -eltorito-alt-boot \
        -e '--interval:appended_partition_2:::' \
        -no-emul-boot \
        -boot-load-size "$efi_size_sectors" \
        "$WORK_DIR/iso"
    
    log_info "Created: $OUTPUT_ISO ($(du -h "$OUTPUT_ISO" | cut -f1))"
}

cleanup() {
    log_info "Cleaning up..."
    rm -rf "$WORK_DIR"
}

main() {
    echo ""
    log_info "=========================================="
    log_info "Ubuntu Image Installer ISO Builder"
    log_info "=========================================="
    echo ""
    
    check_root
    check_deps
    check_packer_image
    download_iso
    extract_iso
    compress_packer_image
    create_installer_script
    create_autorun
    patch_live_filesystem
    modify_grub
    create_efi_image
    create_iso
    cleanup
    
    echo ""
    log_info "=========================================="
    log_info "Build Complete!"
    log_info "=========================================="
    echo ""
    log_info "Output: $SCRIPT_DIR/$OUTPUT_ISO"
    echo ""
    log_info "To write to USB drive:"
    log_info "  sudo dd if=$OUTPUT_ISO of=/dev/sdX bs=4M status=progress conv=fsync"
    echo ""
    log_info "Boot options:"
    log_info "  - 'Automatic Install': Formats largest non-USB disk automatically"
    log_info "  - 'Manual Install': Run 'sudo /cdrom/installer/install.sh' manually"
    echo ""
}

main "$@"
