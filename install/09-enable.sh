#!/bin/bash
set -e

echo "[install] enabling services"

systemctl daemon-reload

systemctl enable clock-watch.service
systemctl enable zvoneni-generator.service
systemctl enable zvoneni.target
