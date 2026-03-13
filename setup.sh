#!/usr/bin/env bash
###############################################################################
#  RunPod Gaming Rig v14 — Pathfinder: WotR
#  NVIDIA A5000/L4 | Ubuntu 22.04 | Sunshine → Moonlight | 4K@144Hz
#  KNOWN: RunPod blocks inbound UDP — Tailscale stays on DERP relay
#  REQUIREMENT: Use provider with open UDP (Vast.ai, Lambda, etc.)
###############################################################################

mkdir -p /workspace/gaming-logs
exec > >(tee /workspace/gaming-logs/setup.log) 2>&1
set -uo pipefail

SECONDS=0
LOG_DIR="/workspace/gaming-logs"

# ── tunables ──────────────────────────────────────────────────
DISPLAY_NUM=99
export DISPLAY=":${DISPLAY_NUM}"
RES_W=3840; RES_H=2160; RES_HZ=144
ROOT_PASS="gondolin123"
SUNSHINE_USER="admin"
SUNSHINE_PASS="gondolin123"
B2_BUCKET="FunFun"
B2_ENDPOINT="${B2_ENDPOINT:-s3.us-east-005.backblazeb2.com}"
B2_KEY_ID="${B2_KEY_ID:-}"
B2_APP_KEY="${B2_APP_KEY:-}"

# WotR paths — native Linux + Proton fallback
WOTR_SAVES="/root/.local/share/unity3d/Owlcat Games/Pathfinder Wrath Of The Righteous/Saved Games"
WOTR_SAVES_PROTON="/root/.steam/steam/steamapps/compatdata/1184370/pfx/drive_c/users/steamuser/AppData/LocalLow/Owlcat Games/Pathfinder Wrath Of The Righteous/Saved Games"
WOTR_MODS="/root/.steam/steam/steamapps/common/Pathfinder Second Adventure/Mods"

