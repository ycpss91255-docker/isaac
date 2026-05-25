#!/usr/bin/env bats
#
# Integration tests for upgrade.sh end-to-end.
#
# Fixture: a bare "template" remote seeded with two tags (v0.9.5, v0.9.7) plus a
# "downstream" consumer repo that has template added as a subtree at v0.9.5.
# Tests drive the real upgrade.sh against this fake remote and assert on
# the resulting working tree + git state.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  UPGRADE="/source/upgrade.sh"

  TMPL_WORK="${BATS_TEST_TMPDIR}/template_work"
  TMPL_BARE="${BATS_TEST_TMPDIR}/template.git"
  DOWN_DIR="${BATS_TEST_TMPDIR}/downstream"

  _seed_template_remote
  _seed_downstream_repo
}

# ── Fixture helpers ─────────────────────────────────────────────────────────

# _seed_template_remote
#   Build a tiny template layout matching what upgrade.sh's post-flight
#   checks look for (markers: .base/.version, .base/init.sh,
#   .base/script/docker/setup.sh), wrap two tagged versions around it,
#   and push to a bare repo we can treat as TEMPLATE_REMOTE.
_seed_template_remote() {
  mkdir -p "${TMPL_WORK}/script/docker"
  git -C "${TMPL_WORK}" init -q -b main
  git -C "${TMPL_WORK}" config user.email t@t
  git -C "${TMPL_WORK}" config user.name t

  # v0.9.5: baseline subtree content. Use the real upgrade.sh under test so
  # the downstream repo (which invokes ./.base/upgrade.sh) runs the
  # same code these tests validate.
  echo "v0.9.5" > "${TMPL_WORK}/.version"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${TMPL_WORK}/init.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${TMPL_WORK}/script/docker/setup.sh"
  cp "${UPGRADE}" "${TMPL_WORK}/upgrade.sh"
  # upgrade.sh sources _lib.sh on load (#278: _log / _error wrap _log_*).
  # _lib.sh itself sources i18n.sh + lib/*.sh sub-libs (#284), so copy
  # all three surfaces into the fake remote.
  mkdir -p "${TMPL_WORK}/script/docker/lib"
  cp /source/script/docker/_lib.sh "${TMPL_WORK}/script/docker/_lib.sh"
  cp /source/script/docker/i18n.sh "${TMPL_WORK}/script/docker/i18n.sh"
  cp /source/script/docker/lib/*.sh "${TMPL_WORK}/script/docker/lib/"
  chmod +x "${TMPL_WORK}/init.sh" "${TMPL_WORK}/script/docker/setup.sh" "${TMPL_WORK}/upgrade.sh"
  git -C "${TMPL_WORK}" add -A
  git -C "${TMPL_WORK}" commit -q -m "v0.9.5"
  git -C "${TMPL_WORK}" tag v0.9.5

  # v0.9.7: version bump + a new file (lets tests assert the new payload arrived).
  echo "v0.9.7" > "${TMPL_WORK}/.version"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${TMPL_WORK}/script/docker/new_script.sh"
  chmod +x "${TMPL_WORK}/script/docker/new_script.sh"
  git -C "${TMPL_WORK}" add -A
  git -C "${TMPL_WORK}" commit -q -m "v0.9.7"
  git -C "${TMPL_WORK}" tag v0.9.7

  git init --bare -q "${TMPL_BARE}"
  git -C "${TMPL_WORK}" push -q "${TMPL_BARE}" v0.9.5 v0.9.7 main
}

# _seed_downstream_repo
#   Simulate a consumer repo at the moment right after `git subtree add
#   --prefix=.base ... v0.9.5 --squash`: a committed README, a
#   main.yaml with @v0.9.5 references ready to be bumped, and .base/ as
#   a proper subtree.
_seed_downstream_repo() {
  mkdir -p "${DOWN_DIR}/.github/workflows"
  git -C "${DOWN_DIR}" init -q -b main
  git -C "${DOWN_DIR}" config user.email t@t
  git -C "${DOWN_DIR}" config user.name t

  echo "DOWNSTREAM" > "${DOWN_DIR}/README.md"
  cat > "${DOWN_DIR}/.github/workflows/main.yaml" <<'YAML'
jobs:
  build:
    uses: ycpss91255-docker/base/.github/workflows/build-worker.yaml@v0.9.5
  release:
    uses: ycpss91255-docker/base/.github/workflows/release-worker.yaml@v0.9.5
YAML
  git -C "${DOWN_DIR}" add -A
  git -C "${DOWN_DIR}" commit -q -m "initial downstream"

  git -C "${DOWN_DIR}" subtree add -q --prefix=.base \
    "file://${TMPL_BARE}" v0.9.5 --squash
}

# ── Happy path ──────────────────────────────────────────────────────────────

@test "upgrade.sh v0.9.7: bumps .base/.version, pulls new content, updates main.yaml" {
  cd "${DOWN_DIR}"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/upgrade.sh v0.9.7
  assert_success
  assert_output --partial "Upgrading: v0.9.5 → v0.9.7"
  assert_output --partial "Done! Upgraded to v0.9.7"

  # Version bumped
  [ "$(cat .base/.version)" = "v0.9.7" ]
  # New file from v0.9.7 arrived under the subtree prefix
  [ -f ".base/script/docker/new_script.sh" ]
  # main.yaml @tag references bumped to v0.9.7
  grep -Fq "build-worker.yaml@v0.9.7" .github/workflows/main.yaml
  grep -Fq "release-worker.yaml@v0.9.7" .github/workflows/main.yaml
  # README.md and other downstream content untouched
  [ "$(cat README.md)" = "DOWNSTREAM" ]
}

@test "upgrade.sh patches Dockerfile lint stage when missing COPY .base/script/docker/lib /lint/lib (#348)" {
  cd "${DOWN_DIR}"
  cat > Dockerfile <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/*.sh /lint/
RUN shellcheck -S warning /lint/*.sh
EOF
  git add Dockerfile
  git commit -q -m "add Dockerfile"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/upgrade.sh v0.9.7
  assert_success
  assert_output --partial "Dockerfile patched"

  grep -Fq "COPY .base/script/docker/lib /lint/lib" Dockerfile
  grep -Fq "RUN shellcheck -S warning /lint/*.sh /lint/lib/*.sh" Dockerfile
}

@test "upgrade.sh is idempotent on Dockerfile already containing the lib COPY line (#348)" {
  cd "${DOWN_DIR}"
  cat > Dockerfile <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/*.sh /lint/
COPY .base/script/docker/lib /lint/lib
RUN shellcheck -S warning /lint/*.sh /lint/lib/*.sh
EOF
  git add Dockerfile
  git commit -q -m "add Dockerfile (already patched)"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/upgrade.sh v0.9.7
  assert_success
  assert_output --partial "already copies .base/script/docker/lib"
  refute_output --partial "Dockerfile patched"

  # Single COPY line, no duplicate insertion.
  [ "$(grep -c 'COPY .base/script/docker/lib /lint/lib' Dockerfile)" = "1" ]
}

@test "upgrade.sh warns + skips Dockerfile patch when stock shellcheck anchor is missing (#348)" {
  cd "${DOWN_DIR}"
  cat > Dockerfile <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/*.sh /lint/
RUN echo "custom Dockerfile lint setup"
EOF
  git add Dockerfile
  git commit -q -m "add custom Dockerfile"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/upgrade.sh v0.9.7
  assert_success
  assert_output --partial "lacks stock 'RUN shellcheck -S warning /lint/*.sh' anchor"
  refute_output --partial "Dockerfile patched"

  ! grep -q "COPY .base/script/docker/lib /lint/lib" Dockerfile
}

@test "upgrade.sh continues cleanly when no Dockerfile at repo root (#348)" {
  cd "${DOWN_DIR}"
  # Default _seed_downstream_repo fixture leaves no Dockerfile at root —
  # exercise the early-return branch.
  [ ! -f Dockerfile ]

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/upgrade.sh v0.9.7
  assert_success
  assert_output --partial "no Dockerfile at repo root"
}

@test "upgrade.sh v0.9.7 is idempotent on a second run" {
  cd "${DOWN_DIR}"

  env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/upgrade.sh v0.9.7 >/dev/null

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/upgrade.sh v0.9.7
  assert_success
  assert_output --partial "Already at v0.9.7"
  [ "$(cat .base/.version)" = "v0.9.7" ]
}

@test "upgrade.sh --check reports update available from v0.9.5 → v0.9.7" {
  cd "${DOWN_DIR}"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/upgrade.sh --check
  # _check exits 1 when an update is available (documented contract).
  assert_failure
  assert_output --partial "Local:  v0.9.5"
  assert_output --partial "Latest: v0.9.7"
  assert_output --partial "Update available"
}

@test "make upgrade-check (downstream Makefile): exit 0 when update available (#175)" {
  # Regression #175: the Makefile recipe wraps upgrade.sh so make doesn't
  # mistake exit 1 (update available) for a build failure. The downstream
  # Makefile is symlinked into every consumer repo via init.sh; copy it
  # here because the seeded subtree fixture omits the Makefile (only the
  # markers upgrade.sh's post-flight check needs are seeded).
  cd "${DOWN_DIR}"
  cp /source/script/docker/Makefile Makefile

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" make upgrade-check
  assert_success
  assert_output --partial "Local:  v0.9.5"
  assert_output --partial "Latest: v0.9.7"
  assert_output --partial "Update available"
  refute_output --partial "Error 1"
}

@test "make upgrade-check (downstream Makefile): exit 0 when up-to-date" {
  cd "${DOWN_DIR}"
  cp /source/script/docker/Makefile Makefile

  env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/upgrade.sh v0.9.7 >/dev/null

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" make upgrade-check
  assert_success
  assert_output --partial "Already up to date."
}

# ── Pre-flight guards ───────────────────────────────────────────────────────

@test "upgrade.sh fails fast when git identity is missing" {
  cd "${DOWN_DIR}"

  # Strip both repo-local and inherited identity so git config resolves empty.
  git config --unset user.email
  git config --unset user.name

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      HOME="${BATS_TEST_TMPDIR}" \
      GIT_CONFIG_GLOBAL=/dev/null \
      GIT_CONFIG_SYSTEM=/dev/null \
      ./.base/upgrade.sh v0.9.7
  assert_failure
  assert_output --partial "git identity not configured"
  # Pre-flight aborted before subtree pull ran.
  [ "$(cat .base/.version)" = "v0.9.5" ]
}

@test "upgrade.sh fails fast when MERGE_HEAD is present" {
  cd "${DOWN_DIR}"
  touch .git/MERGE_HEAD

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/upgrade.sh v0.9.7
  assert_failure
  assert_output --partial "MERGE_HEAD present"
  [ "$(cat .base/.version)" = "v0.9.5" ]
}

# ── Rollback on destructive subtree pull ────────────────────────────────────

@test "upgrade.sh rolls back when git-subtree does a destructive fast-forward" {
  cd "${DOWN_DIR}"

  # Install a git-subtree stub that simulates the Jetson v0.9.7 failure
  # mode: fetches the tag, then hard-resets HEAD to FETCH_HEAD (which
  # has template content at REPO ROOT, not under .base/). The
  # resulting working tree loses .base/.version and template-prefixed
  # files.
  #
  # `git subtree` resolves via GIT_EXEC_PATH (default /usr/lib/git-core),
  # NOT PATH, so a plain PATH-prepended stub is ignored. We point
  # GIT_EXEC_PATH at our stub dir; the stub forwards non-`pull`
  # subcommands back to the distro location for any incidental use.
  local _stub_dir="${BATS_TEST_TMPDIR}/stub_bin"
  mkdir -p "${_stub_dir}"
  cat > "${_stub_dir}/git-subtree" <<'STUB'
#!/usr/bin/env bash
# Forward everything except `pull` to the real git-subtree. Relies on
# /usr/lib/git-core/git-subtree being present; if the distro places it
# elsewhere, the test will need to be adjusted.
if [[ "$1" != "pull" ]]; then
  exec /usr/lib/git-core/git-subtree "$@"
fi
shift
_remote=""
_ref=""
while (( $# )); do
  case "$1" in
    --prefix=*) shift ;;
    --squash) shift ;;
    -m) shift 2 ;;
    file://*|https://*|git@*) _remote="$1"; shift ;;
    v*) _ref="$1"; shift ;;
    *) shift ;;
  esac
done
git fetch "${_remote}" "${_ref}" >/dev/null 2>&1
git reset --hard FETCH_HEAD >/dev/null 2>&1
STUB
  chmod +x "${_stub_dir}/git-subtree"

  local _pre_head
  _pre_head="$(git rev-parse HEAD)"

  run env GIT_EXEC_PATH="${_stub_dir}" \
      TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/upgrade.sh v0.9.7

  assert_failure
  assert_output --partial "integrity check failed"
  assert_output --partial ".base/.version"
  assert_output --partial "Rolling back"
  assert_output --partial "upgrade aborted"

  # Post-condition: repo restored. HEAD back to pre-pull, subtree markers
  # present, version still v0.9.5 — the user's working copy is usable.
  [ "$(git rev-parse HEAD)" = "${_pre_head}" ]
  [ -f ".base/.version" ]
  [ "$(cat .base/.version)" = "v0.9.5" ]
  [ -f ".base/script/docker/setup.sh" ]
  [ -f "README.md" ]
}
