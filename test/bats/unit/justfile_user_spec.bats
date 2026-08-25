#!/usr/bin/env bats
#
# Executable tests for the user-facing justfile at
# dist/script/justfile (entry) + dist/script/docker/justfile.docker (symlinked from downstream repo root as
# `justfile`). ADR-00000005`just` replaces the GNU make wrapper.
# Each recipe is a 1:1 forward to ./script/<name>.sh with `{{args}}`
# passthrough -- no MAKEOVERRIDES guard / `--` separator / EXEC_ARGS shim.
#
# These RUN `just` for real (parity with the retired makefile_user_spec).
# They skip when `just` is not in the test-tools image yet (pre-release
# GHCR pull); see template_spec for the static `apk add ... just` guard
# and the release-test-tools smoke check. Static content lives in
# justfile_spec.bats.
#
# Strategy mirrors the old makefile_user_spec: sandbox a repo with the
# justfile symlinked at root and the wrapper scripts stubbed under
# script/, each recording `<name> <args...>` to ${TMP_REPO}/.invocation_log.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  command -v just >/dev/null 2>&1 || skip "just not installed in this test-tools image"

  # shellcheck disable=SC2154
  TMP_REPO="$(mktemp -d)"
  export TMP_REPO
  mkdir -p "${TMP_REPO}/.base/dist/script/docker" "${TMP_REPO}/script/docker"

  # Layered entry chain (ADR-00000010): <repo>/justfile -> script/justfile
  # -> .base/dist/script/justfile (entry), which imports
  # script/docker/justfile.docker (the top-level docker recipes).
  cp /source/dist/script/justfile "${TMP_REPO}/.base/dist/script/justfile"
  cp /source/dist/script/docker/justfile.docker "${TMP_REPO}/.base/dist/script/docker/justfile.docker"
  ln -s "script/justfile" "${TMP_REPO}/justfile"
  ln -s "../.base/dist/script/justfile" "${TMP_REPO}/script/justfile"
  ln -s "../../.base/dist/script/docker/justfile.docker" "${TMP_REPO}/script/docker/justfile.docker"

  # `template` namespace: the entry mod?s script/template/justfile.template.
  mkdir -p "${TMP_REPO}/.base/dist/script/template/skel" "${TMP_REPO}/script/template"
  # new.sh sources ../docker/lib/i18n.sh for --lang; mirror it. The
  # namespace `help` recipes invoke the shared i18n renderer
  # (docker/lib/help.sh), which sources i18n.sh from the same lib dir.
  mkdir -p "${TMP_REPO}/.base/dist/script/docker/lib"
  cp /source/dist/script/docker/lib/i18n.sh "${TMP_REPO}/.base/dist/script/docker/lib/i18n.sh"
  cp /source/dist/script/docker/lib/help.sh "${TMP_REPO}/.base/dist/script/docker/lib/help.sh"
  chmod +x "${TMP_REPO}/.base/dist/script/docker/lib/help.sh"
  cp /source/dist/script/template/justfile.template "${TMP_REPO}/.base/dist/script/template/justfile.template"
  cp /source/dist/script/template/new.sh "${TMP_REPO}/.base/dist/script/template/new.sh"
  cp /source/dist/script/template/skel/justfile.skel "${TMP_REPO}/.base/dist/script/template/skel/justfile.skel"
  cp /source/dist/script/template/skel/skel.sh "${TMP_REPO}/.base/dist/script/template/skel/skel.sh"
  chmod +x "${TMP_REPO}/.base/dist/script/template/new.sh"
  ln -s "../../.base/dist/script/template/justfile.template" "${TMP_REPO}/script/template/justfile.template"
  ln -s "../../.base/dist/script/template/new.sh" "${TMP_REPO}/script/template/new.sh"
  ln -s "../../.base/dist/script/template/skel" "${TMP_REPO}/script/template/skel"

  # `base` namespace: the entry mod?s script/base/justfile.base
  # (just base upgrade / update / init / completions).
  mkdir -p "${TMP_REPO}/.base/dist/script/base" "${TMP_REPO}/script/base"
  cp /source/dist/script/base/justfile.base "${TMP_REPO}/.base/dist/script/base/justfile.base"
  ln -s "../../.base/dist/script/base/justfile.base" "${TMP_REPO}/script/base/justfile.base"
  # completions.sh is reached via the consumer symlink script/base/completions.sh;
  # stub it as a recorder so `just base completions` forwarding is observable.
  cat > "${TMP_REPO}/.base/dist/script/base/completions.sh" <<'EOS'
#!/usr/bin/env bash
printf 'completions'
for _arg in "$@"; do printf ' %s' "${_arg}"; done
printf '\n'
EOS
  chmod +x "${TMP_REPO}/.base/dist/script/base/completions.sh"
  ln -s "../../.base/dist/script/base/completions.sh" "${TMP_REPO}/script/base/completions.sh"
  # `just base init` forwards to ./.base/dist/script/base/init.sh
  # (relocated in) -- stub it as a recorder.
  cat > "${TMP_REPO}/.base/dist/script/base/init.sh" <<'EOS'
