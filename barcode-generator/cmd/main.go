package main

import (
	"log/slog"
	"os"
	"time"

	"github.com/your-org/barcode-generator/barcodegen"
	amqp "github.com/rabbitmq/amqp091-go"
	"go.uber.org/zap"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	rabbitmqURL := getEnv("RABBITMQ_URL", "amqp://guest:guest@localhost:5672/")
	queue       := getEnv("RABBITMQ_QUEUE", "barcodes")

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

	// ── BarcodeGenerator (traduit depuis PHP) ─────────────────
	zapLogger, _ := zap.NewProduction()
	defer zapLogger.Sync()
	generator := barcodegen.NewBarcodeGenerator(zapLogger)

	logger.Info("barcode-generator démarré", "queue", queue)

	// Publie un message toutes les 5 secondes
	for {
		entity := barcodegen.TestBarcodeOwner{
			ObjectType: "sparepart",
			Value:      "1234567890128",
			Title:      "Test Barcode",
		}

		imgFile, err := generator.GenerateBarcodeEntity(entity)
		if err != nil {
			logger.Error("échec génération code-barre", "error", err)
		} else {
			logger.Info("code-barre généré", "file", imgFile)
		}

		body := `{"barcode":"1234567890128","format":"CODE128","title":"Test Barcode"}`
		err = ch.Publish(
			"",
			queue,
			false,
			false,
			amqp.Publishing{
				ContentType:  "application/json",
				DeliveryMode: amqp.Persistent,
				Body:         []byte(body),
			},
		)
		if err != nil {
			logger.Error("échec publication", "error", err)
		} else {
			logger.Info("message publié", "barcode", "1234567890128")
		}

		time.Sleep(5 * time.Second)
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}