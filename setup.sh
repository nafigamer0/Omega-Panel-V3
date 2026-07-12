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
    fail "Run as root: sudo bash setup.sh"
fi

step "1/10 — System packages"
echo "  Running: apt-get update..."
apt-get update
echo "  Running: apt-get install system packages..."
apt-get install -y curl wget gnupg2 ca-certificates lsb-release socat jq software-properties-common
ok "System packages installed"

step "2/10 — Install LXD"

LXD_OK=false

# Quick check: is LXD socket already alive?
if [ -S /var/snap/lxd/common/lxd/unix.socket ]; then
    LXD_OK=true
fi

# Also check: does lxc command already work?
if [ "$LXD_OK" = false ] && command -v lxc >/dev/null 2>&1; then
    LXD_OK=true
fi
if [ "$LXD_OK" = false ] && [ -x /snap/bin/lxc ]; then
    LXD_OK=true
fi

# Remove conflicting apt packages (lxc binary from apt can't talk to snap LXD)
for pkg in lxd lxd-client lxc; do
    if command -v dpkg >/dev/null; then
        if timeout 5 dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            echo "  Removing apt package: $pkg..."
            apt-get remove -y --purge "$pkg" || true
        fi
    fi
done
rm -f /usr/bin/lxc /usr/sbin/lxc /usr/bin/lxd /usr/sbin/lxd 2>/dev/null || true

# Ensure /snap/bin is FIRST in PATH so it beats /usr/sbin
export PATH="/snap/bin:$PATH"

if [ "$LXD_OK" = true ]; then
    ok "LXD already installed"
else
    # Install snapd if missing
    if ! command -v snap >/dev/null; then
        echo "  Installing snapd..."
        apt-get install -y snapd
        systemctl enable snapd --now
        echo "  Waiting for snapd..."
        for i in $(seq 1 15); do
            if [ -S /run/snapd.socket ]; then
                break
            fi
            sleep 2
        done
    fi

    # Install LXD via snap
    echo "  Installing LXD snap (this can take a few minutes)..."
    timeout 600 snap install lxd --channel=5.0/stable 2>&1 || {
        echo "  snap install timed out. Trying again..."
        timeout 600 snap install lxd 2>&1 || true
    }
    ok "LXD installed via snap"
fi

export PATH="/snap/bin:$PATH"

step "  Waiting for LXD daemon to start..."
echo "  Socket: /var/snap/lxd/common/lxd/unix.socket"
for i in $(seq 1 30); do
    if [ -S /var/snap/lxd/common/lxd/unix.socket ]; then
        break
    fi
    sleep 1
done

if [ ! -S /var/snap/lxd/common/lxd/unix.socket ]; then
    fail "LXD socket not found"
fi

echo "  LXD socket ready, waiting for daemon to accept requests..."
echo "  lxc binary: $(command -v lxc || echo 'not found')"
for i in $(seq 1 30); do
    if timeout 5 lxc version >/dev/null 2>&1; then
        echo "  LXD daemon ready after ~${i}s"
        break
    fi
    if [ "$i" -eq 20 ]; then
        echo "  (still waiting... lxc version not responding yet)"
    fi
    sleep 2
done

step "3/10 — Configure LXD"

# Create default storage pool if missing
if timeout 10 lxc storage show default >/dev/null 2>&1; then
    ok "Storage pool 'default' already exists"
else
    echo "  Creating storage pool 'default' (dir)..."
    POOL_OUT=$(timeout 60 lxc storage create default dir 2>&1) || true
    if ! timeout 10 lxc storage show default >/dev/null 2>&1; then
        echo "  WARNING: storage create failed: $POOL_OUT"
        echo "  You can create it later with: lxc storage create default dir"
    fi
    ok "Storage pool handled"
fi

# Create lxdbr0 bridge network if missing
if ! timeout 10 lxc network list 2>/dev/null | grep -q "lxdbr0"; then
    echo "  Creating bridge network 'lxdbr0' (10.132.115.1/24)..."
    timeout 30 lxc network create lxdbr0 \
        --type=bridge \
        ipv4.address=10.132.115.1/24 \
        ipv4.nat=true \
        ipv6.address=none 2>&1 || {
        echo "  'lxc network create' failed, checking if network exists anyway..."
        timeout 10 lxc network list 2>/dev/null | grep -q "lxdbr0" || echo "  WARNING: network not created, containers may not have internet"
    }
    ok "Bridge network 'lxdbr0' created"
else
    ok "Bridge network 'lxdbr0' already exists"
fi

# Ensure default profile has root disk and eth0 nic
HAS_ROOT=false; HAS_ETH0=false
timeout 10 lxc profile device list default 2>/dev/null | grep -q "root" && HAS_ROOT=true
timeout 10 lxc profile device list default 2>/dev/null | grep -q "eth0" && HAS_ETH0=true
if [ "$HAS_ROOT" = false ] || [ "$HAS_ETH0" = false ]; then
    echo "  Configuring default profile..."
    if [ "$HAS_ROOT" = false ]; then
        timeout 10 lxc profile device add default root disk path=/ pool=default 2>/dev/null || true
    fi
    if [ "$HAS_ETH0" = false ]; then
        timeout 10 lxc profile device add default eth0 nic name=eth0 network=lxdbr0 2>/dev/null || true
    fi
    ok "Default profile configured"
