# Changelog
#
# v0.19.0 - 2025-03-15
- **Added backup and restore functionality for .bashrc.
- **Improved SQL password handling for database operations.
- **Updated Icecast configuration.
- **Added error handling for SQL operations.
- **Integrated optional privilege management for rduser.
- **Improved readability and added comments for clarity.
##
# v0.18.0 - 2025-03-14
- **Initial release of the script.
- **Includes installation of Rivendell, MATE Desktop, xRDP, and broadcasting tools.
- **Added step tracking to avoid re-running completed steps.
- **Configured Icecast, Liquidsoap, and other broadcasting tools.
#
## v0.18.0 - 2025-03-14
### Changes:
- **RRebased on v0.12.x codebase with critical fixes
- **RFixed Icecast configuration to use custom icecast.xml
- **RAdded check to ensure Desktop directory exists before moving shortcuts
- **RCorrected MySQL password extraction and injection in backup script
- **RResolved Icecast permissions issues
#
## v0.17.3 (2025-03-14)
### Changes:
- **Fixed**: Improved step tracking mechanism to ensure completed steps are respected after reboots.
- **RAdded ownership checks for the step tracking directory (`/home/rd/rivendell_install_steps`) to ensure it is always owned by the `rd` user.
- **REnhanced step completion checks to prevent re-execution of already completed steps (e.g., MATE Desktop installation).
- **Improved**: Graceful handling of mid-script reboots to ensure the script resumes correctly.
- **Updated**: Documentation and prompts for better user guidance during installation.
- **Tested**: Verified on a fresh Ubuntu installation to ensure smooth execution after reboots.

## v0.17.1 (2025-03-14)
### Changes:
- **RAdded mid-script reboot handling to allow reboots after installing MATE Desktop and xRDP.
- **RIntroduced the `mid_script_reboot` function to mark steps as completed and prompt for a reboot.
- **Rpdated step tracking to ensure the script can resume after reboots.
- **RImproved robustness by checking for existing installations (e.g., MATE Desktop).
- **RAdded debugging output for easier troubleshooting.
- **RUpdated documentation and comments for clarity.
#
## v0.17 (2025-03-14)
### Changes:
- **RFix step tracking and basic installation flow.
- **RTroubleshoot logic
#
## v0.16 - 2025-03-13
### Changes:
- **RFixed interactive prompts breaking by replacing global log redirection with selective logging.
- **RAdded a `log` function to log non-interactive output while preserving interactive prompts.
- **RUpdated log file handling to ensure proper permissions and ownership.
- ** # - Removed `exec > >(tee -a "$TEMP_LOG_FILE") 2>&1` to prevent interference with interactive prompts.


## v0.15 - 2025-03-13
### Changes:
- **Interactive terminal check**: Added a check to ensure the script runs in an interactive terminal.
- **Locale settings**: Set locale to UTF-8 to prevent display issues.
- **Fixed log file creation**: Used a temporary file in `/tmp` before moving it to `/home/rd` after the `rd` user is created.
- **Restored interactive timezone configuration**: Reverted to the interactive timezone picker for ease of use.
- **Escaped `$` characters in Icecast passwords**: Fixed password formatting in `icecast.xml`.
- **SSH hardening**: Disabled password authentication in both `/etc/ssh/sshd_config` and `/etc/ssh/sshd_config.d/50-cloud-init.conf`.
- **Renamed `Desktop Shortcuts` to `Shortcuts`**: Updated paths to reflect the renamed folder.
- **Added RDP login note**: Prompted the user to log in via RDP before moving shortcuts.
- **Improved `rd` user creation**: Added a password prompt and ensured correct permissions for the home directory.


## v0.14 - 2025-03-13
### Changes:
- **Fixed log file creation**: Used a temporary file in `/tmp` before moving it to `/home/rd` after the `rd` user is created.
- **Restored interactive timezone configuration**: Reverted to the interactive timezone picker for ease of use.
- **Escaped `$` characters in Icecast passwords**: Fixed password formatting in `icecast.xml`.
- **SSH hardening**: Disabled password authentication in both `/etc/ssh/sshd_config` and `/etc/ssh/sshd_config.d/50-cloud-init.conf`.
- **Renamed `Desktop Shortcuts` to `Shortcuts`**: Updated paths to reflect the renamed folder.
- **Added RDP login note**: Prompted the user to log in via RDP before moving shortcuts.
- **Improved `rd` user creation**: Added a password prompt and ensured correct permissions for the home directory.