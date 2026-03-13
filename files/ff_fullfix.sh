#!/bin/bash
set -uo pipefail
LOG="/workspace/ff_fullfix.log"
exec > >(tee -a "$LOG") 2>&1

echo "============================================"
echo "  FunFunPod FULL FIX — $(date)"
echo "============================================"

# ── 0. FIX SSH ──────────────────────────────────
echo ""
echo "▸ [0/7] FIXING SSH"
mkdir -p /root/.ssh
chmod 700 /root/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBnM1oFYLebSo0zG6U/+lbO40QcTX1q3TVOb9XKPuONq eru@DESKTOP-DILGDT9" >> /root/.ssh/authorized_keys
sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
if ! pgrep -x sshd >/dev/null; then
    /usr/sbin/sshd 2>/dev/null || service ssh start 2>/dev/null || true
fi
echo "  ✓ SSH key added, authorized_keys fixed"

# ── 1. DIAGNOSTICS ──────────────────────────────
echo ""
echo "▸ [1/7] DIAGNOSTICS"
if ! nvidia-smi &>/dev/null; then
    echo "  ✗ FATAL: nvidia-smi not working. GPU not available."
    exit 1
fi

DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | tr -d '[:space:]')
MAJOR_VER=$(echo "$DRIVER_VER" | cut -d. -f1)
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
echo "  GPU: $GPU_NAME"
echo "  Driver: $DRIVER_VER (major: $MAJOR_VER)"

echo "  Searching for NVIDIA libs..."
NVIDIA_LIB_DIRS=()
while IFS= read -r d; do
    NVIDIA_LIB_DIRS+=("$d")
done < <(find / -maxdepth 5 \( -name "libnvidia-encode.so*" -o -name "libvdpau_nvidia.so*" -o -name "libnvidia-ml.so*" -o -name "libcuda.so*" \) 2>/dev/null | xargs -I{} dirname {} | sort -u)

