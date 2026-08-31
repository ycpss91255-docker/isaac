#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/early_close_reader.sh -- the "no
# pipeline into an early-closing reader" lint.
#
# `grep -q` leaves the instant it matches and `head -n1` after one line.
# A writer still writing then takes SIGPIPE and exits 141, `pipefail`
# makes 141 the PIPELINE's status, and an `if` reads that as false -- so a
# SUCCESSFUL match is reported as "not found". The status is not lost, it
# is inverted, and the caller silently takes the other branch. Where the
# status feeds a bare assignment under `set -e` instead, the caller dies
# with no message at all.
#
# The rule is scoped to dist/ + script/ *.sh -- shell that runs under
# `set -euo pipefail` at file scope, or is sourced by shell that does. A
# whole-tree version would be worthless: bats test bodies run with
# pipefail OFF (measured: `false | true` yields 0 there), so every one of
# the ~65 candidates under test/bats/** is structurally incapable of the
# inversion.
#
# Detection runs against a controlled temp REPO_ROOT so the spec is
# independent of the live tree's contents; a final case drives the REAL
# tree to prove it passes today. Shape mirrors
# bash_source_guard_lint_spec.bats / home_literal_lint_spec.bats.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/early_close_reader.sh

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/dist/script/docker/lib" \
    "${SCRATCH}/script/test/drivers"
  REPO_ROOT="${SCRATCH}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _write <relative-path> <line>... -- create a scanned-tree fixture file.
_write() {
  local _rel="${1}"; shift
  mkdir -p "$(dirname "${SCRATCH}/${_rel}")"
  printf '%s\n' "$@" > "${SCRATCH}/${_rel}"
}

# ════════════════════════════════════════════════════════════════════
# _run_early_close_reader: violations
# ════════════════════════════════════════════════════════════════════

@test "_run_early_close_reader: FAILS on a pipeline into grep -q, naming file and line (#905)" {
  # The run.sh / exec.sh shape: a running container reported as not
  # running, and the caller takes the other branch in silence.
  _write "dist/script/docker/lib/x.sh" \
    '#!/usr/bin/env bash' \
    'if docker ps --format "{{.Names}}" | grep -qx "${_name}"; then :; fi'
  run _run_early_close_reader
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/x.sh:2"* ]]
}

@test "_run_early_close_reader: FAILS on a clustered quiet flag (-qxF) (#905)" {
  # `-q` is rarely alone. A rule that only matched the bare flag would
  # have missed completions.sh and check-base-version.sh outright.
  _write "dist/script/base/y.sh" \
    '#!/usr/bin/env bash' \
    'zsh -c "print -l \$fpath" | grep -qxF "${_dir}"'
  run _run_early_close_reader
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/base/y.sh:2"* ]]
}

@test "_run_early_close_reader: FAILS on a quiet flag that is not the first argument (#905)" {
  _write "dist/script/base/y.sh" \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "${_x}" | grep -x -q -- "${_want}"'
  run _run_early_close_reader
  [ "${status}" -ne 0 ]
}

@test "_run_early_close_reader: FAILS on the long-form --quiet (#905)" {
  _write "dist/script/base/y.sh" \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "${_x}" | grep --quiet "${_want}"'
  run _run_early_close_reader
  [ "${status}" -ne 0 ]
}

@test "_run_early_close_reader: FAILS on a pipeline into head, with or without -n (#905)" {
  _write "dist/script/base/z.sh" \
    '#!/usr/bin/env bash' \
    '_a="$(git ls-remote --tags "${_r}" | head -1)"' \
    '_b="$(nvidia-smi --query-gpu=x --format=csv,noheader | head)"' \
    '_c="$(printf "%s\n" "${_v}" | head -n1)"'
  run _run_early_close_reader
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"z.sh:2"* ]]
  [[ "${output}" == *"z.sh:3"* ]]
  [[ "${output}" == *"z.sh:4"* ]]
}

@test "_run_early_close_reader: FAILS on a reader on its own continuation line (#905)" {
  # Both `| head -1` sites in the tree were written this way. A rule that
  # required the writer and the reader on one line would have found
  # neither.
  _write "dist/script/base/z.sh" \
    '#!/usr/bin/env bash' \
    '_r="$(git ls-remote --tags "${_x}" \' \
    '  | grep -oE "refs/tags/v[0-9.]+" \' \
    '  | head -1)"'
  run _run_early_close_reader
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"z.sh:4"* ]]
}

