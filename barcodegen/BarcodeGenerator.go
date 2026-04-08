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

    os.MkdirAll("output", 0755)
    filename := fmt.Sprintf("output/%s_%s.jpg", obj.ObjectType, obj.Value)

    if err := os.WriteFile(filename, imgBytes, 0644); err != nil {
        return "", err
    }

    g.logger.Info("Saved barcode image", zap.String("file", filename))
    return filename, nil
}

func (g *BarcodeGenerator) GenerateBarcodeImage(value string, title string) ([]byte, error) {
    // Force the correct type
    var code barcode.Barcode
    var err error

    // Encode Code128
    code, err = code128.Encode(value)
    if err != nil {
        return nil, err
    }

    // Scale barcode
    code, err = barcode.Scale(code, 400, DefaultBarcodeHeight)
    if err != nil {
        return nil, err
    }

    // Prepare title text
    titleLines := wrapText(title, 45)
    titleHeight := len(titleLines) * 15
    totalHeight := DefaultBorder + titleHeight + DefaultSpace + DefaultBarcodeHeight + DefaultSpace + 20 + DefaultBorder

    // Create white background
    img := image.NewRGBA(image.Rect(0, 0, DefaultImageWidth, totalHeight))
    white := color.RGBA{255, 255, 255, 255}
    draw.Draw(img, img.Bounds(), &image.Uniform{white}, image.Point{}, draw.Src)

    // Draw title
    y := DefaultBorder
    for _, line := range titleLines {
        addLabel(img, centerX(line, DefaultImageWidth), y, line)
        y += 15
    }

    // Draw barcode centered
    draw.Draw(
        img,
        image.Rect(
            (DefaultImageWidth-400)/2,
            y+DefaultSpace,
            (DefaultImageWidth+400)/2,
            y+DefaultSpace+DefaultBarcodeHeight,
        ),
        code,
        image.Point{},
        draw.Over,
    )

    // Draw value text under barcode
    addLabel(img, centerX(value, DefaultImageWidth), y+DefaultSpace+DefaultBarcodeHeight+DefaultSpace+15, value)

    // Encode final image
    buf := new(bytes.Buffer)
    if err := jpeg.Encode(buf, img, nil); err != nil {
        return nil, err
    }

    return buf.Bytes(), nil
}

func addLabel(img *image.RGBA, x, y int, label string) {
    d := &font.Drawer{
        Dst:  img,
        Src:  image.NewUniform(color.Black),
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