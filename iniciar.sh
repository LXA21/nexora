#!/bin/bash
set -Eeuo pipefail

# ============================================================================== 
# INSTALADOR UNIVERSAL DEFINITIVO
# Docker / Docker Compose / MySQL / MariaDB / PostgreSQL
#
# Objetivos principales:
#   - Cada ejecución crea una instancia aislada: P1, P2, P3...
#   - Nunca elimina volúmenes automáticamente.
#   - Nunca reutiliza silenciosamente un volumen de otra instancia.
#   - No cambia MySQL <-> MariaDB sobre datos existentes.
#   - No sustituye una imagen existente por :latest en un despliegue nuevo.
#   - Detecta container_name, volumes, networks, bind mounts y puertos fijos
#     que puedan romper el aislamiento antes de ejecutar docker compose up.
#   - Los puertos/variables de instancia se generan en Pn/.env y se pasan a
#     Compose mediante --env-file, sin sobrescribir el .env del repositorio.
#   - Si una decisión es ambigua o peligrosa, se detiene y pregunta.
#
# IMPORTANTE:
#   Este script NO ejecuta `docker compose down -v`.
#   Una nueva instancia NO reutiliza los datos de una instancia anterior.
# ============================================================================== 

set +e
trap 'rc=$?; set -e; echo "❌ Error en la línea $LINENO. Código: $rc"; exit "$rc"' ERR
set -e

SUDO=""
if [ "${EUID:-0}" -ne 0 ]; then SUDO="sudo"; fi

command_exists() { command -v "$1" >/dev/null 2>&1; }

sanitize_name() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g; s/^-*//; s/-*$//'
}

sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

prompt_yes_no() {
    local prompt="$1" default="${2:-N}" answer
    read -r -p "$prompt" answer
    answer=${answer:-$default}
    [[ "$answer" =~ ^[SsYy]$ ]]
}

# ------------------------------------------------------------------------------
# 0. Docker y herramientas base
# ------------------------------------------------------------------------------
echo "================================================="
echo "🐳 0. Verificando Docker, Compose y herramientas..."
echo "================================================="

if ! command_exists docker; then
    echo "⚙️ Docker no está instalado. Instalando Docker..."
    $SUDO apt-get update -y
    $SUDO apt-get install -y ca-certificates curl gnupg git unzip iproute2 python3 sudo
    $SUDO install -m 0755 -d /etc/apt/keyrings

    . /etc/os-release
    case "${ID:-}" in
        debian)
            DOCKER_REPO="https://download.docker.com/linux/debian"
            ;;
        ubuntu)
            DOCKER_REPO="https://download.docker.com/linux/ubuntu"
            ;;
        *)
            echo "❌ Sistema no soportado automáticamente para instalar Docker: ${ID:-desconocido}"
            echo "   Instala Docker/Compose y vuelve a ejecutar el script."
            exit 1
            ;;
    esac

    $SUDO install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "$DOCKER_REPO/gpg" | $SUDO gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] $DOCKER_REPO ${VERSION_CODENAME} stable" \
        | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
    $SUDO apt-get update -y
    $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    $SUDO systemctl enable --now docker
fi

for pkg in git unzip iproute2 python3; do
    if ! command_exists "$pkg"; then
        echo "⚙️ Instalando $pkg..."
        $SUDO apt-get update -y >/dev/null
        $SUDO apt-get install -y "$pkg"
    fi
done

if ! docker compose version >/dev/null 2>&1; then
    echo "❌ Docker Compose v2 no está disponible."
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "⚡ Iniciando Docker..."
    $SUDO systemctl enable --now docker 2>/dev/null || $SUDO service docker start
fi

echo "✅ Docker: $(docker --version)"
echo "✅ Compose: $(docker compose version --short 2>/dev/null || docker compose version)"

# ------------------------------------------------------------------------------
# 0.1 Usuario administrativo
# ------------------------------------------------------------------------------
echo "================================================="
echo "👤 0.1 Configuración del usuario administrativo"
echo "================================================="

SUDO_USER_NAME="${1:-}"
if [ -z "$SUDO_USER_NAME" ]; then
    read -r -p "👉 Nombre del usuario sudo a crear/usar: " SUDO_USER_NAME
fi
[ -n "$SUDO_USER_NAME" ] || { echo "❌ Usuario vacío."; exit 1; }

if ! id "$SUDO_USER_NAME" >/dev/null 2>&1; then
    read -r -s -p "👉 Contraseña para '$SUDO_USER_NAME' (ENTER = sin contraseña): " SUDO_USER_PASS
    echo ""
    $SUDO useradd -m -s /bin/bash "$SUDO_USER_NAME"
    $SUDO usermod -aG sudo "$SUDO_USER_NAME"
    if [ -n "$SUDO_USER_PASS" ]; then
        printf '%s:%s\n' "$SUDO_USER_NAME" "$SUDO_USER_PASS" | $SUDO chpasswd
    else
        $SUDO passwd -d "$SUDO_USER_NAME" >/dev/null 2>&1 || true
    fi
else
    echo "✅ El usuario '$SUDO_USER_NAME' ya existe."
    if ! id -nG "$SUDO_USER_NAME" | grep -qw sudo; then
        $SUDO usermod -aG sudo "$SUDO_USER_NAME"
    fi
fi

for U in "${USER:-}" "$SUDO_USER_NAME"; do
    if [ -n "$U" ] && id "$U" >/dev/null 2>&1; then
        id -nG "$U" | grep -qw docker || $SUDO usermod -aG docker "$U" 2>/dev/null || true
    fi
done

# ------------------------------------------------------------------------------
# 0.2 Escritorio y repositorio
# ------------------------------------------------------------------------------
USER_HOME=$(getent passwd "$SUDO_USER_NAME" | cut -d: -f6 || true)
USER_HOME=${USER_HOME:-$HOME}

if [ -d "$USER_HOME/Desktop" ]; then
    ESCRITORIO="$USER_HOME/Desktop"
elif [ -d "$USER_HOME/Escritorio" ]; then
    ESCRITORIO="$USER_HOME/Escritorio"
else
    ESCRITORIO="$USER_HOME/Desktop"
    $SUDO mkdir -p "$ESCRITORIO"
    $SUDO chown "$SUDO_USER_NAME:$SUDO_USER_NAME" "$ESCRITORIO" 2>/dev/null || true
fi

read -r -p "👉 URL del repositorio Git: " REPO_URL
[ -n "$REPO_URL" ] || { echo "❌ Debes indicar una URL Git."; exit 1; }

