#!/bin/bash
set -Eeuo pipefail
 
# ============================================================================== 
# SUPER INSTALLER UNIVERSAL - Docker / Docker Compose / MySQL / MariaDB
# - Repositorio configurable
# - Código fuente en Escritorio/<NOMBRE_SISTEMA>
# - Despliegue secuencial en Escritorio/P1, P2, P3...
# - Evita colisiones con archivos, carpetas y proyectos Docker existentes
# - Detecta Dockerfile, Compose, SQL, .env.example y servicios
# - BD vacía o inicializada desde SQL
# - Usuario BD opcional y permisos configurables
# ============================================================================== 
 
trap 'echo "❌ Error en la línea $LINENO. El despliegue se detuvo."' ERR
 
SUDO=""
if [ "$EUID" -ne 0 ]; then SUDO="sudo"; fi
 
pause_read() { :; }
 
command_exists() { command -v "$1" >/dev/null 2>&1; }
 
sanitize_name() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/^-*//; s/-*$//'
}
 
sql_escape() {
    printf "%s" "$1" | sed "s/'/''/g"
}
 
# ============================================================================== 
# 0. Docker y herramientas base
# ============================================================================== 
echo "================================================="
echo "🐳 0. Verificando Docker y herramientas..."
echo "================================================="
 
if ! command_exists docker; then
    echo "⚙️  Docker no está instalado. Instalando desde el repositorio oficial..."
    $SUDO apt-get update -y
    $SUDO apt-get install -y ca-certificates curl gnupg sudo git unzip iproute2
    $SUDO install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
    $SUDO apt-get update -y
    $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    $SUDO systemctl enable --now docker
else
    echo "✅ Docker ya está instalado."
fi
 
for pkg in git unzip iproute2; do
    if ! command_exists "$pkg"; then
        echo "⚙️  Instalando $pkg..."
        $SUDO apt-get update -y >/dev/null
        $SUDO apt-get install -y "$pkg"
    fi
done
 
if ! docker compose version >/dev/null 2>&1; then
    echo "❌ Docker Compose v2 no está disponible. Instala docker-compose-plugin y vuelve a ejecutar."
    exit 1
fi
 
if ! docker info >/dev/null 2>&1; then
    echo "⚡ Iniciando Docker..."
    $SUDO systemctl enable --now docker 2>/dev/null || $SUDO service docker start
fi
 
# ============================================================================== 
# 0.1 Usuario administrativo sudo
# ============================================================================== 
echo "================================================="
echo "👤 0.1 Configuración del usuario administrativo"
echo "================================================="
 
SUDO_USER_NAME="${1:-}"
SUDO_USER_PASS="${2-}"
PASS_FROM_ARG=0
 
if [ -n "$SUDO_USER_PASS" ]; then PASS_FROM_ARG=1; fi
 
if [ -z "$SUDO_USER_NAME" ]; then
    read -r -p "👉 Nombre del usuario sudo a crear/usar: " SUDO_USER_NAME
fi
 
if [ -z "$SUDO_USER_NAME" ]; then
    echo "❌ El nombre de usuario no puede estar vacío."
    exit 1
fi
 
if ! id "$SUDO_USER_NAME" >/dev/null 2>&1; then
    if [ "$PASS_FROM_ARG" -eq 0 ]; then
        read -r -s -p "👉 Contraseña para '$SUDO_USER_NAME' (ENTER = sin contraseña): " SUDO_USER_PASS
        echo ""
    fi
    echo "⚙️  Creando usuario '$SUDO_USER_NAME'..."
    $SUDO useradd -m -s /bin/bash "$SUDO_USER_NAME"
    $SUDO usermod -aG sudo "$SUDO_USER_NAME"
else
    echo "✅ El usuario '$SUDO_USER_NAME' ya existe."
    if [ "$PASS_FROM_ARG" -eq 0 ]; then
        read -r -s -p "👉 Contraseña para '$SUDO_USER_NAME' (ENTER = dejar/sin contraseña): " SUDO_USER_PASS
        echo ""
    fi
    if ! id -nG "$SUDO_USER_NAME" | grep -qw sudo; then
        $SUDO usermod -aG sudo "$SUDO_USER_NAME"
    fi
fi
 
if [ -n "$SUDO_USER_PASS" ]; then
    printf '%s:%s\n' "$SUDO_USER_NAME" "$SUDO_USER_PASS" | $SUDO chpasswd
    echo "✅ Contraseña establecida/actualizada."
else
    $SUDO passwd -d "$SUDO_USER_NAME" >/dev/null 2>&1 || true
    echo "✅ Campo de contraseña vacío: el usuario queda sin contraseña."
fi
 
for U in "$USER" "$SUDO_USER_NAME"; do
    if id "$U" >/dev/null 2>&1 && ! id -nG "$U" 2>/dev/null | grep -qw docker; then
        $SUDO usermod -aG docker "$U" 2>/dev/null || true
    fi
done
 
# ============================================================================== 
# 0.2 Detectar escritorio y solicitar repositorio
# ============================================================================== 
USER_HOME=$(getent passwd "$SUDO_USER_NAME" | cut -d: -f6)
[ -n "$USER_HOME" ] || USER_HOME="$HOME"
 
if [ -d "$USER_HOME/Desktop" ]; then
    ESCRITORIO="$USER_HOME/Desktop"
elif [ -d "$USER_HOME/Escritorio" ]; then
    ESCRITORIO="$USER_HOME/Escritorio"
