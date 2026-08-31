#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/derived_figures.sh -- the "a figure a
# document repeats must match the code that defines it" lint.
#
# Two figures had drifted, each in more than one place, which is what makes
# a hand fix the wrong answer: the baseline stage blocklist was written as a
# five-element set including `devel-test` in the README, in two of
# stage.sh's own docstrings, in all three localized READMEs and in all four
# setup_tui.sh message tables, while `_validate_stage_name` blocklists four
# names plus two legacy aliases and deliberately lets `devel-test` through;
# and README.md's setup.conf overview announced seven sections while
# SCHEMA_SECTIONS declared fourteen.
#
# So the lint derives both figures from the code -- the baseline renderings
# by reading `_validate_stage_name`'s own `return 2` case arms and probing
# each name back through the predicate, the section list straight out of
# SCHEMA_SECTIONS -- and fails on any prose that disagrees.
#
# Detection runs against a controlled temp REPO_ROOT so the spec is
# independent of the live tree's contents; a final case drives the REAL tree
# to prove it passes today. Shape mirrors stale_setup_conf_lint_spec.bats /
# home_literal_lint_spec.bats.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die, and reads
  # _validate_stage_name / SCHEMA_SECTIONS out of the shipped lib; provide
  # all of them so the function runs against a controlled scratch tree.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/derived_figures.sh

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/dist/script/docker/lib" "${SCRATCH}/doc/readme"
  REPO_ROOT="${SCRATCH}"

  # A tree that passes, so each case perturbs exactly one thing.
  _write_readme
  printf '%s\n' '# CONTEXT' > "${SCRATCH}/CONTEXT.md"
  printf '%s\n' '#!/usr/bin/env bash' \
    > "${SCRATCH}/dist/script/docker/lib/sample.sh"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _write_readme [extra-line]... -- a scratch README.md whose setup.conf
# overview agrees with SCHEMA_SECTIONS, plus any extra prose lines.
_write_readme() {
  {
    printf '# base\n\n### One conf, %s sections\n\n```\n' \
      "${#SCHEMA_SECTIONS[@]}"
    local _section
    for _section in "${SCHEMA_SECTIONS[@]}"; do
      printf '[%s]    key = value\n' "${_section}"
    done
    printf '```\n\n'
    if [[ $# -gt 0 ]]; then
      printf '%s\n' "$@"
    fi
  } > "${SCRATCH}/README.md"
}

# _append <relative-path> <line>... -- add prose to a scratch file.
_append() {
  local _rel="${1}"; shift
  mkdir -p "$(dirname "${SCRATCH}/${_rel}")"
  printf '%s\n' "$@" >> "${SCRATCH}/${_rel}"
}

# ════════════════════════════════════════════════════════════════════
# _derived_baseline_renderings: the canonical set, read from the code
# ════════════════════════════════════════════════════════════════════

@test "_derived_baseline_renderings: derives the forward-looking and legacy sets from _validate_stage_name (#874)" {
  run _derived_baseline_renderings
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"{sys, devel-base, devel, runtime-test}"* ]]
  [[ "${output}" == *"{base, test}"* ]]
}

@test "_derived_baseline_renderings: does NOT include devel-test -- the predicate emits it as a service (#874)" {
  # The whole point of the drift: devel-test is emitted as the `test`
  # service, so a set that lists it tells a reader the service does not
  # exist.
  run _derived_baseline_renderings
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"devel-test"* ]]
}

@test "_derived_baseline_renderings: every derived name probes back as a baseline collision (#874)" {
  # The extractor reads case arms; the probe is what proves it read them
  # right. A name that does not return 2 means the extraction is wrong,
  # and the driver must say so rather than pin prose to a bad set.
  local _name _rc
  while read -r _name; do
    _rc=0
    _validate_stage_name "${_name}" || _rc=$?
    [ "${_rc}" -eq 2 ]
  done < <(_derived_baseline_names)
}

# ════════════════════════════════════════════════════════════════════
# _run_derived_figures: the baseline stage set
# ════════════════════════════════════════════════════════════════════

@test "_run_derived_figures: FAILS on a README baseline set that lists devel-test, naming file and line (#874)" {
  _write_readme 'Any stage outside the blocklist' \
    '{sys, devel-base, devel, devel-test, runtime-test} is auto-emitted.'
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"README.md:"* ]]
  [[ "${output}" == *"devel-test"* ]]
  [[ "${output}" == *"{sys, devel-base, devel, runtime-test}"* ]]
}

@test "_run_derived_figures: PASSES on the canonical forward-looking and legacy renderings (#874)" {
  _write_readme 'Outside `{sys, devel-base, devel, runtime-test}` (legacy' \
    '`{base, test}` also accepted) a stage is auto-emitted.'
  run _run_derived_figures
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_derived_figures: ignores a brace set that names no baseline stage (#874)" {
  _write_readme 'Isaac Sim adds `{headless, gui}` on top of devel.'
  run _run_derived_figures
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_derived_figures: catches a stale set wrapped across markdown lines (#874)" {
  # The live drift was wrapped in all four READMEs, so a line-at-a-time
  # matcher would have reported none of them.
  _write_readme 'Outside the blocklist `{sys, devel-base, devel, devel-test,' \
    'runtime-test}` a stage is auto-emitted.'
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"README.md:"* ]]
}

