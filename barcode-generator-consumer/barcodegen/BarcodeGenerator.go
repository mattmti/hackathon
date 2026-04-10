package barcodegen

import (
	"bytes"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/jpeg"
	"os"
	"strings"
	"sync"

	"github.com/boombuler/barcode"
	"github.com/boombuler/barcode/code128"
	"go.uber.org/zap"
	"golang.org/x/image/font"
	"golang.org/x/image/font/basicfont"
	"golang.org/x/image/math/fixed"
)

const (
	DefaultImageWidth    = 460
	DefaultBarcodeHeight = 120
	DefaultBorder        = 10
	DefaultSpace         = 8
)

// Pool de buffers réutilisables — évite des allocations à chaque message
var bufPool = sync.Pool{
	New: func() any {
		return new(bytes.Buffer)
	},
}

// Couleurs précalculées une seule fois
var (
	colorWhite = color.RGBA{255, 255, 255, 255}
	colorBlack = image.NewUniform(color.Black)
)

// MkdirAll une seule fois au démarrage
func init() {
	os.MkdirAll("output", 0755)
}

type TestBarcodeOwner struct {
	ObjectType string
	Value      string
	Title      string
}

func (t TestBarcodeOwner) BarcodeObjectType() string { return t.ObjectType }
func (t TestBarcodeOwner) BarcodeValue() string      { return t.Value }
func (t TestBarcodeOwner) ShortTitle() string        { return t.Title }

type BarcodeGenerator struct {
	logger *zap.Logger
}

func NewBarcodeGenerator(logger *zap.Logger) *BarcodeGenerator {
	return &BarcodeGenerator{logger: logger}
}

func (g *BarcodeGenerator) GenerateBarcodeEntity(obj TestBarcodeOwner) (string, error) {
	imgBytes, err := g.GenerateBarcodeImage(obj.Value, obj.Title)
	if err != nil {
		return "", err
	}

	filename := fmt.Sprintf("output/%s_%s.jpg", obj.ObjectType, obj.Value)
	if err := os.WriteFile(filename, imgBytes, 0644); err != nil {
		return "", err
	}

	g.logger.Info("Saved barcode image", zap.String("file", filename))
	return filename, nil
}

func (g *BarcodeGenerator) GenerateBarcodeImage(value string, title string) ([]byte, error) {
	// Génération du code-barre — on utilise image.Image pour éviter le problème de type
	rawCode, err := code128.Encode(value)
	if err != nil {
		return nil, err
	}

	scaledCode, err := barcode.Scale(rawCode, 400, DefaultBarcodeHeight)
	if err != nil {
		return nil, err
	}

	// Calcul dimensions
	titleLines := wrapText(title, 45)
	titleHeight := len(titleLines) * 15
	totalHeight := DefaultBorder + titleHeight + DefaultSpace + DefaultBarcodeHeight + DefaultSpace + 20 + DefaultBorder

	// Création image — fond blanc
	img := image.NewRGBA(image.Rect(0, 0, DefaultImageWidth, totalHeight))
	draw.Draw(img, img.Bounds(), &image.Uniform{colorWhite}, image.Point{}, draw.Src)

	// Titre centré
	y := DefaultBorder
	for _, line := range titleLines {
		addLabel(img, centerX(line, DefaultImageWidth), y, line)
		y += 15
	}

	// Code-barre centré
	draw.Draw(
		img,
		image.Rect(
			(DefaultImageWidth-400)/2,
			y+DefaultSpace,
			(DefaultImageWidth+400)/2,
			y+DefaultSpace+DefaultBarcodeHeight,
		),
		scaledCode,
		image.Point{},
		draw.Over,
	)

	// Valeur texte sous le code-barre
	addLabel(img, centerX(value, DefaultImageWidth), y+DefaultSpace+DefaultBarcodeHeight+DefaultSpace+15, value)

	// Encodage JPEG avec buffer du pool
	buf := bufPool.Get().(*bytes.Buffer)
	buf.Reset()
	defer bufPool.Put(buf)

	if err := jpeg.Encode(buf, img, nil); err != nil {
		return nil, err
	}

	result := make([]byte, buf.Len())
	copy(result, buf.Bytes())
	return result, nil
}

func addLabel(img *image.RGBA, x, y int, label string) {
	d := &font.Drawer{
		Dst:  img,
		Src:  colorBlack,
		Face: basicfont.Face7x13,
		Dot:  fixed.Point26_6{X: fixed.I(x), Y: fixed.I(y)},
	}
	d.DrawString(label)
}

func wrapText(text string, maxLen int) []string {
	words := strings.Fields(text)
	var lines []string
	var line string

	for _, w := range words {
		if len(line)+len(w)+1 > maxLen {
			lines = append(lines, line)
			line = w
		} else {
			if line == "" {
				line = w
			} else {
				line += " " + w
			}
		}
	}
	if line != "" {
		lines = append(lines, line)
	}

	return lines
}

func centerX(text string, width int) int {
	return (width - len(text)*7) / 2
}