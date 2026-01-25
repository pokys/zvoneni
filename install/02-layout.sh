#!/bin/bash
set -e

mkdir -p /opt/zvoneni/{sounds}
mkdir -p /usr/local/bin

[ -f /opt/zvoneni/schedule.txt ] || cat > /opt/zvoneni/schedule.txt <<EOF
# DAY TIME TYPE
Mon 08:00 normal
EOF