<!-- Draft for https://github.com/llm-d/llm-d-router/issues/new — Bug Report template -->

**What happened**:

Long-context OpenAI-compatible streaming completion requests (~220 KB prompt) can incur **more than 1s time-to-first-byte (TTFT)** while traversing the llm-d-router **Endpoint Picker (EPP)** request path, even when the backend model server returns almost instantly.

With `llm-d-inference-sim` as the backend, throughput plateaus around ~128-132 req/s while TTFT keeps growing with concurrency, which points to queueing / CPU pressure inside EPP rather than backend prefill latency.

Reproduction harness:

- Branch/path: `https://github.com/yankay/llm-d-router/tree/bench/bench/pure-router`
- Raw text results: `bench/pure-router/results/sweep.txt`, `bench/pure-router/results/c150-steady-30s.txt`, `bench/pure-router/results/stable-1s-summary.txt`, `bench/pure-router/results/epp-metrics-steady.txt`

Observed TTFT vs concurrency on a KIND host (220 KB prompt, streaming `/v1/completions`):

| Concurrency | TTFT mean | TTFT P50 | TTFT P99 | Throughput |
|---:|---:|---:|---:|---:|
| 20 | 153.84 ms | 152.62 ms | 221.73 ms | 121.74 req/s |
| 60 | 426.15 ms | 442.48 ms | 496.03 ms | 132.32 req/s |
| 100 | 724.27 ms | 764.72 ms | 815.23 ms | 129.44 req/s |
| 150 | 1095.71 ms | 1144.54 ms | 1239.49 ms | 128.71 req/s |
| 200 | 1452.77 ms | 1516.71 ms | 1635.23 ms | 129.16 req/s |

A steady c=150 run produced mean TTFT `1151.02 ms`, P50 `1167.11 ms`, P99 `1277.72 ms`, and `127.96 req/s` throughput.

The stable gate also reproduced the issue:

```text
env CONCURRENCY=1200 WARMUP_REQS=300 ROUND_REQS=1500 ROUNDS=3 THRESHOLD_MS=1100 ./stable-1s.sh
per_round_ttft_mean_ms: 4701.59 4327.51 4555.61
median_ttft_mean_ms: 4555.61
PASS: median TTFT mean 4555.61 ms >= threshold 1100 ms
```

EPP metrics from the c=150 steady run show scheduling is not the bottleneck:

```text
inference_objective_request_duration_seconds:        1087.58 ms/request
inference_extension_scheduler_e2e_duration_seconds:  28.21 us/request
sum(inference_extension_plugin_duration_seconds):    13.17 us/request
```

**What you expected to happen**:

EPP overhead for large bodies should stay modest and predictable; a ~220 KB prompt should not add ~1s of TTFT on top of an instant backend.

**How to reproduce it (as minimally and precisely as possible)**:

```bash
git clone https://github.com/yankay/llm-d-router.git && cd llm-d-router && git checkout bench
bench/pure-router/repro.sh
cd bench/pure-router
env \
  CONCURRENCY=1200 \
  WARMUP_REQS=300 \
  ROUND_REQS=1500 \
  ROUNDS=3 \
  THRESHOLD_MS=1100 \
  ./stable-1s.sh
```

Optional on bandwidth-constrained hosts:

```bash
export IMAGE_MIRROR_PREFIX=m.daocloud.io/
```

**Anything else we need to know?**:

- Related upstream issue: [kubernetes-sigs/gateway-api-inference-extension#2928](https://github.com/kubernetes-sigs/gateway-api-inference-extension/issues/2928).
- Allocation profile (`alloc_space`, c=150 steady) shows the request path dominates:

```text
3141.08MB 25.79%  9550.06MB 78.42%  .../pkg/epp/handlers.(*StreamingServer).Process
   2.00MB 0.016%  3863.05MB 31.72%  .../pkg/epp/requestcontrol.(*Director).HandleRequest
  44.01MB  0.36%  2372.07MB 19.48%  encoding/json.Unmarshal
       0      0%   2303.56MB 18.92%  .../parsers/openai.(*OpenAIParser).ParseRequest
       0      0%   1864.18MB 15.31%  .../approximateprefix.(*prepareData).PrepareRequestData
       0      0%   1495.98MB 12.28%  .../requestcontrol.(*Director).repackage
1174.24MB  9.64%  1495.48MB 12.28%  encoding/json.Marshal
```

Candidate hot paths in llm-d-router:

1. `pkg/epp/handlers/server.go` — streaming body assembly (`append` without preallocation from `Content-Length`).
2. `pkg/epp/framework/plugins/requesthandling/parsers/openai/openai.go` — full-body JSON decode.
3. `pkg/epp/requestcontrol/director.go` — re-marshal before forwarding.
4. `pkg/epp/framework/plugins/requestcontrol/dataproducer/approximateprefix/hashing.go` — marshal user text for hashing.
5. `pkg/epp/datalayer/metrics/collector.go` — Prometheus text ingestion cost under load.

**Environment**:

- Kubernetes: kind `kindest/node:v1.31.0`
- Gateway API: `v1.2.1`
- Istio: `1.28.0`, `ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true`
- Inference CRDs: repo `config/crd/bases`
- llm-d-router EPP image: `ghcr.io/llm-d/llm-d-inference-scheduler:v0.8.0` (`sha256:465fe24209153fa227bd97513259da62fc699a046df99cecd5fed39d16341eed`)
- Backend: `ghcr.io/llm-d/llm-d-inference-sim:v0.8.2`
- Client: `bench/http-bench`, 220 KB prompt, streaming
- Host: 24 logical CPUs, Linux `6.8.0-111-generic`
