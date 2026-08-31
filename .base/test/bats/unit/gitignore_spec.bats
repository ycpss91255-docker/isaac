#!/usr/bin/env bats
#
# Unit tests for .base/dist/script/docker/lib/gitignore.sh.
#
# init.sh / upgrade.sh need to sync a canonical .gitignore set
# (.env, .env.bak, compose.yaml, .setup.conf.bak, coverage/,
# .Dockerfile.generated). The lib has three responsibilities:
#   1. Emit the canonical list (single source of truth).
#   2. Append-missing into a target .gitignore, idempotent, preserving
#      user-defined lines.
#   3. `git rm --cached` any canonical entry that's still tracked in the
#      repo (so 15 downstream repos that mis-track compose.yaml get
#      healed by the next batch-upgrade).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # _sync_logging_gitignore (added in PR-B) reads setup.conf via
  # _collect_logging -> _parse_ini_section, both shared libs. Source
  # them up front so every test gets the full surface.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/conf.sh
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/conf_logging.sh
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/gitignore.sh

  TMP_DIR="$(mktemp -d)"
  # _collect_logging falls back to the template setup.conf when the
  # per-repo one omits [logging]. Point template lookup at a directory
  # that has no setup.conf so tests stay deterministic and don't pick
  # up the real template defaults.
  _SETUP_SCRIPT_DIR="${TMP_DIR}/no-template/docker"
}

teardown() {
  rm -rf "${TMP_DIR}"
}

# ════════════════════════════════════════════════════════════════════
# _canonical_gitignore_entries
# ════════════════════════════════════════════════════════════════════

@test "_canonical_gitignore_entries: emits exactly the 11 canonical lines (#502, #507, #606, #832, #879, #893)" {
  run _canonical_gitignore_entries
  assert_success
  assert_output - <<'EXPECTED'
.env
.env.generated
.env.bak
compose.yaml
.setup.conf.bak
.setup.conf.local
coverage/
.Dockerfile.generated
.docker.xauth
log/
/deploy/
EXPECTED
}

@test "_canonical_gitignore_entries: advertises .setup.conf.local again (#893)" {
  # The line was retired while nothing read the file it named. The
  # per-worktree override layer restores the mechanism, so the line names a
  # real file again -- and it MUST be canonical, because the whole point of
  # the layer is that it never gets committed.
  run _canonical_gitignore_entries
  assert_success
  assert_line ".setup.conf.local"
}

@test "no entry is both canonical and retired (#893)" {
  # The coherence guard. A line in both lists is a repo that deletes, on
  # every sync, the line it just added -- forever. This is what un-retiring
  # .setup.conf.local had to get exactly right, and the guard is what keeps
  # the next retirement from getting it wrong.
  local -a _canon=() _retired=()
  mapfile -t _canon < <(_canonical_gitignore_entries)
  mapfile -t _retired < <(_retired_gitignore_entries)
  local _c _r _both=""
  for _r in "${_retired[@]+"${_retired[@]}"}"; do
    [[ -n "${_r}" ]] || continue
    for _c in "${_canon[@]+"${_canon[@]}"}"; do
      [[ "${_c}" == "${_r}" ]] && _both+=" ${_r}"
    done
  done
  [[ -z "${_both}" ]] || { echo "entries in BOTH lists:${_both}"; false; }
}

@test "_retired_gitignore_entries: retires nothing today (#893)" {
  # .setup.conf.local was its only member and is canonical again. The
  # retraction MECHANISM stays (the next retirement needs it); the LIST is
  # empty, which is what the coherence guard above is asserting against.
  run _retired_gitignore_entries
  assert_success
  assert_output ""
}

@test "_sync_gitignore: a full sync leaves .setup.conf.local in the file, twice running (#893)" {
  # The failure mode being guarded: prune-then-append, forever. Two syncs
  # must converge with the line present, not oscillate around it.
  local _f="${TMP_DIR}/.gitignore"
  : > "${_f}"
  _sync_gitignore "${_f}"
  local _first; _first="$(cat "${_f}")"
  _sync_gitignore "${_f}"
  local _second; _second="$(cat "${_f}")"
  assert_equal "${_second}" "${_first}"
  run cat "${_f}"
  assert_line ".setup.conf.local"
}

