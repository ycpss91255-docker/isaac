#!/usr/bin/env bats
#
# Unit tests for dist/script/docker/lib/transcript.lnav-format.json.
#
# A regex-type lnav format for the plain-text wrapper transcript
# (`<ISO ts> [service] LEVEL: msg`,), coexisting with the JSON
# log.lnav-format.json (*.jsonl). The CI image has no jq/lnav, so the
# format is checked structurally (grep) + functionally: the embedded
# regex (extracted + JSON-unescaped) must match real transcript lines and
# the 5 levels via `grep -P` (PCRE, same engine class lnav uses).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  FMT="/source/dist/script/docker/lib/transcript.lnav-format.json"
  [[ -f "${FMT}" ]] || skip "transcript.lnav-format.json not at expected path"
}

# Extract the regex pattern and JSON-unescape it (\\ -> \) for grep -P.
_fmt_pattern() {
  grep '"pattern"' "${FMT}" \
    | sed -e 's/^[[:space:]]*"pattern": "//' -e 's/"$//' -e 's/\\\\/\\/g'
}

@test "transcript.lnav-format.json: declares the lnav format schema + format key (#609)" {
  run grep -F 'lnav.org/schemas/format-v1.schema.json' "${FMT}"
  assert_success
  run grep -F 'ycpss91255_wrapper_transcript' "${FMT}"
  assert_success
}

@test "transcript.lnav-format.json: is a regex format (not json) (#609)" {
  run grep -F '"regex"' "${FMT}"
  assert_success
  run grep -F '"pattern"' "${FMT}"
  assert_success
  # must NOT be a JSON format like log.lnav-format.json
  run grep -F '"json": true' "${FMT}"
  assert_failure
}

@test "transcript.lnav-format.json: maps all 5 levels (#609)" {
  for _kv in '"debug": "DEBUG"' '"info": "INFO"' '"warning": "WARN"' '"error": "ERROR"' '"fatal": "FATAL"'; do
    run grep -F "${_kv}" "${FMT}"
    assert_success
  done
}

@test "transcript.lnav-format.json: timestamp/level/body fields + log/ file-pattern wired (#609)" {
  run grep -F '"timestamp-field": "timestamp"' "${FMT}"
  assert_success
  run grep -F '"level-field": "level"' "${FMT}"
  assert_success
  run grep -F '"body-field": "body"' "${FMT}"
  assert_success
  run grep -E '"file-pattern":.*log/.*\\.log' "${FMT}"
  assert_success
}

@test "transcript.lnav-format.json: regex matches real transcript lines, all 5 levels (#609)" {
  local _pat
  _pat="$(_fmt_pattern)"
  [ -n "${_pat}" ]
  run grep -Pq "${_pat}" <<< "2026-06-18T10:11:12.123456Z [build] INFO : transcript_started verb=build"
  assert_success
  local _lvl
  for _lvl in DEBUG INFO WARN ERROR FATAL; do
    run grep -Pq "${_pat}" <<< "2026-06-18T10:11:12Z [run] ${_lvl} : some message"
    assert_success
  done
}

@test "transcript.lnav-format.json: a raw docker output line does NOT match (falls through as body) (#609)" {
  local _pat
  _pat="$(_fmt_pattern)"
  run grep -Pq "${_pat}" <<< " => [internal] load build definition from Dockerfile"
  assert_failure
}

@test "transcript.lnav-format.json: every declared sample line matches the pattern (#609)" {
  local _pat
  _pat="$(_fmt_pattern)"
  local -a _samples=()
  local _l
  while IFS= read -r _l; do
    _samples+=("${_l}")
  done < <(grep -oE '"line": "[^"]*"' "${FMT}" | sed -e 's/^"line": "//' -e 's/"$//')
  [ "${#_samples[@]}" -ge 1 ]
  for _l in "${_samples[@]}"; do
    run grep -Pq "${_pat}" <<< "${_l}"
    assert_success
  done
}

@test "log.lnav-format.json (JSON) still coexists unchanged (#609)" {
  run grep -q '"json": true' /source/dist/script/docker/lib/log.lnav-format.json
  assert_success
}
