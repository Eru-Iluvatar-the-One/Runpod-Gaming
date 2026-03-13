param()
$ErrorActionPreference = "Continue"
$host.UI.RawUI.WindowTitle = "FunFunPod"

$POD_ID = "lu82dw2kr8nuuj"
$EMAIL  = "eruilu22@gmail.com"
$SSHKEY = "$env:USERPROFILE\.ssh\id_ed25519"

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

# ── Resume pod ──────────────────────────────────────────────────────
W "Starting pod..."
$startQ = '{"query":"mutation{podResume(input:{podId:\"' + $POD_ID + '\",gpuCount:1}){id desiredStatus}}"}'
try { Invoke-RestMethod "https://api.runpod.io/graphql?api_key=$API_KEY" -Method POST -ContentType "application/json" -Body $startQ | Out-Null } catch {}

# ── Poll GraphQL for SSH port ───────────────────────────────────────
W "Waiting for pod SSH port..."
$ip = ""; $port = 0; $tries = 0
do {
    Start-Sleep 5; $tries++
    if ($tries -gt 60) { W "Timed out." "Red"; Read-Host; exit 1 }
    try {
        $q = '{"query":"{myself{pods{id desiredStatus runtime{ports{ip publicPort privatePort}}}}}"}'
        $r = Invoke-RestMethod "https://api.runpod.io/graphql?api_key=$API_KEY" -Method POST -ContentType "application/json" -Body $q
        $pod = $r.data.myself.pods | Where-Object { $_.id -eq $POD_ID } | Select-Object -First 1
        if ($pod -and $pod.desiredStatus -eq "RUNNING" -and $pod.runtime -and $pod.runtime.ports) {
            $sp = $pod.runtime.ports | Where-Object { $_.privatePort -eq 22 } | Select-Object -First 1
            if ($sp) { $ip = $sp.ip; $port = $sp.publicPort }
        }
    } catch {}
    W "Waiting... ($tries)"
} while (-not $ip)

W "SSH at ${ip}:${port} — pushing Parsec setup..."

# ── Bash payload ────────────────────────────────────────────────────
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
b2 upload-file FunFun "`$CFG" parsec/config.cfg 2>/dev/null || true
echo PARSEC_READY
"@

$tmp = "$env:TEMP\ff_$(Get-Random).sh"
$bash | Set-Content $tmp -Encoding Ascii
$out = "$env:TEMP\ffout.txt"
$err = "$env:TEMP\fferr.txt"

Start-Process ssh -ArgumentList @("-o","StrictHostKeyChecking=no","-o","UserKnownHostsFile=NUL","-i",$SSHKEY,"-p","$port","root@$ip","bash","-s") `
    -RedirectStandardInput $tmp -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -Wait | Out-Null

$result = Get-Content $out -Raw -ErrorAction SilentlyContinue
Remove-Item $tmp -ErrorAction SilentlyContinue

if ($result -match "AUTH_FAILED") { W "Parsec auth failed — check ParsecPW." "Red"; Write-Host $result; Read-Host; exit 1 }

W "Done! Launching Parsec..." "Green"
Start-Process "C:\Program Files\Parsec\parsecd.exe"
Start-Sleep 4
W "Hit Reload in Parsec. Pod shows under My Computers." "Green"
Start-Sleep 5
