# HANDOFF — Runpod-Gaming
_Trigger: `BARAHIR HANDOFF runpod-gaming`_

## Identity
Station IV. MCP active: filesystem, github, memory. Win10 LTSC client.

## Pod
- Host: `66.92.198.162` SSH port `11193`
- GPU: NVIDIA L4, 23034 MiB, driver 570
- BusID: `PCI:36:0:0`
- Image: `runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04`
- Persistent: 150GB `/workspace`
- Pod ID: `by8x28h0ciubu7`

## Repo
`https://github.com/Eru-Iluvatar-the-One/Runpod-Gaming`
Single file: `setup.sh`

## Run command (always use this)
```bash
python3 -c "import urllib.request; open('/tmp/s.sh','wb').write(urllib.request.urlopen('https://raw.githubusercontent.com/Eru-Iluvatar-the-One/Runpod-Gaming/main/setup.sh').read())" && /bin/bash /tmp/s.sh
```

## Current status: v8 ran, 2/7 passed. TWO BUGS REMAIN.

### Bug 1 — Wrong /dev/dri device paths (CRITICAL)
xorg.conf hardcodes `card0` / `renderD128`.
Actual nodes on this pod:
```
/dev/dri/card4        ← real card
/dev/dri/renderD131   ← real render node
```
`mknod` is denied (not privileged). Must auto-detect actual paths.

Fix: at runtime, detect `card*` and `renderD*` under `/dev/dri/` and use those.
```bash
DRI_CARD=$(ls /dev/dri/card* 2>/dev/null | head -1)
DRI_RENDER=$(ls /dev/dri/renderD* 2>/dev/null | head -1)
```
Use `$DRI_RENDER` in sunshine.conf `adapter_name`.
Xorg nvidia driver uses its own `/dev/nvidia*` path — but modesetting fallback
was trying `card0` which doesn't exist → "no screens found".

### Bug 2 — Sunshine missing libayatana-appindicator3.so.1
```
/usr/bin/sunshine: error while loading shared libraries: libayatana-appindicator3.so.1
```
Fix: `apt-get install -y libayatana-appindicator3-1` (or safe_install it).
This is a normal apt package, no EXDEV expected.

### Bug 3 — NVIDIA kernel module init failure in Xorg
```
(EE) NVIDIA: Failed to initialize the NVIDIA kernel module.
```
`/dev/nvidia3`, `/dev/nvidiactl`, `/dev/nvidia-modeset` all exist.
Likely cause: xorg nvidia DDX can't open the device because it's looking
for GPU index 0 but container sees it as index 3. Try adding to xorg.conf Device section:
```
Option "NVidiaCTL" "/dev/nvidiactl"
```
Or force modesetting driver (bypasses NVIDIA DDX entirely):
- Change Driver from "nvidia" to "modesetting"
- Use `card4` explicitly
- Sunshine x11 capture still works with modesetting

## What v9 must do
1. `apt-get install -y libayatana-appindicator3-1` early in packages phase
2. Auto-detect DRI nodes at runtime, use actual paths
3. Try nvidia driver first; if Xorg log shows "Failed to initialize NVIDIA kernel module",
   fall back to modesetting driver with detected card path
4. Set `adapter_name = $DRI_RENDER` (detected) in sunshine.conf
5. All other v8 logic stays (staged Sunshine extraction, pip supervisord, etc.)

## Bug history
- v1: `set -e` + exec sudo = silent exit
- v2: LOG_DIR=/var/log (read-only)
- v3: `exec &> >(tee ...)` silent death in bash <(wget) context
- v4: wget not in image
- v5: curl not in image, bash not at /usr/bin/bash
- v6: added curl/wget step 0
- v7: dpkg-deb -x sunshine.deb / clobbered /bin/sh + coreutils
- v8: staged extraction fixed clobber; but wrong DRI paths + missing libayatana

## PowerShell tunnel (Win10 LTSC)
```powershell
ssh -N `
  -L 47984:localhost:47984 `
  -L 47989:localhost:47989 `
  -L 47990:localhost:47990 `
  -L 48010:localhost:48010 `
  root@66.92.198.162 -p 11193 -o StrictHostKeyChecking=no
```
Moonlight → Add PC → 127.0.0.1
Web UI → https://127.0.0.1:47990 (admin / gondolin123)

## Next action
Push v9 to repo. Run via python3 command above.
