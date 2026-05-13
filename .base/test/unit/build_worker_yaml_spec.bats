#!/usr/bin/env bats
#
# build_worker_yaml_spec.bats — structural assertions for the
# `.github/workflows/build-worker.yaml` reusable workflow.
#
# Reusable workflows can't be unit-tested by exec'ing them, but their
# structural invariants (which inputs exist, which `with:` keys
# forward into docker/build-push-action) are still grep-able. These
# tests lock the #195 changes — `context_path` / `dockerfile_path`
# inputs and the corresponding `context:` / `file:` lines in the 3
# build steps — so a future refactor that drops one of them lights up
# CI red instead of silently breaking nested-Dockerfile downstreams.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WF="/source/.github/workflows/build-worker.yaml"
  [[ -f "${WF}" ]] || skip "build-worker.yaml not at expected path"
}

# ── Inputs declared (#195) ────────────────────────────────────────────

@test "build-worker.yaml: declares context_path input with default '.'" {
  run grep -A 3 '^      context_path:' "${WF}"
  assert_success
  assert_output --partial 'required: false'
  assert_output --partial 'type: string'
  assert_output --partial 'default: "."'
}

@test "build-worker.yaml: declares dockerfile_path input with empty default" {
  run grep -A 3 '^      dockerfile_path:' "${WF}"
  assert_success
  assert_output --partial 'required: false'
  assert_output --partial 'type: string'
  assert_output --partial 'default: ""'
}

# ── Build steps forward both inputs (#195) ────────────────────────────

@test "build-worker.yaml: 4 build steps all reference inputs.context_path (#243 added runtime-test)" {
  # Four `docker/build-push-action` calls after #243:
  # devel-test / devel / runtime-test / runtime stages. Each must read
  # context from the new input; `context: .` would silently work for
  # repo-root-Dockerfile callers but break the nested-Dockerfile use
  # case the #195 issue body documented.
  run grep -c 'context: ${{ inputs.context_path }}' "${WF}"
  assert_success
  assert_output "4"
}

@test "build-worker.yaml: 4 build steps all forward inputs.dockerfile_path with format() fallback" {
  # The `||` short-circuit means an empty dockerfile_path falls back
  # to `<context_path>/Dockerfile`, matching docker/build-push-action's
  # implicit default. Override path lets callers pin a non-standard
  # filename.
  run grep -c "file: \${{ inputs.dockerfile_path || format('{0}/Dockerfile', inputs.context_path) }}" "${WF}"
  assert_success
  assert_output "4"
}

@test "build-worker.yaml: no leftover hardcoded 'context: .' lines" {
  # Catches partial-refactor regressions where one of the 3 stages
  # gets reverted by accident. The post-#195 file should have ZERO
  # `context: .` literals — every reference reads from the input.
  run grep -c '^          context: \.$' "${WF}"
  [ "${status}" -ne 0 ] || [ "${output}" = "0" ]
}

@test "build-worker.yaml: no hardcoded Dockerfile path bypassing the input" {
  # Belt-and-braces against someone hard-coding `file: ./Dockerfile`
  # in one stage and forgetting that callers expect the input to flow
  # through.
  run grep -E '^[[:space:]]+file: \./Dockerfile$' "${WF}"
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
}

# ── Backwards compatibility ──────────────────────────────────────────

@test "build-worker.yaml: defaults preserve repo-root-Dockerfile behavior" {
  # Both inputs default such that an existing caller passing only
  # `image_name:` still resolves to context=. and file=./Dockerfile —
  # what every pre-#195 downstream main.yaml expects. Asserts the
  # combination, not just each default in isolation.
  local _ctx _df
  _ctx="$(grep -A 3 '^      context_path:' "${WF}" | grep 'default:' | head -1)"
  _df="$(grep -A 3 '^      dockerfile_path:' "${WF}" | grep 'default:' | head -1)"
  [[ "${_ctx}" == *'"."'* ]]
  [[ "${_df}" == *'""'* ]]
}

# ── User build-args alignment with Dockerfile.example (#198) ──────────

@test "build-worker.yaml: 4 build steps pass USER_NAME=ci (long form, matching Dockerfile.example sys stage)" {
  # Pre-#198 the workflow passed `USER=ci` (short form) which the
  # Dockerfile only sees in the devel stage; the sys-stage useradd
  # reads USER_NAME and stuck on the default "user". The container
  # then USER-switched to "ci" with no /etc/passwd entry, exploding
  # any RUN that resolved the username.
  run grep -c '^            USER_NAME=ci$' "${WF}"
  assert_success
  assert_output "4"
}

@test "build-worker.yaml: 4 build steps pass USER_GROUP=ci (long form)" {
  run grep -c '^            USER_GROUP=ci$' "${WF}"
  assert_success
  assert_output "4"
}

@test "build-worker.yaml: 4 build steps pass USER_UID=1000 (long form)" {
  run grep -c '^            USER_UID=1000$' "${WF}"
  assert_success
  assert_output "4"
}