@test "_run_early_close_reader: FAILS in base's own tooling tree, not just dist/ (#905)" {
  _write "script/test/drivers/w.sh" \
    '#!/usr/bin/env bash' \
    '_min="$(printf "%s\n" "${_nums[@]}" | sort | head -n1)"'
  run _run_early_close_reader
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"script/test/drivers/w.sh:2"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_early_close_reader: what is deliberately NOT a violation
# ════════════════════════════════════════════════════════════════════

@test "_run_early_close_reader: PASSES a reader that drains the stream (grep -v, grep -c) (#905)" {
  # The hazard is the reader LEAVING, not the pipe. `grep -v` and
  # `grep -c` both read to EOF, so nothing upstream is ever stranded --
  # and build.sh / prune.sh / setup_tui.sh use exactly these today.
  _write "dist/script/docker/wrapper/b.sh" \
    '#!/usr/bin/env bash' \
    '_imgs="$(docker images --format "{{.Repository}}" | grep -v "^<none>$")"' \
    '_n="$(nvidia-smi -L | grep -c "^GPU ")"'
  run _run_early_close_reader
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_early_close_reader: PASSES grep -q reading a FILE, which strands nobody (#905)" {
  # No pipe, no writer, no race. dockerfile_migrate.sh is full of these.
  _write "dist/script/docker/lib/m.sh" \
    '#!/usr/bin/env bash' \
    'grep -q "\.base/downstream/" "${_file}"' \
    'grep -qE "^COPY" "${_a}" || grep -qE "^RUN" "${_b}"'
  run _run_early_close_reader
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_early_close_reader: PASSES a logical OR that merely precedes grep -q (#905)" {
  # `||` is not a pipeline. Masking it is what keeps the rule off the
  # ~dozen `... || grep -q ... file` lines the tree already has.
  _write "dist/script/docker/lib/m.sh" \
    '#!/usr/bin/env bash' \
    '[[ -f "${_p}" ]] || grep -q "^x" "${_p}"'
  run _run_early_close_reader
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_early_close_reader: PASSES a here-string into grep -q (no writer process) (#905)" {
  # `<<<` is a redirection, not a pipeline: its status is not part of
  # pipefail and there is no upstream process to strand.
  _write "dist/script/docker/lib/m.sh" \
    '#!/usr/bin/env bash' \
    'grep -qE "^${_svc}:" <<< "${_str}"'
  run _run_early_close_reader
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_early_close_reader: PASSES a comment that merely describes the shape (#905)" {
  # Every fix in the tree carries a comment spelling the bad pipeline out.
  # Flagging prose about the rule would make the rule unwritable.
  _write "dist/script/docker/lib/m.sh" \
    '#!/usr/bin/env bash' \
    '# It used to be `docker ps --format "{{.Names}}" | grep -qx "${n}"`,' \
    '# and `git ls-remote ... | head -1` before that.' \
    '_x=1'
  run _run_early_close_reader
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_early_close_reader: PASSES an in-shell drain (the shape the fixes use) (#905)" {
  _write "dist/script/docker/lib/m.sh" \
    '#!/usr/bin/env bash' \
    '_found=1' \
    'while IFS= read -r _l || [[ -n "${_l}" ]]; do' \
    '  [[ "${_l}" == "${_n}" ]] && _found=0' \
    'done < <(docker ps --format "{{.Names}}")'
  run _run_early_close_reader
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_early_close_reader: ignores non-.sh files and files outside the scanned trees (#905)" {
  _write "dist/notes.md" 'docker ps | grep -q x'
  _write "dist/script/docker/lib/m.sh" '#!/usr/bin/env bash'
  mkdir -p "${SCRATCH}/test/bats/unit"
  printf '%s\n' 'ls "${d}" | head -n1' > "${SCRATCH}/test/bats/unit/a_spec.bats"
  printf '%s\n' 'ls "${d}" | head -n1' > "${SCRATCH}/test/bats/unit/b.sh"
  run _run_early_close_reader
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_early_close_reader: allow region
# ════════════════════════════════════════════════════════════════════

@test "_run_early_close_reader: EXEMPTS a pipeline inside an allow-begin/allow-end region (#905)" {
  _write "dist/script/docker/lib/m.sh" \
    '#!/usr/bin/env bash' \
    '# early-close-lint: allow-begin -- display only, status discarded' \
    'docker images | head -20' \
    '# early-close-lint: allow-end'
  run _run_early_close_reader
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_early_close_reader: FAILS on a pipeline AFTER an allow-end (region does not leak) (#905)" {
  _write "dist/script/docker/lib/m.sh" \
    '#!/usr/bin/env bash' \
    '# early-close-lint: allow-begin -- display only' \
    'docker images | head -20' \
    '# early-close-lint: allow-end' \
    'docker ps | head -1'
  run _run_early_close_reader
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"m.sh:5"* ]]
}

@test "_run_early_close_reader: FAILS on an unterminated allow-begin region (#905)" {
  _write "dist/script/docker/lib/m.sh" \
    '#!/usr/bin/env bash' \
    '# early-close-lint: allow-begin -- forgot to close' \
    'docker images | head -20'
  run _run_early_close_reader
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unterminated"* ]]
}

@test "_run_early_close_reader: FAILS on an allow-end with no matching allow-begin (#905)" {
  _write "dist/script/docker/lib/m.sh" \
    '#!/usr/bin/env bash' \
    '# early-close-lint: allow-end'
  run _run_early_close_reader
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unmatched"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_early_close_reader: scan-root guard
# ════════════════════════════════════════════════════════════════════

@test "_run_early_close_reader: FAILS when a scan root is missing (no vacuous pass) (#905)" {
  rm -rf "${SCRATCH}/dist"
  run _run_early_close_reader
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_early_close_reader: real tree guard
# ════════════════════════════════════════════════════════════════════

@test "_run_early_close_reader: the REAL shipped + tooling trees pass today (#905)" {
  REPO_ROOT="/source"
  run _run_early_close_reader
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}
