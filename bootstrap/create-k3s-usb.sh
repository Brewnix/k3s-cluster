#!/bin/bash
# K3s Cluster Bootstrap Creator
# Creates bootable USB drive for K3s Kubernetes cluster installation

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging
LOG_FILE="/var/log/brewnix-k3s-bootstrap.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
}

info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

# Default configuration
SITE_CONFIG=""
USB_DEVICE=""
UBUNTU_ISO_URL="https://releases.ubuntu.com/22.04/ubuntu-22.04.3-live-server-amd64.iso"

usage() {
    cat << EOF
K3s Cluster Bootstrap Creator

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --site-config FILE    Path to site configuration YAML file
    --usb-device DEVICE   USB device path (e.g., /dev/sdb)
    --iso-url URL         Ubuntu ISO download URL
    --help               Show this help message

EXAMPLE:
    $0 --site-config /opt/brewnix/config/sites/k3s-cluster.yml --usb-device /dev/sdb

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --site-config)
            SITE_CONFIG="$2"
            shift 2
            ;;
        --usb-device)
            USB_DEVICE="$2"
            shift 2
            ;;
        --iso-url)
            UBUNTU_ISO_URL="$2"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate arguments
if [[ -z "$USB_DEVICE" ]]; then
    error "USB device not specified"
    exit 1
fi

if [[ -z "$SITE_CONFIG" ]]; then
    error "Site configuration file not specified"
    exit 1
fi

# Load site configuration
if [[ ! -f "$SITE_CONFIG" ]]; then
    error "Site configuration file not found: $SITE_CONFIG"
    exit 1
fi

log "Loading site configuration: $SITE_CONFIG"

# Extract configuration values
SITE_NAME=$(grep -E '^site_name:' "$SITE_CONFIG" | sed 's/.*: //' | tr -d '"')
NETWORK_VLAN=$(grep -E '^network:' "$SITE_CONFIG" -A 10 | grep -E 'vlan_id:' | sed 's/.*: //' | tr -d ' ')
NETWORK_RANGE=$(grep -E '^network:' "$SITE_CONFIG" -A 10 | grep -E 'ip_range:' | sed 's/.*: //' | tr -d '"')

# Extract K3s-specific configuration
K8S_NODES=$(grep -E '^kubernetes:' "$SITE_CONFIG" -A 10 | grep -E 'nodes:' | sed 's/.*: //' | tr -d ' ')
K8S_VERSION=$(grep -E '^kubernetes:' "$SITE_CONFIG" -A 10 | grep -E 'version:' | sed 's/.*: //' | tr -d '"')

# Set defaults
K8S_NODES=${K8S_NODES:-3}
K8S_VERSION=${K8S_VERSION:-"v1.28.0"}

log "Site: $SITE_NAME"
log "Network VLAN: $NETWORK_VLAN"
log "Network Range: $NETWORK_RANGE"
log "K3s Nodes: $K8S_NODES"
log "K3s Version: $K8S_VERSION"

# Validate USB device
if [[ ! -b "$USB_DEVICE" ]]; then
    error "Invalid USB device: $USB_DEVICE"
    exit 1
fi

# Get device size
DEVICE_SIZE=$(lsblk -b -n -o SIZE "$USB_DEVICE" | head -1)
DEVICE_SIZE_GB=$((DEVICE_SIZE / 1024 / 1024 / 1024))

if [[ $DEVICE_SIZE_GB -lt 8 ]]; then
    error "USB device too small. Need at least 8GB, got ${DEVICE_SIZE_GB}GB"
    exit 1
fi

log "USB Device: $USB_DEVICE (${DEVICE_SIZE_GB}GB)"

# Download Ubuntu ISO if not present
ISO_FILE="/tmp/ubuntu-k3s.iso"
if [[ ! -f "$ISO_FILE" ]]; then
    log "Downloading Ubuntu ISO..."
    if ! curl -L -o "$ISO_FILE" "$UBUNTU_ISO_URL"; then
        error "Failed to download Ubuntu ISO"
        exit 1
    fi
fi

