param()
$ErrorActionPreference = "Stop"
$LOG = "C:\FunFunPod\last_run.log"
Start-Transcript -Path $LOG -Force | Out-Null

try {

$host.UI.RawUI.WindowTitle = "FunFunPod"

$POD_ID      = "lu82dw2kr8nuuj"
$EMAIL       = "eruilu22@gmail.com"
$SSHKEY      = "$env:USERPROFILE\.ssh\id_ed25519"
$CACHE_FILE  = "$env:USERPROFILE\.funfunpod_cache.json"
$WOTR_SAVES_WIN = "$env:USERPROFILE\AppData\LocalLow\Owlcat Games\Pathfinder Wrath Of The Righteous\Saved Games"
$KNOWN_IP   = "69.30.85.244"
$KNOWN_PORT = 22060

function GetEnv($n) {
    $v = [Environment]::GetEnvironmentVariable($n, "User")
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($n, "Machine") }
    return $v
}
$API_KEY = GetEnv "FunFunPod"
$B2_ID   = GetEnv "B2 FunFun keyID"
$B2_KEY  = GetEnv "B2 applicationKey"
$PW      = GetEnv "ParsecPW"

function W($m, $c="Cyan") { Write-Host ">> $m" -ForegroundColor $c }

W "API_KEY present: $(-not [string]::IsNullOrEmpty($API_KEY))"
W "B2_ID present:   $(-not [string]::IsNullOrEmpty($B2_ID))"
W "B2_KEY present:  $(-not [string]::IsNullOrEmpty($B2_KEY))"
W "PW present:      $(-not [string]::IsNullOrEmpty($PW))"
W "SSHKEY exists:   $(Test-Path $SSHKEY)"

if (-not $API_KEY) { throw "FunFunPod env var missing" }
if (-not $PW)      { throw "ParsecPW env var missing" }
if (-not (Test-Path $SSHKEY)) { throw "SSH key not found at $SSHKEY" }

function Test-TCP($ip, $port, $ms=3000) {
    try {
        $t = New-Object System.Net.Sockets.TcpClient
        $r = $t.BeginConnect($ip, $port, $null, $null)
        $ok = $r.AsyncWaitHandle.WaitOne($ms, $false)
        $connected = $ok -and $t.Connected
        $t.Close()
        return $connected
    } catch { return $false }
}

function Read-Cache {
    try {
        if (Test-Path $CACHE_FILE) {
            $c = Get-Content $CACHE_FILE -Raw | ConvertFrom-Json
            if ($c.podId -eq $POD_ID -and $c.ip -and $c.port) { return $c }
        }
    } catch {}
    return $null
}
function Write-Cache($ip, $port) {
    @{ podId=$POD_ID; ip=$ip; port=$port } | ConvertTo-Json | Set-Content $CACHE_FILE -Force
}

# ── Resume pod ───────────────────────────────────────────────────────
W "Starting pod..."
$ErrorActionPreference = "Continue"
$startQ = '{"query":"mutation{podResume(input:{podId:\"' + $POD_ID + '\",gpuCount:1}){id desiredStatus}}"}' 
try { Invoke-RestMethod "https://api.runpod.io/graphql?api_key=$API_KEY" -Method POST -ContentType "application/json" -Body $startQ | Out-Null } catch { W "Resume call: $_" "DarkGray" }
$ErrorActionPreference = "Stop"

# ── Port detection ───────────────────────────────────────────────────
W "Detecting SSH endpoint..."
$ip = ""; $port = 0; $tries = 0

