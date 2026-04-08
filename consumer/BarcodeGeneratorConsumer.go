package consumer

import (
    "encoding/json"
    "fmt"

    "hackathon/barcodegen"
    "go.uber.org/zap"
)

type BarcodeMessage struct {
    ObjectType string `json:"object_type"`
    ObjectID   string `json:"object_id"`
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

func (c *BarcodeGeneratorConsumer) HandleHardcodedMessage() error {
    // Simulate incoming JSON message
    raw := `{"object_type": "sparepart", "object_id": "12345"}`

    var payload BarcodeMessage
    if err := json.Unmarshal([]byte(raw), &payload); err != nil {
        return err
    }

    // Simulate loading entity from DB
    entity := barcodegen.TestBarcodeOwner{
        ObjectType: payload.ObjectType,
        Value:      "SP-12345",
        Title:      "Test Sparepart Title",
    }

    // Generate barcode
    file, err := c.generator.GenerateBarcodeEntity(entity)
    if err != nil {
        return err
    }

    fmt.Println("Generated file:", file)
    return nil
}