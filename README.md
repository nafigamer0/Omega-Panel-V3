# Omega Panel V3

A full-featured VPS management website built with Flask, LXC/LXD, and modern web technologies.

## Features

- **User Authentication**: Register and login system with secure password hashing
- **Admin Panel**: Create and manage VPS instances for users
- **User Dashboard**: View and manage your VPS instances
- **LXC Integration**: Automated VPS creation using LXC/LXD containers
- **SSH Access**: sshx-based SSH access to VPS instances
- **Real-time Status**: Auto-refreshing VPS status monitoring

## Default Credentials

- **Admin Username**: admin
- **Admin Password**: admin123

## Setup

### Prerequisites

- Python 3.10+
- LXD snap installed and initialized

### Installation

1. Clone the repository and run as root:
```bash
sudo bash setup.sh
```

The setup script performs 10 steps:
- Installs system packages (curl, wget, jq, etc.)
- Installs LXD via snap (if not present)
- Removes conflicting apt `lxc` package
- Waits for LXD daemon readiness
- Creates `default` storage pool (dir)
- Creates `lxdbr0` bridge network
- Configures default profile (root disk + eth0)
- Pre-downloads Ubuntu LXC images (22.04, 24.04, 26.04)
- Installs Python 3.10 + deadsnakes PPA if needed
- Installs pip
- Creates Python virtual environment in `venv/`
- Installs `requirements.txt` + `node_requirements.txt`
- Creates `static/uploads/` and initializes `data.db`

2. Start the panel:
```bash
source venv/bin/activate
python app.py
```

3. Visit http://localhost:5000

4. (Optional) Start the node agent on each worker node:
```bash
source venv/bin/activate
python node.py --port=5001 --name=node1
```

## Manual Setup

If you prefer manual setup:

1. Install LXD snap and configure:
```bash
snap install lxd --channel=5.0/stable
/snap/bin/lxd init --auto
```

2. Create Python virtual environment:
```bash
python3.10 -m venv venv
source venv/bin/activate
```

3. Install Python dependencies:
```bash
pip install -r requirements.txt
```

4. Initialize the database:
```bash
python -c "import app; app.init_db()"
```

5. Run the application:
```bash
python app.py
```

### Pre-pulling LXC Images

Images are pulled automatically on first container creation, but you can pre-pull:

```bash
lxc image copy ubuntu:22.04 local: --alias 22.04 --auto-update
lxc image copy ubuntu:24.04 local: --alias 24.04 --auto-update
lxc image copy ubuntu:26.04 local: --alias 26.04 --auto-update
```

## Usage

### For Admins

1. Login with admin credentials
2. Go to Admin Panel
3. Click "Create VPS"
4. Select a user, OS type, and specifications
5. The VPS will be created and assigned to the user

### For Users

1. Register an account
2. Login to your dashboard
3. View your VPS instances
4. Start, stop, restart, or delete your VPS
5. Click the terminal icon to access SSH (sshx)


## API Endpoints

See On Admin > API Docs.
