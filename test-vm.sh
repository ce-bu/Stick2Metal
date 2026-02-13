#!/bin/bash
#
# Test the Ubuntu installer ISO in a VM
# Simulates booting from the installer USB and installing to a target disk
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Configuration
ISO_IMAGE="${1:-ubuntu-installer.iso}"
TARGET_DISK="test-target.qcow2"
DISK_SIZE="40G"
MEMORY="4096"
CPUS="2"
OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS="/usr/share/OVMF/OVMF_VARS_4M.fd"
LOCAL_OVMF_VARS="test_OVMF_VARS.fd"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    cat << EOF
Ubuntu Installer ISO Test Script

Usage: $0 [OPTIONS]

OPTIONS:
    --install, -i       Boot from ISO and run installer (default)
    --boot, -b          Boot from installed system
    --clean, -c         Remove test disk and OVMF vars
    --help, -h          Show this help

WORKFLOW:
    1. Build the Packer image first: ./build.sh
    2. Build the installer ISO: sudo ./build-installer-iso.sh
    3. Run this script to test: ./test-vm.sh
    4. In the live environment, run: sudo /cdrom/installer/install.sh
    5. After install, test boot: ./test-vm.sh --boot
    6. Login with ubuser/ubuser

EOF
}

check_deps() {
    if ! command -v qemu-system-x86_64 &> /dev/null; then
        log_error "qemu-system-x86_64 not found"
        log_info "Install with: sudo apt-get install -y qemu-system-x86"
        exit 1
    fi
    
    if [ ! -f "$OVMF_CODE" ]; then
        log_error "OVMF firmware not found: $OVMF_CODE"
        log_info "Install with: sudo apt-get install -y ovmf"
        exit 1
    fi
}

check_iso() {
    if [ ! -f "$ISO_IMAGE" ]; then
        log_error "ISO not found: $ISO_IMAGE"
        log_info "Build it with: sudo ./build-installer-iso.sh"
        exit 1
    fi
}

create_target_disk() {
    if [ ! -f "$TARGET_DISK" ]; then
        log_info "Creating target disk: $TARGET_DISK ($DISK_SIZE)"
        qemu-img create -f qcow2 "$TARGET_DISK" "$DISK_SIZE"
    else
        log_info "Using existing target disk: $TARGET_DISK"
    fi
}

setup_ovmf() {
    # Always reset OVMF vars to ensure clean boot entries
    log_info "Setting up fresh UEFI firmware..."
    cp "$OVMF_VARS" "$LOCAL_OVMF_VARS"
}

run_install() {
    check_iso
    create_target_disk
    setup_ovmf
    
    log_info "Starting installer VM..."
    log_info "ISO: $ISO_IMAGE"
    log_info "Target: $TARGET_DISK"
    log_info ""
    log_info "After boot, run in the live environment:"
    log_info "  sudo /cdrom/installer/install.sh"
    log_info ""
    log_info "Press Ctrl+Alt+G to release mouse"
    log_info ""
    
    qemu-system-x86_64 \
        -enable-kvm \
        -machine q35 \
        -cpu host \
        -m "$MEMORY" \
        -smp "$CPUS" \
        -vga std \
        -display gtk \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$LOCAL_OVMF_VARS" \
        -drive file="$ISO_IMAGE",format=raw,media=cdrom,readonly=on,if=none,id=cdrom \
        -device ide-cd,drive=cdrom,bootindex=0 \
        -drive file="$TARGET_DISK",format=qcow2,if=none,id=target \
        -device virtio-blk-pci,drive=target,bootindex=1 \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::2222-:22 \
        -serial mon:stdio
}

run_boot() {
    if [ ! -f "$TARGET_DISK" ]; then
        log_error "Target disk not found: $TARGET_DISK"
        log_info "Run installer first: $0 --install"
        exit 1
    fi
    
    setup_ovmf
    
    log_info "Booting installed system..."
    log_info "Disk: $TARGET_DISK"
    log_info ""
    log_info "Login: ubuser / ubuser"
    log_info "SSH: ssh -p 2222 ubuser@localhost"
    log_info ""
    
    qemu-system-x86_64 \
        -enable-kvm \
        -machine q35 \
        -cpu host \
        -m "$MEMORY" \
        -smp "$CPUS" \
        -vga std \
        -display gtk \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$LOCAL_OVMF_VARS" \
        -drive file="$TARGET_DISK",format=qcow2,if=none,id=target \
        -device virtio-blk-pci,drive=target,bootindex=0 \
        -boot menu=on \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::2222-:22 \
        -serial mon:stdio
}

clean() {
    log_info "Cleaning up test files..."
    rm -f "$TARGET_DISK" "$LOCAL_OVMF_VARS" test-install-disk.qcow2
    log_info "Done"
}

# Main
check_deps

case "${1:-}" in
    --install|-i|"")
        run_install
        ;;
    --boot|-b)
        run_boot
        ;;
    --clean|-c)
        clean
        ;;
    --help|-h)
        usage
        ;;
    *)
        # If argument looks like a file, use it as ISO
        if [ -f "$1" ]; then
            ISO_IMAGE="$1"
            run_install
        else
            log_error "Unknown option: $1"
            usage
            exit 1
        fi
        ;;
esac
