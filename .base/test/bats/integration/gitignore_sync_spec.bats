#!/usr/bin/env bats
#
# Integration: .gitignore sync via init.sh (new + existing) and upgrade.sh.
#
# The lib functions are unit-tested in test/unit/gitignore_spec.bats;
# this spec wires them through the user-facing entry points and proves
# the v0.12.x → v0.12.4 batch upgrade will heal the 15-repo
# tracked-compose.yaml drift in one shot, no separate sweep required.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"

  TMP_ROOT="$(mktemp -d)"
  REPO_DIR="${TMP_ROOT}/myrepo"
  mkdir -p "${REPO_DIR}/.base"
  cp -a /source/. "${REPO_DIR}/.base/"
  # A real vendored subtree never carries `.git`; `cp -a /source/.` copies
  # the source checkout's `.git`, which the self-run guard (ADR-00000011
  # sec.8) reads as "this is the base source". Strip it so the fixture
  # matches a genuine `.base/` subtree.
  rm -rf "${REPO_DIR}/.base/.git"
  cd "${REPO_DIR}"
}

teardown() {
  rm -rf "${TMP_ROOT}"
}

# ════════════════════════════════════════════════════════════════════
# init.sh new-repo path: .gitignore is created via lib (single source)
# ════════════════════════════════════════════════════════════════════

@test "init.sh new-repo: .gitignore contains all canonical entries (#507: runtime.env retired)" {
  bash .base/dist/script/base/init.sh
  local _entry
  for _entry in .env .env.generated .env.bak compose.yaml .setup.conf.bak coverage/ .Dockerfile.generated; do
    run grep -xF "${_entry}" "${REPO_DIR}/.gitignore"
    assert_success
  done
}

@test "init.sh new-repo: .gitignore has the 'managed by template' marker" {
  bash .base/dist/script/base/init.sh
  run grep -F 'managed by template' "${REPO_DIR}/.gitignore"
  assert_success
}

@test "init.sh new-repo: .dockerignore contains all canonical derived entries (#604)" {
  bash .base/dist/script/base/init.sh
  assert [ -f "${REPO_DIR}/.dockerignore" ]
  local _entry
  for _entry in .env .env.generated .env.bak compose.yaml .setup.conf.bak coverage/ .Dockerfile.generated; do
    run grep -xF "${_entry}" "${REPO_DIR}/.dockerignore"
    assert_success
  done
}

@test "init.sh new-repo: .dockerignore has the 'managed by template' marker (#604)" {
  bash .base/dist/script/base/init.sh
  run grep -F 'managed by template' "${REPO_DIR}/.dockerignore"
  assert_success
}

@test "init.sh new-repo: log/ lands in BOTH the .gitignore and .dockerignore canonical sets (#606)" {
  bash .base/dist/script/base/init.sh
  run grep -xF 'log/' "${REPO_DIR}/.gitignore"
  assert_success
  run grep -xF 'log/' "${REPO_DIR}/.dockerignore"
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
  bash .base/dist/script/base/init.sh

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
  run grep -xF '.setup.conf.bak' "${REPO_DIR}/.gitignore"
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

  bash .base/dist/script/base/init.sh

  # No longer in index
  run git -C "${REPO_DIR}" ls-files compose.yaml
  assert_output ""
  # Still on disk — user's working copy untouched
  [[ -f "${REPO_DIR}/compose.yaml" ]]
}

@test "init.sh existing-repo: setup.conf stays committed across init runs (#201)" {
  # <repo>/.setup.conf is the user's committed override.
  # init.sh must NOT untrack it on existing-repo init; .gitignore sync
  # must NOT add it.
  _seed_existing_repo
  mkdir -p "${REPO_DIR}"
  cat > "${REPO_DIR}/.setup.conf" <<'EOF'
[network]
mode = bridge
[volumes]
mount_1 = ${WS_PATH}:/home/${USER_NAME}/work
EOF
  git -C "${REPO_DIR}" add .setup.conf
  git -C "${REPO_DIR}" commit -q -m "track setup.conf"

  bash .base/dist/script/base/init.sh

  # setup.conf still tracked by git
  run git -C "${REPO_DIR}" ls-files .setup.conf
  assert_output ".setup.conf"
  # Content unchanged
  run grep -F 'mode = bridge' "${REPO_DIR}/.setup.conf"
  assert_success
  # Not in .gitignore
  run grep -E '^setup\.conf$' "${REPO_DIR}/.gitignore"
  assert_failure
}

@test "init.sh existing-repo: idempotent — second run produces no .gitignore changes" {
  _seed_existing_repo
  bash .base/dist/script/base/init.sh
  local _first
  _first="$(cat "${REPO_DIR}/.gitignore")"

  bash .base/dist/script/base/init.sh
  local _second
  _second="$(cat "${REPO_DIR}/.gitignore")"

  assert_equal "${_second}" "${_first}"
}

