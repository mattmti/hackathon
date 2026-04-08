# Barcode Project — Documentation Technique

## Vue d'ensemble

Migration d'un consumer PHP vers Go pour la génération et la consommation de codes-barres EAN-13.

```
Publisher ──► RabbitMQ (barcodes) ──► barcode-generator-consumer
                     │                          │
                     │                          ├── Génère PNG via boombuler/barcode
                     │                          ├── Upload S3 (aws-sdk-go-v2)
                     │                          ├── Persiste en MySQL (sqlx)
                     │                          └── Retry/backoff → DLQ si échec
                     │
                     └── barcodes.dlq (dead-letter queue)
```

---

## Stack Technique

| Composant | Technologie | Port |
|-----------|-------------|------|
| Message broker | RabbitMQ 3.13 | 5672 / 15672 (UI) |
| Base de données | MySQL 8.4 | 3306 |
| Stockage S3 local | LocalStack 3.4 | 4566 |
| Generator | Go 1.22 | — |
| Consumer | Go 1.22 | — |

### Librairies Go

| PHP (origine) | Go (migration) |
|---------------|----------------|
| `picqer/php-barcode-generator` | `boombuler/barcode` |
| `imagine/imagine (GD)` | `image/jpeg` + `golang.org/x/image` |
| `Gaufrette S3` | `aws-sdk-go-v2/s3` |
| `Doctrine ORM` | `database/sql` + `sqlx` |
| `php-amqplib` | `rabbitmq/amqp091-go` |
| `ramsey/uuid` | `google/uuid v5` |

---

## Démarrage rapide

### Prérequis
- Docker ≥ 24.0
- Docker Compose ≥ 2.0
- Make

### Lancer l'environnement

```bash
# 1. Cloner le repo
git clone <repo-url>
cd barcode-project

# 2. Démarrer tous les services
make up

# 3. Vérifier que tout tourne
make ps
```

### Accès aux services

| Service | URL | Credentials |
|---------|-----|-------------|
| RabbitMQ Management | http://localhost:15672 | guest / guest |
| MySQL | localhost:3306 | barcode / barcode |
| S3 (LocalStack) | http://localhost:4566 | test / test |

---

## Architecture Docker

### Multi-stage build

Les deux services Go utilisent un **multi-stage build** :

- **Stage 1 (builder)** : `golang:1.22-alpine` — compile le binaire avec CGO désactivé
- **Stage 2 (runtime)** : `scratch` — image vide, contient uniquement le binaire

Résultat : image finale ~10 MB au lieu de ~300 MB avec une image Go complète.

```dockerfile
FROM golang:1.22-alpine AS builder
# ... compilation ...

FROM scratch
COPY --from=builder /app/binary /binary
ENTRYPOINT ["/binary"]
```

### Healthchecks

Tous les services infrastructure (RabbitMQ, MySQL, LocalStack) exposent des healthchecks. Les services Go démarrent uniquement quand tous les healthchecks passent (`condition: service_healthy`).

---

## RabbitMQ — Configuration

### Queues

| Queue | Rôle |
|-------|------|
| `barcodes` | Queue principale — messages entrants |
| `barcodes.dlq` | Dead-letter queue — messages en échec |

### Dead-Letter Queue (DLQ)

La queue `barcodes` est configurée avec :
- `x-dead-letter-exchange: barcodes.dlx` — exchange DLQ dédié
- `x-dead-letter-routing-key: barcodes.dlq`
- `x-message-ttl: 86400000` — TTL 24h

Un message est envoyé en DLQ quand :
1. Le consumer le `Nack` avec `requeue=false`
2. Le TTL expire

---

## Consumer Go — Patterns attendus

### Retry / Backoff exponentiel

```
Tentative 1 : immédiat
Tentative 2 : 500ms
Tentative 3 : 1000ms
Tentative 4 : → Nack → DLQ
```

Délai = `RETRY_INITIAL_DELAY_MS * 2^(attempt-1)`

### Idempotence

Chaque message doit porter un `message_id` (UUID). Avant traitement :

```sql
-- Vérifier si déjà traité
SELECT 1 FROM processed_messages WHERE message_id = $1;

-- Après traitement réussi
INSERT INTO processed_messages (message_id, barcode) VALUES ($1, $2);
```

### Logs structurés (slog)

Format JSON obligatoire. Champs minimum :

```json
{
  "time": "2024-01-15T10:30:00Z",
  "level": "INFO",
  "msg": "message processed",
  "barcode": "1234567890128",
  "message_id": "550e8400-e29b-41d4-a716-446655440000",
  "attempt": 1,
  "duration_ms": 42
}
```

### Graceful shutdown

Le consumer doit écouter `SIGTERM` (envoyé par `docker stop`) :

```go
ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
defer cancel()
// ... consumer loop ...
<-ctx.Done() // attend le signal
// ... cleanup (close connections, ack pending messages) ...
```

---

## Base de données — Schéma

```sql
-- Messages traités (idempotence)
processed_messages (message_id UUID PK, barcode, processed_at)

-- Codes-barres générés
barcodes (id UUID PK, barcode, format, s3_key, s3_url, created_at, processed_at)

-- Messages en échec (DLQ applicative)
dead_letter_messages (id, message_id, barcode, payload JSON, error, attempts, failed_at)
```

---

## Variables d'environnement

| Variable | Description | Défaut |
|----------|-------------|--------|
| `RABBITMQ_URL` | URL de connexion AMQP | `amqp://guest:guest@rabbitmq:5672/` |
| `RABBITMQ_QUEUE` | Nom de la queue principale | `barcodes` |
| `RABBITMQ_DLQ` | Nom de la dead-letter queue | `barcodes.dlq` |
| `AWS_ENDPOINT` | Endpoint S3 (vide = AWS réel) | `http://localstack:4566` |
| `AWS_REGION` | Région AWS | `eu-west-1` |
| `S3_BUCKET` | Nom du bucket | `barcodes` |
| `DATABASE_URL` | DSN MySQL | `barcode:barcode@tcp(mysql:3306)/barcode?parseTime=true` |
| `LOG_LEVEL` | Niveau de log | `info` |
| `RETRY_MAX` | Nombre max de retries | `3` |
| `RETRY_INITIAL_DELAY_MS` | Délai initial retry (ms) | `500` |

---

## Commandes utiles

```bash
make up                              # Démarrer tout
make down                            # Arrêter tout
make clean                           # Reset complet (volumes inclus)
make logs                            # Logs de tous les services
make logs-consumer                   # Logs du consumer uniquement
make restart SERVICE=barcode-generator-consumer  # Rebuild + restart un service
make shell SERVICE=barcode-generator-consumer    # Shell dans un container
```

---

## Benchmark PHP vs Go

Voir [`benchmark/results.md`](./benchmark/results.md) pour le template et les résultats.

---

## Pour l'équipe Go

1. **Remplacer** `barcode-generator/cmd/main.go` et `barcode-generator-consumer/cmd/main.go` par le vrai code
2. **Mettre à jour** `go.sum` (`go mod tidy` après ajout des imports réels)
3. **Lancer** `make up` — tout le reste est prêt
4. **Vérifier** les logs avec `make logs`

L'équipe n'a **aucune config Docker à toucher** — seulement le code Go.