#!/usr/bin/env bash
printf 'init'
for _arg in "$@"; do printf ' %s' "${_arg}"; done
printf '\n'
EOS
  chmod +x "${TMP_REPO}/.base/dist/script/base/init.sh"

  local _name
  for _name in build run exec stop prune setup setup_tui; do
    cat > "${TMP_REPO}/script/${_name}.sh" <<EOS
#!/usr/bin/env bash
printf '${_name}'
for _arg in "\$@"; do printf ' %s' "\${_arg}"; done
printf '\n'
EOS
    chmod +x "${TMP_REPO}/script/${_name}.sh"
  done
  # upgrade wrapper lives under .base/dist/script/base/
  cat > "${TMP_REPO}/.base/dist/script/base/upgrade.sh" <<'EOS'
#!/usr/bin/env bash
printf 'upgrade'
for _arg in "$@"; do printf ' %s' "${_arg}"; done
printf '\n'
EOS
  chmod +x "${TMP_REPO}/.base/dist/script/base/upgrade.sh"
}

teardown() {
  # Guard with an if-block (not `[ ] && rm`): when setup skips before
  # TMP_REPO is set (e.g. `just` absent in the kcov runner image), the
  # `&&` chain exits non-zero and bats turns the clean skip into a
  # teardown failure.
  if [ -n "${TMP_REPO:-}" ]; then
    rm -rf "${TMP_REPO}"
  fi
}

@test "just docker build forwards positional args to ./script/build.sh" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" docker build test
  assert_success
  assert_output --partial "build test"
}

@test "just docker build passes flags through verbatim (no -- separator needed)" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" docker build --no-cache test
  assert_success
  assert_output --partial "build --no-cache test"
}

@test "just docker exec passes = -bearing Kit-style args through (no EXEC_ARGS shim, #469)" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" docker exec -t cli --/app/k=v
  assert_success
  assert_output --partial "exec -t cli --/app/k=v"
}

@test "just docker run / stop / prune / setup forward to their wrappers" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" docker run -d
  assert_success
  assert_output --partial "run -d"
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" docker stop
  assert_success
  assert_output --partial "stop"
}

@test "just docker setup-tui forwards to ./script/setup_tui.sh" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" docker setup-tui
  assert_success
  assert_output --partial "setup_tui"
}

@test "just docker start --help prints composite usage and does NOT build or run (#779)" {
  # The composite `start` verb runs build.sh then run.sh. `--help` must
  # short-circuit with the composite usage and exit BEFORE either step --
  # previously build.sh's --help printed help (exit 0) and then run.sh ran
  # a real container anyway. The stub build.sh would emit `build --help`
  # and stub run.sh a bare `run` line iff the steps executed.
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" docker start --help
  assert_success
  assert_output --partial "Usage: just docker start"
  refute_line "build --help"
  refute_line "run"
}

@test "just docker start -h short-circuits like --help (#779)" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" docker start -h
  assert_success
  assert_output --partial "Usage: just docker start"
  refute_line "build -h"
  refute_line "run"
}

@test "just base upgrade forwards to ./.base/dist/script/base/upgrade.sh (#652, #654, ADR-00000011)" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" base upgrade v0.30.0
  assert_success
  assert_output --partial "upgrade v0.30.0"
}

@test "just base update runs upgrade.sh --check (apt-aligned, #652)" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" base update
  assert_success
  assert_output --partial "upgrade --check"
}

@test "just base init forwards to ./.base/dist/script/base/init.sh (#653, #654, ADR-00000011)" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" base init --force
  assert_success
  assert_output --partial "init --force"
}

@test "just base completions forwards to script/base/completions.sh (#653, ADR-00000011)" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" base completions install --shell bash
  assert_success
  assert_output --partial "completions install --shell bash"
}

@test "bare just lists namespaces (replaces make help)" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}"
  assert_success
  # docker verbs now live under the `docker` namespace (ADR-00000011), so the
  # entry lists `docker ...` rather than top-level build/run.
  assert_output --partial "docker"
}

# ──namespace bare help + recipe --help/--lang forwarding ───────────────

@test "bare just docker lists the docker verbs (namespace help, #655)" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" docker
  assert_success
  assert_output --partial "build"
}

@test "bare just base lists the base verbs (namespace help, #655)" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" base
  assert_success
  assert_output --partial "upgrade"
}

@test "just docker build --help forwards --help to the backing script (#655)" {
  # The docker recipe is `build *args:` -> ./script/build.sh {{args}}, so
  # --help reaches the script as an arg (just 1.52 forwards recipe flags).
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" docker build --help
  assert_success
  assert_output --partial "build --help"
}

@test "just docker build --lang ja forwards --lang to the backing script (#655)" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" docker build --lang ja
  assert_success
  assert_output --partial "build --lang ja"
}

