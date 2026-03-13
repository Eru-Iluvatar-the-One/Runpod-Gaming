param()
$LOG = "$env:USERPROFILE\Desktop\FunFunPod_log.txt"
New-Item -ItemType Directory -Force -Path "C:\FunFunPod" | Out-Null
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
        $p = Start-Process ssh -ArgumentList ($SSH + $cmd) -NoNewWindow -Wait -PassThru
        return $p.ExitCode
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
        SSH-Run "mkdir -p /tmp/wis" | Out-Null
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
CFG=/root/.config/parsec/config.cfg
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
echo "Parsec config..."
mkdir -p /root/.config/parsec
rclone copyto b2:FunFun/parsec/config.cfg "$CFG" 2>/dev/null || true
[ ! -f /usr/bin/parsecd ] && wget -q https://builds.parsec.app/package/parsec-linux.deb -O /tmp/p.deb \
  && (dpkg -i /tmp/p.deb >/dev/null 2>&1 || apt-get install -f -y -qq >/dev/null 2>&1) || true
if ! grep -q app_session_id "$CFG" 2>/dev/null; then
  echo "Authenticating Parsec..."
  JSON=$(jq -n --arg e '__EMAIL__' --arg p "$PW" '{"email":$e,"password":$p,"tfa":""}')
  echo "Sending auth request..."
  AUTH=$(curl -s -X POST https://kessel-api.parsec.app/v1/auth \
    -H 'Content-Type: application/json' -d "$JSON") || AUTH=""
  [ -z "$AUTH" ] && AUTH=$(curl -s -X POST https://kessel-api.parsecgaming.com/v1/auth \
    -H 'Content-Type: application/json' -d "$JSON") || true
  echo "Auth response: $AUTH"
  TFA=$(echo "$AUTH" | jq -r '.data.tfa_required // false' 2>/dev/null || echo false)
  [ "$TFA" = "true" ] && echo "AUTH_FAILED: 2FA enabled" && exit 1
  SID=$(echo "$AUTH" | jq -r '.data.id // empty' 2>/dev/null || true)
  [ -z "$SID" ] && echo "AUTH_FAILED: no session id — $AUTH" && exit 1
  cat > "$CFG" << PCFG
app_host = 1
app_session_id = ${SID}
server_resolution_x = 1920
server_resolution_y = 1080
encoder_bitrate = 50
encoder_fps = 60
PCFG
  echo "Config written."
  rclone copyto "$CFG" b2:FunFun/parsec/config.cfg 2>/dev/null || true
fi
echo "Launching Parsec..."
pkill Xvfb 2>/dev/null || true; pkill parsecd 2>/dev/null || true; sleep 1
Xvfb :99 -screen 0 1920x1080x24 &
sleep 3
DISPLAY=:99 parsecd app_host=1 &
sleep 15
ps aux | grep -E 'parsecd|Xvfb' | grep -v grep
(while true; do sleep 300; rclone sync "$WS/" b2:FunFun/wotr/saves/ 2>/dev/null||true; done) &
disown
echo "=== PARSEC_READY ==="
'@
    $bash = $bash.Replace('__PW64__', $PW64).Replace('__B2I__', $B2I).Replace('__B2K__', $B2K).Replace('__EMAIL__', $EMAIL)
    $bashBytes = [Text.Encoding]::UTF8.GetBytes(($bash -replace "`r`n","`n"))
    $tmp = "$env:TEMP\ff_$PID.sh"
    [IO.File]::WriteAllBytes($tmp, $bashBytes)

    Write-Host ">> Uploading script..."
    Start-Process scp -ArgumentList @("-P","$KNOWN_PORT","-i",$SSHKEY,"-o","StrictHostKeyChecking=no","-o","UserKnownHostsFile=NUL",$tmp,"root@${KNOWN_IP}:/tmp/ff_setup.sh") -NoNewWindow -Wait | Out-Null
    Remove-Item $tmp -EA SilentlyContinue

    Write-Host ">> Executing script (takes ~2 min)..."
    SSH-Run "bash /tmp/ff_setup.sh" | Out-Null

    Write-Host ">> Fetching log..."
    $res = SSH-Out "cat /workspace/ff_setup.log"
    Write-Host "=== POD LOG ===`n$res"

    if($res -match "AUTH_FAILED"){throw "Parsec auth failed — check ParsecPW env var"}
    if($res -notmatch "PARSEC_READY"){Write-Host "!! PARSEC_READY not seen — check log above" -ForegroundColor Yellow}

    Write-Host ">> Launching Parsec..." -ForegroundColor Green
    Start-Process "C:\Program Files\Parsec\parsecd.exe"
    Start-Sleep 4
    Write-Host ">> Done. Click FunFunPod in My Computers." -ForegroundColor Green
} catch {
    Write-Host ("`n!! ERROR: " + $_) -ForegroundColor Red
    Write-Host "Check pod log: ssh -p $KNOWN_PORT -i $SSHKEY root@$KNOWN_IP cat /workspace/ff_setup.log" -ForegroundColor Yellow
}

Stop-Transcript | Out-Null
Write-Host "`nLog: $LOG"
Read-Host "Press Enter to close"
