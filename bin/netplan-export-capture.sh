#!/bin/bash
#
# netplan-export-capture.sh - Export and compress capture sessions
#
# This script packages capture sessions into a compressed archive for
# easy sharing with colleagues or for archival purposes.
#

set -euo pipefail

# Configuration
CAPTURE_BASE_DIR="/root/netplan-rollback/captures"
OUTPUT_DIR="/root/netplan-rollback/exports"

show_help() {
    cat <<'EOF'
Usage: netplan-export-capture.sh [OPTIONS] [SESSION_ID]

Export and compress capture session for sharing.

OPTIONS:
  -o, --output PATH         Output path for compressed archive
  -l, --list                List available capture sessions
  -a, --all                 Export all capture sessions
  -h, --help                Show this help message

ARGUMENTS:
  SESSION_ID   Capture session timestamp (e.g., 20260211-190000)
               If not specified, exports the most recent session

DESCRIPTION:
  Creates a compressed tar.gz archive of capture session(s) including:
  - Packet captures (pcap files)
  - System logs
  - Interface statistics
  - Diagnostic information
  
  The archive can be easily shared with colleagues or stored for later analysis.

EXAMPLES:
  # Export most recent capture session
  sudo netplan-export-capture.sh

  # Export specific session
  sudo netplan-export-capture.sh 20260211-190000

  # Export to specific location
  sudo netplan-export-capture.sh -o /tmp/network-issue.tar.gz 20260211-190000

  # List available sessions
  sudo netplan-export-capture.sh --list

  # Export all sessions
  sudo netplan-export-capture.sh --all

OUTPUT:
  Default output location: /root/netplan-rollback/exports/
  Filename format: netplan-capture-<SESSION_ID>.tar.gz
EOF
}

# Parse command line arguments
OUTPUT_PATH=""
LIST_ONLY=""
EXPORT_ALL=""
SESSION_ID=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--output)
            OUTPUT_PATH="$2"
            shift 2
            ;;
        -l|--list)
            LIST_ONLY="yes"
            shift
            ;;
        -a|--all)
            EXPORT_ALL="yes"
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
            SESSION_ID="$1"
            shift
            ;;
    esac
done

# Validate root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root" >&2
    echo "Please run with sudo: sudo $0 $*" >&2
    exit 1
fi

# Check if captures directory exists
if [[ ! -d "${CAPTURE_BASE_DIR}" ]]; then
    echo "Error: No captures directory found: ${CAPTURE_BASE_DIR}" >&2
    echo "No capture sessions have been created yet." >&2
    exit 1
fi

# List available sessions
list_sessions() {
    local sessions
    sessions=$(find "${CAPTURE_BASE_DIR}" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null | sort -r)
    
    if [[ -z "${sessions}" ]]; then
        echo "No capture sessions found in ${CAPTURE_BASE_DIR}"
        return 1
    fi
    
    echo "Available capture sessions:"
    echo "=========================="
    echo ""
    
    while IFS= read -r session; do
        local session_dir="${CAPTURE_BASE_DIR}/${session}"
        local size
        size=$(du -sh "${session_dir}" 2>/dev/null | cut -f1)
        
        local readme="${session_dir}/README.txt"
        local interfaces=""
        if [[ -f "${readme}" ]]; then
            interfaces=$(grep -A 10 "Captured Interfaces:" "${readme}" 2>/dev/null | grep "^  -" | sed 's/^  - //' | tr '\n' ', ' | sed 's/,$//')
        fi
        
        echo "Session: ${session}"
        echo "  Size: ${size}"
        if [[ -n "${interfaces}" ]]; then
            echo "  Interfaces: ${interfaces}"
        fi
        echo "  Location: ${session_dir}"
        echo ""
    done <<< "${sessions}"
    
    return 0
}

