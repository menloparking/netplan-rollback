#!/bin/bash
#
# netplan-swap.sh - Safe netplan configuration switcher with auto-rollback
#
# This script safely applies a new netplan configuration with automatic rollback
# capability. It creates a backup of the current configuration, applies the new
# one, and schedules an automatic rollback if not confirmed within the timeout.
#
# Usage: netplan-swap.sh [OPTIONS] <current-config-path> <new-config-path> [timeout-seconds]
#

set -euo pipefail

# Configuration
STATE_DIR="/root/netplan-rollback"
STATE_FILE="${STATE_DIR}/state.json"
LOG_FILE="${STATE_DIR}/rollback.log"
DEFAULT_TIMEOUT=300

# Parse command line arguments
DRY_RUN=""
CURRENT_CONFIG=""
NEW_CONFIG=""
TIMEOUT="${DEFAULT_TIMEOUT}"

show_help() {
    cat <<'EOF'
Usage: netplan-swap.sh [OPTIONS] <current-config-path> <new-config-path> [timeout-seconds]

Safe netplan configuration switcher with automatic rollback.

OPTIONS:
  -n, --dry-run       Validate but don't apply changes
  -h, --help          Show this help message

ARGUMENTS:
  current-config-path   Path to current netplan YAML (e.g., /etc/netplan/50-cloud-init.yaml)
  new-config-path       Path to new netplan YAML to apply
  timeout-seconds       Seconds before auto-rollback (default: 300)

DESCRIPTION:
  This script safely applies a new netplan configuration with automatic rollback
  protection. It will:

  1. Validate the new configuration syntax
  2. Create a backup of the current configuration
  3. Apply the new configuration
  4. Schedule an automatic rollback after the specified timeout
  5. Allow you to confirm the new configuration to cancel the rollback

  If you don't confirm within the timeout period, the system will automatically
  rollback to the previous configuration.

EXAMPLES:
  # Apply new bond configuration with 5 minute timeout
  netplan-swap.sh /etc/netplan/50-cloud-init.yaml /root/netplan-bond.yaml 300

  # Test without applying (dry-run)
  netplan-swap.sh --dry-run /etc/netplan/50-cloud-init.yaml /root/netplan-bond.yaml

  # Apply with 10 minute timeout
  netplan-swap.sh /etc/netplan/50-cloud-init.yaml /root/netplan-bond.yaml 600

AFTER APPLYING:
  If network works:
    sudo netplan-confirm.sh

  If network fails (force immediate rollback):
    sudo systemctl start netplan-auto-rollback.service

  Check rollback status:
    systemctl status netplan-auto-rollback.timer
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--dry-run)
            DRY_RUN="yes"
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -*)
            echo "Error: Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
        *)
            if [[ -z "${CURRENT_CONFIG}" ]]; then
                CURRENT_CONFIG="$1"
            elif [[ -z "${NEW_CONFIG}" ]]; then
                NEW_CONFIG="$1"
            else
                TIMEOUT="$1"
            fi
            shift
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
    echo "[${timestamp}] [${level}] ${message}"
    if [[ -d "${STATE_DIR}" ]]; then
        echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}"
    fi
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
    logger -t netplan-swap "$@"
}

# Validation functions
validate_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        echo "Please run with sudo: sudo $0 $*" >&2
        exit 1
    fi
}

validate_arguments() {
    if [[ -z "${CURRENT_CONFIG}" ]] || [[ -z "${NEW_CONFIG}" ]]; then
        log_error "Missing required arguments"
        echo "Use --help for usage information" >&2
        exit 1
    fi

    if [[ ! -f "${CURRENT_CONFIG}" ]]; then
        log_error "Current config file not found: ${CURRENT_CONFIG}"
        exit 1
    fi

    if [[ ! -r "${CURRENT_CONFIG}" ]]; then
        log_error "Current config file not readable: ${CURRENT_CONFIG}"
        exit 1
    fi

    if [[ ! -f "${NEW_CONFIG}" ]]; then
        log_error "New config file not found: ${NEW_CONFIG}"
        exit 1
    fi

    if [[ ! -r "${NEW_CONFIG}" ]]; then
        log_error "New config file not readable: ${NEW_CONFIG}"
        exit 1
    fi

    if ! [[ "${TIMEOUT}" =~ ^[0-9]+$ ]] || [[ "${TIMEOUT}" -le 0 ]]; then
        log_error "Timeout must be a positive integer"
        exit 1
    fi
}

