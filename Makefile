.PHONY: up down build logs ps clean help test test-infra test-mysql test-s3 test-dlq benchmark benchmark-php benchmark-all

# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────
COMPOSE = docker compose
ENV_FILE = .env

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

## Logs du consumer Go uniquement
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

# ─────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────

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

# ─────────────────────────────────────────────
# Benchmarks
# ─────────────────────────────────────────────

## Lance le benchmark Go — paliers 100/500/1000/2000
## Usage : make benchmark N=5000
benchmark:
	bash benchmark/run-benchmark.sh $${N:-}

## Lance le benchmark PHP — paliers 100/500/1000/2000
## Usage : make benchmark-php N=5000
benchmark-php:
	bash benchmark/run-benchmark-php.sh $${N:-}

## Lance benchmark Go + PHP enchaînés (rapport complet)
benchmark-all:
	bash benchmark/run-benchmark.sh
	bash benchmark/run-benchmark-php.sh

# ─────────────────────────────────────────────
# Aide
# ─────────────────────────────────────────────

## Affiche les commandes disponibles
help:
	@echo ""
	@echo "Commandes disponibles :"
	@grep -E '^## ' Makefile | sed 's/## /  /'
	@echo ""