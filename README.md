# netplan-rollback

Safe netplan configuration switcher with automatic rollback protection.

## Overview

`netplan-rollback` is a set of bash scripts that allow you to safely apply new netplan network configurations with automatic rollback capability. If you lose network connectivity after applying a new configuration, the system will automatically revert to the previous working configuration after a specified timeout.

### Why This Tool Exists

While netplan provides a built-in `netplan try` command for safe configuration testing, **it does not support creating or modifying network bonds**. When you need to add bond interfaces or change bond configurations, `netplan try` will fail, leaving you without a safety net for risky network changes.

This tool fills that gap by providing the same rollback protection that `netplan try` offers, but with full support for:
- Creating new network bonds
- Modifying existing bond configurations
- Any other netplan configuration changes
- Reboot-resistant rollback timers (survives system reboots)

This is especially useful when:
- Applying network bonding configurations (where `netplan try` cannot be used)
- Making risky network changes remotely
- Testing new network configurations without physical access
- Data center network reconfiguration

## Features

- **Automatic Rollback**: Schedules automatic revert if new config isn't confirmed
- **Reboot Resistant**: Survives system reboots using persistent systemd timers
- **Syntax Validation**: Validates netplan config before applying
- **Dry-Run Mode**: Test without making actual changes
- **Configuration Backup**: Automatically backs up current configuration
- **Flexible Timeout**: Configurable rollback timeout (default: 5 minutes)
- **Easy Confirmation**: Simple command to confirm working configuration
- **Detailed Logging**: Comprehensive logging to syslog and file

## Requirements

- Ubuntu 20.04+ (or similar Linux distribution with netplan)
- systemd
- netplan
- jq (JSON processor)
- Root access

## Installation

### Quick Install

```bash
# Clone the repository
git clone https://github.com/menloparking/netplan-rollback.git
cd netplan-rollback

# Install
sudo ./install.sh
```

### Installation Options

```bash
# Install (default)
sudo ./install.sh --install

# Test installation without making changes
sudo ./install.sh --dry-run

# Update existing installation
sudo ./install.sh --update

# Uninstall
sudo ./install.sh --uninstall
```

## Quick Start

### 1. Apply New Configuration with Rollback Protection

```bash
sudo netplan-swap.sh /etc/netplan/50-cloud-init.yaml /root/new-network-config.yaml 300
```

This will:
1. Validate the new configuration syntax
2. Create a backup of the current configuration
3. Apply the new configuration
4. Schedule automatic rollback in 300 seconds (5 minutes)

### 2. Test Your Network

After applying, **immediately test your network connectivity**:
- Can you still SSH to the server?
- Can you ping external hosts?
- Are your services accessible?

### 3a. If Network Works - Confirm

```bash
sudo netplan-confirm.sh
```

This cancels the automatic rollback and makes the new configuration permanent.

### 3b. If Network Fails - Wait or Force Rollback

```bash
# Option 1: Wait for automatic rollback (after timeout)
# The system will automatically revert

# Option 2: Force immediate rollback
sudo systemctl start netplan-auto-rollback.service
```

## Usage

### netplan-swap.sh

Main script to apply configurations with rollback protection.

```bash
Usage: netplan-swap.sh [OPTIONS] <current-config-path> <new-config-path> [timeout-seconds]

OPTIONS:
  -n, --dry-run       Validate but don't apply changes
  -h, --help          Show help message

ARGUMENTS:
  current-config-path   Path to current netplan YAML
  new-config-path       Path to new netplan YAML to apply
  timeout-seconds       Seconds before auto-rollback (default: 300)

EXAMPLES:
  # Apply with 5 minute timeout
  sudo netplan-swap.sh /etc/netplan/50-cloud-init.yaml /root/bond.yaml 300

  # Test without applying
  sudo netplan-swap.sh --dry-run /etc/netplan/50-cloud-init.yaml /root/bond.yaml

  # Apply with 10 minute timeout
  sudo netplan-swap.sh /etc/netplan/50-cloud-init.yaml /root/bond.yaml 600
```

### netplan-confirm.sh

Confirm new configuration and cancel rollback.

```bash
Usage: netplan-confirm.sh [OPTIONS]

OPTIONS:
  -k, --keep-backup    Keep backup files without prompting
  -h, --help          Show help message

EXAMPLES:
  # Confirm and prompt about backup
  sudo netplan-confirm.sh

  # Confirm and keep backup
  sudo netplan-confirm.sh --keep-backup
```

### netplan-rollback.sh

Execute rollback (normally called automatically by systemd).

```bash
Usage: netplan-rollback.sh

This script is typically called automatically by the systemd timer.
You can also call it manually to force an immediate rollback.

EXAMPLES:
  # Force immediate rollback
  sudo netplan-rollback.sh
```

## How It Works

