#!/usr/bin/env bash

set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"

REPO_ROOT="$DEFAULT_REPO_ROOT"
FRONTEND_PORT=9000
WEB_PORT=9001
PUBLIC_URL=""

SKIP_APT=0
SKIP_NPM_INSTALL=0
SKIP_BUILD=0

RUN_STATUS="success"
FAILED_STEP=""
CURRENT_STEP="initializing"

MONGODB_DISTRO="noble"
MONGODB_KEYRING="/usr/share/keyrings/mongodb-server-8.0.gpg"
MONGODB_LIST="/etc/apt/sources.list.d/mongodb-org-8.0.list"
MONGODB_REPO_BASE="https://repo.mongodb.org/apt/ubuntu"

APT_PACKAGES=(
  build-essential
  postgresql
  redis-server
  mongodb-org
  mongodb-mongosh
  nginx
  libmagic-dev
  imagemagick
  optipng
  qpdf
  jq
  parallel
  pkg-config
  python-is-python3
  python3-pygments
  inkscape
  poppler-utils
  latexmk
  texlive-latex-recommended
  texlive-latex-extra
  texlive-fonts-recommended
  texlive-pictures
  texlive-plain-generic
  texlive-xetex
  texlive-luatex
  texlive-bibtex-extra
  texlive-extra-utils
  texlive-lang-english
  biber
)

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [repo-root]

Bootstrap a native Overleaf checkout on Ubuntu-like systems.

Options:
  --repo-root PATH       Use a specific Overleaf checkout.
  --port PORT            Frontend port exposed by nginx. Default: 9000
  --web-port PORT        Internal web service port. Default: 9001
  --public-url URL       Public URL used by Overleaf. Default: http://127.0.0.1:<port>
  --skip-apt             Do not install or update system packages.
  --skip-npm-install     Do not run npm install steps.
  --skip-build           Do not build the web assets.
  --write-only           Only write native helper scripts and docs.
  --help                 Show this message.

Examples:
  $(basename "$0")
  $(basename "$0") --port 9100 --public-url http://127.0.0.1:9100
  $(basename "$0") --write-only /path/to/overleaf
EOF
}

log() {
  printf '[bootstrap] %s\n' "$*"
}

die() {
  printf '[bootstrap] error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
}

