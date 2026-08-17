#!/bin/bash
set -e

echo "[install] enabling services"

systemctl daemon-reload

systemctl enable clock-watch.service
systemctl enable zvoneni-amp-reset.service
# Always enabled; the daemon exits immediately when the button is switched
# off in amp.conf, so the config alone decides and a reboot needs no extra
# state.
systemctl enable zvoneni-amp-button.service
systemctl enable zvoneni-generator.service
systemctl enable zvoneni.target
