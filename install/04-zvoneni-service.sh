#!/bin/bash
set -e

cat > /etc/systemd/system/zvoneni@.service <<'EOF'
[Unit]
Description=School bell (%i)
ConditionPathExists=/run/clock-ok
ConditionPathExists=/opt/zvoneni/sounds/%i.wav

[Service]
Type=oneshot
# Long enough for the amplifier pre-roll + the sound + the post-roll.
# The default of 90s would kill a bell with a generous pre-roll.
TimeoutStartSec=900
ExecStart=/usr/local/bin/zvoneni-ring %i
# Belt and braces: zvoneni-ring already releases the amplifier from a trap,
# this also covers the unit being killed outright.
ExecStopPost=/usr/local/bin/zvoneni-amp off ring-%i
EOF