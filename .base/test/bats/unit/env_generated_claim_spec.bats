#!/usr/bin/env bats
#
# Unit tests pinning the derived-artifact claim every setup surface makes.
#
# `setup.sh apply` regenerates TWO files: `.env.generated` (the derived
# interpolation cache, incl. the SETUP_* drift metadata) and `compose.yaml`.
# `.env` is the hand-authored, gitignored workload overlay -- apply scaffolds
# it once and never rewrites it (see `_setup_apply`'s A2 file-role comment and
# `_wrapper_setup_sync`).
#
# Every user-visible surface used to say "regenerate .env", which teaches the
# opposite of the file-role model: a user who hand-edited `.env` reads that and
# avoids the very command they are supposed to run, and a user who expects
# apply to rewrite `.env` from their conf edits waits for a change that never
# comes. These tests pin the corrected claim against the code so prose alone is
# never the guard, and they cover all four locales -- a string fix that lands in
# one locale is not a fix.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  HELP_SH="/source/dist/script/docker/lib/help.sh"
  SETUP_SH="/source/dist/script/docker/wrapper/setup.sh"
  JUSTFILE_DOCKER="/source/dist/script/docker/justfile.docker"
}

# ════════════════════════════════════════════════════════════════════
# `just docker help` -- the localized recipe listing (all four locales)
# ════════════════════════════════════════════════════════════════════

@test "just docker help: en setup summary names .env.generated (#879)" {
  run bash "${HELP_SH}" docker --lang en
  assert_success
  assert_output --partial "Regenerate .env.generated + compose.yaml from setup.conf"
}

@test "just docker help: zh-TW setup summary names .env.generated (#879)" {
  run bash "${HELP_SH}" docker --lang zh-TW
  assert_success
  assert_output --partial "重新產生 .env.generated 與 compose.yaml"
}

@test "just docker help: zh-CN setup summary names .env.generated (#879)" {
  run bash "${HELP_SH}" docker --lang zh-CN
  assert_success
  assert_output --partial "重新生成 .env.generated 与 compose.yaml"
}

@test "just docker help: ja setup summary names .env.generated (#879)" {
  run bash "${HELP_SH}" docker --lang ja
  assert_success
  assert_output --partial ".env.generated と compose.yaml を再生成"
}

# ════════════════════════════════════════════════════════════════════
# `just --list` doc comment (English-only; just cannot be intercepted)
# ════════════════════════════════════════════════════════════════════

@test "justfile.docker: the setup doc comment names .env.generated (#879)" {
  run grep -n '^# Regenerate' "${JUSTFILE_DOCKER}"
  assert_success
  assert_output --partial ".env.generated + compose.yaml from setup.conf"
}

# ════════════════════════════════════════════════════════════════════
# setup.sh usage + the post-mutation "next:" hint
# ════════════════════════════════════════════════════════════════════

@test "setup.sh --help: usage names .env.generated (#879)" {
  run bash "${SETUP_SH}" --help
  assert_success
  assert_output --partial "Regenerate .env.generated + compose.yaml"
}

@test "setup.sh set: the next hint names .env.generated (#879)" {
  local _repo="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${_repo}"
  run bash "${SETUP_SH}" set network.mode bridge --base-path "${_repo}"
  assert_success
  assert_output --partial "to regenerate .env.generated + compose.yaml"
}

@test "setup.sh add: the next hint names .env.generated (#879)" {
  local _repo="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${_repo}"
  run bash "${SETUP_SH}" add environment.env FOO=bar --base-path "${_repo}"
  assert_success
  assert_output --partial "to regenerate .env.generated + compose.yaml"
}

@test "setup.sh remove: the next hint names .env.generated (#879)" {
  local _repo="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${_repo}"
  run bash "${SETUP_SH}" set network.mode bridge --base-path "${_repo}"
  assert_success
  run bash "${SETUP_SH}" remove network.mode --base-path "${_repo}"
  assert_success
  assert_output --partial "to regenerate .env.generated + compose.yaml"
}

# ════════════════════════════════════════════════════════════════════
# apply's completion line (_setup_msg env done) -- all four locales
# ════════════════════════════════════════════════════════════════════

@test "setup.sh env done message names .env.generated in all four locales (#879)" {
  local _lang
  for _lang in en zh-TW zh-CN ja; do
    run bash -c "_LANG='${_lang}'; source '${SETUP_SH}' 2>/dev/null; _LANG='${_lang}'; _setup_msg env done"
    assert_success
    assert_output --partial ".env.generated"
  done
}

# ════════════════════════════════════════════════════════════════════
# Cross-surface guard: no shipped surface claims `.env` is regenerated
# ════════════════════════════════════════════════════════════════════

# The surfaces a user actually reads. Kept as an explicit list rather than a
# tree walk so a new surface is a deliberate addition, not an accident.
_claim_surfaces() {
  cat <<'EOF'
/source/dist/.setup.conf
/source/dist/script/docker/justfile.docker
/source/dist/script/docker/lib/help.sh
/source/dist/script/docker/lib/setup_cmd.sh
/source/dist/script/docker/lib/wrapper.sh
/source/dist/script/docker/wrapper/build.sh
/source/dist/script/docker/wrapper/run.sh
/source/dist/script/docker/wrapper/setup.sh
/source/dist/script/docker/wrapper/setup_tui.sh
EOF
}

@test "no shipped surface claims setup regenerates a bare .env (#879)" {
  # Two claim shapes, matched deliberately narrowly so a legitimate sentence
  # that merely mentions both `.env` and a regenerate verb (the TUI's
  # workload-env info page says apply does NOT touch `.env`) is not a hit:
  #   1. verb-first (en / zh-TW / zh-CN): "Regenerate .env", "重新產生 .env"
  #   2. object-first (ja): ".env + compose.yaml を再生成"
  # `\.env([^.[:alnum:]]|$)` excludes the qualified `.env.generated` /
  # `.env.bak` names, so only a bare `.env` is the wrong claim.
  local _bad_claim
  _bad_claim='(egenerate|egenerates|egenerating|重新產生|重新生成|再產生)[[:space:]]+\.env([^.[:alnum:]]|$)'
  _bad_claim+='|\.env([^.[:alnum:]]|$)[^。]{0,25}再生成'
  local _file _hits=""
  while IFS= read -r _file; do
    local _out=""
    _out="$(grep -nE "${_bad_claim}" "${_file}" || true)"
    if [[ -n "${_out}" ]]; then
      _hits+="${_file}"$'\n'"${_out}"$'\n'
    fi
  done < <(_claim_surfaces)
  [[ -z "${_hits}" ]] || {
    printf 'surfaces still claiming a bare .env is regenerated:\n%s\n' "${_hits}" >&2
    return 1
  }
}
