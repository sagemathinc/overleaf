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
