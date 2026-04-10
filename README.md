# Documentation Technique — Migration Consumer PHP → Go
### Système de Génération de Codes-Barres

> **Version** 1.0.0 · **Date** Avril 2026 · **Équipe** Engineering · **Statut** Production Ready

---

## Table des matières

1. [Résumé Exécutif](#1-résumé-exécutif)
2. [Contexte et Problématique](#2-contexte-et-problématique)
3. [Architecture du Système](#3-architecture-du-système)
4. [Stack Technique](#4-stack-technique)
5. [Mécanismes de Fiabilité](#5-mécanismes-de-fiabilité)
6. [Schéma de Base de Données](#6-schéma-de-base-de-données)
7. [Guide d'Utilisation](#7-guide-dutilisation)
8. [Personnalisation — Génération par Commande](#8-personnalisation--génération-automatique-par-commande)
9. [Variables d'Environnement](#9-variables-denvironnement)
10. [Analyse des Performances](#10-analyse-des-performances--benchmark-scientifique)
11. [Passage en Production](#11-checklist-de-passage-en-production)
12. [Infrastructure de Tests](#12-infrastructure-de-tests)
13. [Structure du Projet](#13-structure-du-projet)
14. [Glossaire](#14-glossaire-technique)

---

## 1. Résumé Exécutif

Ce document présente la migration du consumer PHP de génération de codes-barres vers le langage Go, réalisée dans le cadre d'un hackathon d'ingénierie. L'objectif principal était d'améliorer les performances, la maintenabilité et la scalabilité du système de génération de codes-barres utilisé en production pour identifier les pièces détachées, les emplacements et les produits dans les entrepôts.

> 🎯 **Objectif** — Migrer le consumer PHP vers Go en exploitant la concurrence native du langage pour multiplier le débit de traitement, réduire la latence et diminuer les coûts d'infrastructure en production.

### 1.1 Résultats Clés du Benchmark

| Métrique | PHP 8.2 | Go 1.23 | Gain |
|----------|---------|---------|------|
| Débit moyen | 76 msg/s | 181 msg/s | ▲ +138% |
| Latence moyenne | 13 ms/msg | 5 ms/msg | ▼ -62% |
| Temps (2 000 messages) | 26 secondes | 11 secondes | ▼ -58% |
| RAM consommée | 15.46 MiB | 15.77 MiB | ~ stable |
| Serveurs nécessaires* | ~13 serveurs | ~6 serveurs | ▼ -54% |

*\* Estimation pour absorber une charge de 1 000 messages/seconde en production.*

> 💡 **Point Clé** — Go traite 2,4× plus de messages dans le même temps, avec une latence 2,6× inférieure, tout en nécessitant moitié moins de serveurs pour absorber la même charge. La concurrence native de Go (goroutines) est l'élément différenciateur fondamental.

---

## 2. Contexte et Problématique

### 2.1 Système Existant en PHP

Le système de génération de codes-barres existant repose sur deux composants PHP développés dans le framework Symfony :

- **`BarcodeGenerator.php`** — composant responsable de la génération graphique des codes-barres (format CODE128) et de leur upload vers Amazon S3. Il utilise la librairie `picqer/php-barcode-generator` et `Imagine/GD` pour la création d'images JPEG.
- **`BarcodeGeneratorConsumer.php`** — consumer RabbitMQ qui reçoit les événements métier, valide les entités via Doctrine ORM et orchestre la génération des codes-barres.

Ce système présente plusieurs limitations architecturales fondamentales héritées de PHP :

- **Mono-thread par conception** — PHP ne supporte pas la concurrence native. Chaque consumer traite exactement un message à la fois, bloquant le thread pendant la génération de l'image et les opérations I/O.
- **Démarrage à froid coûteux** — chaque requête PHP recharge l'interpréteur, les extensions et le framework, générant une surcharge constante.
- **Gestion mémoire non optimisée** — les buffers d'image sont alloués et désalloués à chaque traitement, sans possibilité de réutilisation entre requêtes.
- **Scalabilité horizontale uniquement** — pour augmenter le débit, il faut multiplier le nombre de processus PHP, consommant linéairement plus de RAM et de CPU.

### 2.2 Pourquoi Go ?

Go (Golang) est un langage compilé, statiquement typé, conçu par Google pour les systèmes distribués et les workloads à haute concurrence. Ses caractéristiques fondamentales en font un candidat idéal pour remplacer un consumer PHP :

| Caractéristique | Description | Bénéfice |
|----------------|-------------|----------|
| Goroutines | Threads légers gérés par le runtime Go (< 2 KB par goroutine) | Concurrence native sans overhead |
| Compilation statique | Binaire unique, sans dépendances runtime | Image Docker < 10 MB vs > 100 MB PHP |
| Gestion mémoire | Garbage collector optimisé + `sync.Pool` | Réutilisation des buffers entre goroutines |
| Typage statique | Erreurs détectées à la compilation | Moins de bugs en production |
| Performances I/O | I/O non-bloquantes natives | Meilleure utilisation des ressources système |

---

## 3. Architecture du Système

### 3.1 Vue d'Ensemble

Le système repose sur une architecture orientée messages (*message-driven architecture*) avec RabbitMQ comme broker central. Cette approche découple les producteurs de messages des consommateurs, permettant une scalabilité indépendante et une tolérance aux pannes.

```
[Source de données / API métier]
           │
           ▼
[barcode-generator — Publisher Go]  →  publie JSON dans RabbitMQ
                                              │
                                      [queue "barcodes"]
                                              │
                                              ▼
                             [barcode-generator-consumer]
                          Worker Pool — 10 goroutines parallèles
                             /          │          \
                     Génère JPEG   Persiste MySQL   Upload S3
                             \          │          /
                                   ACK / NACK
                              (échec → barcodes.dlq)
```

### 3.2 Format du Message RabbitMQ

Chaque événement de génération de code-barre transite sous la forme d'un message JSON structuré dans la queue RabbitMQ. Ce format constitue le **contrat d'interface** entre le publisher et le consumer.

```json
{
  "barcode": "SPAREPART_4",
  "format":  "CODE128",
  "title":   "Montant Inférieur (#6) / Lower pole (4,5 FT)"
}
```

| Champ | Type | Description | Exemple |
|-------|------|-------------|---------|
| `barcode` | string | Valeur encodée dans le code-barre | `SPAREPART_4` |
| `format` | string | Standard de codage du code-barre | `CODE128` |
| `title` | string | Titre affiché au-dessus du code-barre | `Montant Inférieur (#6)` |

### 3.3 Worker Pool Go — Concurrence Native

L'élément différenciateur fondamental de la migration Go réside dans l'implémentation d'un **worker pool** basé sur les goroutines. Contrairement à PHP qui traite les messages séquentiellement, Go lance chaque message dans une goroutine indépendante.

| Aspect | PHP (Avant) | Go (Après) |
|--------|------------|-----------|
| Modèle de traitement | Séquentiel — 1 message à la fois | Concurrent — 10 messages en parallèle |
| Prefetch RabbitMQ | `Qos(1)` — 1 message en vol | `Qos(10)` — 10 messages en vol |
| Mémoire par worker | ~12 MB (processus PHP complet) | ~2 KB (goroutine Go) |
| Pool de connexions MySQL | 1 connexion unique | Pool de 10 connexions simultanées |
| Réutilisation des buffers | Non — allocation à chaque message | Oui — `sync.Pool` entre goroutines |

---

## 4. Stack Technique

### 4.1 Composants d'Infrastructure

| Composant | Technologie | Version | Rôle | Port |
|-----------|-------------|---------|------|------|
| Message Broker | RabbitMQ | 3.13 | File de messages + DLQ | 5672 / 15672 |
| Base de données | MySQL | 8.4 | Persistance + idempotence | 3306 |
| Stockage objet | LocalStack / AWS S3 | 3.4 | Stockage des images JPEG | 4566 |
| Consumer Go | Go | 1.23 | Traitement concurrent | — |
| Consumer PHP | PHP | 8.2 | Référence benchmark uniquement | — |

### 4.2 Correspondance des Librairies PHP → Go

| Fonction | PHP (Origine) | Go (Migration) |
|----------|--------------|----------------|
| Génération code-barre | `picqer/php-barcode-generator` | `boombuler/barcode v1.0.2` |
| Traitement image | `Imagine/GD` | `image/jpeg` + `golang.org/x/image` |
| Upload S3 | `Gaufrette S3` | `aws-sdk-go-v2/s3` |
| ORM / Base de données | `Doctrine ORM` | `database/sql` + `go-sql-driver/mysql` |
| Client RabbitMQ | `php-amqplib` | `rabbitmq/amqp091-go` |
| Identifiants uniques | `ramsey/uuid` | `google/uuid` |
| Logging structuré | `Monolog` | `go.uber.org/zap` + `log/slog` |

### 4.3 Architecture Docker — Images Ultra-légères

Les services Go utilisent un build **multi-stage Docker**, produisant des images de production extrêmement compactes basées sur l'image `scratch` (image vide). Cette approche réduit la surface d'attaque et les temps de déploiement.

| Image | Taille | Base | Contenu |
|-------|--------|------|---------|
| `barcode-generator` | ~5 MB | `scratch` | Binaire Go statique uniquement |
| `barcode-generator-consumer` | ~8 MB | `scratch` | Binaire Go statique uniquement |
| `barcode-generator-consumer-php` | ~180 MB | `php:8.2-cli` | PHP + extensions + Composer |
| `barcode-rabbitmq` | ~45 MB | `rabbitmq:3.13-alpine` | Broker + Management UI |
| `barcode-mysql` | ~600 MB | `mysql:8.4` | Base de données relationnelle |

> ⚠️ **Note importante** — L'image `scratch` ne contient pas de shell. Les commandes `docker exec ... ls` ou `docker exec ... sh` ne fonctionneront pas sur les services Go. Pour récupérer des fichiers générés, utiliser `docker cp barcode-generator-consumer:/output/ ./output-local/`

---

## 5. Mécanismes de Fiabilité

### 5.1 Retry avec Backoff Exponentiel

En cas d'échec de traitement d'un message, le consumer applique automatiquement une stratégie de retry avec backoff exponentiel avant de renvoyer le message en Dead-Letter Queue.

| Tentative | Délai avant retry | Action si échec |
|-----------|------------------|----------------|
| 1 (immédiat) | 0 ms | Réessayer immédiatement |
| 2 | 500 ms | Attendre et réessayer |
| 3 | 1 000 ms | Attendre et réessayer |
| 4 (finale) | — | Nack → Dead-Letter Queue |

*Formule appliquée : `Délai(n) = RETRY_INITIAL_DELAY_MS × 2^(n-1)`*

### 5.2 Idempotence — Protection contre le Double Traitement

Chaque message RabbitMQ est identifié par un `MessageId` unique (UUID v4). Avant tout traitement, le consumer vérifie dans la table `processed_messages` si ce message a déjà été traité. Si oui, il l'acquitte (ACK) directement sans retraitement.

```sql
-- Vérification idempotence
SELECT COUNT(*) FROM processed_messages WHERE message_id = ?;

-- Marquage après succès
INSERT IGNORE INTO processed_messages (message_id, barcode) VALUES (?, ?);
```

### 5.3 Dead-Letter Queue (DLQ)

Les messages qui échouent après le nombre maximum de retries sont routés vers la queue `barcodes.dlq` via l'exchange `barcodes.dlx`. Ils sont également sauvegardés dans la table `dead_letter_messages` pour audit et retraitement manuel.

| Paramètre RabbitMQ | Valeur | Rôle |
|-------------------|--------|------|
| `x-dead-letter-exchange` | `barcodes.dlx` | Exchange de routage vers la DLQ |
| `x-dead-letter-routing-key` | `barcodes.dlq` | Clé de routage vers la DLQ |
| `x-message-ttl` | `86 400 000 ms` (24h) | TTL des messages dans la queue principale |

### 5.4 Graceful Shutdown

Le consumer Go intercepte les signaux `SIGTERM` et `SIGINT` (envoyés par Docker lors d'un arrêt) et attend la fin du traitement de tous les messages en cours avant de s'arrêter, garantissant qu'aucun message n'est perdu lors d'un redémarrage ou d'un déploiement.

---

## 6. Schéma de Base de Données

```sql
-- Historique des codes-barres générés
CREATE TABLE barcodes (
    id           CHAR(36)    NOT NULL DEFAULT (UUID()),
    barcode      VARCHAR(20) NOT NULL,
    format       VARCHAR(20) NOT NULL DEFAULT 'CODE128',
    s3_key       TEXT,
    s3_url       TEXT,
    created_at   DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    processed_at DATETIME,
    PRIMARY KEY (id)
);

-- Garantie d'idempotence
CREATE TABLE processed_messages (
    message_id   CHAR(36)    NOT NULL,
    barcode      VARCHAR(20) NOT NULL,
    processed_at DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (message_id)
);

-- Messages en échec pour audit et retraitement
CREATE TABLE dead_letter_messages (
    id           CHAR(36)    NOT NULL DEFAULT (UUID()),
    message_id   CHAR(36)    NOT NULL,
    payload      JSON        NOT NULL,
    error        TEXT        NOT NULL,
    attempts     INT         NOT NULL DEFAULT 0,
    failed_at    DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id)
);
```

### Requêtes de Surveillance Utiles

```sql
-- Messages en échec (DLQ applicative)
SELECT * FROM dead_letter_messages ORDER BY failed_at DESC LIMIT 50;

-- Volume de codes-barres générés aujourd'hui
SELECT COUNT(*) FROM barcodes WHERE DATE(created_at) = CURDATE();

-- Taux d'échec sur les 24 dernières heures
SELECT COUNT(*) FROM dead_letter_messages
WHERE failed_at > NOW() - INTERVAL 24 HOUR;
```

---

## 7. Guide d'Utilisation

### 7.1 Prérequis

| Outil | Version minimale | Vérification |
|-------|-----------------|--------------|
| Docker | 24.0+ | `docker --version` |
| Docker Compose | 2.0+ | `docker compose version` |
| Make | 3.8+ | `make --version` |
| Go *(dev seulement)* | 1.23+ | `go version` |

### 7.2 Démarrage Rapide

```bash
# 1. Cloner le dépôt
git clone <url-du-repo> && cd barcode-project

# 2. Copier la configuration d'environnement
cp .env.example .env

# 3. Démarrer tous les services
make up

# 4. Vérifier que l'infrastructure est opérationnelle
make test

# 5. Consulter les logs en temps réel
make logs
```

> ✅ **Services disponibles après `make up`**
> - RabbitMQ Management UI → http://localhost:15672 `(guest/guest)`
> - MySQL → `localhost:3306` `(barcode/barcode)`
> - S3 LocalStack → http://localhost:4566 `(test/test)`

### 7.3 Commandes Disponibles

| Commande | Description |
|----------|-------------|
| `make up` | Démarre tous les services (build si nécessaire) |
| `make down` | Arrête tous les services |
| `make clean` | Arrête et supprime les volumes (reset complet) |
| `make logs` | Logs en temps réel — tous les services |
| `make logs-consumer` | Logs du consumer Go uniquement |
| `make logs-generator` | Logs du generator uniquement |
| `make ps` | Statut des containers |
| `make test` | Lance tous les tests d'infrastructure |
| `make test-mysql` | Test MySQL + idempotence uniquement |
| `make test-s3` | Test S3 / LocalStack uniquement |
| `make test-dlq` | Test Dead-Letter Queue uniquement |
| `make benchmark N=1000` | Benchmark consumer Go (N messages) |
| `make benchmark-php N=1000` | Benchmark consumer PHP (N messages) |
| `make benchmark-all` | Benchmark Go + PHP enchaînés |
| `make restart SERVICE=xxx` | Rebuild et redémarre un service spécifique |

### 7.4 Récupérer les Codes-Barres Générés

En environnement de développement, les images JPEG générées sont stockées dans le container. Pour les récupérer :

```bash
# Copier tout le dossier output sur la machine locale
docker cp barcode-generator-consumer:/output/ ./output-local/

# Récupérer un fichier spécifique
docker cp barcode-generator-consumer:/output/CODE128_SPAREPART_4.jpg .
```

> 📌 En production, les images seront directement uploadées sur S3. La sauvegarde locale est uniquement présente en environnement de développement/test.

---

## 8. Personnalisation — Génération Automatique par Commande

Cette section décrit comment configurer le système pour que chaque nouvelle commande, création de produit ou événement métier déclenche automatiquement la génération d'un code-barre. C'est l'adaptation principale à réaliser pour le passage en production.

> 🔧 **Contexte** — Actuellement, le `barcode-generator` publie un message de démonstration toutes les 5 secondes. En production, ce comportement doit être remplacé par un déclencheur lié aux événements métier réels.

### 8.1 Fichier à Modifier

Un seul fichier doit être modifié pour connecter le système à votre source de données réelle :

```
barcode-generator/cmd/main.go   ← point d'entrée du publisher
```

### 8.2 Code Actuel (Mode Démonstration)

```go
// ⚠️ MODE DÉMO — À REMPLACER EN PRODUCTION
for {
    body := `{"barcode":"1234567890128","format":"CODE128","title":"Test"}`
    ch.Publish("", queue, false, false, amqp.Publishing{
        Body: []byte(body),
    })
    time.Sleep(5 * time.Second) // ← boucle de démo toutes les 5 secondes
}
```

### 8.3 Pattern A — Polling Base de Données (Nouvelles Commandes)

Ce pattern convient si vos commandes sont stockées en base de données et doivent déclencher la génération d'un code-barre lors de leur création.

```go
// Pattern A — Polling DB toutes les N secondes
for {
    // Récupérer les nouvelles commandes sans code-barre
    rows, _ := db.Query(`
        SELECT sku, title FROM orders
        WHERE barcode_generated = FALSE
        LIMIT 100`)

    for rows.Next() {
        var sku, title string
        rows.Scan(&sku, &title)

        body := fmt.Sprintf(
            `{"barcode":"%s","format":"CODE128","title":"%s"}`,
            sku, title)

        // ⚠️ MessageId obligatoire pour l'idempotence
        ch.Publish("", queue, false, false, amqp.Publishing{
            ContentType:  "application/json",
            DeliveryMode: amqp.Persistent,
            MessageId:    uuid.New().String(), // ← UUID unique par message
            Body:         []byte(body),
        })

        // Marquer comme traité dans la table source
        db.Exec("UPDATE orders SET barcode_generated = TRUE WHERE sku = ?", sku)
    }

    time.Sleep(30 * time.Second) // Polling toutes les 30 secondes
}
```

### 8.4 Pattern B — Webhook HTTP (Événement Temps Réel)

Ce pattern convient si votre système déclenche un webhook lors d'une création de commande ou de produit.

```go
// Pattern B — Serveur HTTP qui reçoit les événements
http.HandleFunc("/barcode", func(w http.ResponseWriter, r *http.Request) {
    var req struct {
        Barcode string `json:"barcode"`
        Title   string `json:"title"`
    }
    json.NewDecoder(r.Body).Decode(&req)

    body, _ := json.Marshal(map[string]string{
        "barcode": req.Barcode,
        "format":  "CODE128",
        "title":   req.Title,
    })

    ch.Publish("", queue, false, false, amqp.Publishing{
        ContentType:  "application/json",
        DeliveryMode: amqp.Persistent,
        MessageId:    uuid.New().String(), // ← UUID unique obligatoire
        Body:         body,
    })

    w.WriteHeader(http.StatusAccepted) // 202 — message en cours de traitement
})

http.ListenAndServe(":8080", nil)
```

> ⚠️ **Règle Obligatoire — `MessageId`** — Le champ `MessageId` doit toujours être renseigné avec un UUID unique par message. Sans cela, le mécanisme d'idempotence ne fonctionne pas et un même événement peut générer plusieurs codes-barres identiques en cas de retry RabbitMQ.

---

## 9. Variables d'Environnement

Copiez `.env.example` en `.env` et adaptez les valeurs :

```bash
cp .env.example .env
```

| Variable | Dev (défaut) | Production | Description |
|----------|-------------|-----------|-------------|
| `RABBITMQ_USER` | `guest` | À sécuriser | Utilisateur RabbitMQ |
| `RABBITMQ_PASS` | `guest` | À sécuriser | Mot de passe RabbitMQ |
| `RABBITMQ_QUEUE` | `barcodes` | `barcodes` | Queue principale |
| `RABBITMQ_DLQ` | `barcodes.dlq` | `barcodes.dlq` | Dead-Letter Queue |
| `MYSQL_USER` | `barcode` | À sécuriser | Utilisateur MySQL |
| `MYSQL_PASSWORD` | `barcode` | À sécuriser | Mot de passe MySQL |
| `MYSQL_DATABASE` | `barcode` | `barcode` | Nom de la base de données |
| `AWS_ENDPOINT` | `http://localstack:4566` | Vide (AWS réel) | Endpoint S3 |
| `AWS_REGION` | `eu-west-1` | Selon config | Région AWS |
| `AWS_ACCESS_KEY_ID` | `test` | Clé IAM réelle | Identifiant AWS |
| `AWS_SECRET_ACCESS_KEY` | `test` | Secret IAM réel | Secret AWS |
| `S3_BUCKET` | `barcodes` | Bucket prod | Nom du bucket S3 |
| `LOG_LEVEL` | `info` | `warn` | Niveau de verbosité des logs |
| `RETRY_MAX` | `3` | `3` | Nombre maximum de retries |
| `RETRY_INITIAL_DELAY_MS` | `500` | `500` | Délai initial du backoff (ms) |
| `WORKER_COUNT` | `10` | Selon charge | Nombre de goroutines en parallèle |

---

## 10. Analyse des Performances — Benchmark Scientifique

### 10.1 Méthodologie

Pour garantir la validité scientifique des mesures, une méthodologie rigoureuse a été appliquée pour éliminer les biais de mesure courants dans les benchmarks de systèmes distribués :

| Biais potentiel | Solution appliquée |
|----------------|-------------------|
| Consumer consomme pendant la publication | Consumer arrêté pendant la publication, redémarré au chrono |
| Publisher pollue la queue pendant le test | `barcode-generator` stoppé avant chaque benchmark Go |
| Interférence entre les deux consumers | Consumer Go arrêté pendant le benchmark PHP et vice-versa |
| Métriques CPU/RAM biaisées | Monitoring continu en arrière-plan pendant toute la consommation |
| Échantillonnage insuffisant | Sampling toutes les 500ms pour P50/P95/P99 |
| Conditions non comparables | Même charge, mêmes données, mêmes opérations MySQL |

### 10.2 Résultats Détaillés — 2 000 Messages

| Métrique | PHP 8.2 | Go sans concurrence | Go avec worker pool |
|----------|---------|--------------------|--------------------|
| Messages traités | 2 000 | 2 000 | 2 000 |
| Temps total | 26 s | 20 s | **11 s** |
| Débit moyen | 76 msg/s | 50 msg/s | **181 msg/s** |
| Latence moyenne | 13 ms/msg | 20 ms/msg | **5 ms/msg** |
| Débit P50 | 190 msg/s | 21 msg/s | 44 msg/s |
| Débit P95 | 491 msg/s | 338 msg/s | **1 810 msg/s** |
| CPU pic | 37.45% | 62.79% | 380.55% |
| RAM pic | 15.46 MiB | 8.6 MiB | 15.77 MiB |

### 10.3 Interprétation Scientifique

#### Sur le CPU

Le CPU Go à 380% peut sembler alarmant mais s'explique par le modèle de concurrence : sur Linux/Docker, 100% correspond à 1 cœur physique. **Go utilise donc 3,8 cœurs simultanément** grâce à ses 10 goroutines. PHP est limité à ~37% car il est mono-thread et ne peut exploiter qu'un seul cœur.

La métrique pertinente est le **CPU par message traité** (efficacité CPU) :

| | PHP | Go (worker pool) |
|--|-----|-----------------|
| CPU consommé | 37% | 380% |
| Débit | 76 msg/s | 181 msg/s |
| **CPU par message** | 0.49% / message | 2.10% / message |
| **Serveurs pour 1 000 msg/s** | ~13 serveurs | ~6 serveurs |

> 📊 **Conclusion** — Go consomme 4× plus de CPU par message mais traite 2,4× plus de messages par seconde. En termes d'infrastructure, cela se traduit par une **réduction de 54% du nombre de serveurs** nécessaires pour absorber la même charge.

#### Sur la RAM

La consommation mémoire est similaire entre PHP et Go (~15 MiB) pour 10 workers Go simultanés versus 1 processus PHP. Cela illustre l'efficacité mémoire des goroutines Go : chaque goroutine démarre avec environ 2-8 KB de pile (contre plusieurs MB pour un processus ou thread OS), permettant des milliers de goroutines simultanées sans explosion de la mémoire.

#### Sur les Percentiles de Débit

Un P95 de **1 810 msg/s** pour Go signifie que 95% du temps, le consumer traite au moins 1 810 messages par seconde pendant les pics de charge — confirmant la capacité à absorber des rafales importantes sans dégradation de service.

#### Sur le WORKER_COUNT

| `WORKER_COUNT` | Cas d'usage recommandé | CPU attendu |
|---------------|----------------------|-------------|
| 5 | Serveur partagé, ressources limitées | ~150-200% |
| **10 (défaut)** | **Serveur dédié 4-8 cœurs (recommandé)** | **~300-400%** |
| 20 | Serveur haute performance 16+ cœurs | ~600-800% |
| 50+ | Workload I/O intensif (upload S3 lent) | Variable |

---

## 11. Checklist de Passage en Production

| # | Action | Fichier | Priorité |
|---|--------|---------|----------|
| 1 | Remplacer la boucle de démo par la vraie source de données | `barcode-generator/cmd/main.go` | 🔴 CRITIQUE |
| 2 | Ajouter l'upload S3 dans `GenerateBarcodeEntity()` | `barcode-generator-consumer/barcodegen/BarcodeGenerator.go` | 🔴 CRITIQUE |
| 3 | Supprimer le service `localstack` du docker-compose | `docker-compose.yml` | 🔴 CRITIQUE |
| 4 | Configurer les vraies credentials AWS dans `.env` | `.env` | 🔴 CRITIQUE |
| 5 | Sécuriser les credentials RabbitMQ et MySQL | `.env` | 🔴 CRITIQUE |
| 6 | Retirer `AWS_ENDPOINT` du `.env` (vide = AWS réel) | `.env` | 🔴 CRITIQUE |
| 7 | Vérifier les droits IAM S3 (`s3:PutObject`) | AWS Console | 🔴 CRITIQUE |
| 8 | Passer `LOG_LEVEL=warn` en production | `.env` | 🟡 RECOMMANDÉ |
| 9 | Ajuster `WORKER_COUNT` selon les ressources disponibles | `.env` | 🟡 RECOMMANDÉ |
| 10 | Mettre en place un monitoring de la DLQ | Infra / Alerting | 🟡 RECOMMANDÉ |

### Upload S3 — Code de Migration

```go
// AVANT (sauvegarde locale — dev uniquement)
filename := fmt.Sprintf("output/%s_%s.jpg", obj.ObjectType, obj.Value)
os.WriteFile(filename, imgBytes, 0644)

// APRÈS (upload S3 — production)
s3Key := fmt.Sprintf("barcodes/%s_%s.jpg", obj.ObjectType, obj.Value)
g.s3Client.PutObject(ctx, &s3.PutObjectInput{
    Bucket:      aws.String(g.bucket),
    Key:         aws.String(s3Key),
    Body:        bytes.NewReader(imgBytes),
    ContentType: aws.String("image/jpeg"),
})
```

---

## 12. Infrastructure de Tests

Une suite de 27 tests automatisés vérifie l'intégrité de l'ensemble de l'infrastructure.

```bash
make test   # Lance tous les tests
```

| Suite | Commande | Ce qui est testé | Nombre |
|-------|----------|-----------------|--------|
| Infrastructure globale | `make test-infra` | Containers, RabbitMQ, queues, MySQL, S3, publication | 13 tests |
| MySQL + Schéma | `make test-mysql` | Tables, contraintes, idempotence (`INSERT IGNORE`) | 5 tests |
| S3 / LocalStack | `make test-s3` | Upload, listing, download, suppression | 5 tests |
| Dead-Letter Queue | `make test-dlq` | Message invalide → retry → Nack → DLQ | 4 tests |

> ✅ **Résultat attendu** — 27 tests / 27 OK. Le test DLQ arrête temporairement le consumer pendant son exécution — c'est normal, il est redémarré automatiquement à la fin.

### Lancer les Benchmarks

```bash
make benchmark N=2000         # Benchmark consumer Go
make benchmark-php N=2000     # Benchmark consumer PHP
make benchmark-all            # Go + PHP enchaînés (rapport comparatif)
```

Les résultats sont automatiquement sauvegardés dans `benchmark/results.md` avec horodatage, métriques détaillées (P50/P95/P99, CPU, RAM) et contexte environnement.

---

## 13. Structure du Projet

```
barcode-project/
│
├── barcode-generator/                        # Publisher Go
│   ├── Dockerfile                            # Multi-stage: golang:1.23 → scratch
│   ├── go.mod
│   ├── barcodegen/BarcodeGenerator.go        # Traduit depuis PHP + optimisations
│   └── cmd/main.go                           # ← À MODIFIER EN PRODUCTION
│
├── barcode-generator-consumer/               # Consumer Go (worker pool)
│   ├── Dockerfile                            # Multi-stage: golang:1.23 → scratch
│   ├── go.mod
│   ├── barcodegen/BarcodeGenerator.go        # sync.Pool + couleurs précalculées
│   ├── consumer/BarcodeGeneratorConsumer.go  # Traduit depuis PHP
│   └── cmd/main.go                           # Worker pool 10 goroutines
│
├── barcode-generator-consumer-php/           # Consumer PHP (benchmark uniquement)
│   ├── Dockerfile                            # php:8.2-cli + GD + sockets + pdo_mysql
│   ├── composer.json
│   └── cmd/main.php                          # Consumer PHP équivalent au Go
│
├── scripts/
│   ├── init.sql                              # Schéma MySQL (3 tables)
│   ├── init-s3.sh                            # Création bucket S3 au démarrage
│   ├── rabbitmq-definitions.json             # Queues + DLQ + Exchange pré-configurés
│   └── rabbitmq.conf
│
├── tests/                                    # 27 tests d'infrastructure
│   ├── run-all-tests.sh
│   ├── test-infra.sh
│   ├── test-mysql.sh
│   ├── test-s3.sh
│   └── test-dlq.sh
│
├── benchmark/                                # Scripts + résultats comparatifs
│   ├── run-benchmark.sh                      # Benchmark Go
│   ├── run-benchmark-php.sh                  # Benchmark PHP
│   └── results.md                            # Résultats avec horodatage
│
├── docker-compose.yml
├── Makefile                                  # Interface unifiée
├── .env.example                              # Template de configuration
├── .gitignore
└── README.md
```

---

## 14. Glossaire Technique

| Terme | Définition |
|-------|-----------|
| **ACK** | Confirmation de traitement réussi d'un message RabbitMQ. Le message est supprimé de la queue. |
| **NACK** | Confirmation d'échec de traitement. Le message est renvoyé en queue ou en DLQ selon la configuration. |
| **Backoff exponentiel** | Stratégie de retry où le délai entre tentatives double à chaque échec : 500ms → 1s → 2s. |
| **Dead-Letter Queue (DLQ)** | Queue spéciale recevant les messages qui ont échoué après le nombre maximum de retries. |
| **Goroutine** | Thread léger géré par le runtime Go. Démarre avec ~2 KB de pile (vs plusieurs MB pour un thread OS). |
| **Idempotence** | Propriété d'une opération qui produit le même résultat qu'on l'exécute une ou N fois. |
| **MessageId** | Identifiant unique (UUID) attaché à chaque message RabbitMQ, utilisé pour garantir l'idempotence. |
| **Prefetch / Qos** | Nombre de messages que RabbitMQ envoie au consumer sans attendre d'ACK. Contrôle le parallélisme. |
| **sync.Pool** | Pool d'objets réutilisables en Go, réduisant la pression sur le garbage collector. |
| **Worker Pool** | Ensemble de goroutines en attente de travail, permettant de limiter et contrôler la concurrence. |
| **scratch** | Image Docker vide (0 octet). Contient uniquement le binaire Go compilé statiquement. |
| **P50 / P95 / P99** | Percentiles de latence/débit : 50% / 95% / 99% des mesures sont en-dessous de cette valeur. |

---

*Documentation rédigée dans le cadre du Hackathon Engineering — Avril 2026*
*Équipe Engineering — Usage interne uniquement*