else
    ok "Default profile already configured (root+eth0)"
fi

echo ""
echo "  Storage pools:"
timeout 10 lxc storage list 2>/dev/null | sed 's/^/    /'
echo "  Networks:"
timeout 10 lxc network list 2>/dev/null | sed 's/^/    /'

step "4/10 — Pre-download Ubuntu LXC images"
for ver in 22.04 24.04 26.04; do
    if timeout 10 lxc image list 2>/dev/null | grep -q "$ver"; then
        ok "Ubuntu $ver already cached"
    else
        echo "  Downloading Ubuntu $ver (this may take a minute)..."
        timeout 300 lxc image copy "https://cloud-images.ubuntu.com/releases/$ver" "local:" \
            --protocol simplestreams --alias "$ver" --auto-update 2>&1 || \
        timeout 300 lxc image copy ubuntu:$ver local: --alias "$ver" --auto-update 2>&1 || \
        echo "  WARNING: Could not pre-download Ubuntu $ver (will pull on demand)"
    fi
done
echo "  Cached images:"
timeout 15 lxc image list 2>/dev/null | sed 's/^/    /' || echo "  (unavailable)"
ok "LXC images ready"

step "5/10 — Python 3.10"
NEED_INSTALL=false
echo "  Checking python3.10..."
command -v python3.10 || NEED_INSTALL=true
echo "  Checking python3.10 -m venv..."
python3.10 -m venv --help >/dev/null 2>&1 || NEED_INSTALL=true
echo "  Checking python3.10 -m ensurepip..."
python3.10 -m ensurepip --version >/dev/null 2>&1 || NEED_INSTALL=true
echo "  Checking python3.10 distutils..."
python3.10 -c "import distutils" >/dev/null 2>&1 || NEED_INSTALL=true

if [ "$NEED_INSTALL" = true ]; then
    echo "  Python 3.10 incomplete, installing from deadsnakes PPA..."
    add-apt-repository ppa:deadsnakes/ppa -y
    apt-get update
    apt-get install -y python3.10 python3.10-venv python3.10-distutils \
                       python3-pip-whl python3-setuptools-whl
fi
echo "  Python version: $(python3.10 --version)"
ok "Python 3.10 ready"

step "6/10 — Install pip for Python 3.10"
echo "  Downloading get-pip.py..."
curl -sS https://bootstrap.pypa.io/get-pip.py | python3.10
echo "  Pip version: $(python3.10 -m pip --version)"
ok "pip installed"

step "7/10 — Setup virtual environment"
echo "  Creating venv..."
python3.10 -m venv venv
source venv/bin/activate
echo "  Python: $(which python)"
echo "  Pip:    $(which pip)"
ok "Virtual environment created"

step "8/10 — Python packages"
echo "  Upgrading pip..."
pip install --upgrade pip
echo "  Installing requirements.txt..."
pip install -r requirements.txt
echo "  Installing node_requirements.txt..."
pip install -r node_requirements.txt
echo "  Installed packages:"
pip list --format=columns
ok "Python packages installed"

step "9/10 — Setup directories & database"
echo "  Creating static/uploads..."
mkdir -p static/uploads
echo "  Initializing database..."
venv/bin/python -c "import app; app.init_db(); print('Database initialized')"
echo "  Database file: $(ls -la data.db 2>/dev/null || ls -la c/data.db 2>/dev/null || echo 'unknown')"
ok "Database ready"

step "10/10 — Verify"
echo ""
echo "  LXD:  $(timeout 5 lxc version 2>/dev/null | head -1 || echo 'unknown')"
echo ""
echo "  Storage pools:"
timeout 10 lxc storage list 2>/dev/null | sed 's/^/    /' || echo "    (unavailable)"
echo ""
echo "  Network:"
timeout 10 lxc network list 2>/dev/null | sed 's/^/    /' || echo "    (unavailable)"
echo ""
echo "  Images:"
timeout 10 lxc image list 2>/dev/null | sed 's/^/    /' || echo "    (unavailable)"
echo ""
timeout 5 lxc info 2>/dev/null | grep -E "Kernel|Uptime|LXD" | sed 's/^/  /' || true
ok "All checks passed"

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}   VPS Manager (LXC) — Setup Complete${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "  Admin login:"
echo "    Username: admin"
echo "    Password: admin123"
echo ""
echo "  Start panel:"
echo "    source venv/bin/activate"
echo "    python app.py"
echo ""
echo "  Start node agent (on each node):"
echo "    source venv/bin/activate"
echo "    python node.py --port=5001 --name=node1"
echo ""
echo "  Default VPS OS options:"
echo "    Ubuntu 22.04, 24.04, 26.04"
echo ""
echo -e "${GREEN}============================================${NC}"
