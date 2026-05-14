#!/usr/bin/env bash
# Pure llm-d-router EPP reproduction for large-body TTFT overhead (see GIE issue #2928).
#
# Brings up KIND + Gateway API + GIE-compatible InferencePool CRDs + Istio (Gateway API inference)
# + llm-d-inference-sim + InferencePool Helm chart from THIS repo + Gateway/HTTPRoute, then runs
# an http-bench concurrency sweep and optional steady-state pprof snapshots under ./out/.
#
# Requirements: docker, kind, kubectl, helm, go 1.22+, curl.
#
# Optional (recommended from mainland China): pull-through mirror prefix without committing it:
#   export IMAGE_MIRROR_PREFIX=m.daocloud.io/
#
# Optional: build EPP from source instead of pulling GHCR:
#   BUILD_LOCAL_EPP=1 ./repro.sh
#
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${BENCH_DIR}/../.." && pwd)"
OUT_DIR="${BENCH_DIR}/out"
HTTP_BENCH_DIR="$(cd "${BENCH_DIR}/../http-bench" && pwd)"
mkdir -p "${OUT_DIR}"

CLUSTER="${CLUSTER:-router-bench}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.2.1}"
ISTIO_VERSION="${ISTIO_VERSION:-1.28.0}"
NODE_IMAGE="${NODE_IMAGE:-kindest/node:v1.31.0}"
IMAGE_MIRROR_PREFIX="${IMAGE_MIRROR_PREFIX:-}"

SOURCE_PROXY="${SOURCE_PROXY:-1}"
if [[ "${SOURCE_PROXY}" == "1" ]] && [[ -f /root/proxy.sh ]]; then
  # shellcheck disable=SC1091
  source /root/proxy.sh
fi

EPP_REGISTRY="${EPP_REGISTRY:-ghcr.io/llm-d}"
# Published GHCR image still uses the historical repository name (matches Makefile PROJECT_NAME).
EPP_REPOSITORY="${EPP_REPOSITORY:-llm-d-inference-scheduler}"
EPP_TAG="${EPP_TAG:-v0.8.0}"
SIM_IMAGE="${SIM_IMAGE:-ghcr.io/llm-d/llm-d-inference-sim:v0.8.2}"

CHART_DIR="${REPO_ROOT}/config/charts/inferencepool"

