#!/usr/bin/env bash
###############################################################################
#  RunPod Gaming Rig v10
#  NVIDIA L4 | Ubuntu 22.04 | Sunshine → Moonlight | 4K@144Hz
#
#  v10 fixes over v9:
#    - Xvfb replaces Xorg/modesetting (no DRI access needed in unprivileged container)
#    - Broken sunshine dpkg record purged before apt installs (was poisoning all apt)
#    - libayatana + deps installed cleanly after dpkg repair
#    - Sunshine binary extracted manually (no dpkg -i, avoids re-poisoning)
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
log "SSH ready"

###############################################################################
hdr "2 — PURGE BROKEN DPKG STATE"
###############################################################################
# sunshine dpkg -i in prior runs left a half-installed record that blocks ALL apt
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
apt-get update -qq 2>/dev/null || warn "apt update failed"

# Core X + tools — use Xvfb (virtual framebuffer, no DRI needed)
apt-get install -y --no-install-recommends \
    xvfb x11-xserver-utils x11-utils xterm openbox dbus-x11 \
    xdotool xauth xkb-data 2>/dev/null || warn "some X pkgs failed"

apt-get install -y --no-install-recommends \
    pulseaudio pulseaudio-utils alsa-utils 2>/dev/null || warn "pulse pkgs failed"

apt-get install -y --no-install-recommends \
    rsync jq mesa-utils 2>/dev/null || warn "util pkgs failed"

# Sunshine runtime deps — install individually so one failure doesn't block rest
for pkg in \
    libayatana-appindicator3-1 \
    libnotify4 \
    libminiupnpc17 \
    libevdev2 \
    libnuma1 \
    libboost-locale1.74.0 \
    libboost-thread1.74.0 \
    libboost-filesystem1.74.0 \
    libboost-log1.74.0 \
    libboost-program-options1.74.0; do
    apt-get install -y --no-install-recommends "$pkg" 2>/dev/null \
        || warn "optional dep $pkg not available — skipping"
done
ldconfig 2>/dev/null || true
log "packages done"

# supervisord via pip (more reliable than apt in this image)
pip3 install --quiet supervisor 2>/dev/null || true
SUPD=$(command -v supervisord 2>/dev/null \
    || find /usr/local/bin /root/.local/bin /usr/bin -name supervisord 2>/dev/null | head -1 || true)
[ -z "$SUPD" ] && { apt-get install -y supervisor 2>/dev/null || true; SUPD=$(command -v supervisord 2>/dev/null || true); }
[ -z "$SUPD" ] && { err "supervisord not found"; exit 1; }
SUPC=$(command -v supervisorctl 2>/dev/null \
    || find /usr/local/bin /root/.local/bin /usr/bin -name supervisorctl 2>/dev/null | head -1 || true)
[ -n "$SUPC" ] && ln -sf "$SUPC" /usr/local/bin/supervisorctl 2>/dev/null || true
log "supervisord: $SUPD"
mkdir -p /etc/supervisor/conf.d

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
hdr "5 — SUNSHINE (binary extraction only — no dpkg -i)"
###############################################################################
# Never run dpkg -i sunshine.deb again — it has unresolvable deps (libmfx1/Intel)
# and will re-poison apt. Extract binary + libs only.
SUN_BIN=$(command -v sunshine 2>/dev/null \
    || find /usr/bin /usr/local/bin -name sunshine -type f 2>/dev/null | head -1 || true)

if [ -z "$SUN_BIN" ]; then
    log "Downloading Sunshine deb for binary extraction..."
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

# Verify the libayatana dep is actually satisfied now
if ! ldd "$SUN_BIN" 2>/dev/null | grep -q "libayatana"; then
    AYATANA_SO=$(ldconfig -p 2>/dev/null | grep libayatana-appindicator3 | awk '{print $NF}' | head -1 || true)
    [ -n "$AYATANA_SO" ] && log "libayatana found: $AYATANA_SO" || warn "libayatana NOT in ldconfig — sunshine will crash"
fi

mkdir -p /root/.config/sunshine
cat > /root/.config/sunshine/sunshine.conf << SUNEOF
bind_address          = 127.0.0.1
port                  = 47989
upnp                  = off
origin_web_ui_allowed = pc
address_family        = ipv4
capture               = x11
encoder               = nvenc
adapter_name          = ${DRI_RENDER}
output_name           = 0
resolutions           = [3840x2160, 2560x1440, 1920x1080]
fps                   = [144, 60, 30]
nv_preset             = p4
nv_tune               = ll
nv_rc                 = cbr
min_log_level         = info
SUNEOF

