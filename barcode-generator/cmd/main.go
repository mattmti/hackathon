package main

import (
	"context"
	"database/sql"
	"log/slog"
	"math"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	_ "github.com/go-sql-driver/mysql"
	amqp "github.com/rabbitmq/amqp091-go"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	rabbitmqURL  := getEnv("RABBITMQ_URL", "amqp://guest:guest@localhost:5672/")
	queue        := getEnv("RABBITMQ_QUEUE", "barcodes")
	databaseURL  := getEnv("DATABASE_URL", "barcode:barcode@tcp(mysql:3306)/barcode?parseTime=true")
	retryMax     := getEnvInt("RETRY_MAX", 3)
	retryInitial := getEnvInt("RETRY_INITIAL_DELAY_MS", 500)

	// ── MySQL ────────────────────────────────────────────────
	db, err := sql.Open("mysql", databaseURL)
	if err != nil {
		logger.Error("impossible d'ouvrir la DB", "error", err)
		os.Exit(1)
	}
	defer db.Close()

	if err := db.Ping(); err != nil {
		logger.Error("impossible de joindre MySQL", "error", err)
		os.Exit(1)
	}
	logger.Info("MySQL connecté")

	// ── RabbitMQ ─────────────────────────────────────────────
	conn, err := amqp.Dial(rabbitmqURL)
	if err != nil {
		logger.Error("impossible de se connecter à RabbitMQ", "error", err)
		os.Exit(1)
	}
	defer conn.Close()

	ch, err := conn.Channel()
	if err != nil {
		logger.Error("impossible d'ouvrir un channel", "error", err)
		os.Exit(1)
	}
	defer ch.Close()

	// Prefetch : traite 1 message à la fois
	ch.Qos(1, 0, false)

	msgs, err := ch.Consume(queue, "", false, false, false, false, nil)
	if err != nil {
		logger.Error("impossible de consommer la queue", "error", err)
		os.Exit(1)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer cancel()

	logger.Info("consumer démarré", "queue", queue, "retry_max", retryMax)

	for {
		select {
		case <-ctx.Done():
			logger.Info("arrêt du consumer (SIGTERM)")
			return

		case msg, ok := <-msgs:
			if !ok {
				return
			}

			messageID := msg.MessageId
			if messageID == "" {
				messageID = "unknown"
			}

			log := logger.With("message_id", messageID)

			// ── Idempotence ──────────────────────────────────
			if isAlreadyProcessed(db, messageID) {
				log.Info("message déjà traité, skip")
				msg.Ack(false)
				continue
			}

			// ── Retry / Backoff exponentiel ──────────────────
			var processErr error
			for attempt := 1; attempt <= retryMax; attempt++ {
				log.Info("traitement du message",
					"attempt", attempt,
					"body", string(msg.Body),
				)

				processErr = process(ctx, string(msg.Body))
				if processErr == nil {
					break
				}

				log.Warn("échec traitement",
					"attempt", attempt,
					"error", processErr,
				)

				if attempt < retryMax {
					delay := time.Duration(float64(retryInitial)*math.Pow(2, float64(attempt-1))) * time.Millisecond
					log.Info("retry dans...", "delay_ms", delay.Milliseconds())
					time.Sleep(delay)
				}
			}

			if processErr != nil {
				// Max retries atteint → DLQ
				log.Error("max retries atteint, envoi en DLQ",
					"error", processErr,
					"attempts", retryMax,
				)
				saveToDLQ(db, messageID, string(msg.Body), processErr.Error(), retryMax)
				msg.Nack(false, false) // requeue=false → DLQ RabbitMQ
				continue
			}

			// ── Succès ───────────────────────────────────────
			markAsProcessed(db, messageID, string(msg.Body))
			log.Info("message traité avec succès")
			msg.Ack(false)
		}
	}
}

// process simule le traitement métier.
// L'équipe Go remplace cette fonction par le vrai code.
func process(ctx context.Context, body string) error {
	// TODO : remplacer par le vrai traitement
	// ex: générer le code-barre, uploader sur S3, persister en DB
	_ = body
	return nil
}

// isAlreadyProcessed vérifie si le message a déjà été traité.
func isAlreadyProcessed(db *sql.DB, messageID string) bool {
	if messageID == "unknown" {
		return false
	}
	var count int
	err := db.QueryRow(
		"SELECT COUNT(*) FROM processed_messages WHERE message_id = ?",
		messageID,
	).Scan(&count)
	return err == nil && count > 0
}

// markAsProcessed persiste le message comme traité (idempotence).
func markAsProcessed(db *sql.DB, messageID, body string) {
	if messageID == "unknown" {
		return
	}
	db.Exec(
		"INSERT IGNORE INTO processed_messages (message_id, barcode) VALUES (?, ?)",
		messageID, body,
	)
}

// saveToDLQ persiste le message en échec dans la DLQ applicative.
func saveToDLQ(db *sql.DB, messageID, payload, errMsg string, attempts int) {
	db.Exec(
		`INSERT INTO dead_letter_messages (message_id, payload, error, attempts)
		 VALUES (?, ?, ?, ?)`,
		messageID, payload, errMsg, attempts,
	)
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getEnvInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if i, err := strconv.Atoi(v); err == nil {
			return i
		}
	}
	return fallback
}