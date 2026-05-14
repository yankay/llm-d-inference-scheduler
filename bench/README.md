# Bench harness (EPP request-path TTFT)

This directory holds reproducibility tooling for **Endpoint Picker (EPP)** time-to-first-token (TTFT)
regressions on **large OpenAI-style completion bodies** (~220 KB prompt), aligned with the analysis in
[kubernetes-sigs/gateway-api-inference-extension#2928](https://github.com/kubernetes-sigs/gateway-api-inference-extension/issues/2928).

The EPP implementation now lives in **llm-d-router** (`pkg/epp/...`). See:

- [`pure-router/README.md`](pure-router/README.md) — full scenario (KIND + Gateway API + Istio + InferencePool chart + `llm-d-inference-sim`).
- [`pure-router/repro.sh`](pure-router/repro.sh) — one-shot cluster bring-up + concurrency sweep + steady-state profiles (written under `pure-router/out/`, gitignored).
- [`pure-router/stable-1s.sh`](pure-router/stable-1s.sh) — stable TTFT gate (median-of-round-means vs threshold).
- [`http-bench/`](http-bench/) — small Go load generator (streaming completions, TTFT stats).
