#!/bin/bash
#
# install.sh - Installation script for netplan-rollback
#
# This script installs, updates, or uninstalls the netplan-rollback system.
#
# Usage: install.sh [OPTIONS]
#

set -euo pipefail

# Configuration
INSTALL_DIR="/usr/local/bin"
STATE_DIR="/root/netplan-rollback"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Script names
SCRIPTS=("netplan-swap.sh" "netplan-rollback.sh" "netplan-confirm.sh" "netplan-status.sh" "netplan-capture.sh" "netplan-export-capture.sh")

# Operation mode
MODE=""
DRY_RUN=""

show_help() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Installation script for netplan-rollback system.

OPTIONS:
  --install       Install netplan-rollback scripts (default)
  --uninstall     Remove netplan-rollback scripts
  --update        Update existing installation
  --dry-run       Show what would be done without making changes
  -h, --help      Show this help message

DESCRIPTION:
  This script manages the installation of netplan-rollback, a safe netplan
  configuration switcher with automatic rollback capability.

  Installation copies the scripts to /usr/local/bin/ and creates the
  state directory at /root/netplan-rollback/.

  Uninstallation removes the scripts and optionally removes state files.

EXAMPLES:
  # Install (default)
  sudo ./install.sh

  # Install explicitly
  sudo ./install.sh --install

  # Test installation without making changes
  sudo ./install.sh --dry-run

  # Update existing installation
  sudo ./install.sh --update

  # Remove installation
  sudo ./install.sh --uninstall

REQUIREMENTS:
  - Ubuntu 20.04+ or similar Linux distribution
  - systemd
  - netplan
  - jq (JSON processor)
  - Root access
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --install)
            MODE="install"
            shift
            ;;
        --uninstall)
            MODE="uninstall"
            shift
            ;;
        --update)
            MODE="update"
            shift
            ;;
        --dry-run)
            DRY_RUN="yes"
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Error: Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
    esac
done

# Default mode is install
if [[ -z "${MODE}" ]]; then
    MODE="install"
fi

# Logging functions
log_info() {
    echo "[INFO] $*"
}

log_ok() {
    echo "[OK] $*"
}

log_warn() {
    echo "[WARN] $*"
}

log_error() {
    echo "[ERROR] $*" >&2
}

log_dry_run() {
    echo "[DRY-RUN] $*"
}

# Validation functions
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        echo "Please run with sudo: sudo $0 $*" >&2
        exit 1
    fi
}

check_dependencies() {
    local missing=()

    if ! command -v systemctl &> /dev/null; then
        missing+=("systemd")
    fi

    if ! command -v netplan &> /dev/null; then
        missing+=("netplan")
    fi

    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        echo ""
        echo "Install missing dependencies:"
        echo "  sudo apt-get update"
        echo "  sudo apt-get install -y ${missing[*]}"
        exit 1
    fi

    log_ok "All dependencies found"
}

check_optional_dependencies() {
    log_info "Checking optional dependencies for packet capture..."

    if ! command -v dumpcap &> /dev/null; then
        log_warn "Optional: tshark not found (needed for packet capture)"
        echo ""
        echo "The packet capture feature requires tshark/wireshark."
        echo "This is optional - the main tool works without it."
        echo ""
        read -p "Install tshark now? [Y/n] " -n 1 -r
        echo

        if [[ $REPLY =~ ^[Yy]$|^$ ]]; then
            log_info "Installing tshark..."
            if apt-get update && apt-get install -y tshark; then
                log_ok "tshark installed successfully"
                echo ""
                echo "Note: To allow non-root packet capture, run:"
                echo "  sudo dpkg-reconfigure wireshark-common"
                echo "  sudo usermod -a -G wireshark root"
            else
                log_warn "Failed to install tshark - capture features will not work"
            fi
        else
            log_info "Skipping tshark installation"
            echo "You can install it later with:"
            echo "  sudo apt-get install tshark"
        fi
        echo ""
    else
        log_ok "Optional: tshark available for packet capture"
    fi
}

check_script_files() {
    local missing=()

    for script in "${SCRIPTS[@]}"; do
        if [[ ! -f "${SCRIPT_DIR}/bin/${script}" ]]; then
            missing+=("${script}")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing script files: ${missing[*]}"
        log_error "Script directory: ${SCRIPT_DIR}/bin/"
        exit 1
    fi

    log_ok "All script files found"
}

# Installation functions
install_scripts() {
    log_info "Installing scripts to ${INSTALL_DIR}..."

    for script in "${SCRIPTS[@]}"; do
        local src="${SCRIPT_DIR}/bin/${script}"
        local dst="${INSTALL_DIR}/${script}"

        if [[ -n "${DRY_RUN}" ]]; then
            log_dry_run "Would copy: ${src} -> ${dst}"
            log_dry_run "Would set permissions: 755"
        else
            cp "${src}" "${dst}"
            chmod 755 "${dst}"
            log_ok "Installed: ${script}"
        fi
    done
}

create_state_directory() {
    log_info "Creating state directory..."

    if [[ -n "${DRY_RUN}" ]]; then
        log_dry_run "Would create directory: ${STATE_DIR}"
        log_dry_run "Would set permissions: 700"
    else
        mkdir -p "${STATE_DIR}"
        chmod 700 "${STATE_DIR}"
        log_ok "Created: ${STATE_DIR}"
    fi
}