"$SUN_BIN" --creds admin gondolin123 2>/dev/null || warn "sunshine --creds failed — set via web UI"
log "Sunshine configured (adapter_name=${DRI_RENDER})"

###############################################################################
hdr "6 — GAME ASSETS"
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
hdr "7 — B2 SYNC"
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
rclone sync "${FERAL_PACKS}/" "b2funfun:${B2_BUCKET}/packs/'" --log-file="${LOG_DIR}/b2.log"
SYNCEOF
    chmod +x /usr/local/bin/b2-sync.sh
    (crontab -l 2>/dev/null; echo "*/15 * * * * /usr/local/bin/b2-sync.sh") | sort -u | crontab - 2>/dev/null || true
    log "B2 configured"
else
    warn "B2 skipped — set B2_KEY_ID + B2_APP_KEY env vars to enable"
fi

###############################################################################
hdr "8 — PULSEAUDIO"
###############################################################################
pulseaudio --daemonize --exit-idle-time=-1 2>/dev/null || true
sleep 1
pactl load-module module-null-sink sink_name=virtual_out 2>/dev/null || true
pactl set-default-sink virtual_out 2>/dev/null || true
log "PulseAudio virtual sink ready"

###############################################################################
hdr "9 — SUPERVISOR"
###############################################################################
pkill -x supervisord 2>/dev/null || true; sleep 1
pkill -f Xvfb        2>/dev/null || true
pkill -f sunshine    2>/dev/null || true

mkdir -p /run/user/0; chmod 700 /run/user/0

XVFB_BIN=$(command -v Xvfb 2>/dev/null || find /usr/bin -name Xvfb 2>/dev/null | head -1 || true)
[ -z "$XVFB_BIN" ] && { err "Xvfb not found"; exit 1; }
log "Xvfb: $XVFB_BIN"

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

# Xvfb: virtual framebuffer — no DRI, no KMS, no permission issues
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
hdr "10 — LAUNCH"
###############################################################################
nohup "$SUPD" -c /etc/supervisor/supervisord.conf >> "${LOG_DIR}/supervisord-boot.log" 2>&1 &
disown
log "supervisord launched — waiting 20s..."
sleep 20

supervisorctl -c /etc/supervisor/supervisord.conf status 2>/dev/null | sed 's/^/  /' || warn "supervisorctl not responding yet"

###############################################################################
hdr "11 — VERIFY"
###############################################################################
PASS=0; FAIL=0
chk() { [ "$1" = ok ] && { printf "  [OK] %s\n" "$2"; ((PASS++)); } || { printf "  [!!] %s\n" "$2"; ((FAIL++)); }; }

pgrep -x sshd    &>/dev/null && chk ok "SSHD"        || chk fail "SSHD"
xdpyinfo -display ":${DISPLAY_NUM}" &>/dev/null      && chk ok  "Xvfb :${DISPLAY_NUM}"  || chk fail "Xvfb :${DISPLAY_NUM} — check ${LOG_DIR}/xvfb.log"
ldconfig -p 2>/dev/null | grep -q libnvidia-encode   && chk ok  "NVENC in ldconfig"     || chk fail "NVENC not in ldconfig"
ldconfig -p 2>/dev/null | grep -q libayatana          && chk ok  "libayatana present"    || chk fail "libayatana MISSING — sunshine will crash"
pgrep -f sunshine &>/dev/null                        && chk ok  "Sunshine running"      || chk fail "Sunshine — check ${LOG_DIR}/sunshine.log"
echo "  GPU: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1)"
echo ""
echo "  Result: ${PASS} passed / ${FAIL} failed"

###############################################################################
echo ""
echo "==========================================="
echo " RunPod Gaming Rig v10 — ${SECONDS}s"
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
echo " tail -f ${LOG_DIR}/xvfb.log"
echo "==========================================="

if [ -n "${JUPYTER_TOKEN:-}" ] || [ -n "${JUPYTER_RUNTIME_DIR:-}" ] || [ -n "${JPY_PARENT_PID:-}" ]; then
    log "Jupyter detected — terminal staying open (services daemonized)"
    exec sleep infinity
fi