REPO_BASENAME=$(basename "${REPO_URL%/}")
REPO_BASENAME=${REPO_BASENAME%.git}
DEFAULT_SYSTEM_NAME=$(sanitize_name "$REPO_BASENAME")
DEFAULT_SYSTEM_NAME=${DEFAULT_SYSTEM_NAME:-sistema}

read -r -p "👉 Nombre del sistema [$DEFAULT_SYSTEM_NAME]: " SYSTEM_NAME
SYSTEM_NAME=${SYSTEM_NAME:-$DEFAULT_SYSTEM_NAME}
SYSTEM_NAME=$(sanitize_name "$SYSTEM_NAME")
[ -n "$SYSTEM_NAME" ] || { echo "❌ Nombre de sistema inválido."; exit 1; }

REPO_DIR="$ESCRITORIO/$SYSTEM_NAME"

if [ -e "$REPO_DIR" ] && [ ! -d "$REPO_DIR/.git" ]; then
    echo "❌ Ya existe '$REPO_DIR' y no es un repositorio Git."
    exit 1
fi

# ------------------------------------------------------------------------------
# 0.3 Descargar/clonar repositorio sin destruir una copia existente
# ------------------------------------------------------------------------------
echo "================================================="
echo "📥 0.3 Obteniendo repositorio"
echo "================================================="

extract_repository_zip() {
    local zip_file="$1" dest="$2" extract_dir top_count top_dir
    extract_dir=$(mktemp -d)

    echo "📦 Extrayendo repositorio ZIP..."
    if ! unzip -q "$zip_file" -d "$extract_dir"; then
        rm -rf "$extract_dir"
        echo "❌ No se pudo extraer el ZIP del repositorio."
        exit 1
    fi

    top_count=$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
    if [ "$top_count" = "1" ] && [ "$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')" = "0" ]; then
        top_dir=$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d -print -quit)
    else
        top_dir="$extract_dir"
    fi

    mkdir -p "$dest"
    tar -C "$top_dir" -cf - . | tar -C "$dest" -xf -
    rm -rf "$extract_dir"
}

REPO_URL_NO_QUERY="${REPO_URL%%\?*}"
case "${REPO_URL_NO_QUERY,,}" in
    *.zip)
        ZIP_TMP=$(mktemp --suffix=.zip)
        echo "⬇️ Descargando ZIP: $REPO_URL"
        if ! curl -fL --retry 3 --connect-timeout 20 "$REPO_URL" -o "$ZIP_TMP"; then
            rm -f "$ZIP_TMP"
            echo "❌ No se pudo descargar el ZIP del repositorio."
            exit 1
        fi
        if [ -e "$REPO_DIR" ]; then
            echo "❌ Ya existe '$REPO_DIR'. Para un repositorio ZIP no se sobrescribirá una copia existente."
            rm -f "$ZIP_TMP"
            exit 1
        fi
        mkdir -p "$REPO_DIR"
        extract_repository_zip "$ZIP_TMP" "$REPO_DIR"
        rm -f "$ZIP_TMP"
        ;;
    *)
        if [ -d "$REPO_DIR/.git" ]; then
            git -C "$REPO_DIR" remote set-url origin "$REPO_URL"
            if ! git -C "$REPO_DIR" pull --ff-only; then
                echo "⚠️ No se pudo actualizar con pull --ff-only. Se conserva el código local."
            fi
        else
            if [ -n "$SUDO" ]; then
                $SUDO -u "$SUDO_USER_NAME" git clone "$REPO_URL" "$REPO_DIR"
            else
                git clone "$REPO_URL" "$REPO_DIR"
            fi
        fi
        ;;
esac

$SUDO chown -R "$SUDO_USER_NAME:$SUDO_USER_NAME" "$REPO_DIR" 2>/dev/null || true

echo "✅ Código fuente: $REPO_DIR"

# ------------------------------------------------------------------------------
# 1. Detectar Compose
# ------------------------------------------------------------------------------
COMPOSE_FILE=""
for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [ -f "$REPO_DIR/$f" ]; then
        COMPOSE_FILE="$REPO_DIR/$f"
        break
    fi
done

[ -n "$COMPOSE_FILE" ] || { echo "❌ No se encontró un archivo Compose."; exit 1; }

cd "$REPO_DIR"

echo "================================================="
echo "🔎 1. Analizando proyecto"
echo "================================================="

PREFIX_CONTENEDOR="${PREFIX_CONTENEDOR:-}" COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-}" \
    docker compose -f "$COMPOSE_FILE" config >/dev/null
mapfile -t SERVICES < <(PREFIX_CONTENEDOR="${PREFIX_CONTENEDOR:-}" COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-}" \
    docker compose -f "$COMPOSE_FILE" config --services)
[ "${#SERVICES[@]}" -gt 0 ] || { echo "❌ Compose no contiene servicios."; exit 1; }

printf '   • %s\n' "${SERVICES[@]}"

# ------------------------------------------------------------------------------
# 2. Seleccionar instancia Pn sin tocar las anteriores
# ------------------------------------------------------------------------------
CONTADOR=1
while :; do
    CARPETA_DESTINO="$ESCRITORIO/P${CONTADOR}"
    PROJECT_CANDIDATE="p${CONTADOR}"
    if [ ! -e "$CARPETA_DESTINO" ] && \
       ! docker ps -a --format '{{.Names}}' | grep -q "^${PROJECT_CANDIDATE}_" && \
       ! docker network ls --format '{{.Name}}' | grep -q "^${PROJECT_CANDIDATE}_"; then
        break
    fi
    CONTADOR=$((CONTADOR + 1))
done

NOMBRE_CARPETA="P${CONTADOR}"
COMPOSE_PROJECT_NAME="$PROJECT_CANDIDATE"
mkdir -p "$CARPETA_DESTINO"

INSTANCE_SOURCE="$CARPETA_DESTINO/source"
INSTANCE_ENV="$CARPETA_DESTINO/.env"
MANIFEST="$CARPETA_DESTINO/deployment.env"

if [ -f "$REPO_DIR/.env" ]; then
    cp "$REPO_DIR/.env" "$INSTANCE_ENV"
else
    : > "$INSTANCE_ENV"
fi
printf '\nCOMPOSE_PROJECT_NAME=%s\nPREFIX_CONTENEDOR=%s\nPROJECT_NAME=%s\nPROJECT_SOURCE=%s\n' \
    "$COMPOSE_PROJECT_NAME" "$COMPOSE_PROJECT_NAME" "$SYSTEM_NAME" "$CARPETA_DESTINO/source" >> "$INSTANCE_ENV"

