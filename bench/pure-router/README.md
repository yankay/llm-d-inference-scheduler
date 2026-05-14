# EPP large-input perf repro — llm-d-router

Companion benchmark originally derived from `bench/pure-gie/` in
[`yankay/gateway-api-inference-extension@bench`](https://github.com/yankay/gateway-api-inference-extension/tree/bench/bench/pure-gie),
adapted so the **Endpoint Picker is the llm-d-router EPP** deployed from this repository’s
[`config/charts/inferencepool`](../../config/charts/inferencepool) Helm chart.

This scenario isolates **EPP request-path cost** (body buffering, JSON parse/marshal, prefix hashing,
datalayer metrics ingestion) by using [`llm-d-inference-sim`](https://github.com/llm-d/llm-d-inference-sim)
as a near-instant OpenAI-compatible backend.

Related upstream discussion: [kubernetes-sigs/gateway-api-inference-extension#2928](https://github.com/kubernetes-sigs/gateway-api-inference-extension/issues/2928).

## Stack under test

| Component | Version / source |
|-----------|------------------|
| Kubernetes | kind (default `kindest/node:v1.31.0`) |
| Gateway API | `v1.2.1` standard channel CRDs |
| Inference extension CRDs | [`config/crd/bases/`](../../config/crd/bases/) applied directly by `repro.sh` (avoids kustomize git fetch to GitHub) |
| Gateway | Istio `1.28.x` with `ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true` |
| InferencePool + EPP | Helm chart [`config/charts/inferencepool`](../../config/charts/inferencepool), `provider.name=istio` |
| EPP image (default) | `ghcr.io/llm-d/llm-d-inference-scheduler:v0.8.0` (override with `EPP_*`; use `BUILD_LOCAL_EPP=1` to build from this repo) |
| Model server | `ghcr.io/llm-d/llm-d-inference-sim:v0.8.2` × 4, `--max-model-len=65536` |
| Load tool | [`../http-bench`](../http-bench) (streaming `/v1/completions`, TTFT) |

Default Helm values keep the shipped **`default-plugins.yaml`** (`approx-prefix-cache-producer`, prefix /
KV / queue scorers, etc.) unless you override `pluginsCustomConfig`.

## Layout

```
pure-router/
  README.md           this file
  repro.sh            KIND + Istio + chart + sim + sweep + profiles under ./out/
  stable-1s.sh        stable TTFT gate (warmup + rounds + median + threshold)
  manifests/
    sim-deployment.yaml
    gateway-route.yaml
  results/            checked-in text snapshots from the maintainer run
  UPSTREAM-ISSUE.md   draft GitHub issue body for llm-d/llm-d-router
```

## One-shot repro

```bash
bench/pure-router/repro.sh
```

Environment knobs:

| Variable | Meaning |
|----------|---------|
| `CLUSTER` | KIND cluster name (default `router-bench`) |
| `IMAGE_MIRROR_PREFIX` | e.g. `m.daocloud.io/` pull-through prefix for `docker pull` / kind preload |
| `BUILD_LOCAL_EPP=1` | `docker build` from [`Dockerfile.epp`](../../Dockerfile.epp) and load into kind |
| `EPP_REGISTRY` / `EPP_REPOSITORY` / `EPP_TAG` | Pin the EPP image |
| `SIM_IMAGE` | Override inference-sim image |
| `SOURCE_PROXY=0` | Skip sourcing `/root/proxy.sh` |

## Stable TTFT gate (`stable-1s.sh`)

After `repro.sh`:

```bash
cd bench/pure-router
./stable-1s.sh
```

On fast hosts:

```bash
CONCURRENCY=1200 WARMUP_REQS=300 ROUND_REQS=1500 ROUNDS=3 THRESHOLD_MS=1100 ./stable-1s.sh
```

Exit codes: `0` median ≥ threshold (repro confirmed), `1` below threshold (expected after a successful fix), `2` connectivity, `3` parse error.

## Hot paths (for ~220 KB bodies)

| Area | Location |
|------|----------|
| Request body chunks appended without pre-sizing | [`pkg/epp/handlers/server.go`](../../pkg/epp/handlers/server.go) |
| OpenAI JSON parsing | [`pkg/epp/framework/plugins/requesthandling/parsers/openai/openai.go`](../../pkg/epp/framework/plugins/requesthandling/parsers/openai/openai.go) |
| Director re-marshal | [`pkg/epp/requestcontrol/director.go`](../../pkg/epp/requestcontrol/director.go) |
| Approximate prefix hashing | [`pkg/epp/framework/plugins/requestcontrol/dataproducer/approximateprefix/hashing.go`](../../pkg/epp/framework/plugins/requestcontrol/dataproducer/approximateprefix/hashing.go) |
| Datalayer Prometheus scrape / parsing | [`pkg/epp/datalayer/metrics/collector.go`](../../pkg/epp/datalayer/metrics/collector.go) |

## Measured on this host

See [`results/`](results/) for raw text artifacts. This run used `CLUSTER=router-bench-repro` and `IMAGE_MIRROR_PREFIX=m.daocloud.io/`.

| Field | Value |
|-------|-------|
| Date (UTC) | 2026-05-14 |
| Host | 24 logical CPUs, Linux `6.8.0-111-generic` |
| Commit | `f6e6e18d232ffa104bcf9d499bb9d59d59502ad8` |
| EPP image | `ghcr.io/llm-d/llm-d-inference-scheduler:v0.8.0` (`sha256:465fe24209153fa227bd97513259da62fc699a046df99cecd5fed39d16341eed`) |
| Backend | 4x `ghcr.io/llm-d/llm-d-inference-sim:v0.8.2`, `--max-model-len=65536` |

### TTFT vs concurrency

220 KB prompt, streaming `/v1/completions`, near-instant simulator backend:

| Concurrency | TTFT mean | TTFT P50 | TTFT P99 | Throughput |
|---:|---:|---:|---:|---:|
| 20 | 153.84 ms | 152.62 ms | 221.73 ms | 121.74 req/s |
| 60 | 426.15 ms | 442.48 ms | 496.03 ms | 132.32 req/s |
| 100 | 724.27 ms | 764.72 ms | 815.23 ms | 129.44 req/s |
| 150 | 1095.71 ms | 1144.54 ms | 1239.49 ms | 128.71 req/s |
| 200 | 1452.77 ms | 1516.71 ms | 1635.23 ms | 129.16 req/s |

A longer steady c=150 run (`results/c150-steady-30s.txt`) produced mean TTFT `1151.02 ms`, P50 `1167.11 ms`, P99 `1277.72 ms`, and `127.96 req/s` throughput.

### Stable TTFT gate

`CONCURRENCY=1200 WARMUP_REQS=300 ROUND_REQS=1500 ROUNDS=3 THRESHOLD_MS=1100 ./stable-1s.sh`:

```text
per_round_ttft_mean_ms: 4701.59 4327.51 4555.61
median_ttft_mean_ms: 4555.61
PASS: median TTFT mean 4555.61 ms >= threshold 1100 ms
```

### EPP metrics

From `results/epp-metrics-steady.txt` after the c=150 steady run:

| Metric | Average per request |
|--------|---------------------|
| `inference_objective_request_duration_seconds` | 1087.58 ms |
| `inference_extension_scheduler_e2e_duration_seconds` | 28.21 us |
| Sum of `inference_extension_plugin_duration_seconds` | 13.17 us |

The scheduler and plugin totals are orders of magnitude smaller than request duration, so the extra TTFT is in request-path processing, not in endpoint selection itself.

### Allocation profile

Top of `go tool pprof -top -cum -nodecount=30` from `results/allocs-c150-steady.top30.txt`:

```text
3141.08MB 25.79%  9550.06MB 78.42%  .../pkg/epp/handlers.(*StreamingServer).Process
   2.00MB 0.016%  3863.05MB 31.72%  .../pkg/epp/requestcontrol.(*Director).HandleRequest
  44.01MB  0.36%  2372.07MB 19.48%  encoding/json.Unmarshal
       0      0%   2303.56MB 18.92%  .../parsers/openai.(*OpenAIParser).ParseRequest
2295.06MB 18.85%  2296.56MB 18.86%  encoding/json.(*decodeState).literalStore
       0      0%   1864.18MB 15.31%  .../approximateprefix.(*prepareData).PrepareRequestData
       0      0%   1495.98MB 12.28%  .../requestcontrol.(*Director).repackage
1174.24MB  9.64%  1495.48MB 12.28%  encoding/json.Marshal
```