# Verify ISO size (should be > 1GB)
ISO_SIZE=$(stat -c%s "$ISO_FILE" 2>/dev/null || stat -f%z "$ISO_FILE" 2>/dev/null || echo "0")
if [[ $ISO_SIZE -lt 1000000000 ]]; then
    error "Downloaded ISO file seems too small: $ISO_SIZE bytes"
    exit 1
fi

log "Ubuntu ISO ready: $(ls -lh "$ISO_FILE" | awk '{print $5}')"

# Create USB drive
log "Creating bootable USB drive..."

# Unmount any existing partitions
umount "${USB_DEVICE}"* 2>/dev/null || true

# Create partition table
log "Creating partition table..."
parted -s "$USB_DEVICE" mklabel gpt

# Create EFI partition
parted -s "$USB_DEVICE" mkpart EFI fat32 1MiB 512MiB
parted -s "$USB_DEVICE" set 1 esp on

# Create root partition
parted -s "$USB_DEVICE" mkpart root ext4 512MiB 100%

# Format partitions
log "Formatting partitions..."
mkfs.vfat -F 32 "${USB_DEVICE}1"
mkfs.ext4 "${USB_DEVICE}2"

# Mount partitions
EFI_MOUNT="/mnt/efi"
ROOT_MOUNT="/mnt/root"

mkdir -p "$EFI_MOUNT" "$ROOT_MOUNT"

mount "${USB_DEVICE}1" "$EFI_MOUNT"
mount "${USB_DEVICE}2" "$ROOT_MOUNT"

