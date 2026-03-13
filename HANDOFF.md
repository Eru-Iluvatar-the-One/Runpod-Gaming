# HANDOFF — Runpod-Gaming
_Trigger: `BARAHIR HANDOFF runpod-gaming`_

## Identity
Station IV. MCP active: filesystem, github, memory, terminal, Claude-in-Chrome. Win10 LTSC client.

## Current Status: Session 4 — MOONLIGHT CONNECTED, RunPod abandoned

### What worked (session 4)
- libstdc++ upgraded via conda-forge (6.0.33) → fixed segfault on stream start
- `hevc_mode=1` in sunshine.conf → disables 10-bit HEVC path → fixes `cuda_t AV_PIX_FMT_NV12` segfault mid-stream
- h264_nvenc + hevc_nvenc both detected and working
- Tailscale running, Moonlight paired to FunFunPod
- **Moonlight DID connect and stream** (black screen with dialog, "slow connection" warning)
- Root cause of slow connection: **RunPod blocks inbound UDP at network level** → Tailscale forced through DERP relay (Toronto, 45-50ms)
- DERP = TCP tunnel = no raw UDP = bitrate cap ~20Mbps = useless for 4K@144Hz

### Why RunPod is a dead end
RunPod containers do not allow inbound UDP. Tailscale `tailscale ping` shows `via DERP(tor)` permanently. No workaround exists short of RunPod bare metal (not available on consumer). Moonlight streams video over UDP — without direct UDP path, 4K@144Hz is impossible.

### Next provider requirements
- **Must have**: Open inbound UDP (47998-48010)
- **Must have**: NVIDIA GPU with NVENC (RTX 3090/4090/A5000+)
- **Must have**: Near Denver (sub-30ms preferred)
- **Good options**: Vast.ai (filter Denver/US, RTX 4090), Lambda Labs, TensorDock Denver nodes
- **Verify before committing**: SSH in, run `nc -u -l 48000` + test from Windows that UDP gets through

### setup.sh v14 changes
- Added `hevc_mode=1` + `hevc_register=true` to sunshine.conf (8-bit only, no 10-bit HEVC crash)
- Added conda-forge libstdc++ install + symlink step (fixes segfault)
- Added Tailscale install step (was manual before)
- Bumped to v14

## Repo
`https://github.com/Eru-Iluvatar-the-One/Runpod-Gaming`

## Run command (always use this)
```bash
python3 -c "import urllib.request; open('/tmp/s.sh','wb').write(urllib.request.urlopen('https://raw.githubusercontent.com/Eru-Iluvatar-the-One/Runpod-Gaming/main/setup.sh').read())" && /bin/bash /tmp/s.sh
```

## First actions next session
1. Pick new provider with open UDP near Denver
2. SSH in, verify UDP: `nc -u -l 48000` then from Windows `ncat -u <ip> 48000`
3. Run setup.sh
4. Tailscale up with authkey
5. Moonlight connect — expect direct path this time

## PowerShell tunnel (fallback if no Tailscale)
```powershell
ssh -N `
  -L 47984:localhost:47984 `
  -L 47989:localhost:47989 `
  -L 47990:localhost:47990 `
  -L 47998:localhost:47998 `
  -L 47999:localhost:47999 `
  -L 48000:localhost:48000 `
  -L 48010:localhost:48010 `
  root@<<<POD_IP>>> -p <<<SSH_PORT>>> -o StrictHostKeyChecking=no
```
Moonlight → Add PC → 127.0.0.1  
Web UI → https://127.0.0.1:47990 (admin / gondolin123)

---

## Full bug history
- v1: `set -e` + exec sudo = silent exit
- v2: LOG_DIR=/var/log (read-only)
- v3: `exec &> >(tee ...)` silent death in bash <(wget) context
- v4: wget not in image
- v5: curl not in image, bash not at /usr/bin/bash
- v6: added curl/wget step 0
- v7: dpkg-deb -x sunshine.deb clobbered /bin/sh + coreutils
- v8: staged extraction fixed clobber; wrong DRI paths + missing libayatana
- v9: DRI auto-detect + modesetting xorg — card4 permission denied; libayatana still missing (dpkg poison blocked apt)
- v10: Xvfb + dpkg purge + individual dep installs + binary-only sunshine extraction
- v10→v11: stale X lock, stale supervisor configs, missing libva2, chk() bug
- v11→v12: sunshine running but segfaulting on stream — libstdc++ too old
- v12→v13: conda-forge libstdc++ 6.0.33 fixed segfault on launch; 10-bit HEVC path still crashing mid-stream
- v13→v14: hevc_mode=1 (8-bit only) fixes mid-stream crash; RunPod UDP blocked → abandoned provider

---

## ⚠️ BARAHIR VIOLATIONS LOG

### Session 1-3 violations: see git history

### Session 4
- No new violations. Station IV identified root cause (UDP/DERP) and recommended provider switch without excessive iteration.
