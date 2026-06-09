# Brain-only mode: serving STT/brain without a local mic front-end

**AC7 from `PRD-constellation-voice-role`**

## What this is

A constellation node can *serve* a brain or STT endpoint over the mesh without
running its **own** voice front-end (microphone capture → VAD → wm-stt pipeline).

This distinguishes two orthogonal capabilities:

| Capability | Governed by |
|---|---|
| Local mic front-end (wm-audio → wm-stt → wake/VAD) | `voice_node` flag |
| Serving a brain/STT endpoint to other nodes | Node's brain/dispatch role |

A desktop or cloud node with `voice_node: false` can still accept inference
requests from voice nodes (the laptop) over the mesh — it just never starts
wm-audio or wm-stt locally.

## How it works

The wintermute brain ladder (configured via `WM_BRAIN_SKIP_TIERS` /
`WM_BRAIN_MAX_TIER`) exposes an HTTP brain endpoint that any fleet node can
reach over the Tailscale mesh.

A voice node (laptop) sends its recognised-text turn to the mesh brain by
setting `WM_BRAIN_ENDPOINT=http://<desktop-node>:8765` (or the appropriate
mesh address).

The desktop/cloud node runs `brain-serve` (or the relevant wm-brain daemon) as
part of its dispatch worker role — independently of `voice_node`.

## What is NOT affected by `voice_node: false`

- `agorabus.service` — always up; the coordination bus never goes away.
- Brain ladder / dispatch worker — governed by the node's compute role, not
  `voice_node`.
- Any STT-server endpoint the node exposes to other fleet nodes.

## What IS gated by `voice_node: false`

- `wm-audio.service` — microphone capture + PipeWire routing.
- `wm-stt.service` — local Whisper inference on captured audio.
- `wm-wake.service` — wake-word detector.
- `wm-vad.service` — voice-activity detector.
- The `wintermute.target` pull-in (i3→graphical-session bridge) that starts
  the above units at login.

## Example: Radeon desktop as a brain server, not a voice node

```yaml
# host_vars/wintermute-desktop.yml
voice_node: false   # no mic, no voice front-end
gpu: amd            # serves brain via ROCm / llama.cpp-Vulkan
```

Re-provisioning with this config:
1. Stops + disables wm-audio/wm-stt/wake/VAD.
2. Leaves agorabus and the brain-serve daemon fully up.
3. The laptop can route its brain turns to the desktop over the mesh.

## Summary

The `voice_node` flag is a scalpel: it removes only the microphone front-end.
It has no effect on whether the node answers other nodes' inference turns.
That is a dispatch/brain-role decision, not a voice-role decision.
