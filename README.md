# Barcode Project — Documentation Technique

> Migration d'un consumer PHP vers Go pour la génération et la consommation de codes-barres.

---

## Table des matières

1. [Vue d'ensemble](#vue-densemble)
2. [Architecture](#architecture)
3. [Stack technique](#stack-technique)
4. [Démarrage rapide](#démarrage-rapide)
5. [Structure du projet](#structure-du-projet)
6. [Guide d'intégration — Équipe Go](#guide-dintégration--équipe-go)
7. [Variables d'environnement](#variables-denvironnement)
8. [Base de données](#base-de-données)
9. [RabbitMQ & DLQ](#rabbitmq--dlq)
10. [Passage en production](#passage-en-production)
11. [Commandes utiles](#commandes-utiles)

---

## Vue d'ensemble

Ce projet dockerise deux services Go qui remplacent les consumers PHP existants :

| Service PHP (origine) | Service Go (migration) | Rôle |
|-----------------------|------------------------|------|
| `BarcodeGenerator.php` | `barcode-generator` | Publie des messages dans RabbitMQ |
| `BarcodeGeneratorConsumer.php` | `barcode-generator-consumer` | Consomme les messages, génère les images, sauvegarde |

Le flux complet :

```
[Source de données] ──► barcode-generator ──► RabbitMQ (barcodes) ──► barcode-generator-consumer
                                                        │                         │
                                                        │                         ├── Génère image JPG (boombuler/barcode)
                                                        │                         ├── Sauvegarde locale / upload S3
                                                        │                         ├── Persiste en MySQL
                                                        │                         └── Retry/backoff → DLQ si échec
                                                        │
                                                        └── barcodes.dlq (messages en échec)
```

---

## Architecture

### Multi-stage build Docker

Les deux services utilisent un build en deux étapes :

- **Stage 1 — Builder** : `golang:1.23-alpine` — compile le binaire statique (CGO désactivé)
- **Stage 2 — Runtime** : `scratch` — image vide (~5 MB), contient uniquement le binaire

> ⚠️ L'image `scratch` ne contient pas de shell. `docker exec ... ls` ne fonctionne pas. Utiliser `docker cp` pour récupérer des fichiers.

### Healthchecks

Tous les services infrastructure exposent des healthchecks. Les services Go démarrent uniquement quand RabbitMQ, MySQL et S3 sont `healthy`.

### Retry / Backoff exponentiel

En cas d'échec de traitement, le consumer retente automatiquement :

```
Tentative 1 : immédiat
Tentative 2 : 500 ms
Tentative 3 : 1000 ms
Tentative 4 : → Nack → DLQ
```

Délai = `RETRY_INITIAL_DELAY_MS × 2^(attempt-1)`

### Idempotence

Chaque message est tracé dans la table `processed_messages` via son `message_id`. Si un message arrive deux fois, il est ignoré proprement.

---

## Stack technique

| Composant | Technologie | Port local |
|-----------|-------------|------------|
| Message broker | RabbitMQ 3.13 | 5672 / 15672 (UI) |
| Base de données | MySQL 8.4 | 3306 |
| Stockage S3 (local) | LocalStack 3.4 | 4566 |
| Generator | Go 1.23 | — |
| Consumer | Go 1.23 | — |

### Correspondance des librairies PHP → Go

| PHP (origine) | Go (migration) |
|---------------|----------------|
| `picqer/php-barcode-generator` | `boombuler/barcode` + `code128` |
| `imagine/imagine (GD)` | `image/jpeg` + `golang.org/x/image` |
| `Gaufrette S3` | `aws-sdk-go-v2/s3` |
| `Doctrine ORM` | `database/sql` + `go-sql-driver/mysql` |
| `php-amqplib` | `rabbitmq/amqp091-go` |
| `ramsey/uuid` | `google/uuid` |
| `monolog` | `go.uber.org/zap` + `log/slog` |

---

## Démarrage rapide

### Prérequis

- Docker ≥ 24.0
- Docker Compose ≥ 2.0
- Make
- Go 1.23+ (pour `go mod tidy` en local uniquement)

### Installation

```bash
# 1. Cloner le repo
git clone <repo-url>
cd barcode-project

# 2. Générer les go.sum (une seule fois)
cd barcode-generator && go mod tidy && cd ..
cd barcode-generator-consumer && go mod tidy && cd ..

# 3. Démarrer tous les services
make up

# 4. Vérifier que tout tourne
make ps
```

### Accès aux services

| Service | URL | Credentials |
|---------|-----|-------------|
| RabbitMQ Management | http://localhost:15672 | guest / guest |
| MySQL | localhost:3306 | barcode / barcode |
| S3 LocalStack | http://localhost:4566 | test / test |

---

## Structure du projet

```
barcode-project/
│
├── barcode-generator/                      # Service publisher
│   ├── Dockerfile
│   ├── go.mod
│   ├── barcodegen/
│   │   └── BarcodeGenerator.go            # ← Traduit depuis BarcodeGenerator.php
│   └── cmd/
│       └── main.go                        # ← Point d'entrée — À MODIFIER EN PROD
│
├── barcode-generator-consumer/             # Service consumer
│   ├── Dockerfile
│   ├── go.mod
│   ├── barcodegen/
│   │   └── BarcodeGenerator.go            # ← Traduit depuis BarcodeGenerator.php
│   ├── consumer/
│   │   └── BarcodeGeneratorConsumer.go    # ← Traduit depuis BarcodeGeneratorConsumer.php
│   └── cmd/
│       └── main.go                        # ← Point d'entrée (retry/DLQ/idempotence)
│
├── scripts/
│   ├── init.sql                           # Schéma MySQL
│   ├── init-s3.sh                         # Création du bucket S3 au démarrage
│   ├── rabbitmq-definitions.json          # Queues + DLQ préconfigurées
│   └── rabbitmq.conf
│
├── tests/
│   ├── run-all-tests.sh                   # Lance tous les tests d'infra
│   ├── test-infra.sh
│   ├── test-mysql.sh
│   ├── test-s3.sh
│   └── test-dlq.sh
│
├── benchmark/
│   └── results.md                         # Template benchmark PHP vs Go
│
├── docker-compose.yml
├── Makefile
├── .env.example
└── .gitignore
```

---

## Guide d'intégration — Équipe Go

> Cette section décrit précisément ce que l'équipe Go doit modifier pour connecter le vrai code métier.

### Format du message RabbitMQ

Tous les messages publiés dans la queue `barcodes` doivent respecter ce format JSON :

```json
{
  "barcode": "SPAREPART_4",
  "format": "CODE128",
  "title": "Montant Inférieur (#6) / Lower pole (4,5 FT)"
}
```

| Champ | Type | Description |
|-------|------|-------------|
| `barcode` | string | Valeur encodée dans le code-barre (ex: `SPAREPART_4`) |
| `format` | string | Format du code-barre (ex: `CODE128`, `EAN13`) |
| `title` | string | Titre affiché au-dessus du code-barre |

### Ce que l'équipe doit modifier

#### 1. `barcode-generator/cmd/main.go`

**Situation actuelle** : le generator publie un message hardcodé toutes les 5 secondes (mode démo).

**À modifier** : connecter la vraie source de données (API, base de données, événement métier) et publier le message au bon moment.

```go
// AVANT (mode démo — à remplacer)
for {
    body := `{"barcode":"1234567890128","format":"CODE128","title":"Test Barcode"}`
    ch.Publish(...)
    time.Sleep(5 * time.Second)
}

// APRÈS (exemple avec un vrai événement)
// Écouter une source de données (HTTP, DB polling, event bus...)
// et publier uniquement quand un nouveau barcode doit être généré :
for _, product := range newProducts {
    body := fmt.Sprintf(`{"barcode":"%s","format":"CODE128","title":"%s"}`,
        product.SKU, product.Title)
    ch.Publish("", queue, false, false, amqp.Publishing{
        ContentType:  "application/json",
        DeliveryMode: amqp.Persistent,
        MessageId:    uuid.New().String(), // ← important pour l'idempotence
        Body:         []byte(body),
    })
}
```

> ⚠️ **Important** : toujours renseigner le champ `MessageId` avec un UUID unique par message. Sans cela, l'idempotence ne fonctionne pas.

#### 2. `barcode-generator-consumer/barcodegen/BarcodeGenerator.go`

**Situation actuelle** : les images sont sauvegardées dans `output/` à l'intérieur du container (temporaire).

**À modifier pour la prod** : remplacer la sauvegarde locale par un upload S3.

```go
// AVANT (sauvegarde locale — dev uniquement)
func (g *BarcodeGenerator) GenerateBarcodeEntity(obj TestBarcodeOwner) (string, error) {
    imgBytes, _ := g.GenerateBarcodeImage(obj.Value, obj.Title)
    os.WriteFile("output/"+filename, imgBytes, 0644)
    return filename, nil
}

// APRÈS (upload S3 — prod)
func (g *BarcodeGenerator) GenerateBarcodeEntity(obj TestBarcodeOwner) (string, error) {
    imgBytes, _ := g.GenerateBarcodeImage(obj.Value, obj.Title)
    s3Key := fmt.Sprintf("barcodes/%s_%s.jpg", obj.ObjectType, obj.Value)
    g.s3Client.PutObject(ctx, &s3.PutObjectInput{
        Bucket:      aws.String(g.bucket),
        Key:         aws.String(s3Key),
        Body:        bytes.NewReader(imgBytes),
        ContentType: aws.String("image/jpeg"),
    })
    return s3Key, nil
}
```

Le client S3 est déjà configuré dans `barcode-generator-consumer/cmd/main.go` via `newS3Client()` — il suffit de le passer au `BarcodeGenerator`.

#### 3. `barcode-generator-consumer/consumer/BarcodeGeneratorConsumer.go`

**Situation actuelle** : fonctionne correctement, aucune modification requise pour la prod.

Le consumer parse le message, appelle `BarcodeGenerator.GenerateBarcodeEntity()` et loggue le résultat. Il suffit que `GenerateBarcodeEntity()` uploade sur S3 (point 2 ci-dessus).

---

## Variables d'environnement

Copier `.env.example` en `.env` et adapter les valeurs :

```bash
cp .env.example .env
```

| Variable | Description | Dev | Prod |
|----------|-------------|-----|------|
| `RABBITMQ_USER` | Utilisateur RabbitMQ | `guest` | À sécuriser |
| `RABBITMQ_PASS` | Mot de passe RabbitMQ | `guest` | À sécuriser |
| `RABBITMQ_QUEUE` | Queue principale | `barcodes` | `barcodes` |
| `RABBITMQ_DLQ` | Dead-letter queue | `barcodes.dlq` | `barcodes.dlq` |
| `MYSQL_USER` | Utilisateur MySQL | `barcode` | À sécuriser |
| `MYSQL_PASSWORD` | Mot de passe MySQL | `barcode` | À sécuriser |
| `MYSQL_DATABASE` | Nom de la base | `barcode` | `barcode` |
| `AWS_ENDPOINT` | Endpoint S3 | `http://localstack:4566` | Vide (AWS réel) |
| `AWS_REGION` | Région AWS | `eu-west-1` | Selon config |
| `AWS_ACCESS_KEY_ID` | Clé AWS | `test` | Clé IAM réelle |
| `AWS_SECRET_ACCESS_KEY` | Secret AWS | `test` | Secret IAM réel |
| `S3_BUCKET` | Nom du bucket | `barcodes` | Bucket prod |
| `LOG_LEVEL` | Niveau de log | `info` | `warn` |
| `RETRY_MAX` | Max retries | `3` | `3` |
| `RETRY_INITIAL_DELAY_MS` | Délai initial retry | `500` | `500` |

---

## Base de données

### Schéma

```sql
-- Codes-barres générés
barcodes (id, barcode, format, s3_key, s3_url, created_at, processed_at)

-- Idempotence — messages déjà traités
processed_messages (message_id PK, barcode, processed_at)

-- DLQ applicative — messages en échec après max retries
dead_letter_messages (id, message_id, barcode, payload JSON, error, attempts, failed_at)
```

### Surveiller les messages en échec

```sql
-- Voir les messages en DLQ
SELECT * FROM dead_letter_messages ORDER BY failed_at DESC;

-- Voir les codes-barres générés
SELECT * FROM barcodes ORDER BY created_at DESC;
```

---

## RabbitMQ & DLQ

### Queues configurées

| Queue | Rôle |
|-------|------|
| `barcodes` | Queue principale — messages entrants |
| `barcodes.dlq` | Dead-letter queue — messages en échec |

### Visualiser les queues

Ouvrir http://localhost:15672 (guest / guest) → onglet **Queues**.

### Un message va en DLQ quand

1. Le consumer échoue 3 fois de suite (`RETRY_MAX=3`)
2. Le TTL du message expire (24h par défaut)

---

## Passage en production

Checklist avant de passer en prod :

- [ ] Remplacer la boucle de démo dans `barcode-generator/cmd/main.go` par la vraie source de données
- [ ] Ajouter l'upload S3 dans `BarcodeGenerator.GenerateBarcodeEntity()`
- [ ] Supprimer `localstack` du `docker-compose.yml` (ou créer un `docker-compose.prod.yml`)
- [ ] Renseigner les vraies credentials AWS dans `.env`
- [ ] Sécuriser les credentials RabbitMQ et MySQL dans `.env`
- [ ] Retirer `AWS_ENDPOINT` du `.env` (vide = AWS réel)
- [ ] Passer `LOG_LEVEL=warn` en prod
- [ ] Vérifier que le bucket S3 prod existe et que l'IAM a les droits `s3:PutObject`

---

## Commandes utiles

```bash
make up                                          # Démarrer tout
make down                                        # Arrêter tout
make clean                                       # Reset complet (volumes inclus)
make logs                                        # Logs temps réel — tous les services
make logs-generator                              # Logs du generator uniquement
make logs-consumer                               # Logs du consumer uniquement
make ps                                          # Statut des containers
make restart SERVICE=barcode-generator-consumer  # Rebuild + restart un service
make test                                        # Lancer tous les tests d'infra
make test-mysql                                  # Test MySQL uniquement
make test-s3                                     # Test S3 uniquement
make test-dlq                                    # Test DLQ uniquement
```

### Récupérer un fichier généré (dev)

```bash
# Lister les fichiers générés
docker cp barcode-generator-consumer:/output/ ./output-local/

# Récupérer un fichier spécifique
docker cp barcode-generator-consumer:/output/CODE128_SPAREPART_4.jpg .
```

---

## Benchmark PHP vs Go

Voir [`benchmark/results.md`](./benchmark/results.md) pour le template de comparaison des performances.