# ── helpers ───────────────────────────────────────────────────
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[1;34m'; N='\033[0m'
log()  { printf "${G}[OK %s]${N} %s\n" "$(date +%H:%M:%S)" "$*"; }
warn() { printf "${Y}[WW %s]${N} %s\n" "$(date +%H:%M:%S)" "$*"; }
err()  { printf "${R}[EE %s]${N} %s\n" "$(date +%H:%M:%S)" "$*"; }
hdr()  { printf "\n${B}=== %s ===${N}\n" "$*"; }

###############################################################################
hdr "0 — BOOTSTRAP + CLEANUP"
###############################################################################
pkill -x supervisord 2>/dev/null || true
pkill -f Xvfb        2>/dev/null || true
pkill -f Xorg        2>/dev/null || true
pkill -f sunshine    2>/dev/null || true
pkill -f openbox     2>/dev/null || true
sleep 2

rm -f /tmp/.X${DISPLAY_NUM}-lock 2>/dev/null || true
rm -f /tmp/.X11-unix/X${DISPLAY_NUM} 2>/dev/null || true

apt-get install -y curl wget 2>/dev/null || true
log "bootstrap done"

###############################################################################
hdr "1 — SSH"
###############################################################################
echo "root:${ROOT_PASS}" | chpasswd
CFG=/etc/ssh/sshd_config
grep -q '^PasswordAuthentication' "$CFG" \
    && sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' "$CFG" \
    || echo 'PasswordAuthentication yes' >> "$CFG"
grep -q '^PermitRootLogin' "$CFG" \
    && sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' "$CFG" \
    || echo 'PermitRootLogin yes' >> "$CFG"
grep -q '^#PasswordAuthentication' "$CFG" && sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' "$CFG" || true
grep -q '^#PermitRootLogin' "$CFG"        && sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' "$CFG"              || true
service ssh restart 2>/dev/null || systemctl restart ssh 2>/dev/null || /usr/sbin/sshd 2>/dev/null || true
log "SSH ready"

###############################################################################
hdr "2 — PURGE BROKEN DPKG STATE"
###############################################################################
dpkg --remove --force-remove-reinstreq sunshine 2>/dev/null || true
dpkg --purge  --force-remove-reinstreq sunshine 2>/dev/null || true
dpkg --configure -a 2>/dev/null || true
apt-get -f install -y 2>/dev/null || true
log "dpkg state clean"

###############################################################################
hdr "3 — PACKAGES"
###############################################################################
export DEBIAN_FRONTEND=noninteractive
add-apt-repository -y universe 2>/dev/null || true
apt-get update -qq || warn "apt update had errors"

apt-get install -y --no-install-recommends \
    xvfb x11-xserver-utils x11-utils xterm openbox dbus-x11 \
    xdotool xauth xkb-data 2>/dev/null || warn "some X pkgs failed"

apt-get install -y --no-install-recommends \
    pulseaudio pulseaudio-utils alsa-utils 2>/dev/null || warn "pulse pkgs failed"

apt-get install -y --no-install-recommends \
    rsync jq mesa-utils 2>/dev/null || warn "util pkgs failed"

# CRITICAL sunshine deps
CRITICAL_DEPS=(
    libayatana-appindicator3-1
    libva2
    libva-drm2
)
for pkg in "${CRITICAL_DEPS[@]}"; do
    log "Installing CRITICAL dep: $pkg"
    if ! apt-get install -y --no-install-recommends "$pkg"; then
        err "CRITICAL dep $pkg FAILED — sunshine will not start without this"
    fi
done

for pkg in \
    libnotify4 \
    libminiupnpc17 \
    libevdev2 \
    libnuma1 \
    libvdpau1 \
    libboost-locale1.74.0 \
    libboost-thread1.74.0 \
    libboost-filesystem1.74.0 \
    libboost-log1.74.0 \
    libboost-program-options1.74.0; do
    apt-get install -y --no-install-recommends "$pkg" 2>/dev/null \
        || warn "optional dep $pkg not available — skipping"
done

# Fix libstdc++ — old version causes Sunshine segfault mid-stream
# Install conda-forge libstdc++ 6.0.33+
if python3 -c "import ctypes; ctypes.CDLL('libstdc++.so.6')" 2>/dev/null; then
    STDCXX_VER=$(strings $(ldconfig -p | grep 'libstdc++.so.6' | awk '{print $NF}' | head -1) 2>/dev/null | grep 'GLIBCXX_' | sort -V | tail -1 || echo "unknown")
    log "libstdc++ GLIBCXX max: $STDCXX_VER"
fi
# Install conda if not present and use it for libstdc++
if ! command -v conda &>/dev/null; then
    log "Installing miniconda for libstdc++ fix..."
    curl -fsSL https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -o /tmp/miniconda.sh
    bash /tmp/miniconda.sh -b -p /opt/conda 2>/dev/null
    rm -f /tmp/miniconda.sh
    export PATH="/opt/conda/bin:$PATH"
fi
export PATH="/opt/conda/bin:$PATH"
conda install -y -c conda-forge libstdcxx-ng 2>/dev/null || warn "conda libstdcxx-ng install failed"
# Symlink conda's libstdc++ over system one
CONDA_STDCXX=$(find /opt/conda -name 'libstdc++.so.6.*' 2>/dev/null | sort -V | tail -1 || true)
if [ -n "$CONDA_STDCXX" ]; then
    cp -f "$CONDA_STDCXX" /usr/lib/x86_64-linux-gnu/libstdc++.so.6
    ldconfig
    log "libstdc++ updated from conda: $CONDA_STDCXX"
else
    warn "conda libstdc++ not found — segfault risk remains"
fi

ldconfig 2>/dev/null || true

CRITICAL_SO_OK=true
for soname in libayatana-appindicator3.so.1 libva.so.2; do
    SO_PATH=$(find /usr/lib /usr/lib64 /usr/local/lib -name "$soname" 2>/dev/null | head -1 || true)
    if [ -n "$SO_PATH" ]; then
        log "FOUND: $soname → $SO_PATH"
    else
        err "MISSING: $soname"
        CRITICAL_SO_OK=false
    fi
done
[ "$CRITICAL_SO_OK" = false ] && err "Critical .so missing — sunshine WILL crash"

log "packages done"

pip3 install --quiet supervisor 2>/dev/null || true
SUPD=$(command -v supervisord 2>/dev/null \
    || find /usr/local/bin /root/.local/bin /usr/bin -name supervisord 2>/dev/null | head -1 || true)
[ -z "$SUPD" ] && { apt-get install -y supervisor 2>/dev/null || true; SUPD=$(command -v supervisord 2>/dev/null || true); }
[ -z "$SUPD" ] && { err "supervisord not found"; exit 1; }
SUPC=$(command -v supervisorctl 2>/dev/null \
    || find /usr/local/bin /root/.local/bin /usr/bin -name supervisorctl 2>/dev/null | head -1 || true)
[ -n "$SUPC" ] && ln -sf "$SUPC" /usr/local/bin/supervisorctl 2>/dev/null || true
log "supervisord: $SUPD"

###############################################################################
hdr "4 — GPU / NVENC"
###############################################################################
DRI_RENDER=$(ls /dev/dri/renderD* 2>/dev/null | sort -V | tail -1 || true)
[ -z "$DRI_RENDER" ] && { warn "No renderD* found"; DRI_RENDER="/dev/dri/renderD128"; } \
                     || log "DRI render: $DRI_RENDER"

GPU_NAME=$(nvidia-smi --query-gpu=name           --format=csv,noheader 2>/dev/null | head -1 || echo "UNKNOWN")
DRV_FULL=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "570.0")
log "GPU=$GPU_NAME drv=$DRV_FULL"

LINK_DIR="/usr/lib/x86_64-linux-gnu"
NVENC_REAL=""
for sd in "$LINK_DIR" /usr/local/nvidia/lib64 /usr/lib64 /usr/local/lib; do
    c=$(find "$sd" -maxdepth 1 -name "libnvidia-encode.so.*" \
        ! -name "libnvidia-encode.so.1" 2>/dev/null | sort -V | tail -1 || true)
    [ -n "$c" ] && { NVENC_REAL="$c"; break; }
done
if [ -n "$NVENC_REAL" ]; then
    ln -sf "$NVENC_REAL"                       "${LINK_DIR}/libnvidia-encode.so.1" 2>/dev/null \
        || cp -f "$NVENC_REAL"                 "${LINK_DIR}/libnvidia-encode.so.1"
    ln -sf "${LINK_DIR}/libnvidia-encode.so.1" "${LINK_DIR}/libnvidia-encode.so"
    printf '%s\n' "$LINK_DIR" "$(dirname "$NVENC_REAL")" > /etc/ld.so.conf.d/nvenc.conf
    ldconfig
    log "NVENC → $NVENC_REAL"
else
    err "libnvidia-encode.so not found — NVENC will fail"
fi
CUDA_REAL=$(find "$LINK_DIR" /usr/local/nvidia/lib64 /usr/lib64 \
    -maxdepth 1 -name "libcuda.so.*" ! -name "libcuda.so.1" 2>/dev/null | head -1 || true)
[ -n "$CUDA_REAL" ] && { ln -sf "$CUDA_REAL" "${LINK_DIR}/libcuda.so.1" 2>/dev/null || true; ldconfig; log "libcuda.so.1 linked"; }

###############################################################################
hdr "5 — SUNSHINE"
###############################################################################
SUN_BIN=$(command -v sunshine 2>/dev/null \
    || find /usr/bin /usr/local/bin -name sunshine -type f 2>/dev/null | head -1 || true)

if [ -z "$SUN_BIN" ]; then
    log "Downloading Sunshine deb..."
    SUN_URL="https://github.com/LizardByte/Sunshine/releases/download/v0.23.1/sunshine-ubuntu-22.04-amd64.deb"
    curl -fsSL "$SUN_URL" -o /tmp/sunshine.deb || { err "Sunshine download failed"; exit 1; }
    SUN_STAGE=$(mktemp -d /tmp/sun-stage-XXXXXX)
    dpkg-deb -x /tmp/sunshine.deb "$SUN_STAGE"
    [ -f "${SUN_STAGE}/usr/bin/sunshine" ]   && cp -f "${SUN_STAGE}/usr/bin/sunshine"   /usr/bin/sunshine
    [ -d "${SUN_STAGE}/usr/lib/sunshine" ]   && { mkdir -p /usr/lib/sunshine; cp -a "${SUN_STAGE}/usr/lib/sunshine/." /usr/lib/sunshine/; }
    [ -d "${SUN_STAGE}/usr/share/sunshine" ] && { mkdir -p /usr/share/sunshine; cp -a "${SUN_STAGE}/usr/share/sunshine/." /usr/share/sunshine/; }
    [ -d "${SUN_STAGE}/etc/sunshine" ]       && { mkdir -p /etc/sunshine; cp -a "${SUN_STAGE}/etc/sunshine/." /etc/sunshine/; }
    rm -rf "$SUN_STAGE" /tmp/sunshine.deb
    ldconfig 2>/dev/null || true
    log "Sunshine extracted"
else
    log "Sunshine already present: $SUN_BIN"
fi

SUN_BIN=$(command -v sunshine 2>/dev/null \
    || find /usr/bin /usr/local/bin -name sunshine -type f 2>/dev/null | head -1 || true)
[ -z "$SUN_BIN" ] && { err "sunshine binary not found"; exit 1; }
chmod +x "$SUN_BIN"

MISSING_LIBS=$(ldd "$SUN_BIN" 2>/dev/null | grep "not found" || true)
if [ -n "$MISSING_LIBS" ]; then
    err "Sunshine missing shared libs:"
    echo "$MISSING_LIBS" | sed 's/^/  /'
else
    log "All sunshine shared libs satisfied"
fi

mkdir -p /root/.config/sunshine
echo '{}' > /root/.config/sunshine/sunshine_state.json

# hevc_mode=1 = 8-bit only. Disables 10-bit HEVC path that triggers
# cuda_t AV_PIX_FMT_NV12 assertion → segfault mid-stream (confirmed session 4)
cat > /root/.config/sunshine/sunshine.conf << SUNEOF
port                  = 47989
upnp                  = off
origin_web_ui_allowed = pc
address_family        = ipv4
capture               = x11
encoder               = nvenc
hevc_register         = true
hevc_mode             = 1
min_threads           = 2
adapter_name          = ${DRI_RENDER}
output_name           = 0
resolutions           = [3840x2160, 2560x1440, 1920x1080]
fps                   = [144, 60, 30]
min_log_level         = info
SUNEOF

"$SUN_BIN" --creds "${SUNSHINE_USER}" "${SUNSHINE_PASS}" 2>/dev/null \
    && log "Sunshine creds set: ${SUNSHINE_USER} / ${SUNSHINE_PASS}" \
    || warn "sunshine --creds failed — use web UI at https://127.0.0.1:47990"

###############################################################################
hdr "6 — TAILSCALE"
###############################################################################
if ! command -v tailscale &>/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh 2>/dev/null || warn "Tailscale install failed"
fi
if command -v tailscale &>/dev/null; then
    # Start tailscaled if not running
    if ! pgrep tailscaled &>/dev/null; then
        tailscaled --tun=userspace-networking --socks5-server=localhost:1055 \
            > /workspace/gaming-logs/tailscale.log 2>&1 &
        sleep 3
    fi
    log "Tailscale daemon running"
    log "Run: tailscale up --authkey=<YOUR_KEY> to connect"
else
    warn "Tailscale not available"
fi

###############################################################################
hdr "7 — GAME ASSETS (WotR)"
###############################################################################
mkdir -p "$WOTR_SAVES" "$WOTR_SAVES_PROTON" "$WOTR_MODS" "$LOG_DIR"

SC=0
while IFS= read -r -d '' f; do
    cp -n "$f" "$WOTR_SAVES/" 2>/dev/null || true
    cp -n "$f" "$WOTR_SAVES_PROTON/" 2>/dev/null || true
    SC=$((SC+1))
done < <(find /workspace -maxdepth 4 -name "*.save" -print0 2>/dev/null)
log "Workspace .save files staged: $SC"

###############################################################################
hdr "8 — B2 SYNC (WotR saves)"
###############################################################################
if [ -n "$B2_KEY_ID" ] && [ -n "$B2_APP_KEY" ]; then
    command -v rclone &>/dev/null || curl -fsSL https://rclone.org/install.sh | bash 2>/dev/null || true

    mkdir -p /root/.config/rclone
    cat > /root/.config/rclone/rclone.conf << RCONF
[b2]
type = s3
provider = Other
access_key_id = ${B2_KEY_ID}
secret_access_key = ${B2_APP_KEY}
endpoint = ${B2_ENDPOINT}
acl = private
no_check_bucket = true
RCONF

    rclone copy "b2:${B2_BUCKET}/wotr/saves/" "$WOTR_SAVES/" --update 2>/dev/null \
        && log "B2 saves pulled → $WOTR_SAVES" \
        || warn "B2 saves pull empty or failed"
    rclone copy "b2:${B2_BUCKET}/wotr/saves/" "$WOTR_SAVES_PROTON/" --update 2>/dev/null || true

    cat > /usr/local/bin/wotr-b2-sync.sh << SYNCEOF
#!/usr/bin/env bash
rclone sync "${WOTR_SAVES}/" "b2:${B2_BUCKET}/wotr/saves/" \
    --log-file="${LOG_DIR}/b2.log" --log-level INFO 2>/dev/null || true
SYNCEOF
    chmod +x /usr/local/bin/wotr-b2-sync.sh

    (crontab -l 2>/dev/null | grep -v wotr-b2-sync; echo "*/5 * * * * /usr/local/bin/wotr-b2-sync.sh") | crontab - 2>/dev/null || true
    log "B2 configured — syncing WotR saves every 5 min"
else
    warn "B2 skipped — set B2_KEY_ID + B2_APP_KEY env vars on the pod to enable"
fi

###############################################################################
hdr "9 — PULSEAUDIO"
###############################################################################
pulseaudio --kill 2>/dev/null || true
sleep 1
pulseaudio --daemonize --exit-idle-time=-1 2>/dev/null || true
sleep 1
pactl load-module module-null-sink sink_name=virtual_out 2>/dev/null || true
pactl set-default-sink virtual_out 2>/dev/null || true
log "PulseAudio virtual sink ready"

###############################################################################
hdr "10 — SUPERVISOR"
###############################################################################
mkdir -p /run/user/0; chmod 700 /run/user/0

XVFB_BIN=$(command -v Xvfb 2>/dev/null || find /usr/bin -name Xvfb 2>/dev/null | head -1 || true)
[ -z "$XVFB_BIN" ] && { err "Xvfb not found"; exit 1; }

rm -f /etc/supervisor/conf.d/*.conf 2>/dev/null || true
mkdir -p /etc/supervisor/conf.d

cat > /etc/supervisor/supervisord.conf << SUPCONF
[supervisord]
nodaemon=false
user=root
logfile=${LOG_DIR}/supervisord.log
logfile_maxbytes=20MB
loglevel=info
pidfile=/tmp/supervisord.pid

[unix_http_server]
file=/tmp/supervisor.sock

[rpcinterface:supervisor]
supervisor.rpcinterface_factory=supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///tmp/supervisor.sock

[include]
files = /etc/supervisor/conf.d/*.conf
SUPCONF

cat > /etc/supervisor/conf.d/pulseaudio.conf << 'EOF'
[program:pulseaudio]
command=/usr/bin/pulseaudio --system --disallow-exit --exit-idle-time=-1 --log-target=stderr
autorestart=true
startretries=99
startsecs=2
priority=5
stdout_logfile=/workspace/gaming-logs/pulse.log
stderr_logfile=/workspace/gaming-logs/pulse.log
environment=HOME="/root"
EOF

cat > /etc/supervisor/conf.d/xvfb.conf << XVEOF
[program:xvfb]
command=${XVFB_BIN} :${DISPLAY_NUM} -screen 0 ${RES_W}x${RES_H}x24 -ac +extension GLX +extension RANDR -noreset
autorestart=true
startretries=10
startsecs=3
priority=10
stdout_logfile=${LOG_DIR}/xvfb.log
stderr_logfile=${LOG_DIR}/xvfb.log
environment=HOME="/root"
XVEOF

cat > /etc/supervisor/conf.d/openbox.conf << OBSEOF
[program:openbox]
command=/usr/bin/openbox-session
autorestart=true
startretries=5
startsecs=3
priority=15
stdout_logfile=${LOG_DIR}/openbox.log
stderr_logfile=${LOG_DIR}/openbox.log
environment=DISPLAY=":${DISPLAY_NUM}",HOME="/root"
OBSEOF

cat > /etc/supervisor/conf.d/sunshine.conf << SSEOF
[program:sunshine]
command=${SUN_BIN} /root/.config/sunshine/sunshine.conf
autorestart=true
startretries=10
startsecs=8
priority=20
stdout_logfile=${LOG_DIR}/sunshine.log
stderr_logfile=${LOG_DIR}/sunshine.log
environment=DISPLAY=":${DISPLAY_NUM}",HOME="/root",XDG_RUNTIME_DIR="/run/user/0",LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu:/usr/local/nvidia/lib64"
SSEOF

###############################################################################
hdr "11 — LAUNCH"
###############################################################################
nohup "$SUPD" -c /etc/supervisor/supervisord.conf >> "${LOG_DIR}/supervisord-boot.log" 2>&1 &
disown
log "supervisord launched — waiting 20s..."
sleep 20

supervisorctl -c /etc/supervisor/supervisord.conf status 2>/dev/null | sed 's/^/  /' || warn "supervisorctl not responding yet"

###############################################################################
hdr "12 — VERIFY"
###############################################################################
PASS=0; FAIL=0
chk() {
    if [ "$1" = ok ]; then
        printf "  [OK] %s\n" "$2"; PASS=$((PASS+1))
    else
        printf "  [!!] %s\n" "$2"; FAIL=$((FAIL+1))
    fi
}

pgrep -x sshd &>/dev/null                         && chk ok "SSHD"                  || chk fail "SSHD"
xdpyinfo -display ":${DISPLAY_NUM}" &>/dev/null   && chk ok "Xvfb :${DISPLAY_NUM}"  || chk fail "Xvfb — check ${LOG_DIR}/xvfb.log"
ldconfig -p 2>/dev/null | grep -q libnvidia-encode && chk ok "NVENC in ldconfig"     || chk fail "NVENC not in ldconfig"
[ -f "$(find /usr/lib -name 'libayatana-appindicator3.so.1' 2>/dev/null | head -1)" ] \
    && chk ok "libayatana-appindicator3.so.1" || chk fail "libayatana-appindicator3.so.1 MISSING"
[ -f "$(find /usr/lib -name 'libva.so.2' 2>/dev/null | head -1)" ] \
    && chk ok "libva.so.2"                    || chk fail "libva.so.2 MISSING"
pgrep -f sunshine &>/dev/null                      && chk ok "Sunshine running"      || chk fail "Sunshine — check ${LOG_DIR}/sunshine.log"

echo "  GPU: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1)"
echo "  Result: ${PASS} passed / ${FAIL} failed"

###############################################################################
hdr "13 — GENERATE connect.bat"
###############################################################################
PUBIP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || curl -s --max-time 5 api.ipify.org 2>/dev/null || echo "UNKNOWN")
SSH_PORT="${RUNPOD_TCP_PORT_22:-22}"

log "Public IP: ${PUBIP}  SSH port: ${SSH_PORT}"

cat > /workspace/connect.bat << ENDBAT
@echo off
title RunPod Gaming — Connecting...
echo.
echo   ========================================
echo    RunPod Gaming Rig — One-Click Connect
echo   ========================================
echo.

taskkill /F /IM ssh.exe >nul 2>&1

echo   [1/3] Opening tunnel to ${PUBIP}:${SSH_PORT}...
start /B ssh -N ^
  -L 47984:localhost:47984 ^
  -L 47989:localhost:47989 ^
  -L 47990:localhost:47990 ^
  -L 47998:localhost:47998 ^
  -L 47999:localhost:47999 ^
  -L 48000:localhost:48000 ^
  -L 48010:localhost:48010 ^
  root@${PUBIP} -p ${SSH_PORT} ^
  -o StrictHostKeyChecking=no ^
  -o UserKnownHostsFile=NUL

echo   [2/3] Waiting for tunnel...
timeout /t 4 /nobreak >nul

echo   [3/3] Launching Moonlight...
start "" "C:\Program Files\Moonlight Game Streaming\Moonlight.exe"

echo.
echo   ==========================================
echo    Tunnel OPEN. Moonlight launching.
echo.
echo    FIRST TIME ONLY:
echo      1. Moonlight shows a 4-digit PIN
echo      2. Enter it at https://127.0.0.1:47990
echo         Login: ${SUNSHINE_USER} / ${SUNSHINE_PASS}
echo      3. After pairing it just works forever
echo   ==========================================
echo.

timeout /t 3 /nobreak >nul
start https://127.0.0.1:47990

echo   Press any key to DISCONNECT.
pause >nul
taskkill /F /IM ssh.exe >nul 2>&1
ENDBAT

chmod 644 /workspace/connect.bat
log "connect.bat written → /workspace/connect.bat"

###############################################################################
echo ""
echo "==========================================="
echo " RunPod Gaming Rig v14 (WotR) — ${SECONDS}s"
echo "==========================================="
echo ""
echo " scp -P ${SSH_PORT} root@${PUBIP}:/workspace/connect.bat ."
echo "==========================================="

if [ -n "${JUPYTER_TOKEN:-}" ] || [ -n "${JUPYTER_RUNTIME_DIR:-}" ] || [ -n "${JPY_PARENT_PID:-}" ]; then
    log "Jupyter detected — staying open"
    exec sleep infinity
fi