@test "init.sh existing-repo: appends missing canonical entries to a user .dockerignore, preserving build-context lines (#604)" {
  _seed_existing_repo
  # User-authored .dockerignore with a hand-maintained build-context line
  # plus one already-present canonical entry.
  printf '%s\n' 'script/' '.env' > "${REPO_DIR}/.dockerignore"
  bash .base/dist/script/base/init.sh

  # Hand-maintained build-context line preserved
  run grep -xF 'script/' "${REPO_DIR}/.dockerignore"
  assert_success
  # Pre-existing canonical entry not duplicated
  run grep -c '^\.env$' "${REPO_DIR}/.dockerignore"
  assert_output "1"
  # Previously-missing canonical entries appended
  run grep -xF 'compose.yaml' "${REPO_DIR}/.dockerignore"
  assert_success
  run grep -xF 'coverage/' "${REPO_DIR}/.dockerignore"
  assert_success
}

@test "init.sh existing-repo: idempotent — second run produces no .dockerignore changes (#604)" {
  _seed_existing_repo
  printf '%s\n' 'script/' > "${REPO_DIR}/.dockerignore"
  bash .base/dist/script/base/init.sh
  local _first
  _first="$(cat "${REPO_DIR}/.dockerignore")"

  bash .base/dist/script/base/init.sh
  local _second
  _second="$(cat "${REPO_DIR}/.dockerignore")"

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
  # passthrough setup.sh stub. init.sh / upgrade.sh live deep at
  # dist/script/base/ and self-locate the subtree root via the
  # `.version` + `dist/` walk-up markers seeded here.
  mkdir -p "${TMPL_WORK}/dist/script/docker/lib" \
           "${TMPL_WORK}/dist/script/base"
  echo "v9.0.0" > "${TMPL_WORK}/.version"
  cp /source/dist/script/base/init.sh "${TMPL_WORK}/dist/script/base/init.sh"
  cp /source/dist/script/base/upgrade.sh "${TMPL_WORK}/dist/script/base/upgrade.sh"
  # Both source their sibling upstream.sh at load (the one definition of
  # the upstream slug / clone URL), so the snapshot ships it too.
  cp /source/dist/script/base/upstream.sh "${TMPL_WORK}/dist/script/base/upstream.sh"
  cp /source/dist/script/docker/lib/gitignore.sh "${TMPL_WORK}/dist/script/docker/lib/gitignore.sh"
  # init.sh / upgrade.sh source _lib.sh on load (route _log / _error
  # through _log_info / _log_err). _lib.sh sources i18n.sh + lib/*.sh
  # sub-libs, so copy all three surfaces.
  cp /source/dist/script/docker/lib/_lib.sh "${TMPL_WORK}/dist/script/docker/lib/_lib.sh"
  cp /source/dist/script/docker/lib/i18n.sh "${TMPL_WORK}/dist/script/docker/lib/i18n.sh"
  cp /source/dist/script/docker/lib/* "${TMPL_WORK}/dist/script/docker/lib/"
  mkdir -p "${TMPL_WORK}/dist/script/docker/wrapper"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${TMPL_WORK}/dist/script/docker/wrapper/setup.sh"
  # _create_symlinks references these paths; empty stubs keep ln -sf happy.
  for _f in build.sh run.sh exec.sh stop.sh setup_tui.sh; do
    : > "${TMPL_WORK}/dist/script/docker/wrapper/${_f}"
  done
  : > "${TMPL_WORK}/dist/script/justfile"
  : > "${TMPL_WORK}/dist/script/docker/justfile.docker"
  : > "${TMPL_WORK}/.hadolint.yaml"
  chmod +x "${TMPL_WORK}/dist/script/base/init.sh" \
           "${TMPL_WORK}/dist/script/base/upgrade.sh" \
           "${TMPL_WORK}/dist/script/docker/wrapper/setup.sh"

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
    uses: ycpss91255-docker/base/.github/workflows/build-worker.yaml@v9.0.0
  release:
    uses: ycpss91255-docker/base/.github/workflows/release-worker.yaml@v9.0.0
YAML
  git -C "${DOWN_DIR}" add -A
  git -C "${DOWN_DIR}" commit -q -m "initial"

  git -C "${DOWN_DIR}" subtree add -q --prefix=.base \
    "file://${TMPL_BARE}" v9.0.0 --squash
}

@test "upgrade.sh end-to-end: synced .gitignore + untracked compose.yaml in single commit" {
  _seed_upgrade_fixture
  cd "${DOWN_DIR}"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v9.0.1
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
  # is expected and orthogonal to
  run git -C "${DOWN_DIR}" diff --quiet HEAD
  assert_success
}

@test "upgrade.sh end-to-end: idempotent on a second run — no extra commits" {
  _seed_upgrade_fixture
  cd "${DOWN_DIR}"

  env TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v9.0.1 >/dev/null
  local _post_first
  _post_first="$(git -C "${DOWN_DIR}" rev-parse HEAD)"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v9.0.1
  assert_success
  assert_output --partial "Already at v9.0.1"

  local _post_second
  _post_second="$(git -C "${DOWN_DIR}" rev-parse HEAD)"
  assert_equal "${_post_second}" "${_post_first}"
}
