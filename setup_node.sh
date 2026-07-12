#!/bin/bash
set -e

VPS_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$VPS_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()  { echo -e "${GREEN}[OK]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
step() { echo -e "\n${CYAN}==> $1${NC}"; }

if [ "$(id -u)" -ne 0 ]; then
    fail "Run as root: sudo bash setup_node.sh"
fi

step "1/6 — Install LXD"
if [ -x /snap/bin/lxc ]; then
    ok "LXD snap already installed"
else
    for pkg in lxd lxd-client lxc; do
        if timeout 5 dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            echo "  Removing apt package: $pkg..."
            apt-get remove -y --purge "$pkg" || true
        fi
    done
    rm -f /usr/bin/lxc /usr/sbin/lxc /usr/bin/lxd /usr/sbin/lxd 2>/dev/null || true
    if ! command -v snap >/dev/null; then
        echo "  Installing snapd..."
        apt-get update
        apt-get install -y snapd
        systemctl enable snapd --now
    fi
    echo "  Installing LXD snap (this may take a minute)..."
    timeout 600 snap install lxd --channel=5.0/stable 2>&1
    ok "LXD installed via snap"
fi

export PATH="/snap/bin:$PATH"

step "  Waiting for LXD daemon..."
for i in $(seq 1 30); do
    if [ -S /var/snap/lxd/common/lxd/unix.socket ]; then
        break
    fi
    sleep 1
done
for i in $(seq 1 30); do
    if timeout 5 lxc version >/dev/null 2>&1; then
        echo "  LXD daemon ready after ~${i}s"
        break
    fi
    sleep 2
done
if [ ! -S /var/snap/lxd/common/lxd/unix.socket ]; then
    fail "LXD socket not found"
fi
ok "LXD running"

step "2/6 — Configure LXD"
if ! timeout 10 lxc storage show default >/dev/null 2>&1; then
    echo "  Creating storage pool 'default' (dir)..."
    timeout 60 lxc storage create default dir 2>&1 || true
    if ! timeout 10 lxc storage show default >/dev/null 2>&1; then
        echo "  WARNING: Could not create storage pool"
    else
        ok "Storage pool 'default' created"
    fi
else
    ok "Storage pool 'default' already exists"
fi

if ! timeout 10 lxc network list 2>/dev/null | grep -q "lxdbr0"; then
    echo "  Creating bridge network 'lxdbr0'..."
    timeout 30 lxc network create lxdbr0 \
        --type=bridge \
        ipv4.address=10.132.115.1/24 \
        ipv4.nat=true \
        ipv6.address=none 2>&1 || true
    ok "Bridge network 'lxdbr0' created"
else
    ok "Bridge network 'lxdbr0' already exists"
fi

echo ""
echo "  Storage pools:"
timeout 10 lxc storage list 2>/dev/null | sed 's/^/    /' || echo "  (unavailable)"
echo "  Networks:"
timeout 10 lxc network list 2>/dev/null | sed 's/^/    /' || echo "  (unavailable)"

step "3/6 — Pre-download Ubuntu LXC images"
for ver in 22.04 24.04 26.04; do
    if timeout 10 lxc image list 2>/dev/null | grep -q "$ver"; then
        ok "Ubuntu $ver already cached"
    else
        echo "  Downloading Ubuntu $ver..."
        timeout 300 lxc image copy "https://cloud-images.ubuntu.com/releases/$ver" "local:" \
            --protocol simplestreams --alias "$ver" --auto-update 2>&1 || \
        timeout 300 lxc image copy ubuntu:$ver local: --alias "$ver" --auto-update 2>&1 || \
        echo "  WARNING: Could not download Ubuntu $ver"
    fi
done
echo "  Cached images:"
timeout 15 lxc image list 2>/dev/null | sed 's/^/    /' || echo "  (unavailable)"
ok "LXC images ready"

step "4/6 — Install Python 3.10"
if command -v python3.10 >/dev/null && python3.10 -m venv --help >/dev/null 2>&1; then
    ok "Python 3.10 already installed"
else
    echo "  Installing Python 3.10 from deadsnakes PPA..."
    apt-get update
    apt-get install -y software-properties-common
    add-apt-repository ppa:deadsnakes/ppa -y
    apt-get update
    apt-get install -y python3.10 python3.10-venv python3.10-distutils || {
        echo "  Falling back to default python3..."
        apt-get install -y python3 python3-venv python3-pip
    }
    ok "Python 3.10 installed"
fi
echo "  $(python3.10 --version 2>/dev/null || python3 --version 2>/dev/null)"

step "5/6 — Install Python packages"
curl -sS https://bootstrap.pypa.io/get-pip.py | python3.10 2>/dev/null || python3 -m pip install --upgrade pip
python3.10 -m venv venv 2>/dev/null || python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install flask psutil gunicorn
ok "Python packages installed"

step "6/6 — Install system dependencies"
apt-get install -y socat
ok "socat installed"

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}   Node Agent Setup Complete (LXC)${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "  Start node agent:"
echo "    source venv/bin/activate"
echo "    python node.py --port=5001 --name=node1"
echo ""
echo "  Cached LXC images:"
timeout 10 lxc image list 2>/dev/null | sed 's/^/    /' || echo "    (none)"
echo ""
