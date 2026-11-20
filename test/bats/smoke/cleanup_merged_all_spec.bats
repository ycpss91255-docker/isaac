#!/usr/bin/env bats
# bats file_tags=core
#
# Behavioral guard for script/git/cleanup-merged-all.sh, the script behind
# `just cleanup-merged` (#368).
#
# Hermetic: a throwaway repo (bare origin + clone + sibling worktree/ dir) is
# built in BATS_TEST_TMPDIR; `gh` is a stub that answers
#   gh pr list --head <branch> ...  from  <tmp>/prs/<branch with / as _>
#   gh pr view <n> ...              from  <tmp>/view/<n>
# No docker, no network, no real worktree is touched.
#
# Baked into /smoke_test/ next to the scripts by the devel-test stage.

bats_require_minimum_version 1.5.0

setup() {
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

  T="${BATS_TEST_TMPDIR}"
  git init -q --bare -b main "${T}/origin.git"
  git clone -q "${T}/origin.git" "${T}/repo/src" 2>/dev/null
  MAIN="${T}/repo/src"
  git -C "${MAIN}" checkout -q -b main
  echo base >"${MAIN}/f.txt"
  git -C "${MAIN}" add f.txt
  git -C "${MAIN}" commit -q -m base
  git -C "${MAIN}" push -q origin main
  git -C "${MAIN}" remote set-head origin main

  mkdir -p "${T}/bin" "${T}/prs" "${T}/view"
  cat >"${T}/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr list")
    for ((i = 1; i <= $#; i++)); do
      [[ "${!i}" == "--head" ]] && { j=$((i + 1)); b="${!j}"; }
    done
    f="${GH_STUB_DIR}/prs/${b//\//_}"
    [[ -f "${f}" ]] && cat "${f}"
    exit 0 ;;
  "pr view") cat "${GH_STUB_DIR}/view/$3" ;;
esac
EOF
  chmod +x "${T}/bin/gh"
  export GH_STUB_DIR="${T}"
  export PATH="${T}/bin:${PATH}"
  SCRIPT="${BATS_TEST_DIRNAME}/cleanup-merged-all.sh"
}

# add_wt <name> <pr> <state>: worktree <name> on branch feat/<name>, pushed,
# with PR <pr> in <state> as far as the gh stub is concerned.
add_wt() {
  local name="$1" pr="$2" state="$3"
  local wt="${T}/repo/worktree/${name}"
  git -C "${MAIN}" worktree add -q "${wt}" -b "feat/${name}" main
  echo "${name}" >"${wt}/${name}.txt"
  git -C "${wt}" add .
  git -C "${wt}" commit -q -m "${name}"
  git -C "${wt}" push -q origin "feat/${name}"
  printf '%s\n' "${pr}" >"${T}/prs/feat_${name}"
  printf '%s\t%s\t%s\n' "${state}" "feat/${name}" \
    "$(git -C "${wt}" rev-parse HEAD)" >"${T}/view/${pr}"
}

@test "cleanup-merged-all: removes merged worktrees, skips the rest, prints summary" {
  add_wt a 11 MERGED
  add_wt b 12 MERGED
  echo wip >>"${T}/repo/worktree/b/b.txt"
  add_wt c 13 OPEN
  run bash -c "cd '${MAIN}' && '${SCRIPT}'"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"removed=1 skipped=2"* ]]
  [ ! -e "${T}/repo/worktree/a" ]
  [ -d "${T}/repo/worktree/b" ]
  [ -d "${T}/repo/worktree/c" ]
  [ -z "$(git -C "${MAIN}" branch --list feat/a)" ]
}

@test "cleanup-merged-all: --dry-run removes nothing and still prints the summary" {
  add_wt a 11 MERGED
  add_wt c 13 OPEN
  run bash -c "cd '${MAIN}' && '${SCRIPT}' --dry-run"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"WOULD-REMOVE"* ]]
  [[ "${output}" == *"removed=0 skipped=1"* ]]
  [ -d "${T}/repo/worktree/a" ]
  [ -n "$(git -C "${MAIN}" branch --list feat/a)" ]
}

@test "cleanup-merged-all: one worktree failing does not abort the batch" {
  add_wt a 11 MERGED
  add_wt b 12 MERGED
  # Stub cleanup: crashes for PR 11, defers to the real script otherwise.
  cat >"${T}/cleanup-stub.sh" <<EOF
#!/usr/bin/env bash
[[ "\${@: -1}" == "11" ]] && { echo boom >&2; exit 3; }
exec "${BATS_TEST_DIRNAME}/cleanup-merged-worktree.sh" "\$@"
EOF
  chmod +x "${T}/cleanup-stub.sh"
  CLEANUP_SCRIPT="${T}/cleanup-stub.sh" run bash -c "cd '${MAIN}' && '${SCRIPT}'"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"removed=1 skipped=1"* ]]
  [ -d "${T}/repo/worktree/a" ]
  [ ! -e "${T}/repo/worktree/b" ]
}

@test "cleanup-merged-all: a worktree with no merged PR is skipped, not an error" {
  add_wt a 11 MERGED
  rm "${T}/prs/feat_a"
  run bash -c "cd '${MAIN}' && '${SCRIPT}'"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"removed=0 skipped=1"* ]]
  [ -d "${T}/repo/worktree/a" ]
}
