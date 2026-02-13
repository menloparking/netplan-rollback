#!/bin/bash
#
# netplan-capture.sh - Packet capture and logging for netplan rollback
#
# This script runs packet capture on network interfaces and captures
# system logs during a netplan configuration change. This provides
# observability even when the network configuration is problematic.
#

set -euo pipefail

# Configuration
STATE_DIR="/root/netplan-rollback"
CAPTURE_DIR="${STATE_DIR}/captures"
STATE_FILE="${STATE_DIR}/state.json"
LOG_FILE="${STATE_DIR}/rollback.log"

# Capture settings
CAPTURE_DURATION=""
INTERFACES=()
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
CAPTURE_SESSION_DIR="${CAPTURE_DIR}/${TIMESTAMP}"

# Process tracking
DUMPCAP_PIDS=()
LOG_CAPTURE_PID=""

show_help() {
    cat <<'EOF'
Usage: netplan-capture.sh [OPTIONS]

Start packet capture and system log monitoring for netplan rollback.

OPTIONS:
  -i, --interfaces IFACE1,IFACE2   Comma-separated list of interfaces to capture
  -d, --duration SECONDS           Capture duration (default: run until stopped)
  -h, --help                       Show this help message

DESCRIPTION:
  This script is typically called automatically by netplan-swap.sh when
  the --enable-capture flag is used. It performs:
  
  1. Packet capture on specified interfaces using dumpcap
  2. Continuous system log capture (dmesg, journalctl)
  3. Interface statistics snapshots
  
  All captures are stored in /root/netplan-rollback/captures/<timestamp>/

EXAMPLES:
  # Capture on eth0 and eth1 for 600 seconds
  netplan-capture.sh --interfaces eth0,eth1 --duration 600
  
  # Capture on bond0 and its slaves indefinitely
  netplan-capture.sh --interfaces eth0,eth1,bond0

STOPPING:
  The capture can be stopped by:
  - Waiting for --duration to expire
  - Calling: pkill -f "netplan-capture.sh"
  - Killing individual dumpcap processes
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--interfaces)
            IFS=',' read -ra INTERFACES <<< "$2"
            shift 2
            ;;
        -d|--duration)
            CAPTURE_DURATION="$2"
            shift 2
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

# Logging functions
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [CAPTURE/${level}] ${message}" >&2
    if [[ -d "${STATE_DIR}" ]]; then
        echo "[${timestamp}] [CAPTURE/${level}] ${message}" >> "${LOG_FILE}"
    fi
}

log_info() {
    log "INFO" "$@"
}

log_ok() {
    log "OK" "$@"
}

log_error() {
    log "ERROR" "$@"
}

