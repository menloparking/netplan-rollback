#!/bin/bash
#
# netplan-confirm.sh - Confirm netplan configuration and cancel rollback
#
# This script confirms that the new netplan configuration is working correctly
# and cancels the scheduled automatic rollback.
#
# Usage: netplan-confirm.sh [--keep-backup|-k]
#

set -euo pipefail

# Configuration
STATE_DIR="/root/netplan-rollback"
STATE_FILE="${STATE_DIR}/state.json"
LOG_FILE="${STATE_DIR}/rollback.log"

# Parse command line arguments
KEEP_BACKUP=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -k|--keep-backup)
            KEEP_BACKUP="yes"
            shift
            ;;
        -h|--help)
            cat <<'EOF'
Usage: netplan-confirm.sh [OPTIONS]

Confirm the new netplan configuration and cancel scheduled rollback.

OPTIONS:
  -k, --keep-backup    Keep backup files without prompting
  -h, --help          Show this help message

DESCRIPTION:
  This command confirms that your new netplan configuration is working
  correctly and cancels the automatic rollback timer. Once confirmed,
  the new configuration becomes permanent.

EXAMPLES:
  # Confirm and prompt about backup retention
  netplan-confirm.sh

  # Confirm and keep backup files
  netplan-confirm.sh --keep-backup
EOF
            exit 0
            ;;
        *)
            echo "Error: Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
    esac
done

# Logging functions
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}" >&2
}

log_info() {
    log "INFO" "$@"
}

log_ok() {
    log "OK" "$@"
}

log_warn() {
    log "WARN" "$@"
}

log_error() {
    log "ERROR" "$@"
}

# Syslog logging
log_syslog() {
    logger -t netplan-confirm "$@"
}

# Stop capture if running
stop_capture() {
    if [[ ! -f "${STATE_DIR}/capture.pid" ]]; then
        return 0
    fi
    
    local capture_pid
    capture_pid=$(cat "${STATE_DIR}/capture.pid" 2>/dev/null || echo "")
    
    if [[ -z "${capture_pid}" ]]; then
        return 0
    fi
    
    if kill -0 "${capture_pid}" 2>/dev/null; then
        log_info "Stopping capture process (PID: ${capture_pid})"
        kill -TERM "${capture_pid}" 2>/dev/null || true
        sleep 2
        log_ok "Capture stopped"
    fi
    
    rm -f "${STATE_DIR}/capture.pid"
}

# Display banner
display_banner() {
    cat <<'EOF'
================================================================================
CONFIRMING NETPLAN CONFIGURATION
================================================================================
Cancelling scheduled rollback...
================================================================================
EOF
}

# Main confirmation function
main() {
    # Phase 1: Validation
    if [[ ! -f "${STATE_FILE}" ]]; then
        log_warn "No pending rollback found. Nothing to confirm."
        exit 0
    fi

    # Parse state file
    log_info "Reading state file: ${STATE_FILE}"
    local backup_path
    backup_path=$(jq -r '.backup_path' "${STATE_FILE}")

    # Check if timer is active
    if systemctl is-active --quiet netplan-auto-rollback.timer; then
        log_info "Rollback timer is active - proceeding with cancellation"
    else
        log_warn "Rollback timer is not active. May have already executed or been cancelled."
        read -p "Continue with cleanup? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Cancelled by user"
            exit 0
        fi
    fi

    # Phase 2: Cancel rollback
    display_banner

    log_info "Stopping rollback timer..."
    systemctl stop netplan-auto-rollback.timer 2>/dev/null || true
    log_ok "Rollback timer stopped"

    log_info "Disabling rollback timer..."
    systemctl disable netplan-auto-rollback.timer 2>/dev/null || true
    log_ok "Rollback timer disabled"

    log_info "Removing systemd units..."
    rm -f /etc/systemd/system/netplan-auto-rollback.timer
    rm -f /etc/systemd/system/netplan-auto-rollback.service
    systemctl daemon-reload
    log_ok "Rollback timer removed"

    log_syslog "netplan configuration confirmed by user, rollback cancelled"

    # Phase 3: Update state and handle backup
    log_info "Updating state file..."
    local confirmed_at
    confirmed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    jq --arg confirmed_at "${confirmed_at}" \
        '.status = "confirmed" | .confirmed_at = $confirmed_at' \
        "${STATE_FILE}" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "${STATE_FILE}"

    # Stop any running capture
    stop_capture
    
    # Handle backup file
    local delete_backup="no"

    if [[ -z "${KEEP_BACKUP}" ]]; then
        echo ""
        echo "Backup file: ${backup_path}"
        read -p "Keep backup file? [Y/n] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            delete_backup="yes"
        fi
    fi

    if [[ "${delete_backup}" == "yes" ]]; then
        rm -f "${backup_path}"
        log_info "Backup file removed"
    else
        log_info "Backup preserved at: ${backup_path}"
    fi

    # Display success message
    cat <<EOF

================================================================================
CONFIGURATION CONFIRMED
================================================================================
New netplan configuration is now permanent.
Automatic rollback has been cancelled.

Backup location: ${backup_path}
State file: ${STATE_FILE}

You can safely delete the backup and state file if no longer needed:
  rm ${backup_path}
  rm ${STATE_FILE}
================================================================================
EOF

    log_syslog "netplan-confirm completed successfully"
}

# Run main function
main "$@"
