package main

import (
    "hackathon/barcodegen" // Ajoute le préfixe du module
    "hackathon/consumer"   // Ajoute le préfixe du module
    "go.uber.org/zap"
)

func main() {
    logger, _ := zap.NewProduction()
    defer logger.Sync()

    // Ces noms doivent correspondre aux noms des dossiers
    generator := barcodegen.NewBarcodeGenerator(logger)
    cons := consumer.NewBarcodeGeneratorConsumer(logger, generator)

    cons.HandleHardcodedMessage()
}