# The retraction mechanism is exercised against a STUBBED retired list: the
# real one is empty, and a spec that drives an empty list proves nothing.
_stub_retired() {
  _retired_gitignore_entries() { printf '%s\n' "legacy.retired"; }
}

@test "_sync_gitignore: prunes a retired entry from the managed block (#879)" {
  _stub_retired
  local _f="${TMP_DIR}/.gitignore"
  cat > "${_f}" <<'EOF'
node_modules/
# managed by template (do not remove)
.env
.setup.conf.bak
legacy.retired
EOF
  run _sync_gitignore "${_f}"
  assert_success
  run cat "${_f}"
  refute_line "legacy.retired"
  # Everything else survives, user lines included.
  assert_line "node_modules/"
  assert_line ".env"
  assert_line ".setup.conf.bak"
}

@test "_sync_gitignore: leaves a retired entry the user put ABOVE the marker alone (#879)" {
  # Above the marker is the user's half of the file; the template retracts
  # only what the template added.
  _stub_retired
  local _f="${TMP_DIR}/.gitignore"
  cat > "${_f}" <<'EOF'
legacy.retired
# managed by template (do not remove)
.env
EOF
  run _sync_gitignore "${_f}"
  assert_success
  run cat "${_f}"
  assert_line "legacy.retired"
}

@test "_prune_retired_entries: an early-closing reader cannot lose the managed marker (#905)" {
  # The marker line number came from `grep -n ... | head -1 | cut -d: -f1`,
  # a pipeline into a reader that stops reading. `head -1` leaves after one
  # line, the grep still writing takes SIGPIPE and exits 141, and under
  # init.sh's `set -euo pipefail` that 141 would abort the whole init --
  # which is what the `|| true` on the end was for. But `|| true` throws
  # the status away rather than removing the dependency, so what actually
  # happened was quieter: `cut` had nothing to print, the marker read as
  # ABSENT, the function returned early, and the retired entry stayed in
  # every downstream .gitignore the template was trying to retract it from.
  #
  # `head` is shimmed to leave without reading, and `grep` to write only
  # after it has gone -- both halves of the losing interleaving, pinned.
  # Reading the file in-shell execs neither.
  _stub_retired
  local _shim="${TMP_DIR}/shim"
  shim_early_closing_reader "${_shim}" head
  shim_late_writer "${_shim}" grep \
    "2:# managed by template (do not remove)" \
    "5:# managed by template (do not remove)"

  local _f="${TMP_DIR}/.gitignore"
  cat > "${_f}" <<'EOF'
node_modules/
# managed by template (do not remove)
.env
legacy.retired
EOF

  local _saved_path="${PATH}"
  PATH="${_shim}:${PATH}"
  _prune_retired_entries "${_f}"
  PATH="${_saved_path}"

  run cat "${_f}"
  refute_line "legacy.retired"
  assert_line "node_modules/"
  assert_line ".env"
}

@test "_sync_gitignore: pruning a retired entry is idempotent (#879)" {
  _stub_retired
  local _f="${TMP_DIR}/.gitignore"
  cat > "${_f}" <<'EOF'
# managed by template (do not remove)
.env
legacy.retired
EOF
  _sync_gitignore "${_f}"
  local _first; _first="$(cat "${_f}")"
  _sync_gitignore "${_f}"
  local _second; _second="$(cat "${_f}")"
  assert_equal "${_second}" "${_first}"
}

@test "_canonical_gitignore_entries: list is stable order" {
  # Two calls must produce byte-identical output (consumers may diff).
  local _a _b
  _a="$(_canonical_gitignore_entries)"
  _b="$(_canonical_gitignore_entries)"
  assert_equal "${_a}" "${_b}"
}

# ════════════════════════════════════════════════════════════════════
# _sync_gitignore
# ════════════════════════════════════════════════════════════════════

@test "_sync_gitignore: creates the file when missing, with marker block + all entries" {
  local _f="${TMP_DIR}/.gitignore"
  run _sync_gitignore "${_f}"
  assert_success
  [[ -f "${_f}" ]]
  run cat "${_f}"
  assert_line --partial "managed by template"
  assert_line ".env"
  assert_line ".env.bak"
  assert_line "compose.yaml"
  assert_line ".setup.conf.bak"
  assert_line "coverage/"
  assert_line ".Dockerfile.generated"
}

