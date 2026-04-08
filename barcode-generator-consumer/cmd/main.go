package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	amqp "github.com/rabbitmq/amqp091-go"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	rabbitmqURL := getEnv("RABBITMQ_URL", "amqp://guest:guest@localhost:5672/")
	queue := getEnv("RABBITMQ_QUEUE", "barcodes")

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

	msgs, err := ch.Consume(
		queue,
		"",    // consumer tag
		false, // auto-ack désactivé — on ack manuellement
		false, false, false, nil,
	)
	if err != nil {
		logger.Error("impossible de consommer la queue", "error", err)
		os.Exit(1)
	}

	logger.Info("barcode-consumer démarré, en attente de messages", "queue", queue)

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer cancel()

	for {
		select {
		case <-ctx.Done():
			logger.Info("arrêt du consumer")
			return
		case msg, ok := <-msgs:
			if !ok {
				return
			}
			logger.Info("message reçu", "body", string(msg.Body))
			// Ack — l'équipe Go remplacera ici par le vrai traitement
			msg.Ack(false)
		}
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}