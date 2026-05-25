.PHONY: build run exec stop prune setup setup-tui upgrade upgrade-check help

# Default goal: bare `make` prints help instead of building. Discoverability
# beats implicit build for a user-facing entry. RFC #330.
.DEFAULT_GOAL := help

# Each wrapper recipe forwards the remaining positional args from
# MAKECMDGOALS to the underlying script. The `%:` catch-all at the bottom
# turns those positional tokens into no-ops so Make does not error on
# `make build test` ("test" has no rule of its own). Flags such as
# --no-cache must come after a `--` separator because Make's argument
# parser consumes `-` / `--` tokens as its own options before MAKECMDGOALS
# is built:
#
#   make build test                # -> ./script/build.sh test
#   make build -- --no-cache test  # -> ./script/build.sh --no-cache test

build: ## Build devel image (e.g. make build test  |  make build -- --no-cache)
	./script/build.sh $(filter-out $@,$(MAKECMDGOALS))

run: ## Run container interactively (e.g. make run  |  make run -- -d)
	./script/run.sh $(filter-out $@,$(MAKECMDGOALS))

exec: ## Exec into running container (e.g. make exec -- -t bats-src bash)
	./script/exec.sh $(filter-out $@,$(MAKECMDGOALS))

stop: ## Stop and remove containers
	./script/stop.sh $(filter-out $@,$(MAKECMDGOALS))

prune: ## Prune build cache / dangling images
	./script/prune.sh $(filter-out $@,$(MAKECMDGOALS))

setup: ## Regenerate .env + compose.yaml from setup.conf
	./script/setup.sh $(filter-out $@,$(MAKECMDGOALS))

setup-tui: ## Interactive TUI to edit setup.conf
	./script/setup_tui.sh $(filter-out $@,$(MAKECMDGOALS))

upgrade: ## Upgrade base subtree (e.g. make upgrade v0.30.0)
	./.base/upgrade.sh $(filter-out $@,$(MAKECMDGOALS))

upgrade-check: ## Check for base updates
	@./.base/upgrade.sh --check || [ $$? -eq 1 ]

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*##"}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# Catch-all: positional args forwarded by the named recipes above land here
# as goal names with no recipe of their own. Silent no-op keeps Make from
# erroring on `make build test`, `make upgrade v0.30.0`, etc.
%:
	@:
