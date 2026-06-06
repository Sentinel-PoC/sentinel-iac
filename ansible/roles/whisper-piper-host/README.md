# whisper-piper-host — Wyoming Voice Services on pve4 GPU

**OPS-586 Section B** — Whisper STT + Piper TTS on pve4 Alienware GPU LXC

---

## Privacy Posture

> **No audio leaves the LAN. All STT/TTS processing runs on pve4 GPU LXC (192.168.12.80).**

- Whisper (speech-to-text) runs the `turbo` model on NVIDIA RTX 3060 inside ai-tier1 LXC.
- Piper (text-to-speech) runs CPU-mode inside the same LXC.
- No cloud STT/TTS services are used. Microphone audio is processed exclusively on local hardware.
- Models are downloaded from HuggingFace/rhasspy on first run, then cached at `/opt/wyoming/`.

---

## Architecture

```
Phone/browser mic
    │ (audio)
    ▼
HA Container (LXC 201, 192.168.12.81) — HA Assist pipeline
    │ Wyoming protocol (TCP)
    ├──► wyoming-whisper (LXC 200, 192.168.12.80:10300) — RTX 3060 GPU
    │        faster-whisper "turbo" model → transcript text
    │
    └──► wyoming-piper (LXC 200, 192.168.12.80:10200) — CPU
             en_US-ryan-high voice → TTS audio

    Optional conversation (LLM):
    └──► Ollama (LXC 200, 192.168.12.80:11434) — llama3.2:3b
```

### Why Container mode requires standalone Wyoming containers

HA is deployed as **Container mode** (Docker on LXC 201) — NOT Supervised/HA OS.
The HA add-on store requires the Supervisor layer, which is only available in Supervised/HA OS.
Standalone `rhasspy/wyoming-*` Docker containers provide identical Wyoming protocol endpoints
and are the documented approach for non-Supervised deployments.

---

## Voice Selection Rationale

**Selected voice: `en_US-ryan-high`**

| Voice | Quality | Gender | Notes |
|-------|---------|--------|-------|
| `en_US-ryan-high` ✓ | High (22.05KHz) | Male | Warm, professional, grounded. Haists IT Consulting tone. |
| `en_US-lessac-medium` | Medium | Male | HA add-on default. Competent but flat/neutral. |
| `en_US-joe-medium` | Medium | Male | Casual/conversational. Less professional. |
| `en_US-kristin-medium` | Medium | Female | Warm female alternative. Good option if preferred. |
| `en_GB-cori-high` | High (22.05KHz) | Female | British English, very high quality. Distinct brand voice option. |

"High" quality = 22.05KHz generation; slowest but best output. On pve4 hardware (8-core AMD
5900x, 64GB RAM), Piper TTS at "high" quality generates sub-second responses for typical
voice command responses (< 100 words). GPU is not used for Piper (inference is fast enough on CPU).

To change voice after deployment, update `wyoming_piper_voice` and re-run the role.
Piper downloads new voices automatically on startup.

---

## Upstream References

