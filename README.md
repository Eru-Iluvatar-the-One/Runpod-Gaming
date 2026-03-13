# runpod-gaming-rig

One-shot RunPod cloud gaming setup. NVIDIA L4/L40 → Sunshine → Moonlight → 4K@144Hz.

## Usage

```bash
# On your RunPod pod (Jupyter terminal or SSH):

# Optional: set B2 creds before running
export B2_KEY_ID="your-keyid"
export B2_APP_KEY="your-appkey"

# Run
bash <(wget -qO- https://raw.githubusercontent.com/Eru-Iluvatar-the-One/runpod-gaming-rig/main/setup.sh)
```

Or paste `setup.sh` contents directly.

## What it does

| Step | Action |
|------|--------|
| SSH | root:gondolin123, PasswordAuthentication yes, PermitRootLogin yes |
| GPU | Auto-detects BusID via nvidia-smi |
| EXDEV fix | `apt-get download` + `dpkg-deb -x` — never calls `dpkg -i` |
| /dev/dri | mknod card0 (226:0) + renderD128 (226:128) |
| libnvidia-encode | Finds versioned .so, symlinks to /usr/lib/x86_64-linux-gnu/ |
| Xorg | Headless, 3840x2160@144 custom modeline, CVT timing |
| Sunshine | capture=x11, encoder=nvenc, localhost-only |
| Assets | .save + .pack from /workspace → Feral + Proton paths |
| B2 sync | rclone push every 15min (if creds provided) |
| Persistence | supervisord via pip — survives Jupyter terminal close |

## Windows 10 LTSC — SSH Tunnel

```powershell
ssh -N `
  -L 47984:localhost:47984 `
  -L 47989:localhost:47989 `
  -L 47990:localhost:47990 `
  -L 48010:localhost:48010 `
  root@66.92.198.162 -p 11717 `
  -o StrictHostKeyChecking=no `
  -o ServerAliveInterval=60 `
  -o ServerAliveCountMax=10
```

Then Moonlight → Add PC → `127.0.0.1`

**UDP caveat:** SSH tunnels TCP only. Moonlight video/audio uses UDP 47998-48000.  
Options: Tailscale (easiest), RunPod exposed UDP ports, or Moonlight Force TCP mode.

## B2 Persistence

```
Bucket  : Funfun
Endpoint: s3.us-east-005.backblazeb2.com
Saves   : b2funfun:Funfun/saves/
Packs   : b2funfun:Funfun/packs/
```

Manual sync: `/usr/local/bin/b2-sync.sh`

## Logs

```
/var/log/gaming/setup.log
/var/log/gaming/xorg.log
/var/log/gaming/sunshine.log
/var/log/gaming/supervisord.log
/var/log/gaming/b2-sync.log
```

## Troubleshoot

```bash
supervisorctl status           # service health
tail -f /var/log/gaming/xorg.log
tail -f /var/log/gaming/sunshine.log
DISPLAY=:99 xrandr             # verify display
nvidia-smi                     # GPU alive
ls -la /dev/dri                # encoder nodes
```