else
    ESCRITORIO="$USER_HOME/Desktop"
    $SUDO mkdir -p "$ESCRITORIO"
    $SUDO chown "$SUDO_USER_NAME:$SUDO_USER_NAME" "$ESCRITORIO" 2>/dev/null || true
fi
 
SCRIPT_ACTUAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
 
# Si el script viene de un repositorio, no se vuelve a clonar sobre sí mismo.
read -r -p "👉 URL del repositorio Git: " REPO_URL
[ -n "$REPO_URL" ] || { echo "❌ Debes indicar una URL de repositorio."; exit 1; }
 
REPO_BASENAME=$(basename "${REPO_URL%/}")
REPO_BASENAME=${REPO_BASENAME%.git}
DEFAULT_SYSTEM_NAME=$(sanitize_name "$REPO_BASENAME")
[ -n "$DEFAULT_SYSTEM_NAME" ] || DEFAULT_SYSTEM_NAME="sistema"
 
read -r -p "👉 Nombre del sistema [$DEFAULT_SYSTEM_NAME]: " SYSTEM_NAME
SYSTEM_NAME=${SYSTEM_NAME:-$DEFAULT_SYSTEM_NAME}
SYSTEM_NAME=$(sanitize_name "$SYSTEM_NAME")
[ -n "$SYSTEM_NAME" ] || { echo "❌ Nombre de sistema inválido."; exit 1; }
 
REPO_DIR="$ESCRITORIO/$SYSTEM_NAME"
 
# ============================================================================== 
# 0.3 Evitar colisión en carpeta del sistema
# ============================================================================== 
if [ -e "$REPO_DIR" ]; then
    echo "⚠️  Ya existe un archivo o carpeta con el nombre: $REPO_DIR"
    echo "1) Actualizar/usar ese repositorio si es Git"
    echo "2) Cancelar"
    read -r -p "👉 Selección [1/2]: " EXISTING_ACTION
    EXISTING_ACTION=${EXISTING_ACTION:-1}
    if [ "$EXISTING_ACTION" = "2" ]; then exit 0; fi
    if [ ! -d "$REPO_DIR/.git" ]; then
        echo "❌ Existe algo llamado '$REPO_DIR', pero no es un repositorio Git."
        echo "   Para proteger tus archivos, el script no lo sobrescribirá."
        exit 1
    fi
fi
 
# ============================================================================== 
# 0.4 Clonar/actualizar repositorio
# ============================================================================== 
echo "================================================="
echo "📥 0.4 Sincronizando: $SYSTEM_NAME"
echo "================================================="
 
if [ -d "$REPO_DIR/.git" ]; then
    git -C "$REPO_DIR" remote set-url origin "$REPO_URL"
    git -C "$REPO_DIR" pull --ff-only || {
        echo "⚠️  No se pudo hacer pull --ff-only. Se conserva el repositorio local."
    }
else
    if [ -e "$REPO_DIR" ]; then
        echo "❌ La ruta existe pero no es un repositorio Git."
        exit 1
    fi
    $SUDO mkdir -p "$ESCRITORIO"
    if [ -n "$SUDO" ]; then
        $SUDO -u "$SUDO_USER_NAME" git clone "$REPO_URL" "$REPO_DIR"
    elif command_exists runuser; then
        runuser -u "$SUDO_USER_NAME" -- git clone "$REPO_URL" "$REPO_DIR"
    else
        git clone "$REPO_URL" "$REPO_DIR"
    fi
fi
 
$SUDO chown -R "$SUDO_USER_NAME:$SUDO_USER_NAME" "$REPO_DIR" 2>/dev/null || true
chmod +x "$REPO_DIR/iniciar.sh" 2>/dev/null || true
 
echo "✅ Código fuente disponible en: $REPO_DIR"
 
# ============================================================================== 
# 0.5 Extraer ZIP si existe
# ============================================================================== 
ZIP_FILE=$(find "$REPO_DIR" -maxdepth 1 -type f -iname '*.zip' -print -quit || true)
if [ -n "$ZIP_FILE" ]; then
    echo "📦 Encontrado ZIP: $(basename "$ZIP_FILE")"
    TMP_EXTRACT="$REPO_DIR/.extract_tmp"
    rm -rf "$TMP_EXTRACT"
    mkdir -p "$TMP_EXTRACT"
    unzip -oq "$ZIP_FILE" -d "$TMP_EXTRACT"
    mapfile -t CONTENIDO_ZIP < <(find "$TMP_EXTRACT" -mindepth 1 -maxdepth 1 -printf '%f\n')
    if [ "${#CONTENIDO_ZIP[@]}" -eq 1 ] && [ -d "$TMP_EXTRACT/${CONTENIDO_ZIP[0]}" ]; then
        cp -a "$TMP_EXTRACT/${CONTENIDO_ZIP[0]}/." "$REPO_DIR/"
    else
        cp -a "$TMP_EXTRACT/." "$REPO_DIR/"
    fi
    rm -rf "$TMP_EXTRACT"
    echo "✅ ZIP extraído."
fi
 
# ============================================================================== 
# 1. Análisis automático del proyecto
# ============================================================================== 
echo "================================================="
echo "🔎 1. Analizando el proyecto..."
echo "================================================="
 
COMPOSE_FILE=""
if [ -f "$REPO_DIR/docker-compose.yml" ]; then
    COMPOSE_FILE="$REPO_DIR/docker-compose.yml"
elif [ -f "$REPO_DIR/docker-compose.yaml" ]; then
    COMPOSE_FILE="$REPO_DIR/docker-compose.yaml"
fi
 