@test "_sync_gitignore: empty file gets marker block + all entries appended" {
  local _f="${TMP_DIR}/.gitignore"
  : > "${_f}"
  run _sync_gitignore "${_f}"
  assert_success
  run cat "${_f}"
  assert_line --partial "managed by template"
  assert_line ".env"
  assert_line "compose.yaml"
}

@test "_sync_gitignore: file with all entries already present is a no-op" {
  local _f="${TMP_DIR}/.gitignore"
  cat > "${_f}" <<'EOF'
.env
.env.generated
.env.bak
compose.yaml
.setup.conf.bak
.setup.conf.local
coverage/
.Dockerfile.generated
.docker.xauth
log/
/deploy/
EOF
  local _before
  _before="$(cat "${_f}")"
  run _sync_gitignore "${_f}"
  assert_success
  local _after
  _after="$(cat "${_f}")"
  assert_equal "${_after}" "${_before}"
}

@test "_sync_gitignore: appends only missing entries when subset already present" {
  local _f="${TMP_DIR}/.gitignore"
  # Pre-existing partial set (the 15-repo state at the time was filed)
  cat > "${_f}" <<'EOF'
.env
.claude/
EOF
  run _sync_gitignore "${_f}"
  assert_success
  # User entry preserved
  run grep -c '^\.claude/$' "${_f}"
  assert_output "1"
  # Existing canonical preserved (no duplicate)
  run grep -c '^\.env$' "${_f}"
  assert_output "1"
  # Missing canonical appended
  run grep -c '^compose\.yaml$' "${_f}"
  assert_output "1"
  run grep -c '^\.env\.bak$' "${_f}"
  assert_output "1"
  run grep -c '^coverage/$' "${_f}"
  assert_output "1"
}

@test "_sync_gitignore: preserves user-defined lines (bridge.yaml, .env.gpg, .claude/)" {
  local _f="${TMP_DIR}/.gitignore"
  cat > "${_f}" <<'EOF'
.env
.env.gpg
data/
bridge.yaml
.claude/
EOF
  run _sync_gitignore "${_f}"
  assert_success
  run cat "${_f}"
  assert_line ".env.gpg"
  assert_line "data/"
  assert_line "bridge.yaml"
  assert_line ".claude/"
}

@test "_sync_gitignore: idempotent — second invocation produces no further changes" {
  local _f="${TMP_DIR}/.gitignore"
  cat > "${_f}" <<'EOF'
.env
EOF
  _sync_gitignore "${_f}"
  local _after_first
  _after_first="$(cat "${_f}")"
  _sync_gitignore "${_f}"
  local _after_second
  _after_second="$(cat "${_f}")"
  assert_equal "${_after_second}" "${_after_first}"
}

@test "_sync_gitignore: no duplicate canonical lines after re-run" {
  local _f="${TMP_DIR}/.gitignore"
  cat > "${_f}" <<'EOF'
compose.yaml
EOF
  _sync_gitignore "${_f}"
  _sync_gitignore "${_f}"
  run grep -c '^compose\.yaml$' "${_f}"
  assert_output "1"
}

@test "_sync_gitignore: documented constraint -- CRLF entries are not matched (LF-only) (#692)" {
  # _sync_managed_entries decides presence with `grep -qxF` (exact whole-LF-line
  # match). A .gitignore saved with CRLF stores `.env\r`, which is NOT equal to
  # `.env`, so the canonical entry is treated as missing and re-appended -- the
  # file then carries both `.env\r` and `.env`. This pins that documented
  # LF-only constraint (downstream .gitignore must use LF); a future CRLF
  # normalisation would flip this to a single-entry assertion.
  local _f="${TMP_DIR}/.gitignore"
  printf '.env\r\ncompose.yaml\r\n' > "${_f}"
  _sync_gitignore "${_f}"
  # The CRLF-terminated `.env\r` is preserved AND a fresh LF `.env` is appended.
  run grep -c '^\.env$' "${_f}"
  assert_output "1"
  assert [ "$(grep -c $'\.env\r$' "${_f}")" -eq 1 ]
}

