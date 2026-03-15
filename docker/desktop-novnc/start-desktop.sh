#!/usr/bin/env bash
set -euo pipefail

mkdir -p /root/.vnc /workspace
echo "${VNC_PASSWORD}" | /opt/TurboVNC/bin/vncpasswd -f > /root/.vnc/passwd
chmod 600 /root/.vnc/passwd
rm -rf /tmp/.X*-lock /tmp/.X11-unix/X* || true
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
