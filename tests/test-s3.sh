#!/bin/bash
# ─────────────────────────────────────────────────────────────
# test-s3.sh — Vérifie que S3 (LocalStack) fonctionne
#
# Teste : upload, listing, download, delete
# ─────────────────────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

BUCKET="${S3_BUCKET:-barcodes}"
TEST_KEY="test/barcode-test-$(date +%s).txt"
TEST_CONTENT="barcode-test-EAN13-1234567890128"

pass() { echo -e "${GREEN}✓ PASS${NC} — $1"; }
fail() { echo -e "${RED}✗ FAIL${NC} — $1"; exit 1; }
info() { echo -e "${YELLOW}▶${NC} $1"; }

echo ""
echo "═══════════════════════════════════════════════"
echo "  TEST S3 — LocalStack"
echo "═══════════════════════════════════════════════"
echo ""

# 1. Bucket existe ?
info "Vérification du bucket '$BUCKET'..."
BUCKET_EXISTS=$(docker exec barcode-s3 \
    awslocal s3 ls 2>/dev/null | grep "$BUCKET" || echo "")

if [ -n "$BUCKET_EXISTS" ]; then
    pass "Bucket '$BUCKET' existe"
else
    info "Bucket absent, création..."
    docker exec barcode-s3 awslocal s3 mb "s3://$BUCKET" --region eu-west-1
    pass "Bucket '$BUCKET' créé"
fi

# 2. Upload
info "Upload d'un fichier test..."
echo "$TEST_CONTENT" | docker exec -i barcode-s3 \
    awslocal s3 cp - "s3://$BUCKET/$TEST_KEY" 2>/dev/null
pass "Upload OK → s3://$BUCKET/$TEST_KEY"

# 3. List
info "Listing du bucket..."
LISTED=$(docker exec barcode-s3 \
    awslocal s3 ls "s3://$BUCKET/test/" 2>/dev/null | grep "barcode-test" || echo "")

if [ -n "$LISTED" ]; then
    pass "Fichier visible dans le listing"
else
    fail "Fichier absent du listing"
fi

# 4. Download + vérification contenu
info "Download et vérification du contenu..."
DOWNLOADED=$(docker exec barcode-s3 \
    awslocal s3 cp "s3://$BUCKET/$TEST_KEY" - 2>/dev/null || echo "")

if echo "$DOWNLOADED" | grep -q "$TEST_CONTENT"; then
    pass "Contenu du fichier correct"
else
    fail "Contenu incorrect — attendu: '$TEST_CONTENT', reçu: '$DOWNLOADED'"
fi

# 5. Cleanup
info "Suppression du fichier test..."
docker exec barcode-s3 awslocal s3 rm "s3://$BUCKET/$TEST_KEY" 2>/dev/null
pass "Fichier supprimé"

echo ""
echo "═══════════════════════════════════════════════"
echo -e "  ${GREEN}✓ S3 opérationnel — upload/download/delete OK${NC}"
echo "═══════════════════════════════════════════════"
echo ""