| Component | URL | Relevant section |
|-----------|-----|------------------|
| Whisper add-on docs | [DOCS.md](https://raw.githubusercontent.com/home-assistant/addons/master/whisper/DOCS.md) | Model options, beam_size, Wyoming discovery |
| Piper add-on docs | [DOCS.md](https://raw.githubusercontent.com/home-assistant/addons/master/piper/DOCS.md) | Voice naming scheme, quality levels |
| HA Assist Pipeline | [home-assistant.io](https://www.home-assistant.io/integrations/assist_pipeline/) | Pipeline creation via UI |
| HA Wyoming integration | [home-assistant.io](https://www.home-assistant.io/integrations/wyoming/) | Manual host+port setup for standalone servers |
| Piper voice samples | [rhasspy.github.io](https://rhasspy.github.io/piper-samples/) | Listen before changing voice |
| wyoming-faster-whisper | [GitHub](https://github.com/rhasspy/wyoming-faster-whisper) | Docker image, GPU flags |
| wyoming-piper | [GitHub](https://github.com/rhasspy/wyoming-piper) | Docker image, voice args |

---

## Role Variables

See `defaults/main.yml` for full documentation. Key variables:

| Variable | Default | Notes |
|----------|---------|-------|
| `whisper_piper_lxc_id` | `200` | ai-tier1 LXC VMID (from OPS-564) |
| `whisper_piper_lxc_ip` | `192.168.12.80` | ai-tier1 LXC IP |
| `wyoming_whisper_model` | `turbo` | Whisper model. RTX 3060 can run `turbo` or `large-v3`. |
| `wyoming_whisper_language` | `en` | Language hint. Set to `auto` for multi-language. |
| `wyoming_piper_voice` | `en_US-ryan-high` | Piper voice. See voice selection table above. |
| `wyoming_piper_length_scale` | `1.0` | Speaking rate (< 1.0 faster, > 1.0 slower). |
| `whisper_piper_enabled` | `true` | Set `false` to skip role entirely. |

---

## Operator Post-Deploy Steps (HA UI)

**These steps must be completed in the HA web UI after Ansible deploys the containers.**
The Wyoming integration and Assist Pipeline cannot be fully automated without HA Supervisor.

### Step 1: Add Wyoming STT (Whisper)

1. In HA, go to **Settings → Devices & Services → Add Integration**
2. Search for **"Wyoming Protocol"**
3. Enter: Host `192.168.12.80`, Port `10300`
4. Name it **"Whisper (pve4 GPU)"**
5. Select as STT provider: the integration creates a `Wyoming Speech-to-text` entity

### Step 2: Add Wyoming TTS (Piper)

1. Repeat **Add Integration → Wyoming Protocol**
2. Enter: Host `192.168.12.80`, Port `10200`
3. Name it **"Piper (en_US-ryan-high)"**
4. Piper becomes available as a TTS provider

### Step 3: Create Assist Pipeline

1. Go to **Settings → Voice Assistants → Add Pipeline**
2. Name: **"Haists Voice (local)"**
3. Speech-to-text: **Wyoming — Whisper (pve4 GPU)**
4. Text-to-speech: **Wyoming — Piper (en_US-ryan-high)**
5. Conversation agent: **Home Assistant** (default) or **Ollama** (see Step 4)
6. Wake word: optional — configure per your hardware

### Step 4: (Optional) Ollama Conversation Agent

If you want "Hey Haists, what's the security state?" style natural language:

1. **Settings → Devices & Services → Add Integration → Ollama**
2. Host: `192.168.12.80`, Port: `11434`
3. Model: `llama3.2:3b` (already pulled by OPS-564)
4. In the Assist Pipeline, select this Ollama integration as the **Conversation agent**

Note: `llama3.2:3b` is a small/fast model good for HA command understanding. Larger models
(e.g., `llama3.1:8b`) provide better intent parsing but need to be pulled first via Ollama.

### Step 5: E2E Verification Recipe (Operator Scope)

**After HA UI setup, test with:**
1. Open the HA app on your phone
2. Tap the microphone / Assist button
3. Select pipeline **"Haists Voice (local)"**
4. Say: **"Turn on the office light"**
5. Expected: HA processes via Whisper STT → intent match → light turns on → Piper TTS confirms

This test requires a Z-Wave/Zigbee bulb already paired and a light entity created in HA.
The STT→intent→TTS path works without a paired device; only the action step requires hardware.

---

## Deployment

Role targets `pve4-alienware` hosts. Add to your playbook:

```yaml
- hosts: pve4-alienware
  roles:
    - pve4-nvidia-gpu   # OPS-564 — must run first (creates ai-tier1 LXC with GPU)
    - whisper-piper-host  # OPS-586 Section B — this role
```

Or run standalone (assuming ai-tier1 LXC already exists from OPS-564):

```bash
ansible-playbook site.yml --limit pve4-alienware --tags whisper-piper
```

---

## Troubleshooting

**Whisper container exits immediately:**
Check model download space. `turbo` model needs ~2GB in `/opt/wyoming/whisper-data/`.
```bash
pct exec 200 -- docker logs wyoming-whisper --tail=50
```

**GPU not found in Whisper container:**
Verify NVIDIA devices are accessible in the LXC:
```bash
pct exec 200 -- ls /dev/nvidia*
pct exec 200 -- docker exec wyoming-whisper nvidia-smi
```
If `ls /dev/nvidia*` shows devices but Docker can't see them, check Docker daemon runtime config:
```bash
pct exec 200 -- cat /etc/docker/daemon.json
```
Should contain `"runtimes": {"nvidia": {...}}`.

**Piper voice not loading:**
Piper downloads voices from HuggingFace on first use. Check internet connectivity from ai-tier1:
```bash
pct exec 200 -- curl -s https://huggingface.co > /dev/null && echo "OK"
```

**HA can't reach Wyoming services:**
Verify ports are listening from inside ai-tier1:
```bash
pct exec 200 -- nc -z 127.0.0.1 10300 && echo "Whisper OK"
pct exec 200 -- nc -z 127.0.0.1 10200 && echo "Piper OK"
```
Verify from management network (iac-control):
```bash
nc -z 192.168.12.80 10300 && echo "Whisper reachable from network"
```
