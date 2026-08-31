#!/usr/bin/env bash
# local.sh -- companion bash template for repo-local just recipes.
#
# REPO-OWNED: committed by this repo, never clobbered by a base subtree
# upgrade (like justfile.local beside it). It is a starting point -- replace
# the body with your own logic and back a recipe in justfile.local, e.g.:
#
#   local-hello:
#       @./local.sh
#
# For a fuller, namespaced command group prefer `just template new <name>`,
# which scaffolds script/local/<name>/{justfile.<name>,<name>.sh} and
# registers it for you; this top-level local.sh is the lightweight option.
set -euo pipefail

main() {
  echo "hello from script/local/local.sh -- edit me"
}

main "$@"
