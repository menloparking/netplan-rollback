# Systemd Unit Templates

These are template files for the systemd units used by netplan-rollback.

**Note:** The actual systemd units are created dynamically by `netplan-swap.sh`
at runtime with the appropriate timing values. These templates are provided
for reference and documentation purposes.

## Files

- `netplan-auto-rollback.service.template` - Service unit that executes the rollback
- `netplan-auto-rollback.timer.template` - Timer unit that schedules the rollback

## How It Works

When you run `netplan-swap.sh`, it creates these units in `/etc/systemd/system/`
with the `OnCalendar` value set to the exact datetime when the rollback should occur.

The timer unit uses:
- `Persistent=true` - Ensures rollback happens after reboot if the system was down
- `AccuracySec=1s` - Fires within 1 second of the scheduled time
- `PartOf=` - Ensures stopping the service also stops the timer

## Manual Operations

To check rollback status:
```bash
systemctl status netplan-auto-rollback.timer
systemctl list-timers netplan-auto-rollback.timer
```

To force immediate rollback:
```bash
sudo systemctl start netplan-auto-rollback.service
```

To cancel scheduled rollback:
```bash
sudo netplan-confirm.sh
```
