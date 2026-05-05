#!/usr/bin/env bats
#
# Integration: .gitignore sync via init.sh (new + existing) and upgrade.sh.
#
# Issue #172. The lib functions are unit-tested in test/unit/gitignore_spec.bats;
# this spec wires them through the user-facing entry points and proves
# the v0.12.x → v0.12.4 batch upgrade will heal the 15-repo
# tracked-compose.yaml drift in one shot, no separate sweep required.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"

  TMP_ROOT="$(mktemp -d)"
  REPO_DIR="${TMP_ROOT}/myrepo"
  mkdir -p "${REPO_DIR}/template"
  cp -a /source/. "${REPO_DIR}/template/"
  cd "${REPO_DIR}"
}

teardown() {
  rm -rf "${TMP_ROOT}"
}

# ════════════════════════════════════════════════════════════════════
# init.sh new-repo path: .gitignore is created via lib (single source)
# ════════════════════════════════════════════════════════════════════

@test "init.sh new-repo: .gitignore contains all 7 canonical entries" {
  bash template/init.sh
  local _entry
  for _entry in .env .env.bak compose.yaml setup.conf.bak setup.conf.local coverage/ .Dockerfile.generated; do
    run grep -xF "${_entry}" "${REPO_DIR}/.gitignore"
    assert_success
  done
}

