#!/bin/bash
# ─────────────────────────────────────────────────────────────
# run-all-tests.sh — Lance tous les tests d'infra
# Usage : ./tests/run-all-tests.sh
# ─────────────────────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OVERALL_PASS=true

run_test() {
    local NAME=$1
    local SCRIPT=$2
    echo ""
    echo -e "${BOLD}━━━ $NAME ━━━${NC}"
    if bash "$SCRIPT"; then
        echo -e "${GREEN}✓ $NAME : OK${NC}"
    else
        echo -e "${RED}✗ $NAME : ÉCHEC${NC}"
        OVERALL_PASS=false
    fi
}

echo ""
echo -e "${BOLD}╔═══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   TESTS INFRA — Barcode Project           ║${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════════╝${NC}"

# Attendre que les services soient prêts
echo ""
echo -e "${YELLOW}▶ Attente que les services soient healthy...${NC}"
sleep 3

run_test "Infrastructure globale"  "$SCRIPT_DIR/test-infra.sh"
run_test "MySQL + Schéma"     "$SCRIPT_DIR/test-mysql.sh"
run_test "S3 / LocalStack"         "$SCRIPT_DIR/test-s3.sh"
run_test "Dead-Letter Queue"       "$SCRIPT_DIR/test-dlq.sh"

echo ""
echo -e "${BOLD}╔═══════════════════════════════════════════╗${NC}"
if $OVERALL_PASS; then
    echo -e "${BOLD}║  ${GREEN}✓ TOUS LES TESTS PASSENT${NC}${BOLD}               ║${NC}"
    echo -e "${BOLD}║  L'infra est prête pour l'équipe Go.      ║${NC}"
else
    echo -e "${BOLD}║  ${RED}✗ DES TESTS ONT ÉCHOUÉ${NC}${BOLD}                ║${NC}"
    echo -e "${BOLD}║  Lance 'make logs' pour diagnostiquer.    ║${NC}"
fi
echo -e "${BOLD}╚═══════════════════════════════════════════╝${NC}"
echo ""

$OVERALL_PASS && exit 0 || exit 1