DOCKERFILE="$REPO_DIR/Dockerfile"
if [ -f "$DOCKERFILE" ]; then echo "✅ Dockerfile encontrado"; else echo "ℹ️  Dockerfile no encontrado"; fi
if [ -n "$COMPOSE_FILE" ]; then echo "✅ Compose encontrado: $(basename "$COMPOSE_FILE")"; else echo "❌ No se encontró docker-compose.yml/.yaml"; exit 1; fi
 
# Necesario para analizar YAML sin depender de yq: usamos docker compose config.
cd "$REPO_DIR"
 
echo "🔧 Validando Docker Compose..."
docker compose -f "$COMPOSE_FILE" config >/dev/null
 
echo "📋 Servicios detectados:"
mapfile -t SERVICES < <(docker compose -f "$COMPOSE_FILE" config --services)
for SVC in "${SERVICES[@]}"; do echo "   • $SVC"; done
 
DB_SERVICE=""
for SVC in "${SERVICES[@]}"; do
    SVC_LOWER=$(echo "$SVC" | tr '[:upper:]' '[:lower:]')
    if [[ "$SVC_LOWER" =~ (mysql|mariadb|database|db|postgres|postgresql) ]]; then
        DB_SERVICE="$SVC"
        break
    fi
done
 
if [ -n "$DB_SERVICE" ]; then
    echo "🗄️  Servicio de base de datos detectado: $DB_SERVICE"
else
    echo "ℹ️  No se detectó automáticamente un servicio de base de datos."
fi
 
# Detectar nombres habituales desde compose config.
COMPOSE_CONFIG=$(docker compose -f "$COMPOSE_FILE" config)
DB_NAME_DETECTED=""
DB_USER_DETECTED=""
DB_PASSWORD_DETECTED=""
ROOT_PASSWORD_DETECTED=""
 
# Compose config suele mostrar estos valores como texto plano. Se busca dentro
# del servicio detectado sin depender de yq ni de expresiones YAML complejas.
SERVICE_BLOCK=""
if [ -n "$DB_SERVICE" ]; then
    SERVICE_BLOCK=$(printf '%s\n' "$COMPOSE_CONFIG" | awk -v svc="$DB_SERVICE" '
        $0 == "  " svc ":" {inside=1; next}
        inside && /^  [A-Za-z0-9_.-]+:$/ {exit}
        inside {print}
    ')
 
    DB_NAME_DETECTED=$(printf '%s\n' "$SERVICE_BLOCK" | grep -E '^[[:space:]]+(MYSQL_DATABASE|MARIADB_DATABASE|POSTGRES_DB):' | head -n1 | sed -E 's/^[^:]+:[[:space:]]*//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//' || true)
    DB_USER_DETECTED=$(printf '%s\n' "$SERVICE_BLOCK" | grep -E '^[[:space:]]+(MYSQL_USER|MARIADB_USER|POSTGRES_USER):' | head -n1 | sed -E 's/^[^:]+:[[:space:]]*//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//' || true)
    DB_PASSWORD_DETECTED=$(printf '%s\n' "$SERVICE_BLOCK" | grep -E '^[[:space:]]+(MYSQL_PASSWORD|MARIADB_PASSWORD|POSTGRES_PASSWORD):' | head -n1 | sed -E 's/^[^:]+:[[:space:]]*//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//' || true)
    ROOT_PASSWORD_DETECTED=$(printf '%s\n' "$SERVICE_BLOCK" | grep -E '^[[:space:]]+(MYSQL_ROOT_PASSWORD|MARIADB_ROOT_PASSWORD):' | head -n1 | sed -E 's/^[^:]+:[[:space:]]*//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//' || true)
fi
 
# DB_IMAGE se extrae del SERVICE_BLOCK ya acotado al servicio de BD, para no
# arrastrar por error la 'image:' de otro servicio que venga a continuación.
DB_ENGINE=""
if [ -n "$DB_SERVICE" ]; then
    DB_IMAGE=$(printf '%s\n' "$SERVICE_BLOCK" | grep -E '^[[:space:]]+image:' | head -n1 | sed -E 's/^[^:]+:[[:space:]]*//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//' || true)
    case "$DB_IMAGE" in
        *mariadb*) DB_ENGINE="mariadb" ;;
        *mysql*) DB_ENGINE="mysql" ;;
        *postgres*) DB_ENGINE="postgres" ;;
    esac
fi
 
# ============================================================================== 
# 2. Selección de BD y SQL
# ============================================================================== 
DB_MODE="none"
DB_NAME="${DB_NAME_DETECTED:-}"
SQL_FILE=""
 