@test "_run_derived_figures: catches a stale set split by an escaped newline in a shell string (#874)" {
  # setup_tui.sh's four message tables wrap the set with a literal \n
  # inside a $'...' string -- the same drift, in the surface a user
  # actually reads at the TUI.
  _append "dist/script/docker/lib/sample.sh" \
    "_MSG[per_stage.empty]=\$'baseline {sys, devel-base, devel, devel-test,\\nruntime-test} is reserved.'"
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/sample.sh:"* ]]
}

@test "_run_derived_figures: catches a stale set wrapped across two shell comment lines (#874)" {
  # stage.sh's own docstring wraps the set over a `#` continuation, so the
  # comment marker has to be dropped before the join or it lands inside
  # the set and the whole literal reads as prose.
  _append "dist/script/docker/lib/sample.sh" \
    '# filters out the baseline blocklist {sys, devel-base, devel,' \
    '# devel-test, runtime-test} and echoes the rest.'
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/sample.sh:"* ]]
}

@test "_run_derived_figures: ignores a brace EXPANSION glued to a path (#874)" {
  # `test/bats/smoke/{shared,devel-test,runtime-test}/` is a real directory
  # layout, not a prose set -- rewriting it to the baseline would be
  # nonsense.
  _append "dist/script/docker/lib/sample.sh" \
    'Specs live under test/bats/smoke/{shared,devel-test,runtime-test}/.'
  run _run_derived_figures
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_derived_figures: scans CONTEXT.md and the localized READMEs too (#874)" {
  printf '%s\n' '# CONTEXT' 'A baseline stage is `{devel, devel-test}`.' \
    > "${SCRATCH}/CONTEXT.md"
  _append "doc/readme/README.zh-TW.md" \
    'baseline blocklist `{sys, devel-base, devel, devel-test, runtime-test}`'
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"CONTEXT.md:"* ]]
  [[ "${output}" == *"doc/readme/README.zh-TW.md:"* ]]
}

@test "_run_derived_figures: ignores a \${VAR} expansion that is not a stage set (#874)" {
  _append "dist/script/docker/lib/sample.sh" \
    '_conf="${_root}/.setup.conf"' \
    'printf "%s" "${_stage}"'
  run _run_derived_figures
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_derived_figures: the setup.conf section list
# ════════════════════════════════════════════════════════════════════

@test "_run_derived_figures: FAILS when the README section count disagrees with SCHEMA_SECTIONS (#874)" {
  sed -i "s/^### One conf, .* sections$/### One conf, seven sections/" \
    "${SCRATCH}/README.md"
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"One conf"* ]]
}

@test "_run_derived_figures: FAILS when the count is a number but the wrong one (#874)" {
  sed -i "s/^### One conf, .* sections$/### One conf, 7 sections/" \
    "${SCRATCH}/README.md"
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"${#SCHEMA_SECTIONS[@]}"* ]]
}

@test "_run_derived_figures: FAILS when the listed sections differ from SCHEMA_SECTIONS (#874)" {
  # The count is only the list's length; a block that drops [security] and
  # invents [extras] keeps the length and is still wrong.
  sed -i 's/^\[security\]    key = value$/[extras]    key = value/' \
    "${SCRATCH}/README.md"
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"security"* ]]
}

@test "_run_derived_figures: FAILS when the listed sections are out of template order (#874)" {
  # Swap the first two entries through a sentinel, so the second
  # expression cannot undo the first.
  sed -i 's/^\[image\]/[swap]/; s/^\[build\]/[image]/; s/^\[swap\]/[build]/' \
    "${SCRATCH}/README.md"
  run _run_derived_figures
  [ "${status}" -ne 0 ]
}

@test "_run_derived_figures: FAILS when the section heading is absent (no vacuous pass) (#874)" {
  sed -i '/^### One conf, /d' "${SCRATCH}/README.md"
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"One conf"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_derived_figures: scan-surface guard
# ════════════════════════════════════════════════════════════════════

@test "_run_derived_figures: FAILS when a required doc file is missing (no vacuous pass) (#874)" {
  rm -f "${SCRATCH}/CONTEXT.md"
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"CONTEXT.md"* ]]
}

@test "_run_derived_figures: FAILS when the dist/ scan root is missing (no vacuous pass) (#874)" {
  rm -rf "${SCRATCH}/dist"
  run _run_derived_figures
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_derived_figures: real tree guard
# ════════════════════════════════════════════════════════════════════

@test "_run_derived_figures: the REAL tree passes today (#874)" {
  REPO_ROOT="/source"
  run _run_derived_figures
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}
