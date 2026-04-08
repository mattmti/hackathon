#!/bin/bash
# ─────────────────────────────────────────────────────────────
# test-dlq.sh — Vérifie le comportement de la Dead-Letter Queue
#
# Simule un message "poison" (mauvais format) et vérifie
# qu'après expiration du TTL il atterrit bien en DLQ.
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

# Purge la DLQ avant le test
info "Purge de la DLQ avant test..."
curl -s -o /dev/null \
    -u guest:guest \
    -X DELETE http://localhost:15672/api/queues/%2F/barcodes.dlq/contents
pass "DLQ purgée"

# Publie un message avec TTL très court (1 seconde) pour forcer le passage en DLQ
info "Publication d'un message avec TTL 1s (simulera l'expiration)..."
PUB=$(curl -s -o /dev/null -w "%{http_code}" \
    -u guest:guest \
    -H "Content-Type: application/json" \
    -X POST http://localhost:15672/api/exchanges/%2F//publish \
    -d '{
        "properties": {
            "message_id": "dlq-test-poison-001",
            "delivery_mode": 2,
            "expiration": "1000"
        },
        "routing_key": "barcodes",
        "payload": "{\"barcode\":\"INVALID\",\"format\":\"UNKNOWN\",\"message_id\":\"dlq-test-poison-001\"}",
        "payload_encoding": "string"
    }')

if [ "$PUB" = "200" ]; then
    pass "Message poison publié"
else
    fail "Échec publication — HTTP $PUB"
fi

# Attend l'expiration du TTL
info "Attente expiration TTL (2s)..."
sleep 2

# Vérifie que le message est passé en DLQ
DLQ_COUNT=$(curl -s -u guest:guest \
    http://localhost:15672/api/queues/%2F/barcodes.dlq 2>/dev/null | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('messages',0))" 2>/dev/null || echo "0")

if [ "$DLQ_COUNT" -ge "1" ]; then
    pass "Message arrivé en DLQ ($DLQ_COUNT message(s)) — DLQ fonctionne ✓"
else
    fail "Message absent de la DLQ — vérifier la config x-dead-letter-exchange"
fi

# Inspecte le message en DLQ
info "Contenu du message en DLQ :"
curl -s \
    -u guest:guest \
    -H "Content-Type: application/json" \
    -X POST http://localhost:15672/api/queues/%2F/barcodes.dlq/get \
    -d '{"count":1,"ackmode":"ack_requeue_true","encoding":"auto"}' | \
    python3 -c "
import sys, json
msgs = json.load(sys.stdin)
if msgs:
    m = msgs[0]
    print(f'  payload    : {m.get(\"payload\", \"\")}')
    print(f'  message_id : {m.get(\"properties\",{}).get(\"message_id\",\"\")}')
    x_death = m.get('properties',{}).get('headers',{}).get('x-death',[])
    if x_death:
        print(f'  reason     : {x_death[0].get(\"reason\",\"\")}')
        print(f'  queue orig : {x_death[0].get(\"queue\",\"\")}')
" 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════"
echo -e "  ${GREEN}✓ DLQ opérationnelle${NC}"
echo "═══════════════════════════════════════════════"
echo ""