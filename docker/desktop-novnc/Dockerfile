FROM nvidia/cuda:12.4.1-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:1 \
    VNC_PORT=5901 \
    NOVNC_PORT=6901 \
    VNC_COL_DEPTH=24 \
    VNC_RESOLUTION=2560x1440 \
    VNC_QUALITY=7 \
    VNC_COMPRESS=2 \
    VNC_PASSWORD=runpod \
    USER=root \
    HOME=/root

RUN apt-get update && apt-get install -y --no-install-recommends \
    xfce4 xfce4-terminal dbus-x11 xauth x11-xserver-utils xfwm4 \
    git curl wget ca-certificates novnc websockify supervisor mesa-utils \
    && rm -rf /var/lib/apt/lists/*

# TurboVNC via GitHub releases (not SourceForge)
RUN curl -fsSL -o /tmp/turbovnc.deb \
    https://github.com/TurboVNC/turbovnc/releases/download/3.1.1/turbovnc_3.1.1_amd64.deb && \
    apt-get install -y /tmp/turbovnc.deb && \
    rm -f /tmp/turbovnc.deb && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /root/.vnc && \
    printf '%s\n' '#!/bin/bash' \
      'xfconf-query -c xfwm4 -p /general/use_compositing -s false || true' \
      'startxfce4 &' > /root/.vnc/xstartup && \
    chmod +x /root/.vnc/xstartup

RUN cat >/etc/supervisor/conf.d/desktop.conf <<'EOF'
[supervisord]
nodaemon=true

[program:vnc]
command=/opt/TurboVNC/bin/vncserver :1 -rfbport %(ENV_VNC_PORT)s -geometry %(ENV_VNC_RESOLUTION)s -depth %(ENV_VNC_COL_DEPTH)s -securitytypes VncAuth -passwd /root/.vnc/passwd -quality %(ENV_VNC_QUALITY)s -compresslevel %(ENV_VNC_COMPRESS)s
autorestart=true
stdout_logfile=/workspace/vnc_stdout.log
stderr_logfile=/workspace/vnc_stderr.log

[program:novnc]
command=websockify --web=/usr/share/novnc/ %(ENV_NOVNC_PORT)s localhost:%(ENV_VNC_PORT)s
autorestart=true
stdout_logfile=/workspace/novnc_stdout.log
stderr_logfile=/workspace/novnc_stderr.log
EOF

COPY start-desktop.sh /usr/local/bin/start-desktop.sh
RUN chmod +x /usr/local/bin/start-desktop.sh

WORKDIR /workspace
EXPOSE 6901
CMD ["/usr/local/bin/start-desktop.sh"]
