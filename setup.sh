#!/usr/bin/env bash
###############################################################################
#  RunPod Gaming Rig v8
#  NVIDIA L4 | Ubuntu 22.04 | Sunshine → Moonlight | 4K@144Hz
#
#  v8 fixes:
#    - Sunshine deb extracted to STAGING DIR, not / (was clobbering /bin/sh)
#    - nvidia_drv.so extracted to staging, copied selectively (EXDEV fix)
#    - /dev/dri: mknod failure tolerated; warns if nodes still missing
#    - SSH restart hardened
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
RUNPOD_HOST="66.92.198.162"
RUNPOD_SSH_PORT="11193"
B2_BUCKET="Funfun"
B2_ENDPOINT="${B2_ENDPOINT:-s3.us-east-005.backblazeb2.com}"
B2_KEY_ID="${B2_KEY_ID:-}"
B2_APP_KEY="${B2_APP_KEY:-}"
FERAL_SAVES="/root/.local/share/feral-interactive/Total War THREE KINGDOMS/User Data/Save Games"
FERAL_PACKS="/root/.local/share/feral-interactive/Total War THREE KINGDOMS/User Data/packs"
PROTON_BASE="/root/.steam/steam/steamapps/compatdata/779340/pfx/drive_c/users/steamuser/Documents/My Games/Total War THREE KINGDOMS"

