#!/bin/bash
# ─────────────────────────────────────────────────────────────
# test-infra.sh — Vérifie que toute l'infra est opérationnelle
# Usage : ./tests/test-infra.sh
# ─────────────────────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "${GREEN}✓ PASS${NC} — $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}✗ FAIL${NC} — $1"; FAIL=$((FAIL+1)); }
info() { echo -e "${YELLOW}▶${NC} $1"; }

echo ""
echo "═══════════════════════════════════════════════"
echo "  TEST INFRA — Barcode Project"
echo "═══════════════════════════════════════════════"
echo ""

# ─────────────────────────────────────────────
# 1. Docker Compose — services up
# ─────────────────────────────────────────────
info "Vérification des containers Docker..."

for SERVICE in barcode-rabbitmq barcode-mysql barcode-s3; do
    STATUS=$(docker inspect -f '{{.State.Health.Status}}' "$SERVICE" 2>/dev/null || echo "not found")
    if [ "$STATUS" = "healthy" ]; then
        pass "Container $SERVICE est healthy"
    else
        fail "Container $SERVICE — status: $STATUS"
    fi
done

# ─────────────────────────────────────────────
# 2. RabbitMQ — API de management
# ─────────────────────────────────────────────
info "Test RabbitMQ..."

RABBIT_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -u guest:guest http://localhost:15672/api/overview)

if [ "$RABBIT_STATUS" = "200" ]; then
    pass "RabbitMQ Management API répond (HTTP 200)"
else
    fail "RabbitMQ Management API — HTTP $RABBIT_STATUS"
fi

QUEUE=$(curl -s -u guest:guest \
    http://localhost:15672/api/queues/%2F/barcodes 2>/dev/null | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('name',''))" 2>/dev/null || echo "")

if [ "$QUEUE" = "barcodes" ]; then
    pass "Queue 'barcodes' existe"
else
    fail "Queue 'barcodes' introuvable"
fi

DLQ=$(curl -s -u guest:guest \
    http://localhost:15672/api/queues/%2F/barcodes.dlq 2>/dev/null | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('name',''))" 2>/dev/null || echo "")

if [ "$DLQ" = "barcodes.dlq" ]; then
    pass "Dead-letter queue 'barcodes.dlq' existe"
else
    fail "Dead-letter queue 'barcodes.dlq' introuvable"
fi

# ─────────────────────────────────────────────
# 3. MySQL — connexion + tables
# ─────────────────────────────────────────────
info "Test MySQL..."

MYSQL_OK=$(docker exec barcode-mysql \
    mysql -ubarcode -pbarcode barcode -sNe "SELECT 1" 2>/dev/null || echo "")

if [ "$MYSQL_OK" = "1" ]; then
    pass "MySQL connexion OK"
else
    fail "MySQL connexion échouée"
fi

for TABLE in barcodes processed_messages dead_letter_messages; do
    EXISTS=$(docker exec barcode-mysql \
        mysql -ubarcode -pbarcode barcode -sNe \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='barcode' AND table_name='$TABLE';" 2>/dev/null || echo "0")
    if [ "$EXISTS" = "1" ]; then
        pass "Table '$TABLE' existe"
    else
        fail "Table '$TABLE' introuvable"
    fi
done

# ─────────────────────────────────────────────
# 4. S3 / LocalStack — bucket
# ─────────────────────────────────────────────
info "Test S3 (LocalStack)..."

S3_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" \
    http://localhost:4566/_localstack/health)

if [ "$S3_HEALTH" = "200" ]; then
    pass "LocalStack répond (HTTP 200)"
else
    fail "LocalStack — HTTP $S3_HEALTH"
fi

BUCKET=$(docker exec barcode-s3 \
    awslocal s3 ls 2>/dev/null | grep "barcodes" || echo "")

if [ -n "$BUCKET" ]; then
    pass "Bucket S3 'barcodes' existe"
else
    fail "Bucket S3 'barcodes' introuvable"
fi

# ─────────────────────────────────────────────
# 5. Publish + Consume test (RabbitMQ round-trip)
# ─────────────────────────────────────────────
info "Test publish/consume RabbitMQ (round-trip)..."

PUB=$(curl -s -o /dev/null -w "%{http_code}" \
    -u guest:guest \
    -H "Content-Type: application/json" \
    -X POST http://localhost:15672/api/exchanges/%2F//publish \
    -d '{
        "properties": {"message_id": "test-infra-001", "delivery_mode": 2},
        "routing_key": "barcodes",
        "payload": "{\"barcode\":\"1234567890128\",\"format\":\"EAN13\",\"message_id\":\"test-infra-001\"}",
        "payload_encoding": "string"
    }')

if [ "$PUB" = "200" ]; then
    pass "Publication d'un message de test OK"
else
    fail "Publication message — HTTP $PUB"
fi

sleep 1
MSG_COUNT=$(curl -s -u guest:guest \
    http://localhost:15672/api/queues/%2F/barcodes 2>/dev/null | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('messages',0))" 2>/dev/null || echo "0")

if [ "$MSG_COUNT" -ge "1" ]; then
    pass "Message visible dans la queue ($MSG_COUNT message(s))"
else
    fail "Aucun message dans la queue après publication"
fi

# ─────────────────────────────────────────────
# Résumé
# ─────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════"
TOTAL=$((PASS+FAIL))
echo -e "  Résultat : ${GREEN}$PASS OK${NC} / ${RED}$FAIL KO${NC} / $TOTAL tests"
echo "═══════════════════════════════════════════════"
echo ""

if [ "$FAIL" -gt "0" ]; then
    echo -e "${RED}⚠ Des tests ont échoué. Lance 'make logs' pour diagnostiquer.${NC}"
    exit 1
else
    echo -e "${GREEN}✓ Infra opérationnelle — l'équipe Go peut déposer son code.${NC}"
    exit 0
fi