if [ -n "$DB_SERVICE" ]; then
    echo "================================================="
    echo "🗄️  2. CONFIGURACIÓN DE BASE DE DATOS"
    echo "================================================="
    echo "1) Crear/usar una base de datos completamente vacía"
    echo "2) Crear/usar la base de datos e importar datos iniciales"
    echo "3) No gestionar la base de datos desde este instalador"
    read -r -p "👉 Selección [1]: " DB_MODE
    DB_MODE=${DB_MODE:-1}
    case "$DB_MODE" in 1|2|3) ;; *) echo "❌ Selección inválida."; exit 1 ;; esac
 
    if [ -z "$DB_NAME" ]; then
        read -r -p "👉 Nombre de la base de datos: " DB_NAME
    else
        read -r -p "👉 Nombre de la base de datos [$DB_NAME]: " INPUT_DB_NAME
        DB_NAME=${INPUT_DB_NAME:-$DB_NAME}
    fi
 
    if [ "$DB_MODE" = "2" ]; then
        mapfile -t SQL_FILES < <(find "$REPO_DIR" -type f \( -iname '*.sql' -o -iname '*.sql.gz' \) ! -path '*/.git/*' | sort)
        if [ "${#SQL_FILES[@]}" -eq 0 ]; then
            echo "❌ Elegiste importar datos, pero no se encontró ningún archivo SQL."
            exit 1
        elif [ "${#SQL_FILES[@]}" -eq 1 ]; then
            SQL_FILE="${SQL_FILES[0]}"
            echo "📄 SQL detectado: $(basename "$SQL_FILE")"
        else
            echo "📄 Archivos SQL encontrados:"
            for i in "${!SQL_FILES[@]}"; do echo "   $((i+1))) ${SQL_FILES[$i]#$REPO_DIR/}"; done
            read -r -p "👉 Selecciona el archivo [1]: " SQL_INDEX
            SQL_INDEX=${SQL_INDEX:-1}
            [[ "$SQL_INDEX" =~ ^[0-9]+$ ]] || { echo "❌ Selección inválida."; exit 1; }
            [ "$SQL_INDEX" -ge 1 ] && [ "$SQL_INDEX" -le "${#SQL_FILES[@]}" ] || { echo "❌ Selección inválida."; exit 1; }
            SQL_FILE="${SQL_FILES[$((SQL_INDEX-1))]}"
        fi
    fi
else
    DB_MODE="none"
fi
 
# ============================================================================== 
# 3. Usuario de BD y permisos
# ============================================================================== 
DB_APP_USER=""
DB_APP_PASS=""
GRANT_MODE="none"
CREATE_DB_USER="2"
 
if [ -n "$DB_SERVICE" ] && [ "$DB_MODE" != "none" ]; then
    echo "================================================="
    echo "👤 3. USUARIO DE BASE DE DATOS"
    echo "================================================="
    echo "1) Crear usuario para la aplicación"
    echo "2) No crear usuario"
    read -r -p "👉 Selección [1]: " CREATE_DB_USER
    CREATE_DB_USER=${CREATE_DB_USER:-1}
 
    if [ "$CREATE_DB_USER" = "1" ]; then
        DB_APP_USER="${DB_USER_DETECTED:-}"
        if [ -n "$DB_APP_USER" ]; then
            read -r -p "👉 Usuario BD [$DB_APP_USER]: " INPUT_DB_USER
            DB_APP_USER=${INPUT_DB_USER:-$DB_APP_USER}
        else
            read -r -p "👉 Usuario BD: " DB_APP_USER
        fi
 
        read -r -s -p "👉 Contraseña BD (ENTER = sin contraseña): " DB_APP_PASS
        echo ""
 
        echo "¿Qué permisos tendrá '$DB_APP_USER'?"
        echo "1) Todos los permisos SOLO sobre '$DB_NAME'"
        echo "2) Permisos básicos de aplicación"
        echo "3) No otorgar permisos automáticamente"
        read -r -p "👉 Selección [1]: " GRANT_MODE
        GRANT_MODE=${GRANT_MODE:-1}
    fi
fi
 
# ============================================================================== 
# 4. Crear carpeta de despliegue P1/P2/P3... en el Escritorio
# ============================================================================== 
CONTADOR=1
while true; do
    CARPETA_DESTINO="$ESCRITORIO/P${CONTADOR}"
    if [ ! -e "$CARPETA_DESTINO" ] && ! docker ps -a --format '{{.Names}}' | grep -q "^P${CONTADOR}_"; then
        break
    fi
    CONTADOR=$((CONTADOR + 1))
done
 
NOMBRE_CARPETA="P${CONTADOR}"
# Docker Compose exige nombres de proyecto en minúsculas (solo [a-z0-9_-],
# empezando por letra o número). La carpeta visual (P1, P2...) puede seguir
# en mayúscula porque es solo un nombre de directorio, son cosas distintas.
COMPOSE_PROJECT_NAME=$(sanitize_name "$NOMBRE_CARPETA")
mkdir -p "$CARPETA_DESTINO"
 
# El archivo de compose queda también dentro de Pn para que el despliegue tenga
# una carpeta propia y fácil de localizar. El contexto real sigue siendo el repo.
cp "$COMPOSE_FILE" "$CARPETA_DESTINO/$(basename "$COMPOSE_FILE")"
[ -f "$REPO_DIR/.env.example" ] && cp "$REPO_DIR/.env.example" "$CARPETA_DESTINO/.env.example" || true
 
# ============================================================================== 
# 5. Puertos y variables genéricas
# ============================================================================== 
echo "================================================="
echo "🔌 4. Asignando puertos y variables..."
echo "================================================="
 
NUM_INSTANCIA=$((CONTADOR - 1))
PUERTO_WEB_ORIGINAL=$((1080 + NUM_INSTANCIA * 2))
PUERTO_PMA_ORIGINAL=$((8081 + NUM_INSTANCIA * 2))
PUERTO_DB_ORIGINAL=$((3307 + NUM_INSTANCIA))
PUERTO_SSL_ORIGINAL=$((8443 + NUM_INSTANCIA * 2))
 
verificar_y_corregir() {
    local puerto="$1"
    local incremento="$2"
    while ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\.)${puerto}$"; do
        puerto=$((puerto + incremento))
    done
    echo "$puerto"
}
 
PUERTO_WEB=$(verificar_y_corregir "$PUERTO_WEB_ORIGINAL" 2)
PUERTO_PMA=$(verificar_y_corregir "$PUERTO_PMA_ORIGINAL" 2)
PUERTO_DB=$(verificar_y_corregir "$PUERTO_DB_ORIGINAL" 1)
PUERTO_SSL=$(verificar_y_corregir "$PUERTO_SSL_ORIGINAL" 2)
 