write_install_log() {
  local native_dir="$REPO_ROOT/native"
  local apt_status="completed"
  local npm_status="completed"
  local build_status="completed"
  local npm_engine=""
  local npm_version="unavailable"
  local node_version="unavailable"

  (( SKIP_APT )) && apt_status="skipped"
  (( SKIP_NPM_INSTALL )) && npm_status="skipped"
  (( SKIP_BUILD )) && build_status="skipped"

  if command -v node >/dev/null 2>&1; then
    node_version="$(node -v)"
    npm_engine="$(node -p "require('./package.json').engines?.npm || ''" 2>/dev/null || true)"
  fi
  if command -v npm >/dev/null 2>&1; then
    npm_version="$(npm -v)"
  fi

  mkdir -p "$native_dir"
  {
    cat <<EOF
# Native Overleaf Install Log

Date: $(date +%F)
Status: ${RUN_STATUS}
Repo root: \`${REPO_ROOT}\`

EOF
    if [[ -n "$FAILED_STEP" ]]; then
      cat <<EOF
Failed step: \`${FAILED_STEP}\`

EOF
    fi
    cat <<EOF
## Options

- Frontend port: \`${FRONTEND_PORT}\`
- Internal web port: \`${WEB_PORT}\`
- Public URL: \`${PUBLIC_URL}\`
- Apt stage: \`${apt_status}\`
- npm install stage: \`${npm_status}\`
- Web build stage: \`${build_status}\`

## Tooling

- Node.js: \`${node_version}\`
- npm: \`${npm_version}\`
- Repo npm engine: \`${npm_engine:-unspecified}\`

## System packages

\`\`\`text
EOF
    printf '%s\n' "${APT_PACKAGES[@]}"
    cat <<EOF
\`\`\`

## MongoDB apt repository

\`\`\`text
deb [ arch=$(dpkg --print-architecture 2>/dev/null || echo amd64) signed-by=${MONGODB_KEYRING} ] ${MONGODB_REPO_BASE} ${MONGODB_DISTRO}/mongodb-org/8.0 multiverse
\`\`\`

## Generated files

- \`native/overleaf.env\`
- \`native/start-overleaf.sh\`
- \`native/stop-overleaf.sh\`

## Runtime topology

- Front proxy: \`nginx\` on \`${FRONTEND_PORT}\`
- Web backend: \`${WEB_PORT}\`
- Real-time: \`3026\`, exposed through \`/socket.io\`
- CLSI file server: \`8080\`
- history-v1: \`3100\`

## Build commands

\`\`\`bash
CYPRESS_INSTALL_BINARY=0 npm install --omit=dev
CYPRESS_INSTALL_BINARY=0 npm install --include=dev -w services/web
npm run lezer-latex:generate -w services/web
make -C services/web create_module_Makefiles
npm run precompile-pug -w services/web
OVERLEAF_CONFIG=${REPO_ROOT}/services/web/config/settings.webpack.js npm run webpack:production -w services/web
\`\`\`

## Usage

\`\`\`bash
cd ${REPO_ROOT}
./native/start-overleaf.sh
./native/stop-overleaf.sh
\`\`\`
EOF
  } >"$native_dir/INSTALL_LOG.md"
}

on_error() {
  local exit_code=$?
  RUN_STATUS="failed"
  FAILED_STEP="$CURRENT_STEP"
  write_install_log
  printf '[bootstrap] failed during step: %s\n' "$CURRENT_STEP" >&2
  exit "$exit_code"
}

trap on_error ERR

parse_args() {
  local positional_repo_root=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo-root)
        [[ $# -ge 2 ]] || die "--repo-root requires a value"
        REPO_ROOT="$2"
        shift 2
        ;;
      --port)
        [[ $# -ge 2 ]] || die "--port requires a value"
        FRONTEND_PORT="$2"
        shift 2
        ;;
      --web-port)
        [[ $# -ge 2 ]] || die "--web-port requires a value"
        WEB_PORT="$2"
        shift 2
        ;;
      --public-url)
        [[ $# -ge 2 ]] || die "--public-url requires a value"
        PUBLIC_URL="$2"
        shift 2
        ;;
      --skip-apt)
        SKIP_APT=1
        shift
        ;;
      --skip-npm-install)
        SKIP_NPM_INSTALL=1
        shift
        ;;
      --skip-build)
        SKIP_BUILD=1
        shift
        ;;
      --write-only)
        SKIP_APT=1
        SKIP_NPM_INSTALL=1
        SKIP_BUILD=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --*)
        die "unknown option: $1"
        ;;
      *)
        if [[ -n "$positional_repo_root" ]]; then
          die "unexpected extra argument: $1"
        fi
        positional_repo_root="$1"
        shift
        ;;
    esac
  done

  if [[ -n "$positional_repo_root" ]]; then
    REPO_ROOT="$positional_repo_root"
  fi
}

normalize_inputs() {
  [[ -d "$REPO_ROOT" ]] || die "repo root does not exist: $REPO_ROOT"
  REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
  [[ "$FRONTEND_PORT" =~ ^[0-9]+$ ]] || die "invalid --port value: $FRONTEND_PORT"
  [[ "$WEB_PORT" =~ ^[0-9]+$ ]] || die "invalid --web-port value: $WEB_PORT"
  if [[ -z "$PUBLIC_URL" ]]; then
    PUBLIC_URL="http://127.0.0.1:${FRONTEND_PORT}"
  fi
}

validate_checkout() {
  CURRENT_STEP="validating checkout"
  [[ -f "$REPO_ROOT/package.json" ]] || die "missing package.json under $REPO_ROOT"
  [[ -d "$REPO_ROOT/services/web" ]] || die "missing services/web under $REPO_ROOT"
  [[ -d "$REPO_ROOT/services/real-time" ]] || die "missing services/real-time under $REPO_ROOT"
  [[ -d "$REPO_ROOT/services/clsi" ]] || die "missing services/clsi under $REPO_ROOT"
  [[ -d "$REPO_ROOT/services/history-v1" ]] || die "missing services/history-v1 under $REPO_ROOT"
}

ensure_mongodb_repo() {
  CURRENT_STEP="configuring mongodb apt repository"
  local arch repo_line
  arch="$(dpkg --print-architecture)"
  repo_line="deb [ arch=${arch} signed-by=${MONGODB_KEYRING} ] ${MONGODB_REPO_BASE} ${MONGODB_DISTRO}/mongodb-org/8.0 multiverse"

  if [[ -f "$MONGODB_LIST" ]] && grep -Fqx "$repo_line" "$MONGODB_LIST"; then
    return
  fi

  require_command sudo
  sudo install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://pgp.mongodb.com/server-8.0.asc \
    | sudo gpg --dearmor -o "$MONGODB_KEYRING"
  printf '%s\n' "$repo_line" | sudo tee "$MONGODB_LIST" >/dev/null
}

install_system_packages() {
  (( SKIP_APT )) && return

  CURRENT_STEP="installing apt prerequisites"
  require_command sudo
  sudo env DEBIAN_FRONTEND=noninteractive apt-get update
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    gnupg

  ensure_mongodb_repo

  CURRENT_STEP="installing apt packages"
  sudo env DEBIAN_FRONTEND=noninteractive apt-get update
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_PACKAGES[@]}"
}

check_toolchain() {
  CURRENT_STEP="checking toolchain"
  require_command bash
  require_command node
  require_command npm
  require_command make
  require_command curl

  if (( ! SKIP_APT )); then
    require_command psql
    require_command redis-server
    require_command mongod
    require_command mongosh
    require_command nginx
  fi
}

warn_on_npm_engine_mismatch() {
  CURRENT_STEP="checking npm version"
  local expected actual
  expected="$(cd "$REPO_ROOT" && node -p "require('./package.json').engines?.npm || ''" 2>/dev/null || true)"
  actual="$(npm -v)"
  if [[ -n "$expected" ]] && [[ "$expected" != "$actual" ]]; then
    log "warning: repo declares npm ${expected}, current npm is ${actual}"
  fi
}

write_overleaf_env() {
  local env_file="$REPO_ROOT/native/overleaf.env"
  local escaped_public_url
  escaped_public_url="${PUBLIC_URL//&/\\&}"

  cat >"$env_file" <<'EOF'
#!/usr/bin/env bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export NODE_ENV=production

export APP_NAME="Overleaf Community Edition"
export OVERLEAF_APP_NAME="Overleaf Community Edition"
export ADMIN_PRIVILEGE_AVAILABLE=true
export OVERLEAF_ALLOW_PUBLIC_ACCESS=true
export EMAIL_CONFIRMATION_DISABLED=true
export ENABLE_CONVERSIONS=true
export ENABLED_LINKED_FILE_TYPES="project_file,project_output_file"
export BCRYPT_ROUNDS=1

export WEB_API_USER=overleaf
export WEB_API_PASSWORD=password
export SESSION_SECRET="overleaf-local-session-secret"
export OT_JWT_AUTH_KEY="overleaf-local-jwt-secret"
export OT_JWT_AUTH_ALG=HS256
export STAGING_PASSWORD=password

export FRONTEND_PORT="${FRONTEND_PORT:-__FRONTEND_PORT__}"
export WEB_PORT="${WEB_PORT:-__WEB_PORT__}"
export WEB_API_PORT="${WEB_API_PORT:-$WEB_PORT}"

export PUBLIC_URL="${PUBLIC_URL:-__PUBLIC_URL__}"
export ADMIN_URL="${ADMIN_URL:-$PUBLIC_URL}"
export DOWNLOAD_HOST="${DOWNLOAD_HOST:-http://127.0.0.1:8080}"

export CHAT_HOST=127.0.0.1
export CLSI_HOST=127.0.0.1
export CONTACTS_HOST=127.0.0.1
export DOCSTORE_HOST=127.0.0.1
export DOCUMENT_UPDATER_HOST=127.0.0.1
export DOCUPDATER_HOST=127.0.0.1
export FILESTORE_HOST=127.0.0.1
export HISTORY_V1_HOST=127.0.0.1
export V1_HISTORY_HOST=127.0.0.1
export NOTIFICATIONS_HOST=127.0.0.1
export PROJECT_HISTORY_HOST=127.0.0.1
export REALTIME_HOST=127.0.0.1
export WEB_HOST=127.0.0.1
export WEB_API_HOST=127.0.0.1
export WEBPACK_HOST=127.0.0.1

export MONGO_URL="mongodb://127.0.0.1:27017/sharelatex?replicaSet=overleaf"
export MONGO_CONNECTION_STRING="$MONGO_URL"
export OVERLEAF_MONGO_URL="$MONGO_URL"
export MONGO_HOST=127.0.0.1

export REDIS_HOST=127.0.0.1
export REDIS_PORT=6379
export QUEUES_REDIS_HOST=127.0.0.1
export ANALYTICS_QUEUES_REDIS_HOST=127.0.0.1
export PUBSUB_REDIS_HOST=127.0.0.1
export RATELIMITER_REDIS_HOST=127.0.0.1
export GCLOUD_2_REDIS_HOST=127.0.0.1
export HISTORY_REDIS_HOST=127.0.0.1
export DOC_UPDATER_REDIS_HOST=127.0.0.1
export REAL_TIME_REDIS_HOST=127.0.0.1
export SESSIONS_REDIS_HOST=127.0.0.1
export LOCK_REDIS_HOST=127.0.0.1

export HISTORY_CONNECTION_STRING="postgres://overleaf:overleaf@127.0.0.1:5432/overleaf_history_v1"
export HISTORY_FOLLOWER_CONNECTION_STRING="$HISTORY_CONNECTION_STRING"
export POSTGRES_HOST=127.0.0.1

export PERSISTOR_BACKEND=fs
export OVERLEAF_EDITOR_BLOBS_BUCKET="$ROOT_DIR/.native-run/history/blobs"
export OVERLEAF_EDITOR_PROJECT_BLOBS_BUCKET="$ROOT_DIR/.native-run/history/project-blobs"
export OVERLEAF_EDITOR_CHUNKS_BUCKET="$ROOT_DIR/.native-run/history/chunks"
export OVERLEAF_EDITOR_ZIPS_BUCKET="$ROOT_DIR/.native-run/history/zips"
EOF

  sed -i \
    -e "s|__FRONTEND_PORT__|$FRONTEND_PORT|g" \
    -e "s|__WEB_PORT__|$WEB_PORT|g" \
    -e "s|__PUBLIC_URL__|$escaped_public_url|g" \
    "$env_file"
}

write_start_script() {
  cat >"$REPO_ROOT/native/start-overleaf.sh" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/native/overleaf.env"

RUN_DIR="$ROOT_DIR/.native-run"
LOG_DIR="$RUN_DIR/logs"
PID_DIR="$RUN_DIR/pids"
NGINX_DIR="$RUN_DIR/nginx"

mkdir -p \
  "$LOG_DIR" \
  "$PID_DIR" \
  "$NGINX_DIR/logs" \
  "$NGINX_DIR/temp/client_body" \
  "$NGINX_DIR/temp/proxy" \
  "$NGINX_DIR/temp/fastcgi" \
  "$NGINX_DIR/temp/uwsgi" \
  "$NGINX_DIR/temp/scgi" \
  "$RUN_DIR/mongo" \
  "$RUN_DIR/redis" \
  "$RUN_DIR/history/blobs" \
  "$RUN_DIR/history/project-blobs" \
  "$RUN_DIR/history/chunks" \
  "$RUN_DIR/history/zips" \
  "$ROOT_DIR/services/web/data/dumpFolder" \
  "$ROOT_DIR/services/web/data/uploads" \
  "$ROOT_DIR/services/clsi/compiles" \
  "$ROOT_DIR/services/clsi/output" \
  "$ROOT_DIR/services/clsi/cache" \
  "$ROOT_DIR/services/clsi/uploads" \
  "$ROOT_DIR/services/filestore/uploads" \
  "$ROOT_DIR/services/filestore/template_files" \
  "$ROOT_DIR/services/filestore/public_files"

start_postgres() {
  sudo pg_ctlcluster 18 main start >/dev/null 2>&1 || true
  sudo -u postgres psql -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'overleaf') THEN
    CREATE ROLE overleaf LOGIN PASSWORD 'overleaf' CREATEDB;
  ELSE
    ALTER ROLE overleaf WITH LOGIN PASSWORD 'overleaf' CREATEDB;
  END IF;
END $$;
SELECT 'CREATE DATABASE overleaf_history_v1 OWNER overleaf'
WHERE NOT EXISTS (
  SELECT FROM pg_database WHERE datname = 'overleaf_history_v1'
) \gexec
SQL
}

start_mongo() {
  if ! pgrep -x mongod >/dev/null 2>&1; then
    mongod \
      --dbpath "$RUN_DIR/mongo" \
      --bind_ip 127.0.0.1 \
      --port 27017 \
      --replSet overleaf \
      --logpath "$LOG_DIR/mongod.log" \
      --fork
  fi

  mongosh --quiet --eval \
    "try { rs.status().ok } catch (e) { rs.initiate({_id:'overleaf',members:[{_id:0,host:'127.0.0.1:27017'}]}) }" \
    >/dev/null
}

start_redis() {
  if ! pgrep -x redis-server >/dev/null 2>&1; then
    redis-server \
      --bind 127.0.0.1 \
      --port 6379 \
      --dir "$RUN_DIR/redis" \
      --pidfile "$PID_DIR/redis.pid" \
      --logfile "$LOG_DIR/redis.log" \
      --daemonize yes
  fi
}

write_nginx_config() {
  cat >"$NGINX_DIR/nginx.conf" <<EOF_NGINX
daemon off;
worker_processes 1;
pid logs/nginx.pid;

events {
  worker_connections 1024;
}

http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;

  access_log logs/access.log;
  error_log logs/error.log;

  sendfile on;
  tcp_nopush on;
  tcp_nodelay on;
  keepalive_timeout 65;
  gzip on;
  gzip_proxied any;
  client_max_body_size 50m;

  client_body_temp_path temp/client_body;
  proxy_temp_path temp/proxy;
  fastcgi_temp_path temp/fastcgi;
  uwsgi_temp_path temp/uwsgi;
  scgi_temp_path temp/scgi;

  server {
    listen ${FRONTEND_PORT};
    server_name _;
    root ${ROOT_DIR}/services/web/public;

    location /metrics {
      internal;
    }

    location / {
      proxy_pass http://127.0.0.1:${WEB_PORT};
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection "upgrade";
      proxy_set_header Host \$host;
      proxy_set_header X-Forwarded-Host \$host;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_read_timeout 10m;
      proxy_send_timeout 10m;
    }

    location /socket.io {
      proxy_pass http://127.0.0.1:3026;
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection "upgrade";
      proxy_set_header Host \$host;
      proxy_set_header X-Forwarded-Host \$host;
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_read_timeout 10m;
      proxy_send_timeout 10m;
    }

    location /stylesheets {
      expires 1y;
    }

    location /minjs {
      expires 1y;
    }

    location /img {
      expires 1y;
    }

    location ~ ^/project/([0-9a-f]+)/user/([0-9a-f]+)/build/([0-9a-f-]+)/output/output\.([a-z.]+)$ {
      proxy_pass http://127.0.0.1:8080;
      proxy_http_version 1.1;
    }

    location ~ ^/project/([0-9a-f]+)/build/([0-9a-f-]+)/output/output\.([a-z.]+)$ {
      proxy_pass http://127.0.0.1:8080;
      proxy_http_version 1.1;
    }

    location ~ ^/project/([0-9a-f]+)/user/([0-9a-f]+)/content/([0-9a-f-]+/[0-9a-f]+)$ {
      proxy_pass http://127.0.0.1:8080;
      proxy_http_version 1.1;
    }

    location ~ ^/project/([0-9a-f]+)/content/([0-9a-f-]+/[0-9a-f]+)$ {
      proxy_pass http://127.0.0.1:8080;
      proxy_http_version 1.1;
    }

    location ~* ^/metrics/?$ {
      return 404 "Not found";
    }

    location ~* ^/health_check {
      return 404 "Not found";
    }
  }

  server {
    add_header X-Served-By clsi-nginx always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Download-Options noopen always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-XSS-Protection "1; mode=block" always;

    listen 8080;
    server_name clsi-nginx;
    server_tokens off;
    access_log off;
    disable_symlinks off;

    gzip on;
    gzip_types text/plain;
    gzip_proxied any;
    types {
      text/plain log blg aux stdout stderr;
      application/pdf pdf;
    }

    location ~ ^/project/([0-9a-f]+)/user/([0-9a-f]+)/build/([0-9a-f-]+)/output/(.+)$ {
      rewrite ^/project/([0-9a-f]+)/user/([0-9a-f]+)/build/([0-9a-f-]+)/output/(.+)$ /\$4 break;
      root ${ROOT_DIR}/services/clsi/output/\$1-\$2/generated-files/\$3/;
    }

    location ~ ^/project/([0-9a-f]+)/build/([0-9a-f-]+)/output/(.+)$ {
      rewrite ^/project/([0-9a-f]+)/build/([0-9a-f-]+)/output/(.+)$ /\$3 break;
      root ${ROOT_DIR}/services/clsi/output/\$1/generated-files/\$2/;
    }

    location ~ ^/project/([0-9a-f]+)/user/([0-9a-f]+)/content/([0-9a-f-]+/[0-9a-f]+)$ {
      expires 1d;
      alias ${ROOT_DIR}/services/clsi/output/\$1-\$2/content/\$3;
    }

    location ~ ^/project/([0-9a-f]+)/content/([0-9a-f-]+/[0-9a-f]+)$ {
      expires 1d;
      alias ${ROOT_DIR}/services/clsi/output/\$1/content/\$2;
    }

    location / {
      return 404;
    }
  }
}
EOF_NGINX
}

run_history_migrations() {
  (
    cd "$ROOT_DIR/services/history-v1"
    NODE_CONFIG_DIR="$PWD/config" npx knex migrate:latest
  ) >>"$LOG_DIR/history-v1-migrate.log" 2>&1
}

start_service() {
  local name="$1"
  local workdir="$2"
  local cmd="$3"
  local pidfile="$PID_DIR/$name.pid"
  local logfile="$LOG_DIR/$name.log"

  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" >/dev/null 2>&1; then
    echo "$name already running"
    return
  fi

  (
    cd "$workdir"
    nohup bash -lc "$cmd" >>"$logfile" 2>&1 &
    echo $! >"$pidfile"
  )
}

wait_for_http() {
  local name="$1"
  local url="$2"

  for _ in $(seq 1 60); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      echo "$name ready at $url"
      return 0
    fi
    sleep 1
  done

  echo "$name failed to come up: $url" >&2
  return 1
}

start_postgres
start_mongo
start_redis
write_nginx_config
run_history_migrations

start_service chat "$ROOT_DIR/services/chat" "exec node app.js"
start_service contacts "$ROOT_DIR/services/contacts" "exec node app.js"
start_service docstore "$ROOT_DIR/services/docstore" "exec node app.js"
start_service document-updater "$ROOT_DIR/services/document-updater" "exec node app.js"
start_service filestore "$ROOT_DIR/services/filestore" "exec node app.js"
start_service notifications "$ROOT_DIR/services/notifications" "exec node app.ts"
start_service project-history "$ROOT_DIR/services/project-history" "exec node app.js"
start_service real-time "$ROOT_DIR/services/real-time" "exec node app.js"
start_service history-v1 "$ROOT_DIR/services/history-v1" "exec env PORT=3100 NODE_CONFIG_DIR=$ROOT_DIR/services/history-v1/config node app.js"
start_service clsi "$ROOT_DIR/services/clsi" "exec node app.js"
start_service web "$ROOT_DIR/services/web" "exec env LISTEN_ADDRESS=0.0.0.0 WEB_PORT=$WEB_PORT node app.mjs"
start_service nginx "$ROOT_DIR" "exec nginx -c $NGINX_DIR/nginx.conf -p $NGINX_DIR"

wait_for_http history-v1 "http://127.0.0.1:3100/status"
wait_for_http web "http://127.0.0.1:${WEB_PORT}/status"
wait_for_http frontend "http://127.0.0.1:${FRONTEND_PORT}/status"
wait_for_http socketio "http://127.0.0.1:${FRONTEND_PORT}/socket.io/socket.io.js"
wait_for_http launchpad "http://127.0.0.1:${FRONTEND_PORT}/launchpad"

echo
echo "Overleaf is running on http://127.0.0.1:${FRONTEND_PORT}"
echo "Logs: $LOG_DIR"
EOF
}

write_stop_script() {
  cat >"$REPO_ROOT/native/stop-overleaf.sh" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PID_DIR="$ROOT_DIR/.native-run/pids"

stop_pidfile() {
  local pidfile="$1"
  if [[ -f "$pidfile" ]]; then
    local pid
    pid="$(cat "$pidfile")"
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
      wait "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  fi
}

for name in \
  nginx \
  web \
  clsi \
  history-v1 \
  real-time \
  project-history \
  notifications \
  filestore \
  document-updater \
  docstore \
  contacts \
  chat
do
  stop_pidfile "$PID_DIR/$name.pid"
done

if [[ -f "$PID_DIR/redis.pid" ]]; then
  redis-cli shutdown >/dev/null 2>&1 || true
  rm -f "$PID_DIR/redis.pid"
fi

if pgrep -x mongod >/dev/null 2>&1; then
  mongosh --quiet --eval "db.adminCommand({ shutdown: 1, force: true })" >/dev/null 2>&1 || true
fi

echo "Stopped native Overleaf services."
EOF
}

write_native_files() {
  CURRENT_STEP="writing native helper scripts"
  mkdir -p "$REPO_ROOT/native"
  write_overleaf_env
  write_start_script
  write_stop_script
  chmod +x \
    "$REPO_ROOT/native/bootstrap-overleaf.sh" \
    "$REPO_ROOT/native/start-overleaf.sh" \
    "$REPO_ROOT/native/stop-overleaf.sh"
}

install_node_dependencies() {
  (( SKIP_NPM_INSTALL )) && return
  CURRENT_STEP="installing npm workspace dependencies"
  (
    cd "$REPO_ROOT"
    CYPRESS_INSTALL_BINARY=0 npm install --omit=dev
    CYPRESS_INSTALL_BINARY=0 npm install --include=dev -w services/web
  )
}

build_web_assets() {
  (( SKIP_BUILD )) && return
  CURRENT_STEP="building web assets"
  (
    cd "$REPO_ROOT"
    npm run lezer-latex:generate -w services/web
    make -C services/web create_module_Makefiles
    npm run precompile-pug -w services/web
    OVERLEAF_CONFIG="$REPO_ROOT/services/web/config/settings.webpack.js" \
      npm run webpack:production -w services/web
  )
}

main() {
  parse_args "$@"
  normalize_inputs
  validate_checkout

  cd "$REPO_ROOT"
  write_native_files
  install_system_packages
  check_toolchain
  warn_on_npm_engine_mismatch
  install_node_dependencies
  build_web_assets

  CURRENT_STEP="writing install log"
  write_install_log

  log "bootstrap complete"
  log "repo root: $REPO_ROOT"
  log "start with: cd $REPO_ROOT && ./native/start-overleaf.sh"
}

main "$@"
