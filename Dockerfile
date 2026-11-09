# ==========================================
# STAGE 1: Build de dependencias (Composer)
# ==========================================
FROM composer:2.7 AS vendor

WORKDIR /app

# Copiamos solo los archivos de dependencias para aprovechar la caché de capas de Docker
COPY composer.json composer.lock ./

# Instalación optimizada para producción:
# --no-dev: omite librerías de testing y desarrollo
# --no-scripts / --no-autoloader: previene fallos antes de tener el código fuente completo
RUN composer install \
    --no-dev \
    --no-interaction \
    --no-plugins \
    --no-scripts \
    --prefer-dist \
    --optimize-autoloader

# ==========================================
# STAGE 2: Imagen Final de Producción (PHP-FPM)
# ==========================================
FROM php:8.3-fpm-alpine

# Argumentos de entorno para configuración
ENV COMPOSER_ALLOW_SUPERUSER=1 \
    APP_ENV=production

# Instalar dependencias del sistema y extensiones requeridas por Laravel y MySQL
RUN apk add --no-cache \
    bash \
    curl \
    libpng-dev \
    libzip-dev \
    libxml2-dev \
    oniguruma-dev \
    icu-dev \
    mysql-client \
    && docker-php-ext-configure intl \
    && docker-php-ext-install -j$(nproc) \
        pdo_mysql \
        mbstring \
        exif \
        pcntl \
        bcmath \
        gd \
        zip \
        intl \
        opcache

# Configuración recomendada de OPcache para producción
RUN echo -e "\
opcache.enable=1\n\
opcache.memory_consumption=128\n\
opcache.interned_strings_buffer=8\n\
opcache.max_accelerated_files=10000\n\
opcache.revalidate_freq=0\n\
opcache.validate_timestamps=0\n\
opcache.save_comments=1\n\
opcache.fast_shutdown=1" > /usr/local/etc/php/conf.d/opcache-recommended.ini

# Establecer directorio de trabajo
WORKDIR /var/www/html

# Copiar el código fuente de la aplicación
COPY . /var/www/html

# Copiar dependencias de Composer desde el stage 'vendor'
COPY --from=vendor /app/vendor /var/www/html/vendor

# Copiar binario de Composer para tareas de artisan y scripts si fuese necesario
COPY --from=vendor /usr/bin/composer /usr/bin/composer

# Volver a generar el autoloader optimizado con las clases del proyecto y ajustar permisos
RUN composer dump-autoload --optimize --no-dev \
    && chown -R www-data:www-data /var/www/html \
    && chmod -R 775 /var/www/html/storage /var/www/html/bootstrap/cache

# Cambiar al usuario sin privilegios por seguridad
USER www-data

# Exponer el puerto de PHP-FPM
EXPOSE 9000

CMD ["php-fpm"]
