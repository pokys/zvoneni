#!/bin/bash
set -e

cat > /etc/systemd/system/zvoneni.target <<EOF
[Unit]
Description=School Bell System
EOF