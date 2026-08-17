#!/bin/bash
set -e

cat > /etc/update-motd.d/99-zvoneni <<'EOF'
#!/bin/bash

echo
echo "========================================"
echo "        SCHOOL BELL SYSTEM (ZVONENI)"
echo "========================================"
echo

TIME=$(date '+%Y-%m-%d %H:%M:%S')

if systemctl is-active zvoneni.target >/dev/null 2>&1; then
  STATE="RUNNING"
else
  STATE="STOPPED"
fi

if [ -f /run/clock-ok ]; then
  CLOCK="OK"
else
  CLOCK="WAIT"
fi

NEXT=$(/usr/local/bin/zvoneni-next-bell 2>/dev/null || echo "-")

COUNT=$(systemctl list-timers --no-legend | grep -c zvoneni)

echo "State:       $STATE"
echo "Time:        $TIME"
echo "Clock:       $CLOCK"
echo "Timers:      $COUNT active"
echo "Next bell:   $NEXT"

echo
echo "Admin UI:   sudo zvoneni-tui"
echo
EOF

chmod +x /etc/update-motd.d/99-zvoneni
