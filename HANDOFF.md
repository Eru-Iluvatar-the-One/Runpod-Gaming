# HANDOFF — FunFunPod Neko Edition

**Trigger:** `BARAHIR HANDOFF runpod-gaming`

## Architecture (current)

- **Stack:** Neko (m1k1o/neko) + NVENC + Steam + Proton
- **Transport:** WebRTC over TCP mux — single port `8080/http`
- **Access:** Browser → `https://<POD_ID>-8080.proxy.runpod.net`
- **No UDP. No tunnels. No client software.**

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Build the pod image — Neko NVENC + Steam + Proton |
| `neko-init.sh` | First-boot: symlinks Steam/saves to `/workspace` network volume |
| `FunFunConnect.ps1` | Windows one-click: starts pod, waits, opens browser |
| `build-and-push.ps1` | One-time: build and push Docker image to registry |

## Env Vars Required (Windows)

| Var | Value |
|---|---|
| `FunFunPod` | RunPod API key |
| `FunFunPodID` | RunPod pod ID |

## RunPod Pod Settings

- Container image: `eruilu/funfunpod:latest`
- Expose port: `8080` as HTTP
- Network volume: attached, mounted at `/workspace`
- GPU: RTX 4000 Ada / A4000 or better (NVENC required)

## First-Time Setup (inside browser, after pod starts)

1. Open terminal in Xfce desktop
2. Run `steam` — log in, install Total War: Three Kingdoms
3. Set Proton compatibility version in Steam settings
4. Launch game once to generate compatdata, then it's saved to `/workspace`

## Neko Credentials

- Admin: `admin` / `admin`
- Viewer: `neko` / `neko`

## What Failed Before (DO NOT RETRY)

- Moonlight/Sunshine — requires UDP, RunPod blocks it
- Chisel — Windows Defender flags as HackTool
- Tailscale/boringtun — no TUN device in unprivileged containers
- Parsec — no Linux hosting on consumer accounts
- Vast.ai + Moonlight — open UDP but driver instability killed it

## BARAHIR: Arena Escalation Rule

If any task hits 3 unresolved iterations → escalate to Arena.AI immediately.
