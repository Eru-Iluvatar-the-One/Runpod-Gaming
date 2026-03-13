param()
$LOG = "$env:USERPROFILE\Desktop\FunFunPod_log.txt"
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\FunFunPod" | Out-Null
Start-Transcript -Path $LOG -Force | Out-Null
$ErrorActionPreference = "Stop"

try {
    $host.UI.RawUI.WindowTitle = "FunFunPod"
    $POD_ID  = "fna668y0lkmimr"
    $EMAIL   = "eruilu22@gmail.com"
    $SSHKEY  = "$env:USERPROFILE\.ssh\id_ed25519"
    $CACHE   = "$env:USERPROFILE\.funfunpod_cache.json"
    $WOTR    = "$env:USERPROFILE\AppData\LocalLow\Owlcat Games\Pathfinder Wrath Of The Righteous\Saved Games"
    $KNOWN_IP   = "203.57.40.126"
    $KNOWN_PORT = 10094

    function G($n) {
        $v = [Environment]::GetEnvironmentVariable($n,"User")
        if (!$v) { $v = [Environment]::GetEnvironmentVariable($n,"Machine") }
        return $v
    }
    $API = G "FunFunPod"
    $B2I = G "B2 FunFun keyID"
    $B2K = G "B2 applicationKey"
    $PW  = G "ParsecPW"

    Write-Host "API=$(-not !$API) B2I=$(-not !$B2I) B2K=$(-not !$B2K) PW=$(-not !$PW) KEY=$(Test-Path $SSHKEY)"

    if (!$API) { throw "FunFunPod env var missing" }
    if (!$PW)  { throw "ParsecPW env var missing" }
    if (!(Test-Path $SSHKEY)) { throw "SSH key missing: $SSHKEY" }

    $SSH = @("-o","StrictHostKeyChecking=no","-o","UserKnownHostsFile=NUL","-i",$SSHKEY,"-p","$KNOWN_PORT","root@$KNOWN_IP")

    function TCP($h,$p) {
        try { $t=New-Object Net.Sockets.TcpClient; $r=$t.BeginConnect($h,$p,$null,$null)
              $ok=$r.AsyncWaitHandle.WaitOne(3000,$false); $c=$ok-and$t.Connected; $t.Close(); return $c }
        catch { return $false }
    }
    function RC {
        try { if(Test-Path $CACHE){$c=Get-Content $CACHE -Raw|ConvertFrom-Json
              if($c.podId-eq$POD_ID-and$c.ip-and$c.port){return $c}} } catch {}; return $null
    }
    function WC($i,$p){ @{podId=$POD_ID;ip=$i;port=$p}|ConvertTo-Json|Set-Content $CACHE -Force }
    function SSH-Run($cmd) {
        Start-Process ssh -ArgumentList ($SSH + $cmd) -NoNewWindow -Wait -PassThru | Out-Null
    }
    function SSH-Out($cmd) {
        $out = "$env:TEMP\sshout_$PID.txt"
        Start-Process ssh -ArgumentList ($SSH + $cmd) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $out | Out-Null
        $r = Get-Content $out -Raw -EA SilentlyContinue
        Remove-Item $out -EA SilentlyContinue
        return $r
    }

    Write-Host ">> Starting pod..."
    $ErrorActionPreference="Continue"
    try { Invoke-RestMethod "https://api.runpod.io/graphql?api_key=$API" -Method POST -ContentType "application/json" `
          -Body ('{"query":"mutation{podResume(input:{podId:\"'+$POD_ID+'\",gpuCount:1}){id desiredStatus}}"}') | Out-Null } catch {}
    $ErrorActionPreference="Stop"

    Write-Host ">> Waiting for SSH..."
    $tries=0
    do {
        $tries++; if($tries-gt72){throw "Timed out (6 min)"}
        if(TCP $KNOWN_IP $KNOWN_PORT){Write-Host ">> Live: ${KNOWN_IP}:${KNOWN_PORT}";WC $KNOWN_IP $KNOWN_PORT;break}
        $c=RC; if($c -and (TCP $c.ip $c.port)){Write-Host ">> Cache: $($c.ip):$($c.port)";break}
        Write-Host ">> Waiting... (try $tries)"; Start-Sleep 5
    } while ($true)

    if(Test-Path $WOTR){
        Write-Host ">> Uploading saves..."
        $ErrorActionPreference="Continue"
        SSH-Run "mkdir -p /tmp/wis"
        Start-Process scp -ArgumentList @("-r","-P","$KNOWN_PORT","-i",$SSHKEY,"-o","StrictHostKeyChecking=no","-o","UserKnownHostsFile=NUL","`"$WOTR`"","root@${KNOWN_IP}:/tmp/wis/") -NoNewWindow -Wait | Out-Null
        $ErrorActionPreference="Stop"
    }

    Write-Host ">> Building setup script..."
    $PW64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($PW))

    $bash=@'