@test "just base completions --lang forwards --lang to completions.sh (#655)" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" base completions install --lang zh-TW
  assert_success
  assert_output --partial "completions install --lang zh-TW"
}

# ── help coverage: recipe --help shim + namespace help recipe ──────────

@test "just base update --help reaches upgrade.sh usage, not the check (#789)" {
  # `update` is check-only; the *args --help shim must forward --help (usage)
  # and must NOT run --check (the stub echoes its args, so we can tell them
  # apart).
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" base update --help
  assert_success
  assert_output --partial "upgrade --help"
  refute_output --partial "--check"
}

@test "just base update -h reaches upgrade.sh usage (#789)" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" base update -h
  assert_success
  assert_output --partial "upgrade --help"
}

@test "just docker help + h alias list the docker verbs (#789)" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" docker help
  assert_success
  assert_output --partial "build"
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" docker h
  assert_success
  assert_output --partial "build"
}

@test "just base help + h alias list the base verbs (#789)" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" base help
  assert_success
  assert_output --partial "upgrade"
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" base h
  assert_success
  assert_output --partial "upgrade"
}

@test "just template help + h alias print the template usage (#789)" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" template help
  assert_success
  assert_output --partial "just template new"
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" template h
  assert_success
  assert_output --partial "just template new"
}

# ── language-aware `just <ns> help` (i18n via _msg help) ───────────────
# The namespace `help` recipe renders each recipe's one-line summary in
# the caller's language through the shared _msg help renderer
# (dist/script/docker/lib/help.sh). `just --list` / bare `just <ns>`
# stay English (native listing cannot be intercepted); `just <ns> help`
# is the rich translated entry point.

@test "just docker help renders zh-TW recipe summaries under LANG=zh-TW (i18n)" {
  LANG=zh_TW.UTF-8 run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" docker help
  assert_success
  assert_output --partial "建置 devel 映像"
  assert_output --partial "just docker build"
  assert_output --partial "互動式啟動容器"
}

@test "just docker help renders Japanese recipe summaries under LANG=ja (i18n)" {
  LANG=ja_JP.UTF-8 run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" docker help
  assert_success
  assert_output --partial "devel イメージをビルド"
}

@test "just docker help --lang overrides LANG for the listing (i18n)" {
  LANG=C run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" docker help --lang zh-CN
  assert_success
  assert_output --partial "构建 devel 镜像"
}

@test "just docker help English default still renders the translated listing (i18n)" {
  LANG=C run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" docker help
  assert_success
  assert_output --partial "Build the devel image"
  assert_output --partial "just docker build"
}

@test "just base help renders zh-TW recipe summaries under LANG=zh-TW (i18n)" {
  LANG=zh_TW.UTF-8 run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" base help
  assert_success
  assert_output --partial "拉取 .base subtree"
  assert_output --partial "just base upgrade"
}

@test "just template help renders zh-TW recipe summary under LANG=zh-TW (i18n)" {
  LANG=zh_TW.UTF-8 run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" template help
  assert_success
  assert_output --partial "just template new"
  assert_output --partial "命令群組"
}

@test "dashed just <ns> --help errors but hints 'help' (documented just limit, #789)" {
  # A dashed name cannot be a just recipe/alias, so `just <ns> --help` cannot be
  # intercepted; with a `help` recipe present just emits a 'Did you mean help?'
  # hint instead of a bare error. This is the documented namespace-help contract.
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" docker --help
  assert_failure
  assert_output --partial "help"
}

@test "just template new --help shows the recipe usage (recipe-level help, #789)" {
  # A required-positional recipe still surfaces --help: just passes it through
  # and new.sh prints its usage.
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" template new --help
  assert_success
  assert_output --partial "Usage: just template new"
}

@test "repo-local group via script/local/justfile.local resolves as a top-level namespace (#632)" {
  # The entry imports script/local/justfile.local (`import?`); a group
  # registered there with a `mod?` line (path relative to script/local)
  # becomes a top-level sub-command `just <group> <recipe>`.
  mkdir -p "${TMP_REPO}/script/local/greet"
  printf "mod? greet 'greet/justfile.greet'\n" > "${TMP_REPO}/script/local/justfile.local"
  printf 'hi:\n    @echo "greet-hi"\n' > "${TMP_REPO}/script/local/greet/justfile.greet"
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" greet hi
  assert_success
  assert_output --partial "greet-hi"
}

@test "just template new <name> scaffolds a working repo-local group (#633, closes #594)" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" template new deploy
  assert_success
  assert [ -f "${TMP_REPO}/script/local/deploy/justfile.deploy" ]
  # the new group is immediately usable as a top-level namespace
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" deploy hello
  assert_success
  assert_output --partial "hello from the deploy group"
}

@test "bare just template prints help (#633)" {
  run just --justfile "${TMP_REPO}/justfile" --working-directory "${TMP_REPO}" template
  assert_success
  assert_output --partial "just template new"
}