@test "init.sh new-repo: .gitignore has the 'managed by template' marker" {
  bash template/init.sh
  run grep -F 'managed by template' "${REPO_DIR}/.gitignore"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# init.sh existing-repo path: sync + untrack the 15-repo drift case
# ════════════════════════════════════════════════════════════════════

_seed_existing_repo() {
  # Mirror the v0.12.1-era 15-repo state: Dockerfile present (so init.sh
  # takes the existing-repo path), partial canonical .gitignore (`.env`
  # only) plus a user-defined entry, compose.yaml committed.
  echo "FROM alpine" > "${REPO_DIR}/Dockerfile"
  git -C "${REPO_DIR}" init -q -b main
  git -C "${REPO_DIR}" config user.email t@t
  git -C "${REPO_DIR}" config user.name t
  cat > "${REPO_DIR}/.gitignore" <<'EOF'
.env
.claude/
EOF
  echo "services: {}" > "${REPO_DIR}/compose.yaml"
  git -C "${REPO_DIR}" add -A
  git -C "${REPO_DIR}" commit -q -m "init"
}

@test "init.sh existing-repo: appends missing canonical entries to user .gitignore" {
  _seed_existing_repo
  bash template/init.sh

  # User entry preserved verbatim
  run grep -xF '.claude/' "${REPO_DIR}/.gitignore"
  assert_success
  # Pre-existing canonical entry preserved (no duplicate)
  run grep -c '^\.env$' "${REPO_DIR}/.gitignore"
  assert_output "1"
  # All previously-missing canonical entries now present
  run grep -xF 'compose.yaml' "${REPO_DIR}/.gitignore"
  assert_success
  run grep -xF '.env.bak' "${REPO_DIR}/.gitignore"
  assert_success
  run grep -xF 'setup.conf.bak' "${REPO_DIR}/.gitignore"
  assert_success
  run grep -xF 'coverage/' "${REPO_DIR}/.gitignore"
  assert_success
  run grep -xF '.Dockerfile.generated' "${REPO_DIR}/.gitignore"
  assert_success
}

@test "init.sh existing-repo: untracks compose.yaml that was committed" {
  _seed_existing_repo
  # Sanity: compose.yaml is tracked before init.sh runs
  run git -C "${REPO_DIR}" ls-files compose.yaml
  assert_output "compose.yaml"

  bash template/init.sh

  # No longer in index
  run git -C "${REPO_DIR}" ls-files compose.yaml
  assert_output ""
  # Still on disk — user's working copy untouched
  [[ -f "${REPO_DIR}/compose.yaml" ]]
}

@test "init.sh existing-repo: setup.conf stays committed across init runs (#201)" {
  # Post-#201: <repo>/setup.conf is the user's committed override.
  # init.sh must NOT untrack it on existing-repo init; .gitignore sync
  # must NOT add it.
  _seed_existing_repo
  cat > "${REPO_DIR}/setup.conf" <<'EOF'
[network]
mode = bridge
[volumes]
mount_1 = ${WS_PATH}:/home/${USER_NAME}/work
EOF
  git -C "${REPO_DIR}" add setup.conf
  git -C "${REPO_DIR}" commit -q -m "track setup.conf"

  bash template/init.sh

  # setup.conf still tracked by git
  run git -C "${REPO_DIR}" ls-files setup.conf
  assert_output "setup.conf"
  # Content unchanged
  run grep -F 'mode = bridge' "${REPO_DIR}/setup.conf"
  assert_success
  # Not in .gitignore
  run grep -E '^setup\.conf$' "${REPO_DIR}/.gitignore"
  assert_failure
}

@test "init.sh existing-repo: idempotent — second run produces no .gitignore changes" {
  _seed_existing_repo
  bash template/init.sh
  local _first
  _first="$(cat "${REPO_DIR}/.gitignore")"

  bash template/init.sh
  local _second
  _second="$(cat "${REPO_DIR}/.gitignore")"

  assert_equal "${_second}" "${_first}"
}

# ════════════════════════════════════════════════════════════════════
# upgrade.sh end-to-end: subtree pull → init.sh sync → single commit
# ════════════════════════════════════════════════════════════════════
#
# Standalone fixture (independent of upgrade_spec.bats's stub-init fixture)
# because gitignore sync requires the REAL init.sh to run during Step 3.

_seed_upgrade_fixture() {
  TMPL_WORK="${BATS_TEST_TMPDIR}/template_work"
  TMPL_BARE="${BATS_TEST_TMPDIR}/template.git"
  DOWN_DIR="${BATS_TEST_TMPDIR}/downstream"

  # Build a "template" snapshot containing the real init.sh + lib + a
  # passthrough setup.sh stub.
  mkdir -p "${TMPL_WORK}/script/docker/lib"
  echo "v9.0.0" > "${TMPL_WORK}/.version"
  cp /source/init.sh "${TMPL_WORK}/init.sh"
  cp /source/upgrade.sh "${TMPL_WORK}/upgrade.sh"
  cp /source/script/docker/lib/gitignore.sh "${TMPL_WORK}/script/docker/lib/gitignore.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${TMPL_WORK}/script/docker/setup.sh"
  # _create_symlinks references these paths; empty stubs keep ln -sf happy.
  for _f in build.sh run.sh exec.sh stop.sh setup_tui.sh Makefile; do
    : > "${TMPL_WORK}/script/docker/${_f}"
  done
  : > "${TMPL_WORK}/.hadolint.yaml"
  chmod +x "${TMPL_WORK}/init.sh" "${TMPL_WORK}/upgrade.sh" \
           "${TMPL_WORK}/script/docker/setup.sh"

  git -C "${TMPL_WORK}" init -q -b main
  git -C "${TMPL_WORK}" config user.email t@t
  git -C "${TMPL_WORK}" config user.name t
  git -C "${TMPL_WORK}" add -A
  git -C "${TMPL_WORK}" commit -q -m "v9.0.0"
  git -C "${TMPL_WORK}" tag v9.0.0

  # Bump to v9.0.1 (no real change beyond the version file — sufficient
  # to drive an upgrade run).
  echo "v9.0.1" > "${TMPL_WORK}/.version"
  git -C "${TMPL_WORK}" add -A
  git -C "${TMPL_WORK}" commit -q -m "v9.0.1"
  git -C "${TMPL_WORK}" tag v9.0.1

  git init --bare -q "${TMPL_BARE}"
  git -C "${TMPL_WORK}" push -q "${TMPL_BARE}" v9.0.0 v9.0.1 main

  # Downstream consumer: Dockerfile (so init.sh existing-repo path
  # fires), partial .gitignore, tracked compose.yaml, main.yaml with
  # @v9.0.0 references for the @tag rewrite step.
  mkdir -p "${DOWN_DIR}/.github/workflows"
  git -C "${DOWN_DIR}" init -q -b main
  git -C "${DOWN_DIR}" config user.email t@t
  git -C "${DOWN_DIR}" config user.name t
  echo "FROM alpine" > "${DOWN_DIR}/Dockerfile"
  echo "services: {}" > "${DOWN_DIR}/compose.yaml"
  cat > "${DOWN_DIR}/.gitignore" <<'EOF'
.env
.claude/
EOF
  cat > "${DOWN_DIR}/.github/workflows/main.yaml" <<'YAML'
jobs:
  build:
    uses: ycpss91255-docker/template/.github/workflows/build-worker.yaml@v9.0.0
  release:
    uses: ycpss91255-docker/template/.github/workflows/release-worker.yaml@v9.0.0
YAML
  git -C "${DOWN_DIR}" add -A
  git -C "${DOWN_DIR}" commit -q -m "initial"

  git -C "${DOWN_DIR}" subtree add -q --prefix=template \
    "file://${TMPL_BARE}" v9.0.0 --squash
}

@test "upgrade.sh end-to-end: synced .gitignore + untracked compose.yaml in single commit" {
  _seed_upgrade_fixture
  cd "${DOWN_DIR}"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./template/upgrade.sh v9.0.1
  assert_success
  assert_output --partial "Done! Upgraded to v9.0.1"

  # .gitignore now contains all canonical entries
  run grep -xF 'compose.yaml' "${DOWN_DIR}/.gitignore"
  assert_success
  run grep -xF '.env.bak' "${DOWN_DIR}/.gitignore"
  assert_success
  run grep -xF 'coverage/' "${DOWN_DIR}/.gitignore"
  assert_success
  # User .claude/ line preserved
  run grep -xF '.claude/' "${DOWN_DIR}/.gitignore"
  assert_success
  # compose.yaml untracked from index, file still on disk
  run git -C "${DOWN_DIR}" ls-files compose.yaml
  assert_output ""
  [[ -f "${DOWN_DIR}/compose.yaml" ]]

  # The .gitignore + index removal landed in the workflow @tag commit,
  # not as a stray uncommitted change. We only assert tracked-side
  # cleanliness — the first init.sh on this fixture also creates new
  # symlinks (build.sh, run.sh, ...) that show up as untracked, which
  # is expected and orthogonal to #172.
  run git -C "${DOWN_DIR}" diff --quiet HEAD
  assert_success
}

@test "upgrade.sh end-to-end: idempotent on a second run — no extra commits" {
  _seed_upgrade_fixture
  cd "${DOWN_DIR}"

  env TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./template/upgrade.sh v9.0.1 >/dev/null
  local _post_first
  _post_first="$(git -C "${DOWN_DIR}" rev-parse HEAD)"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./template/upgrade.sh v9.0.1
  assert_success
  assert_output --partial "Already at v9.0.1"

  local _post_second
  _post_second="$(git -C "${DOWN_DIR}" rev-parse HEAD)"
  assert_equal "${_post_second}" "${_post_first}"
}