cat > "$CARPETA_DESTINO/.env" <<ENVFILE
COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}
PREFIX_CONTENEDOR=${COMPOSE_PROJECT_NAME}
PROJECT_NAME=${SYSTEM_NAME}
PROJECT_SOURCE=${REPO_DIR}
PUERTO_WEB=${PUERTO_WEB}
PUERTO_PMA=${PUERTO_PMA}
PUERTO_DB=${PUERTO_DB}
PUERTO_SSL=${PUERTO_SSL}
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_APP_USER}
DB_PASSWORD=${DB_APP_PASS}
ENVFILE
 
# ============================================================================== 
# 5.1 Preflight: cada servicio debe ser construible o descargable
# ============================================================================== 
# Si un servicio solo tiene 'image:' (sin 'build:'), esa imagen debe existir ya
# localmente o en algún registro accesible. Si no, en vez de dejar que 'docker
# compose up' falle con un error genérico de pull, se avisa explícitamente y
# se pregunta cómo continuar (coherente con "si no se puede determinar, se
# pregunta, no se asume").
 
# Busca, entre TODOS los Dockerfile del repositorio (sin importar en qué
# carpeta estén), el que mejor corresponde a un servicio. Empareja por
# palabras clave: nombre del servicio, tokens del nombre de la imagen y,
# si aplica, el motor de BD detectado. Se descartan tokens ruidosos de
# menos de 3 caracteres (p.ej. "mi", "p1") salvo que sean exactamente el
# nombre del servicio, para evitar falsos positivos como "mi" matcheando
# dentro de "adMIn". Si hay empate entre varios candidatos, se pregunta
# al usuario en vez de asumir — misma filosofía que el resto del script.
match_dockerfile_for_service() {
    local svc="$1" image="$2"
    local svc_lower kw path_lower score best_score=0 image_no_tag entry sel i d
    local -a keyword_list=() img_tokens=() scored_paths=() best_paths=()
 
    svc_lower=$(echo "$svc" | tr '[:upper:]' '[:lower:]')
    keyword_list+=("$svc_lower")
 
    image_no_tag="${image%%:*}"
    local IFS='/_.-'
    read -r -a img_tokens <<< "$image_no_tag"
    unset IFS
    for kw in "${img_tokens[@]}"; do
        kw=$(echo "$kw" | tr '[:upper:]' '[:lower:]')
        [ -n "$kw" ] && keyword_list+=("$kw")
    done
 
    if [ -n "$DB_SERVICE" ] && [ "$svc" = "$DB_SERVICE" ] && [ -n "$DB_ENGINE" ]; then
        keyword_list+=("$DB_ENGINE")
        [ "$DB_ENGINE" = "mariadb" ] && keyword_list+=("mysql")
        [ "$DB_ENGINE" = "mysql" ] && keyword_list+=("mariadb")
    fi
 
    for d in "${all_dockerfiles[@]}"; do
        path_lower=$(echo "${d#$REPO_DIR/}" | tr '[:upper:]' '[:lower:]')
        score=0
        for kw in "${keyword_list[@]}"; do
            if [ "${#kw}" -lt 3 ] && [ "$kw" != "$svc_lower" ]; then
                continue
            fi
            case "$path_lower" in
                *"$kw"*) score=$((score + 1)) ;;
            esac
        done
        [ "$score" -gt 0 ] && scored_paths+=("$score|$d")
    done
 
    [ "${#scored_paths[@]}" -eq 0 ] && return 0
 
    for entry in "${scored_paths[@]}"; do
        local s="${entry%%|*}"
        [ "$s" -gt "$best_score" ] && best_score="$s"
    done
    for entry in "${scored_paths[@]}"; do
        local s="${entry%%|*}"
        [ "$s" -eq "$best_score" ] && best_paths+=("${entry#*|}")
    done
 
    if [ "${#best_paths[@]}" -eq 1 ]; then
        echo "${best_paths[0]}"
        return 0
    fi
 
    echo "❓ Varios Dockerfile podrían pertenecer al servicio '$svc' (imagen '$image'):" >&2
    for i in "${!best_paths[@]}"; do
        echo "    $((i+1))) ${best_paths[$i]#$REPO_DIR/}" >&2
    done
    read -r -p "👉 Selecciona cuál usar (0 = ninguno) [0]: " sel
    sel=${sel:-0}
    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#best_paths[@]}" ]; then
        echo "${best_paths[$((sel-1))]}"
    fi
    return 0
}
 
