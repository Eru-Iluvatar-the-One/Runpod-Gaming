# ARENA.AI HANDOFF — RunPod Game Streaming via Moonlight/Sunshine
**Date:** 2026-03-13 (Updated end of Session 2)
**Trigger Phrase:** "RUNPOD STREAMING HANDOFF — pick up from the UDP tunnel failure. Read BARAHIR/ARENA-HANDOFF-RUNPOD-UDP-2026-03-13.md and BARAHIR/SESSION-2-VIOLATIONS-2026-03-13.md fully before responding."

---

## PROBLEM STATEMENT
Stream games from a RunPod GPU pod (RTX A5000) to a Windows 10 LTSC PC using Sunshine (server) + Moonlight (client). The core blocker: Moonlight requires UDP ports 47998/47999/48000 but RunPod only exposes TCP ports.

## CURRENT STATE (as of Session 2 end)
- **Pod:** RunPod, RTX A5000, `runpod-torch-v240` template
- **Pod IP:** `203.57.40.247` (changes on restart — UPDATE THIS)
- **SSH:** `ssh root@203.57.40.247 -p 10282`
- **Auth:** password `gondolin123` OR SSH key if added to RunPod settings
- **UDP outbound FROM pod works:** `bash -c 'echo "test" > /dev/udp/8.8.8.8/53'` returns OK
- **UDP inbound TO pod is blocked:** RunPod only proxies TCP via their `Direct TCP ports` feature
- **Sunshine:** NOT confirmed installed on current pod instance
- **Moonlight version on PC:** Does NOT have "Force TCP" option

## WHAT FAILED — DO NOT REPEAT THESE
| # | Approach | Why it failed |
|---|----------|---------------|
| 1 | **chisel** (TCP↔UDP tunnel) | Windows Defender flags as `HackTool:Win64/Chisel!MTB` HIGH. User will NOT add exclusions. **BANNED.** |
| 2 | **plink.exe** password auth | "Configured password was not accepted" |
| 3 | **SSH -L + "Force TCP" in Moonlight** | `ssh -L` only forwards TCP. Moonlight does NOT have a "Force TCP" toggle. **Feature was hallucinated.** |
| 4 | **udp2raw / any tool Defender flags** | Same class of problem as chisel. If Defender will flag it, it's dead. |

## HARD CONSTRAINTS
- **No TUN device** (unprivileged container)
- **No CAP_NET_ADMIN**
- **No iptables/nftables**
- **Windows Defender ON, zero exclusions allowed**
- **No hack tools** — if Defender flags it, it's banned
- **One-click .bat file** — user double-clicks, it works. Zero manual steps after first-time SSH key setup.
- **User SSH key:** `%USERPROFILE%\.ssh\id_ed25519` (may need generation + RunPod settings)

## VIABLE OPTIONS (RESEARCH THESE)

### Option A: RunPod Native UDP Exposure
- Does RunPod support exposing UDP ports? Check docs, API, community.
- If yes → cleanest fix, no tunneling at all.
- **Priority: HIGH — check this first.**

### Option B: Sunshine TCP-only mode
- Sunshine v0.20+ may support streaming over TCP only (no UDP).
- Check `sunshine.conf` for `protocol`, `channels`, `force_tcp`, or similar.
- If available → plain `ssh -L` works for everything.
- **Priority: HIGH.**

### Option C: socat UDP↔TCP bridge
- `socat` is a standard utility, NOT flagged by Defender.
- Pattern:
  - Pod: `socat TCP-LISTEN:X,fork UDP:localhost:47998` (one per UDP port)
  - Windows SSH: `ssh -L X:localhost:X` (forwards the TCP)
  - Windows: `socat UDP-LISTEN:47998,fork TCP:localhost:X` (converts back)
- Need Windows socat build — check if Cygwin socat or standalone .exe is Defender-safe.
- **Priority: MEDIUM — verify Defender compatibility first.**

### Option D: WireGuard-go / BoringTun userspace VPN
- Userspace WireGuard, no TUN needed.
- WireGuard is signed, Defender-friendly.
- Heavier setup but rock-solid.
- **Priority: MEDIUM.**

### Option E: Parsec instead of Moonlight
- Parsec works over TCP natively, no UDP port forwarding.
- Eliminates the entire UDP problem.
- Different client = different latency/quality tradeoffs.
- **Priority: MEDIUM — fallback if A-D all fail.**

## QUESTIONS TO ANSWER
1. Does RunPod expose UDP ports? (Check runpod.io docs, API reference, community/Discord)
2. Does Sunshine have TCP-only streaming? (Check LizardByte/Sunshine GitHub, sunshine.conf docs)
3. Is socat.exe flagged by Windows Defender? (Test or research)
4. Can boringtun run in unprivileged RunPod container?
5. What's Parsec's latency vs Moonlight for this use case?

## REPO
- `Eru-Iluvatar-the-One/Runpod-Gaming`
- Violations log: `BARAHIR/SESSION-2-VIOLATIONS-2026-03-13.md`

## DELIVERABLE
A single `connect.bat` that the user saves to `C:\Users\Eru\connect.bat`, points a shortcut at, and double-clicks. It must:
1. Work with zero third-party downloads that Defender would flag
2. SSH into pod, start Sunshine
3. Establish whatever tunnel/bridge is needed
4. Launch Moonlight configured to connect
5. Require password/key entry at most ONCE

## USER PREFERENCES
- Ship code, not explanations
- One file, one click, one command
- Find the ONE root cause, not 10 possibilities
- Do not come back without a working solution
- Aggressive communicator — wants execution, not discussion
