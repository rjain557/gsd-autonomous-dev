---
type: managed-agent
id: nvidia-deepseek-v4-pro-agent
status: Proposed
source_url: https://build.nvidia.com/deepseek-ai/deepseek-v4-pro
source_access: fetched-limited-2026-04-27
owned_upgrade: v7.0-extended-model-pool
activation: model-probe, monthly-feature-check
---

# NVIDIA DeepSeek V4 Pro Agent

## Purpose

Track NVIDIA NIM hosting for DeepSeek V4 Pro as a separate routing lane from DeepSeek's direct API.

## V7 Additions

- Keep the NIM model probe in V7 even now that DeepSeek direct API is available.
- Treat NIM as a hosting/provider lane with separate quotas, auth, latency, and failure modes.
- Prefer direct DeepSeek for official model behavior when available; fall back to NIM when it is cheaper, faster, or more reliable on the operator workstation.
- 2026-04-27 authenticated probe confirmed the vault NVIDIA key works against `https://integrate.api.nvidia.com/v1/models`; the endpoint returned 136 model ids.
- 2026-04-27 smoke test confirmed `deepseek-ai/deepseek-v4-flash` chat completions work with `max_tokens=8`.

## Operating Contract

1. Probe `deepseek-ai/deepseek-v4-pro` through NVIDIA before adding it to an active routing pool.
2. Record max token behavior, RPM, auth errors, and schema quirks separately from direct DeepSeek.
3. Keep `NVIDIA_API_KEY` handling isolated from `DEEPSEEK_API_KEY`.

## Acceptance Criteria

- V7 can distinguish model identity from hosting provider.
- A NIM outage or quota cap gracefully falls back without disabling direct DeepSeek V4.
- V7 treats NIM as free for prototype/evaluation use only; production customer workloads require NVIDIA AI Enterprise licensing.
