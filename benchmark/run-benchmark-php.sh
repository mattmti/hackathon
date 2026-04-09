#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# benchmark/run-benchmark-php.sh
# Benchmark de performance — Consumer PHP
# Même méthodologie et mêmes métriques que run-benchmark.sh (Go)
#
# Usage :
#   ./benchmark/run-benchmark-php.sh           → 1000 messages (défaut)
#   ./benchmark/run-benchmark-php.sh 5000      → 5000 messages
#   make benchmark-php N=500
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

N=${1:-1000}
RABBITMQ="http://localhost:15672"
CREDS="guest:guest"
QUEUE="barcodes"
CONSUMER_PHP="barcode-generator-consumer-php"
CONSUMER_GO="barcode-generator-consumer"
RESULTS_FILE="benchmark/results.md"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
DATE_FILE=$(date '+%Y%m%d_%H%M')

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

success() { echo -e "${GREEN}✓${NC} $1"; }
info()    { echo -e "${CYAN}▶${NC} $1"; }
warn()    { echo -e "${YELLOW}⚠${NC} $1"; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     BENCHMARK PERFORMANCE — Consumer PHP             ║${NC}"
echo -e "${BOLD}║     $TIMESTAMP — $N messages                   ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"

# ── 1. Vérifications ─────────────────────────────────────────
echo ""
info "Vérifications..."

STATUS=$(curl -s -o /dev/null -w "%{http_code}" -u "$CREDS" "$RABBITMQ/api/overview")
[ "$STATUS" != "200" ] && echo -e "${RED}✗ RabbitMQ non accessible${NC}" && exit 1
success "RabbitMQ accessible"

# Stopper le consumer Go pour isoler le benchmark
info "Arrêt du consumer Go (isolation benchmark)..."
docker stop "$CONSUMER_GO" > /dev/null 2>&1 || true
success "Consumer Go arrêté"

# Builder le consumer PHP
info "Build du consumer PHP..."
docker compose --profile benchmark build barcode-generator-consumer-php 2>/dev/null
success "Consumer PHP buildé"

OS=$(uname -s)
DOCKER_VERSION=$(docker --version | awk '{print $3}' | tr -d ',')
echo ""
echo -e "  OS      : $OS"
echo -e "  Docker  : $DOCKER_VERSION"
echo -e "  PHP     : 8.2"

# ── 2. Stopper consumer PHP si existant ──────────────────────
docker stop "$CONSUMER_PHP" > /dev/null 2>&1 || true
sleep 1

# ── 3. Purge queue ───────────────────────────────────────────
echo ""
info "Purge de la queue '$QUEUE'..."
curl -s -o /dev/null -u "$CREDS" -X DELETE "$RABBITMQ/api/queues/%2F/$QUEUE/contents"
success "Queue purgée"

# ── 4. Publication ────────────────────────────────────────────
echo ""
info "Publication de $N messages (consumer en pause)..."
PUBLISHED=0
for i in $(seq 1 "$N"); do
  R=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "$CREDS" -H "Content-Type: application/json" \
    -X POST "$RABBITMQ/api/exchanges/%2F//publish" \
    -d "{\"properties\":{\"message_id\":\"bench-php-$DATE_FILE-$i\",\"delivery_mode\":2},\"routing_key\":\"$QUEUE\",\"payload\":\"{\\\"barcode\\\":\\\"SPAREPART_$i\\\",\\\"format\\\":\\\"CODE128\\\",\\\"title\\\":\\\"Benchmark Produit $i\\\"}\",\"payload_encoding\":\"string\"}")
  [ "$R" = "200" ] && PUBLISHED=$((PUBLISHED+1))
  [ $((i % 100)) -eq 0 ] && echo -e "  ${CYAN}→${NC} $i / $N publiés..."
done
success "$PUBLISHED / $N messages en queue"

# ── 5. Démarrer consumer PHP + monitoring ─────────────────────
echo ""
info "Démarrage consumer PHP + monitoring..."
TMP_STATS=$(mktemp)
TMP_LATENCES=$(mktemp)

docker compose --profile benchmark up -d barcode-generator-consumer-php 2>/dev/null
START_S=$(date +%s)
sleep 3

# Monitoring CPU/RAM en arrière-plan
(
  while true; do
    SNAP=$(docker stats "$CONSUMER_PHP" --no-stream --format "{{.CPUPerc}}|{{.MemUsage}}" 2>/dev/null || echo "0.00%|0B / 0B")
    echo "$SNAP" >> "$TMP_STATS"
    sleep 1
  done
) &
MONITOR_PID=$!

# ── 6. Attente consommation ───────────────────────────────────
echo ""
info "Attente de la consommation complète..."
PREV_COUNT=$N
TIMEOUT=300
ELAPSED=0
PREV_TIME=$START_S

