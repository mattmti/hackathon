#!/bin/bash
# ─────────────────────────────────────────────────────────────
# test-mysql.sh — Vérifie le schéma MySQL et l'idempotence
# ─────────────────────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

MYSQL_USER="${MYSQL_USER:-barcode}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-barcode}"
MYSQL_DATABASE="${MYSQL_DATABASE:-barcode}"

PASS=0
FAIL=0

pass() { echo -e "${GREEN}✓ PASS${NC} — $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}✗ FAIL${NC} — $1"; FAIL=$((FAIL+1)); }
info() { echo -e "${YELLOW}▶${NC} $1"; }

mysql_q() {
    docker exec barcode-mysql \
        mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -sNe "$1" 2>/dev/null
}

echo ""
echo "═══════════════════════════════════════════════"
echo "  TEST MYSQL — Schéma + Idempotence"
echo "═══════════════════════════════════════════════"
echo ""

info "Vérification des tables..."
for TABLE in barcodes processed_messages dead_letter_messages; do
    COUNT=$(mysql_q "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$MYSQL_DATABASE' AND table_name='$TABLE';")
    if [ "$COUNT" = "1" ]; then
        pass "Table '$TABLE' présente"
    else
        fail "Table '$TABLE' absente"
    fi
done

info "Test idempotence (processed_messages)..."
TEST_UUID="550e8400-e29b-41d4-a716-$(date +%s)"
mysql_q "INSERT INTO processed_messages (message_id, barcode) VALUES ('$TEST_UUID', '1234567890128');"
pass "Premier insert OK"

mysql_q "INSERT IGNORE INTO processed_messages (message_id, barcode) VALUES ('$TEST_UUID', '1234567890128');"
COUNT=$(mysql_q "SELECT COUNT(*) FROM processed_messages WHERE message_id='$TEST_UUID';")
if [ "$COUNT" = "1" ]; then
    pass "Idempotence OK — double insert ignoré (INSERT IGNORE)"
else
    fail "Idempotence KO"
fi

mysql_q "DELETE FROM processed_messages WHERE message_id='$TEST_UUID';"

echo ""
echo "═══════════════════════════════════════════════"
TOTAL=$((PASS+FAIL))
echo -e "  Résultat : ${GREEN}$PASS OK${NC} / ${RED}$FAIL KO${NC} / $TOTAL tests"
echo "═══════════════════════════════════════════════"
echo ""

[ "$FAIL" -eq 0 ] && exit 0 || exit 1