# Copy Ubuntu ISO content
log "Copying Ubuntu ISO content..."
mkdir -p "$ROOT_MOUNT/ubuntu"
mount -o loop "$ISO_FILE" /mnt/iso
cp -r /mnt/iso/* "$ROOT_MOUNT/ubuntu/"
umount /mnt/iso

# Create boot configuration
log "Creating boot configuration..."

# Create GRUB configuration
mkdir -p "$EFI_MOUNT/EFI/BOOT"
cat > "$EFI_MOUNT/EFI/BOOT/grub.cfg" << EOF
set timeout=5
set default=0

menuentry "Ubuntu K3s Cluster Installation" {
    linux /ubuntu/casper/vmlinuz initrd=/ubuntu/casper/initrd \\
          console=tty0 console=ttyS0,115200 \\
          net.ifnames=0 biosdevname=0 \\
          k3s-cluster=true \\
          site-config=/ubuntu/site-config.yml \\
          autoinstall ds=nocloud;s=/ubuntu/
    initrd /ubuntu/casper/initrd
}

menuentry "Ubuntu Server (Manual Installation)" {
    linux /ubuntu/casper/vmlinuz initrd=/ubuntu/casper/initrd \\
          console=tty0 console=ttyS0,115200 \\
          net.ifnames=0 biosdevname=0
    initrd /ubuntu/casper/initrd
}
EOF

# Copy GRUB EFI binary
if [[ -f "/usr/lib/grub/x86_64-efi/grub.efi" ]]; then
    cp "/usr/lib/grub/x86_64-efi/grub.efi" "$EFI_MOUNT/EFI/BOOT/bootx64.efi"
fi

# Create autoinstall configuration
log "Creating autoinstall configuration..."
mkdir -p "$ROOT_MOUNT/ubuntu/autoinstall"

cat > "$ROOT_MOUNT/ubuntu/autoinstall/user-data" << EOF
#cloud-config
autoinstall:
  version: 1
  identity:
    hostname: k3s-master-$SITE_NAME
    username: ubuntu
    password: "\$6\$exDY1mhS4KUYCE/2\$zmn9ToZwTKLhCw.b4/b.ZRTIZM30JZ4QrOQ2aOXJ8yk96xpcCof0kxKwuX1kqLG/ygbJ1f8wxED22bTL4F46P0"
  ssh:
    install-server: true
    authorized-keys: []
  network:
    version: 2
    ethernets:
      enp1s0:
        dhcp4: true
  storage:
    version: 1
    layout:
      name: lvm
  packages:
    - curl
    - wget
    - git
    - htop
    - vim
  user-data:
    disable_root: false
    package_update: true
    package_upgrade: true
    packages:
      - curl
      - wget
      - git
  late-commands:
    - curtin in-target --target=/target -- chmod +x /target/root/post-install.sh
    - curtin in-target --target=/target -- /target/root/post-install.sh
EOF

cat > "$ROOT_MOUNT/ubuntu/autoinstall/meta-data" << EOF
instance-id: k3s-cluster-$SITE_NAME
local-hostname: k3s-master-$SITE_NAME
EOF

# Create site configuration for installation
log "Creating site configuration for installation..."
cp "$SITE_CONFIG" "$ROOT_MOUNT/ubuntu/site-config.yml"

# Create post-install script
cat > "$ROOT_MOUNT/ubuntu/post-install.sh" << EOF
#!/bin/bash
# K3s Cluster Post-Installation Script

set -e

# Load site configuration
SITE_CONFIG="/ubuntu/site-config.yml"
if [[ -f "\$SITE_CONFIG" ]]; then
    SITE_NAME=\$(grep -E '^site_name:' "\$SITE_CONFIG" | sed 's/.*: //' | tr -d '"')
    K8S_NODES=\$(grep -E '^kubernetes:' "\$SITE_CONFIG" -A 10 | grep -E 'nodes:' | sed 's/.*: //' | tr -d ' ')
    K8S_VERSION=\$(grep -E '^kubernetes:' "\$SITE_CONFIG" -A 10 | grep -E 'version:' | sed 's/.*: //' | tr -d '"')
fi

# Set defaults
K8S_NODES=\${K8S_NODES:-3}
K8S_VERSION=\${K8S_VERSION:-"v1.28.0"}

# Install K3s
echo "Installing K3s version \$K8S_VERSION..."

# Install K3s master node
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="\$K8S_VERSION" sh -

# Wait for K3s to be ready
sleep 30

# Get node token for worker nodes
NODE_TOKEN=\$(cat /var/lib/rancher/k3s/server/node-token)

# Configure kubectl
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Install additional components
echo "Installing additional K3s components..."

# Install Helm
curl https://get.helm.sh/helm-v3.12.0-linux-amd64.tar.gz -o helm.tar.gz
tar -zxvf helm.tar.gz
mv linux-amd64/helm /usr/local/bin/helm
rm -rf linux-amd64 helm.tar.gz

# Install common Kubernetes tools
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/cloud/deploy.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml

# Create cluster info file for worker nodes
cat > /boot/k3s-cluster-info.txt << CLUSTER_INFO
K3s Cluster Information
=======================

Master Node: \$(hostname -I | awk '{print \$1}')
Node Token: \$NODE_TOKEN
K3s Version: \$K8S_VERSION
Expected Nodes: \$K8S_NODES

To join worker nodes:
curl -sfL https://get.k3s.io | K3S_URL=https://\$(hostname -I | awk '{print \$1}'):6443 K3S_TOKEN=\$NODE_TOKEN sh -

Dashboard URL: https://\$(hostname -I | awk '{print \$1})/kubernetes-dashboard/
CLUSTER_INFO

# Configure firewall
ufw allow 6443/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# Set up monitoring
cat > /etc/systemd/system/k3s-monitoring.service << MONSERVICE
[Unit]
Description=K3s Cluster Monitoring
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
ExecStart=/usr/local/bin/helm repo update
ExecStart=/usr/local/bin/helm install monitoring prometheus-community/kube-prometheus-stack
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
MONSERVICE

systemctl enable k3s-monitoring

echo "K3s cluster installation completed!"
echo "Master node is ready at: \$(hostname -I | awk '{print \$1}')"
echo "Node token for workers: \$NODE_TOKEN"
echo "Dashboard: https://\$(hostname -I | awk '{print \$1})/kubernetes-dashboard/"
EOF

chmod +x "$ROOT_MOUNT/ubuntu/post-install.sh"

# Cleanup
log "Cleaning up..."
umount "$EFI_MOUNT" "$ROOT_MOUNT"
rmdir "$EFI_MOUNT" "$ROOT_MOUNT"

# Remove temporary ISO
rm -f "$ISO_FILE"

log "K3s Cluster bootstrap USB created successfully!"
info "Insert the USB drive into your server and boot from it to begin installation."
info "The system will automatically install Ubuntu and set up a K3s Kubernetes cluster."
info "Additional worker nodes can join using the token provided in /boot/k3s-cluster-info.txt"
