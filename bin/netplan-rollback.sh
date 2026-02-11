#!/bin/bash
#
# netplan-rollback.sh - Automatic rollback script for netplan configurations
#
# This script is called automatically by systemd timer when a rollback is
# scheduled, or can be invoked manually for immediate rollback.
#
# Usage: netplan-rollback.sh
#

set -euo pipefail

# Configuration
STATE_DIR="/root/netplan-rollback"
STATE_FILE="${STATE_DIR}/state.json"
LOG_FILE="${STATE_DIR}/rollback.log"

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
    logger -t netplan-rollback "$@"
}

# Display banner
display_banner() {
    cat <<'EOF'
================================================================================
EXECUTING NETPLAN ROLLBACK
================================================================================
EOF
}

# Main rollback function
main() {
    log_syslog "netplan-rollback script invoked"

    # Phase 1: Initialization
    log_info "Starting netplan rollback process"

    if [[ ! -f "${STATE_FILE}" ]]; then
        log_warn "No rollback state found. Nothing to rollback."
        log_syslog "netplan-rollback invoked but no state file found"
        exit 0
    fi

    # Parse state file
    log_info "Reading state file: ${STATE_FILE}"
    local original_config_path
    local backup_path

    original_config_path=$(jq -r '.original_config_path' "${STATE_FILE}")
    backup_path=$(jq -r '.backup_path' "${STATE_FILE}")

    if [[ -z "${original_config_path}" ]] || [[ "${original_config_path}" == "null" ]]; then
        log_error "Invalid state file: missing original_config_path"
        log_syslog "netplan-rollback failed - invalid state file"
        exit 1
    fi

    if [[ -z "${backup_path}" ]] || [[ "${backup_path}" == "null" ]]; then
        log_error "Invalid state file: missing backup_path"
        log_syslog "netplan-rollback failed - invalid state file"
        exit 1
    fi

    # Verify backup file exists
    if [[ ! -f "${backup_path}" ]]; then
        log_error "Backup file not found: ${backup_path}"
        log_syslog "netplan-rollback failed - backup file missing"
        exit 1
    fi

    log_ok "State file validated"

    # Phase 2: Display banner and rollback info
    display_banner
    log_info "Rolling back to: ${backup_path}"
    log_info "Target location: ${original_config_path}"
    log_info "Reason: Automatic rollback timeout reached"
    echo "================================================================================"

    # Phase 3: Execute rollback
    log_syslog "Starting netplan rollback from ${backup_path}"

    log_info "Restoring backup configuration..."
    if ! cp "${backup_path}" "${original_config_path}"; then
        log_error "Failed to copy backup file to ${original_config_path}"
        log_syslog "netplan-rollback FAILED - could not restore backup"
        exit 1
    fi
    log_ok "Backup restored to ${original_config_path}"

    log_info "Applying netplan configuration..."
    if netplan apply 2>&1 | tee -a "${LOG_FILE}"; then
        log_ok "Rollback completed successfully"
        log_syslog "netplan-rollback completed successfully"
    else
        log_error "netplan apply failed during rollback!"
        log_error "Manual intervention may be required."
        log_syslog "netplan-rollback FAILED - netplan apply failed"
        # Don't exit with error - continue cleanup
    fi

    # Phase 4: Cleanup
    log_info "Updating state file..."
    local rollback_completed_at
    rollback_completed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    jq --arg completed_at "${rollback_completed_at}" \
        '.status = "completed" | .rollback_completed_at = $completed_at' \
        "${STATE_FILE}" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "${STATE_FILE}"

    log_info "Stopping and disabling rollback timer..."
    systemctl stop netplan-auto-rollback.timer 2>/dev/null || true
    systemctl disable netplan-auto-rollback.timer 2>/dev/null || true

    log_info "Removing systemd units..."
    rm -f /etc/systemd/system/netplan-auto-rollback.timer
    rm -f /etc/systemd/system/netplan-auto-rollback.service
    systemctl daemon-reload

    log_ok "Rollback timer removed"

    # Display completion message
    cat <<EOF

================================================================================
ROLLBACK COMPLETE
================================================================================
Your previous netplan configuration has been restored.

Backup preserved at: ${backup_path}
State file preserved: ${STATE_FILE}

If you need to re-apply the new configuration, you can run netplan-swap.sh
again with the appropriate parameters.
================================================================================
EOF

    log_syslog "netplan-rollback completed and cleaned up"
}

# Run main function
main "$@"
