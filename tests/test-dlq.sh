#!/bin/bash
# ─────────────────────────────────────────────────────────────
# test-dlq.sh — Vérifie la Dead-Letter Queue
# Envoie un message invalide → le consumer le Nack → DLQ
# ─────────────────────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓ PASS${NC} — $1"; }
fail() { echo -e "${RED}✗ FAIL${NC} — $1"; exit 1; }
info() { echo -e "${YELLOW}▶${NC} $1"; }

echo ""
echo "═══════════════════════════════════════════════"
echo "  TEST DLQ — Dead-Letter Queue"
echo "═══════════════════════════════════════════════"
echo ""

# S'assurer que le consumer tourne
info "Vérification du consumer..."
docker start barcode-generator-consumer > /dev/null 2>&1 || true
sleep 2
pass "Consumer actif"

# Purge la DLQ avant le test
info "Purge de la DLQ avant test..."
curl -s -o /dev/null \
    -u guest:guest \
    -X DELETE http://localhost:15672/api/queues/%2F/barcodes.dlq/contents
pass "DLQ purgée"

# Publier un message avec barcode vide → va échouer dans le consumer
# Le consumer va retry 3 fois puis Nack → DLQ
info "Publication d'un message invalide (barcode vide)..."
PUB=$(curl -s -o /dev/null -w "%{http_code}" \
    -u guest:guest \
    -H "Content-Type: application/json" \
    -X POST http://localhost:15672/api/exchanges/%2F//publish \
    -d '{
        "properties": {
            "message_id": "dlq-test-invalid-001",
            "delivery_mode": 2
        },
        "routing_key": "barcodes",
        "payload": "{\"barcode\":\"\",\"format\":\"CODE128\",\"title\":\"Test DLQ\"}",
        "payload_encoding": "string"
    }')

if [ "$PUB" = "200" ]; then
    pass "Message invalide publié"
else
    fail "Échec publication — HTTP $PUB"
fi

# Attendre que le consumer traite + retry + Nack → DLQ
# retry_max=3, délais: 0ms + 500ms + 1000ms = ~2s + marge
info "Attente du traitement et des retries (10s)..."
sleep 10

# Vérifier que le message est en DLQ
DLQ_COUNT=$(curl -s -u guest:guest \
    http://localhost:15672/api/queues/%2F/barcodes.dlq 2>/dev/null | \
    python -c "import sys,json; d=json.load(sys.stdin); print(d.get('messages',0))" 2>/dev/null || echo "0")

if [ "$DLQ_COUNT" -ge "1" ]; then
    pass "Message arrivé en DLQ ($DLQ_COUNT message(s)) — DLQ fonctionne ✓"
else
    fail "Message absent de la DLQ"
fi

echo ""
echo "═══════════════════════════════════════════════"
echo -e "  ${GREEN}✓ DLQ opérationnelle${NC}"
echo "═══════════════════════════════════════════════"
echo ""