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

    Write-Host ">> Starting pod..."
    $ErrorActionPreference="Continue"
    try { Invoke-RestMethod "https://api.runpod.io/graphql?api_key=$API" -Method POST -ContentType "application/json" `
          -Body ('{"query":"mutation{podResume(input:{podId:\"'+$POD_ID+'\",gpuCount:1}){id desiredStatus}}"}') | Out-Null } catch {}
    $ErrorActionPreference="Stop"

    Write-Host ">> Detecting SSH..."
    $ip=""; $port=0; $tries=0
    $ErrorActionPreference="Continue"
    do {
        $tries++; if($tries-gt72){throw "Timed out (6 min)"}
        $c=RC; if($c -and (TCP $c.ip $c.port)){$ip=$c.ip;$port=$c.port;Write-Host ">> Cache: ${ip}:${port}";break}
        if(TCP $KNOWN_IP $KNOWN_PORT){$ip=$KNOWN_IP;$port=$KNOWN_PORT;Write-Host ">> Live: ${ip}:${port}";WC $ip $port;break}
        try {
            $r=Invoke-RestMethod "https://api.runpod.io/graphql?api_key=$API" -Method POST -ContentType "application/json" `
               -Body ('{"query":"{ pod(input:{podId:\"'+$POD_ID+'\"}) { desiredStatus runtime { ports { ip publicPort privatePort } } } }"}')
            $sp=$r.data.pod.runtime.ports|Where-Object{$_.privatePort-eq 22}|Select-Object -First 1
            if($sp -and $sp.ip){$ip=$sp.ip;$port=$sp.publicPort;Write-Host ">> GQL: ${ip}:${port}";WC $ip $port;break}
            Write-Host ">> $($r.data.pod.desiredStatus) / no ports (try $tries)"
        } catch { Write-Host (">> GQL err $tries`: " + $_) }
        Start-Sleep 5
    } while (!$ip)
    $ErrorActionPreference="Stop"

    if(Test-Path $WOTR){
        Write-Host ">> Uploading saves..."
        $ErrorActionPreference="Continue"
        Start-Process ssh -ArgumentList @("-o","StrictHostKeyChecking=no","-o","UserKnownHostsFile=NUL","-i",$SSHKEY,"-p","$port","root@$ip","mkdir -p /tmp/wis") -NoNewWindow -Wait | Out-Null
        Start-Process scp -ArgumentList @("-r","-P","$port","-i",$SSHKEY,"-o","StrictHostKeyChecking=no","-o","UserKnownHostsFile=NUL","`"$WOTR`"","root@${ip}:/tmp/wis/") -NoNewWindow -Wait | Out-Null
        $ErrorActionPreference="Stop"
    }

    Write-Host ">> Pushing setup to ${ip}:${port}..."
    $PW64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($PW))

    # FIXED: literal here-string prevents PowerShell expanding $B2I/$B2K/$EMAIL inside bash
    # Values injected via .Replace() tokens
    $bash=@'
#!/bin/bash
set -e
PW=$(printf '%s' '__PW64__' | base64 -d)
CFG=/root/.config/parsec/config.cfg
LOG=/workspace/gaming-logs
WS="/root/.local/share/unity3d/Owlcat Games/Pathfinder Wrath Of The Righteous/Saved Games"
WP="/root/.steam/steam/steamapps/compatdata/1184370/pfx/drive_c/users/steamuser/AppData/LocalLow/Owlcat Games/Pathfinder Wrath Of The Righteous/Saved Games"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wget xvfb curl jq python3-pip rsync >/dev/null 2>&1
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
mkdir -p "$WS" "$WP" "$LOG"
rclone copy b2:FunFun/wotr/saves/ "$WS/" --update 2>/dev/null || true
rclone copy b2:FunFun/wotr/saves/ "$WP/" --update 2>/dev/null || true
[ -d /tmp/wis ] && rsync -a --update /tmp/wis/ "$WS/" 2>/dev/null || true
[ -d /tmp/wis ] && rsync -a --update /tmp/wis/ "$WP/" 2>/dev/null || true
rclone sync "$WS/" b2:FunFun/wotr/saves/ 2>/dev/null || true
mkdir -p /root/.config/parsec
rclone copyto b2:FunFun/parsec/config.cfg "$CFG" 2>/dev/null || true
[ ! -f /usr/bin/parsecd ] && wget -q https://builds.parsec.app/package/parsec-linux.deb -O /tmp/p.deb && (dpkg -i /tmp/p.deb >/dev/null 2>&1 || apt-get install -f -y -qq >/dev/null 2>&1) || true
if ! grep -q app_session_id "$CFG" 2>/dev/null; then
  AUTH=$(curl -sf -X POST https://kessel-api.parsecgaming.com/v1/auth \
    -H 'Content-Type: application/json' \
    --data-raw "$(jq -n --arg e '__EMAIL__' --arg p "$PW" '{email:$e,password:$p,tfa:""}')")
  SID=$(echo "$AUTH"|jq -r '.data.id // empty')
  [ -z "$SID" ] && echo "AUTH_FAILED: $AUTH" >&2 && exit 1
  printf '{"app_host":1,"app_session_id":"%s"}' "$SID" > "$CFG"
fi
pkill Xvfb 2>/dev/null; pkill parsecd 2>/dev/null; sleep 1
Xvfb :99 -screen 0 1920x1080x24 & sleep 3
DISPLAY=:99 parsecd app_host=1 & sleep 12
(while true; do sleep 300; rclone sync "$WS/" b2:FunFun/wotr/saves/ 2>/dev/null||true; done) &
disown
rclone copyto "$CFG" b2:FunFun/parsec/config.cfg 2>/dev/null || true
echo PARSEC_READY
'@
    $bash = $bash.Replace('__PW64__', $PW64).Replace('__B2I__', $B2I).Replace('__B2K__', $B2K).Replace('__EMAIL__', $EMAIL)
    # LF only — bash will reject CRLF
    $bashBytes = [Text.Encoding]::UTF8.GetBytes(($bash -replace "`r`n","`n"))

    $tmp="$env:TEMP\ff_$PID.sh"; $out="$env:TEMP\ffout_$PID.txt"; $err="$env:TEMP\fferr_$PID.txt"
    [IO.File]::WriteAllBytes($tmp, $bashBytes)
    Start-Process ssh -ArgumentList @("-o","StrictHostKeyChecking=no","-o","UserKnownHostsFile=NUL","-i",$SSHKEY,"-p","$port","root@$ip","bash","-s") `
        -RedirectStandardInput $tmp -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -Wait | Out-Null
    $res=Get-Content $out -Raw -EA SilentlyContinue
    $er =Get-Content $err -Raw -EA SilentlyContinue
    Remove-Item $tmp -EA SilentlyContinue
    Write-Host "=== SSH STDOUT ===`n$res"
    Write-Host "=== SSH STDERR ===`n$er"
    if($res -match "AUTH_FAILED"){throw "Parsec auth failed - check ParsecPW"}
    if($res -notmatch "PARSEC_READY"){Write-Host "!! PARSEC_READY not seen" -ForegroundColor Yellow}
    Write-Host ">> Launching Parsec..." -ForegroundColor Green
    Start-Process "C:\Program Files\Parsec\parsecd.exe"
    Start-Sleep 4
    Write-Host ">> Done. Click FunFunPod in My Computers." -ForegroundColor Green
} catch {
    Write-Host ("`n!! ERROR: " + $_) -ForegroundColor Red
}

Stop-Transcript | Out-Null
Write-Host "`nLog: $LOG"
Read-Host "Press Enter to close"
