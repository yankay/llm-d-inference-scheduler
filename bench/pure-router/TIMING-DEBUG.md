# EPP TTFT Timing Debug Notes

This note records the temporary timing instrumentation used to understand why
large-input TTFT remains high after request body buffer preallocation.

## Instrumentation

Set `EPP_TIMING_DEBUG=1` on the EPP deployment to enable aggregate timing logs.
The instrumentation logs every 100 completed requests and is intentionally
coarse-grained so it can be used during the existing pure-router benchmark.

The current debug build records:

- `pkg/epp/handlers/server.go`
  - request headers to first request body chunk
  - request body stream duration until end-of-stream
  - request body append/assembly time
  - parser time
  - director time
  - request response generation time
  - body chunk count and body byte count
- `pkg/epp/framework/plugins/requesthandling/parsers/openai/openai.go`
  - generic `map[string]any` JSON decode time
  - typed request JSON decode time
- `pkg/epp/requestcontrol/director.go`
  - model rewrite, request assembly, admission, endpoint lookup
  - data producer, admission plugins, scheduler, prepare request, repackage
- `pkg/epp/framework/plugins/requestcontrol/dataproducer/approximateprefix/hashing.go`
  - user input materialization time
  - hash loop time
  - hash input size and generated hash count

## Preliminary Results

Workload:

```bash
bench/http-bench \
  --url http://127.0.0.1:8080/v1/completions \
  --host bench.local \
  --model Qwen/Qwen3-32B \
  --concurrency 1200 \
  --total 1200 \
  --input-chars 220000 \
  --metrics http://127.0.0.1:19090/metrics \
  --timeout 180s
```

Observed client-side result:

```text
TTFT mean: 5007.70 ms
TTFT P50:  5022.34 ms
TTFT P99:  9532.00 ms
```

Representative EPP aggregate after 1200 requests:

```text
avgTotalMs:             305.65
avgHeaderToFirstBodyMs:   8.83
avgBodyStreamMs:        284.05
avgBodyAppendMs:          0.29
avgParseMs:               5.87
avgDirectorMs:            6.83
avgResponseBuildMs:       0.07
avgBodyChunks:            7.24
avgBodyBytes:        220069
```

OpenAI parser aggregate:

```text
avgTotalMs:       5.87
avgMapDecodeMs:   2.18
avgTypedDecodeMs: 3.69
avgBodyBytes: 220069
```

Director aggregate:

```text
avgTotalMs:        6.81
avgDataProducerMs: 5.71
avgRepackageMs:    0.97
avgScheduleMs:     0.05
```

Approximate prefix hash aggregate:

```text
avgTotalMs:          0.34
avgGetInputMs:       0.31
avgHashLoopMs:       0.01
avgInputBytes:   16384
avgGeneratedHashes: 256
```

The same pattern appears at c=150. Client TTFT remains around 1s, but the
instrumented EPP work after request headers is around 210 ms, with most of that
time spent waiting for request body chunks to finish streaming:

```text
c=150 TTFT mean: 1007.73 ms
avgTotalMs:       209.62
avgBodyStreamMs:  193.20
avgParseMs:         5.31
avgDirectorMs:      5.10
avgBodyAppendMs:    0.23
```

## Current Interpretation

Request body append/preallocation is not the TTFT bottleneck in this benchmark.
The measured append/assembly time is roughly 0.2-0.3 ms per request.

Duplicate OpenAI JSON parsing and downstream repackage/prefix-copy work are real
CPU/allocation costs, but they account for single-digit milliseconds per request
in this run. They are still worth optimizing to reduce CPU and allocation
pressure, but they are unlikely to remove the 1s-class TTFT by themselves.

The visible EPP-side wait is dominated by receiving the large request body:
220 KB arrives as roughly 7 body chunks, and the measured body-stream interval
is around 190-285 ms depending on the run. The rest of client-observed TTFT is
likely before EPP has completed receiving the body or in the surrounding
Gateway/port-forward/client upload path.

## Next Experiments

1. Run `http-bench` inside the KIND cluster and access the Gateway service
   directly. This removes local `kubectl port-forward` from the request upload
   path.
2. Test `inferenceExtension.replicas=2` and `4` to see whether single EPP
   saturation and body-stream queueing scale down with more replicas.
3. Inspect and experiment with Envoy/Gateway ext_proc body streaming or
   buffering settings. The next likely bottleneck is the delivery of 220 KB
   request bodies to EPP, not the Go slice append itself.
4. Keep the request body preallocation PR scoped as low-risk allocation hygiene.
   Treat JSON parse/marshal and prompt-copy reduction as follow-up CPU/allocation
   work, not as the main TTFT fix for this benchmark.