$ErrorActionPreference = "Continue"
do {
    $tries++
    if ($tries -gt 60) { throw "Timed out waiting for pod SSH port" }

    $c = Read-Cache
    if ($c -and (Test-TCP $c.ip $c.port)) {
        $ip = $c.ip; $port = $c.port
        W "Cache hit: ${ip}:${port}" "Green"; break
    }
    if (Test-TCP $KNOWN_IP $KNOWN_PORT) {
        $ip = $KNOWN_IP; $port = $KNOWN_PORT
        W "Endpoint alive: ${ip}:${port}" "Green"
        Write-Cache $ip $port; break
    }
    try {
        $q = '{"query":"{ pod(input: { podId: \"' + $POD_ID + '\" }) { desiredStatus runtime { ports { ip publicPort privatePort } } } }"}'
        $r = Invoke-RestMethod "https://api.runpod.io/graphql?api_key=$API_KEY" -Method POST -ContentType "application/json" -Body $q
        $sp = $r.data.pod.runtime.ports | Where-Object { $_.privatePort -eq 22 } | Select-Object -First 1
        if ($sp -and $sp.ip -and $sp.publicPort) {
            $ip = $sp.ip; $port = $sp.publicPort
            W "GraphQL ports: ${ip}:${port}" "Green"
            Write-Cache $ip $port; break
        }
        W "Pod: $($r.data.pod.desiredStatus) / ports null - retry $tries..." "DarkGray"
    } catch { W "GQL failed ($tries): $_" "DarkGray" }
    Start-Sleep 5
} while (-not $ip)
$ErrorActionPreference = "Stop"