mkdir -p "$INSTANCE_SOURCE"
tar -C "$REPO_DIR" --exclude='./.git' -cf - . | tar -C "$INSTANCE_SOURCE" -xf -

extract_embedded_zips() {
    local pass zip_file key out_dir found
    declare -A ZIP_DONE=()

    for pass in 1 2 3 4 5; do
        found=0
        while IFS= read -r -d '' zip_file; do
            key=$(printf '%s' "$zip_file" | sha256sum | awk '{print $1}')
            [ -n "${ZIP_DONE[$key]:-}" ] && continue
            ZIP_DONE[$key]=1
            found=1

            out_dir="$INSTANCE_SOURCE/.zip_extract/$key"
            mkdir -p "$out_dir"
            echo "📦 Extrayendo paquete interno: ${zip_file#$INSTANCE_SOURCE/}"
            if ! unzip -oq "$zip_file" -d "$out_dir"; then
                echo "❌ No se pudo extraer: ${zip_file#$INSTANCE_SOURCE/}"
                return 1
            fi
        done < <(find "$INSTANCE_SOURCE" -type f -iname '*.zip' ! -path '*/.git/*' -print0)

        [ "$found" -eq 0 ] && break
    done
}

extract_embedded_zips

INSTANCE_COMPOSE_FILE=""
for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [ -f "$INSTANCE_SOURCE/$f" ]; then
        grep -vE '^version:[[:space:]]*["'\'']?[0-9.]+["'\'']?' "$INSTANCE_SOURCE/$f" > "$INSTANCE_SOURCE/.universal-compose.yml"
        INSTANCE_COMPOSE_FILE="$INSTANCE_SOURCE/.universal-compose.yml"
        break
    fi
done
[ -n "$INSTANCE_COMPOSE_FILE" ] || { echo "❌ No se encontró Compose dentro de la copia de la instancia."; exit 1; }

[ -f "$REPO_DIR/.env.example" ] && cp "$REPO_DIR/.env.example" "$CARPETA_DESTINO/.env.example" || true

ORIGINAL_COMPOSE_FILE="$COMPOSE_FILE"
COMPOSE_FILE="$INSTANCE_COMPOSE_FILE"
REPO_DIR_ORIGINAL="$REPO_DIR"
REPO_DIR="$INSTANCE_SOURCE"

COMPOSE_CONFIG=$(docker compose --env-file "$INSTANCE_ENV" -f "$COMPOSE_FILE" --project-directory "$REPO_DIR" config)
mapfile -t SERVICES < <(docker compose --env-file "$INSTANCE_ENV" -f "$COMPOSE_FILE" --project-directory "$REPO_DIR" config --services)

# ------------------------------------------------------------------------------
# 3. Analizar servicio de BD e imagen exacta
# ------------------------------------------------------------------------------

DB_SERVICE=""
DB_ENGINE=""
DB_IMAGE=""
DB_NAME_DETECTED=""
DB_USER_DETECTED=""
DB_PASSWORD_DETECTED=""
ROOT_PASSWORD_DETECTED=""

for preferred in mysql mariadb db database postgres postgresql; do
    for svc in "${SERVICES[@]}"; do
        if [ "$(printf '%s' "$svc" | tr '[:upper:]' '[:lower:]')" = "$preferred" ]; then
            DB_SERVICE="$svc"
            break 2
        fi
    done
done

if [ -z "$DB_SERVICE" ]; then
    for svc in "${SERVICES[@]}"; do
        lower=$(printf '%s' "$svc" | tr '[:upper:]' '[:lower:]')
        if [[ "$lower" =~ (mysql|mariadb|postgres|database|db) ]]; then
            DB_SERVICE="$svc"
            break
        fi
    done
fi

service_block() {
    local svc="$1"
    printf '%s\n' "$COMPOSE_CONFIG" | awk -v svc="$svc" '
        $0 == "  " svc ":" {inside=1; next}
        inside && /^  [A-Za-z0-9_.-]+:$/ {exit}
        inside {print}
    '
}

if [ -n "$DB_SERVICE" ]; then
    SERVICE_BLOCK=$(service_block "$DB_SERVICE")
    DB_IMAGE=$(printf '%s\n' "$SERVICE_BLOCK" | awk '/^[[:space:]]+image:/ {sub(/^[^:]+:[[:space:]]*/, ""); print; exit}' | sed 's/^"//;s/"$//' || true)

    DB_NAME_DETECTED=$(printf '%s\n' "$SERVICE_BLOCK" | grep -E '^[[:space:]]+(MYSQL_DATABASE|MARIADB_DATABASE|POSTGRES_DB):' | head -n1 | sed -E 's/^[^:]+:[[:space:]]*//;s/^"//;s/"$//' || true)
    DB_USER_DETECTED=$(printf '%s\n' "$SERVICE_BLOCK" | grep -E '^[[:space:]]+(MYSQL_USER|MARIADB_USER|POSTGRES_USER):' | head -n1 | sed -E 's/^[^:]+:[[:space:]]*//;s/^"//;s/"$//' || true)
    DB_PASSWORD_DETECTED=$(printf '%s\n' "$SERVICE_BLOCK" | grep -E '^[[:space:]]+(MYSQL_PASSWORD|MARIADB_PASSWORD|POSTGRES_PASSWORD):' | head -n1 | sed -E 's/^[^:]+:[[:space:]]*//;s/^"//;s/"$//' || true)
    ROOT_PASSWORD_DETECTED=$(printf '%s\n' "$SERVICE_BLOCK" | grep -E '^[[:space:]]+(MYSQL_ROOT_PASSWORD|MARIADB_ROOT_PASSWORD):' | head -n1 | sed -E 's/^[^:]+:[[:space:]]*//;s/^"//;s/"$//' || true)

    case "${DB_IMAGE,,}" in
        *mariadb*) DB_ENGINE="mariadb" ;;
        *mysql*) DB_ENGINE="mysql" ;;
        *postgres*) DB_ENGINE="postgres" ;;
    esac

    if [ -z "$DB_ENGINE" ]; then
        if printf '%s\n' "$SERVICE_BLOCK" | grep -qE 'MARIADB_(DATABASE|USER|PASSWORD|ROOT_PASSWORD)'; then
            DB_ENGINE="mariadb"
        elif printf '%s\n' "$SERVICE_BLOCK" | grep -qE 'POSTGRES_(DB|USER|PASSWORD)'; then
            DB_ENGINE="postgres"
        elif printf '%s\n' "$SERVICE_BLOCK" | grep -qE 'MYSQL_(DATABASE|USER|PASSWORD|ROOT_PASSWORD)'; then
            echo "⚠️ El servicio '$DB_SERVICE' usa variables MYSQL_* pero su imagen no identifica el motor."
            echo "   No se adivinará silenciosamente entre MySQL y MariaDB."
            echo "1) MySQL"
            echo "2) MariaDB"
            read -r -p "👉 Selección [1]: " engine_choice
            engine_choice=${engine_choice:-1}
            case "$engine_choice" in
                1) DB_ENGINE="mysql" ;;
                2) DB_ENGINE="mariadb" ;;
                *) echo "❌ Selección inválida."; exit 1 ;;
            esac
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 4. Elegir modo BD / SQL
# ------------------------------------------------------------------------------
DB_MODE="none"
DB_NAME="$DB_NAME_DETECTED"
DB_APP_USER=""
DB_APP_PASS=""
GRANT_MODE="none"
CREATE_DB_USER="2"
SQL_FILE=""

