package main

import (
	"context"
	"database/sql"
	"log/slog"
	"math"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"syscall"
	"time"

	_ "github.com/go-sql-driver/mysql"
	amqp "github.com/rabbitmq/amqp091-go"
	"go.uber.org/zap"

	"github.com/your-org/barcode-generator-consumer/barcodegen"
	"github.com/your-org/barcode-generator-consumer/consumer"
)

// ─────────────────────────────────────────────────────────────
// Worker pool — exploite la vraie concurrence Go
// PHP : 1 message à la fois (séquentiel)
// Go  : N messages en parallèle (goroutines)
// ─────────────────────────────────────────────────────────────
const WORKER_COUNT = 10 // 10 goroutines en parallèle

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	rabbitmqURL  := getEnv("RABBITMQ_URL", "amqp://guest:guest@localhost:5672/")
	queue        := getEnv("RABBITMQ_QUEUE", "barcodes")
	databaseURL  := getEnv("DATABASE_URL", "barcode:barcode@tcp(mysql:3306)/barcode?parseTime=true")
	retryMax     := getEnvInt("RETRY_MAX", 3)
	retryInitial := getEnvInt("RETRY_INITIAL_DELAY_MS", 500)
	workerCount  := getEnvInt("WORKER_COUNT", WORKER_COUNT)

	// ── MySQL avec pool de connexions ─────────────────────────
	db, err := sql.Open("mysql", databaseURL)
	if err != nil {
		logger.Error("impossible d'ouvrir la DB", "error", err)
		os.Exit(1)
	}
	defer db.Close()

	// Pool de connexions MySQL — une par worker
	db.SetMaxOpenConns(workerCount + 2)
	db.SetMaxIdleConns(workerCount)
	db.SetConnMaxLifetime(5 * time.Minute)

	for i := 0; i < 10; i++ {
		if err := db.Ping(); err == nil {
			break
		}
		logger.Error("impossible de joindre MySQL", "error", err)
		time.Sleep(2 * time.Second)
		if i == 9 {
			os.Exit(1)
		}
	}
	logger.Info("MySQL connecté")

	// ── BarcodeGenerator — thread-safe, partagé entre workers ─
	zapLogger, _ := zap.NewProduction()
	defer zapLogger.Sync()
	generator := barcodegen.NewBarcodeGenerator(zapLogger)
	barcodeConsumer := consumer.NewBarcodeGeneratorConsumer(zapLogger, generator)

	// ── RabbitMQ avec retry ───────────────────────────────────
	var conn *amqp.Connection
	for i := 0; i < 10; i++ {
		conn, err = amqp.Dial(rabbitmqURL)
		if err == nil {
			break
		}
		logger.Error("impossible de se connecter à RabbitMQ", "error", err)
		time.Sleep(2 * time.Second)
		if i == 9 {
			os.Exit(1)
		}
	}
	defer conn.Close()

	ch, err := conn.Channel()
	if err != nil {
		logger.Error("impossible d'ouvrir un channel", "error", err)
		os.Exit(1)
	}
	defer ch.Close()

	// Prefetch = workerCount — RabbitMQ envoie N messages d'un coup
	// PHP : Qos(1) → 1 message à la fois
	// Go  : Qos(N) → N messages en parallèle
	ch.Qos(workerCount, 0, false)

	msgs, err := ch.Consume(queue, "", false, false, false, false, nil)
	if err != nil {
		logger.Error("impossible de consommer la queue", "error", err)
		os.Exit(1)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer cancel()

	logger.Info("consumer démarré",
		"queue", queue,
		"retry_max", retryMax,
		"workers", workerCount,
	)

	// ── Worker pool — goroutines en parallèle ─────────────────
	// Chaque message est traité dans sa propre goroutine
	// Go gère des milliers de goroutines sans overhead
	var wg sync.WaitGroup

	for {
		select {
		case <-ctx.Done():
			logger.Info("arrêt du consumer — attente des workers en cours...")
			wg.Wait() // attendre que tous les messages en cours soient traités
			logger.Info("tous les workers terminés — arrêt propre")
			return

		case msg, ok := <-msgs:
			if !ok {
				wg.Wait()
				return
			}

			// Chaque message → goroutine indépendante
			wg.Add(1)
			go func(msg amqp.Delivery) {
				defer wg.Done()
				processMessage(msg, db, barcodeConsumer, logger, retryMax, retryInitial)
			}(msg)
		}
	}
}

// processMessage — traitement complet d'un message dans une goroutine
func processMessage(
	msg amqp.Delivery,
	db *sql.DB,
	barcodeConsumer *consumer.BarcodeGeneratorConsumer,
	logger *slog.Logger,
	retryMax, retryInitial int,
) {
	messageID := msg.MessageId
	if messageID == "" {
		messageID = "unknown"
	}
	log := logger.With("message_id", messageID)

	// ── Idempotence ───────────────────────────────────────────
	if isAlreadyProcessed(db, messageID) {
		log.Info("message déjà traité, skip")
		msg.Ack(false)
		return
	}

	// ── Retry / Backoff exponentiel ───────────────────────────
	var processErr error
	for attempt := 1; attempt <= retryMax; attempt++ {
		log.Info("traitement du message", "attempt", attempt)

		processErr = barcodeConsumer.Execute(msg.Body)
		if processErr == nil {
			break
		}

		log.Warn("échec traitement", "attempt", attempt, "error", processErr)
		if attempt < retryMax {
			delay := time.Duration(float64(retryInitial)*math.Pow(2, float64(attempt-1))) * time.Millisecond
			log.Info("retry dans...", "delay_ms", delay.Milliseconds())
			time.Sleep(delay)
		}
	}

	if processErr != nil {
		log.Error("max retries atteint, envoi en DLQ", "error", processErr)
		saveToDLQ(db, messageID, string(msg.Body), processErr.Error(), retryMax)
		msg.Nack(false, false)
		return
	}

	markAsProcessed(db, messageID, string(msg.Body))
	log.Info("message traité avec succès")
	msg.Ack(false)
}

func isAlreadyProcessed(db *sql.DB, messageID string) bool {
	if messageID == "unknown" {
		return false
	}
	var count int
	db.QueryRow("SELECT COUNT(*) FROM processed_messages WHERE message_id = ?", messageID).Scan(&count)
	return count > 0
}

func markAsProcessed(db *sql.DB, messageID, body string) {
	if messageID == "unknown" {
		return
	}
	db.Exec("INSERT IGNORE INTO processed_messages (message_id, barcode) VALUES (?, ?)", messageID, body)
}

func saveToDLQ(db *sql.DB, messageID, payload, errMsg string, attempts int) {
	db.Exec(
		`INSERT INTO dead_letter_messages (message_id, payload, error, attempts) VALUES (?, ?, ?, ?)`,
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