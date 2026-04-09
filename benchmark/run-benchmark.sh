#!/bin/bash
# ─────────────────────────────────────────────────────────────
# benchmark/run-benchmark.sh
# Usage :
#   ./benchmark/run-benchmark.sh           → 1000 messages
#   ./benchmark/run-benchmark.sh 5000      → 5000 messages
# ─────────────────────────────────────────────────────────────

set -euo pipefail

N=${1:-1000}
RABBITMQ="http://localhost:15672"
CREDS="guest:guest"
QUEUE="barcodes"
CONSUMER="barcode-generator-consumer"
RESULTS_FILE="benchmark/results.md"

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
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  BENCHMARK — Consumer Go — $N messages${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"

# ── 1. Vérifications ─────────────────────────────────────────
echo ""
info "Vérifications..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -u "$CREDS" "$RABBITMQ/api/overview")
if [ "$STATUS" != "200" ]; then
  echo -e "${RED}✗ RabbitMQ non accessible. Lance 'make up' d'abord.${NC}"; exit 1
fi
success "RabbitMQ OK"

if ! docker ps --format '{{.Names}}' | grep -q "$CONSUMER"; then
  echo -e "${RED}✗ Container $CONSUMER non démarré.${NC}"; exit 1
fi
success "Consumer Go OK"

# ── 2. Stopper le consumer ────────────────────────────────────
echo ""
info "Pause du consumer pendant le chargement..."
docker stop "$CONSUMER" > /dev/null
success "Consumer mis en pause"

# ── 3. Purge ──────────────────────────────────────────────────
echo ""
info "Purge de la queue '$QUEUE'..."
curl -s -o /dev/null -u "$CREDS" -X DELETE "$RABBITMQ/api/queues/%2F/$QUEUE/contents"
success "Queue purgée"

# ── 4. Publication ────────────────────────────────────────────
echo ""
info "Publication de $N messages (consumer en pause)..."
PUBLISHED=0

for i in $(seq 1 "$N"); do
  RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "$CREDS" \
    -H "Content-Type: application/json" \
    -X POST "$RABBITMQ/api/exchanges/%2F//publish" \
    -d "{\"properties\":{\"message_id\":\"bench-go-$i\",\"delivery_mode\":2},\"routing_key\":\"$QUEUE\",\"payload\":\"{\\\"barcode\\\":\\\"SPAREPART_$i\\\",\\\"format\\\":\\\"CODE128\\\",\\\"title\\\":\\\"Benchmark Item $i\\\"}\",\"payload_encoding\":\"string\"}")
  [ "$RESULT" = "200" ] && PUBLISHED=$((PUBLISHED+1))
  [ $((i % 100)) -eq 0 ] && echo -e "  ${CYAN}→${NC} $i / $N publiés..."
done

MSG_IN_QUEUE=$(curl -s -u "$CREDS" "$RABBITMQ/api/queues/%2F/$QUEUE" | \
  python -c "import sys,json; d=json.load(sys.stdin); print(d.get('messages',0))" 2>/dev/null || echo "0")
success "$PUBLISHED messages publiés — $MSG_IN_QUEUE dans la queue"

# ── 5. Démarrer consumer ──────────────────────────────────────
echo ""
info "Démarrage du consumer — chrono lancé !"
docker start "$CONSUMER" > /dev/null
START_S=$(date +%s)

# Laisser le consumer démarrer
sleep 2

# ── 6. Mesure CPU/RAM pendant la consommation ─────────────────
echo ""
info "Mesure CPU/RAM pendant la consommation..."

CPU_MAX="0.00%"
MEM_PEAK="0B"

# Surveiller en arrière-plan toutes les 2 secondes
TMP_STATS=$(mktemp)
(
  while true; do
    SNAP=$(docker stats "$CONSUMER" --no-stream --format "{{.CPUPerc}}|{{.MemUsage}}" 2>/dev/null || echo "0.00%|0B")
    echo "$SNAP" >> "$TMP_STATS"
    sleep 2
  done
) &
MONITOR_PID=$!

# ── 7. Attente consommation complète ─────────────────────────
TIMEOUT=300
ELAPSED=0

while true; do
  MSG_COUNT=$(curl -s -u "$CREDS" "$RABBITMQ/api/queues/%2F/$QUEUE" 2>/dev/null | \
    python -c "import sys,json; d=json.load(sys.stdin); print(d.get('messages',0))" 2>/dev/null || echo "0")

  echo -ne "\r  Messages restants : ${YELLOW}$MSG_COUNT${NC} / $N   "

  if [ "$MSG_COUNT" -eq "0" ]; then
    echo ""
    break
  fi

  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo ""; warn "Timeout $TIMEOUT s — $MSG_COUNT messages non traités"; break
  fi

  sleep 1
  ELAPSED=$((ELAPSED+1))
done

END_S=$(date +%s)
TOTAL_S=$((END_S - START_S))

# Stopper le monitoring
kill $MONITOR_PID 2>/dev/null || true
sleep 1

# Extraire CPU max et RAM max depuis les snapshots
if [ -f "$TMP_STATS" ] && [ -s "$TMP_STATS" ]; then
  CPU_MAX=$(cat "$TMP_STATS" | cut -d'|' -f1 | tr -d '%' | sort -n | tail -1)
  CPU_MAX="${CPU_MAX}%"
  MEM_PEAK=$(cat "$TMP_STATS" | cut -d'|' -f2 | cut -d'/' -f1 | tr -d ' ' | sort -h | tail -1)
  MEM_TOTAL=$(cat "$TMP_STATS" | cut -d'|' -f2 | cut -d'/' -f2 | tr -d ' ' | head -1)
fi
rm -f "$TMP_STATS"

# ── 8. Calculs ────────────────────────────────────────────────
if [ "$TOTAL_S" -gt "0" ]; then
  MSG_PER_SEC=$((N / TOTAL_S))
  MS_PER_MSG=$((TOTAL_S * 1000 / N))
else
  MSG_PER_SEC="$N (< 1s)"
  MS_PER_MSG="< 1"
fi

# ── 9. Résumé ─────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  RÉSULTATS — Consumer Go${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo ""
echo -e "  Messages traités  : ${GREEN}$PUBLISHED${NC}"
echo -e "  Temps total       : ${GREEN}${TOTAL_S}s${NC}"
echo -e "  Débit             : ${GREEN}${MSG_PER_SEC} msg/s${NC}"
echo -e "  Latence moyenne   : ${GREEN}${MS_PER_MSG} ms/msg${NC}"
echo ""
echo -e "  CPU pic           : ${GREEN}${CPU_MAX}${NC}"
echo -e "  RAM pic           : ${GREEN}${MEM_PEAK}${NC}"
echo ""

# ── 10. Sauvegarde ────────────────────────────────────────────
TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
cat >> "$RESULTS_FILE" << RESULT

---

## Benchmark Go — $TIMESTAMP

| Métrique | Valeur |
|----------|--------|
| Messages testés | $N |
| Temps total | ${TOTAL_S}s |
| Débit | ${MSG_PER_SEC} msg/s |
| Latence moyenne | ${MS_PER_MSG} ms/msg |
| CPU pic (pendant benchmark) | ${CPU_MAX} |
| RAM pic (pendant benchmark) | ${MEM_PEAK} |

RESULT

success "Résultats sauvegardés dans $RESULTS_FILE"
echo ""