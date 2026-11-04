# Container images

Three images, all built from this repository: two production ones (upstream's)
and a development one (this fork's), plus the CI that publishes the production
ones.

| Build | Dockerfile | What it is | Size |
| --- | --- | --- | --- |
| `make build-hybrid` | `Dockerfile` | **the default.** BM25 + local ONNX embeddings; the model is fetched once at build time and baked in, so the running container downloads nothing | ~650 MB |
| `make build-lexical` | `Dockerfile.lexical` | the small one. SQLite FTS5 BM25 only, no embedding runtime | ~215 MB |
| `make build-dev` | `Dockerfile.dev` | development: devDependencies, `uv`, full source, no model | ~755 MB |

All three run as the unprivileged `node` user, keep their state in `/data`, and
carry the same `HEALTHCHECK` — `GET /readyz`, which only answers 200 when the
database is actually open.

```sh
make            # list the targets
make build      # all three, tagged tinywebui:local, :local-lexical, :dev
make smoke      # boot tinywebui:local and probe it
make dev        # the development loop on http://127.0.0.1:7777
```

## The development loop

`make dev` runs `docker compose -f compose.dev.yaml up --build`:

```
./src  ./bin      -> /app/src, /app/bin     (read-only)  watched; the process restarts on a change
./public          -> /app/public            (read-only)  read per request, no restart needed
./test ./evals    -> /app/test, /app/evals  (read-only)  so the suite runs in the container
tinywebui-dev-data -> /data                 (volume)     accounts, chats, config, secrets, mcp.json
./models          -> /data/models           (bind)       optional embedding bundle
```

Edit a file under `src/`, and `node --watch-path` restarts the server; edit
`public/` and a reload shows it. `config.json` and `mcp.json` already hot-reload
inside the process, so they need neither. `node_modules` and `package.json`
stay in the image — changing a dependency is the one thing that needs
`--build`:

```sh
make dev-test        # npm test, in the dev image (the full 425-test suite)
make dev-typecheck   # tsc -p .
make dev-shell       # sh, inside the running container
make dev-doctor      # tinywebui doctor, against the dev instance
make dev-down        # stop; the named volume survives until `down -v`
```

The host port is `TINYWEBUI_DEV_PORT` (default 7777):
`TINYWEBUI_DEV_PORT=8080 make dev`.

### Hybrid search in the dev loop

The dev image has no embedding model, so search is BM25. To run the hybrid path
locally, pull a bundle on the host into `./models` (which is mounted at
`/data/models`, the default location beside the config) and switch the mode:

```sh
mkdir -p models                                   # `make models` does this
docker compose -f compose.dev.yaml run --rm tinywebui \
  node bin/tinywebui.ts models pull fast          # ~90 MB, into ./models
TINYWEBUI_RETRIEVAL_MODE=hybrid make dev
```

Always `mkdir -p models` first, or Docker creates it as root and the host user
cannot write to it afterwards.

### The default MCP servers need network

`uv` is installed in the dev image, so a fresh `/data` gets the upstream default
`mcp.json`: TinySearch and TinyContext started with
`uvx --from 'tinysuite-search[server]>=0.6.8'`. The first start therefore needs
PyPI access and downloads ~60 packages. Note the `>=` floor in that spec — an
unpinned version resolved at runtime. The production images ship neither `uv`
nor `npm` deliberately (see the note in `README.md`): connect MCP servers over
HTTP, or build a custom image with the executables in it. If you want the
defaults out of the picture entirely, write your own `mcp.json` into `/data`:

```sh
docker compose -f compose.dev.yaml exec tinywebui sh -c 'echo "{\"mcpServers\":{}}" > /data/mcp.json'
```

## What CI publishes

`.github/workflows/images.yml`, on this fork:

| Trigger | What it does |
| --- | --- |
| pull request | builds `linux/amd64` into the runner, pushes nothing, boots it and probes it |
| push to `main` | pushes `linux/amd64` + `linux/arm64` as `main` and `sha-<rev>` |
| `v*` tag | the same, plus `<version>`, `<major>.<minor>` and `latest` |

Everything lands in GHCR as `ghcr.io/matuszelenak/tinywebui`, with the lexical
builds suffixed: `:latest` is hybrid, `:latest-lexical` is lexical. Each push
carries a `max`-mode provenance attestation and an SBOM, signed with the
workflow's OIDC identity, so any digest traces back to a commit and a run.

**Before the first deploy:** a new GHCR package is private. Either pull with a
token, or make it public once under *Packages → tinywebui → Package settings →
Change visibility*. The arm64 leg builds under emulation and is the slow part of
a cold run.

Whether the pushed artifact is the thing that works is checked, not assumed: the
workflow boots the **digest it just pushed** and runs `scripts/smoke-image.sh`
against it — `/readyz` reports `{"ready":true}`, `/` serves the page, and
`/api/{chats,mcp,config}` answer 401 without a session. A 200 on any of those
would mean the app came up with its API open, which is exactly the failure worth
catching before a digest is pinned somewhere.

## Deploying a published image

Pin the digest, not the tag — tags move, digests do not:

```sh
docker pull ghcr.io/matuszelenak/tinywebui@sha256:...
```

State lives in `/data` (accounts, chats, `tinywebui.config.json`,
`tinywebui.secrets.json`, `tinywebui.db`, `mcp.json`, and any embedding bundle
under `models/`). The container runs as uid/gid 1000, so a bind-mounted data
directory has to be owned by that user — under a rootful podman with
`UserNS=auto`, that is the mapped host uid, not 1000:

```sh
podman unshare chown -R 1000:1000 /var/lib/services/tinywebui
```

Mount it with `:idmap` (or `:Z` for SELinux) as usual, so on-disk ownership
matches what the container sees. `authMode` is `multiuser` by default, which is
what makes `--host 0.0.0.0` safe; `local` refuses to bind off loopback by
design. Behind a reverse proxy with local accounts, set `trustedProxyCidrs` to
the proxy and have it forward `X-Forwarded-Proto: https`, or the session cookie
is issued without `Secure`. With `authMode: 'trusted-header'` the app believes
`x-tinysuite-user-id` (configurable) from any peer in `trustedProxyCidrs` — so
the proxy has to **strip** those headers from client requests, or anyone can
name themselves.