@test "build-worker.yaml: 4 build steps pass USER_GID=1000 (long form)" {
  run grep -c '^            USER_GID=1000$' "${WF}"
  assert_success
  assert_output "4"
}

@test "build-worker.yaml: no short-form USER=/GROUP=/UID=/GID= build-args (regression #198)" {
  # The Generate-.env step at the top of the workflow uses long-form
  # writes via `printf 'USER_NAME=...'`; only build-args lines (8-space
  # indent inside the build steps) are at risk. Anchor on that
  # indentation to avoid false positives from the env-file write.
  run grep -E '^            (USER|GROUP|UID|GID)=' "${WF}"
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
}

# ── build_contexts input forwards to docker/build-push-action (#207) ──

@test "build-worker.yaml: declares build_contexts input with empty default" {
  # #199 added compose's `additional_contexts:` for local builds, but
  # CI invokes `docker/build-push-action` directly (bypassing compose),
  # so the named contexts never reached BuildKit. #207 adds the input
  # the workflow needs to forward them to the action's `build-contexts:`
  # field. Default is empty so existing callers see zero diff.
  run grep -A 3 '^      build_contexts:' "${WF}"
  assert_success
  assert_output --partial 'required: false'
  assert_output --partial 'type: string'
  assert_output --partial 'default: ""'
}

@test "build-worker.yaml: 4 build steps forward inputs.build_contexts to docker/build-push-action build-contexts:" {
  # Four docker/build-push-action calls after #243 (devel-test / devel
  # / runtime-test / runtime). Each must forward the input so named
  # contexts work end-to-end in CI.
  run grep -c '^          build-contexts: \${{ inputs.build_contexts }}$' "${WF}"
  assert_success
  assert_output "4"
}

# ── #243: stage rename + runtime-test smoke step ──────────────────────

@test "build-worker.yaml: devel-test build step uses target: devel-test (renamed from target: test)" {
  # Pre-#243 the test stage was named `test`; renamed to `devel-test`
  # for symmetry with the new `runtime-test` stage. The literal target
  # line must reflect the new name.
  run grep -E '^          target: devel-test$' "${WF}"
  assert_success
}

@test "build-worker.yaml: no leftover target: test (the renamed stage)" {
  # If we forget to update one of the build steps, this catches it.
  run grep -E '^          target: test$' "${WF}"
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
}

@test "build-worker.yaml: runtime-test build step exists and uses target: runtime-test" {
  run grep -E '^          target: runtime-test$' "${WF}"
  assert_success
}

@test "build-worker.yaml: runtime-test build step is gated on inputs.build_runtime" {
  # Same gate as the runtime stage build, so agent/* repos
  # (build_runtime: false) skip both cleanly. Asserts the gate appears
  # at least twice in the file (once for runtime-test, once for runtime).
  run grep -c '^        if: ${{ inputs.build_runtime }}$' "${WF}"
  assert_success
  [[ "${output}" -ge 2 ]] || { echo "expected >=2 build_runtime gates, got ${output}"; return 1; }
}

@test "build-worker.yaml: build_contexts default preserves zero-diff for existing callers (#207)" {
  # The combined safety net: with empty default + per-step plumbing,
  # callers that don't pass build_contexts get an empty action input,
  # which docker/build-push-action treats as "no extra contexts" — the
  # exact pre-#207 behaviour.
  local _bc
  _bc="$(grep -A 3 '^      build_contexts:' "${WF}" | grep 'default:' | head -1)"
  [[ "${_bc}" == *'""'* ]]
}

# ── #272: GHA buildx cache (per-(repo, variant, arch)) ────────────────

@test "build-worker.yaml: declares cache_variant input with empty default (#272)" {
  # New optional input for repos that call build-worker.yaml multiple
  # times with the same image_name but different build_args (the
  # env/ros{,2}_distro pattern). Default empty so existing single-call
  # callers see no scope-key shape change.
  run grep -A 3 '^      cache_variant:' "${WF}"
  assert_success
  assert_output --partial 'required: false'
  assert_output --partial 'type: string'
  assert_output --partial 'default: ""'
}

@test "build-worker.yaml: Compute cache scope step emits id: cache with scope key in GITHUB_OUTPUT (#272)" {
  # The step computes `${image_name}[-${cache_variant}]-${hardware}-cache`
  # once at the top of the build job; all 4 build steps reference the
  # output. Asserts presence + id so downstream `steps.cache.outputs.key`
  # references resolve.
  run grep -E '^        id: cache$' "${WF}"
  assert_success
  run grep -E '^          echo "key=\$\{base\}-\$\{\{ matrix\.hardware \}\}-cache" >> "\$\{GITHUB_OUTPUT\}"$' "${WF}"
  assert_success
}

@test "build-worker.yaml: 4 build steps all set cache-from=type=gha (#272)" {
  # Every docker/build-push-action call must read from the same GHA
  # scope so feature-branch builds reuse the base branch's cache and
  # subsequent steps within the same shard share intermediate layers.
  run grep -c '^          cache-from: type=gha,scope=\${{ steps\.cache\.outputs\.key }}$' "${WF}"
  assert_success
  assert_output "4"
}

