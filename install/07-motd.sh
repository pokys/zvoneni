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

# Bells in the schedule vs. timers actually installed. These diverge
# silently in one case that matters: the generator runs on every boot and
# refuses a schedule that is invalid or empty, so a broken schedule.txt
# leaves the PREVIOUS timers running indefinitely, with the error only in
# a journal nobody reads. Everywhere else the failure is loud at apply
# time; here it is not, which is why the count sits on the login banner.
SCHEDULED=$(grep -cvE '^[[:space:]]*(#|$)' /opt/zvoneni/schedule.txt 2>/dev/null || true)
[ -n "$SCHEDULED" ] || SCHEDULED=0
ACTIVE=$(ls -1 /etc/systemd/system/zvoneni-[A-Z][a-z][a-z]-[0-9][0-9][0-9][0-9].timer 2>/dev/null | wc -l)

BELLS="$SCHEDULED scheduled / $ACTIVE active"
[ "$SCHEDULED" -eq "$ACTIVE" ] || BELLS="$BELLS   (!) run Apply schedule"

echo "State:       $STATE"
echo "Time:        $TIME"
echo "Clock:       $CLOCK"
echo "Bells:       $BELLS"
echo "Next bell:   $NEXT"

echo
echo "Admin UI:   sudo zvoneni-tui"
echo
EOF

chmod +x /etc/update-motd.d/99-zvoneni
