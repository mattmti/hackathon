package consumer

import (
	"encoding/json"
	"fmt"

	"github.com/your-org/barcode-generator-consumer/barcodegen"
	"go.uber.org/zap"
)

type BarcodeMessage struct {
	Barcode string `json:"barcode"`
	Format  string `json:"format"`
	Title   string `json:"title"`
}

type BarcodeGeneratorConsumer struct {
	logger    *zap.Logger
	generator *barcodegen.BarcodeGenerator
}

func NewBarcodeGeneratorConsumer(logger *zap.Logger, generator *barcodegen.BarcodeGenerator) *BarcodeGeneratorConsumer {
	return &BarcodeGeneratorConsumer{
		logger:    logger,
		generator: generator,
	}
}

func (c *BarcodeGeneratorConsumer) Execute(body string) error {
	var payload BarcodeMessage
	if err := json.Unmarshal([]byte(body), &payload); err != nil {
		return fmt.Errorf("parse message: %w", err)
	}

	if payload.Barcode == "" {
		return fmt.Errorf("barcode value is empty")
	}

	entity := barcodegen.TestBarcodeOwner{
		ObjectType: payload.Format,
		Value:      payload.Barcode,
		Title:      payload.Title,
	}

	file, err := c.generator.GenerateBarcodeEntity(entity)
	if err != nil {
		return fmt.Errorf("generate barcode: %w", err)
	}

	c.logger.Info("Barcode generated", zap.String("file", file), zap.String("barcode", payload.Barcode))
	return nil
}