@test "build-worker.yaml: 4 build steps all set cache-to=type=gha,...,mode=max (#272)" {
  # mode=max exports all intermediate stage layers (including the heavy
  # builder / source-build stages). The 10 GB GHA quota tradeoff is
  # accepted; LRU eviction is expected to keep hot paths cached.
  run grep -c '^          cache-to: type=gha,scope=\${{ steps\.cache\.outputs\.key }},mode=max$' "${WF}"
  assert_success
  assert_output "4"
}

@test "build-worker.yaml: cache_variant default preserves zero-diff for single-call callers (#272)" {
  # Single-distro repos (agent/* + ros1_bridge-${distro} pattern) leave
  # cache_variant unset; the scope key reduces to
  # ${image_name}-${hardware}-cache, which is already per-(repo, arch)
  # and matches the existing matrix shape.
  local _cv
  _cv="$(grep -A 3 '^      cache_variant:' "${WF}" | grep 'default:' | head -1)"
  [[ "${_cv}" == *'""'* ]]
}

# ── #273 Phase 1: doc-only PR fast-pass ────────────────────────────────

@test "build-worker.yaml: declares path-filter job (#273)" {
  # New job runs the doc-only classifier; outputs code_changed
  # consumed by compute-matrix / build / docker-build downstream.
  run grep -E '^  path-filter:$' "${WF}"
  assert_success
}

@test "build-worker.yaml: path-filter classifier is pure shell (#273 Phase 2: no dorny/paths-filter)" {
  # Phase 2 — dorny/paths-filter@v3 dependency dropped; classification
  # is now `git diff --name-only base...head` + `case` glob in inline
  # shell. Asserts the `uses:` import is gone (comments mentioning
  # `dorny` for historical context are still fine) AND the shell
  # driver is present.
  run grep -E '^\s+uses:\s+dorny/paths-filter' "${WF}"
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
  run grep -F 'git diff --name-only "${BASE_SHA}...${HEAD_SHA}"' "${WF}"
  assert_success
}

@test "build-worker.yaml: classifier reads EVENT_NAME / BASE_SHA / HEAD_SHA from env (#273 Phase 2)" {
  # Template tokens pre-expand into env vars so the shell case body
  # stays portable to non-GitHub CI hosts — only the YAML env: keys
  # bind to GitHub context.
  run grep -F 'EVENT_NAME: ${{ github.event_name }}' "${WF}"
  assert_success
  run grep -F 'BASE_SHA: ${{ github.event.pull_request.base.sha }}' "${WF}"
  assert_success
  run grep -F 'HEAD_SHA: ${{ github.event.pull_request.head.sha }}' "${WF}"
  assert_success
}

@test "build-worker.yaml: non-pull_request event short-circuits to code_changed=true before git diff (#273 Phase 2)" {
  # Push / tag / workflow_dispatch never run the classifier loop —
  # the early `[ ... != pull_request ] && exit 0` arm is essential
  # because BASE_SHA / HEAD_SHA are empty on non-PR events.
  run grep -E '\[ "\$\{EVENT_NAME\}" != "pull_request" \]' "${WF}"
  assert_success
}

@test "build-worker.yaml: doc-only allowlist case-glob covers all 6 documented paths (#273)" {
  # **/*.md, doc/**, LICENSE, .gitignore, .github/CODEOWNERS,
  # .github/dependabot.yml — match the issue body / design comment.
  # Phase 2 expresses them as a single `case` arm with `|`-joined
  # patterns; one grep checks the whole arm at once.
  run grep -F '*.md|doc/*|LICENSE|.gitignore|.github/CODEOWNERS|.github/dependabot.yml' "${WF}"
  assert_success
}

@test "build-worker.yaml: compute-matrix and build are gated on code_changed (#273)" {
  # Both heavy jobs need needs.path-filter.outputs.code_changed == 'true'.
  # Count = 2 means both jobs have the gate.
  run grep -c "if: needs\\.path-filter\\.outputs\\.code_changed == 'true'" "${WF}"
  assert_success
  assert_output "2"
}

@test "build-worker.yaml: docker-build aggregator short-circuits to success on doc-only (#273)" {
  # The aggregator must report success when code_changed == 'false'
  # so branch protection's required check still resolves green even
  # though the matrix was skipped.
  run grep -F 'needs.path-filter.outputs.code_changed }}" = "false"' "${WF}"
  assert_success
  # And it still needs both path-filter + build so the conditional
  # has both data sources.
  run grep -E '^    needs: \[path-filter, build\]$' "${WF}"
  assert_success
}

@test "build-worker.yaml: non-pull_request event resolves code_changed=true (#273)" {
  # Push to main / tag / workflow_dispatch must always run the full
  # matrix — the doc-only fast-pass is PR-only.
  run grep -F 'echo "code_changed=true"' "${WF}"
  assert_success
}
