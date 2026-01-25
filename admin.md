# Troubleshooting

## Status
systemctl status clock-watch
ls /run/clock-ok

## Timers
systemctl list-timers | grep zvoneni

## Logs
journalctl -u clock-watch
journalctl -u zvoneni@*

## Test sound
systemctl start zvoneni@normal.service

## FS mode
mount | grep ' / '