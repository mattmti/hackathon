<?php

declare(strict_types=1);

require_once __DIR__ . '/../vendor/autoload.php';

use PhpAmqpLib\Connection\AMQPStreamConnection;
use PhpAmqpLib\Message\AMQPMessage;
use Picqer\Barcode\BarcodeGeneratorJPG;
use Monolog\Logger;
use Monolog\Handler\StreamHandler;

// ─────────────────────────────────────────────────────────────
// Config
// ─────────────────────────────────────────────────────────────
$rabbitmqHost   = getenv('RABBITMQ_HOST')                ?: 'rabbitmq';
$rabbitmqPort   = (int)(getenv('RABBITMQ_PORT')          ?: 5672);
$rabbitmqUser   = getenv('RABBITMQ_USER')                ?: 'guest';
$rabbitmqPass   = getenv('RABBITMQ_PASS')                ?: 'guest';
$queue          = getenv('RABBITMQ_QUEUE')               ?: 'barcodes';
$retryMax       = (int)(getenv('RETRY_MAX')              ?: 3);
$retryInitialMs = (int)(getenv('RETRY_INITIAL_DELAY_MS') ?: 500);
$dbHost         = getenv('MYSQL_HOST')                   ?: 'mysql';
$dbPort         = getenv('MYSQL_PORT')                   ?: '3306';
$dbUser         = getenv('MYSQL_USER')                   ?: 'barcode';
$dbPass         = getenv('MYSQL_PASSWORD')               ?: 'barcode';
$dbName         = getenv('MYSQL_DATABASE')               ?: 'barcode';

// ─────────────────────────────────────────────────────────────
// Logger JSON structuré — équivalent slog Go
// ─────────────────────────────────────────────────────────────
$logger = new Logger('barcode-consumer-php');
$logger->pushHandler(new StreamHandler('php://stdout', Logger::INFO));

