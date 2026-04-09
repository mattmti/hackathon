FROM php:8.2-cli

RUN apt-get update && apt-get install -y \
        libpng-dev \
        libjpeg-dev \
        libfreetype6-dev \
        curl \
        unzip \
        default-mysql-client \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) gd pcntl sockets pdo pdo_mysql \
    && curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY composer.json ./
RUN composer install --no-dev --optimize-autoloader --no-interaction

COPY src/ ./src/
COPY cmd/main.php ./cmd/main.php

CMD ["php", "-d", "memory_limit=128M", "cmd/main.php"]