if [ -n "$DB_SERVICE" ]; then
    echo "================================================="
    echo "🗄️ 2. Configuración de base de datos"
    echo "================================================="
    echo "Servicio : $DB_SERVICE"
    echo "Motor    : ${DB_ENGINE:-no determinado}"
    echo "Imagen   : ${DB_IMAGE:-no especificada}"
    echo ""
    echo "1) Crear/usar BD y no importar SQL"
    echo "2) Crear/usar BD e importar SQL si está vacía"
    echo "3) No gestionar la BD desde este instalador"
    read -r -p "👉 Selección [1]: " DB_MODE
    DB_MODE=${DB_MODE:-1}
    [[ "$DB_MODE" =~ ^[123]$ ]] || { echo "❌ Selección inválida."; exit 1; }

    if [ -z "$DB_NAME" ]; then
        read -r -p "👉 Nombre de la base de datos: " DB_NAME
    else
        read -r -p "👉 Nombre de la base de datos [$DB_NAME]: " tmp
        DB_NAME=${tmp:-$DB_NAME}
    fi

    if [ "$DB_MODE" = "2" ]; then
        echo "🔎 Buscando archivos SQL dentro del contenido extraído (incluidos paquetes ZIP internos)..."
        mapfile -t SQL_FILES < <(find "$REPO_DIR" -type f \( -iname '*.sql' -o -iname '*.sql.gz' \) ! -path '*/.git/*' | sort)

        if [ "${#SQL_FILES[@]}" -eq 0 ]; then
            echo "⚠️ Se seleccionó importar SQL, pero no se encontró ningún archivo .sql/.sql.gz."
            echo "   La BD '$DB_NAME' se creará/usará normalmente y NO se realizará ninguna importación."
            echo "   El despliegue continuará; no se considera un error fatal."
            SQL_FILE=""
        else
            PREFERRED_SQL=""
            for candidate in "${SQL_FILES[@]}"; do
                base=$(basename "$candidate")
                case "${base,,}" in
                    base.sql|base.sql.gz)
                        PREFERRED_SQL="$candidate"
                        break
                        ;;
                esac
            done

            if [ -n "$PREFERRED_SQL" ]; then
                SQL_FILE="$PREFERRED_SQL"
                echo "📄 SQL inicial detectado: ${SQL_FILE#$REPO_DIR/}"
            elif [ "${#SQL_FILES[@]}" -eq 1 ]; then
                SQL_FILE="${SQL_FILES[0]}"
                echo "📄 SQL detectado: ${SQL_FILE#$REPO_DIR/}"
            else
                echo "📄 SQL encontrados en el repositorio extraído:"
                for i in "${!SQL_FILES[@]}"; do
                    echo "   $((i+1))) ${SQL_FILES[$i]#$REPO_DIR/}"
                done
                read -r -p "👉 Selección [1]: " SQL_INDEX
                SQL_INDEX=${SQL_INDEX:-1}
                [[ "$SQL_INDEX" =~ ^[0-9]+$ ]] && [ "$SQL_INDEX" -ge 1 ] && [ "$SQL_INDEX" -le "${#SQL_FILES[@]}" ] || { echo "❌ Selección inválida."; exit 1; }
                SQL_FILE="${SQL_FILES[$((SQL_INDEX-1))]}"
            fi
        fi
    fi
fi

if [ -n "$DB_SERVICE" ] && [ "$DB_MODE" != "3" ] && [ -n "$DB_ENGINE" ]; then
    echo "================================================="
    echo "👤 3. Usuario de base de datos"
    echo "================================================="
    echo "1) Crear/configurar usuario de aplicación"
    echo "2) No crear usuario"
    read -r -p "👉 Selección [1]: " CREATE_DB_USER
    CREATE_DB_USER=${CREATE_DB_USER:-1}

    if [ "$CREATE_DB_USER" = "1" ]; then
        DB_APP_USER="$DB_USER_DETECTED"
        read -r -p "👉 Usuario BD [${DB_APP_USER:-app}]: " tmp
        DB_APP_USER=${tmp:-${DB_APP_USER:-app}}
        read -r -s -p "👉 Contraseña BD (ENTER = usar la definida por Compose / sin cambiar): " DB_APP_PASS
        echo ""
        if [ -z "$DB_APP_PASS" ]; then DB_APP_PASS="$DB_PASSWORD_DETECTED"; fi

        if [[ "$DB_ENGINE" == "mysql" || "$DB_ENGINE" == "mariadb" ]]; then
            echo "1) Todos los permisos solo sobre '$DB_NAME'"
            echo "2) Permisos básicos de aplicación"
            echo "3) Crear usuario sin otorgar permisos"
            read -r -p "👉 Permisos [1]: " GRANT_MODE
            GRANT_MODE=${GRANT_MODE:-1}
        else
            GRANT_MODE="none"
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 5. Generar variables de instancia
# ------------------------------------------------------------------------------
NUM_INSTANCIA=$((CONTADOR - 1))
BASE_WEB=$((1080 + NUM_INSTANCIA * 2))
BASE_PMA=$((8081 + NUM_INSTANCIA * 2))
BASE_DB=$((3307 + NUM_INSTANCIA))
BASE_SSL=$((8443 + NUM_INSTANCIA * 2))