# Validate requirements
check_requirements() {
    if [[ ${#INTERFACES[@]} -eq 0 ]]; then
        log_error "No interfaces specified"
        echo "Use --interfaces to specify interfaces to capture" >&2
        exit 1
    fi

    if ! command -v dumpcap &>/dev/null; then
        log_error "dumpcap not found"
        echo "Install tshark/wireshark: sudo apt-get install tshark" >&2
        exit 1
    fi

    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Create capture directory structure
setup_capture_directory() {
    log_info "Creating capture directory: ${CAPTURE_SESSION_DIR}"
    mkdir -p "${CAPTURE_SESSION_DIR}"
    chmod 700 "${CAPTURE_SESSION_DIR}"
    
    # Create subdirectories
    mkdir -p "${CAPTURE_SESSION_DIR}/pcaps"
    mkdir -p "${CAPTURE_SESSION_DIR}/logs"
    mkdir -p "${CAPTURE_SESSION_DIR}/stats"
}

# Capture initial interface statistics
capture_initial_stats() {
    log_info "Capturing initial interface statistics..."
    
    {
        echo "=== Interface Statistics at Start ==="
        echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        
        for iface in "${INTERFACES[@]}"; do
            echo "--- Interface: ${iface} ---"
            ip -s link show "${iface}" 2>&1 || echo "Interface ${iface} not found"
            echo ""
            ethtool -S "${iface}" 2>&1 || echo "ethtool stats not available for ${iface}"
            echo ""
        done
        
        echo "=== Route Table ==="
        ip route show
        echo ""
        
        echo "=== IP Addresses ==="
        ip addr show
        echo ""
        
    } > "${CAPTURE_SESSION_DIR}/stats/initial-stats.txt"
    
    log_ok "Initial statistics captured"
}

# Start packet capture on an interface
start_interface_capture() {
    local iface="$1"
    local pcap_file="${CAPTURE_SESSION_DIR}/pcaps/${iface}.pcapng"
    
    log_info "Starting packet capture on ${iface}..."
    
    # Use timeout to automatically kill dumpcap after duration
    # This guarantees cleanup even if main script crashes
    if [[ -n "${CAPTURE_DURATION}" ]]; then
        local timeout_duration=$((CAPTURE_DURATION + 5))  # Add 5s grace period
        timeout --signal=TERM --kill-after=5s "${timeout_duration}s" \
            dumpcap -i "${iface}" -w "${pcap_file}" -a duration:"${CAPTURE_DURATION}" \
            > "${CAPTURE_SESSION_DIR}/logs/${iface}-dumpcap.log" 2>&1 &
    else
        # No duration specified - capture indefinitely (rely on manual stop)
        dumpcap -i "${iface}" -w "${pcap_file}" \
            > "${CAPTURE_SESSION_DIR}/logs/${iface}-dumpcap.log" 2>&1 &
    fi
    
    local pid=$!
    DUMPCAP_PIDS+=("${pid}")
    
    log_ok "Started dumpcap on ${iface} (PID: ${pid})"
    
    # Store PID for later cleanup
    echo "${pid}" >> "${CAPTURE_SESSION_DIR}/dumpcap.pids"
}

# Start continuous system log capture
start_log_capture() {
    log_info "Starting system log capture..."
    
    # Capture comprehensive system logs
    {
        echo "=========================================="
        echo "SYSTEM LOG CAPTURE START"
        echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "=========================================="
        echo ""
        
        # Initial dmesg snapshot (network-related, last 200 lines)
        echo "=== Initial dmesg (network-related) ===" 
        dmesg | grep -iE 'network|link|bond|eth|interface|netplan|arp|route|ip_' | tail -200
        echo ""
        
        # Initial kern.log snapshot (last 100 lines)
        echo "=== Initial kern.log (network-related) ==="
        tail -100 /var/log/kern.log | grep -iE 'network|link|bond|eth|interface' || echo "No recent network events in kern.log"
        echo ""
        
        # Initial syslog snapshot (network-related, last 100 lines)
        echo "=== Initial syslog (network-related) ==="
        tail -100 /var/log/syslog | grep -iE 'network|link|bond|eth|interface|netplan|dhcp' || echo "No recent network events in syslog"
        echo ""
        
        echo "=== Continuous Log Monitoring Started ==="
        echo ""
        
    } > "${CAPTURE_SESSION_DIR}/logs/system-logs.txt" 2>&1
    
    # Start continuous journalctl monitoring for all network-related services
    # Wrap in timeout to guarantee cleanup
    if [[ -n "${CAPTURE_DURATION}" ]]; then
        # Use timeout slightly longer than capture duration to allow graceful shutdown
        local timeout_duration=$((CAPTURE_DURATION + 5))  # Add 5s grace period
        
        {
            timeout --signal=TERM --kill-after=5s "${timeout_duration}s" \
                journalctl -f -n 0 \
                    -u systemd-networkd \
                    -u systemd-networkd-wait-online \
                    -u networkd-dispatcher \
                    -u systemd-resolved \
                    -u systemd-timesyncd \
                | grep --line-buffered -v 'RTNETLINK' &
            
            local journal_pid=$!
            
            # Monitor dmesg for kernel network events
            timeout --signal=TERM --kill-after=5s "${timeout_duration}s" \
                dmesg -w | grep --line-buffered -iE 'network|link|bond|eth|interface|arp|route' &
            local dmesg_pid=$!
            
            # Also tail syslog for general network events
            timeout --signal=TERM --kill-after=5s "${timeout_duration}s" \
                tail -f /var/log/syslog | grep --line-buffered -iE 'network|link|bond|eth|interface|netplan|dhcp|dns' &
            local syslog_pid=$!
            
            # Wait for completion
            wait ${journal_pid} ${dmesg_pid} ${syslog_pid} 2>/dev/null || true
            
        } >> "${CAPTURE_SESSION_DIR}/logs/system-logs.txt" 2>&1 &
    else
        # No duration - capture indefinitely (manual cleanup required)
        {
            journalctl -f -n 0 \
                -u systemd-networkd \
                -u systemd-networkd-wait-online \
                -u networkd-dispatcher \
                -u systemd-resolved \
                -u systemd-timesyncd \
                | grep --line-buffered -v 'RTNETLINK' &
            
            local journal_pid=$!
            
            # Monitor dmesg for kernel network events
            dmesg -w | grep --line-buffered -iE 'network|link|bond|eth|interface|arp|route' &
            local dmesg_pid=$!
            
            # Also tail syslog for general network events
            tail -f /var/log/syslog | grep --line-buffered -iE 'network|link|bond|eth|interface|netplan|dhcp|dns' &
            local syslog_pid=$!
            
            # Wait forever
            wait
            
        } >> "${CAPTURE_SESSION_DIR}/logs/system-logs.txt" 2>&1 &
    fi
    
    LOG_CAPTURE_PID=$!
    log_ok "Started system log capture (PID: ${LOG_CAPTURE_PID})"
    echo "${LOG_CAPTURE_PID}" >> "${CAPTURE_SESSION_DIR}/log-capture.pid"
    
    # Also capture specific systemd service logs separately
    start_systemd_log_capture
}

# Capture specific systemd service logs
start_systemd_log_capture() {
    log_info "Starting systemd service log capture..."
    
    {
        echo "=========================================="
        echo "SYSTEMD NETWORK SERVICE LOGS"
        echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "=========================================="
        echo ""
        
        # Capture last 100 lines from key services
        echo "=== systemd-networkd ===" 
        journalctl -u systemd-networkd -n 100 --no-pager
        echo ""
        
        echo "=== systemd-networkd-wait-online ==="
        journalctl -u systemd-networkd-wait-online -n 50 --no-pager
        echo ""
        
        echo "=== networkd-dispatcher ==="
        journalctl -u networkd-dispatcher -n 50 --no-pager
        echo ""
        
        echo "=== systemd-resolved ==="
        journalctl -u systemd-resolved -n 50 --no-pager
        echo ""
        
        echo "=== Continuous monitoring started ==="
        echo ""
        
        # Follow these services continuously
        journalctl -f -n 0 \
            -u systemd-networkd \
            -u systemd-networkd-wait-online \
            -u networkd-dispatcher \
            -u systemd-resolved &
        
        local follow_pid=$!
        
        if [[ -n "${CAPTURE_DURATION}" ]]; then
            sleep "${CAPTURE_DURATION}"
            kill ${follow_pid} 2>/dev/null || true
        else
            wait
        fi
        
    } > "${CAPTURE_SESSION_DIR}/logs/systemd-services.txt" 2>&1 &
    
    local systemd_capture_pid=$!
    log_ok "Started systemd service log capture (PID: ${systemd_capture_pid})"
    echo "${systemd_capture_pid}" >> "${CAPTURE_SESSION_DIR}/log-capture.pid"
}

# Monitor interface statistics periodically
monitor_interface_stats() {
    log_info "Starting periodic interface statistics monitoring..."
    
    {
        local interval=10  # seconds between samples
        local iterations=$((CAPTURE_DURATION / interval))
        
        if [[ -z "${CAPTURE_DURATION}" ]]; then
            iterations=999999  # Effectively infinite
        fi
        
        for ((i=1; i<=iterations; i++)); do
            sleep ${interval}
            
            echo "=== Sample ${i} at $(date '+%Y-%m-%d %H:%M:%S') ==="
            for iface in "${INTERFACES[@]}"; do
                echo "--- ${iface} ---"
                ip -s -s link show "${iface}" 2>&1 | grep -E 'RX:|TX:|errors|dropped' || true
            done
            echo ""
        done
    } > "${CAPTURE_SESSION_DIR}/stats/periodic-stats.txt" 2>&1 &
    
    local stats_pid=$!
    log_ok "Started statistics monitoring (PID: ${stats_pid})"
    echo "${stats_pid}" >> "${CAPTURE_SESSION_DIR}/stats-monitor.pid"
}

# Capture comprehensive final diagnostics
capture_final_diagnostics() {
    log_info "Capturing final diagnostics..."
    
    {
        echo "=== Final Network Diagnostics ==="
        echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        
        echo "--- Netplan Configuration ---"
        netplan get all 2>&1 || echo "netplan get failed"
        echo ""
        
        echo "--- Netplan Status ---"
        netplan status 2>&1 || echo "netplan status not available"
        echo ""
        
        echo "--- ARP Table ---"
        ip neigh show
        echo ""
        
        echo "--- Connection Tracking (sample) ---"
        conntrack -L 2>&1 | head -50 || echo "conntrack not available"
        echo ""
        
        echo "--- Network Socket Summary ---"
        ss -s
        echo ""
        
        echo "--- Active TCP Connections ---"
        ss -t -a | head -50
        echo ""
        
        echo "--- Active UDP Connections ---"
        ss -u -a | head -50
        echo ""
        
        echo "--- DNS Resolution Status ---"
        systemctl status systemd-resolved --no-pager -l | head -30
        echo ""
        
        echo "--- resolv.conf ---"
        cat /etc/resolv.conf
        echo ""
        
        echo "--- Kernel Network Parameters (selection) ---"
        sysctl -a 2>/dev/null | grep -E 'net.ipv4|net.ipv6|net.core' | grep -v '^#' | head -100
        echo ""
        
        echo "--- Final uname ---"
        uname -a
        echo ""
        
        echo "--- Final uptime ---"
        uptime
        echo ""
        
    } > "${CAPTURE_SESSION_DIR}/logs/final-diagnostics.txt" 2>&1
    
    log_ok "Final diagnostics captured"
}

# Cleanup handler
cleanup() {
    log_info "Stopping all captures..."
    
    # If we used timeout with duration, most processes should auto-terminate
    # But we still need to handle manual stops and indefinite captures
    
    # Kill dumpcap processes (timeout wraps these)
    if [[ -f "${CAPTURE_SESSION_DIR}/dumpcap.pids" ]]; then
        while read -r pid; do
            if kill -0 "${pid}" 2>/dev/null; then
                log_info "Stopping dumpcap/timeout wrapper (PID: ${pid})"
                kill -TERM "${pid}" 2>/dev/null || true
                sleep 1
                # Force kill if still alive
                if kill -0 "${pid}" 2>/dev/null; then
                    kill -KILL "${pid}" 2>/dev/null || true
                fi
            fi
        done < "${CAPTURE_SESSION_DIR}/dumpcap.pids"
    fi
    
    # Kill log capture PIDs
    if [[ -f "${CAPTURE_SESSION_DIR}/log-capture.pid" ]]; then
        while read -r pid; do
            if kill -0 "${pid}" 2>/dev/null; then
                log_info "Stopping log capture (PID: ${pid})"
                kill -TERM "${pid}" 2>/dev/null || true
                sleep 1
                if kill -0 "${pid}" 2>/dev/null; then
                    kill -KILL "${pid}" 2>/dev/null || true
                fi
            fi
        done < "${CAPTURE_SESSION_DIR}/log-capture.pid"
    fi
    
    # Kill stats monitor
    if [[ -f "${CAPTURE_SESSION_DIR}/stats-monitor.pid" ]]; then
        local stats_pid
        stats_pid=$(cat "${CAPTURE_SESSION_DIR}/stats-monitor.pid" 2>/dev/null || echo "")
        if [[ -n "${stats_pid}" ]] && kill -0 "${stats_pid}" 2>/dev/null; then
            log_info "Stopping stats monitor (PID: ${stats_pid})"
            kill -TERM "${stats_pid}" 2>/dev/null || true
            sleep 1
            if kill -0 "${stats_pid}" 2>/dev/null; then
                kill -KILL "${stats_pid}" 2>/dev/null || true
            fi
        fi
    fi
    
    # Final safety: look for any remaining dumpcap processes
    local orphans
    orphans=$(pgrep -f "dumpcap" | xargs -I {} sh -c 'ps -p {} -o args= | grep -q "'"${TIMESTAMP}"'" && echo {}' 2>/dev/null || true)
    if [[ -n "${orphans}" ]]; then
        log_warn "Found orphaned dumpcap processes, force killing..."
        echo "${orphans}" | xargs -r kill -KILL 2>/dev/null || true
    fi
    
    # Wait for cleanup
    sleep 2
    
    # Capture final statistics and diagnostics
    capture_final_stats
    capture_final_diagnostics
    
    log_ok "All captures stopped"
    log_info "Capture files located at: ${CAPTURE_SESSION_DIR}"
    log_info "Total size: $(du -sh ${CAPTURE_SESSION_DIR} 2>/dev/null | cut -f1 || echo 'unknown')"
}

# Capture final statistics
capture_final_stats() {
    log_info "Capturing final interface statistics..."
    
    {
        echo "=== Interface Statistics at End ==="
        echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        
        for iface in "${INTERFACES[@]}"; do
            echo "--- Interface: ${iface} ---"
            ip -s link show "${iface}" 2>&1 || echo "Interface ${iface} not found"
            echo ""
            ethtool -S "${iface}" 2>&1 || echo "ethtool stats not available for ${iface}"
            echo ""
        done
        
        echo "=== Route Table ==="
        ip route show
        echo ""
        
        echo "=== IP Addresses ==="
        ip addr show
        echo ""
        
        echo "=== Final dmesg (network-related, last 100 lines) ==="
        dmesg | grep -iE 'network|link|bond|eth|interface' | tail -100
        
    } > "${CAPTURE_SESSION_DIR}/stats/final-stats.txt"
    
    log_ok "Final statistics captured"
}

# Create summary file
create_summary() {
    log_info "Creating capture summary..."
    
    {
        echo "Netplan Rollback Capture Session"
        echo "================================="
        echo ""
        echo "Session ID: ${TIMESTAMP}"
        echo "Start Time: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Duration: ${CAPTURE_DURATION:-"Indefinite (until stopped)"} seconds"
        echo ""
        echo "Captured Interfaces:"
        for iface in "${INTERFACES[@]}"; do
            echo "  - ${iface}"
        done
        echo ""
        echo "Capture Directory Structure:"
        echo "  ${CAPTURE_SESSION_DIR}/"
        echo "  ├── pcaps/              # Packet captures (pcapng format)"
        for iface in "${INTERFACES[@]}"; do
            echo "  │   ├── ${iface}.pcapng"
        done
        echo "  ├── logs/               # System and service logs"
        echo "  │   ├── system-logs.txt        # Comprehensive system logs (dmesg, syslog, journalctl)"
        echo "  │   ├── systemd-services.txt   # Systemd network service logs"
        echo "  │   ├── final-diagnostics.txt  # Final diagnostic snapshot"
        for iface in "${INTERFACES[@]}"; do
            echo "  │   ├── ${iface}-dumpcap.log  # Dumpcap output for ${iface}"
        done
        echo "  ├── stats/              # Interface statistics"
        echo "  │   ├── initial-stats.txt      # Statistics at capture start"
        echo "  │   ├── periodic-stats.txt     # Periodic samples during capture"
        echo "  │   └── final-stats.txt        # Statistics at capture end"
        echo "  └── README.txt          # This file"
        echo ""
        echo "Logs Captured:"
        echo "  - dmesg (kernel messages)"
        echo "  - /var/log/syslog"
        echo "  - /var/log/kern.log"
        echo "  - journalctl for: systemd-networkd, systemd-resolved, networkd-dispatcher"
        echo ""
        echo "To analyze captures:"
        echo "  # View packet capture in Wireshark"
        echo "  wireshark ${CAPTURE_SESSION_DIR}/pcaps/<interface>.pcapng"
        echo ""
        echo "  # Analyze with tshark"
        echo "  tshark -r ${CAPTURE_SESSION_DIR}/pcaps/<interface>.pcapng"
        echo ""
        echo "  # View system logs"
        echo "  less ${CAPTURE_SESSION_DIR}/logs/system-logs.txt"
        echo ""
        echo "  # View interface statistics"
        echo "  less ${CAPTURE_SESSION_DIR}/stats/periodic-stats.txt"
        echo ""
        
    } > "${CAPTURE_SESSION_DIR}/README.txt"
    
    log_ok "Summary created: ${CAPTURE_SESSION_DIR}/README.txt"
}

# Main execution
main() {
    check_requirements
    setup_capture_directory
    create_summary

    # Ignore SIGHUP so capture continues even if parent SSH session dies
    # This is critical for remote network changes
    trap '' HUP
    
    # Set up cleanup handler for other signals
    trap cleanup EXIT INT TERM
    
    # Capture initial state
    capture_initial_stats
    
    # Start packet captures on all interfaces
    for iface in "${INTERFACES[@]}"; do
        start_interface_capture "${iface}"
    done
    
    # Start log capture
    start_log_capture
    
    # Start stats monitoring
    monitor_interface_stats
    
    log_ok "All captures started successfully"
    log_info "Capture directory: ${CAPTURE_SESSION_DIR}"
    
    # If duration specified, wait for it
    if [[ -n "${CAPTURE_DURATION}" ]]; then
        log_info "Capturing for ${CAPTURE_DURATION} seconds..."
        sleep "${CAPTURE_DURATION}"
        log_info "Capture duration completed"
    else
        log_info "Capturing indefinitely (Ctrl+C or kill to stop)..."
        # Wait forever until killed
        while true; do
            sleep 3600
        done
    fi
}

# Run main function
main "$@"
