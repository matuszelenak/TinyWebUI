# Container images and the development loop. `make` with no target lists these.
#
#   make dev            # source bind-mounted, restarts on change, :7777
#   make dev-test       # the test suite, in the same image the loop uses
#   make build          # all three images, tagged local
#   make smoke          # boot a build and check it actually serves
#
# The production stack is docker-compose.yml; CI builds and publishes the images
# (.github/workflows/images.yml). See docs/docker.md.

IMAGE ?= tinywebui
TAG ?= local
COMPOSE_DEV := docker compose -f compose.dev.yaml

.DEFAULT_GOAL := help
.PHONY: help models dev dev-bg dev-down dev-logs dev-shell dev-test dev-typecheck dev-doctor \
        build build-hybrid build-lexical build-dev smoke smoke-lexical prod-up prod-down clean

help: ## list the targets
	@grep -hE '^[a-z][a-z-]*:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1m%-16s\033[0m %s\n", $$1, $$2}'

models: ## create ./models, so a pulled embedding bundle is owned by you and not root
	@mkdir -p models

# ---- development --------------------------------------------------------------

dev: models ## run the dev stack in the foreground (hot reload) on 127.0.0.1:7777
	$(COMPOSE_DEV) up --build

dev-bg: models ## same, detached
	$(COMPOSE_DEV) up --build --detach

dev-down: ## stop the dev stack (the data volume is kept; -v is the only thing that drops it)
	$(COMPOSE_DEV) down

dev-logs: ## follow the dev container's log
	$(COMPOSE_DEV) logs --follow tinywebui

dev-shell: ## a shell in the dev container
	$(COMPOSE_DEV) exec tinywebui sh

dev-test: ## run the test suite in the dev image (as on the host)
	$(COMPOSE_DEV) run --rm tinywebui npm test

dev-typecheck: ## typecheck in the dev image
	$(COMPOSE_DEV) run --rm tinywebui npm run typecheck

dev-doctor: ## tinywebui doctor, inside the running dev container
	$(COMPOSE_DEV) exec tinywebui node bin/tinywebui.ts doctor



# ---- images -------------------------------------------------------------------

build: build-hybrid build-lexical build-dev ## build every image

build-hybrid: ## the default image: BM25 + local embeddings, model baked in
	docker build --file Dockerfile --tag $(IMAGE):$(TAG) .

build-lexical: ## the small image: FTS5 BM25 only, no embedding runtime
	docker build --file Dockerfile.lexical --tag $(IMAGE):$(TAG)-lexical .

build-dev: ## the development image
	docker build --file Dockerfile.dev --tag $(IMAGE):dev .

# Boots an image and asserts it does what a deployment needs: reaches its
# database, serves the page, and keeps its API closed without a session. The
# same probe .github/workflows/images.yml runs on what it publishes.
smoke: ## boot the default image and probe it (needs build-hybrid)
	@./scripts/smoke-image.sh $(IMAGE):$(TAG)

smoke-lexical: ## boot the lexical image and probe it (needs build-lexical)
	@./scripts/smoke-image.sh $(IMAGE):$(TAG)-lexical

# ---- production ---------------------------------------------------------------

prod-up: ## the production stack from docker-compose.yml, detached
	docker compose up --build --detach

prod-down: ## stop the production stack
	docker compose down

clean: ## remove the local images this Makefile builds
	-@docker image rm --force $(IMAGE):$(TAG) $(IMAGE):$(TAG)-lexical $(IMAGE):dev 2>/dev/null || true