### Architecture

1. **netplan-swap.sh** - Orchestrates the entire process:
   - Validates syntax
   - Creates backup
   - Applies new config
   - Schedules rollback timer

2. **systemd timer** - Persistent timer that:
   - Survives reboots
   - Triggers rollback at scheduled time
   - Works even if SSH connection dies

3. **netplan-rollback.sh** - Executes rollback:
   - Restores backup configuration
   - Applies netplan
   - Cleans up timer

4. **netplan-confirm.sh** - Cancels rollback:
   - Stops and disables timer
   - Marks config as confirmed
   - Optional backup cleanup

### State Management

All state is stored in `/root/netplan-rollback/`:
- `state.json` - Current rollback state
- `backup-YYYYMMDD-HHMMSS.yaml` - Backup configurations
- `rollback.log` - Detailed operation log

### Reboot Resistance

The rollback uses systemd's `Persistent=true` timer feature with absolute calendar time (`OnCalendar`). This means:
- If system reboots during timeout, rollback still occurs after boot
- Timer persists across reboots with correct trigger time
- No manual intervention needed

## Examples

### Example 1: Bond Configuration Change

```bash
# You have a bond configuration to apply
sudo netplan-swap.sh /etc/netplan/50-cloud-init.yaml /root/netplan-bond.yaml 300

# Test network connectivity
ping 8.8.8.8
ssh user@another-server

# If everything works, confirm
sudo netplan-confirm.sh
```

### Example 2: Testing Before Production

```bash
# First, validate syntax with dry-run
sudo netplan-swap.sh --dry-run /etc/netplan/current.yaml /root/new-config.yaml

# If validation passes, apply with longer timeout for thorough testing
sudo netplan-swap.sh /etc/netplan/current.yaml /root/new-config.yaml 600

# Run comprehensive network tests...
# If all tests pass, confirm
sudo netplan-confirm.sh
```

### Example 3: Multiple Network Changes

```bash
# Apply first change
sudo netplan-swap.sh /etc/netplan/current.yaml /root/config-v1.yaml 300
# Test and confirm
sudo netplan-confirm.sh

# Apply second change (can only have one rollback at a time)
sudo netplan-swap.sh /etc/netplan/current.yaml /root/config-v2.yaml 300
# Test and confirm
sudo netplan-confirm.sh
```

## Monitoring

### Check Rollback Status

```bash
# Check if rollback is scheduled
systemctl status netplan-auto-rollback.timer

# List all timers including rollback
systemctl list-timers netplan-auto-rollback.timer

# View real-time logs
journalctl -u netplan-auto-rollback -f

# View rollback log file
tail -f /root/netplan-rollback/rollback.log
```

### Check State File

```bash
# View current state
cat /root/netplan-rollback/state.json | jq .

# Check rollback time
jq -r '.rollback_datetime' /root/netplan-rollback/state.json
```

## Troubleshooting

### Rollback Timer Not Firing

Check timer status:
```bash
systemctl status netplan-auto-rollback.timer
journalctl -u netplan-auto-rollback.timer
```

### Manual Rollback

If automatic rollback fails:
```bash
# Check backup files
ls -l /root/netplan-rollback/

# Manually restore
sudo cp /root/netplan-rollback/backup-YYYYMMDD-HHMMSS.yaml /etc/netplan/50-cloud-init.yaml
sudo netplan apply
```

### Permission Issues

All scripts require root:
```bash
sudo netplan-swap.sh ...
```

State directory requires root access:
```bash
sudo ls -la /root/netplan-rollback/
```

### Cleanup After Issues

```bash
# Stop any active rollback
sudo systemctl stop netplan-auto-rollback.timer
sudo systemctl disable netplan-auto-rollback.timer

# Remove systemd units
sudo rm /etc/systemd/system/netplan-auto-rollback.*
sudo systemctl daemon-reload

# Clean state directory
sudo rm -rf /root/netplan-rollback/
```

## Safety Features

1. **Pre-flight Validation**: Syntax checked before applying
2. **Single Rollback**: Only one rollback can be scheduled at a time
3. **Backup Preservation**: Original configs backed up with timestamps
4. **Comprehensive Logging**: All operations logged to syslog and file
5. **Reboot Protection**: Timer persists across reboots
6. **State Tracking**: Full state information in JSON format

## Testing

Run the automated test suite:

```bash
# Run all tests
sudo ./tests/test-suite.sh

# Run interactively (with prompts)
sudo ./tests/test-suite.sh --interactive

# Run specific test
sudo ./tests/test-suite.sh --test-syntax
```

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## License

MIT License - see LICENSE file for details.

## Author

Andrew Janssen

## Links

- GitHub: https://github.com/menloparking/netplan-rollback
- Issues: https://github.com/menloparking/netplan-rollback/issues
