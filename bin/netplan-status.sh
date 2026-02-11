#!/bin/bash
#
# netplan-status.sh - Check status of pending netplan rollback
#
# This script checks if there is a rollback timer active and displays
# the current status including time remaining until rollback.
#

set -euo pipefail

# Configuration
STATE_DIR="/root/netplan-rollback"
STATE_FILE="${STATE_DIR}/state.json"

show_help() {
    cat <<'EOF'
Usage: netplan-status.sh [OPTIONS]

Check status of pending netplan rollback.

OPTIONS:
  -q, --quiet            Only exit code (0=active, 1=not active)
  -j, --json             Output in JSON format
  -h, --help             Show this help message

DESCRIPTION:
  This script checks if there is a netplan rollback timer currently active
  and displays information about the pending rollback including:
  - Whether a rollback is scheduled
  - Time until rollback
  - Backup file location
  - Configuration paths

EXIT CODES:
  0 - Rollback is active/pending
  1 - No rollback active
  2 - Error occurred

EXAMPLES:
  # Check status (human-readable)
  sudo netplan-status.sh

  # Check if rollback is active (script-friendly)
  if sudo netplan-status.sh --quiet; then
    echo "Rollback is pending"
  fi

  # Get JSON output
  sudo netplan-status.sh --json
EOF
}

# Parse command line arguments
QUIET_MODE=""
JSON_MODE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -q|--quiet)
            QUIET_MODE="yes"
            shift
            ;;
        -j|--json)
            JSON_MODE="yes"
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -*)
            echo "Error: Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
            exit 2
            ;;
        *)
            echo "Error: Unexpected argument: $1" >&2
            echo "Use --help for usage information" >&2
            exit 2
            ;;
    esac
done

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    if [[ -z "${QUIET_MODE}" ]]; then
        echo "Error: This script must be run as root" >&2
        echo "Please run with sudo: sudo $0" >&2
    fi
    exit 2
fi

# Check if timer is active
timer_active() {
    systemctl is-active --quiet netplan-auto-rollback.timer 2>/dev/null
}

# Calculate time remaining
calculate_time_remaining() {
    local rollback_epoch="$1"
    local current_epoch
    current_epoch=$(date +%s)
    local remaining=$((rollback_epoch - current_epoch))
    
    if [[ ${remaining} -lt 0 ]]; then
        echo "0"
    else
        echo "${remaining}"
    fi
}

# Format seconds as human-readable time
format_duration() {
    local seconds=$1
    local minutes=$((seconds / 60))
    local hours=$((minutes / 60))
    local days=$((hours / 24))
    
    if [[ ${days} -gt 0 ]]; then
        echo "${days}d ${hours}h ${minutes}m ${seconds}s"
    elif [[ ${hours} -gt 0 ]]; then
        echo "${hours}h ${minutes}m ${seconds}s"
    elif [[ ${minutes} -gt 0 ]]; then
        echo "${minutes}m ${seconds}s"
    else
        echo "${seconds}s"
    fi
}

# Main status check
if ! timer_active; then
    if [[ -n "${QUIET_MODE}" ]]; then
        exit 1
    elif [[ -n "${JSON_MODE}" ]]; then
        cat <<'EOF'
{
  "active": false,
  "message": "No rollback timer active"
}
EOF
        exit 1
    else
        echo "No rollback timer active"
        echo ""
        echo "To apply a new configuration with rollback protection:"
        echo "  sudo netplan-swap.sh <current-config> <new-config> [timeout]"
        exit 1
    fi
fi

# Timer is active - read state file
if [[ ! -f "${STATE_FILE}" ]]; then
    if [[ -n "${QUIET_MODE}" ]]; then
        exit 2
    elif [[ -n "${JSON_MODE}" ]]; then
        cat <<'EOF'
{
  "active": true,
  "error": "Timer active but state file missing",
  "state_file": "/root/netplan-rollback/state.json"
}
EOF
        exit 2
    else
        echo "Error: Timer is active but state file is missing: ${STATE_FILE}" >&2
        echo "This is an inconsistent state. Consider running:" >&2
        echo "  sudo systemctl stop netplan-auto-rollback.timer" >&2
        exit 2
    fi
fi

# Parse state file
if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but not installed" >&2
    exit 2
fi

rollback_epoch=$(jq -r '.rollback_epoch' "${STATE_FILE}")
rollback_datetime=$(jq -r '.rollback_datetime' "${STATE_FILE}")
original_config=$(jq -r '.original_config_path' "${STATE_FILE}")
new_config=$(jq -r '.new_config_path' "${STATE_FILE}")
backup_path=$(jq -r '.backup_path' "${STATE_FILE}")
timeout_seconds=$(jq -r '.timeout_seconds' "${STATE_FILE}")
status=$(jq -r '.status' "${STATE_FILE}")

# Calculate time remaining
time_remaining=$(calculate_time_remaining "${rollback_epoch}")

# Quiet mode - just exit with code
if [[ -n "${QUIET_MODE}" ]]; then
    exit 0
fi

# JSON mode
if [[ -n "${JSON_MODE}" ]]; then
    current_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    cat <<EOF
{
  "active": true,
  "status": "${status}",
  "current_time": "${current_time}",
  "rollback_epoch": ${rollback_epoch},
  "rollback_datetime": "${rollback_datetime}",
  "time_remaining_seconds": ${time_remaining},
  "timeout_seconds": ${timeout_seconds},
  "original_config_path": "${original_config}",
  "new_config_path": "${new_config}",
  "backup_path": "${backup_path}",
  "state_file": "${STATE_FILE}"
}
EOF
    exit 0
fi

# Human-readable output
current_time=$(date "+%Y-%m-%d %H:%M:%S %Z (UTC%z)")
time_remaining_formatted=$(format_duration "${time_remaining}")

cat <<EOF

================================================================================
NETPLAN ROLLBACK STATUS
================================================================================
Status:                 ACTIVE - Rollback scheduled
Current time:           ${current_time}
Rollback scheduled:     ${rollback_datetime}
Time remaining:         ${time_remaining_formatted} (${time_remaining} seconds)

Original timeout:       ${timeout_seconds} seconds
Current status:         ${status}

Configuration:
  Original config:      ${original_config}
  New config:           ${new_config}
  Backup location:      ${backup_path}

State file:             ${STATE_FILE}
================================================================================

ACTIONS:
  Confirm and cancel rollback:
    sudo netplan-confirm.sh

  Force immediate rollback:
    sudo systemctl start netplan-auto-rollback.service

  View timer details:
    systemctl status netplan-auto-rollback.timer
    systemctl list-timers netplan-auto-rollback.timer

  View logs:
    journalctl -u netplan-auto-rollback -f
    tail -f ${STATE_DIR}/rollback.log

================================================================================
EOF

exit 0