# ── SCP local WotR saves → pod ───────────────────────────────────────
$ErrorActionPreference = "Continue"
if (Test-Path $WOTR_SAVES_WIN) {
    W "Uploading local WotR saves..."
    Start-Process ssh -ArgumentList @("-o","StrictHostKeyChecking=no","-o","UserKnownHostsFile=NUL","-i",$SSHKEY,"-p","$port","root@$ip","mkdir -p /tmp/wotr_saves_incoming") -NoNewWindow -Wait | Out-Null
    Start-Process scp -ArgumentList @("-r","-P","$port","-i",$SSHKEY,"-o","StrictHostKeyChecking=no","-o","UserKnownHostsFile=NUL","`"$WOTR_SAVES_WIN`"","root@${ip}:/tmp/wotr_saves_incoming/") -NoNewWindow -Wait | Out-Null
    W "Saves staged." "Green"
} else {
    W "No local WotR saves at: $WOTR_SAVES_WIN" "DarkGray"
}
$ErrorActionPreference = "Stop"

W "SSH at ${ip}:${port} - configuring pod..."

# ── Bash payload ─────────────────────────────────────────────────────
$PW_B64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($PW))
$bash = @"
#!/bin/bash
set -e
PW=`$(printf '%s' '$PW_B64' | base64 -d)
CFG=/root/.config/parsec/config.cfg
LOG=/workspace/gaming-logs
WOTR_SAVES="/root/.local/share/unity3d/Owlcat Games/Pathfinder Wrath Of The Righteous/Saved Games"
WOTR_SAVES_PROTON="/root/.steam/steam/steamapps/compatdata/1184370/pfx/drive_c/users/steamuser/AppData/LocalLow/Owlcat Games/Pathfinder Wrath Of The Righteous/Saved Games"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wget xvfb curl jq python3-pip rsync >/dev/null 2>&1
pip3 install b2 -q >/dev/null 2>&1 || true
if ! command -v rclone &>/dev/null; then curl -fsSL https://rclone.org/install.sh | bash >/dev/null 2>&1 || true; fi
mkdir -p /root/.config/rclone
cat > /root/.config/rclone/rclone.conf << REOF
[b2]
type = s3
provider = Other
access_key_id = $B2_ID
secret_access_key = $B2_KEY
endpoint = s3.us-east-005.backblazeb2.com
acl = private
no_check_bucket = true
REOF
mkdir -p "`$WOTR_SAVES" "`$WOTR_SAVES_PROTON" "`$LOG"
rclone copy b2:FunFun/wotr/saves/ "`$WOTR_SAVES/" --update 2>/dev/null || true
rclone copy b2:FunFun/wotr/saves/ "`$WOTR_SAVES_PROTON/" --update 2>/dev/null || true
if [ -d /tmp/wotr_saves_incoming ]; then
    rsync -a --update /tmp/wotr_saves_incoming/ "`$WOTR_SAVES/" 2>/dev/null || true
    rsync -a --update /tmp/wotr_saves_incoming/ "`$WOTR_SAVES_PROTON/" 2>/dev/null || true
fi
rclone sync "`$WOTR_SAVES/" b2:FunFun/wotr/saves/ --log-file="`$LOG/b2.log" 2>/dev/null || true
mkdir -p /root/.config/parsec
b2 authorize-account '$B2_ID' '$B2_KEY' 2>/dev/null || true
b2 download-file-by-name FunFun parsec/config.cfg "`$CFG" 2>/dev/null || true
if [ ! -f /usr/bin/parsecd ]; then
    wget -q https://builds.parsec.app/package/parsec-linux.deb -O /tmp/p.deb
    dpkg -i /tmp/p.deb >/dev/null 2>&1 || apt-get install -f -y -qq >/dev/null 2>&1
fi
if ! grep -q app_session_id "`$CFG" 2>/dev/null; then
    AUTH=`$(curl -sf -X POST https://kessel-api.parsecgaming.com/v1/auth \
        -H 'Content-Type: application/json' \
        -d "{\"email\":\"$EMAIL\",\"password\":\"`$PW\",\"tfa\":\"\"}")
    SID=`$(echo "`$AUTH" | jq -r '.data.id // empty')
    if [ -z "`$SID" ]; then echo "AUTH_FAILED: `$AUTH" >&2; exit 1; fi
    printf '{"app_host":1,"app_session_id":"%s"}' "`$SID" > "`$CFG"
fi
pkill Xvfb 2>/dev/null || true; pkill parsecd 2>/dev/null || true; sleep 1
Xvfb :99 -screen 0 1920x1080x24 &
sleep 3
DISPLAY=:99 parsecd app_host=1 &
sleep 12
cat > /tmp/wotr_b2_sync.sh << 'SYNCEOF'
#!/bin/bash
WOTR_SAVES="/root/.local/share/unity3d/Owlcat Games/Pathfinder Wrath Of The Righteous/Saved Games"
while true; do sleep 300; rclone sync "`$WOTR_SAVES/" b2:FunFun/wotr/saves/ --log-file=/workspace/gaming-logs/b2.log --log-level INFO 2>/dev/null || true; done
SYNCEOF
chmod +x /tmp/wotr_b2_sync.sh
nohup /tmp/wotr_b2_sync.sh </dev/null >/dev/null 2>&1 &
disown
b2 upload-file FunFun "`$CFG" parsec/config.cfg 2>/dev/null || true
echo PARSEC_READY
"@

$tmp = "$env:TEMP\ff_$(Get-Random).sh"
$out = "$env:TEMP\ffout.txt"
$err = "$env:TEMP\fferr.txt"
$bash | Set-Content $tmp -Encoding Ascii

Start-Process ssh -ArgumentList @("-o","StrictHostKeyChecking=no","-o","UserKnownHostsFile=NUL","-i",$SSHKEY,"-p","$port","root@$ip","bash","-s") `
    -RedirectStandardInput $tmp -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -Wait | Out-Null

$result = Get-Content $out -Raw -ErrorAction SilentlyContinue
$errout = Get-Content $err -Raw -ErrorAction SilentlyContinue
Remove-Item $tmp -ErrorAction SilentlyContinue

if ($result -match "AUTH_FAILED") { throw "Parsec auth failed. Check ParsecPW.`n$result" }
if ($errout) { W "SSH stderr: $errout" "DarkGray" }
if ($result -notmatch "PARSEC_READY") { W "Unexpected output: $result" "Yellow" }

W "PARSEC_READY - launching Parsec..." "Green"
Start-Process "C:\Program Files\Parsec\parsecd.exe"
Start-Sleep 4
W "Click FunFunPod in My Computers." "Green"
Start-Sleep 3

} catch {
    Write-Host "`n!! FAILED: $_" -ForegroundColor Red
    Write-Host "Log: $LOG" -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
}

Stop-Transcript | Out-Null