next_free_port() {
    local p="$1" step="$2"
    while ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\.)${p}$"; do
        p=$((p + step))
    done
    echo "$p"
}

PUERTO_WEB=$(next_free_port "$BASE_WEB" 2)
PUERTO_PMA=$(next_free_port "$BASE_PMA" 2)
PUERTO_DB=$(next_free_port "$BASE_DB" 1)
PUERTO_SSL=$(next_free_port "$BASE_SSL" 2)

python3 - "$INSTANCE_ENV" "$COMPOSE_PROJECT_NAME" "$SYSTEM_NAME" "$INSTANCE_SOURCE" "$PUERTO_WEB" "$PUERTO_PMA" "$PUERTO_DB" "$PUERTO_SSL" "$DB_NAME" "$DB_APP_USER" "$DB_APP_PASS" <<'PY'
import sys, os
p=sys.argv[1]
managed={
    "COMPOSE_PROJECT_NAME": sys.argv[2],
    "PREFIX_CONTENEDOR": sys.argv[2],
    "PROJECT_NAME": sys.argv[3],
    "PROJECT_SOURCE": sys.argv[4],
    "PUERTO_WEB": sys.argv[5],
    "PUERTO_PMA": sys.argv[6],
    "PUERTO_DB": sys.argv[7],
    "PUERTO_SSL": sys.argv[8],
    "DB_DATABASE": sys.argv[9],
    "DB_USERNAME": sys.argv[10],
    "DB_PASSWORD": sys.argv[11],
}
lines=open(p).read().splitlines() if __import__('os').path.exists(p) else []
out=[]
seen=set()
for line in lines:
    if not line or line.lstrip().startswith('#') or '=' not in line:
        out.append(line); continue
    key=line.split('=',1)[0]
    if key in managed:
        if key not in seen:
            out.append(f'{key}={managed[key]}'); seen.add(key)
    else:
        out.append(line)
for k,v in managed.items():
    if k not in seen:
        out.append(f'{k}={v}')
open(p,'w').write('\n'.join(out)+'\n')
PY

# ------------------------------------------------------------------------------
# 6. Renderizar Compose para esta instancia y analizar aislamiento
# ------------------------------------------------------------------------------
render_compose() {
    docker compose \
        --env-file "$INSTANCE_ENV" \
        -f "$COMPOSE_FILE" \
        --project-directory "$REPO_DIR" \
        -p "$COMPOSE_PROJECT_NAME" \
        config --format json
}

RENDERED_JSON=$(render_compose)
printf '%s\n' "$RENDERED_JSON" > "$CARPETA_DESTINO/compose.rendered.json"

ANALYSIS_FILE="$CARPETA_DESTINO/resource-analysis.txt"
printf "%s\n" "$RENDERED_JSON" > "$CARPETA_DESTINO/compose.rendered.json.tmp"
python3 - "$CARPETA_DESTINO/compose.rendered.json.tmp" "$ANALYSIS_FILE" <<'PY'
import json, sys
src=sys.argv[1]
out=sys.argv[2]
d=json.load(open(src))
lines=[]
services=d.get('services') or {}
volumes=d.get('volumes') or {}
networks=d.get('networks') or {}

lines.append('[SERVICES]')
for s,c in services.items():
    if c.get('container_name'):
        lines.append(f'CONTAINER_NAME|{s}|{c["container_name"]}')
    for p in c.get('ports') or []:
        if isinstance(p, dict):
            host=p.get('published','')
            target=p.get('target','')
            proto=p.get('protocol','tcp')
            lines.append(f'PORT|{s}|{host}|{target}|{proto}')
    for m in c.get('volumes') or []:
        if isinstance(m, dict):
            typ=m.get('type','')
            source=m.get('source','')
            target=m.get('target','')
            lines.append(f'MOUNT|{s}|{typ}|{source}|{target}')

lines.append('[VOLUMES]')
for name,v in volumes.items():
    lines.append(f'VOLUME|{name}|name={v.get("name","")}|external={v.get("external",False)}')

lines.append('[NETWORKS]')
for name,n in networks.items():
    lines.append(f'NETWORK|{name}|name={n.get("name","")}|external={n.get("external",False)}')

open(out,'w').write('\n'.join(lines)+'\n')
PY
rm -f "$CARPETA_DESTINO/compose.rendered.json.tmp"

# ------------------------------------------------------------------------------
# 7. Verificación estricta de aislamiento
# ------------------------------------------------------------------------------
echo "================================================="
echo "🛡️ 4. Verificando aislamiento de la instancia $NOMBRE_CARPETA"
echo "================================================="

CONFLICT=0

while IFS='|' read -r kind svc cname; do
    [ "$kind" = "CONTAINER_NAME" ] || continue
    if docker ps -a --format '{{.Names}}' | grep -Fxq "$cname"; then
        echo "❌ CONFLICTO: el container_name '$cname' ya existe."
        echo "   El Compose debe usar un nombre derivado de COMPOSE_PROJECT_NAME o eliminar container_name."
        CONFLICT=1
    fi
done < "$ANALYSIS_FILE"

while IFS='|' read -r kind vname namepart externalpart; do
    [ "$kind" = "VOLUME" ] || continue
    fixed_name="${namepart#name=}"
    external="${externalpart#external=}"
    if [ "$external" = "True" ] || [ "$external" = "true" ]; then
        echo "❌ CONFLICTO: volumen externo '$vname'."
        echo "   Una nueva instancia no puede reutilizar automáticamente un volumen externo."
        CONFLICT=1
    elif [ -n "$fixed_name" ] && [[ "$fixed_name" != "${COMPOSE_PROJECT_NAME}_"* ]]; then
        echo "❌ CONFLICTO: volumen '$vname' tiene nombre explícito '$fixed_name'."
        echo "   Un nombre explícito solo es seguro si queda aislado bajo '$COMPOSE_PROJECT_NAME'."
        CONFLICT=1
    fi
done < "$ANALYSIS_FILE"

while IFS='|' read -r kind nname namepart externalpart; do
    [ "$kind" = "NETWORK" ] || continue
    fixed_name="${namepart#name=}"
    external="${externalpart#external=}"
    if [ "$external" = "True" ] || [ "$external" = "true" ]; then
        echo "❌ CONFLICTO: red externa '$nname'."
        echo "   Una nueva instancia no puede compartirla automáticamente."
        CONFLICT=1
    elif [ -n "$fixed_name" ] && [[ "$fixed_name" != "${COMPOSE_PROJECT_NAME}_"* ]]; then
        echo "❌ CONFLICTO: red '$nname' tiene nombre explícito '$fixed_name'."
        echo "   Un nombre explícito solo es seguro si queda aislado bajo '$COMPOSE_PROJECT_NAME'."
        CONFLICT=1
    fi
