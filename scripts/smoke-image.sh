#!/bin/sh
# Boot a TinyWebUI image and assert it does what a deployment needs.
#
#   ./scripts/smoke-image.sh tinywebui:local
#   ./scripts/smoke-image.sh ghcr.io/owner/tinywebui@sha256:...
#
# A green build only means the layers assembled. This starts the container and
# checks the things that make it a working deployment rather than an image:
#
#   1. /readyz answers 200 {"ready":true,...}  -- the process reached its database
#   2. / serves the page                        -- the app is really serving
#   3. /api/{chats,mcp,config} answer 401       -- the API is closed without a
#      session. A 200 here would mean auth came up open, which is the failure
#      worth catching before a digest is pinned in a deploy.
#   4. the image runs as a non-root user
#
# CI runs this against exactly the digest it publishes
# (.github/workflows/images.yml), so what is verified is what is pulled.
set -eu

ref="${1:-}"
if [ -z "$ref" ]; then
  echo "usage: $0 <image-ref>" >&2
  exit 2
fi

name="tinywebui-smoke-$$"
container_port=7777
ready_timeout="${SMOKE_TIMEOUT:-120}"

cleanup() {
  docker rm --force "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  if docker inspect "$name" >/dev/null 2>&1; then
    echo "--- container logs ---" >&2
    docker logs "$name" >&2 2>&1 || true
  fi
  exit 1
}

docker image inspect "$ref" >/dev/null 2>&1 \
  || fail "no local image named $ref (build it first: make build)"

# Non-root, checked on the image rather than the container so it holds for the
# Dockerfile's default too.
user=$(docker inspect --format '{{.Config.User}}' "$ref" 2>/dev/null || echo '')
case "$user" in
  '' | root | 0 | 0:*)
    fail "$ref runs as root (Config.User='$user'); every image here should set USER"
    ;;
esac

echo "booting $ref (user $user)"
# A random host port, so two smoke tests never collide.
docker run --detach --name "$name" --publish 127.0.0.1::"$container_port" "$ref" >/dev/null
hostport=$(docker port "$name" "$container_port/tcp" | head -n1 | sed 's/.*://')
[ -n "$hostport" ] || fail "no published port"
base="http://127.0.0.1:$hostport"

i=0
while [ "$i" -lt "$ready_timeout" ]; do
  if body=$(curl -fsS "$base/readyz" 2>/dev/null); then
    echo "readyz: $body"
    case "$body" in
      *'"ready":true'*) break ;;
    esac
  fi
  i=$((i + 1))
  sleep 1
done
[ "$i" -lt "$ready_timeout" ] || fail "/readyz did not report ready within ${ready_timeout}s"

code=$(curl -s -o /dev/null -w '%{http_code}' "$base/") || fail "GET / failed"
[ "$code" = 200 ] || fail "GET / returned $code, expected 200"
echo "GET / -> $code"

for path in /api/chats /api/mcp /api/config; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$base$path")
  [ "$code" = 401 ] || fail "GET $path returned $code, expected 401 (the API must be closed without a session)"
  echo "GET $path -> $code"
done

cleanup
trap - EXIT INT TERM
echo "ok: $ref"