remove_scripts() {
    log_info "Removing scripts from ${INSTALL_DIR}..."

    for script in "${SCRIPTS[@]}"; do
        local dst="${INSTALL_DIR}/${script}"

        if [[ -f "${dst}" ]]; then
            if [[ -n "${DRY_RUN}" ]]; then
                log_dry_run "Would remove: ${dst}"
            else
                rm -f "${dst}"
                log_ok "Removed: ${script}"
            fi
        else
            log_info "Not found (skipping): ${script}"
        fi
    done
}

check_active_rollback() {
    if systemctl is-active --quiet netplan-auto-rollback.timer 2>/dev/null; then
        log_warn "Active rollback timer detected!"
        echo ""
        echo "There is currently a scheduled rollback active."
        echo "Status:"
        systemctl status netplan-auto-rollback.timer --no-pager || true
        echo ""
        return 1
    fi
    return 0
}

remove_state_directory() {
    if [[ ! -d "${STATE_DIR}" ]]; then
        log_info "State directory does not exist (skipping)"
        return
    fi

    echo ""
    log_warn "State directory contains configuration backups and history"
    echo "Location: ${STATE_DIR}"
    echo ""
    ls -lh "${STATE_DIR}" 2>/dev/null || true
    echo ""
    read -p "Remove state directory and all backups? [y/N] " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if [[ -n "${DRY_RUN}" ]]; then
            log_dry_run "Would remove directory: ${STATE_DIR}"
        else
            rm -rf "${STATE_DIR}"
            log_ok "Removed: ${STATE_DIR}"
        fi
    else
        log_info "State directory preserved: ${STATE_DIR}"
    fi
}

verify_installation() {
    log_info "Verifying installation..."

    local all_ok=true

    for script in "${SCRIPTS[@]}"; do
        local path="${INSTALL_DIR}/${script}"
        if [[ -f "${path}" ]] && [[ -x "${path}" ]]; then
            log_ok "Found: ${script}"
        else
            log_error "Missing or not executable: ${script}"
            all_ok=false
        fi
    done

    if [[ -d "${STATE_DIR}" ]]; then
        log_ok "State directory exists: ${STATE_DIR}"
    else
        log_warn "State directory missing: ${STATE_DIR}"
    fi

    if [[ "${all_ok}" == "true" ]]; then
        log_ok "Installation verification passed"
        return 0
    else
        log_error "Installation verification failed"
        return 1
    fi
}

display_install_success() {
    cat <<EOF

================================================================================
INSTALLATION COMPLETE
================================================================================
Netplan-rollback has been successfully installed.

Installed scripts:
  - netplan-swap.sh       Main script to apply configs with rollback
  - netplan-rollback.sh   Automatic rollback executor
  - netplan-confirm.sh    Confirm config and cancel rollback

State directory: ${STATE_DIR}

QUICK START:
  # Apply a new netplan config with 5 minute auto-rollback
  sudo netplan-swap.sh /etc/netplan/current.yaml /path/to/new.yaml 300

  # If network works, confirm to cancel rollback
  sudo netplan-confirm.sh

For detailed documentation, see:
  https://github.com/menloparking/netplan-rollback

Get help for any command:
  netplan-swap.sh --help
  netplan-confirm.sh --help
================================================================================
EOF
}

display_uninstall_success() {
    cat <<EOF

================================================================================
UNINSTALLATION COMPLETE
================================================================================
Netplan-rollback has been removed from the system.

If you kept the state directory (${STATE_DIR}),
you can remove it manually:
  sudo rm -rf ${STATE_DIR}
================================================================================
EOF
}

display_update_success() {
    cat <<EOF

================================================================================
UPDATE COMPLETE
================================================================================
Netplan-rollback scripts have been updated to the latest version.

State directory and any existing backups were preserved.
================================================================================
EOF
}

# Main functions
do_install() {
    log_info "Starting installation..."
    echo ""

    check_root
    check_dependencies
    check_script_files
    echo ""

    if [[ -z "${DRY_RUN}" ]]; then
        check_optional_dependencies
    fi

    install_scripts
    create_state_directory
    echo ""

    if [[ -z "${DRY_RUN}" ]]; then
        verify_installation
        echo ""
        display_install_success
    else
        log_dry_run "Installation dry-run complete. No changes made."
    fi
}

do_uninstall() {
    log_info "Starting uninstallation..."
    echo ""

    check_root

    if ! check_active_rollback; then
        log_error "Cannot uninstall while rollback is active"
        echo "Please confirm or wait for rollback to complete first:"
        echo "  sudo netplan-confirm.sh"
        exit 1
    fi

    echo ""
    remove_scripts
    remove_state_directory
    echo ""

    if [[ -z "${DRY_RUN}" ]]; then
        display_uninstall_success
    else
        log_dry_run "Uninstallation dry-run complete. No changes made."
    fi
}

do_update() {
    log_info "Starting update..."
    echo ""

    check_root
    check_dependencies
    check_script_files
    echo ""

    if ! check_active_rollback; then
        log_error "Cannot update while rollback is active"
        echo "Please confirm or wait for rollback to complete first:"
        echo "  sudo netplan-confirm.sh"
        exit 1
    fi

    echo ""
    install_scripts
    echo ""

    if [[ -z "${DRY_RUN}" ]]; then
        verify_installation
        echo ""
        display_update_success
    else
        log_dry_run "Update dry-run complete. No changes made."
    fi
}

# Main execution
main() {
    case "${MODE}" in
        install)
            do_install
            ;;
        uninstall)
            do_uninstall
            ;;
        update)
            do_update
            ;;
        *)
            log_error "Unknown mode: ${MODE}"
            exit 1
            ;;
    esac
}

main "$@"
