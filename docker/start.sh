#!/bin/bash
set -e
echo "============================================="
echo "TW3K Cloud Gaming -- Starting Up"
echo "============================================="

# Generate Xauthority
xauth add :0 . $(mcookie)

# Bootstrap Sunshine credentials headlessly
/home/gamer/autopair.sh setup "${SUNSHINE_USER:-admin}" "${SUNSHINE_PASS:-admin}" &

# Start services via supervisor
exec supervisord -c /etc/supervisord.conf