done < "$ANALYSIS_FILE"

while IFS='|' read -r kind svc typ source target; do
    [ "$kind" = "MOUNT" ] || continue
    if [ "$typ" = "bind" ]; then
        case "$source" in
            "$REPO_DIR"|"$REPO_DIR"/*|"$CARPETA_DESTINO"|"$CARPETA_DESTINO"/*) ;;
            *)
                echo "❌ CONFLICTO: bind mount externo en '$svc': '$source' -> '$target'"
                echo "   No se puede garantizar aislamiento entre P1/P2/P3."
                CONFLICT=1
                ;;
        esac
    fi
done < "$ANALYSIS_FILE"

while IFS='|' read -r kind svc host target proto; do
    [ "$kind" = "PORT" ] || continue
    [ -n "$host" ] || continue
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\.)${host}$"; then
        echo "❌ CONFLICTO: el puerto host $host/$proto de '$svc' ya está ocupado."
        echo "   El Compose debe consumir una variable de instancia para poder asignar otro puerto."
        CONFLICT=1
    fi
done < "$ANALYSIS_FILE"

while IFS='|' read -r kind svc host target proto; do
    [ "$kind" = "PORT" ] || continue
    [ -n "$host" ] || continue
    owners=$(docker ps --format '{{.Names}}' --filter "publish=$host" 2>/dev/null || true)
    if [ -n "$owners" ]; then
        echo "❌ CONFLICTO Docker: $svc intenta publicar $host y ya existe: $owners"
        CONFLICT=1
    fi
done < "$ANALYSIS_FILE"

if [ "$CONFLICT" -ne 0 ]; then
    echo ""
    echo "🛑 DESPLIEGUE DETENIDO ANTES DE docker compose up."
    echo "   No se eliminaron volúmenes, contenedores ni redes."
    echo "   Revisa '$CARPETA_DESTINO/resource-analysis.txt'."
    exit 1
fi

echo "✅ No se detectaron recursos fijos/external que puedan colisionar."

# ------------------------------------------------------------------------------
# 8. Preflight de imágenes: conservar exactamente la imagen declarada
# ------------------------------------------------------------------------------
preflight_images() {
    local svc image has_build dockerfile_path
    for svc in "${SERVICES[@]}"; do
        has_build=$(printf '%s\n' "$COMPOSE_CONFIG" | awk -v s="  $svc:" '
            $0==s{inside=1;next} inside && /^  [A-Za-z0-9_.-]+:/{exit}
            inside && /^ *build:/{print 1;exit}')
        image=$(printf '%s\n' "$COMPOSE_CONFIG" | awk -v s="  $svc:" '
            $0==s{inside=1;next} inside && /^  [A-Za-z0-9_.-]+:/{exit}
            inside && /^ *image:/{sub(/^ *image:[[:space:]]*/,"");print;exit}')

        [ -n "$has_build" ] && continue
        [ -n "$image" ] || continue

        # 1. ¿Existe localmente?
        if docker image inspect "$image" >/dev/null 2>&1; then
            echo "✅ Imagen disponible localmente: $svc -> $image"
            continue
        fi

        # 2. ¿Existe un contenedor anterior con esa imagen? (Recuperar/Taggear)
        OLD_CONTAINER=$(docker ps -a --filter "ancestor=$image" --format '{{.ID}}' | head -n 1)
        if [ -n "$OLD_CONTAINER" ]; then
            echo "🔄 Recuperando imagen de contenedor anterior: $OLD_CONTAINER -> $image"
            docker commit "$OLD_CONTAINER" "$image" >/dev/null
            continue
        fi

        # 3. ¿Se puede descargar exactamente esa imagen?
        if docker manifest inspect "$image" >/dev/null 2>&1; then
            echo "⬇️ Descargando imagen: $svc -> $image"
            docker pull "$image"
            continue
        fi

        # 4. ¿Existe Dockerfile en el contenido extraído (incluye .zip_extract)?
        dockerfile_path=$(find "$INSTANCE_SOURCE" -type f -name "Dockerfile" | head -n 1)
        if [ -n "$dockerfile_path" ]; then
            echo "🔨 Construyendo imagen '$image' desde $(dirname "$dockerfile_path")..."
            docker build -t "$image" "$(dirname "$dockerfile_path")"
            continue
        fi

        # Falla solo si se agotan todas las vías legítimas
        echo "❌ No se puede obtener la imagen declarada '$image' para '$svc'."
        echo "   El instalador universal NO sustituirá automáticamente por ':latest'."
        exit 1
    done
}

preflight_images

# ------------------------------------------------------------------------------
# 9. Guardar manifiesto ANTES del despliegue
# ------------------------------------------------------------------------------
cat > "$MANIFEST" <<EOF
SYSTEM_NAME=$SYSTEM_NAME
INSTANCE=$NOMBRE_CARPETA
COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT_NAME
REPOSITORY_ROOT=$REPO_DIR_ORIGINAL
INSTANCE_SOURCE=$INSTANCE_SOURCE
COMPOSE_FILE=$COMPOSE_FILE
DB_SERVICE=$DB_SERVICE
DB_ENGINE=$DB_ENGINE
DB_IMAGE=$DB_IMAGE
DB_DATABASE=$DB_NAME
SQL_FILE=${SQL_FILE:-}
SQL_IMPORT_REQUESTED=$([ "$DB_MODE" = "2" ] && echo yes || echo no)
CREATED_AT=$(date -Is)
VOLUME_POLICY=INSTANCE_ISOLATED
DESTRUCTIVE_VOLUME_OPERATION=NEVER_AUTOMATIC
EOF

{
    echo "# Recursos renderizados para $NOMBRE_CARPETA"
    cat "$ANALYSIS_FILE"
} >> "$MANIFEST"

# ------------------------------------------------------------------------------
# 10. Levantar instancia NUEVA
# ------------------------------------------------------------------------------
echo "================================================="
echo "🐳 5. Desplegando $SYSTEM_NAME como $NOMBRE_CARPETA"
echo "================================================="
echo "📦 Proyecto Compose : $COMPOSE_PROJECT_NAME"
echo "💾 Política         : volumen nuevo/aislado"
echo "🛑 No se ejecutará  : docker compose down -v"
echo ""