#!/bin/bash
set -euo pipefail
exec > /workspace/ff_setup.log 2>&1
echo "=== SETUP START ==="
PW=$(printf '%s' '__PW64__' | base64 -d)
CFG=/root/.parsec/config.txt
WS="/root/.local/share/unity3d/Owlcat Games/Pathfinder Wrath Of The Righteous/Saved Games"
WP="/root/.steam/steam/steamapps/compatdata/1184370/pfx/drive_c/users/steamuser/AppData/LocalLow/Owlcat Games/Pathfinder Wrath Of The Righteous/Saved Games"
export DEBIAN_FRONTEND=noninteractive

echo "Installing deps..."
apt-get update -qq && apt-get install -y -qq wget xvfb curl jq rsync >/dev/null 2>&1

echo "Installing rclone..."
command -v rclone &>/dev/null || (curl -fsSL https://rclone.org/install.sh | bash >/dev/null 2>&1) || true
mkdir -p /root/.config/rclone
cat > /root/.config/rclone/rclone.conf << 'REOF'
[b2]
type = s3
provider = Other
access_key_id = __B2I__
secret_access_key = __B2K__
endpoint = s3.us-east-005.backblazeb2.com
acl = private
no_check_bucket = true
REOF

echo "Syncing saves..."
mkdir -p "$WS" "$WP" /workspace/gaming-logs
rclone copy b2:FunFun/wotr/saves/ "$WS/" --update 2>/dev/null || true
rclone copy b2:FunFun/wotr/saves/ "$WP/" --update 2>/dev/null || true
[ -d /tmp/wis ] && rsync -a --update /tmp/wis/ "$WS/" 2>/dev/null || true
[ -d /tmp/wis ] && rsync -a --update /tmp/wis/ "$WP/" 2>/dev/null || true
rclone sync "$WS/" b2:FunFun/wotr/saves/ 2>/dev/null || true

echo "=== PHASE: NVIDIA LIB FIX ==="
DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d '[:space:]')
if [ -z "$DRIVER_VER" ]; then
    DRIVER_VER=$(cat /proc/driver/nvidia/version 2>/dev/null | grep -oP 'Kernel Module\s+\K[0-9.]+' | head -1)
fi
MAJOR_VER=$(echo "$DRIVER_VER" | cut -d. -f1)
echo "NVIDIA driver: $DRIVER_VER (major: $MAJOR_VER)"

for pkg in libvdpau1 libvdpau-dev vdpau-driver-all \
           libnvidia-encode-${MAJOR_VER} libnvidia-decode-${MAJOR_VER} \
           libnvidia-fbc1-${MAJOR_VER} nvidia-utils-${MAJOR_VER} \
           libxrandr2 libxfixes3 libxcursor1 mesa-utils x11-xserver-utils; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        apt-get install -y -qq "$pkg" >/dev/null 2>&1 && echo "  installed: $pkg" || echo "  skipped: $pkg"
    else
        echo "  present: $pkg"
    fi
done

LIBDIR="/usr/lib/x86_64-linux-gnu"
VDPAU_DIR="$LIBDIR/vdpau"
mkdir -p "$VDPAU_DIR"

for libname in libvdpau_nvidia.so libnvidia-encode.so libcuda.so libnvidia-fbc.so libnvidia-ml.so; do
    if ! ldconfig -p 2>/dev/null | grep -q "$libname"; then
        real=$(find / -maxdepth 6 -name "${libname}*" ! -path "*/proc/*" 2>/dev/null | head -1)
        if [ -n "$real" ]; then
            ln -sf "$real" "$LIBDIR/$libname" 2>/dev/null || true
            ln -sf "$real" "$LIBDIR/${libname}.1" 2>/dev/null || true
            echo "  symlinked: $libname -> $real"
        fi
    fi
done

NVIDIA_VDPAU=$(find / -maxdepth 6 -name "libvdpau_nvidia.so*" ! -path "*/proc/*" 2>/dev/null | head -1)
if [ -n "$NVIDIA_VDPAU" ]; then
    ln -sf "$NVIDIA_VDPAU" "$VDPAU_DIR/libvdpau_nvidia.so.1" 2>/dev/null || true
    ln -sf "$VDPAU_DIR/libvdpau_nvidia.so.1" "$VDPAU_DIR/libvdpau_nvidia.so" 2>/dev/null || true
    echo "  VDPAU driver dir: OK"
fi

cat > /etc/ld.so.conf.d/nvidia-parsec.conf << 'LDEOF'
/usr/lib/x86_64-linux-gnu
/usr/lib/x86_64-linux-gnu/vdpau
/usr/local/nvidia/lib
/usr/local/nvidia/lib64
/usr/local/cuda/lib64
LDEOF
ldconfig 2>&1
echo "ldconfig refreshed"
ldconfig -p | grep -iE "vdpau_nvidia|libnvidia-encode" || echo "  (WARN: libs not in cache)"

echo "=== PHASE: PARSEC AUTH ==="
[ ! -f /usr/bin/parsecd ] && wget -q https://builds.parsec.app/package/parsec-linux.deb -O /tmp/p.deb \
  && (dpkg -i /tmp/p.deb >/dev/null 2>&1 || apt-get install -f -y -qq >/dev/null 2>&1) || true

