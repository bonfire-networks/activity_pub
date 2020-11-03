.PHONY: help dev-exports dev-build dev-deps dev-db dev-test-db dev-test dev-setup dev

ORG_NAME=commonspub
APP_NAME=activitypub

APP_DOCKER_REPO="$(ORG_NAME)/$(APP_NAME)"
APP_DEV_CONTAINER="$(ORG_NAME)_$(APP_NAME)_dev"
APP_DEV_DOCKERCOMPOSE=docker-compose.dev.yml

APP_VSN ?= `grep 'version:' mix.exs | cut -d '"' -f2`
APP_BUILD ?= `git rev-parse --short HEAD`

init:
	@echo "Running build scripts for $(APP_NAME):$(APP_VSN)-$(APP_BUILD)"

help: init
	@perl -nle'print $& if m{^[a-zA-Z_-]+:.*?## .*$$}' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

dev: init ## Run the app in dev
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) run --service-ports web

dev-shell: init ## Open a shell, in dev mode
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) run --service-ports web bash

dev-build: init ## Build the dev image
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) build

dev-rebuild: init ## Rebuild the dev image (without cache)
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) build --no-cache

dev-recompile: init ## Recompile the dev codebase (without cache)
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) run web mix compile --force
	make 

dev-deps: init ## Prepare dev dependencies
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) run web mix local.hex --force 
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) run web mix local.rebar --force
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) run web mix deps.get

dev-dep-rebuild: init ## Rebuild a specific library, eg: `make dev-dep-rebuild lib=pointers`
	sudo rm -rf deps/$(lib)
	sudo rm -rf _build/$(lib)
	sudo rm -rf _build/dev/lib/$(lib)
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) run web rm -rf _build/$(lib) && mix deps.compile $(lib)

dev-dep-update: init ## Upgrade a dep, eg: `make dev-dep-update lib=plug`
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) run web mix deps.update $(lib)

dev-deps-update-all: init ## Upgrade all deps
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) run web mix deps.update --all

dev-db-up: init  ## Start the dev DB
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) up db

dev-search-up: init ## Start the dev search index
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) up search

dev-services-up: init ## Start the dev DB & search index
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) up db search

dev-db-admin: init ## Start the dev DB and dbeaver admin UI
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) up dbeaver

dev-db: init  ## Create the dev DB
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) run web mix ecto.create

dev-db-rollback: init ## Reset the dev DB
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) run web mix ecto.rollback --log-sql

dev-db-reset: init  ## Reset the dev DB
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) run web mix ecto.reset

dev-db-migrate: init  ## Run migrations on dev DB
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) run web mix ecto.migrate --log-sql

dev-db-seeds: init ## Insert some test data in dev DB
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) run web mix ecto.seeds

dev-test-watch: init ## Run tests
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) run --service-ports -e MIX_ENV=test web iex -S mix phx.server

test-db: init  ## Create or reset the test DB
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) run -e MIX_ENV=test web mix ecto.reset

test: init ## Run tests
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) run web mix test $(dir)

test-watch: init ## Run tests
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) run web mix test.watch --stale $(dir)

dev-psql: init ## Run postgres (without Docker)
	psql -h localhost -U postgres $(APP_DEV_CONTAINER)

test-psql: init ## Run postgres for tests (without Docker)
	psql -h localhost -U postgres "$(APP_NAME)_test"

dev-setup: dev-deps dev-db dev-db-migrate ## Prepare dependencies and DB for dev

dev-run: init ## Run a custom command in dev env, eg: `make dev-run cmd="mix deps.update plug`
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) run --service-ports web $(cmd)

dev-logs: init ## Run tests
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) logs -f

dev-stop: init ## Stop the dev app
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) stop

dev-down: init ## Remove the dev app
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) down

dev-docs: init ## Remove the dev app
	docker-compose -p $(APP_DEV_CONTAINER) -f $(APP_DEV_DOCKERCOMPOSE) run web mix docs

manual-deps: init ## Prepare dependencies (without Docker)
	mix local.hex --force
	mix local.rebar --force
	mix deps.get

manual-db: init  ## Create or reset the DB (without Docker)
	mix ecto.reset