check_existing_rollback() {
    if [[ -f "${STATE_FILE}" ]] && systemctl is-active --quiet netplan-auto-rollback.timer 2>/dev/null; then
        log_error "Another rollback is already scheduled"
        log_error "Run 'netplan-confirm.sh' to confirm current config, or wait for completion"
        echo ""
        echo "Current rollback status:"
        systemctl status netplan-auto-rollback.timer --no-pager || true
        exit 1
    fi
}

validate_netplan_syntax() {
    log_info "Validating new netplan configuration..."

    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf ${temp_dir}" EXIT

    # Copy new config to temp directory
    mkdir -p "${temp_dir}/etc/netplan"
    cp "${NEW_CONFIG}" "${temp_dir}/etc/netplan/"

    # Validate using netplan generate
    if netplan generate --root-dir="${temp_dir}" 2>&1 | tee "${temp_dir}/validation.log"; then
        log_ok "Syntax validation passed"
        rm -rf "${temp_dir}"
        trap - EXIT
        return 0
    else
        log_error "Syntax validation failed"
        echo ""
        echo "Netplan validation errors:"
        cat "${temp_dir}/validation.log"
        rm -rf "${temp_dir}"
        trap - EXIT
        return 1
    fi
}

create_backup() {
    log_info "Creating backup directory..."
    mkdir -p "${STATE_DIR}"
    chmod 700 "${STATE_DIR}"

    local timestamp
    timestamp=$(date '+%Y%m%d-%H%M%S')
    local backup_path="${STATE_DIR}/backup-${timestamp}.yaml"

    log_info "Creating backup: ${backup_path}"
    cp "${CURRENT_CONFIG}" "${backup_path}"
    chmod 600 "${backup_path}"

    echo "${backup_path}"
}

calculate_rollback_time() {
    local timeout=$1
    local current_epoch
    local rollback_epoch
    local rollback_datetime
    local timezone

    current_epoch=$(date +%s)
    rollback_epoch=$((current_epoch + timeout))
    timezone=$(date +%Z)
    rollback_datetime=$(date -d "@${rollback_epoch}" "+%Y-%m-%d %H:%M:%S ${timezone} (UTC%z)")

    echo "${rollback_epoch}|${rollback_datetime}"
}

create_state_file() {
    local backup_path="$1"
    local rollback_info="$2"

    local rollback_epoch
    local rollback_datetime
    rollback_epoch=$(echo "${rollback_info}" | cut -d'|' -f1)
    rollback_datetime=$(echo "${rollback_info}" | cut -d'|' -f2-)

    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local timezone
    timezone=$(date +%Z)
    local hostname
    hostname=$(hostname)

    cat > "${STATE_FILE}" <<EOF
{
  "version": "1.0",
  "timestamp": "${timestamp}",
  "original_config_path": "${CURRENT_CONFIG}",
  "backup_path": "${backup_path}",
  "new_config_path": "${NEW_CONFIG}",
  "timeout_seconds": ${TIMEOUT},
  "rollback_epoch": ${rollback_epoch},
  "rollback_datetime": "${rollback_datetime}",
  "timezone": "${timezone}",
  "pid": $$,
  "user": "$(whoami)",
  "hostname": "${hostname}",
  "status": "pending",
  "confirmed_at": null,
  "rollback_completed_at": null
}
EOF
    chmod 600 "${STATE_FILE}"
    log_ok "State file created: ${STATE_FILE}"
}

apply_netplan_config() {
    log_info "Applying new netplan configuration..."

    # Copy new config to target location
    cp "${NEW_CONFIG}" "${CURRENT_CONFIG}"
    log_ok "New configuration copied to ${CURRENT_CONFIG}"

    # Apply netplan
    if netplan apply 2>&1 | tee -a "${LOG_FILE}"; then
        log_ok "Configuration applied"
        return 0
    else
        log_warn "netplan apply reported errors (continuing with rollback schedule)"
        return 1
    fi
}