# Export a single session
export_session() {
    local session_id="$1"
    local session_dir="${CAPTURE_BASE_DIR}/${session_id}"
    
    if [[ ! -d "${session_dir}" ]]; then
        echo "Error: Capture session not found: ${session_id}" >&2
        echo "Available sessions:" >&2
        list_sessions >&2
        return 1
    fi
    
    # Determine output path
    local output_file
    if [[ -n "${OUTPUT_PATH}" ]]; then
        output_file="${OUTPUT_PATH}"
    else
        mkdir -p "${OUTPUT_DIR}"
        output_file="${OUTPUT_DIR}/netplan-capture-${session_id}.tar.gz"
    fi
    
    echo "Exporting capture session: ${session_id}"
    echo "Source: ${session_dir}"
    echo "Destination: ${output_file}"
    echo ""
    
    # Create compressed archive
    echo "Creating compressed archive..."
    tar -czf "${output_file}" -C "${CAPTURE_BASE_DIR}" "${session_id}" 2>&1 | grep -v "Removing leading"
    
    if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
        local size
        size=$(du -sh "${output_file}" | cut -f1)
        echo ""
        echo "Export complete!"
        echo "  Archive: ${output_file}"
        echo "  Size: ${size}"
        echo ""
        echo "To extract on another system:"
        echo "  tar -xzf $(basename "${output_file}")"
        echo ""
        echo "To share the file:"
        echo "  scp ${output_file} colleague@server:/path/"
        return 0
    else
        echo "Error: Failed to create archive" >&2
        return 1
    fi
}

# Export all sessions
export_all_sessions() {
    local sessions
    sessions=$(find "${CAPTURE_BASE_DIR}" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null | sort -r)
    
    if [[ -z "${sessions}" ]]; then
        echo "No capture sessions found to export"
        return 1
    fi
    
    # Determine output path
    local output_file
    if [[ -n "${OUTPUT_PATH}" ]]; then
        output_file="${OUTPUT_PATH}"
    else
        mkdir -p "${OUTPUT_DIR}"
        local timestamp
        timestamp=$(date '+%Y%m%d-%H%M%S')
        output_file="${OUTPUT_DIR}/netplan-captures-all-${timestamp}.tar.gz"
    fi
    
    echo "Exporting all capture sessions"
    echo "Source: ${CAPTURE_BASE_DIR}"
    echo "Destination: ${output_file}"
    echo ""
    
    local session_count
    session_count=$(echo "${sessions}" | wc -l)
    echo "Sessions to export: ${session_count}"
    echo ""
    
    # Create compressed archive of all sessions
    echo "Creating compressed archive..."
    tar -czf "${output_file}" -C "${CAPTURE_BASE_DIR}" . 2>&1 | grep -v "Removing leading"
    
    if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
        local size
        size=$(du -sh "${output_file}" | cut -f1)
        echo ""
        echo "Export complete!"
        echo "  Archive: ${output_file}"
        echo "  Size: ${size}"
        echo "  Sessions included: ${session_count}"
        echo ""
        echo "To extract on another system:"
        echo "  mkdir netplan-captures"
        echo "  tar -xzf $(basename "${output_file}") -C netplan-captures/"
        return 0
    else
        echo "Error: Failed to create archive" >&2
        return 1
    fi
}

# Get most recent session
get_most_recent_session() {
    find "${CAPTURE_BASE_DIR}" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null | sort -r | head -1
}

# Main execution
main() {
    # List mode
    if [[ -n "${LIST_ONLY}" ]]; then
        list_sessions
        exit $?
    fi
    
    # Export all mode
    if [[ -n "${EXPORT_ALL}" ]]; then
        export_all_sessions
        exit $?
    fi
    
    # Determine which session to export
    local target_session="${SESSION_ID}"
    if [[ -z "${target_session}" ]]; then
        target_session=$(get_most_recent_session)
        if [[ -z "${target_session}" ]]; then
            echo "Error: No capture sessions found" >&2
            exit 1
        fi
        echo "No session specified, using most recent: ${target_session}"
        echo ""
    fi
    
    # Export the session
    export_session "${target_session}"
    exit $?
}

# Run main function
main "$@"
