# rivendell-installer
Automate Rivendell Installation with custom configuration on a VPS

## Quick start

This repository provides an offline, single-file installer for Rivendell 4.3.0 that works on Ubuntu 22.04 (jammy) and 24.04 (noble). The installer bundles all required .deb packages and the APPS payload (configs, shortcuts, Icecast, and helper scripts).

### 1) Prerequisites
- Ubuntu Desktop 22.04 or 24.04 (a desktop environment is required; Rivendell does not run headless)
- Sudo/root access
- Git and Git LFS installed

Install prerequisites on Ubuntu:

```bash
sudo apt update && sudo apt install -y git git-lfs
git lfs install
```

### 2) Clone with Git LFS

Clone the repo so the offline installer artifact is fetched correctly via LFS:

```bash
git clone https://github.com/anjeleno/rivendell-installer.git ; cd rivendell-installer
git lfs pull  
# usually automatic, this forces LFS files to download
```

Verify the installer is present and not a small pointer file:

```bash
git lfs ls-files
ls -lh dist/
```

You should see a ~20–35 MB file like:

```
dist/rivendell-installer-0.1.1-YYYYMMDD.run
```

### 3) Run the offline installer

Run as root (or with sudo). The installer detects your series (22.04/24.04) and installs from the bundled .debs.

```bash
sudo ./dist/rivendell-installer-0.1.1-20251018.run
```

The installer will prompt for:
- Installation type (Standalone/Server/Client)
- Hostname (defaults to onair)
- Optional timezone setup
- Optional UFW firewall configuration
- Optional SSH hardening (password auth off; ensure keys work first!)
- Optional MATE desktop for xRDP

It will then:
- Install Rivendell 4.3.0 from bundled .debs
- Create or prepare user (creates `rd` if running as root with no sudo user)
- Configure realtime/memlock limits
- Install xRDP and enable it
- Deploy APPS payload to `/usr/share/rivendell-cloud` (internal cache) and rd's home
- Configure Icecast (enable service)
- Create `/var/www/html/meta.txt` (owned by `pypad` if present)
- Apply xRDP Qt5/XCB fix by linking `.Xauthority`
- Import MariaDB schema from APPS using `/etc/rd.conf` credentials if present
- Optionally set UFW rules and harden SSH
- Pin Rivendell packages at 4.3.0

Reboot is recommended after installation.

## Troubleshooting

### Git LFS pointer instead of the real .run
If `dist/*.run` is very small or `git lfs ls-files` shows nothing:

```bash
sudo apt install -y git-lfs
git lfs install
git lfs fetch --all
git lfs pull
ls -lh dist/
```

### Installer asks for missing tools (whiptail/zenity)
The text UI uses `whiptail` and the optional GUI uses `zenity`.

```bash
sudo apt install -y whiptail zenity
```

### Database import fails
Ensure `/etc/rd.conf` has valid credentials (DbUser/DbPassword/Database). You can re-run just the DB import step manually:

```bash
sudo mysql -uRDUSER -pRDPASS Rivendell < /usr/share/rivendell-cloud/APPS/RDDB_v430_Cloud.sql
```

### xRDP session shows Qt/XCB display issues
Ensure `.Xauthority` for the selected user is linked for root-launched tools:

```bash
sudo ln -sf /home/rd/.Xauthority /root/.Xauthority
```

### UFW/SSH hardening locked me out
If you enabled SSH hardening, ensure your SSH keys are installed on the host. You can revert from console by restoring `/etc/ssh/sshd_config.bak*` and restarting SSH.

### I don’t want to use Git LFS
Download the `.run` from the repo’s Releases page (if provided) or request a direct download link. Alternatively, you can rebuild the installer locally:

```bash
# Build Rivendell 4.3.0 .debs for your series (24.04)
sudo bash scripts/build-rivendell-4.3.0.sh

# Build for 22.04 on a 24.04 host (uses chroot)
sudo bash scripts/build-rivendell-4.3.0-jammy.sh

# Create the offline .run
sudo apt install -y makeself
bash installer/offline/build-makeself.sh
ls -lh dist/
```

## Notes
- The installer is designed to be idempotent; re-running should patch missing bits without breaking an existing setup.
- If you encounter LFS bandwidth limits on GitHub, consider fetching the artifact from a GitHub Release or alternative mirror.
