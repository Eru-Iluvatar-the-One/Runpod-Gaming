# ARENA.AI HANDOFF — RunPod Game Streaming via Moonlight/Sunshine
**Date:** 2026-03-13
**Trigger Phrase:** "RUNPOD STREAMING HANDOFF — pick up from the UDP tunnel failure. Read this doc fully before responding."

---

## PROBLEM STATEMENT
Stream games from a RunPod GPU pod (RTX A5000) to a Windows 10 LTSC PC using Sunshine (server) + Moonlight (client). The core blocker: Moonlight requires UDP ports 47998/47999/48000 but RunPod only exposes TCP ports.

## CURRENT STATE
- **Pod:** RunPod, RTX A5000, `runpod-torch-v240` template
- **Pod IP:** `203.57.40.247` (changes on restart)
- **SSH:** `ssh root@203.57.40.247 -p 10282` (password: `gondolin123`)
- **UDP outbound FROM pod works:** `bash -c 'echo "test" > /dev/udp/8.8.8.8/53'` returns OK
- **UDP inbound TO pod is blocked:** RunPod only proxies TCP via their `Direct TCP ports` feature
- **Sunshine:** NOT confirmed installed on this new pod instance
- **Moonlight:** Installed on Windows PC. Settings screenshot shows NO "Force TCP" option exists in this version.

## WHAT FAILED (DO NOT REPEAT)
1. **chisel** (TCP-to-UDP tunnel tool) — Windows Defender flags it as `HackTool:Win64/Chisel!MTB`, HIGH threat. User will NOT add Defender exclusions. **DO NOT SUGGEST CHISEL.**
2. **plink.exe** — password auth failed with "Configured password was not accepted"
3. **SSH -L for UDP** — `ssh -L` only forwards TCP, not UDP. Moonlight needs UDP. Previous session incorrectly assumed "Force TCP" exists in Moonlight settings — it doesn't.
4. **Multiple sessions of going in circles** asking user to run diagnostic commands instead of shipping a fix.

## CONFIRMED CONSTRAINTS
- No TUN device (unprivileged container)
- No CAP_NET_ADMIN
- No iptables/nftables control
- Windows Defender ON, no exclusions allowed
- User wants ONE double-click .bat file, zero manual steps after first-time SSH key setup
- User SSH key: `%USERPROFILE%\.ssh\id_ed25519` (may need to be generated + added to RunPod)

## VIABLE OPTIONS (NOT YET TRIED)
### Option A: RunPod Native UDP Exposure
- RunPod may support exposing UDP ports natively. Research RunPod docs/API for UDP port exposure.
- If available, this is the cleanest fix — no tunneling needed.

### Option B: Sunshine's built-in TCP-only mode
- Sunshine v0.20+ may have a config option to force all traffic over TCP (no UDP needed).
- Research `sunshine.conf` options: `channels`, `protocol`, or similar.
- If Sunshine can serve everything over TCP, then plain `ssh -L` tunnels work perfectly.

### Option C: socat or SSH-based UDP forwarding
- `socat` can bridge UDP<->TCP without being flagged as a hack tool.
- Pattern: `socat TCP-LISTEN:X,fork UDP:localhost:Y` on pod, `ssh -L` on client, `socat UDP-LISTEN:Y,fork TCP:localhost:X` on Windows.
- socat is NOT flagged by Defender (it's a standard Unix utility, and the Windows build is clean).

### Option D: WireGuard-go / BoringTun (userspace VPN)
- Userspace WireGuard doesn't need TUN — runs as a process.
- WireGuard is signed, Defender-friendly, and handles UDP natively.
- Heavier setup but rock-solid once working.

### Option E: Parsec / Alternative to Moonlight
- Parsec works over TCP natively, no UDP port forwarding needed.
- Would bypass the entire UDP problem.
- Tradeoff: different client, may have different latency/quality characteristics.

## QUESTIONS FOR ARENA.AI SESSION
1. Does Sunshine have a TCP-only streaming mode? Check latest Sunshine docs/GitHub for `sunshine.conf` TCP options.
2. Does RunPod support exposing UDP ports? Check RunPod docs, API, and community forums.
3. Can `socat` on Windows (from the official Cygwin or standalone build) tunnel UDP<->TCP without Defender flags?
4. Is `boringtun` (Cloudflare's userspace WireGuard) viable in an unprivileged RunPod container?
5. Would switching to Parsec eliminate the problem entirely?

## REPO
- GitHub: `Eru-Iluvatar-the-One/Runpod-Gaming`
- Previous session docs committed to `BARAHIR/` directory

## USER PREFERENCES
- One-click .bat file, zero third-party hack tools
- No Defender exclusions
- No multi-step instructions — ship runnable code
- Aggressive, impatient, wants execution not explanation