# ── helpers ───────────────────────────────────────────────────
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[1;34m'; N='\033[0m'
log()  { printf "${G}[OK %s]${N} %s\n" "$(date +%H:%M:%S)" "$*"; }
warn() { printf "${Y}[WW %s]${N} %s\n" "$(date +%H:%M:%S)" "$*"; }
err()  { printf "${R}[EE %s]${N} %s\n" "$(date +%H:%M:%S)" "$*"; }
hdr()  { printf "\n${B}=== %s ===${N}\n" "$*"; }

# ── EXDEV-safe apt install ─────────────────────────────────────
# Extracts all debs to / via dpkg-deb -x (tar, no rename()).
# SAFE for system packages — do NOT use for bundled-binary debs like Sunshine.
safe_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" 2>/dev/null && return 0
    warn "EXDEV fallback: $*"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -d --no-install-recommends "$@" 2>/dev/null || true
    local n=0
    for deb in /var/cache/apt/archives/*.deb; do
        [ -f "$deb" ] || continue
        dpkg-deb -x "$deb" / 2>/dev/null && ((n++)) || true
    done
    ldconfig 2>/dev/null || true
    log "Extracted ${n} system debs"
}

# ── Staged deb install ─────────────────────────────────────────
# For debs that bundle non-standard files (Sunshine, nvidia DDX):
# extract to a temp dir, then selectively copy only known safe paths.
staged_deb_install() {
    local deb="$1"; shift          # deb file
    local paths=("$@")             # list of paths to copy from stage to /
    local stage
    stage=$(mktemp -d /tmp/deb-stage-XXXXXX)
    dpkg-deb -x "$deb" "$stage" 2>/dev/null || { rm -rf "$stage"; return 1; }
    for p in "${paths[@]}"; do
        local src="${stage}${p}"
        local dst_dir
        dst_dir=$(dirname "$p")
        [ -e "$src" ] || continue
        mkdir -p "$dst_dir"
        cp -a "$src" "$p" 2>/dev/null || true
    done
    rm -rf "$stage"
    ldconfig 2>/dev/null || true
}

###############################################################################
hdr "0 — BOOTSTRAP"
###############################################################################
apt-get install -y curl wget 2>/dev/null || true
log "curl/wget present"

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
log "SSH: PasswordAuthentication yes, PermitRootLogin yes"

###############################################################################
hdr "2 — PACKAGES"
###############################################################################
export DEBIAN_FRONTEND=noninteractive
add-apt-repository -y universe 2>/dev/null || true
apt-get update -qq 2>/dev/null || warn "apt update failed"

safe_install xserver-xorg-core x11-xserver-utils x11-utils xinit xterm openbox dbus-x11 xdotool xauth xkb-data
safe_install pulseaudio pulseaudio-utils alsa-utils
safe_install rsync jq mesa-utils

# supervisord
pip3 install --quiet supervisor 2>/dev/null || true
SUPD=$(command -v supervisord 2>/dev/null \
    || find /usr/local/bin /root/.local/bin /usr/bin -name supervisord 2>/dev/null | head -1 || true)
[ -z "$SUPD" ] && { safe_install supervisor; SUPD=$(command -v supervisord 2>/dev/null || true); }
[ -z "$SUPD" ] && { err "supervisord not found"; exit 1; }
SUPC=$(command -v supervisorctl 2>/dev/null \
    || find /usr/local/bin /root/.local/bin /usr/bin -name supervisorctl 2>/dev/null | head -1 || true)
[ -n "$SUPC" ] && ln -sf "$SUPC" /usr/local/bin/supervisorctl 2>/dev/null || true
log "supervisord: $SUPD"
mkdir -p /etc/supervisor/conf.d

###############################################################################
hdr "3 — GPU"
###############################################################################
# mknod requires --privileged; RunPod L4 may deny it. Tolerate the failure.
mkdir -p /dev/dri
mknod -m 666 /dev/dri/card0      c 226 0   2>/dev/null || true
mknod -m 666 /dev/dri/renderD128 c 226 128 2>/dev/null || true
ls -la /dev/dri/ 2>/dev/null || true

GPU_NAME=$(nvidia-smi --query-gpu=name           --format=csv,noheader 2>/dev/null | head -1 || echo "UNKNOWN")
DRV_FULL=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "570.0")
DRV_MAJ=$(echo "$DRV_FULL" | cut -d. -f1)
BUS_RAW=$(nvidia-smi --query-gpu=pci.bus_id      --format=csv,noheader 2>/dev/null | head -1 || echo "0000:00:24.0")
BUS_BDF=$(echo "$BUS_RAW" | sed 's/^[0-9A-Fa-f]*://')
B_HEX=$(echo "$BUS_BDF" | cut -d: -f1)
D_HEX=$(echo "$BUS_BDF" | cut -d: -f2 | cut -d. -f1)
F_DEC=$(echo "$BUS_BDF" | cut -d. -f2)
GPU_BUSID="PCI:$((16#${B_HEX})):$((16#${D_HEX})):${F_DEC}"
log "GPU=$GPU_NAME drv=$DRV_MAJ BusID=$GPU_BUSID"

# nvidia DDX — STAGED extraction to avoid EXDEV clobbering system paths
NV_DDX_STAGE=$(mktemp -d /tmp/nv-ddx-XXXXXX)
( cd "$NV_DDX_STAGE" && apt-get download "xserver-xorg-video-nvidia-${DRV_MAJ}" 2>/dev/null ) || true
NV_DEB=$(ls "$NV_DDX_STAGE"/*.deb 2>/dev/null | head -1 || true)
if [ -n "$NV_DEB" ]; then
    NV_EXTRACT=$(mktemp -d /tmp/nv-extract-XXXXXX)
    dpkg-deb -x "$NV_DEB" "$NV_EXTRACT" 2>/dev/null || true
    NVDRV_SO=$(find "$NV_EXTRACT" -name "nvidia_drv.so" 2>/dev/null | head -1 || true)
    if [ -n "$NVDRV_SO" ]; then
        mkdir -p /usr/lib/xorg/modules/drivers
        cp -f "$NVDRV_SO" /usr/lib/xorg/modules/drivers/nvidia_drv.so
        log "nvidia_drv.so installed via staged extraction"
    fi
    rm -rf "$NV_EXTRACT"
fi
rm -rf "$NV_DDX_STAGE"

###############################################################################
hdr "4 — NVENC"
###############################################################################
LINK_DIR="/usr/lib/x86_64-linux-gnu"
NVENC_REAL=""
for sd in "$LINK_DIR" /usr/local/nvidia/lib64 /usr/lib64 /usr/local/lib; do
    c=$(find "$sd" -maxdepth 1 -name "libnvidia-encode.so.*" \
        ! -name "libnvidia-encode.so.1" 2>/dev/null | sort -V | tail -1 || true)
    [ -n "$c" ] && { NVENC_REAL="$c"; break; }
done
if [ -n "$NVENC_REAL" ]; then
    ln -sf "$NVENC_REAL"                        "${LINK_DIR}/libnvidia-encode.so.1" 2>/dev/null \
        || cp -f "$NVENC_REAL"                  "${LINK_DIR}/libnvidia-encode.so.1"
    ln -sf "${LINK_DIR}/libnvidia-encode.so.1"  "${LINK_DIR}/libnvidia-encode.so"
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
hdr "5 — XORG"
###############################################################################
XORG_BIN=$(command -v Xorg 2>/dev/null || find /usr/lib/xorg /usr/bin -name Xorg -type f 2>/dev/null | head -1 || true)
[ -z "$XORG_BIN" ] && { err "Xorg binary not found"; exit 1; }
log "Xorg: $XORG_BIN"

mkdir -p /etc/X11
cat > /etc/X11/xorg.conf << XORGEOF
Section "ServerLayout"
    Identifier     "Layout0"
    Screen      0  "Screen0"
    Option         "BlankTime"   "0"
    Option         "StandbyTime" "0"
    Option         "SuspendTime" "0"
    Option         "OffTime"     "0"
EndSection

Section "Monitor"
    Identifier     "Monitor0"
    HorizSync       30-700
    VertRefresh     50-${RES_HZ}
    Modeline       "${RES_W}x${RES_H}_${RES_HZ}" 1829.25 ${RES_W} 3888 3920 4000 ${RES_H} 2163 2168 2235 +hsync -vsync
    Option         "DPMS" "false"
EndSection

Section "Device"
    Identifier     "Device0"
    Driver         "nvidia"
    BusID          "${GPU_BUSID}"
    Option         "AllowEmptyInitialConfiguration" "True"
    Option         "ConnectedMonitor"  "DP-0"
    Option         "UseDisplayDevice"  "DP-0"
    Option         "UseEDID"           "False"
    Option         "HardDPMS"          "False"
    Option         "ModeValidation"    "NoMaxPClkCheck,NoEdidMaxPClkCheck,NoMaxSizeCheck,NoHorizSyncCheck,NoVertRefreshCheck,NoVirtualSizeCheck,NoExtendedGpuCapabilitiesCheck,NoTotalSizeCheck,NoDualLinkDVICheck,NoDisplayPortBandwidthCheck,AllowNon3DVisionModes"
EndSection

Section "Screen"
    Identifier     "Screen0"
    Device         "Device0"
    Monitor        "Monitor0"
    DefaultDepth    24
    Option         "MetaModes"    "DP-0: ${RES_W}x${RES_H}_${RES_HZ} +0+0"
    Option         "TripleBuffer" "on"
    SubSection     "Display"
        Depth       24
        Modes      "${RES_W}x${RES_H}_${RES_HZ}" "${RES_W}x${RES_H}" "2560x1440" "1920x1080"
    EndSubSection
EndSection
XORGEOF
log "xorg.conf written ($GPU_BUSID)"

###############################################################################
hdr "6 — SUNSHINE (staged extraction — does NOT touch /bin or /usr/bin)"
###############################################################################
if ! command -v sunshine &>/dev/null; then
    log "Downloading Sunshine..."
    # Pin to v0.23.1 — newer releases bundle system binaries that clobber /bin/sh
    SUN_URL="https://github.com/LizardByte/Sunshine/releases/download/v0.23.1/sunshine-ubuntu-22.04-amd64.deb"
    curl -fsSL "$SUN_URL" -o /tmp/sunshine.deb || { err "Sunshine download failed"; exit 1; }

    # Try normal dpkg first (works if dpkg temp and /usr/bin are on same fs)
    if dpkg -i /tmp/sunshine.deb 2>/dev/null; then
        log "Sunshine installed via dpkg"
    else
        warn "dpkg EXDEV — using staged extraction"
        # Extract to staging dir, then copy ONLY sunshine-specific paths
        SUN_STAGE=$(mktemp -d /tmp/sun-stage-XXXXXX)
        dpkg-deb -x /tmp/sunshine.deb "$SUN_STAGE"
        # Copy binary
        [ -f "${SUN_STAGE}/usr/bin/sunshine" ]    && cp -f "${SUN_STAGE}/usr/bin/sunshine"    /usr/bin/sunshine
        # Copy libs if present
        [ -d "${SUN_STAGE}/usr/lib/sunshine" ]    && { mkdir -p /usr/lib/sunshine; cp -a "${SUN_STAGE}/usr/lib/sunshine/." /usr/lib/sunshine/; }
        [ -d "${SUN_STAGE}/usr/share/sunshine" ]  && { mkdir -p /usr/share/sunshine; cp -a "${SUN_STAGE}/usr/share/sunshine/." /usr/share/sunshine/; }
        [ -d "${SUN_STAGE}/etc/sunshine" ]        && { mkdir -p /etc/sunshine; cp -a "${SUN_STAGE}/etc/sunshine/." /etc/sunshine/; }
        rm -rf "$SUN_STAGE"
        ldconfig 2>/dev/null || true
        log "Sunshine installed via staged extraction"
    fi
    rm -f /tmp/sunshine.deb
fi

SUN_BIN=$(command -v sunshine 2>/dev/null \
    || find /usr/bin /usr/local/bin -name sunshine -type f 2>/dev/null | head -1 || true)
[ -z "$SUN_BIN" ] && { err "sunshine binary not found after install"; exit 1; }
chmod +x "$SUN_BIN" 2>/dev/null || true
log "Sunshine: $SUN_BIN"

mkdir -p /root/.config/sunshine
cat > /root/.config/sunshine/sunshine.conf << 'SUNEOF'
bind_address          = 127.0.0.1
port                  = 47989
upnp                  = off
origin_web_ui_allowed = pc
address_family        = ipv4
capture               = x11
encoder               = nvenc
adapter_name          = /dev/dri/renderD128
output_name           = 0
resolutions           = [3840x2160, 2560x1440, 1920x1080]
fps                   = [144, 60, 30]
nv_preset             = p4
nv_tune               = ll
nv_rc                 = cbr
min_log_level         = info
SUNEOF

"$SUN_BIN" --creds admin gondolin123 2>/dev/null || warn "sunshine --creds failed — set via web UI"
log "Sunshine configured"

###############################################################################
hdr "7 — GAME ASSETS"
###############################################################################
mkdir -p "$FERAL_SAVES" "$FERAL_PACKS" "${PROTON_BASE}/save_games" "${PROTON_BASE}/pack"
SC=0; PC=0
while IFS= read -r -d '' f; do
    cp "$f" "$FERAL_SAVES/"              2>/dev/null || true
    cp "$f" "${PROTON_BASE}/save_games/" 2>/dev/null || true
    ((SC++)) || true
done < <(find /workspace -maxdepth 4 -name "*.save" -print0 2>/dev/null)
while IFS= read -r -d '' f; do
    cp "$f" "$FERAL_PACKS/"        2>/dev/null || true
    cp "$f" "${PROTON_BASE}/pack/" 2>/dev/null || true
    ((PC++)) || true
done < <(find /workspace -maxdepth 4 -name "*.pack" -print0 2>/dev/null)
log "Assets: $SC .save  $PC .pack"

###############################################################################
hdr "8 — B2 SYNC"
###############################################################################
if [ -n "$B2_KEY_ID" ] && [ -n "$B2_APP_KEY" ]; then
    command -v rclone &>/dev/null || curl -fsSL https://rclone.org/install.sh | bash 2>/dev/null || true
    mkdir -p /root/.config/rclone
    cat > /root/.config/rclone/rclone.conf << RCONF
[b2funfun]
type = s3
provider = Other
access_key_id = ${B2_KEY_ID}
secret_access_key = ${B2_APP_KEY}
endpoint = ${B2_ENDPOINT}
acl = private
no_check_bucket = true
RCONF
    rclone copy "b2funfun:${B2_BUCKET}/saves/" "$FERAL_SAVES/" 2>/dev/null || warn "B2 saves pull empty"
    rclone copy "b2funfun:${B2_BUCKET}/packs/" "$FERAL_PACKS/" 2>/dev/null || true
    cat > /usr/local/bin/b2-sync.sh << SYNCEOF
#!/usr/bin/env bash
rclone sync "${FERAL_SAVES}/" "b2funfun:${B2_BUCKET}/saves/" --log-file="${LOG_DIR}/b2.log"
rclone sync "${FERAL_PACKS}/" "b2funfun:${B2_BUCKET}/packs/" --log-file="${LOG_DIR}/b2.log"
SYNCEOF
    chmod +x /usr/local/bin/b2-sync.sh
    (crontab -l 2>/dev/null; echo "*/15 * * * * /usr/local/bin/b2-sync.sh") | sort -u | crontab - 2>/dev/null || true
    log "B2 configured"
else
    warn "B2 skipped — set B2_KEY_ID + B2_APP_KEY env vars to enable"
fi

###############################################################################
hdr "9 — PULSEAUDIO"
###############################################################################
pulseaudio --daemonize --exit-idle-time=-1 2>/dev/null || true
sleep 1
pactl load-module module-null-sink sink_name=virtual_out 2>/dev/null || true
pactl set-default-sink virtual_out 2>/dev/null || true
log "PulseAudio virtual sink ready"

###############################################################################
hdr "10 — SUPERVISOR"
###############################################################################
pkill -x supervisord 2>/dev/null || true; sleep 1
pkill -x Xorg        2>/dev/null || true
pkill -f sunshine    2>/dev/null || true

mkdir -p /run/user/0; chmod 700 /run/user/0

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

cat > /etc/supervisor/conf.d/xorg.conf << XSEOF
[program:xorg]
command=${XORG_BIN} :${DISPLAY_NUM} -noreset +extension GLX +extension RANDR -config /etc/X11/xorg.conf -logfile ${LOG_DIR}/Xorg.${DISPLAY_NUM}.log
autorestart=true
startretries=10
startsecs=3
priority=10
stdout_logfile=${LOG_DIR}/xorg.log
stderr_logfile=${LOG_DIR}/xorg.log
environment=HOME="/root"
XSEOF

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
chk() { [ "$1" = ok ] && { printf "  [OK] %s\n" "$2"; ((PASS++)); } || { printf "  [!!] %s\n" "$2"; ((FAIL++)); }; }

pgrep -x sshd    &>/dev/null && chk ok "SSHD"        || chk fail "SSHD"
xdpyinfo -display ":${DISPLAY_NUM}" &>/dev/null      && chk ok  "Xorg :${DISPLAY_NUM}" || chk fail "Xorg :${DISPLAY_NUM} — check ${LOG_DIR}/Xorg.${DISPLAY_NUM}.log"
ldconfig -p 2>/dev/null | grep -q libnvidia-encode   && chk ok  "NVENC in ldconfig"    || chk fail "NVENC not in ldconfig"
[ -c /dev/dri/renderD128 ]                           && chk ok  "/dev/dri/renderD128"  || chk fail "/dev/dri/renderD128 missing (mknod denied — check RunPod container perms)"
pgrep -f sunshine &>/dev/null                        && chk ok  "Sunshine"             || chk fail "Sunshine — check ${LOG_DIR}/sunshine.log"
echo "  GPU: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1)"
echo ""
echo "  Result: ${PASS} passed / ${FAIL} failed"

###############################################################################
echo ""
echo "==========================================="
echo " RunPod Gaming Rig v8 — ${SECONDS}s"
echo "==========================================="
echo " SSH:  ssh root@${RUNPOD_HOST} -p ${RUNPOD_SSH_PORT}"
echo " Pass: ${ROOT_PASS}"
echo ""
echo " PowerShell tunnel:"
echo "   ssh -N \\"
echo "     -L 47984:localhost:47984 \\"
echo "     -L 47989:localhost:47989 \\"
echo "     -L 47990:localhost:47990 \\"
echo "     -L 48010:localhost:48010 \\"
echo "     root@${RUNPOD_HOST} -p ${RUNPOD_SSH_PORT} -o StrictHostKeyChecking=no"
echo ""
echo " Moonlight → Add PC → 127.0.0.1"
echo " Web UI    → https://127.0.0.1:47990  (admin / gondolin123)"
echo ""
echo " supervisorctl -c /etc/supervisor/supervisord.conf status"
echo " tail -f ${LOG_DIR}/sunshine.log"
echo " tail -f ${LOG_DIR}/Xorg.${DISPLAY_NUM}.log"
echo "==========================================="

if [ -n "${JUPYTER_TOKEN:-}" ] || [ -n "${JUPYTER_RUNTIME_DIR:-}" ] || [ -n "${JPY_PARENT_PID:-}" ]; then
    log "Jupyter detected — terminal staying open (services daemonized)"
    exec sleep infinity
fi
