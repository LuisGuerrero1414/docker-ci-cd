#!/usr/bin/env bash

# ==============================================================================
# SCRIPT DE DESPLIEGUE INMUTABLE CON ROLLBACK AUTOMÁTICO PARA LARAVEL 11
# ==============================================================================

set -eo pipefail

NEW_IMAGE="${1:-}"

if [ -z "$NEW_IMAGE" ]; then
    echo "❌ Error: Debes especificar la nueva imagen como argumento."
    echo "Uso: ./deploy.sh <registry/imagen:tag>"
    exit 1
fi

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="./backups"
BACKUP_FILE="${BACKUP_DIR}/db_backup_${TIMESTAMP}.sql"
HEALTH_CHECK_URL="http://localhost:8080/health"
MAX_ATTEMPTS=15
SLEEP_SECONDS=2

mkdir -p "$BACKUP_DIR"

echo "=========================================================="
echo "🚀 Iniciando despliegue hacia la imagen: $NEW_IMAGE"
echo "=========================================================="

# 1. Obtener la imagen actual en ejecución para rollback si es necesario
PREVIOUS_IMAGE=$(docker compose images app --format "{{.Repository}}:{{.Tag}}" 2>/dev/null || echo "")
if [ -z "$PREVIOUS_IMAGE" ] || [ "$PREVIOUS_IMAGE" = ":" ]; then
    PREVIOUS_IMAGE=${APP_IMAGE:-""}
fi
echo "📌 Imagen previa detectada: ${PREVIOUS_IMAGE:-'Ninguna (primer despliegue)'}"

# 2. Respaldo de la Base de Datos antes de cualquier modificación
echo "📦 Generando respaldo previo de MySQL..."
if docker compose ps -q db > /dev/null 2>&1 && [ "$(docker inspect -f '{{.State.Running}}' laravel_db 2>/dev/null)" = "true" ]; then
    docker compose exec -T db mysqldump -u"${DB_USERNAME:-laravel_user}" -p"${DB_PASSWORD:-laravel_pass}" "${DB_DATABASE:-laravel}" > "$BACKUP_FILE"
    echo "✅ Respaldo guardado con éxito en: $BACKUP_FILE"
else
    echo "⚠️ Contenedor de base de datos no está corriendo o es el primer arranque. Saltando mysqldump..."
fi

# Definición de función de Rollback
rollback() {
    echo "=========================================================="
    echo "🚨 ¡FALLO EN EL DESPLIEGUE! INICIANDO ROLLBACK AUTOMÁTICO..."
    echo "=========================================================="

    if [ -n "$PREVIOUS_IMAGE" ]; then
        echo "🔄 Restaurando imagen Docker anterior: $PREVIOUS_IMAGE"
        export APP_IMAGE="$PREVIOUS_IMAGE"
        docker compose up -d app
    fi

    if [ -f "$BACKUP_FILE" ]; then
        echo "🔄 Restaurando snapshot de base de datos desde $BACKUP_FILE..."
        docker compose exec -T db mysql -u"${DB_USERNAME:-laravel_user}" -p"${DB_PASSWORD:-laravel_pass}" "${DB_DATABASE:-laravel}" < "$BACKUP_FILE" || true
        echo "✅ Base de datos restaurada."
    fi

    echo "❌ Rollback completado. El estado previo fue restablecido."
    exit 1
}

# 3. Descargar la nueva imagen Docker
echo "📥 Descargando nueva imagen de GHCR: $NEW_IMAGE..."
if ! docker pull "$NEW_IMAGE"; then
    echo "❌ Error al descargar la imagen de GHCR."
    exit 1
fi

# 4. Actualizar contenedor con la nueva imagen
echo "🔄 Levantando servicios con la nueva imagen..."
export APP_IMAGE="$NEW_IMAGE"

if ! docker compose up -d --remove-orphans; then
    echo "❌ Fallo al levantar los contenedores."
    rollback
fi

# 5. Ejecutar migraciones en el nuevo contenedor
echo "🗄️ Ejecutando migraciones de Laravel..."
if ! docker compose exec -T app php artisan migrate --force; then
    echo "❌ Error durante las migraciones de la base de datos."
    rollback
fi

# Limpieza y calentamiento de caché de Laravel en producción
echo "⚡ Optimizando caché de configuración y rutas..."
docker compose exec -T app php artisan config:cache || true
docker compose exec -T app php artisan route:cache || true
docker compose exec -T app php artisan view:cache || true

# 6. Polling y validación de Health Check
echo "🔍 Verificando estado de salud en $HEALTH_CHECK_URL (Máximo $((MAX_ATTEMPTS * SLEEP_SECONDS))s)..."

SUCCESS=0
for i in $(seq 1 "$MAX_ATTEMPTS"); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$HEALTH_CHECK_URL" || echo "000")
    if [ "$HTTP_CODE" -eq 200 ]; then
        RESPONSE_BODY=$(curl -s "$HEALTH_CHECK_URL" || echo "")
        echo "✅ Health check exitoso (HTTP $HTTP_CODE): $RESPONSE_BODY"
        SUCCESS=1
        break
    else
        echo "⏳ Intento $i/$MAX_ATTEMPTS: Respuesta HTTP $HTTP_CODE. Esperando ${SLEEP_SECONDS}s..."
        sleep "$SLEEP_SECONDS"
    fi
done

if [ "$SUCCESS" -ne 1 ]; then
    echo "❌ Health check falló o excedió el tiempo límite."
    rollback
fi

echo "=========================================================="
echo "🎉 ¡Despliegue completado satisfactoriamente con la versión: $NEW_IMAGE!"
echo "=========================================================="
