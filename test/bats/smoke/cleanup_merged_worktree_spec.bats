#!/usr/bin/env bats
#
# Behavioral guard for script/git/cleanup-merged-worktree.sh (#368).
#
# Hermetic: a throwaway repo (bare "origin" + a clone as the main checkout +
# a sibling worktree/ directory) is built inside BATS_TEST_TMPDIR, and `gh`
# is a stub that prints a canned tab-separated "state<TAB>branch<TAB>oid"
# line. Nothing touches a real repo or worktree. No docker, no network.
#
# Baked into /smoke_test/ next to the script by the devel-test stage.

bats_require_minimum_version 1.5.0

setup() {
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

  ROOT="${BATS_TEST_TMPDIR}"
  git init -q --bare -b main "${ROOT}/origin.git"
  git clone -q "${ROOT}/origin.git" "${ROOT}/repo/src" 2>/dev/null
  git -C "${ROOT}/repo/src" checkout -q -b main
  echo base >"${ROOT}/repo/src/f.txt"
  git -C "${ROOT}/repo/src" add f.txt
  git -C "${ROOT}/repo/src" commit -q -m base
  git -C "${ROOT}/repo/src" push -q origin main
  git -C "${ROOT}/repo/src" remote set-head origin main

  MAIN="${ROOT}/repo/src"
  WT="${ROOT}/repo/worktree/feat-x"
  git -C "${MAIN}" worktree add -q "${WT}" -b feat/x main
  echo work >"${WT}/g.txt"
  git -C "${WT}" add g.txt
  git -C "${WT}" commit -q -m work
  git -C "${WT}" push -q origin feat/x
  OID="$(git -C "${WT}" rev-parse HEAD)"

  # gh stub: `gh pr view N --json ... --jq ...` prints the canned line.
  STUB="${ROOT}/bin"
  mkdir -p "${STUB}"
  cat >"${STUB}/gh" <<'EOF'
#!/usr/bin/env bash
cat "${GH_STUB_OUT}"
EOF
  chmod +x "${STUB}/gh"
  export GH_STUB_OUT="${ROOT}/gh.out"
  export PATH="${STUB}:${PATH}"

  SCRIPT="${BATS_TEST_DIRNAME}/cleanup-merged-worktree.sh"
}

gh_says() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >"${GH_STUB_OUT}"; }

@test "cleanup: dirty worktree -> SKIP dirty, nothing removed" {
  gh_says MERGED feat/x "${OID}"
  echo wip >>"${WT}/g.txt"
  run bash -c "cd '${MAIN}' && '${SCRIPT}' 7"
  [ "${status}" -eq 0 ]
  [ "${output}" = "SKIP dirty" ]
  [ -d "${WT}" ]
  [ -n "$(git -C "${MAIN}" branch --list feat/x)" ]
}

@test "cleanup: untracked file also counts as dirty" {
  gh_says MERGED feat/x "${OID}"
  echo new >"${WT}/untracked.txt"
  run bash -c "cd '${MAIN}' && '${SCRIPT}' 7"
  [ "${status}" -eq 0 ]
  [ "${output}" = "SKIP dirty" ]
  [ -d "${WT}" ]
}

@test "cleanup: unpushed commit -> SKIP unpushed, nothing removed" {
  gh_says MERGED feat/x "${OID}"
  echo more >"${WT}/h.txt"
  git -C "${WT}" add h.txt
  git -C "${WT}" commit -q -m local-only
  run bash -c "cd '${MAIN}' && '${SCRIPT}' 7"
  [ "${status}" -eq 0 ]
  [ "${output}" = "SKIP unpushed" ]
  [ -d "${WT}" ]
  [ -n "$(git -C "${MAIN}" branch --list feat/x)" ]
}

@test "cleanup: PR not merged -> SKIP not-merged, nothing removed" {
  gh_says OPEN feat/x "${OID}"
  run bash -c "cd '${MAIN}' && '${SCRIPT}' 7"
  [ "${status}" -eq 0 ]
  [ "${output}" = "SKIP not-merged" ]
  [ -d "${WT}" ]
  [ -n "$(git -C "${MAIN}" branch --list feat/x)" ]
}

@test "cleanup: all checks pass -> worktree and branch removed, removed=1" {
  gh_says MERGED feat/x "${OID}"
  run bash -c "cd '${MAIN}' && '${SCRIPT}' 7"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"removed=1"* ]]
  [ ! -e "${WT}" ]
  [ -z "$(git -C "${MAIN}" branch --list feat/x)" ]
  run git -C "${MAIN}" worktree list
  [[ "${output}" != *"feat-x"* ]]
}

@test "cleanup: root-owned files -> SKIP root-owned files + fix command, nothing else removed" {
  gh_says MERGED feat/x "${OID}"
  # Shadow git so `worktree remove` fails the way root-owned files make it
  # fail; every other subcommand goes to the real git.
  REAL_GIT="$(command -v git)"
  cat >"${STUB}/git" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-C" ]]; then a=("\${@:3}"); else a=("\$@"); fi
if [[ "\${a[0]}" == "worktree" && "\${a[1]}" == "remove" ]]; then
  echo "error: failed to delete '${WT}/x': Permission denied" >&2
  exit 1
fi
exec "${REAL_GIT}" "\$@"
EOF
  chmod +x "${STUB}/git"
  run bash -c "cd '${MAIN}' && '${SCRIPT}' 7"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"SKIP root-owned files"* ]]
  [[ "${output}" == *"chown -R"* ]]
  [ -d "${WT}" ]
  [ -n "$("${REAL_GIT}" -C "${MAIN}" branch --list feat/x)" ]
}

@test "cleanup: worktree outside the worktree root -> SKIP outside-worktree-root" {
  gh_says MERGED feat/x "${OID}"
  git -C "${MAIN}" worktree remove "${WT}"
  OUT="${ROOT}/elsewhere/feat-x"
  git -C "${MAIN}" worktree add -q "${OUT}" feat/x
  run bash -c "cd '${MAIN}' && '${SCRIPT}' 7"
  [ "${status}" -eq 0 ]
  [ "${output}" = "SKIP outside-worktree-root" ]
  [ -d "${OUT}" ]
}

@test "cleanup: no PR number -> usage, exit 2" {
  run bash -c "cd '${MAIN}' && '${SCRIPT}'"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"Usage"* ]]
}