@test "_sync_gitignore: ends with newline so future appends start on their own line" {
  local _f="${TMP_DIR}/.gitignore"
  printf 'something' > "${_f}"   # NO trailing newline
  _sync_gitignore "${_f}"
  # Last byte must be a newline
  local _last
  _last="$(tail -c 1 "${_f}" | od -An -c | tr -d ' ')"
  assert_equal "${_last}" '\n'
}

# ════════════════════════════════════════════════════════════════════
# _untrack_canonical_in_repo
# ════════════════════════════════════════════════════════════════════

_init_repo_with_tracked() {
  local _repo="$1"; shift
  git -C "${_repo}" init -q -b main
  git -C "${_repo}" config user.email t@t
  git -C "${_repo}" config user.name t
  local _f
  for _f in "$@"; do
    case "${_f}" in
      */) mkdir -p "${_repo}/${_f}"; : > "${_repo}/${_f}placeholder" ;;
      *)  : > "${_repo}/${_f}" ;;
    esac
  done
  git -C "${_repo}" add -A
  git -C "${_repo}" commit -q -m "init" || true
}

@test "_untrack_canonical_in_repo: git rm --cached for tracked compose.yaml" {
  _init_repo_with_tracked "${TMP_DIR}" compose.yaml
  run _untrack_canonical_in_repo "${TMP_DIR}"
  assert_success
  # File still on disk
  [[ -f "${TMP_DIR}/compose.yaml" ]]
  # No longer in index
  run git -C "${TMP_DIR}" ls-files compose.yaml
  assert_output ""
}

@test "_untrack_canonical_in_repo: leaves untracked files alone" {
  git -C "${TMP_DIR}" init -q -b main
  git -C "${TMP_DIR}" config user.email t@t
  git -C "${TMP_DIR}" config user.name t
  : > "${TMP_DIR}/README"
  git -C "${TMP_DIR}" add -A
  git -C "${TMP_DIR}" commit -q -m "init"
  : > "${TMP_DIR}/compose.yaml"   # exists but never committed
  run _untrack_canonical_in_repo "${TMP_DIR}"
  assert_success
  [[ -f "${TMP_DIR}/compose.yaml" ]]
}

@test "_untrack_canonical_in_repo: no-op when no canonical files tracked" {
  _init_repo_with_tracked "${TMP_DIR}" README.md
  run _untrack_canonical_in_repo "${TMP_DIR}"
  assert_success
  # README still tracked
  run git -C "${TMP_DIR}" ls-files README.md
  assert_output "README.md"
}

@test "_untrack_canonical_in_repo: handles tracked coverage/ directory" {
  _init_repo_with_tracked "${TMP_DIR}" coverage/
  run _untrack_canonical_in_repo "${TMP_DIR}"
  assert_success
  [[ -d "${TMP_DIR}/coverage" ]]
  run git -C "${TMP_DIR}" ls-files coverage/
  assert_output ""
}

@test "_untrack_canonical_in_repo: idempotent — second run succeeds without error" {
  _init_repo_with_tracked "${TMP_DIR}" compose.yaml .env
  _untrack_canonical_in_repo "${TMP_DIR}"
  run _untrack_canonical_in_repo "${TMP_DIR}"
  assert_success
}

@test "_untrack_canonical_in_repo: untracks all canonical entries that match" {
  _init_repo_with_tracked "${TMP_DIR}" compose.yaml .env .env.bak .setup.conf.bak
  run _untrack_canonical_in_repo "${TMP_DIR}"
  assert_success
  run git -C "${TMP_DIR}" ls-files compose.yaml .env .env.bak .setup.conf.bak
  assert_output ""
}

# ════════════════════════════════════════════════════════════════════
# _sync_logging_gitignore (PR-B)
#
# Same managed-block behaviour as the old setup.sh-time
# _sync_logging_local_paths_gitignore, but now reads setup.conf
# itself so init.sh / upgrade.sh can call it without ferrying the
# parsed strings through.
# ════════════════════════════════════════════════════════════════════

