#!/bin/bash
set -e

cat > /etc/update-motd.d/99-zvoneni <<'EOF'
#!/bin/bash
echo "=== SCHOOL BELL SYSTEM ==="
[ -f /run/clock-ok ] && echo "Clock: OK" || echo "Clock: WAITING"
echo "Time: $(date)"
echo "Next bell:"
systemctl list-timers --no-pager | grep zvoneni | head -n1
EOF

chmod +x /etc/update-motd.d/99-zvoneni