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
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  UPGRADE="/source/dist/script/base/upgrade.sh"

  TMPL_WORK="${BATS_TEST_TMPDIR}/template_work"
  TMPL_BARE="${BATS_TEST_TMPDIR}/template.git"
  DOWN_DIR="${BATS_TEST_TMPDIR}/downstream"

  _seed_template_remote
  _seed_downstream_repo
}

# ── Fixture helpers ─────────────────────────────────────────────────────────

# _seed_template_remote
#   Build a tiny template layout matching what upgrade.sh's post-flight
#   checks look for (markers: .base/.version,
#   .base/dist/script/base/init.sh,
#   .base/dist/script/docker/wrapper/setup.sh), wrap two tagged
#   versions around it, and push to a bare repo we can treat as
#   TEMPLATE_REMOTE. init.sh / upgrade.sh live deep at
#   dist/script/base/ and self-locate the subtree root by walking
#   up to the dir carrying `.version` + `dist/`.
_seed_template_remote() {
  mkdir -p "${TMPL_WORK}/dist/script/docker/wrapper" \
           "${TMPL_WORK}/dist/script/base"
  git -C "${TMPL_WORK}" init -q -b main
  git -C "${TMPL_WORK}" config user.email t@t
  git -C "${TMPL_WORK}" config user.name t

  # v0.9.5: baseline subtree content. Use the real upgrade.sh under test so
  # the downstream repo (which invokes
  # ./.base/dist/script/base/upgrade.sh) runs the same code these
  # tests validate. .version + dist/ at the subtree root are the
  # walk-up markers upgrade.sh self-locates from.
  echo "v0.9.5" > "${TMPL_WORK}/.version"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${TMPL_WORK}/dist/script/base/init.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${TMPL_WORK}/dist/script/docker/wrapper/setup.sh"
  cp "${UPGRADE}" "${TMPL_WORK}/dist/script/base/upgrade.sh"
  # upgrade.sh sources its sibling upstream.sh at load (the one definition
  # of the upstream slug / clone URL), so the fake remote ships it too.
  cp /source/dist/script/base/upstream.sh "${TMPL_WORK}/dist/script/base/upstream.sh"
  # upgrade.sh sources _lib.sh on load (_log / _error wrap _log_*).
  # _lib.sh itself sources i18n.sh + lib/*.sh sub-libs, so copy
  # all three surfaces into the fake remote.
  mkdir -p "${TMPL_WORK}/dist/script/docker/lib"
  cp /source/dist/script/docker/lib/_lib.sh "${TMPL_WORK}/dist/script/docker/lib/_lib.sh"
  cp /source/dist/script/docker/lib/i18n.sh "${TMPL_WORK}/dist/script/docker/lib/i18n.sh"
  cp /source/dist/script/docker/lib/* "${TMPL_WORK}/dist/script/docker/lib/"
  chmod +x "${TMPL_WORK}/dist/script/base/init.sh" \
           "${TMPL_WORK}/dist/script/docker/wrapper/setup.sh" \
           "${TMPL_WORK}/dist/script/base/upgrade.sh"
  git -C "${TMPL_WORK}" add -A
  git -C "${TMPL_WORK}" commit -q -m "v0.9.5"
  git -C "${TMPL_WORK}" tag v0.9.5

  # v0.9.7: version bump + a new file (lets tests assert the new payload arrived).
  echo "v0.9.7" > "${TMPL_WORK}/.version"
  mkdir -p "${TMPL_WORK}/script/docker"
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

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
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

# ── Step 5: declarative Dockerfile/entrypoint migrations ───────
# upgrade.sh Step 5 sources lib/dockerfile_migrate.sh and runs the
# apply_migrations dispatcher over the repo-root Dockerfile (and its sibling
# script/entrypoint.sh). These drive the real upgrade.sh end-to-end against
# the fake remote, confirming the migrations run, stage their changes, and
# stay idempotent.

@test "upgrade.sh Step 5 announces the migration pass (#567)" {
  cd "${DOWN_DIR}"
  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  assert_output --partial "Step 5/5: apply Dockerfile/entrypoint migrations (#567 / #579)"
}

@test "upgrade.sh heals a legacy wrapper-COPY Dockerfile via the migration list (#567 m1)" {
  cd "${DOWN_DIR}"
  cat > Dockerfile <<'EOF'
FROM busybox AS lint
COPY *.sh /lint/
RUN shellcheck -S warning /lint/*.sh
EOF
  git add Dockerfile
  git commit -q -m "add Dockerfile (legacy wrapper COPY)"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  grep -Fq "COPY .base/script/docker/wrapper/*.sh /lint/" Dockerfile
  ! grep -Eq '^[[:space:]]*COPY[[:space:]]+\*\.sh[[:space:]]+/lint/' Dockerfile
  # The rewritten Dockerfile is staged into the upgrade's commit.
  git diff --cached --quiet
}

@test "upgrade.sh nounset-guards a sibling entrypoint ROS source (#567 m8 / #579)" {
  cd "${DOWN_DIR}"
  : > Dockerfile  # presence-only; the dispatcher runs against the entrypoint
  mkdir -p script
  cat > script/entrypoint.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1090,SC1091
source "/opt/ros/${ROS_DISTRO}/setup.bash"
exec "$@"
EOF
  git add Dockerfile script/entrypoint.sh
  git commit -q -m "add Dockerfile + nounset-unsafe entrypoint"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  grep -Fxq "set +u" script/entrypoint.sh
  grep -Fxq "set -u" script/entrypoint.sh
}

@test "upgrade.sh Step 5 continues cleanly when no Dockerfile at repo root (#567)" {
  cd "${DOWN_DIR}"
  # Default _seed_downstream_repo fixture leaves no Dockerfile at root —
  # exercise the dispatcher's no-Dockerfile skip branch.
  [ ! -f Dockerfile ]

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  assert_output --partial "no Dockerfile"
}

@test "upgrade.sh migrations are idempotent — already-migrated Dockerfile unchanged (#567)" {
  cd "${DOWN_DIR}"
  cat > Dockerfile <<'EOF'
FROM busybox AS lint
COPY .base/script/docker/wrapper/*.sh /lint/
RUN shellcheck -S warning /lint/*.sh
EOF
  git add Dockerfile
  git commit -q -m "add Dockerfile (already migrated)"
  cp Dockerfile "${BATS_TEST_TMPDIR}/Dockerfile.orig"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  diff Dockerfile "${BATS_TEST_TMPDIR}/Dockerfile.orig"
}

@test "upgrade.sh v0.9.7 is idempotent on a second run" {
  cd "${DOWN_DIR}"

  env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7 >/dev/null

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  assert_output --partial "Already at v0.9.7"
  [ "$(cat .base/.version)" = "v0.9.7" ]
}

@test "upgrade.sh --check reports update available from v0.9.5 → v0.9.7" {
  cd "${DOWN_DIR}"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh --check
  # _check exits 1 when an update is available (documented contract).
  assert_failure
  assert_output --partial "Local:  v0.9.5"
  assert_output --partial "Latest: v0.9.7"
  assert_output --partial "Update available"
}

# Seed the layered consumer entry + docker module so `just docker
# upgrade-check` resolves like a real repo. The docker module pins recipes
# to the repo root via `set working-directory := '../..'` (relative to
# script/docker), so the entry must sit at the repo root and the module at
# script/docker/ -- a bare `cp justfile.docker justfile` would mis-resolve
# the working-directory. The seeded subtree fixture omits these files.
_seed_entry() {
  cp /source/dist/script/justfile justfile
  mkdir -p script/docker script/base
  cp /source/dist/script/docker/justfile.docker script/docker/justfile.docker
  cp /source/dist/script/base/justfile.base script/base/justfile.base
}

@test "just base update (downstream entry): exit 0 when update available (#175, #546, #652)" {
  # Regressionthe upgrade-check recipe wraps upgrade.sh so the
  # runner does not mistake exit 1 (update available) for a build failure.
  # Skips when `just` is not yet in the test-tools image (pre-release GHCR
  # pull) -- the guard keeps the suite green until test-tools ships just.
  command -v just >/dev/null 2>&1 || skip "just not installed in this test-tools image"
  cd "${DOWN_DIR}"
  _seed_entry

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" just base update
  assert_success
  assert_output --partial "Local:  v0.9.5"
  assert_output --partial "Latest: v0.9.7"
  assert_output --partial "Update available"
}

@test "just base update (downstream entry): exit 0 when up-to-date (#546)" {
  command -v just >/dev/null 2>&1 || skip "just not installed in this test-tools image"
  cd "${DOWN_DIR}"
  _seed_entry

  env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7 >/dev/null

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" just base update
  assert_success
  assert_output --partial "Already up to date."
}

# ── Legacy setup.conf auto-migration ────────────────────────────────
# setup.conf left the hand-editable config/ surface and now lives at the
# repo root as .setup.conf. upgrade.sh must relocate a downstream's
# legacy config/docker/setup.conf override so it is never silently
# dropped (fail-loud), and must leave a repo already at the new location
# untouched.

@test "upgrade.sh relocates a legacy config/docker/setup.conf override to repo-root .setup.conf, loudly" {
  cd "${DOWN_DIR}"
  mkdir -p config/docker
  printf '[gpu]\nmode = force\n' > config/docker/setup.conf
  git add config/docker/setup.conf
  git commit -q -m "add legacy setup.conf override"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  # Loud, unmissable migration announcement.
  assert_output --partial "relocating per-repo setup.conf override"
  assert_output --partial "config/docker/setup.conf -> .setup.conf"

  # Override relocated to the root dotfile, content preserved, legacy gone.
  [ -f ".setup.conf" ]
  [ ! -f "config/docker/setup.conf" ]
  grep -Fq "mode = force" .setup.conf

  # The relocation is committed, so the tree is clean afterwards (the
  # subsequent subtree pull would have refused a dirty tree otherwise).
  refute_output --partial "config/docker/setup.conf still present"
}

@test "upgrade.sh leaves a repo already at root .setup.conf untouched (no spurious migration)" {
  cd "${DOWN_DIR}"
  printf '[gpu]\nmode = force\n' > .setup.conf
  git add .setup.conf
  git commit -q -m "add root .setup.conf override"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  refute_output --partial "relocating per-repo setup.conf override"
  [ -f ".setup.conf" ]
  [ ! -f "config/docker/setup.conf" ]
  grep -Fq "mode = force" .setup.conf
}

@test "upgrade.sh warns but does not clobber when BOTH legacy and root setup.conf exist" {
  cd "${DOWN_DIR}"
  mkdir -p config/docker
  printf '[gpu]\nmode = legacy\n' > config/docker/setup.conf
  printf '[gpu]\nmode = root_wins\n' > .setup.conf
  git add config/docker/setup.conf .setup.conf
  git commit -q -m "add both legacy and root setup.conf"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  # Fail-loud: warn about the conflict, keep BOTH, root file wins.
  assert_output --partial "BOTH"
  [ -f ".setup.conf" ]
  [ -f "config/docker/setup.conf" ]
  grep -Fq "mode = root_wins" .setup.conf
}

@test "upgrade.sh relocation commit carries only the moved paths, not unrelated staged work" {
  cd "${DOWN_DIR}"
  mkdir -p config/docker
  printf '[gpu]\nmode = force\n' > config/docker/setup.conf
  git add config/docker/setup.conf
  git commit -q -m "add legacy setup.conf override"

  # Work the user happened to stage before running the upgrade. The
  # pre-flight does not require a clean index, so the relocation commit
  # must scope itself instead of sweeping this in under its own label.
  printf 'unrelated\n' > UNRELATED.txt
  git add UNRELATED.txt

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7

  local _sha
  _sha="$(git log --format=%H --grep='relocate setup.conf override' -1)"
  [ -n "${_sha}" ]
  run git show --no-renames --name-only --format= "${_sha}"
  assert_output --partial ".setup.conf"
  refute_output --partial "UNRELATED.txt"

  # The user's staged work survives untouched, still staged.
  run git diff --cached --name-only
  assert_output --partial "UNRELATED.txt"
}

@test "upgrade.sh migrates the stale devel-scoped [lifecycle] restart = no to the shipped default" {
  cd "${DOWN_DIR}"
  # The vendored template still carries the OLD default, so this upgrade is
  # the one that crosses the devel -> deploy rescope of the key.
  mkdir -p .base/dist
  printf '[lifecycle]\nrestart = no\n' > .base/dist/.setup.conf
  printf '[lifecycle]\nrestart = no\ninit = true\n' > .setup.conf
  git add -A
  git commit -q -m "seed a stale devel-scoped restart default"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  assert_output --partial "MIGRATION"
  assert_output --partial "restart = unless-stopped"

  grep -Fxq "restart = unless-stopped" .setup.conf
  grep -Fxq "init = true" .setup.conf
  # Committed, so the subtree pull that follows it still saw a clean tree.
  refute_output --partial "dirty"
}

@test "upgrade.sh leaves a deliberately configured restart policy alone" {
  cd "${DOWN_DIR}"
  mkdir -p .base/dist
  printf '[lifecycle]\nrestart = no\n' > .base/dist/.setup.conf
  printf '[lifecycle]\nrestart = on-failure:5\n' > .setup.conf
  git add -A
  git commit -q -m "seed a deliberate restart policy"

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  grep -Fxq "restart = on-failure:5" .setup.conf
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
      ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_failure
  assert_output --partial "git identity not configured"
  # Pre-flight aborted before subtree pull ran.
  [ "$(cat .base/.version)" = "v0.9.5" ]
}

@test "upgrade.sh fails fast when MERGE_HEAD is present" {
  cd "${DOWN_DIR}"
  touch .git/MERGE_HEAD

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_failure
  assert_output --partial "MERGE_HEAD present"
  [ "$(cat .base/.version)" = "v0.9.5" ]
}

# ── Rollback on destructive subtree pull ────────────────────────────────────

@test "upgrade.sh rolls back when git-subtree does a destructive fast-forward" {
  cd "${DOWN_DIR}"

  # Install a git-subtree stub that simulates the Jetson v0.9.7 failure
  # mode: fetches the tag, then hard-resets HEAD to FETCH_HEAD (which
  # has template content at REPO ROOT, not under .base). The
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
      ./.base/dist/script/base/upgrade.sh v0.9.7

  assert_failure
  assert_output --partial "integrity check failed"
  # R1+ detects destructive FF via subtree dir missing, ahead of the
  # later .version / version-mismatch checks. The legacy assertion against
  # ".base/.version" missing was specific to the pre-R1+ marker list.
  assert_output --partial "subtree dir missing"
  assert_output --partial "Rolling back"
  assert_output --partial "upgrade aborted"

  # Post-condition: repo restored. HEAD back to pre-pull, subtree markers
  # present, version still v0.9.5 — the user's working copy is usable.
  [ "$(git rev-parse HEAD)" = "${_pre_head}" ]
  [ -f ".base/.version" ]
  [ "$(cat .base/.version)" = "v0.9.5" ]
  [ -f ".base/dist/script/docker/wrapper/setup.sh" ]
  [ -f "README.md" ]
}

# ──walk-up self-location resolves --prefix to the subtree basename ─────
#
# Regression guard for the relocation: upgrade.sh moved deep to
# .base/dist/script/base/upgrade.sh and now derives the subtree
# prefix by WALKING UP to the dir carrying `.version` + `dist/`
# (SUBTREE_ROOT), then `basename`-ing it. The danger is deriving the
# prefix from the script's OWN deep directory (`base`) instead of the
# subtree root (`.base`), which would make `git subtree pull
# --prefix=base` corrupt the repo. Capture the actual --prefix the
# relocated script passes and assert it is the subtree basename `.base`,
# then let the real git-subtree run so we also confirm a clean upgrade
# (no stray base/ dir at repo root).
@test "upgrade.sh (#654 relocated): git subtree pull uses --prefix=.base, not --prefix=base" {
  cd "${DOWN_DIR}"

  # Wrap `git` on PATH: intercept `git subtree pull`, record its --prefix=
  # argument, then delegate the FULL invocation to the real git binary so
  # the upgrade lands normally. (A `git` PATH-shim is used rather than the
  # rollback test's GIT_EXEC_PATH git-subtree stub because the real
  # git-subtree re-invokes `git subtree` internally and must still resolve
  # the distro git-subtree -- the wrapper keeps GIT_EXEC_PATH intact.)
  local _real_git
  _real_git="$(command -v git)"
  local _stub_dir="${BATS_TEST_TMPDIR}/prefix_capture_bin"
  local _prefix_log="${BATS_TEST_TMPDIR}/captured_prefix.txt"
  mkdir -p "${_stub_dir}"
  cat > "${_stub_dir}/git" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "subtree" && "\$2" == "pull" ]]; then
  for _a in "\$@"; do
    case "\${_a}" in
      --prefix=*) printf '%s\n' "\${_a#--prefix=}" > "${_prefix_log}" ;;
    esac
  done
fi
exec "${_real_git}" "\$@"
STUB
  chmod +x "${_stub_dir}/git"

  run env PATH="${_stub_dir}:${PATH}" \
      TEMPLATE_REMOTE="file://${TMPL_BARE}" \
      ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_success
  assert_output --partial "Done! Upgraded to v0.9.7"

  # The load-bearing assertion: prefix is the subtree basename .base.
  [ -f "${_prefix_log}" ]
  assert_equal "$(cat "${_prefix_log}")" ".base"

  # And the real pull landed cleanly: version bumped, no stray base/ dir
  # at the repo root, payload under .base/.
  [ "$(cat .base/.version)" = "v0.9.7" ]
  [ ! -e "base" ]
  [ -f ".base/script/docker/new_script.sh" ]
}

# ════════════════════════════════════════════════════════════════════
# upgrade.sh self-run guard (ADR-00000011 sec.8)
# ════════════════════════════════════════════════════════════════════

@test "upgrade.sh refuses to run when the subtree root carries .git (base template source, #721)" {
  cd "${DOWN_DIR}"

  # The base template SOURCE is itself a git checkout/worktree, so its
  # subtree root carries `.git`; a vendored `.base/` subtree never does
  # (the consumer's `.git` lives at the repo root, outside the subtree).
  # Give the subtree root a `.git` to mimic the source, and assert
  # upgrade refuses instead of running a nonsensical subtree pull into
  # base's PARENT dir.
  rm -rf .base/.git
  mkdir -p .base/.git

  run env TEMPLATE_REMOTE="file://${TMPL_BARE}" ./.base/dist/script/base/upgrade.sh v0.9.7
  assert_failure
  assert_output --partial "template source"
  # Pre-flight aborted before subtree pull ran: version untouched.
  [ "$(cat .base/.version)" = "v0.9.5" ]
}