while true; do
  MSG_COUNT=$(curl -s -u "$CREDS" "$RABBITMQ/api/queues/%2F/$QUEUE" 2>/dev/null | \
    python -c "import sys,json; d=json.load(sys.stdin); print(d.get('messages',0))" 2>/dev/null || echo "0")

  NOW=$(date +%s)
  DELTA_MSG=$((PREV_COUNT - MSG_COUNT))
  DELTA_T=$((NOW - PREV_TIME))
  if [ "$DELTA_T" -gt 0 ] && [ "$DELTA_MSG" -gt 0 ]; then
    echo "$((DELTA_MSG / DELTA_T))" >> "$TMP_LATENCES"
  fi
  PREV_COUNT=$MSG_COUNT
  PREV_TIME=$NOW

  echo -ne "\r  Messages restants : ${YELLOW}$MSG_COUNT${NC} / $N   "
  [ "$MSG_COUNT" -eq "0" ] && echo "" && break
  [ "$ELAPSED" -ge "$TIMEOUT" ] && echo "" && warn "Timeout" && break
  sleep 1
  ELAPSED=$((ELAPSED+1))
done

END_S=$(date +%s)
TOTAL_S=$((END_S - START_S))
kill $MONITOR_PID 2>/dev/null || true
sleep 1

# ── 7. Métriques ─────────────────────────────────────────────
CPU_PIC="N/A"
RAM_PIC="N/A"
if [ -f "$TMP_STATS" ] && [ -s "$TMP_STATS" ]; then
  CPU_PIC=$(cat "$TMP_STATS" | cut -d'|' -f1 | tr -d '%' | grep -E '^[0-9]' | sort -n | tail -1)
  CPU_PIC="${CPU_PIC}%"
  RAM_PIC=$(cat "$TMP_STATS" | cut -d'|' -f2 | cut -d'/' -f1 | tr -d ' ' | grep -v '^0B$' | sort -h | tail -1)
fi

P50="N/A" P95="N/A" P99="N/A"
if [ -f "$TMP_LATENCES" ] && [ -s "$TMP_LATENCES" ]; then
  NB_SAMPLES=$(wc -l < "$TMP_LATENCES")
  if [ "$NB_SAMPLES" -ge 3 ]; then
    P50=$(sort -n "$TMP_LATENCES" | awk -v n="$NB_SAMPLES" 'NR==int(n*0.50){print $1}')
    P95=$(sort -n "$TMP_LATENCES" | awk -v n="$NB_SAMPLES" 'NR==int(n*0.95)+1{print $1}')
    P99=$(sort -n "$TMP_LATENCES" | awk -v n="$NB_SAMPLES" 'NR==int(n*0.99)+1{print $1}')
    [ -n "$P50" ] && P50="${P50} msg/s" || P50="N/A"
    [ -n "$P95" ] && P95="${P95} msg/s" || P95="N/A"
    [ -n "$P99" ] && P99="${P99} msg/s" || P99="N/A"
  fi
fi

rm -f "$TMP_STATS" "$TMP_LATENCES"

MSG_PER_SEC=0
MS_PER_MSG=0
[ "$TOTAL_S" -gt 0 ] && MSG_PER_SEC=$((PUBLISHED / TOTAL_S)) && MS_PER_MSG=$((TOTAL_S * 1000 / PUBLISHED))

# ── 8. Résumé ─────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     RÉSULTATS — Consumer PHP                         ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Messages traités  : ${GREEN}$PUBLISHED${NC}"
echo -e "  Temps total       : ${GREEN}${TOTAL_S}s${NC}"
echo -e "  Débit moyen       : ${GREEN}${MSG_PER_SEC} msg/s${NC}"
echo -e "  Latence moyenne   : ${GREEN}${MS_PER_MSG} ms/msg${NC}"
echo -e "  Débit P50         : ${GREEN}${P50}${NC}"
echo -e "  Débit P95         : ${GREEN}${P95}${NC}"
echo -e "  Débit P99         : ${GREEN}${P99}${NC}"
echo ""
echo -e "  CPU pic           : ${GREEN}${CPU_PIC}${NC}"
echo -e "  RAM pic           : ${GREEN}${RAM_PIC}${NC}"
echo ""

# ── 9. Nettoyage ──────────────────────────────────────────────
docker stop "$CONSUMER_PHP" > /dev/null 2>&1 || true

info "Redémarrage du consumer Go..."
docker start "$CONSUMER_GO" > /dev/null 2>&1 || true
success "Consumer Go redémarré"

# ── 10. Sauvegarde markdown ───────────────────────────────────
cat >> "$RESULTS_FILE" << MDEOF

---

## Benchmark PHP — $TIMESTAMP

### Environnement

| Paramètre | Valeur |
|-----------|--------|
| OS | $OS |
| Docker | $DOCKER_VERSION |
| PHP | 8.2 |
| Librairie barcode | picqer/php-barcode-generator |

### Résultats

| Métrique | Valeur |
|----------|--------|
| Messages testés | $N |
| Temps total | ${TOTAL_S}s |
| Débit moyen | ${MSG_PER_SEC} msg/s |
| Latence moyenne | ${MS_PER_MSG} ms/msg |
| Débit P50 | ${P50} |
| Débit P95 | ${P95} |
| Débit P99 | ${P99} |
| CPU pic | ${CPU_PIC} |
| RAM pic | ${RAM_PIC} |

MDEOF

success "Résultats sauvegardés dans $RESULTS_FILE"
echo ""