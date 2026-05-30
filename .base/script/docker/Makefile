# Disable built-in implicit rules so make does not stat absolute-path
# goals (e.g. /root/demo/test.sh) which would fail with EACCES/ENOENT
# before the catch-all `%:` fires.  Fixes #414 case 2.
MAKEFLAGS += --no-builtin-rules
.SUFFIXES:

.PHONY: build run start exec stop prune setup setup-tui upgrade upgrade-check help

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
#
# Limitation: make treats VAR=VALUE tokens as variable overrides — they
# never reach MAKECMDGOALS.  The guard below detects this via
# MAKEOVERRIDES and aborts with a hint to call the script directly.

# Guard: detect VAR=VALUE args silently swallowed by make (#414 case 1).
define _check_overrides
$(if $(MAKEOVERRIDES),@printf '\033[31mError:\033[0m make intercepted VAR=VALUE argument(s): $(MAKEOVERRIDES)\n' >&2; \
	printf '       Run the underlying script directly for args containing "=".\n' >&2; \
	exit 1;)
endef

build: ## Build devel image (e.g. make build test  |  make build -- --no-cache)
	$(_check_overrides)
	./script/build.sh $(filter-out $@,$(MAKECMDGOALS))

run: ## Run container interactively (e.g. make run  |  make run -- -d)
	$(_check_overrides)
	./script/run.sh $(filter-out $@,$(MAKECMDGOALS))

start: ## Build + run in one step (e.g. make start  |  make start -- --no-cache)
	$(_check_overrides)
	./script/build.sh $(filter-out $@,$(MAKECMDGOALS))
	./script/run.sh

exec: ## Exec into running container (e.g. make exec -- -t bats-src bash; EXEC_ARGS='--/app/k=v' make exec for Kit-style args, #469)
	$(_check_overrides)
	./script/exec.sh $(filter-out $@,$(MAKECMDGOALS)) $(EXEC_ARGS)

stop: ## Stop and remove containers
	$(_check_overrides)
	./script/stop.sh $(filter-out $@,$(MAKECMDGOALS))

prune: ## Prune build cache / dangling images
	$(_check_overrides)
	./script/prune.sh $(filter-out $@,$(MAKECMDGOALS))

setup: ## Regenerate .env + compose.yaml from setup.conf
	$(_check_overrides)
	./script/setup.sh $(filter-out $@,$(MAKECMDGOALS))

setup-tui: ## Interactive TUI to edit setup.conf
	$(_check_overrides)
	./script/setup_tui.sh $(filter-out $@,$(MAKECMDGOALS))

upgrade: ## Upgrade base subtree (e.g. make upgrade v0.30.0)
	$(_check_overrides)
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