# Si un servicio no tiene Dockerfile propio ni imagen descargable, pero por
# su ROL es claramente una BD conocida o un phpMyAdmin, se ofrece la imagen
# oficial correspondiente para descargarla y volver a etiquetarla localmente
# con el nombre que pide el compose. Es el mismo truco que usaba la versión
# anterior del script (pull mariadb/phpmyadmin + docker tag a mi_p1_mysql /
# mi_p1_pma), aquí generalizado para cualquier proyecto en vez de un nombre
# fijo. Nunca se aplica sin que el usuario lo confirme.
guess_upstream_image_for_service() {
    local svc="$1" image="$2"
    local svc_lower image_lower all_text t
    local -a tokens=()
 
    svc_lower=$(echo "$svc" | tr '[:upper:]' '[:lower:]')
    image_lower=$(echo "${image%%:*}" | tr '[:upper:]' '[:lower:]')
 
    if [ -n "$DB_SERVICE" ] && [ "$svc" = "$DB_SERVICE" ] && [ -n "$DB_ENGINE" ]; then
        case "$DB_ENGINE" in
            mariadb)  echo "mariadb:latest";  return 0 ;;
            postgres) echo "postgres:latest"; return 0 ;;
            mysql)
                # El nombre de la imagen sugiere "mysql", pero eso es AMBIGUO:
                # la imagen oficial de MariaDB también acepta las variables
                # MYSQL_* por compatibilidad, así que un tag como "mi_p1_mysql"
                # no permite distinguir con certeza cuál de las dos es. Si el
                # compose usa variables MARIADB_* explícitas, es señal
                # inequívoca de MariaDB. Si no, se pregunta en vez de asumir.
                if printf '%s\n' "$SERVICE_BLOCK" | grep -qE '^[[:space:]]+MARIADB_'; then
                    echo "mariadb:latest"
                    return 0
                fi
                echo "❓ El servicio de BD usa la imagen '$image': el nombre sugiere MySQL, pero" >&2
                echo "    también podría ser MariaDB (son compatibles entre sí)." >&2
                echo "    1) MariaDB (recomendado: suele ser el caso más común en este tipo de proyecto)" >&2
                echo "    2) MySQL oficial" >&2
                local engine_choice
                read -r -p "👉 Selección [1]: " engine_choice
                engine_choice=${engine_choice:-1}
                if [ "$engine_choice" = "2" ]; then
                    echo "mysql:latest"
                else
                    echo "mariadb:latest"
                fi
                return 0
                ;;
        esac
    fi
 
    # Coincidencia por TOKEN completo (no subcadena) para evitar falsos
    # positivos como "pma" dentro de una palabra que no tiene relación.
    all_text="$svc_lower $image_lower"
    local IFS='/_.:- '
    read -r -a tokens <<< "$all_text"
    unset IFS
    for t in "${tokens[@]}"; do
        case "$t" in
            pma|phpmyadmin|myadmin) echo "phpmyadmin:latest"; return 0 ;;
        esac
    done
 
    return 0
}
 