docker compose \
    --env-file "$INSTANCE_ENV" \
    -f "$COMPOSE_FILE" \
    --project-directory "$REPO_DIR" \
    -p "$COMPOSE_PROJECT_NAME" \
    up -d --build --remove-orphans

# ------------------------------------------------------------------------------
# 11. Esperar BD
# ------------------------------------------------------------------------------
DB_CONTAINER=""
if [ -n "$DB_SERVICE" ] && [ "$DB_MODE" != "3" ]; then
    echo "================================================="
    echo "⏳ 6. Esperando BD '$DB_SERVICE'"
    echo "================================================="

    for intento in $(seq 1 60); do
        DB_CONTAINER=$(docker compose --env-file "$INSTANCE_ENV" -f "$COMPOSE_FILE" --project-directory "$REPO_DIR" -p "$COMPOSE_PROJECT_NAME" ps -q "$DB_SERVICE" 2>/dev/null || true)
        [ -n "$DB_CONTAINER" ] && break
        sleep 2
done
    [ -n "$DB_CONTAINER" ] || { echo "❌ No se encontró el contenedor de BD."; exit 1; }

    DB_READY=0
    for intento in $(seq 1 60); do
        DB_STATUS=$(docker inspect -f '{{.State.Status}}' "$DB_CONTAINER" 2>/dev/null || echo desconocido)
        if [ "$DB_STATUS" != "running" ]; then
            echo ""
            echo "❌ El contenedor de BD no está en ejecución (estado: $DB_STATUS)."
            echo "-------------------------------------------------"
            LOGS=$(docker logs --tail 80 "$DB_CONTAINER" 2>&1 || true)
            printf '%s\n' "$LOGS" | sed 's/^/    /'
            echo "-------------------------------------------------"
            if printf '%s\n' "$LOGS" | grep -qiE 'got signal 6|assertion|innodb.*(corrupt|error)|tablespace.*(corrupt|error)'; then
                echo "⚠️ Se detectó un patrón de fallo de InnoDB/SIGABRT."
                echo "   Posibles causas: incompatibilidad/corrupción del datadir o problema de imagen."
                echo "   Esta instancia NO borrará el volumen automáticamente."
            fi
            exit 1
        fi

        case "$DB_ENGINE" in
            mysql|mariadb)
                if docker exec "$DB_CONTAINER" mariadb-admin ping -u root --silent >/dev/null 2>&1 || \
                   docker exec "$DB_CONTAINER" mysqladmin ping -u root --silent >/dev/null 2>&1 || \
                   { [ -n "$ROOT_PASSWORD_DETECTED" ] && docker exec "$DB_CONTAINER" mariadb-admin ping -u root -p"$ROOT_PASSWORD_DETECTED" --silent >/dev/null 2>&1; } || \
                   { [ -n "$ROOT_PASSWORD_DETECTED" ] && docker exec "$DB_CONTAINER" mysqladmin ping -u root -p"$ROOT_PASSWORD_DETECTED" --silent >/dev/null 2>&1; }; then
                    DB_READY=1
                fi
                ;;
            postgres)
                docker exec "$DB_CONTAINER" pg_isready >/dev/null 2>&1 && DB_READY=1 || true
                ;;
            *)
                DB_READY=1
                ;;
        esac

        [ "$DB_READY" -eq 1 ] && break
        echo "   ... BD aún no está lista ($intento/60)"
        sleep 2
    done

    [ "$DB_READY" -eq 1 ] || { echo "❌ La BD no llegó a estar disponible."; exit 1; }
    echo "✅ Base de datos lista."

    # --------------------------------------------------------------------------
    # 12. Inicialización MySQL/MariaDB sin destruir datos
    # --------------------------------------------------------------------------
    if [[ "$DB_ENGINE" == "mysql" || "$DB_ENGINE" == "mariadb" ]] && [ -n "$DB_NAME" ]; then
        if docker exec "$DB_CONTAINER" mariadb --version >/dev/null 2>&1; then
            MYSQL_BIN=mariadb
        else
            MYSQL_BIN=mysql
        fi

        root_exec() {
            if [ -n "$ROOT_PASSWORD_DETECTED" ]; then
                docker exec "$DB_CONTAINER" "$MYSQL_BIN" -u root -p"$ROOT_PASSWORD_DETECTED" "$@"
            else
                docker exec "$DB_CONTAINER" "$MYSQL_BIN" -u root "$@"
            fi
        }

        DB_EXISTS=$(root_exec -N -B -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$(sql_escape "$DB_NAME")';" 2>/dev/null || true)
        if [ "$DB_EXISTS" != "$DB_NAME" ]; then
            root_exec -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;"
            echo "✅ BD '$DB_NAME' creada."
        else
            echo "✅ BD '$DB_NAME' ya existe; no se elimina ni reinicializa."
        fi
if [ "$DB_MODE" = "2" ] && [ -n "$SQL_FILE" ]; then
            TABLE_COUNT=$(root_exec -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$(sql_escape "$DB_NAME")';" 2>/dev/null || echo 0)
            if [ "$TABLE_COUNT" = "0" ]; then
                echo "📥 Importando $(basename "$SQL_FILE")..."
                
                # 1. Copiamos el archivo físicamente dentro del contenedor para evitar errores de buffer o SSL
                docker cp "$SQL_FILE" "$DB_CONTAINER:/tmp/archivo_import.sql"
                
                # 2. Ejecutamos la importación directamente desde adentro del contenedor
                if [[ "$SQL_FILE" == *.gz ]]; then
                    if [ -n "$ROOT_PASSWORD_DETECTED" ]; then
                        docker exec "$DB_CONTAINER" sh -c "gzip -dc /tmp/archivo_import.sql | $MYSQL_BIN -u root -p\"$ROOT_PASSWORD_DETECTED\" \"$DB_NAME\""
                    else
                        docker exec "$DB_CONTAINER" sh -c "gzip -dc /tmp/archivo_import.sql | $MYSQL_BIN -u root \"$DB_NAME\""
                    fi
                else
                    if [ -n "$ROOT_PASSWORD_DETECTED" ]; then
                        docker exec "$DB_CONTAINER" sh -c "$MYSQL_BIN -u root -p\"$ROOT_PASSWORD_DETECTED\" \"$DB_NAME\" < /tmp/archivo_import.sql"
                    else
                        docker exec "$DB_CONTAINER" sh -c "$MYSQL_BIN -u root \"$DB_NAME\" < /tmp/archivo_import.sql"
                    fi
                fi
                
                # 3. Limpiamos el archivo temporal
                docker exec "$DB_CONTAINER" rm -f /tmp/archivo_import.sql
                
                echo "✅ SQL importado."
            else
                echo "ℹ️ La BD ya tiene $TABLE_COUNT tabla(s); se omite SQL para evitar duplicados."
            fi
        fi

        if [ -n "$DB_APP_USER" ] && [ "$CREATE_DB_USER" = "1" ] && [ -n "$DB_APP_PASS" ]; then
            USER_ESC=$(sql_escape "$DB_APP_USER")
            PASS_ESC=$(sql_escape "$DB_APP_PASS")
            root_exec -e "CREATE USER IF NOT EXISTS '$USER_ESC'@'%' IDENTIFIED BY '$PASS_ESC'; ALTER USER '$USER_ESC'@'%' IDENTIFIED BY '$PASS_ESC';"
            case "$GRANT_MODE" in
                1) root_exec -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$USER_ESC'@'%'; FLUSH PRIVILEGES;" ;;
                2) root_exec -e "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP ON \`$DB_NAME\`.* TO '$USER_ESC'@'%'; FLUSH PRIVILEGES;" ;;
            esac
            echo "✅ Usuario de aplicación configurado."
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 13. Validación final de aislamiento y estado
# ------------------------------------------------------------------------------
FINAL_PS=$(docker compose --env-file "$INSTANCE_ENV" -f "$COMPOSE_FILE" --project-directory "$REPO_DIR" -p "$COMPOSE_PROJECT_NAME" ps --format json 2>/dev/null || true)
printf '%s\n' "$FINAL_PS" > "$CARPETA_DESTINO/containers.json"

