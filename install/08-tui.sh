#!/bin/bash
set -e

cat > /usr/local/bin/zvoneni-tui <<'EOF'
#!/bin/bash
while true; do
  fs=$(mount | grep ' / ' | grep -q '(ro,' && echo RO || echo RW)

  choice=$(dialog --menu "School Bell (FS=$fs)" 20 70 10 \
    1 "Edit schedule" \
    2 "Apply schedule" \
    3 "Test bell" \
    4 "Switch FS RW" \
    5 "Switch FS RO" \
    6 "Show status" \
    7 "Exit" 3>&1 1>&2 2>&3)

  case $choice in
    1) nano /opt/zvoneni/schedule.txt ;;
    2) generate-timers.sh ;;
    3) systemctl start zvoneni@normal.service ;;
    4) mount -o remount,rw / ;;
    5) mount -o remount,ro / ;;
    6) systemctl status clock-watch ;;
    7) clear; exit ;;
  esac
done
EOF

chmod +x /usr/local/bin/zvoneni-tui