create_systemd_units() {
    local rollback_epoch="$1"
    local rollback_calendar
    rollback_calendar=$(date -d "@${rollback_epoch}" '+%Y-%m-%d %H:%M:%S')

    log_info "Creating systemd service unit..."
    cat > /etc/systemd/system/netplan-auto-rollback.service <<'EOF'
[Unit]
Description=Netplan Automatic Rollback
Documentation=https://github.com/menloparking/netplan-rollback
After=network.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/local/bin/netplan-rollback.sh
StandardOutput=journal+console
StandardError=journal+console
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

    log_info "Creating systemd timer unit..."
    cat > /etc/systemd/system/netplan-auto-rollback.timer <<EOF
[Unit]
Description=Netplan Automatic Rollback Timer
Documentation=https://github.com/menloparking/netplan-rollback
PartOf=netplan-auto-rollback.service

[Timer]
OnCalendar=${rollback_calendar}
Persistent=true
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

    chmod 644 /etc/systemd/system/netplan-auto-rollback.service
    chmod 644 /etc/systemd/system/netplan-auto-rollback.timer

    log_info "Reloading systemd daemon..."
    systemctl daemon-reload

    log_info "Enabling and starting rollback timer..."
    systemctl enable netplan-auto-rollback.timer
    systemctl start netplan-auto-rollback.timer

    log_ok "Rollback timer scheduled"
}

update_state_scheduled() {
    jq '.status = "scheduled"' "${STATE_FILE}" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "${STATE_FILE}"
}

display_status() {
    local backup_path="$1"
    local rollback_info="$2"

    local rollback_datetime
    rollback_datetime=$(echo "${rollback_info}" | cut -d'|' -f2-)
    local current_time
    current_time=$(date "+%Y-%m-%d %H:%M:%S %Z (UTC%z)")

    cat <<EOF

================================================================================
NETPLAN CONFIGURATION APPLIED WITH AUTO-ROLLBACK
================================================================================
Current time:           ${current_time}
Rollback scheduled:     ${rollback_datetime}
Time until rollback:    ${TIMEOUT} seconds ($((TIMEOUT / 60)) minutes $((TIMEOUT % 60)) seconds)

Backup location:        ${backup_path}
State file:             ${STATE_FILE}
Systemd timer:          netplan-auto-rollback.timer

--------------------------------------------------------------------------------
IMPORTANT: Test your network connectivity now!
--------------------------------------------------------------------------------

IF NETWORK WORKS - Confirm to cancel rollback:
  sudo netplan-confirm.sh

IF NETWORK FAILS - Force immediate rollback:
  sudo systemctl start netplan-auto-rollback.service

To check rollback status:
  systemctl status netplan-auto-rollback.timer
  systemctl list-timers netplan-auto-rollback.timer

To view logs:
  journalctl -u netplan-auto-rollback -f
  tail -f ${LOG_FILE}

================================================================================
EOF
}

dry_run_output() {
    local backup_name
    backup_name="backup-$(date '+%Y%m%d-%H%M%S').yaml"

    cat <<EOF

================================================================================
DRY-RUN MODE - NO CHANGES WILL BE MADE
================================================================================
[DRY-RUN] Would create backup directory: ${STATE_DIR}
[DRY-RUN] Would backup: ${CURRENT_CONFIG}
[DRY-RUN] Would create: ${STATE_DIR}/${backup_name}
[DRY-RUN] Would apply: ${NEW_CONFIG}
[DRY-RUN] Would schedule rollback in ${TIMEOUT} seconds
[DRY-RUN] Would create systemd timer: netplan-auto-rollback.timer
[DRY-RUN] Would create systemd service: netplan-auto-rollback.service

Validation completed successfully. No changes made.
================================================================================
EOF
}

main() {
    log_syslog "netplan-swap invoked with: current=${CURRENT_CONFIG} new=${NEW_CONFIG} timeout=${TIMEOUT}"

    # Phase 1: Pre-flight checks
    validate_root
    validate_arguments
    check_existing_rollback

    # Phase 2: Validation
    if ! validate_netplan_syntax; then
        log_error "Netplan syntax validation failed. Aborting."
        exit 1
    fi

    # Phase 3: Dry-run exit
    if [[ -n "${DRY_RUN}" ]]; then
        dry_run_output
        exit 0
    fi

    # Phase 4: Create backup
    local backup_path
    backup_path=$(create_backup)

    # Phase 5: Calculate rollback time
    local rollback_info
    rollback_info=$(calculate_rollback_time "${TIMEOUT}")
    local rollback_epoch
    rollback_epoch=$(echo "${rollback_info}" | cut -d'|' -f1)

    # Phase 6: Create state file
    create_state_file "${backup_path}" "${rollback_info}"

    # Phase 7: Apply new configuration
    apply_netplan_config

    # Phase 8: Schedule persistent rollback
    create_systemd_units "${rollback_epoch}"

    # Phase 9: Update state
    update_state_scheduled

    # Phase 10: Display status
    display_status "${backup_path}" "${rollback_info}"

    log_syslog "netplan-swap completed successfully, rollback scheduled"
}

# Run main function
main "$@"