mkdir -p /root/.parsec
rm -f "$CFG" /root/.parsec/config.json

echo "Authenticating Parsec..."
JSON=$(jq -n --arg e '__EMAIL__' --arg p "$PW" '{"email":$e,"password":$p,"tfa":""}')
AUTH=$(curl -s -X POST https://kessel-api.parsec.app/v1/auth \
  -H 'Content-Type: application/json' -d "$JSON")
[ -z "$AUTH" ] && AUTH=$(curl -s -X POST https://kessel-api.parsecgaming.com/v1/auth \
  -H 'Content-Type: application/json' -d "$JSON") || true
echo "Auth response: $AUTH"

TFA=$(echo "$AUTH" | jq -r '.data.tfa_required // false' 2>/dev/null || echo false)
[ "$TFA" = "true" ] && echo "AUTH_FAILED: 2FA enabled" && exit 1

SID=$(echo "$AUTH" | jq -r '.session_id // .data.session_id // .data.id // empty' 2>/dev/null || true)
[ -z "$SID" ] && echo "AUTH_FAILED: no session_id — $AUTH" && exit 1

printf 'session_id = %s\napp_host = 1\n' "$SID" > "$CFG"
echo "Config written: $CFG"
cat "$CFG"
rclone copyto "$CFG" b2:FunFun/parsec/config.txt 2>/dev/null || true

echo "=== PHASE: LAUNCH ==="
pkill Xvfb 2>/dev/null || true; pkill parsecd 2>/dev/null || true; sleep 2

Xvfb :99 -screen 0 1920x1080x24 +extension GLX +render -noreset &
sleep 3

export DISPLAY=:99
export LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu:/usr/local/nvidia/lib64:/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export VDPAU_DRIVER=nvidia
export __GL_SYNC_TO_VBLANK=0

DISPLAY=:99 parsecd &
PARSEC_PID=$!
sleep 15

echo "=== PHASE: VERIFY ==="
ps aux | grep -E 'parsecd|Xvfb' | grep -v grep
nvidia-smi 2>&1 | head -5
ldconfig -p | grep -i vdpau || echo "(no vdpau in cache)"

if [ -f /root/.parsec/log.txt ]; then
    if grep -q "status.*-3" /root/.parsec/log.txt 2>/dev/null; then
        echo "WARN_STATUS_MINUS_3: still present in log"
        tail -20 /root/.parsec/log.txt
    else
        echo "NO status -3 in log"
    fi
fi

if kill -0 $PARSEC_PID 2>/dev/null; then
    echo "=== PARSEC_READY ==="
else
    echo "PARSEC_DEAD"
    tail -30 /root/.parsec/log.txt 2>/dev/null || true
fi

(while true; do sleep 300; rclone sync "$WS/" b2:FunFun/wotr/saves/ 2>/dev/null||true; done) &
disown
'@
    $bash = $bash.Replace('__PW64__', $PW64).Replace('__B2I__', $B2I).Replace('__B2K__', $B2K).Replace('__EMAIL__', $EMAIL)
    $bashBytes = [Text.Encoding]::UTF8.GetBytes(($bash -replace "`r`n","`n"))
    $tmp = "$env:TEMP\ff_$PID.sh"
    [IO.File]::WriteAllBytes($tmp, $bashBytes)

    Write-Host ">> Uploading script..."
    Start-Process scp -ArgumentList @("-P","$KNOWN_PORT","-i",$SSHKEY,"-o","StrictHostKeyChecking=no","-o","UserKnownHostsFile=NUL",$tmp,"root@${KNOWN_IP}:/tmp/ff_setup.sh") -NoNewWindow -Wait | Out-Null
    Remove-Item $tmp -EA SilentlyContinue

    Write-Host ">> Executing script (takes ~3 min with NVIDIA fix)..."
    SSH-Run "bash /tmp/ff_setup.sh"

    Write-Host ">> Fetching log..."
    $res = SSH-Out "cat /workspace/ff_setup.log"
    Write-Host "=== POD LOG ===`n$res"

    if($res -match "AUTH_FAILED"){throw "Parsec auth failed: $res"}
    if($res -match "PARSEC_DEAD"){Write-Host "!! Parsec died — check log above" -ForegroundColor Red}
    if($res -match "WARN_STATUS_MINUS_3"){Write-Host "!! Status -3 still present" -ForegroundColor Yellow}
    if($res -notmatch "PARSEC_READY"){Write-Host "!! PARSEC_READY not seen" -ForegroundColor Yellow}

    Write-Host ">> Launching local Parsec..." -ForegroundColor Green
    Start-Process "C:\Program Files\Parsec\parsecd.exe"
    Start-Sleep 4
    Write-Host ">> Done. Click FunFunPod in My Computers." -ForegroundColor Green
} catch {
    Write-Host ("`n!! ERROR: " + $_) -ForegroundColor Red
    Write-Host "Pod log: check $LOG or RunPod web terminal: cat /workspace/ff_setup.log" -ForegroundColor Yellow
}

Stop-Transcript | Out-Null
Write-Host "`nLog: $LOG"
Read-Host "Press Enter to close"
