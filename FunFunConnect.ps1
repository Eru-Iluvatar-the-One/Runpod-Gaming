param()
$ErrorActionPreference = "Continue"
$host.UI.RawUI.WindowTitle = "FunFunPod"

# ── Config ──────────────────────────────────────────────────────────
$POD_ID  = "lu82dw2kr8nuuj"
$API_KEY = "crude_moccasin_mole"
$EMAIL   = "eruilu22@gmail.com"
$PW      = $env:ParsecPW
$SSHKEY  = "$env:USERPROFILE\.ssh\id_ed25519"

function GetEnv($n) {
    $v = [Environment]::GetEnvironmentVariable($n, "User")
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($n, "Machine") }
    return $v
}
$B2_ID  = GetEnv "B2 FunFun keyID"
$B2_KEY = GetEnv "B2 applicationKey"

function W($m, $c="Cyan") { Write-Host ">> $m" -ForegroundColor $c }

# ── Start pod (ignore error if already running) ─────────────────────
W "Starting pod..."
$startQ = '{"query":"mutation{podResume(input:{podId:\"' + $POD_ID + '\",gpuCount:1}){id desiredStatus}}"}'
try {
    Invoke-RestMethod "https://api.runpod.io/graphql?api_key=$API_KEY" `
        -Method POST -ContentType "application/json" -Body $startQ | Out-Null
} catch {}

# ── Poll via REST until SSH port is live ────────────────────────────
W "Waiting for pod..."
$ip = ""; $port = 0; $tries = 0
do {
    Start-Sleep 5
    $tries++
    if ($tries -gt 60) { W "Timed out. Check RunPod dashboard." "Red"; Read-Host; exit 1 }
    try {
        $r = Invoke-RestMethod "https://api.runpod.io/v2/pod/$POD_ID" `
            -Headers @{ Authorization = "Bearer $API_KEY" }
        $pod = $r.data
        if ($pod.desiredStatus -eq "RUNNING" -and $pod.runtime -and $pod.runtime.ports) {
            $sp = $pod.runtime.ports | Where-Object { $_.privatePort -eq 22 } | Select-Object -First 1
            if ($sp) { $ip = $sp.ip; $port = $sp.publicPort }
        }
    } catch {}

    # Fallback: try GraphQL shape
    if (-not $ip) {
        try {
            $pollQ = '{"query":"{pod(input:{podId:\"' + $POD_ID + '\"}){desiredStatus runtime{ports{ip publicPort privatePort}}}}"}'
            $resp = Invoke-RestMethod "https://api.runpod.io/graphql?api_key=$API_KEY" `
                -Method POST -ContentType "application/json" -Body $pollQ
            $pod = $resp.data.pod
            if ($pod.desiredStatus -eq "RUNNING" -and $pod.runtime -and $pod.runtime.ports) {
                $sp = $pod.runtime.ports | Where-Object { $_.privatePort -eq 22 } | Select-Object -First 1
                if ($sp) { $ip = $sp.ip; $port = $sp.publicPort }
            }
        } catch {}
    }
    W "Still waiting... ($tries)"
} while (-not $ip)

W "Pod at ${ip}:${port}"

# ── Build + ship bash setup ─────────────────────────────────────────
$PW_B64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($PW))

$bashScript = @"
#!/bin/bash
set -e
B2_ID='$B2_ID'
B2_KEY='$B2_KEY'
EMAIL='$EMAIL'
PW=`$(printf '%s' '$PW_B64' | base64 -d)
CFG=/root/.config/parsec/config.cfg
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq wget xvfb curl jq python3-pip >/dev/null 2>&1
pip3 install b2 -q >/dev/null 2>&1 || true

mkdir -p /root/.config/parsec

( b2 authorize-account "`$B2_ID" "`$B2_KEY" 2>/dev/null \
  || b2 account authorize "`$B2_ID" "`$B2_KEY" 2>/dev/null ) \
&& ( b2 download-file-by-name FunFun parsec/config.cfg "`$CFG" 2>/dev/null \
     || b2 file download b2://FunFun/parsec/config.cfg "`$CFG" 2>/dev/null ) \
|| true

if [ ! -f /usr/bin/parsecd ]; then
    wget -q https://builds.parsec.app/package/parsec-linux.deb -O /tmp/p.deb
    dpkg -i /tmp/p.deb >/dev/null 2>&1 || apt-get install -f -y -qq >/dev/null 2>&1
fi

if ! grep -q app_session_id "`$CFG" 2>/dev/null; then
    AUTH=`$(curl -sf -X POST https://kessel-api.parsecgaming.com/v1/auth \
        -H 'Content-Type: application/json' \
        -d "{\"email\":\"`$EMAIL\",\"password\":\"`$PW\",\"tfa\":\"\"}")
    SID=`$(echo "`$AUTH" | jq -r '.data.id // empty')
    if [ -z "`$SID" ]; then echo "AUTH_FAILED: `$AUTH" >&2; exit 1; fi
    printf '{"app_host":1,"app_session_id":"%s"}' "`$SID" > "`$CFG"
fi

pkill Xvfb 2>/dev/null || true
pkill parsecd 2>/dev/null || true
sleep 1
Xvfb :99 -screen 0 1920x1080x24 &
sleep 3
DISPLAY=:99 parsecd app_host=1 &
sleep 12

b2 upload-file FunFun "`$CFG" parsec/config.cfg 2>/dev/null || true
echo PARSEC_READY
"@

$tmp = "$env:TEMP\ffsetup_$(Get-Random).sh"
$bashScript | Set-Content $tmp -Encoding Ascii

W "Setting up Parsec on pod..."
$outFile = "$env:TEMP\ffout.txt"
$errFile = "$env:TEMP\fferr.txt"

$sshArgs = @(
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=NUL",
    "-i", $SSHKEY,
    "-p", "$port",
    "root@$ip",
    "bash", "-s"
)

Start-Process ssh `
    -ArgumentList $sshArgs `
    -RedirectStandardInput  $tmp `
    -RedirectStandardOutput $outFile `
    -RedirectStandardError  $errFile `
    -NoNewWindow -Wait -PassThru | Out-Null

$out = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
Remove-Item $tmp -ErrorAction SilentlyContinue

if ($out -match "AUTH_FAILED") {
    W "Parsec auth failed. Check ParsecPW env var." "Red"
    Write-Host $out
    Read-Host "Press Enter to exit"; exit 1
}

W "Launching Parsec!" "Green"
Start-Process "C:\Program Files\Parsec\parsecd.exe"
Start-Sleep 3
W "Hit Reload in Parsec. Your pod appears under My Computers." "Green"
Start-Sleep 5