preflight_check_images() {
    local svc image has_build opt dockerfile_path build_context resolved upstream_image confirm_tag confirm_only unico
    local -a all_dockerfiles=()
    mapfile -t all_dockerfiles < <(find "$REPO_DIR" -type f \( -iname 'Dockerfile' -o -iname 'Dockerfile.*' -o -iname '*.Dockerfile' \) ! -path '*/.git/*' 2>/dev/null | sort)
 
    for svc in "${SERVICES[@]}"; do
        has_build=$(printf '%s\n' "$COMPOSE_CONFIG" | awk -v s="  $svc:" '
            $0==s{inside=1;next} inside && /^  [A-Za-z0-9_.-]+:$/{exit}
            inside && /^ *build:/{print "1"; exit}')
        image=$(printf '%s\n' "$COMPOSE_CONFIG" | awk -v s="  $svc:" '
            $0==s{inside=1;next} inside && /^  [A-Za-z0-9_.-]+:$/{exit}
            inside && /^ *image:/{print $2; exit}')
 
        [ -n "$has_build" ] && continue   # se construye localmente, OK
        [ -z "$image" ] && continue        # sin image ni build, no aplica
 
        if docker image inspect "$image" >/dev/null 2>&1; then
            continue                       # ya existe localmente
        fi
        if docker manifest inspect "$image" >/dev/null 2>&1; then
            continue                       # se puede descargar de un registro
        fi
 
        # Ninguna de las anteriores aplicó: se prueban, en orden, tres
        # estrategias de recuperación automática antes de advertir/fallar.
        # Cada una pide confirmación cuando implica una suposición.
        resolved=0
 
        # 1) Un Dockerfile del repo emparejado por palabras clave.
        dockerfile_path=""
        if [ "${#all_dockerfiles[@]}" -gt 0 ]; then
            dockerfile_path=$(match_dockerfile_for_service "$svc" "$image")
        fi
        if [ -n "$dockerfile_path" ]; then
            build_context=$(dirname "$dockerfile_path")
            echo "🔨 El servicio '$svc' usa la imagen '$image' (no existe localmente ni en un registro),"
            echo "    pero se encontró un Dockerfile relacionado en '${dockerfile_path#$REPO_DIR/}'. Construyendo automáticamente..."
            if docker build -t "$image" -f "$dockerfile_path" "$build_context"; then
                echo "✅ Imagen '$image' construida correctamente para '$svc'."
                resolved=1
            else
                echo "❌ Falló la construcción automática de la imagen '$image' para '$svc'."
            fi
        fi
 
        # 2) ¿Es la BD detectada o "huele" a phpMyAdmin? Ofrecer la imagen
        #    oficial y re-etiquetarla localmente con el nombre pedido.
        if [ "$resolved" -eq 0 ]; then
            upstream_image=$(guess_upstream_image_for_service "$svc" "$image")
            if [ -n "$upstream_image" ]; then
                echo "🧭 El servicio '$svc' usa la imagen '$image' (sin 'build:' y no descargable directamente),"
                echo "    pero por su función parece corresponder a la imagen oficial '$upstream_image'."
                read -r -p "👉 ¿Descargarla y etiquetarla localmente como '$image'? [S/n]: " confirm_tag
                confirm_tag=${confirm_tag:-S}
                if [[ "$confirm_tag" =~ ^[SsYy] ]]; then
                    if docker pull "$upstream_image" && docker tag "$upstream_image" "$image"; then
                        echo "✅ '$image' etiquetada localmente a partir de '$upstream_image'."
                        resolved=1
                    else
                        echo "❌ No se pudo descargar/etiquetar '$upstream_image'."
                    fi
                fi
            fi
        fi
 
        # 3) Último recurso: si en TODO el repo hay un único Dockerfile
        #    (típico de un proyecto con un solo servicio de aplicación),
        #    ofrecerlo aunque su ruta no haya coincidido por palabras clave.
        if [ "$resolved" -eq 0 ] && [ "${#all_dockerfiles[@]}" -eq 1 ]; then
            unico="${all_dockerfiles[0]}"
            echo "❓ El servicio '$svc' usa la imagen '$image' y en el repositorio hay un único Dockerfile"
            echo "    (${unico#$REPO_DIR/}), aunque su ruta no coincide por palabras clave."
            read -r -p "👉 ¿Usarlo para construir '$image'? [s/N]: " confirm_only
            confirm_only=${confirm_only:-N}
            if [[ "$confirm_only" =~ ^[SsYy] ]]; then
                build_context=$(dirname "$unico")
                if docker build -t "$image" -f "$unico" "$build_context"; then
                    echo "✅ Imagen '$image' construida correctamente para '$svc'."
                    resolved=1
                else
                    echo "❌ Falló la construcción automática de la imagen '$image' para '$svc'."
                fi
            fi
        fi
 
        [ "$resolved" -eq 1 ] && continue
 
        echo "⚠️  El servicio '$svc' usa la imagen '$image', que no tiene 'build:',"
        echo "    no existe localmente y no se puede descargar de ningún registro."
        echo "    1) Cancelar el despliegue"
        echo "    2) Continuar de todas formas (probablemente fallará)"
        read -r -p "👉 Selección [1]: " opt
        opt=${opt:-1}
        if [ "$opt" != "2" ]; then
            echo "❌ Despliegue cancelado: prepara un 'build:' para '$svc' o publica la imagen '$image'."
            exit 1
        fi
    done
}
 
# ============================================================================== 
# 6. Levantar Compose
# ============================================================================== 
echo "================================================="
echo "🐳 5. Desplegando $SYSTEM_NAME como $NOMBRE_CARPETA..."
echo "================================================="
 
cd "$REPO_DIR"
export COMPOSE_PROJECT_NAME PREFIX_CONTENEDOR="$COMPOSE_PROJECT_NAME"
export PROJECT_NAME="$SYSTEM_NAME" PROJECT_SOURCE="$REPO_DIR"
export PUERTO_WEB PUERTO_PMA PUERTO_DB PUERTO_SSL
export DB_DATABASE="$DB_NAME" DB_USERNAME="$DB_APP_USER" DB_PASSWORD="$DB_APP_PASS"
 
preflight_check_images
 
# --project-directory mantiene los build contexts y rutas relativas del repositorio.
docker compose -f "$COMPOSE_FILE" --project-directory "$REPO_DIR" -p "$COMPOSE_PROJECT_NAME" down >/dev/null 2>&1 || true
docker compose -f "$COMPOSE_FILE" --project-directory "$REPO_DIR" -p "$COMPOSE_PROJECT_NAME" up -d --build --remove-orphans
 
# ============================================================================== 
# 7. Esperar BD y detectar contenedor
# ============================================================================== 
if [ -n "$DB_SERVICE" ] && [ "$DB_MODE" != "none" ]; then
    echo "================================================="
    echo "⏳ 6. Esperando a que '$DB_SERVICE' esté listo..."
    echo "================================================="
 
    DB_CONTAINER=""
    for intento in $(seq 1 60); do
        DB_CONTAINER=$(docker compose -f "$COMPOSE_FILE" --project-directory "$REPO_DIR" -p "$COMPOSE_PROJECT_NAME" ps -q "$DB_SERVICE" 2>/dev/null || true)
        if [ -n "$DB_CONTAINER" ]; then break; fi
        sleep 2
done
    [ -n "$DB_CONTAINER" ] || { echo "❌ No se encontró el contenedor de BD."; exit 1; }
 
    DB_READY=0
    for intento in $(seq 1 60); do
        DB_STATUS=$(docker inspect -f '{{.State.Status}}' "$DB_CONTAINER" 2>/dev/null || echo "desconocido")
        if [ "$DB_STATUS" != "running" ]; then
            echo ""
            echo "❌ El contenedor de BD no está en ejecución (estado: $DB_STATUS)."
            echo "    Últimas líneas de su log (la causa real del fallo suele estar aquí):"
            docker logs --tail 40 "$DB_CONTAINER" 2>&1 | sed 's/^/    /'
            echo "❌ La base de datos no llegó a estar disponible."
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
                if docker exec "$DB_CONTAINER" pg_isready >/dev/null 2>&1; then DB_READY=1; fi
                ;;
        esac
        [ "$DB_READY" -eq 1 ] && break
        echo "   ... BD aún no está lista ($intento/60)"
        sleep 2
    done
    [ "$DB_READY" -eq 1 ] || { echo "❌ La base de datos no llegó a estar disponible."; exit 1; }
    echo "✅ Base de datos lista."
 
    # ========================================================================== 
    # 8. Inicialización MySQL/MariaDB
    # ========================================================================== 
    if [[ "$DB_ENGINE" == "mysql" || "$DB_ENGINE" == "mariadb" ]]; then
        if docker exec "$DB_CONTAINER" mariadb --version >/dev/null 2>&1; then MYSQL_BIN="mariadb"; else MYSQL_BIN="mysql"; fi
 
        root_exec() {
            if [ -n "$ROOT_PASSWORD_DETECTED" ]; then
                docker exec "$DB_CONTAINER" "$MYSQL_BIN" -u root -p"$ROOT_PASSWORD_DETECTED" "$@"
            else
                docker exec "$DB_CONTAINER" "$MYSQL_BIN" -u root "$@"
            fi
        }
 
        if [ -n "$DB_NAME" ]; then
            DB_EXISTS=$(root_exec -N -B -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$(sql_escape "$DB_NAME")';" 2>/dev/null || true)
            if [ "$DB_EXISTS" != "$DB_NAME" ]; then
                echo "⚙️  Creando base de datos '$DB_NAME'..."
                root_exec -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;"
            fi
 
            if [ "$DB_MODE" = "2" ] && [ -n "$SQL_FILE" ]; then
                TABLE_COUNT=$(root_exec -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$(sql_escape "$DB_NAME")';" 2>/dev/null || echo 0)
                if [ "$TABLE_COUNT" = "0" ]; then
                    echo "📥 Importando $(basename "$SQL_FILE")..."
                    if [[ "$SQL_FILE" == *.gz ]]; then
                        if [ -n "$ROOT_PASSWORD_DETECTED" ]; then
                            gzip -dc "$SQL_FILE" | docker exec -i "$DB_CONTAINER" "$MYSQL_BIN" -u root -p"$ROOT_PASSWORD_DETECTED" "$DB_NAME"
                        else
                            gzip -dc "$SQL_FILE" | docker exec -i "$DB_CONTAINER" "$MYSQL_BIN" -u root "$DB_NAME"
                        fi
                    else
                        if [ -n "$ROOT_PASSWORD_DETECTED" ]; then
                            docker exec -i "$DB_CONTAINER" "$MYSQL_BIN" -u root -p"$ROOT_PASSWORD_DETECTED" "$DB_NAME" < "$SQL_FILE"
                        else
                            docker exec -i "$DB_CONTAINER" "$MYSQL_BIN" -u root "$DB_NAME" < "$SQL_FILE"
                        fi
                    fi
                    echo "✅ Esquema y datos iniciales importados."
                else
                    echo "✅ La BD ya contiene $TABLE_COUNT tabla(s). Se omite la importación para evitar duplicados."
                fi
            else
                echo "✅ BD configurada para comenzar vacía; no se importó ningún SQL."
            fi
 
            if [ -n "$DB_APP_USER" ] && [ "$CREATE_DB_USER" = "1" ]; then
                USER_ESC=$(sql_escape "$DB_APP_USER")
                PASS_ESC=$(sql_escape "$DB_APP_PASS")
                root_exec -e "CREATE USER IF NOT EXISTS '$USER_ESC'@'%' IDENTIFIED BY '$PASS_ESC'; ALTER USER '$USER_ESC'@'%' IDENTIFIED BY '$PASS_ESC';"
                case "$GRANT_MODE" in
                    1)
                        root_exec -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$USER_ESC'@'%'; FLUSH PRIVILEGES;"
                        echo "✅ Todos los permisos otorgados únicamente sobre '$DB_NAME'."
                        ;;
                    2)
                        root_exec -e "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP ON \`$DB_NAME\`.* TO '$USER_ESC'@'%'; FLUSH PRIVILEGES;"
                        echo "✅ Permisos básicos de aplicación otorgados."
                        ;;
                    3)
                        echo "ℹ️  Usuario creado sin permisos adicionales."
                        ;;
                esac
            fi
        fi
    elif [ "$DB_ENGINE" = "postgres" ]; then
        echo "ℹ️  PostgreSQL detectado. La selección de BD/SQL queda registrada, pero la creación/importación automática específica se reserva para una fase PostgreSQL dedicada."
    fi
fi
 
# ============================================================================== 
# 9. Reporte final
# ============================================================================== 
IP_SERVIDOR=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1); exit}') || true
if [ -z "$IP_SERVIDOR" ]; then
    IP_SERVIDOR=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -vE '^172\.|^127\.' | head -n 1 || true)
