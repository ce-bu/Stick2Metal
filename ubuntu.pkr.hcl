packer {
  required_plugins {
    qemu = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "ubuntu_iso_url" {
  type    = string
  default = "https://releases.ubuntu.com/24.04/ubuntu-24.04.3-live-server-amd64.iso"
}

variable "ubuntu_iso_checksum" {
  type    = string
  default = "file:https://releases.ubuntu.com/24.04/SHA256SUMS"
}

variable "vm_name" {
  type    = string
  default = "ubuntu-24.04-autoinstall"
}

variable "disk_size" {
  type    = string
  default = "32G"
}

variable "memory" {
  type    = string
  default = "4096"
}

variable "cpus" {
  type    = string
  default = "4"
}

variable "headless" {
  type    = bool
  default = false
}

variable "ssh_username" {
  type    = string
  default = "ubuser"
}

variable "ssh_password" {
  type    = string
  default = "ubuser"
}

source "qemu" "ubuntu" {
  iso_url           = var.ubuntu_iso_url
  iso_checksum      = var.ubuntu_iso_checksum
  output_directory  = "output"
  shutdown_command  = "echo '${var.ssh_password}' | sudo -S shutdown -P now"
  disk_size         = var.disk_size
  format            = "raw"
  accelerator       = "kvm"
  
  # UEFI firmware
  efi_firmware_code = "/usr/share/OVMF/OVMF_CODE_4M.fd"
  efi_firmware_vars = "/usr/share/OVMF/OVMF_VARS_4M.fd"
  efi_boot          = true
  
  # Non-headless mode with VGA
  headless          = var.headless
  vga               = "std"
  display           = "gtk"
  
  http_directory    = "http"
  http_port_min     = 8100
  http_port_max     = 8150
  
  ssh_username      = var.ssh_username
  ssh_password      = var.ssh_password
  ssh_port          = 22
  ssh_timeout       = "90m"
  ssh_handshake_attempts = 200
  ssh_wait_timeout  = "90m"
  
  vm_name           = var.vm_name
  net_device        = "virtio-net"
  disk_interface    = "virtio"
  
  memory            = var.memory
  cpus              = var.cpus
  
  qemuargs = [
    ["-m", "${var.memory}"],
    ["-smp", "${var.cpus}"],
    ["-vga", "std"],
    ["-display", "gtk"],
    ["-cpu", "host"],
    ["-boot", "d"],
  ]
  
  boot_wait = "5s"
  boot_command = [
    # Wait for GRUB menu to appear
    "<wait10>",
    # Press 'c' to enter GRUB command line
    "c",
    "<wait2>",
    # Set root to the CD-ROM
    "set root=(cd0)<enter><wait1>",
    # Load kernel with autoinstall
    "linux /casper/vmlinuz quiet autoinstall ds=nocloud-net\\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/<enter><wait1>",
    # Load initrd
    "initrd /casper/initrd<enter><wait1>",
    # Boot
    "boot<enter>"
  ]
}

build {
  name    = "ubuntu-autoinstall"
  sources = ["source.qemu.ubuntu"]

  # Wait for cloud-init to complete
  provisioner "shell" {
    inline = [
      "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do echo 'Waiting for cloud-init...'; sleep 5; done",
      "echo 'Cloud-init finished'"
    ]
  }

  # Fix any broken packages and update
  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get -f install -y",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y",
      "sudo dpkg --configure -a",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y"
    ]
  }

  # Install build-essential and development tools
  provisioner "shell" {
    inline = [
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing build-essential gcc g++ make cmake git curl wget pkg-config libssl-dev"
    ]
  }

  # Install XFCE desktop
  provisioner "shell" {
    inline = [
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing xfce4 xfce4-goodies xfce4-terminal lightdm lightdm-gtk-greeter xorg"
    ]
  }

  # Install graphics drivers (Mesa - Intel/AMD, works universally)
  provisioner "shell" {
    inline = [
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing mesa-utils mesa-vulkan-drivers libgl1-mesa-dri vainfo intel-media-va-driver-non-free mesa-va-drivers libvulkan1 vulkan-tools"
    ]
  }

  # Install additional utilities
  provisioner "shell" {
    inline = [
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing vim htop net-tools openssh-server atril gedit gparted"
    ]
  }

  # Install disk utilities
  provisioner "shell" {
    inline = [
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing ncdu duf squashfs-tools dosfstools ntfs-3g exfatprogs btrfs-progs xfsprogs lvm2 mdadm cryptsetup gdisk fdisk parted e2fsprogs smartmontools hdparm sdparm nvme-cli fio iotop sysstat"
    ]
  }

  # Install networking tools
  provisioner "shell" {
    inline = [
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing nftables iptables iputils-ping iputils-tracepath traceroute tcpdump wireshark tshark nmap netcat-openbsd socat iperf3 iproute2 bridge-utils vlan ethtool dnsutils whois mtr-tiny arping nethogs iftop bmon"
    ]
  }

  # Install Brave browser
  provisioner "shell" {
    inline = [
      "sudo curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg",
      "echo 'deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main' | sudo tee /etc/apt/sources.list.d/brave-browser-release.list > /dev/null",
      "sudo apt-get update",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y brave-browser"
    ]
  }

  # Install virtualization and additional tools
  provisioner "shell" {
    inline = [
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing jq virt-manager libxml2-utils virtiofsd libnss-libvirt m4 podman buildah perl freerdp3-x11 mc"
    ]
  }

  # Install Rust toolchain (latest stable)
  provisioner "shell" {
    inline = [
      "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable",
      "echo 'source $HOME/.cargo/env' >> ~/.bashrc",
      ". $HOME/.cargo/env && rustc --version"
    ]
  }

  # Install VS Code
  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y wget gpg",
      "wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg",
      "sudo install -D -o root -g root -m 644 packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg",
      "echo 'deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main' | sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null",
      "rm -f packages.microsoft.gpg",
      "sudo apt-get update",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y code"
    ]
  }

  # Install VS Code extensions
  provisioner "shell" {
    inline = [
      "code --install-extension rust-lang.rust-analyzer",
      "code --install-extension vadimcn.vscode-lldb",
      "code --install-extension tamasfe.even-better-toml",
      "code --install-extension drzix.hc-zenburn-vscode"
    ]
  }

  # Enable graphical login
  provisioner "shell" {
    inline = [
      "sudo systemctl set-default graphical.target",
      "sudo systemctl enable lightdm"
    ]
  }

  # Clean up for smaller image
  provisioner "shell" {
    inline = [
      "sudo apt-get autoremove -y",
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo rm -rf /tmp/*",
      "sudo rm -rf /var/tmp/*"
    ]
  }
}
