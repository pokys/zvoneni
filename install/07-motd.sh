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

NEXT=$(systemctl list-timers --no-legend | grep zvoneni | head -n1 | awk '{print $1" "$2}')
LEFT=$(systemctl list-timers --no-legend | grep zvoneni | head -n1 | awk '{print $3}')

COUNT=$(systemctl list-timers --no-legend | grep -c zvoneni)

echo "State:       $STATE"
echo "Time:        $TIME"
echo "Clock:       $CLOCK"
echo "Timers:      $COUNT active"

if [ -n "$NEXT" ]; then
  echo "Next bell:   $NEXT (in $LEFT)"
else
  echo "Next bell:   -"
fi

echo
echo "Admin UI:    zvoneni-tui"
echo
EOF

chmod +x /etc/update-motd.d/99-zvoneni
