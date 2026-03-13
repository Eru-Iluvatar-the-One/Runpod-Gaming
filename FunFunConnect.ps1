param()
$ErrorActionPreference = "Continue"
$host.UI.RawUI.WindowTitle = "FunFunPod"

$POD_ID      = "lu82dw2kr8nuuj"
$EMAIL       = "eruilu22@gmail.com"
$SSHKEY      = "$env:USERPROFILE\.ssh\id_ed25519"
$CACHE_FILE  = "$env:USERPROFILE\.funfunpod_cache.json"

# Known-good fallback — updated by successful connects
$KNOWN_IP    = "69.30.85.244"
$KNOWN_PORT  = 22060

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

if (-not $API_KEY) { W "ERROR: FunFunPod env var missing." "Red"; Read-Host; exit 1 }
if (-not $PW)      { W "ERROR: ParsecPW env var missing."  "Red"; Read-Host; exit 1 }

# ── TCP probe ────────────────────────────────────────────────────────
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

# ── Cache helpers ────────────────────────────────────────────────────
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
$startQ = '{"query":"mutation{podResume(input:{podId:\"' + $POD_ID + '\",gpuCount:1}){id desiredStatus}}"}'
try { Invoke-RestMethod "https://api.runpod.io/graphql?api_key=$API_KEY" -Method POST -ContentType "application/json" -Body $startQ | Out-Null } catch {}

# ── Port detection ───────────────────────────────────────────────────
# GraphQL runtime.ports is PERMANENTLY NULL on RunPod for this pod type (confirmed).
# Primary: TCP probe against cache → known fallback → GraphQL (last resort).
W "Detecting SSH endpoint..."
$ip = ""; $port = 0; $tries = 0

do {
    $tries++
    if ($tries -gt 60) { W "Timed out." "Red"; Read-Host; exit 1 }

    # 1. Try cache
    if (-not $ip) {
        $c = Read-Cache
        if ($c -and (Test-TCP $c.ip $c.port)) {
            $ip = $c.ip; $port = $c.port
            W "Cache hit: ${ip}:${port}" "Green"
            break
        }
    }

    # 2. Try known-good hardcoded value
    if (-not $ip -and (Test-TCP $KNOWN_IP $KNOWN_PORT)) {
        $ip = $KNOWN_IP; $port = $KNOWN_PORT
        W "Known endpoint alive: ${ip}:${port}" "Green"
        Write-Cache $ip $port
        break
    }

    # 3. GraphQL — only for status check + any rare case ports populate
    if (-not $ip) {
        try {
            $q = '{"query":"{ pod(input: { podId: \"' + $POD_ID + '\" }) { desiredStatus runtime { ports { ip publicPort privatePort } } } }"}'
            $r = Invoke-RestMethod "https://api.runpod.io/graphql?api_key=$API_KEY" -Method POST -ContentType "application/json" -Body $q -ErrorAction Stop
            $pod = $r.data.pod
            if ($pod.runtime.ports) {
                $sp = $pod.runtime.ports | Where-Object { $_.privatePort -eq 22 } | Select-Object -First 1
                if ($sp.ip -and $sp.publicPort) {
                    $ip = $sp.ip; $port = $sp.publicPort
                    W "GraphQL ports found: ${ip}:${port}" "Green"
                    Write-Cache $ip $port
                    break
                }
            }
            W "Pod status: $($pod.desiredStatus) — ports null (expected). TCP probe retry $tries..." "DarkGray"
        } catch { W "GQL failed ($tries)" "DarkGray" }
    }

    Start-Sleep 5

} while (-not $ip)

W "SSH at ${ip}:${port} — pushing Parsec setup..."

# ── Bash payload ─────────────────────────────────────────────────────
$PW_B64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($PW))
$bash = @"
#!/bin/bash
set -e
PW=`$(printf '%s' '$PW_B64' | base64 -d)
CFG=/root/.config/parsec/config.cfg
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wget xvfb curl jq python3-pip >/dev/null 2>&1
pip3 install b2 -q >/dev/null 2>&1 || true
mkdir -p /root/.config/parsec

# ── Parsec config from B2 ──
b2 authorize-account '$B2_ID' '$B2_KEY' 2>/dev/null || true
b2 download-file-by-name FunFun parsec/config.cfg "`$CFG" 2>/dev/null || true

# ── Install Parsec ──
if [ ! -f /usr/bin/parsecd ]; then
    wget -q https://builds.parsec.app/package/parsec-linux.deb -O /tmp/p.deb
    dpkg -i /tmp/p.deb >/dev/null 2>&1 || apt-get install -f -y -qq >/dev/null 2>&1
fi

# ── Auth if needed ──
if ! grep -q app_session_id "`$CFG" 2>/dev/null; then
    AUTH=`$(curl -sf -X POST https://kessel-api.parsecgaming.com/v1/auth \
        -H 'Content-Type: application/json' \
        -d "{\"email\":\"$EMAIL\",\"password\":\"`$PW\",\"tfa\":\"\"}")
    SID=`$(echo "`$AUTH" | jq -r '.data.id // empty')
    if [ -z "`$SID" ]; then echo "AUTH_FAILED: `$AUTH" >&2; exit 1; fi
    printf '{"app_host":1,"app_session_id":"%s"}' "`$SID" > "`$CFG"
fi

# ── Launch Parsec host ──
pkill Xvfb 2>/dev/null || true
pkill parsecd 2>/dev/null || true
sleep 1
Xvfb :99 -screen 0 1920x1080x24 &
sleep 3
DISPLAY=:99 parsecd app_host=1 &
sleep 12

# ── Save session ──
b2 upload-file FunFun "`$CFG" parsec/config.cfg 2>/dev/null || true
echo PARSEC_READY
"@

$tmp = "$env:TEMP\ff_$(Get-Random).sh"
$out = "$env:TEMP\ffout.txt"
$err = "$env:TEMP\fferr.txt"
$bash | Set-Content $tmp -Encoding Ascii

Start-Process ssh -ArgumentList @(
    "-o","StrictHostKeyChecking=no",
    "-o","UserKnownHostsFile=NUL",
    "-i",$SSHKEY,
    "-p","$port",
    "root@$ip",
    "bash","-s"
) -RedirectStandardInput $tmp -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -Wait | Out-Null

$result = Get-Content $out -Raw -ErrorAction SilentlyContinue
Remove-Item $tmp -ErrorAction SilentlyContinue

if ($result -match "AUTH_FAILED") {
    W "Parsec auth failed — check ParsecPW." "Red"
    Write-Host $result
    Read-Host; exit 1
}

if ($result -notmatch "PARSEC_READY") {
    W "Unexpected output — check $err" "Yellow"
    Write-Host $result
}

W "PARSEC_READY — launching client..." "Green"
Start-Process "C:\Program Files\Parsec\parsecd.exe"
Start-Sleep 4
W "Click FunFunPod in My Computers. Hit Reload if not visible." "Green"
Start-Sleep 5
