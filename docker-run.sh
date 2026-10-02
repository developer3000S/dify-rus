#!/usr/bin/env bash
set -euo pipefail

# Build the Dify images from the local sources of this repository and start the
# full stack defined by docker/docker-compose.yaml.
#
# Every rebuild is done with --no-cache, so no layer from a previous build is
# ever reused. Old containers, volumes and images are removed first.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
DOCKER_DIR="$ROOT_DIR/docker"

# Tags must stay in sync with docker/docker-compose.yaml. That file is
# auto-generated (see docker/generate_docker_compose), so instead of editing it
# we build the local images straight onto the tags it already references.
DIFY_API_IMAGE="langgenius/dify-api:1.17.1"
DIFY_WEB_IMAGE="langgenius/dify-web:1.17.1"
DIFY_AGENT_BACKEND_IMAGE="langgenius/dify-agent-backend:1.17.1"
DIFY_LOCAL_SANDBOX_IMAGE="langgenius/dify-agent-local-sandbox:1.17.1"

log() {
  echo "[docker-run] $*"
}

fail() {
  echo "[docker-run] ERROR: $*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 0. Preconditions
# ---------------------------------------------------------------------------
command -v docker >/dev/null 2>&1 || fail "docker is not installed or not in PATH"
docker compose version >/dev/null 2>&1 || fail "docker compose v2 is required"
[ -f "$DOCKER_DIR/docker-compose.yaml" ] || fail "missing $DOCKER_DIR/docker-compose.yaml"

cd "$DOCKER_DIR"

# Preserve an existing .env, it holds local settings and is gitignored.
if [ ! -f .env ]; then
  log "Creating docker/.env from .env.example"
  cp .env.example .env
fi

EXPOSE_NGINX_PORT="$(grep -E '^EXPOSE_NGINX_PORT=' .env | tail -n 1 | cut -d= -f2- | tr -d '\r' || true)"
EXPOSE_NGINX_PORT="${EXPOSE_NGINX_PORT:-80}"

# ---------------------------------------------------------------------------
# 1. Remove the previous deployment: containers, volumes and old images.
#    --rmi all also drops the third-party images (postgres, redis, weaviate,
#    nginx, ...), they get pulled again in step 3.
# ---------------------------------------------------------------------------
log "Stopping and removing previous containers, volumes and images"
docker compose --env-file .env down -v --rmi all --remove-orphans 2>/dev/null || true

# Compose only knows about images it referenced, so force-remove the Dify ones
# as well in case a stale one was pulled from the registry before.
log "Removing old Dify images"
for image in \
  "$DIFY_API_IMAGE" \
  "$DIFY_WEB_IMAGE" \
  "$DIFY_AGENT_BACKEND_IMAGE" \
  "$DIFY_LOCAL_SANDBOX_IMAGE"; do
  docker image rm -f "$image" >/dev/null 2>&1 || true
done

# ---------------------------------------------------------------------------
# 2. Build every image that has a Dockerfile in this repository, from the local
#    sources only and without touching the build cache.
# ---------------------------------------------------------------------------
log "Building images from local sources (no cache)"

log "  -> $DIFY_API_IMAGE"
docker build --no-cache \
  -t "$DIFY_API_IMAGE" \
  -f "$ROOT_DIR/api/Dockerfile" \
  "$ROOT_DIR"

log "  -> $DIFY_WEB_IMAGE"
docker build --no-cache \
  -t "$DIFY_WEB_IMAGE" \
  -f "$ROOT_DIR/web/Dockerfile" \
  "$ROOT_DIR"

log "  -> $DIFY_AGENT_BACKEND_IMAGE"
docker build --no-cache \
  -t "$DIFY_AGENT_BACKEND_IMAGE" \
  -f "$ROOT_DIR/dify-agent/Dockerfile" \
  "$ROOT_DIR"

log "  -> $DIFY_LOCAL_SANDBOX_IMAGE"
docker build --no-cache \
  -t "$DIFY_LOCAL_SANDBOX_IMAGE" \
  -f "$ROOT_DIR/dify-agent-runtime/docker/Dockerfile" \
  "$ROOT_DIR/dify-agent-runtime"

# ---------------------------------------------------------------------------
# 3. Start the stack. Services without a local Dockerfile (sandbox,
#    plugin_daemon) and the third-party middleware are pulled by compose.
# ---------------------------------------------------------------------------
log "Starting the stack"
docker compose --env-file .env up -d

# ---------------------------------------------------------------------------
# 4. Wait until nginx answers, then report where the app is reachable.
# ---------------------------------------------------------------------------
log "Waiting for the web UI on http://localhost:${EXPOSE_NGINX_PORT}"
healthy=0
for _ in $(seq 1 90); do
  if curl -fsS "http://localhost:${EXPOSE_NGINX_PORT}" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 5
done

echo
if [ "$healthy" -eq 1 ]; then
  log "Dify is up and running."
else
  log "The web UI did not become reachable in time; the containers may still be starting."
fi
log "Web UI:        http://localhost:${EXPOSE_NGINX_PORT}"
log "Container logs: docker compose -f $DOCKER_DIR/docker-compose.yaml logs -f"
log "Stop the stack: docker compose -f $DOCKER_DIR/docker-compose.yaml down"
