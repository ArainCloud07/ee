#!/bin/bash
# ============================================
#  KVM Setup for Pterodactyl Wings
#  Run as ROOT on your Wings node
#  Usage: bash kvm-setup.sh
# ============================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo "============================================"
echo "  KVM Setup for Pterodactyl Wings"
echo "============================================"
echo ""

# Must be root
if [ "$(id -u)" != "0" ]; then
    error "This script must be run as root. Use: sudo bash kvm-setup.sh"
fi

# Check KVM support
info "Checking KVM support..."
if [ ! -e /dev/kvm ]; then
    error "/dev/kvm not found. Your VPS/server does not support KVM (nested virtualization may be disabled)."
fi
info "/dev/kvm found!"

# Step 1: KVM permissions
info "Setting KVM device permissions..."
chmod 666 /dev/kvm
echo 'KERNEL=="kvm", MODE="0666"' | tee /etc/udev/rules.d/99-kvm.rules > /dev/null
udevadm control --reload-rules
udevadm trigger
info "KVM permissions set."

# Step 2: Install dependencies
info "Installing dependencies..."
apt-get update -qq
apt-get install -y -qq git wget golang-go python3 2>/dev/null || true

# Try to get a recent Go if system Go is too old
GO_VERSION=$(go version 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || echo "0")
GO_MAJOR=$(echo $GO_VERSION | cut -d. -f1)
GO_MINOR=$(echo $GO_VERSION | cut -d. -f2)
if [ "$GO_MAJOR" -lt 1 ] || { [ "$GO_MAJOR" -eq 1 ] && [ "$GO_MINOR" -lt 21 ]; }; then
    warn "Go version too old ($GO_VERSION). Installing Go 1.22..."
    wget -q -O /tmp/go.tar.gz https://go.dev/dl/go1.22.3.linux-amd64.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm -f /tmp/go.tar.gz
    export PATH=$PATH:/usr/local/go/bin
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
fi
export PATH=$PATH:/usr/local/go/bin
info "Go version: $(go version)"

# Step 3: Clone Wings
info "Cloning Pterodactyl Wings..."
rm -rf /tmp/wings-kvm-build
git clone --depth=1 https://github.com/pterodactyl/wings /tmp/wings-kvm-build 2>&1 | tail -2
cd /tmp/wings-kvm-build

# Step 4: Apply KVM patch using Python
info "Applying KVM device passthrough patch..."

python3 << 'PYEOF'
import sys

container_go = "environment/docker/container.go"

with open(container_go, "r") as f:
    content = f.read()

# Check if already patched
if "PathOnHost" in content and "/dev/kvm" in content:
    print("Already patched, skipping.")
    sys.exit(0)

# Add "os" import if missing
if '"os"' not in content:
    content = content.replace(
        '"strconv"',
        '"os"\n\t"strconv"'
    )
    print("Added os import.")

# Add Devices field to HostConfig before closing brace
# Target: the line with UsernsMode (last field before closing })
old_line = '\t\tUsernsMode:  container.UsernsMode(cfg.Docker.UsernsMode),\n\t}'
new_line = '''\t\tUsernsMode:  container.UsernsMode(cfg.Docker.UsernsMode),

\t\t// KVM device passthrough - allows VMs to use hardware acceleration
\t\tDevices: func() []container.DeviceMapping {
\t\t\tif _, statErr := os.Stat("/dev/kvm"); statErr == nil {
\t\t\t\treturn []container.DeviceMapping{{
\t\t\t\t\tPathOnHost:        "/dev/kvm",
\t\t\t\t\tPathInContainer:   "/dev/kvm",
\t\t\t\t\tCgroupPermissions: "rwm",
\t\t\t\t}}
\t\t\t}
\t\t\treturn nil
\t\t}(),
\t}'''

if old_line in content:
    content = content.replace(old_line, new_line)
    print("KVM device patch applied successfully!")
else:
    # Try alternative ending (in case formatting differs)
    old_line2 = '\t\tUsernsMode: container.UsernsMode(cfg.Docker.UsernsMode),\n\t}'
    new_line2 = new_line.replace('\t\tUsernsMode:  container.', '\t\tUsernsMode: container.')
    if old_line2 in content:
        content = content.replace(old_line2, new_line2)
        print("KVM device patch applied (alt format)!")
    else:
        print("WARNING: Could not find patch location. Printing context for debug:")
        for i, line in enumerate(content.split('\n')):
            if 'UsernsMode' in line:
                print(f"  Line {i}: {repr(line)}")
        sys.exit(1)

with open(container_go, "w") as f:
    f.write(content)

print("Patch written to file.")
PYEOF

# Step 5: Build Wings
info "Building Wings (this may take a few minutes)..."
export CGO_ENABLED=0
go build -ldflags="-s -w" -o wings-patched . 2>&1 | tail -5
info "Build complete."

# Step 6: Install patched Wings
info "Installing patched Wings binary..."
WINGS_PATH=$(which wings 2>/dev/null || echo "/usr/local/bin/wings")

if [ -f "$WINGS_PATH" ]; then
    cp "$WINGS_PATH" "${WINGS_PATH}.bak"
    info "Original Wings backed up to ${WINGS_PATH}.bak"
fi

cp wings-patched "$WINGS_PATH"
chmod +x "$WINGS_PATH"
info "Patched Wings installed at $WINGS_PATH"

# Step 7: Restart Wings
info "Restarting Wings service..."
if systemctl is-active --quiet wings; then
    systemctl restart wings
    sleep 2
    if systemctl is-active --quiet wings; then
        info "Wings restarted successfully."
    else
        warn "Wings may have failed to restart. Check: systemctl status wings"
    fi
else
    warn "Wings service not found or not running. Start it manually: systemctl start wings"
fi

# Cleanup
rm -rf /tmp/wings-kvm-build

echo ""
echo "============================================"
echo "  KVM Setup Complete!"
echo "============================================"
echo ""
echo "  /dev/kvm permissions: $(stat -c '%a' /dev/kvm 2>/dev/null || echo 'unknown')"
echo "  Wings binary: $WINGS_PATH"
echo "  Backup: ${WINGS_PATH}.bak"
echo ""
echo "  Next steps:"
echo "  1. Import the KVM-VPS.json egg in your panel"
echo "  2. Create a new server with the egg"
echo "  3. Install and start - sshx link will appear in console"
echo "============================================"
