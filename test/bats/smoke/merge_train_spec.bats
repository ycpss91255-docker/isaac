#!/usr/bin/env bats
# bats file_tags=core
#
# Behavioral guard for script/git/merge-train.sh (#368).
#
# Hermetic: `gh` is a stub (canned `pr view` lines from a sequence file,
# `gh pr merge` recorded), `sleep` is a no-op, and the cleanup script is a
# stub that records its arguments. No docker, no network.
#
# Baked into /smoke_test/ next to the script by the devel-test stage.

bats_require_minimum_version 1.5.0

setup() {
  T="${BATS_TEST_TMPDIR}"
  mkdir -p "${T}/bin"
  export GH_LOG="${T}/gh.log" CLEANUP_LOG="${T}/cleanup.log"
  export GH_SEQ="${T}/seq"
  : >"${GH_LOG}"
  : >"${CLEANUP_LOG}"

  # `gh pr view` pops the next canned line (the last one repeats);
  # `gh api` answers the allow_squash_merge probe; `gh pr merge` is logged.
  cat >"${T}/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    line="$(head -n1 "${GH_SEQ}")"
    [[ "$(wc -l <"${GH_SEQ}")" -le 1 ]] || sed -i 1d "${GH_SEQ}"
    echo "${line}" ;;
  "pr merge") echo "$*" >>"${GH_LOG}"; exit "${GH_MERGE_RC:-0}" ;;
  api*|"api "*) echo "${GH_SQUASH:-true}" ;;
  *) echo "$*" >>"${GH_LOG}" ;;
esac
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' >"${T}/bin/sleep"
  cat >"${T}/cleanup.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${CLEANUP_LOG}"
echo "SKIP stub"
exit 0
EOF
  chmod +x "${T}/bin/"* "${T}/cleanup.sh"
  export PATH="${T}/bin:${PATH}"
  export CLEANUP_SCRIPT="${T}/cleanup.sh"
  SCRIPT="${BATS_TEST_DIRNAME}/merge-train.sh"
}

# seq <line>...: each line is state|mergeStateStatus|required|other
seq_lines() { printf '%s\n' "$@" >"${GH_SEQ}"; }

@test "merge-train: cleanup runs once with the PR number after its own merge" {
  seq_lines 'OPEN|CLEAN|SUCCESS,SUCCESS|' 'MERGED|||'
  run "${SCRIPT}" 1
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"PR1: MERGED"* ]]
  [[ "${output}" == *"ALL_DONE"* ]]
  [ "$(wc -l <"${CLEANUP_LOG}")" -eq 1 ]
  [ "$(cat "${CLEANUP_LOG}")" = "1" ]
}

@test "merge-train: a PR already MERGED at start is not cleaned up" {
  seq_lines 'MERGED|||'
  run "${SCRIPT}" 1
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"PR1: MERGED"* ]]
  [ ! -s "${CLEANUP_LOG}" ]
  [ ! -s "${GH_LOG}" ]
}

@test "merge-train: gh merge error but PR ends MERGED still triggers cleanup once" {
  seq_lines 'OPEN|CLEAN|SUCCESS,SUCCESS|' 'MERGED|||'
  GH_MERGE_RC=1 run "${SCRIPT}" 1
  [ "${status}" -eq 0 ]
  [ "$(cat "${CLEANUP_LOG}")" = "1" ]
}

@test "merge-train: cleanup SKIP does not change the exit code; each merged PR is cleaned" {
  seq_lines 'OPEN|CLEAN|SUCCESS,SUCCESS|' 'MERGED|||' 'OPEN|CLEAN|SUCCESS,SUCCESS|' 'MERGED|||'
  run "${SCRIPT}" 1 2
  [ "${status}" -eq 0 ]
  [ "$(cat "${CLEANUP_LOG}")" = "$(printf '1\n2')" ]
}

@test "merge-train: a failing required check stops with FAIL and no cleanup" {
  seq_lines 'OPEN|BLOCKED|FAILURE,SUCCESS|'
  run "${SCRIPT}" 1
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"PR1: FAIL"* ]]
  [ ! -s "${CLEANUP_LOG}" ]
}

@test "merge-train: merge method comes from the repo setting (squash allowed)" {
  seq_lines 'OPEN|CLEAN|SUCCESS,SUCCESS|' 'MERGED|||'
  run "${SCRIPT}" 1
  grep -q -e "--squash" "${GH_LOG}"
}

@test "merge-train: merge method falls back to a merge commit when squash is off" {
  seq_lines 'OPEN|CLEAN|SUCCESS,SUCCESS|' 'MERGED|||'
  GH_SQUASH=false run "${SCRIPT}" 1
  grep -q -e "--merge" "${GH_LOG}"
  ! grep -q -e "--squash" "${GH_LOG}"
}

@test "merge-train: the script source never hard-codes the squash flag" {
  run grep -n -e "--squash" "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}