mirror_uri() {
  local canonical="$1"
  if [[ -z "${IMAGE_MIRROR_PREFIX}" ]]; then
    echo "${canonical}"
    return 0
  fi
  local p="${IMAGE_MIRROR_PREFIX%/}/"
  # DaoCloud prefix mirror expects registry-qualified paths. Short Docker Hub library paths like
  # `kindest/node` resolve via `docker.io/kindest/node`.
  if [[ "${canonical}" == kindest/* ]]; then
    echo "${p}docker.io/${canonical}"
    return 0
  fi
  echo "${p}${canonical}"
}

docker_pull_tag_load() {
  local canonical="$1"
  local pull_uri
  pull_uri="$(mirror_uri "${canonical}")"
  echo "[+] docker pull ${pull_uri}"
  docker pull "${pull_uri}"
  if [[ "${pull_uri}" != "${canonical}" ]]; then
    docker tag "${pull_uri}" "${canonical}"
  fi
  echo "[+] kind load docker-image ${canonical}"
  kind load docker-image "${canonical}" --name "${CLUSTER}"
}

echo "[1/9] create KIND cluster ${CLUSTER}"
NODE_PULL="$(mirror_uri "${NODE_IMAGE}")"
if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  kind create cluster --name "${CLUSTER}" --image "${NODE_PULL}" --wait 120s
fi
kubectl config use-context "kind-${CLUSTER}"

echo "[2/9] install Gateway API + InferencePool CRDs"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
# Do not use `kubectl apply -k "${REPO_ROOT}/config/crd"`: it expands to a remote GIE git URL that may time out
# behind strict networks. The CRD YAML is vendored under config/crd/bases/.
kubectl apply --server-side -f "${REPO_ROOT}/config/crd/bases/"

echo "[3/9] install Istio ${ISTIO_VERSION} with Gateway API inference extension enabled"
if [[ "${PRELOAD_ISTIO_IMAGES:-1}" == "1" ]]; then
  echo "  preload Istio images into kind (kubelet pulls docker.io/istio/* otherwise)"
  docker_pull_tag_load "docker.io/istio/pilot:${ISTIO_VERSION}"
  docker_pull_tag_load "docker.io/istio/proxyv2:${ISTIO_VERSION}"
fi
if ! command -v istioctl >/dev/null 2>&1; then
  echo "  istioctl not on PATH; downloading to /tmp/istio-${ISTIO_VERSION}"
  curl -fsSL "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-linux-amd64.tar.gz" \
    | tar xz -C /tmp
  export PATH="/tmp/istio-${ISTIO_VERSION}/bin:${PATH}"
fi
istioctl install -y \
  --set values.pilot.env.ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true

echo "[4/9] preload workload images into kind (before scheduling sim / EPP pods)"
if [[ "${BUILD_LOCAL_EPP:-0}" == "1" ]]; then
  echo "  BUILD_LOCAL_EPP: docker build EPP from repo"
  TAG="bench-$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
  FULL_IMAGE="${EPP_REGISTRY}/${EPP_REPOSITORY}:${TAG}"
  docker build -t "${FULL_IMAGE}" \
    --build-arg TARGETOS=linux \
    --build-arg TARGETARCH=amd64 \
    -f "${REPO_ROOT}/Dockerfile.epp" \
    "${REPO_ROOT}"
  kind load docker-image "${FULL_IMAGE}" --name "${CLUSTER}"
  EPP_TAG="${TAG}"
elif [[ "${PRELOAD_IMAGES:-1}" == "1" ]]; then
  docker_pull_tag_load "${EPP_REGISTRY}/${EPP_REPOSITORY}:${EPP_TAG}"
fi
if [[ "${PRELOAD_IMAGES:-1}" == "1" ]]; then
  docker_pull_tag_load "${SIM_IMAGE}"
fi

echo "[5/9] deploy llm-d-inference-sim (4 replicas)"
sed "s|\${SIM_IMAGE}|${SIM_IMAGE}|g" "${BENCH_DIR}/manifests/sim-deployment.yaml" | kubectl apply -f -
kubectl rollout status deploy/vllm-qwen3-32b --timeout=240s

echo "[6/9] helm install InferencePool + llm-d-router EPP"
helm dependency build "${CHART_DIR}"
helm upgrade --install vllm-qwen3-32b "${CHART_DIR}" \
  --set provider.name=istio \
  --set inferencePool.modelServers.matchLabels.app=vllm-qwen3-32b \
  --set inferenceExtension.replicas=1 \
  --set inferenceExtension.resources.requests.cpu=2 \
  --set inferenceExtension.resources.requests.memory=4Gi \
  --set inferenceExtension.monitoring.prometheus.auth.enabled=false \
  --set inferenceExtension.image.registry="${EPP_REGISTRY}" \
  --set inferenceExtension.image.repository="${EPP_REPOSITORY}" \
  --set inferenceExtension.image.tag="${EPP_TAG}" \
  --set inferenceExtension.image.pullPolicy=IfNotPresent
kubectl rollout status deploy/vllm-qwen3-32b-epp --timeout=300s

echo "[7/9] apply Gateway + HTTPRoute"
kubectl apply -f "${BENCH_DIR}/manifests/gateway-route.yaml"
sleep 5

echo "[8/9] port-forward Gateway:80 and EPP metrics:9090"
setsid -f kubectl port-forward svc/inference-gateway-istio 8080:80 \
  </dev/null >"${OUT_DIR}/pf-gw.log" 2>&1 &
setsid -f kubectl port-forward svc/vllm-qwen3-32b-epp 9090:9090 \
  </dev/null >"${OUT_DIR}/pf-epp.log" 2>&1 &
sleep 3
trap 'pkill -f "kubectl port-forward" 2>/dev/null || true' EXIT

curl -sf -o /dev/null -w "smoke: %{http_code} time=%{time_total}\n" \
  http://localhost:8080/v1/completions \
  -H 'Host: bench.local' \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen3-32B","prompt":"hi","max_tokens":2}'

echo "[9/9] run concurrency sweep (220 KB prompts)"
pushd "${HTTP_BENCH_DIR}" >/dev/null
GOWORK=off go build -o "${OUT_DIR}/http-bench" .
popd >/dev/null

for c in 20 60 100 150 200; do
  echo "===== concurrency=${c} ====="
  "${OUT_DIR}/http-bench" \
    --url http://localhost:8080/v1/completions \
    --host bench.local --model Qwen/Qwen3-32B \
    --concurrency "${c}" --total "$((c * 8))" --input-chars 220000 \
    --timeout 120s --metrics http://localhost:9090/metrics
  echo
done | tee "${OUT_DIR}/sweep.txt"

echo "[+] capture steady-state pprof during a long c=150 run"
( "${OUT_DIR}/http-bench" \
    --url http://localhost:8080/v1/completions \
    --host bench.local --model Qwen/Qwen3-32B \
    --concurrency 150 --total 4000 --input-chars 220000 \
    --timeout 120s --metrics http://localhost:9090/metrics \
    > "${OUT_DIR}/c150-steady-30s.txt" 2>&1 ) &
BENCH_PID=$!
sleep 10
curl -s -o "${OUT_DIR}/allocs-c150-steady.pb.gz" http://localhost:9090/debug/pprof/allocs || true
curl -s -o "${OUT_DIR}/heap-c150-steady.pb.gz" http://localhost:9090/debug/pprof/heap || true
curl -s -o "${OUT_DIR}/mutex-c150-steady.pb.gz" http://localhost:9090/debug/pprof/mutex || true
wait "${BENCH_PID}"

curl -s -o "${OUT_DIR}/epp-metrics-steady.txt" http://localhost:9090/metrics || true
if [[ -f "${OUT_DIR}/allocs-c150-steady.pb.gz" ]]; then
  go tool pprof -top -cum -nodecount=30 \
    "${OUT_DIR}/allocs-c150-steady.pb.gz" > "${OUT_DIR}/allocs-c150-steady.top30.txt" || true
fi

echo "Done. Artifacts written to ${OUT_DIR}"
