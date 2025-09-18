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

# ===== Port-forward do Service =====
echo "===> Abrindo port-forward 8080->svc/php-apache-service:80"
kubectl port-forward svc/php-apache-service 8080:80 >"$OUT/00_port_forward.log" 2>&1 &
PF_PID=$!
sleep 3

stop_pf() { kill "$PF_PID" 2>/dev/null || true; }
trap stop_pf EXIT

# ===== Watchers =====
echo "===> Iniciando watchers"
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
kubectl get pods -o wide | tee "$OUT/11_pods_before.txt" >/dev/null
kubectl get hpa -o wide | tee "$OUT/12_hpa_before.txt" >/dev/null
kubectl top pods | tee "$OUT/13_top_before.txt" >/dev/null || true

# ===== Ferramenta =====
USE_TOOL=""
if command -v hey >/dev/null 2>&1; then
  USE_TOOL="hey"
elif command -v ab >/dev/null 2>&1; then
  USE_TOOL="ab"
else
  echo "ERRO: instale 'hey' ou 'ab'"
  echo "  sudo apt install -y hey"
  echo "  # ou"
  echo "  sudo apt install -y apache2-utils"
  exit 1
fi

# ===== Teste de carga =====
if [ "$USE_TOOL" = "hey" ]; then
  echo "===> Rodando hey"
  hey -z "$DURATION" -c "$CONCURRENCY" "$URL" | tee "$OUT/22_hey.txt"
else
  REQS="$DURATION"
  if [[ "$REQS" =~ [^0-9] ]]; then REQS="20000"; fi
  echo "===> Rodando ab"
  ab -n "$REQS" -c "$CONCURRENCY" "$URL" | tee "$OUT/23_ab.txt"
fi

# ===== Pós-carga =====
kubectl get hpa -o wide | tee "$OUT/30_hpa_after.txt" >/dev/null
kubectl describe hpa php-apache-hpa | tee "$OUT/31_hpa_describe.txt" >/dev/null
kubectl top pods | tee "$OUT/32_top_after.txt" >/dev/null || true
kubectl get pods -o wide | tee "$OUT/33_pods_after.txt" >/dev/null

# ===== Final =====
stop_watchers
stop_pf
echo "✅ Teste concluído! Resultados em: $OUT"