@test "_sync_logging_gitignore: tracer — relative local_path emitted in .gitignore (#402)" {
  mkdir -p "${TMP_DIR}"
  cat > "${TMP_DIR}/.setup.conf" <<'CONF'
[logging]
local_path = ./logs/
CONF
  run _sync_logging_gitignore "${TMP_DIR}"
  assert_success
  run grep -F '/logs/' "${TMP_DIR}/.gitignore"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# _sync_logging_gitignore: relative path appending + filter
#
# Migrated from compose_logging_spec.bats when the implementation
# moved out of setup.sh in (PR-B). Each test stages setup.conf
# instead of passing the resolved strings, exercising the full
# _collect_logging -> sync flow.
# ════════════════════════════════════════════════════════════════════

_stage_logging_conf() {
  mkdir -p "${TMP_DIR}"
  cat > "${TMP_DIR}/.setup.conf"
}

@test "_sync_logging_gitignore appends relative local_path to .gitignore (#402, ex-#328)" {
  _stage_logging_conf <<'CONF'
[logging]
local_path = ./logs/
CONF
  : > "${TMP_DIR}/.gitignore"
  _sync_logging_gitignore "${TMP_DIR}"
  run grep -xF "/logs/" "${TMP_DIR}/.gitignore"
  assert_success
  run grep -xF "# managed by template: [logging] local_path begin (do not remove)" "${TMP_DIR}/.gitignore"
  assert_success
}

@test "_sync_logging_gitignore skips absolute paths (#402, ex-#328)" {
  _stage_logging_conf <<'CONF'
[logging]
local_path = /srv/logs/
CONF
  : > "${TMP_DIR}/.gitignore"
  _sync_logging_gitignore "${TMP_DIR}"
  run grep -F "/srv/logs" "${TMP_DIR}/.gitignore"
  assert_failure
}

@test "_sync_logging_gitignore skips ~ paths (#402, ex-#328)" {
  _stage_logging_conf <<'CONF'
[logging]
local_path = ~/logs/
CONF
  : > "${TMP_DIR}/.gitignore"
  _sync_logging_gitignore "${TMP_DIR}"
  run grep -F "~/logs" "${TMP_DIR}/.gitignore"
  assert_failure
}

@test "_sync_logging_gitignore is idempotent (#402, ex-#328)" {
  _stage_logging_conf <<'CONF'
[logging]
local_path = ./logs/
CONF
  : > "${TMP_DIR}/.gitignore"
  _sync_logging_gitignore "${TMP_DIR}"
  local _first
  _first="$(cat "${TMP_DIR}/.gitignore")"
  _sync_logging_gitignore "${TMP_DIR}"
  [[ "$(cat "${TMP_DIR}/.gitignore")" == "${_first}" ]]
}

@test "_sync_logging_gitignore: documented constraint -- a '..' traversal is wrapped verbatim (#692)" {
  # The filter strips only absolute (/*) and ~ paths; any other relative
  # value is wrapped as /<value>/. A `..`-escaping value therefore produces
  # the (meaningless-as-an-anchor) pattern /../escape/. This pins the current
  # behaviour; a future input-validation pass would skip/reject it instead.
  _stage_logging_conf <<'CONF'
[logging]
local_path = ../escape/
CONF
  : > "${TMP_DIR}/.gitignore"
  _sync_logging_gitignore "${TMP_DIR}"
  run grep -xF "/../escape/" "${TMP_DIR}/.gitignore"
  assert_success
}

@test "_sync_logging_gitignore: documented constraint -- a space-bearing path is wrapped verbatim (#692)" {
  # A value with a space is wrapped as /my logs/ (a literal-space pattern).
  # Pins the current behaviour; a future sanitiser would reject or quote it.
  _stage_logging_conf <<'CONF'
[logging]
local_path = my logs/
CONF
  : > "${TMP_DIR}/.gitignore"
  _sync_logging_gitignore "${TMP_DIR}"
  run grep -xF "/my logs/" "${TMP_DIR}/.gitignore"
  assert_success
}

@test "_sync_logging_gitignore collects from both global + per-svc (#402, ex-#328)" {
  _stage_logging_conf <<'CONF'
[logging]
local_path = ./global-logs/

[logging.devel]
local_path = ./devel-logs/

[logging.test]
local_path = ./test-logs/
CONF
  : > "${TMP_DIR}/.gitignore"
  _sync_logging_gitignore "${TMP_DIR}"
  run grep -xF "/global-logs/" "${TMP_DIR}/.gitignore"
  assert_success
  run grep -xF "/devel-logs/" "${TMP_DIR}/.gitignore"
  assert_success
  run grep -xF "/test-logs/" "${TMP_DIR}/.gitignore"
  assert_success
}

@test "_sync_logging_gitignore is no-op when no local_path keys (#402, ex-#328)" {
  _stage_logging_conf <<'CONF'
[logging]
driver = json-file
CONF
  : > "${TMP_DIR}/.gitignore"
  _sync_logging_gitignore "${TMP_DIR}"
  [[ ! -s "${TMP_DIR}/.gitignore" ]]
}

# ────────────────────────────────────────────────────────────────────
# Prune behaviour : managed-block re-emit + isolation
# ────────────────────────────────────────────────────────────────────

@test "_sync_logging_gitignore prunes stale managed entries on value change (#402, ex-#390)" {
  _stage_logging_conf <<'CONF'
[logging]
local_path = ./logs/
CONF
  : > "${TMP_DIR}/.gitignore"
  _sync_logging_gitignore "${TMP_DIR}"
  run grep -xF "/logs/" "${TMP_DIR}/.gitignore"
  assert_success
  # Rename: /logs/ pruned, /log/ added.
  _stage_logging_conf <<'CONF'
[logging]
local_path = ./log/
CONF
  _sync_logging_gitignore "${TMP_DIR}"
  run grep -xF "/logs/" "${TMP_DIR}/.gitignore"
  assert_failure
  run grep -xF "/log/" "${TMP_DIR}/.gitignore"
  assert_success
}

@test "_sync_logging_gitignore drops marker + entries when candidates become empty (#402, ex-#390)" {
  _stage_logging_conf <<'CONF'
[logging]
local_path = ./logs/
CONF
  : > "${TMP_DIR}/.gitignore"
  _sync_logging_gitignore "${TMP_DIR}"
  run grep -xF "/logs/" "${TMP_DIR}/.gitignore"
  assert_success
  # Feature turned off: marker + entries removed.
  _stage_logging_conf <<'CONF'
[logging]
local_path =
CONF
  _sync_logging_gitignore "${TMP_DIR}"
  run grep -xF "/logs/" "${TMP_DIR}/.gitignore"
  assert_failure
  run grep -xF "# managed by template: [logging] local_path (do not remove)" "${TMP_DIR}/.gitignore"
  assert_failure
}

@test "_sync_logging_gitignore preserves user entries outside managed block (#402, ex-#390)" {
  # User-owned /logs/ above the managed block (e.g. legacy entry kept
  # for the host directory after a rename migration).
  printf '%s\n' "# user ignores" "/logs/" "" > "${TMP_DIR}/.gitignore"
  _stage_logging_conf <<'CONF'
[logging]
local_path = ./log/
CONF
  _sync_logging_gitignore "${TMP_DIR}"
  run grep -xF "/logs/" "${TMP_DIR}/.gitignore"
  assert_success
  run grep -xF "/log/" "${TMP_DIR}/.gitignore"
  assert_success
  # Turning the feature off prunes managed /log/ but leaves user /logs/.
  _stage_logging_conf <<'CONF'
[logging]
local_path =
CONF
  _sync_logging_gitignore "${TMP_DIR}"
  run grep -xF "/logs/" "${TMP_DIR}/.gitignore"
  assert_success
  run grep -xF "/log/" "${TMP_DIR}/.gitignore"
  assert_failure
}

# ────────────────────────────────────────────────────────────────────
# Managed-block bounds: explicit begin/end markers
#
# The block used to be scoped by SHAPE -- the marker line plus every
# following line matching `/<dir>/`. That silently ate a user rule
# appended below the marker (the end of the file is exactly where a
# user appends), and it made the newer canonical `/deploy/` entry --
# appended by _sync_gitignore immediately before this sync runs in the
# same init pass -- survive only by accident, on the spurious blank
# line the dead trailing-newline guard emitted.
#
# Now the block is delimited by an explicit begin/end marker pair (the
# same allow-begin / allow-end shape the stale-path and home-literal
# lints use); only lines strictly between them are template-owned, an
# unterminated block is a loud error, and a pre-existing
# begin-marker-only block written by an older template is migrated in
# place, consuming only the lines the block itself would emit.
# ────────────────────────────────────────────────────────────────────

_LOGGING_BEGIN='# managed by template: [logging] local_path begin (do not remove)'
_LOGGING_END='# managed by template: [logging] local_path end (do not remove)'
_LOGGING_LEGACY='# managed by template: [logging] local_path (do not remove)'

@test "_sync_logging_gitignore: emits an explicit end marker bounding the block (#876)" {
  _stage_logging_conf <<'CONF'
[logging]
local_path = ./log/
CONF
  : > "${TMP_DIR}/.gitignore"
  _sync_logging_gitignore "${TMP_DIR}"
  run grep -xF "${_LOGGING_BEGIN}" "${TMP_DIR}/.gitignore"
  assert_success
  run grep -xF "${_LOGGING_END}" "${TMP_DIR}/.gitignore"
  assert_success
}

@test "_sync_logging_gitignore: preserves a user entry BELOW the managed block (#876)" {
  _stage_logging_conf <<'CONF'
[logging]
local_path = ./log/
CONF
  : > "${TMP_DIR}/.gitignore"
  _sync_logging_gitignore "${TMP_DIR}"
  # The user appends a new anchored dir rule at the end of the file --
  # i.e. directly below the managed block.
  printf '/build/\n' >> "${TMP_DIR}/.gitignore"
  run _sync_logging_gitignore "${TMP_DIR}"
  assert_success
  run grep -xF "/build/" "${TMP_DIR}/.gitignore"
  assert_success
  run grep -xF "/log/" "${TMP_DIR}/.gitignore"
  assert_success
}

@test "_sync_logging_gitignore: user entry below the block survives a value change (#876)" {
  _stage_logging_conf <<'CONF'
[logging]
local_path = ./log/
CONF
  : > "${TMP_DIR}/.gitignore"
  _sync_logging_gitignore "${TMP_DIR}"
  printf '/build/\n' >> "${TMP_DIR}/.gitignore"
  _stage_logging_conf <<'CONF'
[logging]
local_path = ./logs/
CONF
  run _sync_logging_gitignore "${TMP_DIR}"
  assert_success
  # Managed entry re-emitted, stale one pruned, user rule untouched.
  run grep -xF "/logs/" "${TMP_DIR}/.gitignore"
  assert_success
  run grep -xF "/log/" "${TMP_DIR}/.gitignore"
  assert_failure
  run grep -xF "/build/" "${TMP_DIR}/.gitignore"
  assert_success
}

@test "_sync_logging_gitignore: an unterminated managed block is an error (#876)" {
  _stage_logging_conf <<'CONF'
[logging]
local_path = ./log/
CONF
  # A begin marker whose end marker was deleted: the block has no
  # bound, so the sync must refuse rather than guess where it stops.
  printf '%s\n' "${_LOGGING_BEGIN}" "/log/" "/build/" > "${TMP_DIR}/.gitignore"
  local _before
  _before="$(cat "${TMP_DIR}/.gitignore")"
  run _sync_logging_gitignore "${TMP_DIR}"
  assert_failure
  assert_output --partial "gitignore_managed_block_invalid"
  # The file is left byte-identical -- a refused sync never rewrites.
  assert_equal "$(cat "${TMP_DIR}/.gitignore")" "${_before}"
}

@test "_sync_logging_gitignore: an end marker with no begin marker is an error (#876)" {
  _stage_logging_conf <<'CONF'
[logging]
local_path = ./log/
CONF
  printf '%s\n' "/build/" "${_LOGGING_END}" > "${TMP_DIR}/.gitignore"
  run _sync_logging_gitignore "${TMP_DIR}"
  assert_failure
  assert_output --partial "gitignore_managed_block_invalid"
}

@test "_sync_logging_gitignore: migrates a legacy begin-marker-only block (#876)" {
  _stage_logging_conf <<'CONF'
[logging]
local_path = ./log/
CONF
  # What an older template left on disk: begin marker, no end marker.
  printf '%s\n' "# user ignores" "${_LOGGING_LEGACY}" "/log/" \
    > "${TMP_DIR}/.gitignore"
  run _sync_logging_gitignore "${TMP_DIR}"
  assert_success
  run grep -xF "${_LOGGING_LEGACY}" "${TMP_DIR}/.gitignore"
  assert_failure
  run grep -xF "${_LOGGING_BEGIN}" "${TMP_DIR}/.gitignore"
  assert_success
  run grep -xF "${_LOGGING_END}" "${TMP_DIR}/.gitignore"
  assert_success
  run grep -xF "/log/" "${TMP_DIR}/.gitignore"
  assert_success
  run grep -xF "# user ignores" "${TMP_DIR}/.gitignore"
  assert_success
}

@test "_sync_logging_gitignore: legacy migration keeps a following canonical entry (#876)" {
  _stage_logging_conf <<'CONF'
[logging]
local_path = ./log/
CONF
  # The canonical /deploy/ entry appended right below a legacy block,
  # with no blank line between them: the migration must not consume it.
  printf '%s\n' "${_LOGGING_LEGACY}" "/log/" "/deploy/" \
    > "${TMP_DIR}/.gitignore"
  run _sync_logging_gitignore "${TMP_DIR}"
  assert_success
  run grep -xF "/deploy/" "${TMP_DIR}/.gitignore"
  assert_success
  assert [ "$(grep -c '^/log/$' "${TMP_DIR}/.gitignore")" -eq 1 ]
}

@test "_sync_logging_gitignore: legacy migration reports orphaned entries (#876)" {
  _stage_logging_conf <<'CONF'
[logging]
local_path = ./log/
CONF
  printf '%s\n' "${_LOGGING_LEGACY}" "/log/" "/stale/" \
    > "${TMP_DIR}/.gitignore"
  run _sync_logging_gitignore "${TMP_DIR}"
  assert_success
  assert_output --partial "gitignore_managed_block_orphans"
  # Not deleted -- handed back to the user, loudly.
  run grep -xF "/stale/" "${TMP_DIR}/.gitignore"
  assert_success
}

@test "_sync_managed_entries: appends without a spurious blank line (#876)" {
  local _f="${TMP_DIR}/.gitignore"
  printf '%s\n' "/build/" > "${_f}"
  _sync_gitignore "${_f}"
  run grep -c '^$' "${_f}"
  assert_output "0"
}

@test "_sync_gitignore + _sync_logging_gitignore converge over repeated passes (#876)" {
  # The real init.sh order, run three times over a downstream .gitignore
  # that an older template left with a legacy logging block at the end
  # of the file: /deploy/ (a newer canonical entry) and a user rule must
  # both be present and stable, with no duplicates.
  _stage_logging_conf <<'CONF'
[logging]
local_path = ./log/
CONF
  printf '%s\n' ".env" "compose.yaml" "${_LOGGING_LEGACY}" "/log/" \
    > "${TMP_DIR}/.gitignore"
  local _pass _snapshot=""
  for _pass in 1 2 3; do
    run _sync_gitignore "${TMP_DIR}/.gitignore"
    assert_success
    run _sync_logging_gitignore "${TMP_DIR}"
    assert_success
    # The user appends their own rule at the end of the file once, on
    # the first pass; every later pass must leave it alone.
    if [[ "${_pass}" -eq 1 ]]; then
      printf '/build/\n' >> "${TMP_DIR}/.gitignore"
      run _sync_logging_gitignore "${TMP_DIR}"
      assert_success
    fi
    assert [ "$(grep -c '^/deploy/$' "${TMP_DIR}/.gitignore")" -eq 1 ]
    assert [ "$(grep -c '^/log/$' "${TMP_DIR}/.gitignore")" -eq 1 ]
    assert [ "$(grep -c '^/build/$' "${TMP_DIR}/.gitignore")" -eq 1 ]
  done
  _snapshot="$(cat "${TMP_DIR}/.gitignore")"
  _sync_gitignore "${TMP_DIR}/.gitignore"
  _sync_logging_gitignore "${TMP_DIR}"
  assert_equal "$(cat "${TMP_DIR}/.gitignore")" "${_snapshot}"
}
