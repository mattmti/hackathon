.PHONY: up down build logs ps clean help test test-infra test-mysql test-s3 test-dlq benchmark

# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────
COMPOSE = docker compose
ENV_FILE = .env

# Crée le .env s'il n'existe pas
$(ENV_FILE):
	cp .env.example $(ENV_FILE)
	@echo "✓ .env créé depuis .env.example — pense à le personnaliser"

# ─────────────────────────────────────────────
# Commandes principales
# ─────────────────────────────────────────────

## Démarre tous les services (build si nécessaire)
up: $(ENV_FILE)
	$(COMPOSE) up -d --build
	@echo ""
	@echo "✓ Services démarrés"
	@echo "  RabbitMQ UI  → http://localhost:15672  (guest/guest)"
	@echo "  MySQL        → localhost:3306"
	@echo "  S3 local     → http://localhost:4566"

## Arrête tous les services
down:
	$(COMPOSE) down

## Arrête et supprime les volumes (reset complet)
clean:
	$(COMPOSE) down -v --remove-orphans
	@echo "✓ Volumes supprimés"

## Build les images sans démarrer
build:
	$(COMPOSE) build

## Logs en temps réel (tous les services)
logs:
	$(COMPOSE) logs -f

## Logs du consumer uniquement
logs-consumer:
	$(COMPOSE) logs -f barcode-generator-consumer

## Logs du generator uniquement
logs-generator:
	$(COMPOSE) logs -f barcode-generator

## Statut des services
ps:
	$(COMPOSE) ps

## Rebuild et redémarre un service spécifique
## Usage : make restart SERVICE=barcode-generator-consumer
restart:
	$(COMPOSE) up -d --build $(SERVICE)

## Ouvre un shell dans un service
## Usage : make shell SERVICE=barcode-generator-consumer
shell:
	$(COMPOSE) exec $(SERVICE) sh

## Lance tous les tests d'infra
test:
	bash tests/run-all-tests.sh

## Lance uniquement le test infra global
test-infra:
	bash tests/test-infra.sh

## Lance uniquement le test MySQL
test-mysql:
	bash tests/test-mysql.sh

## Lance uniquement le test S3
test-s3:
	bash tests/test-s3.sh

## Lance uniquement le test DLQ
test-dlq:
	bash tests/test-dlq.sh

## Lance le benchmark Go (défaut: 1000 messages)
## Usage : make benchmark N=5000
benchmark:
	bash benchmark/run-benchmark.sh $${N:-1000}

## Aide
help:
	@echo ""
	@echo "Commandes disponibles :"
	@grep -E '^## ' Makefile | sed 's/## /  /'
	@echo ""