// ─────────────────────────────────────────────────────────────
// Connexion MySQL avec retry — équivalent Go
// ─────────────────────────────────────────────────────────────
$pdo = null;
$attempts = 0;
while ($pdo === null && $attempts < 10) {
    try {
        $pdo = new PDO(
            "mysql:host=$dbHost;port=$dbPort;dbname=$dbName;charset=utf8mb4",
            $dbUser, $dbPass,
            [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
        );
        $logger->info('MySQL connecté');
    } catch (\Exception $e) {
        $attempts++;
        $logger->error('Connexion MySQL échouée', ['error' => $e->getMessage(), 'attempt' => $attempts]);
        sleep(2);
    }
}

if ($pdo === null) {
    $logger->error('Impossible de se connecter à MySQL après 10 tentatives');
    exit(1);
}

// ─────────────────────────────────────────────────────────────
// Connexion RabbitMQ avec retry — équivalent Go
// ─────────────────────────────────────────────────────────────
$connection = null;
$attempts = 0;
while ($connection === null && $attempts < 10) {
    try {
        $connection = new AMQPStreamConnection(
            $rabbitmqHost, $rabbitmqPort, $rabbitmqUser, $rabbitmqPass
        );
        $logger->info('RabbitMQ connecté');
    } catch (\Exception $e) {
        $attempts++;
        $logger->error('Connexion RabbitMQ échouée', ['error' => $e->getMessage(), 'attempt' => $attempts]);
        sleep(2);
    }
}

if ($connection === null) {
    $logger->error('Impossible de se connecter à RabbitMQ après 10 tentatives');
    exit(1);
}

$channel = $connection->channel();
$channel->basic_qos(null, 1, null);

// ─────────────────────────────────────────────────────────────
// BarcodeGeneratorJPG — même librairie que BarcodeGenerator.php
// ─────────────────────────────────────────────────────────────
$generator = new BarcodeGeneratorJPG();

$logger->info('PHP consumer démarré', ['queue' => $queue, 'retry_max' => $retryMax]);

// ─────────────────────────────────────────────────────────────
// Idempotence — équivalent isAlreadyProcessed() Go
// ─────────────────────────────────────────────────────────────
function isAlreadyProcessed(PDO $pdo, string $messageId): bool
{
    if ($messageId === 'unknown') return false;
    $stmt = $pdo->prepare('SELECT COUNT(*) FROM processed_messages WHERE message_id = ?');
    $stmt->execute([$messageId]);
    return (int)$stmt->fetchColumn() > 0;
}

function markAsProcessed(PDO $pdo, string $messageId, string $body): void
{
    if ($messageId === 'unknown') return;
    $stmt = $pdo->prepare('INSERT IGNORE INTO processed_messages (message_id, barcode) VALUES (?, ?)');
    $stmt->execute([$messageId, $body]);
}

function saveToDLQ(PDO $pdo, string $messageId, string $payload, string $error, int $attempts): void
{
    $stmt = $pdo->prepare(
        'INSERT INTO dead_letter_messages (message_id, payload, error, attempts) VALUES (?, ?, ?, ?)'
    );
    $stmt->execute([$messageId, $payload, $error, $attempts]);
}

// ─────────────────────────────────────────────────────────────
// process() — génération barcode — équivalent Go
// ─────────────────────────────────────────────────────────────
function process(string $body, BarcodeGeneratorJPG $generator, Logger $logger): bool
{
    $data = json_decode($body, true);
    if (!$data || empty($data['barcode'])) {
        return false;
    }

    $barcode = $data['barcode'];
    $title   = $data['title'] ?? '';

    try {
        // Génération barcode — picqer/php-barcode-generator
        $barcodeData = $generator->getBarcode(
            $barcode,
            \Picqer\Barcode\BarcodeGenerator::TYPE_CODE_128,
            2, 120, [0, 0, 0]
        );

        // Création image avec GD — équivalent image/jpeg Go
        $barcodeImg  = imagecreatefromstring($barcodeData);
        $barcodeW    = imagesx($barcodeImg);
        $barcodeH    = imagesy($barcodeImg);
        $imageWidth  = max(460, $barcodeW + 20);
        $titleHeight = $title ? 20 : 0;
        $imageHeight = 10 + $titleHeight + 8 + $barcodeH + 8 + 20 + 10;

        $image = imagecreatetruecolor($imageWidth, $imageHeight);
        $white = imagecolorallocate($image, 255, 255, 255);
        $black = imagecolorallocate($image, 0, 0, 0);
        imagefill($image, 0, 0, $white);

        $y = 10;
        if ($title) {
            imagestring($image, 2, (int)(($imageWidth - strlen($title) * 6) / 2), $y, $title, $black);
            $y += 20;
        }

        imagecopy($image, $barcodeImg, (int)(($imageWidth - $barcodeW) / 2), $y + 8, 0, 0, $barcodeW, $barcodeH);
        $y += 8 + $barcodeH + 8;
        imagestring($image, 2, (int)(($imageWidth - strlen($barcode) * 6) / 2), $y, $barcode, $black);

        @mkdir('output', 0755, true);
        imagejpeg($image, sprintf('output/CODE128_%s.jpg', $barcode), 85);
        imagedestroy($image);
        imagedestroy($barcodeImg);

        $logger->info('Code-barre généré', ['barcode' => $barcode]);
        return true;

    } catch (\Throwable $e) {
        $logger->error('Erreur génération', ['barcode' => $barcode, 'error' => $e->getMessage()]);
        return false;
    }
}

// ─────────────────────────────────────────────────────────────
// Boucle de consommation avec retry/backoff + idempotence + DLQ
// Équivalent exact du cmd/main.go Go
// ─────────────────────────────────────────────────────────────
$callback = function (AMQPMessage $msg) use (
    $generator, $logger, $pdo, $retryMax, $retryInitialMs
) {
    $messageId = $msg->get_properties()['message_id'] ?? 'unknown';
    $body      = $msg->body;

    // Idempotence
    if (isAlreadyProcessed($pdo, $messageId)) {
        $logger->info('Message déjà traité, skip', ['message_id' => $messageId]);
        $msg->ack();
        return;
    }

    // Retry / backoff exponentiel
    $success   = false;
    $lastError = '';
    for ($attempt = 1; $attempt <= $retryMax; $attempt++) {
        $logger->info('Traitement du message', ['message_id' => $messageId, 'attempt' => $attempt]);

        $success = process($body, $generator, $logger);
        if ($success) break;

        $lastError = 'Échec génération barcode';
        $logger->warning('Échec traitement', ['message_id' => $messageId, 'attempt' => $attempt]);

        if ($attempt < $retryMax) {
            $delayMs = (int)($retryInitialMs * pow(2, $attempt - 1));
            $logger->info('Retry dans...', ['delay_ms' => $delayMs]);
            usleep($delayMs * 1000);
        }
    }

    if ($success) {
        markAsProcessed($pdo, $messageId, $body);
        $logger->info('Message traité avec succès', ['message_id' => $messageId]);
        $msg->ack();
    } else {
        $logger->error('Max retries atteint, envoi en DLQ', ['message_id' => $messageId]);
        saveToDLQ($pdo, $messageId, $body, $lastError, $retryMax);
        $msg->nack(false, false);
    }
};

$channel->basic_consume($queue, '', false, false, false, false, $callback);

// Graceful shutdown SIGTERM — équivalent signal.NotifyContext Go
pcntl_signal(SIGTERM, function() use ($channel, $connection, $logger) {
    $logger->info('Arrêt du consumer PHP (SIGTERM)');
    $channel->close();
    $connection->close();
    exit(0);
});

$logger->info('En attente de messages...', ['queue' => $queue]);

while ($channel->is_consuming()) {
    $channel->wait();
    pcntl_signal_dispatch();
}

$channel->close();
$connection->close();