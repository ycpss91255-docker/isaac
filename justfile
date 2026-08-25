# base self-development entry (just). base maintainers run `just test`
# (bare = run the whole self-test; `just test lint / coverage / ...` for
# sub-actions) and `just release <recipe>` (release / publish tooling).
# Bare `just` lists the namespaces.
#
# This is base's OWN entry, distinct from the consumer-facing entry shipped
# at dist/script/justfile (which downstream repos symlink as their
# root justfile via init.sh). base is consumed as a `.base/` subtree, so
# this file lands at `.base/justfile` in a consumer and is never invoked
# there (the consumer's own root justfile is the auto-discovered one).
#
# ADR-00000010/00000011: layered just entry, action-named namespaces
# (ci -> test, cd -> release). base's own tooling is namespaced here.
#
# base also self-uses the `docker` namespace it ships (ADR-00000011
# sec.2/4): `just docker build --target test-tools` builds base's tooling
# image via the very wrapper consumers use. base is the template SOURCE so
# it has no `.base/` subtree -- script/docker/justfile.docker + the flat
# script/<verb>.sh symlinks point straight into dist/ (committed, since
# init.sh -- which seeds them in a consumer -- never runs on base itself).

# The uid:gid base's own compose.yaml runs its checkout-mounting services
# as -- i.e. who owns everything the self-test writes into this working
# tree. compose.yaml carries no default for them -- a `:-1000` left files
# owned by a stranger on any host whose developer is not uid 1000 --
# and compose INTERPOLATES THE WHOLE FILE whatever service a command
# names, so every command that reads it needs them -- including
# `just docker build --target test-tools`, which names a service that
# reads neither. Exported once here rather than per recipe: `just`
# propagates a root export into module recipes, so the whole `just`
# surface is covered and raw `docker compose` stays the only refused
# path. The recipes that are also reachable via `just -f` (script/test's
# `system`, and test.sh itself) set them again for that case.
export HOST_UID := `id -u`
export HOST_GID := `id -g`

# Container-ops (self-use): build / run / exec / stop / prune / setup / setup-tui
mod? docker 'script/docker/justfile.docker'
# Self-test: bats + shellcheck + hadolint + kcov (just test [lint|coverage|...])
mod? test 'script/test/justfile.test'
# Release / publish tooling (just release <recipe>)
mod? release 'script/release/justfile.release'

# Default: list available recipes / namespaces.
default:
    @just --list