RUNNING_COUNT=$(docker compose --env-file "$INSTANCE_ENV" -f "$COMPOSE_FILE" --project-directory "$REPO_DIR" -p "$COMPOSE_PROJECT_NAME" ps --status running -q 2>/dev/null | wc -l | tr -d ' ')
EXPECTED_COUNT=${#SERVICES[@]}

if [ "$RUNNING_COUNT" -lt "$EXPECTED_COUNT" ]; then
    echo "⚠️ La instancia fue creada pero no todos los servicios están running ($RUNNING_COUNT/$EXPECTED_COUNT)."
    echo "   Revisa: docker compose --env-file '$INSTANCE_ENV' -f '$COMPOSE_FILE' -p '$COMPOSE_PROJECT_NAME' ps"
    echo "   Logs:   docker compose --env-file '$INSTANCE_ENV' -f '$COMPOSE_FILE' -p '$COMPOSE_PROJECT_NAME' logs"
    exit 1
fi

# ------------------------------------------------------------------------------
# 14. Reporte final
# ------------------------------------------------------------------------------
IP_SERVIDOR=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)
IP_SERVIDOR=${IP_SERVIDOR:-localhost}

cat > "$CARPETA_DESTINO/README-DEPLOY.txt" <<EOF
INSTANCIA: $NOMBRE_CARPETA
PROYECTO COMPOSE: $COMPOSE_PROJECT_NAME
SISTEMA: $SYSTEM_NAME
REPOSITORIO_ORIGINAL: $REPO_DIR_ORIGINAL
FUENTE_DE_INSTANCIA: $INSTANCE_SOURCE
COMPOSE: $COMPOSE_FILE
ENV DE INSTANCIA: $INSTANCE_ENV
MANIFIESTO: $MANIFEST

POLÍTICA:
- Esta instancia es independiente de P1/P2/P3 anteriores.
- No se ejecuta docker compose down -v automáticamente.
- No se reutilizan volúmenes externos o con nombre fijo.
- No se cambia automáticamente MySQL <-> MariaDB.
- Los datos persistentes de esta instancia pertenecen a su proyecto Compose.

COMANDOS:
cd "$INSTANCE_SOURCE"
docker compose --env-file "$INSTANCE_ENV" -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" ps
docker compose --env-file "$INSTANCE_ENV" -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" logs -f
docker compose --env-file "$INSTANCE_ENV" -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" restart
docker compose --env-file "$INSTANCE_ENV" -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" down
# Para borrar datos persistentes: NO hacerlo desde este instalador; requiere una operación explícita.
EOF

chmod 600 "$INSTANCE_ENV" 2>/dev/null || true
chown "$SUDO_USER_NAME:$SUDO_USER_NAME" "$CARPETA_DESTINO" "$INSTANCE_ENV" "$MANIFEST" "$ANALYSIS_FILE" "$CARPETA_DESTINO/README-DEPLOY.txt" 2>/dev/null || true

echo ""
echo "================================================="
echo "🎉 ¡DESPLIEGUE EXITOSO!"
echo "================================================="
echo "📦 Sistema             : $SYSTEM_NAME"
echo "📁 Repositorio base     : $REPO_DIR_ORIGINAL"
echo "📁 Fuente de instancia  : $INSTANCE_SOURCE"
echo "🚀 Instancia            : $NOMBRE_CARPETA"
echo "🐳 Proyecto Docker      : $COMPOSE_PROJECT_NAME"
echo "🗄️ Servicio BD          : ${DB_SERVICE:-No detectado}"
echo "🔧 Motor BD             : ${DB_ENGINE:-No determinado}"
echo "💾 Base de datos        : ${DB_NAME:-No gestionada}"
if [ "$DB_MODE" = "2" ]; then
    if [ -n "$SQL_FILE" ]; then
        echo "📄 SQL inicial          : ${SQL_FILE#$REPO_DIR/}"
    else
        echo "📄 SQL inicial          : No encontrado (se omitió importación)"
    fi
fi
echo "🌐 IP servidor          : $IP_SERVIDOR"
echo "🔌 Puerto web           : $PUERTO_WEB"
echo "🔐 Puerto SSL           : $PUERTO_SSL"
echo "🗄️ Puerto BD            : $PUERTO_DB"
echo "🧰 Puerto PMA           : $PUERTO_PMA"
echo "-------------------------------------------------"
echo "📌 Recursos de auditoría:"
echo "   $MANIFEST"
echo "   $ANALYSIS_FILE"
echo "   $CARPETA_DESTINO/README-DEPLOY.txt"
echo "-------------------------------------------------"
echo "📌 La próxima ejecución usará otra instancia Pn y no tocará ésta."
echo "================================================="
