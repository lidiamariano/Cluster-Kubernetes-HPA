#!/usr/bin/env bash
# scripts/metrics.sh
# Instala/valida o metrics-server e coleta métricas por um período.
set -euo pipefail

DURATION="${1:-120}"   # em segundos (padrão: 120s)
INTERVAL="${2:-5}"     # em segundos (padrão: 5s)
NS="${3:-default}"     # namespace para filtrar pods no dump cru da API (padrão: default)

RUN_ID="$(date +"%Y%m%d-%H%M%S")"
OUT="outputs/${RUN_ID}"
mkdir -p "$OUT"

echo "===> Saídas: $OUT"
echo "===> Duração: ${DURATION}s | Intervalo: ${INTERVAL}s | Namespace (dump cru): ${NS}"

# 0) Pré-checagens simples
if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERRO: kubectl não encontrado." >&2; exit 1
fi

# 1) Instalar/atualizar metrics-server (manifest oficial)
echo "===> Aplicando manifest oficial do metrics-server"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml \
  | tee "$OUT/00_metrics_apply.log"

# 2) Patches recomendados para ambientes locais (k3d/k3s/minikube)
echo "===> Aplicando patches (flags para ambiente local e porta 4443)"
kubectl -n kube-system patch deployment metrics-server --type='json' -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"},
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname"},
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-use-node-status-port"},
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--metric-resolution=15s"},
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--secure-port=4443"}
]' | tee "$OUT/01_metrics_patch.log"

echo "===> Aguardando rollout do metrics-server"
kubectl -n kube-system rollout status deploy/metrics-server | tee "$OUT/02_metrics_rollout.log"

# 3) Verificações de saúde
echo "===> Verificando APIService metrics.k8s.io"
kubectl get apiservices | grep metrics | tee "$OUT/03_apiservices_metrics.txt" || true

echo "===> Logs recentes do metrics-server"
kubectl -n kube-system logs deploy/metrics-server --tail=200 | tee "$OUT/04_metrics_logs.txt" || true

# 4) Tentativa de topo imediato (pode falhar nos primeiros segundos)
echo "===> Tentando kubectl top (pode demorar ~30–60s após instalar)"
for i in {1..12}; do
  if kubectl top nodes >/dev/null 2>&1; then break; fi
  sleep 5
done

# Snapshot baseline
kubectl top nodes | tee "$OUT/10_top_nodes_baseline.txt" || true
kubectl top pods -A | tee "$OUT/11_top_pods_baseline.txt" || true

# 5) Coleta periódica durante DURATION (cada INTERVAL s)
echo "===> Coletando amostras por ${DURATION}s a cada ${INTERVAL}s"
END=$((SECONDS + DURATION))
while [ $SECONDS -lt $END ]; do
  TS="$(date +"%Y-%m-%d %H:%M:%S")"
  {
    echo "=== ${TS} ==="
    kubectl get hpa -A -o wide || true
  } >> "$OUT/20_hpa_watch.log" 2>&1

  {
    echo "=== ${TS} ==="
    kubectl top nodes || true
  } >> "$OUT/21_top_nodes_watch.log" 2>&1

  {
    echo "=== ${TS} ==="
    kubectl top pods -A || true
  } >> "$OUT/22_top_pods_watch.log" 2>&1

  # Dump cru da API de metrics para os pods do namespace alvo
  {
    echo "=== ${TS} ==="
    kubectl get --raw "/apis/metrics.k8s.io/v1beta1/namespaces/${NS}/pods" || true
    echo
  } >> "$OUT/23_metrics_api_${NS}.jsonl" 2>&1

  sleep "$INTERVAL"
done

# 6) Snapshots finais
kubectl get hpa -A -o wide | tee "$OUT/30_hpa_final.txt" >/dev/null
kubectl describe hpa php-apache-hpa | tee "$OUT/31_hpa_describe.txt" >/dev/null || true
kubectl top nodes | tee "$OUT/32_top_nodes_final.txt" >/dev/null || true
kubectl top pods -A | tee "$OUT/33_top_pods_final.txt" >/dev/null || true

echo "✅ Métricas coletadas. Veja a pasta: $OUT"
echo "   Principais arquivos:"
echo "     - 20_hpa_watch.log (evolução do HPA)"
echo "     - 21_top_nodes_watch.log / 22_top_pods_watch.log"
echo "     - 23_metrics_api_${NS}.jsonl (dump cru da API)"
echo "     - 31_hpa_describe.txt (eventos de scaling)"