if [ ${#NVIDIA_LIB_DIRS[@]} -eq 0 ]; then
    echo "  ⚠ No NVIDIA libs found via find. Will install via apt."
else
    echo "  Found NVIDIA libs in:"
    for d in "${NVIDIA_LIB_DIRS[@]}"; do
        echo "    → $d"
        ls "$d"/libnvidia-encode* "$d"/libvdpau_nvidia* 2>/dev/null | sed 's/^/      /'
    done
fi

echo "  /dev/nvidia* devices:"
ls -la /dev/nvidia* /dev/dri/* 2>/dev/null | sed 's/^/    /' || echo "    (none)"

# ── 2. INSTALL PACKAGES ─────────────────────────
echo ""
echo "▸ [2/7] INSTALLING PACKAGES"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq 2>/dev/null

apt-get install -y -qq wget xvfb curl jq rsync libvdpau1 libvdpau-dev vdpauinfo \
    libxrandr2 libxfixes3 libxcursor1 mesa-utils x11-xserver-utils 2>/dev/null \
    && echo "  ✓ Core deps installed" || echo "  ⚠ Some core deps failed"

for pkg in "libnvidia-encode-${MAJOR_VER}" "libnvidia-decode-${MAJOR_VER}" \
           "libnvidia-fbc1-${MAJOR_VER}" "libnvidia-gl-${MAJOR_VER}" \
           "libnvidia-encode-${MAJOR_VER}-server" "libnvidia-decode-${MAJOR_VER}-server"; do
    if apt-get install -y -qq "$pkg" 2>/dev/null; then
        echo "  ✓ $pkg"
    else
        echo "  ⚠ $pkg not in repos (will symlink)"
    fi
done

# ── 3. FIND AND SYMLINK LIBS ────────────────────
echo ""
echo "▸ [3/7] SYMLINKING NVIDIA LIBS"

TARGET_DIR="/usr/lib/x86_64-linux-gnu"
VDPAU_DIR="${TARGET_DIR}/vdpau"
mkdir -p "$VDPAU_DIR"

NVIDIA_LIB_DIRS=()
while IFS= read -r d; do
    NVIDIA_LIB_DIRS+=("$d")
done < <(find / -maxdepth 5 \( -name "libnvidia-encode.so*" -o -name "libvdpau_nvidia.so*" \) 2>/dev/null | xargs -I{} dirname {} | sort -u)

EXTRA_DIRS=("/usr/local/nvidia/lib64" "/usr/local/nvidia/lib" "/usr/local/cuda/lib64"
            "/usr/local/cuda/compat" "/usr/lib64" "/run/nvidia/driver/usr/lib/x86_64-linux-gnu"
            "/run/nvidia/driver/usr/lib64")
for d in "${EXTRA_DIRS[@]}"; do
    [ -d "$d" ] && NVIDIA_LIB_DIRS+=("$d")
done
readarray -t NVIDIA_LIB_DIRS < <(printf '%s\n' "${NVIDIA_LIB_DIRS[@]}" | sort -u)

link_lib() {
    local pattern="$1" link_name="$2" link_dir="$3"
    [ -e "${link_dir}/${link_name}" ] && { echo "  ✓ ${link_dir}/${link_name} exists"; return 0; }
    for d in "${NVIDIA_LIB_DIRS[@]}"; do
        local found=$(find "$d" -maxdepth 1 -name "${pattern}" 2>/dev/null | head -1)
        if [ -n "$found" ] && [ -e "$found" ]; then
            ln -sf "$found" "${link_dir}/${link_name}"
            echo "  ✓ ${link_dir}/${link_name} → $found"
            return 0
        fi
    done
    echo "  ✗ ${pattern} not found"
    return 1
}

FAIL=0

link_lib "libnvidia-encode.so.${DRIVER_VER}" "libnvidia-encode.so.1" "$TARGET_DIR" || \
link_lib "libnvidia-encode.so.*" "libnvidia-encode.so.1" "$TARGET_DIR" || FAIL=1
link_lib "libnvidia-encode.so.1" "libnvidia-encode.so" "$TARGET_DIR" 2>/dev/null || true

link_lib "libvdpau_nvidia.so.${DRIVER_VER}" "libvdpau_nvidia.so.1" "$VDPAU_DIR" || \
link_lib "libvdpau_nvidia.so.*" "libvdpau_nvidia.so.1" "$VDPAU_DIR" || FAIL=1
[ -e "$VDPAU_DIR/libvdpau_nvidia.so.1" ] && ln -sf "$VDPAU_DIR/libvdpau_nvidia.so.1" "$VDPAU_DIR/libvdpau_nvidia.so" 2>/dev/null
[ -e "$VDPAU_DIR/libvdpau_nvidia.so.1" ] && ln -sf "$VDPAU_DIR/libvdpau_nvidia.so.1" "$TARGET_DIR/libvdpau_nvidia.so.1" 2>/dev/null

link_lib "libnvidia-fbc.so.${DRIVER_VER}" "libnvidia-fbc.so.1" "$TARGET_DIR" || \
link_lib "libnvidia-fbc.so.*" "libnvidia-fbc.so.1" "$TARGET_DIR" || echo "  ⚠ libnvidia-fbc missing (may be OK)"
link_lib "libcuda.so.*" "libcuda.so.1" "$TARGET_DIR" || true
link_lib "libnvidia-ml.so.*" "libnvidia-ml.so.1" "$TARGET_DIR" || true

if [ $FAIL -eq 1 ]; then
    echo ""
    echo "  ⚠ Critical libs not found. Trying NVIDIA .run installer extraction..."
    cd /tmp
    RUN_FILE="NVIDIA-Linux-x86_64-${DRIVER_VER}.run"
    if [ ! -f "$RUN_FILE" ]; then
        wget -q "https://us.download.nvidia.com/XFree86/Linux-x86_64/${DRIVER_VER}/${RUN_FILE}" -O "$RUN_FILE" 2>/dev/null || \
        wget -q "https://us.download.nvidia.com/tesla/${DRIVER_VER}/${RUN_FILE}" -O "$RUN_FILE" 2>/dev/null || true
    fi
    if [ -f "$RUN_FILE" ] && [ -s "$RUN_FILE" ]; then
        chmod +x "$RUN_FILE"
        ./"$RUN_FILE" --extract-only 2>/dev/null || true
        EXTRACT_DIR="/tmp/NVIDIA-Linux-x86_64-${DRIVER_VER}"
        if [ -d "$EXTRACT_DIR" ]; then
            for lib in libnvidia-encode.so libvdpau_nvidia.so libnvidia-fbc.so; do
                src=$(find "$EXTRACT_DIR" -name "${lib}.${DRIVER_VER}" 2>/dev/null | head -1)
                if [ -n "$src" ]; then
                    cp "$src" "$TARGET_DIR/"
                    ln -sf "$TARGET_DIR/${lib}.${DRIVER_VER}" "$TARGET_DIR/${lib}.1"
                    ln -sf "$TARGET_DIR/${lib}.${DRIVER_VER}" "$TARGET_DIR/${lib}"
                    echo "  ✓ Extracted ${lib} from .run installer"
                fi
            done
            src=$(find "$EXTRACT_DIR" -name "libvdpau_nvidia.so.${DRIVER_VER}" 2>/dev/null | head -1)
            if [ -n "$src" ]; then
                cp "$src" "$VDPAU_DIR/"
                ln -sf "$VDPAU_DIR/libvdpau_nvidia.so.${DRIVER_VER}" "$VDPAU_DIR/libvdpau_nvidia.so.1"
                ln -sf "$VDPAU_DIR/libvdpau_nvidia.so.1" "$VDPAU_DIR/libvdpau_nvidia.so"
            fi
            FAIL=0
        fi
    else
        echo "  ✗ Could not download NVIDIA .run installer"
    fi
    cd /workspace
fi

# ── 4. LDCONFIG ─────────────────────────────────
echo ""
echo "▸ [4/7] UPDATING LDCONFIG"
cat > /etc/ld.so.conf.d/nvidia-runpod.conf <<EOF
$TARGET_DIR
$VDPAU_DIR
/usr/local/nvidia/lib64
/usr/local/nvidia/lib
/usr/local/cuda/lib64
EOF
for d in "${NVIDIA_LIB_DIRS[@]}"; do echo "$d"; done >> /etc/ld.so.conf.d/nvidia-runpod.conf
sort -u /etc/ld.so.conf.d/nvidia-runpod.conf -o /etc/ld.so.conf.d/nvidia-runpod.conf
ldconfig 2>/dev/null
echo "  ✓ ldconfig refreshed"
echo "  Post-fix check:"
ldconfig -p 2>/dev/null | grep -iE "nvidia-encode|vdpau_nvidia" | sed 's/^/    /'

# ── 5. PARSEC AUTH ──────────────────────────────
echo ""
echo "▸ [5/7] PARSEC AUTH"
[ ! -f /usr/bin/parsecd ] && wget -q https://builds.parsec.app/package/parsec-linux.deb -O /tmp/p.deb \
    && (dpkg -i /tmp/p.deb >/dev/null 2>&1 || apt-get install -f -y -qq >/dev/null 2>&1) || true

mkdir -p /root/.parsec
rm -f /root/.parsec/config.txt /root/.parsec/config.json

# NOTE: Password is base64-encoded and injected by FunFunConnect.ps1
# For manual use, replace __PW64__ with your base64-encoded password
PW=$(printf '%s' '__PW64__' | base64 -d)
JSON=$(jq -n --arg e '__EMAIL__' --arg p "$PW" '{"email":$e,"password":$p,"tfa":""}')
AUTH=$(curl -sf -X POST https://kessel-api.parsec.app/v1/auth -H 'Content-Type: application/json' -d "$JSON" 2>/dev/null)
[ -z "$AUTH" ] && AUTH=$(curl -sf -X POST https://kessel-api.parsecgaming.com/v1/auth -H 'Content-Type: application/json' -d "$JSON" 2>/dev/null)

echo "  Auth response: $AUTH"
SID=$(echo "$AUTH" | jq -r '.session_id // .data.session_id // empty' 2>/dev/null)
if [ -z "$SID" ]; then
    echo "  ✗ FATAL: No session_id. Auth failed."
    exit 1
fi
printf 'session_id = %s\napp_host = 1\n' "$SID" > /root/.parsec/config.txt
echo "  ✓ session_id obtained, config.txt written"

# ── 6. LAUNCH ───────────────────────────────────
echo ""
echo "▸ [6/7] LAUNCHING"

pkill -9 parsecd 2>/dev/null; pkill -9 Xvfb 2>/dev/null; sleep 2

Xvfb :99 -screen 0 1920x1080x24 +extension GLX +render -noreset &
sleep 3
if ! pgrep -x Xvfb >/dev/null; then
    echo "  ✗ FATAL: Xvfb failed"
    exit 1
fi
echo "  ✓ Xvfb on :99"

NEW_LD="$TARGET_DIR:$VDPAU_DIR:/usr/local/nvidia/lib64:/usr/local/cuda/lib64"
for d in "${NVIDIA_LIB_DIRS[@]}"; do NEW_LD="${NEW_LD}:${d}"; done

PARSEC_LOG="/workspace/parsecd_latest.log"
DISPLAY=:99 \
VDPAU_DRIVER=nvidia \
LD_LIBRARY_PATH="${NEW_LD}:${LD_LIBRARY_PATH:-}" \
__GL_SYNC_TO_VBLANK=0 \
parsecd > "$PARSEC_LOG" 2>&1 &
PARSEC_PID=$!
echo "  parsecd PID: $PARSEC_PID"
echo "  Waiting 15 seconds..."
sleep 15

# ── 7. VERIFY ───────────────────────────────────
echo ""
echo "▸ [7/7] VERIFICATION"

if ! kill -0 $PARSEC_PID 2>/dev/null; then
    echo "  ✗ parsecd DIED"
    cat "$PARSEC_LOG" | sed 's/^/    /'
    echo ""
    echo "  ═══ RESULT: FAILED — parsecd crashed ═══"
    exit 1
fi

echo "  ✓ parsecd alive"

if grep -q "status.*-3\|status changed to: -3" "$PARSEC_LOG"; then
    echo "  ✗ STATUS -3 STILL PRESENT"
    echo ""
    cat "$PARSEC_LOG" | sed 's/^/    /'
    echo ""
    echo "  ldd check:"
    ldd $(which parsecd) 2>/dev/null | grep -iE "nvidia|vdpau|not found" | sed 's/^/    /'
    echo ""
    echo "  ═══ RESULT: FAILED — status -3 ═══"
    exit 1
else
    echo "  ✓ No status -3!"
    echo ""
    cat "$PARSEC_LOG" | sed 's/^/    /'
    echo ""
    echo "  ═══════════════════════════════════"
    echo "  ═══ RESULT: SUCCESS ═══"
    echo "  ═══════════════════════════════════"
    echo "  Open Parsec on Windows → connect to this host"
fi