fi
[ -n "$IP_SERVIDOR" ] || IP_SERVIDOR="localhost"
 
echo ""
echo "================================================="
echo "🎉 ¡DESPLIEGUE EXITOSO!"
echo "================================================="
echo "📦 Sistema              : $SYSTEM_NAME"
echo "📁 Código fuente        : $REPO_DIR"
echo "🚀 Carpeta despliegue   : $CARPETA_DESTINO"
echo "🐳 Proyecto Docker      : $COMPOSE_PROJECT_NAME"
echo "🗄️  Servicio BD          : ${DB_SERVICE:-No detectado}"
echo "💾 Base de datos        : ${DB_NAME:-No gestionada}"
echo "👤 Usuario BD           : ${DB_APP_USER:-No creado}"
echo "🔐 Permisos             : ${GRANT_MODE:-none}"
echo "-------------------------------------------------"
echo "🌐 Puerto web sugerido  : $PUERTO_WEB"
echo "🔐 Puerto SSL sugerido  : $PUERTO_SSL"
echo "🗄️  Puerto BD sugerido  : $PUERTO_DB"
echo "🧰 Puerto PMA sugerido  : $PUERTO_PMA"
echo "-------------------------------------------------"
echo "📌 Comandos:"
echo "   cd '$REPO_DIR'"
echo "   docker compose -p '$COMPOSE_PROJECT_NAME' ps"
echo "   docker compose -p '$COMPOSE_PROJECT_NAME' logs -f"
echo "   docker compose -p '$COMPOSE_PROJECT_NAME' restart"
echo "   docker compose -p '$COMPOSE_PROJECT_NAME' down"
echo "   docker compose -p '$COMPOSE_PROJECT_NAME' up -d"
echo "================================================="

