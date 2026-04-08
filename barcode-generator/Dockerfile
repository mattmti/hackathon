# ─────────────────────────────────────────────────────────────
# Stage 1 — Builder
# ─────────────────────────────────────────────────────────────
FROM golang:1.23-alpine AS builder

# Build dependencies (gcc needed for CGO with image libs)
RUN apk add --no-cache git ca-certificates tzdata

WORKDIR /app

# Cache dependencies separately from source code
COPY go.mod go.sum ./
RUN go mod download

# Copy source & build
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-w -s" -o /app/barcode-generator ./cmd/main.go

# ─────────────────────────────────────────────────────────────
# Stage 2 — Runtime (image ultra légère)
# ─────────────────────────────────────────────────────────────
FROM scratch

# Certificats TLS (pour les appels AWS/S3)
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
# Timezone
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo
# Binaire compilé
COPY --from=builder /app/barcode-generator /barcode-generator

ENTRYPOINT ["/barcode-generator"]