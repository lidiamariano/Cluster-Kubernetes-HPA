#!/usr/bin/env bash
# scripts/load.sh
set -euo pipefail

# ===== Config =====
DURATION="${1:-2m}"        # hey: 2m, 90s... | ab: número de reqs se usar AB
CONCURRENCY="${2:-50}"     # hey: -c 50       | ab: -c 50
URL="${3:-http://localhost:8080/}"

# ===== Prep =====
RUN_ID="$(date +"%Y%m%d-%H%M%S")"
OUT="outputs/${RUN_ID}"
mkdir -p "$OUT"

echo "===> Saídas serão salvas em: $OUT"
echo "===> Alvo: $URL | Duração/Requests: $DURATION | Concorrência: $CONCURRENCY"

# ===== Verificações rápidas =====
if ! kubectl get svc php-apache-service >/dev/null 2>&1; then
  echo "ERRO: Service php-apache-service não encontrado. Aplique os manifests antes." >&2
  exit 1
fi

# ===== Port-forward do Service (evita 404 do Traefik) =====
echo "===> Abrindo port-forward 8080->svc/php-apache-service:80"
kubectl port-forward svc/php-apache-service 8080:80 >"$OUT/00_port_forward.log" 2>&1 &
PF_PID=$!
sleep 2

stop_pf() { kill "$PF_PID" 2>/dev/null || true; }
trap stop_pf EXIT

# ===== Watchers de HPA e TOP =====
echo "===> Iniciando watchers (HPA e kubectl top pods)"
( while true; do
    echo "=== $(date) ===" >> "$OUT/20_hpa_watch.log"
    kubectl get hpa php-apache-hpa -o wide >> "$OUT/20_hpa_watch.log" 2>&1 || true
    sleep 5
  done ) &
HPA_WATCH_PID=$!

( while true; do
    echo "=== $(date) ===" >> "$OUT/21_top_pods_watch.log"
    kubectl top pods >> "$OUT/21_top_pods_watch.log" 2>&1 || true
    sleep 5
  done ) &
TOP_WATCH_PID=$!

stop_watchers() {
  kill "$HPA_WATCH_PID" "$TOP_WATCH_PID" 2>/dev/null || true
}
trap 'stop_watchers; stop_pf' EXIT

# ===== Baseline =====
echo "===> Coletando baseline"
kubectl get pods -A -o wide | tee "$OUT/11_pods_wide_before.txt" >/dev/null
kubectl get svc -A | tee "$OUT/12_services_before.txt" >/dev/null
kubectl get hpa -A -o wide | tee "$OUT/13_hpa_wide_before.txt" >/dev/null
kubectl describe hpa php-apache-hpa | tee "$OUT/14_hpa_describe_before.txt" >/dev/null
kubectl top nodes | tee "$OUT/16_top_nodes_before.txt" >/dev/null || true
kubectl top pods -A | tee "$OUT/17_top_pods_before.txt" >/dev/null || true

# ===== Escolher ferramenta (hey > ab) =====
USE_TOOL=""
if command -v hey >/dev/null 2>&1; then
  USE_TOOL="hey"
elif command -v ab >/dev/null 2>&1; then
  USE_TOOL="ab"
else
  echo "ERRO: nem 'hey' nem 'ab' encontrados."
  echo "Instale um deles e rode novamente:"
  echo "  sudo apt update && sudo apt install -y hey"
  echo "     - ou -"
  echo "  sudo apt update && sudo apt install -y apache2-utils"
  exit 1
fi

# ===== Rodar carga =====
if [ "$USE_TOOL" = "hey" ]; then
  echo "===> Rodando hey por $DURATION com $CONCURRENCY conexões em $URL"
  hey -z "$DURATION" -c "$CONCURRENCY" "$URL" | tee "$OUT/22_hey_${DURATION/_/}-${CONCURRENCY}.txt" >/dev/null
else
  # Para ab, usamos DURATION como total de requests por padrão
  REQS="$DURATION"
  if [[ "$REQS" =~ [^0-9] ]]; then REQS="20000"; fi
  echo "===> Rodando ab com $REQS requisições e $CONCURRENCY de concorrência em $URL"
  ab -n "$REQS" -c "$CONCURRENCY" "$URL" | tee "$OUT/23_ab_n${REQS}_c${CONCURRENCY}.txt" >/dev/null
fi

# ===== Pós-carga =====
echo "===> Coletando pós-carga"
kubectl get hpa -A -o wide | tee "$OUT/30_hpa_wide_after.txt" >/dev/null
kubectl describe hpa php-apache-hpa | tee "$OUT/31_hpa_describe_after.txt" >/dev/null
kubectl top nodes | tee "$OUT/32_top_nodes_after.txt" >/dev/null || true
kubectl top pods -A | tee "$OUT/33_top_pods_after.txt" >/dev/null || true
kubectl get pods -o wide | tee "$OUT/34_pods_after.txt" >/dev/null

# ===== Encerrar watchers e port-forward =====
stop_watchers
stop_pf

echo "✅ Concluído! Evidências salvas em: $OUT"
echo "   Arquivos-chave:"
echo "     - 22_hey_* ou 23_ab_* (resultado da carga)"
echo "     - 20_hpa_watch.log (evolução TARGET/REPLICAS)"
echo "     - 31_hpa_describe_after.txt (eventos de scale)"
echo "     - 33_top_pods_after.txt (CPU por pod)"
