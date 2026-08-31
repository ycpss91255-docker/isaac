#!/usr/bin/env bats
#
# build_worker_yaml_spec.bats — structural assertions for the
# `.github/workflows/build-worker.yaml` reusable workflow.
#
# Reusable workflows can't be unit-tested by exec'ing them, but their
# structural invariants (which inputs exist, which `with:` keys
# forward into docker/build-push-action) are still grep-able. These
# tests lock the changes — `context_path` / `dockerfile_path`
# inputs and the corresponding `context:` / `file:` lines in the 3
# build steps — so a future refactor that drops one of them lights up
# CI red instead of silently breaking nested-Dockerfile downstreams.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WF="/source/.github/workflows/build-worker.yaml"
  [[ -f "${WF}" ]] || skip "build-worker.yaml not at expected path"
}

# ── Inputs declared ────────────────────────────────────────────

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

# ── Build steps forward both inputs ────────────────────────────

@test "build-worker.yaml: 4 build steps all reference inputs.context_path (#243 added runtime-test)" {
  # Four `docker/build-push-action` calls after
  # devel-test / devel / runtime-test / runtime stages. Each must read
  # context from the new input; `context: .` would silently work for
  # repo-root-Dockerfile callers but break the nested-Dockerfile use
  # case the issue body documented.
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
  # gets reverted by accident. The file should have ZERO
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
  # what every downstream main.yaml expects. Asserts the
  # combination, not just each default in isolation.
  local _ctx _df
  _ctx="$(grep -A 3 '^      context_path:' "${WF}" | grep 'default:' | head -1)"
  _df="$(grep -A 3 '^      dockerfile_path:' "${WF}" | grep 'default:' | head -1)"
  [[ "${_ctx}" == *'"."'* ]]
  [[ "${_df}" == *'""'* ]]
}

# ── User build-args alignment with Dockerfile.example ──────────

@test "build-worker.yaml: 4 build steps pass USER_NAME=ci (long form, matching Dockerfile.example sys stage)" {
  # the workflow passed `USER=ci` (short form) which the
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

# ── build_contexts input forwards to docker/build-push-action ──

@test "build-worker.yaml: declares build_contexts input with empty default" {
  # added compose's `additional_contexts:` for local builds, but
  # CI invokes `docker/build-push-action` directly (bypassing compose),
  # so the named contexts never reached BuildKit. adds the input
  # the workflow needs to forward them to the action's `build-contexts:`
  # field. Default is empty so existing callers see zero diff.
  run grep -A 3 '^      build_contexts:' "${WF}"
  assert_success
  assert_output --partial 'required: false'
  assert_output --partial 'type: string'
  assert_output --partial 'default: ""'
}

@test "build-worker.yaml: 4 build steps forward inputs.build_contexts to docker/build-push-action build-contexts:" {
  # Four docker/build-push-action calls after (devel-test / devel
  # / runtime-test / runtime). Each must forward the input so named
  # contexts work end-to-end in CI.
  run grep -c '^          build-contexts: \${{ inputs.build_contexts }}$' "${WF}"
  assert_success
  assert_output "4"
}

# ──stage rename + runtime-test smoke step ──────────────────────

@test "build-worker.yaml: devel-test build step uses target: devel-test (renamed from target: test)" {
  # the test stage was named `test`; renamed to `devel-test`
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
  # exact behaviour.
  local _bc
  _bc="$(grep -A 3 '^      build_contexts:' "${WF}" | grep 'default:' | head -1)"
  [[ "${_bc}" == *'""'* ]]
}

# ──GHA buildx cache (per-(repo, variant, arch)) ────────────────

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

@test "build-worker.yaml: Compute cache scope step emits id: cache with base key in GITHUB_OUTPUT (#272 + #378 + #802)" {
  # The step computes the per-(repo, variant, arch) base
  # `${image_name}[-${cache_variant}]-${hardware}` once; per-target
  # suffix (`-devel-test-cache`, `-devel-cache`, `-runtime-test-cache`,
  # `-runtime-cache`) is appended at the use site. See the b1 mitigation
  # of for why the shape changed from a single shared `<base>-cache`
  # scope to 4 per-target scopes. The derivation is now delegated to
  # cache_scope.sh; the step keeps `id: cache` + a `key=` GITHUB_OUTPUT.
  run grep -E '^        id: cache$' "${WF}"
  assert_success
  run grep -E '^          echo "key=\$\{key\}" >> "\$\{GITHUB_OUTPUT\}"$' "${WF}"
  assert_success
}

@test "build-worker.yaml: 4 build steps use per-target gha cache scopes in the default branch (#378 b1, #801 ternary)" {
  # all 4 build steps shared `${steps.cache.outputs.key}` so a
  # late-stage COPY in devel cascaded the manifest pointer in the
  # shared scope, invalidating runtime / runtime-test caches on the
  # next PR. each target has its own scope; one scope's manifest update
  # no longer affects the others.
  #
  # The cache_backend option made cache-from / cache-to a
  # `cache_backend`-selected ternary; the default (gha) branch is a
  # `format()` that emits the SAME `type=gha,scope=<key>-<target>-cache`
  # string as before, so gha callers are byte-for-byte unchanged at runtime.
  for _target in devel-test devel runtime-test runtime; do
    run grep -F "format('type=gha,scope={0}-${_target}-cache', steps.cache.outputs.key)" "${WF}"
    assert_success
    run grep -F "format('type=gha,scope={0}-${_target}-cache,mode=max', steps.cache.outputs.key)" "${WF}"
    assert_success
  done
}

@test "build-worker.yaml: 4 build steps emit a type=registry GHCR buildcache ref when cache_backend is registry (#801)" {
  # The registry branch of the ternary stores/reads the buildx cache in
  # GHCR (no 10 GB GHA ceiling): type=registry,ref=ghcr.io/<repo>/buildcache
  # tagged per target, with mode=max on cache-to.
  for _target in devel-test devel runtime-test runtime; do
    run grep -F "format('type=registry,ref=ghcr.io/{0}/buildcache:{1}-${_target}-cache', github.repository, steps.cache.outputs.key)" "${WF}"
    assert_success
    run grep -F "format('type=registry,ref=ghcr.io/{0}/buildcache:{1}-${_target}-cache,mode=max', github.repository, steps.cache.outputs.key)" "${WF}"
    assert_success
  done
}

@test "build-worker.yaml: extra_stages loop honors cache_backend for both backends (#801)" {
  # A caller using cache_backend: registry AND extra_stages must not get
  # those stages silently gha-cached. The extra_stages buildx loop receives
  # the backend + repo via env and selects the cache ref in shell with the
  # same registry/gha shapes as the four standard steps (registry ref with
  # mode=max on cache-to; gha branch byte-for-byte unchanged).
  run grep -F 'CACHE_BACKEND: ${{ inputs.cache_backend }}' "${WF}"
  assert_success
  run grep -F 'REPO: ${{ github.repository }}' "${WF}"
  assert_success
  # Shell selection helpers emit the registry ref (unique %s printf form,
  # distinct from the four steps' format() {0}/{1}) and the unchanged gha form.
  run grep -F 'type=registry,ref=ghcr.io/%s/buildcache:%s' "${WF}"
  assert_success
  run grep -F 'type=registry,ref=ghcr.io/%s/buildcache:%s,mode=max' "${WF}"
  assert_success
  run grep -F 'type=gha,scope=%s' "${WF}"
  assert_success
  # The loop no longer hardwires a gha cache ref on the buildx invocations.
  run grep -F '"type=gha,scope=${CACHE_KEY}' "${WF}"
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
  # Both buildx invocations (test-stage + stage) call the selection helpers.
  run grep -cF -e '--cache-from "$(cache_from_for ' "${WF}"
  assert_success
  assert_output "2"
  run grep -cF -e '--cache-to "$(cache_to_for ' "${WF}"
  assert_success
  assert_output "2"
}

@test "build-worker.yaml: cache lines select the backend on inputs.cache_backend (#801)" {
  # Both cache-from and cache-to (8 lines total) gate on the input so the
  # backend is chosen per call, defaulting to gha.
  run grep -cE "^          cache-(from|to): \\\$\{\{ inputs\.cache_backend == 'registry'" "${WF}"
  assert_success
  assert_output "8"
}

@test "build-worker.yaml: 4 distinct cache scopes exist, no shared scope leftover (#378 b1)" {
  # Negative regression: ensure no legacy `cache-from:`/`cache-to:` line
  # still references the bare base key (which would mean a build step
  # was missed in the per-target migration).
  run grep -cE '^          cache-(from|to): type=gha,scope=\$\{\{ steps\.cache\.outputs\.key \}\}(,|$)' "${WF}"
  [ "${status}" -ne 0 ] || [ "${output}" = "0" ]
}

@test "build-worker.yaml: 4 build steps all set mode=max on cache-to for both backends (#272 preserved, #801)" {
  # mode=max exports all intermediate stage layers (including the heavy
  # builder / source-build stages). Both ternary branches (gha default +
  # registry) carry mode=max on cache-to; 4 cache-to lines * both
  # branches = 4 gha + 4 registry mode=max occurrences.
  # gha default branch is the `|| format(...)` fallback, so its cache-to
  # format() ends the whole `${{ ... }}` expression ( `) }}` ).
  run grep -cF ",mode=max', steps.cache.outputs.key) }}" "${WF}"
  assert_success
  assert_output "4"
  # registry branch is the `&& format(...)` arm, so its cache-to format()
  # is followed by the `||` fallback ( `) ||` ).
  run grep -cF ",mode=max', github.repository, steps.cache.outputs.key) ||" "${WF}"
  assert_success
  assert_output "4"
}

@test "build-worker.yaml: declares cache_backend input with default gha (#801)" {
  # Opt-in registry cache backend; default gha keeps every existing
  # caller byte-for-byte unchanged (no 10 GB GHA ceiling escape unless
  # asked for).
  run grep -A 3 '^      cache_backend:' "${WF}"
  assert_success
  assert_output --partial 'required: false'
  assert_output --partial 'type: string'
  assert_output --partial 'default: "gha"'
}

@test "build-worker.yaml: cache_backend default preserves the gha backend for existing callers (#801)" {
  local _cb
  _cb="$(grep -A 3 '^      cache_backend:' "${WF}" | grep 'default:' | head -1)"
  [[ "${_cb}" == *'"gha"'* ]]
}

@test "build-worker.yaml: GHCR login step is gated on cache_backend == registry (#801)" {
  # The registry backend pushes cache to ghcr.io/<repo>/buildcache and
  # needs an authenticated buildx session; the default gha path adds no
  # login. Assert both the docker/login-action use and its cache_backend
  # gate are present.
  run grep -E '^[[:space:]]+uses: docker/login-action@' "${WF}"
  assert_success
  run grep -F "if: \${{ inputs.cache_backend == 'registry' }}" "${WF}"
  assert_success
}

@test "build-worker.yaml: cache_variant default preserves zero-diff for single-call callers (#272)" {
  # Single-distro repos (agent/* + ros1_bridge-${distro} pattern) leave
  # cache_variant unset; the scope key reduces to
  # ${image_name}-${hardware}-<target>-cache (b1), which is still
  # per-(repo, arch) and now also per-target.
  local _cv
  _cv="$(grep -A 3 '^      cache_variant:' "${WF}" | grep 'default:' | head -1)"
  [[ "${_cv}" == *'""'* ]]
}

# ── Phase 1: doc-only PR fast-pass ────────────────────────────────

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

# ──opt-in free_disk_space for large BASE_IMAGE repos ───────────

@test "build-worker.yaml: declares free_disk_space input as boolean default false (#470)" {
  # Opt-in step that pre-clears ~30 GB of pre-installed runner tooling
  # (Android SDK, .NET, GHC, ...) so repos whose BASE_IMAGE doesn't fit
  # in ubuntu-latest's ~14 GB (Isaac Sim ~15 GB extracted) stop hitting
  # `no space left on device` during BuildKit COPY. Default false so
  # the ~30 s cleanup overhead doesn't tax existing small-image callers.
  run grep -A 3 '^      free_disk_space:' "${WF}"
  assert_success
  assert_output --partial 'required: false'
  assert_output --partial 'type: boolean'
  assert_output --partial 'default: false'
}

@test "build-worker.yaml: Free disk space step gated on inputs.free_disk_space (#470)" {
  # The step is opt-in; without the gate every existing caller would
  # pay the cleanup time even when they don't need it.
  run grep -E "^[[:space:]]+if: \\\$\{\{ inputs\\.free_disk_space \\}\}$" "${WF}"
  assert_success
}

@test "build-worker.yaml: Free disk space step uses jlumbroso/free-disk-space (#470)" {
  # The community action removes Android SDK / .NET / GHC / tool-cache
  # without touching docker daemon state, which is what we need before
  # buildx starts pulling the BASE_IMAGE.
  run grep -E '^[[:space:]]+uses: jlumbroso/free-disk-space@' "${WF}"
  assert_success
}

@test "build-worker.yaml: Free disk space step runs before Set up Docker Buildx (#470)" {
  # Order matters — buildx allocates its overlayfs snapshot dir before
  # the first COPY, so disk must be freed earlier in the job.
  local _free _buildx
  _free="$(grep -n '^      - name: Free disk space$' "${WF}" | cut -d: -f1)"
  _buildx="$(grep -n '^      - name: Set up Docker Buildx$' "${WF}" | cut -d: -f1)"
  [[ -n "${_free}" ]] || { echo "Free disk space step missing"; return 1; }
  [[ -n "${_buildx}" ]] || { echo "Set up Docker Buildx step missing"; return 1; }
  [[ "${_free}" -lt "${_buildx}" ]] || {
    echo "expected Free disk space (line ${_free}) before Set up Docker Buildx (line ${_buildx})"
    return 1
  }
}

# ── worker logic pushed down to host-testable shell scripts ────────────

@test "build-worker.yaml: compute-matrix delegates to the extracted compute_matrix.sh (#802)" {
  # The platform -> matrix logic (the "a matrix condition that produces no
  # jobs" semantic break) is pushed down into a pure-shell, host-testable
  # script covered by build_worker_compute_matrix_spec.bats. The YAML step
  # must call the script and keep only the GITHUB_OUTPUT plumbing -- the old
  # inline `case linux/amd64)` fan-out logic must be gone from the YAML.
  run grep -F 'bash .worker-base/script/ci/build_worker/compute_matrix.sh' "${WF}"
  assert_success
  run grep -F 'echo "matrix=${matrix}" >> "${GITHUB_OUTPUT}"' "${WF}"
  assert_success
  # No leftover inline platform fan-out (would mean the extraction was
  # half-done and the untested inline copy could drift).
  run grep -F '{"platform":"linux/amd64","runner":"ubuntu-latest","hardware":"x86_64"}' "${WF}"
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
}

@test "build-worker.yaml: compute-matrix version-matches the script via job_workflow_sha (#802)" {
  # The script is fetched from base at the SAME ref as this workflow, so the
  # resolver can never drift from the worker it feeds -- the exact
  # version-match pattern the caller-contract preflight uses. Assert the compute-matrix
  # job checks out ycpss91255-docker/base at github.job_workflow_sha into
  # the .worker-base path the delegating call reads from.
  run awk '/^  compute-matrix:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'repository: ycpss91255-docker/base'
  assert_output --partial 'ref: ${{ github.job_workflow_sha }}'
  assert_output --partial 'path: .worker-base'
}

@test "build-worker.yaml: Compute cache scope delegates to the extracted cache_scope.sh (#802)" {
  # The base-key derivation (with its per-target cache-scope bug history) is pushed
  # down into a pure-shell, host-testable script covered by
  # build_worker_cache_scope_spec.bats. The step must call the script,
  # feed it IMAGE_NAME / CACHE_VARIANT / HARDWARE via env, and keep only
  # the GITHUB_OUTPUT plumbing; the old inline `base="..."` derivation must
  # be gone.
  run grep -F 'bash .worker-base/script/ci/build_worker/cache_scope.sh' "${WF}"
  assert_success
  run grep -F 'echo "key=${key}" >> "${GITHUB_OUTPUT}"' "${WF}"
  assert_success
  run grep -F 'IMAGE_NAME: ${{ inputs.image_name }}' "${WF}"
  assert_success
  run grep -F 'CACHE_VARIANT: ${{ inputs.cache_variant }}' "${WF}"
  assert_success
  # No leftover inline scope derivation (would mean an untested copy could
  # drift from the tested script).
  run grep -F 'base="${{ inputs.image_name }}"' "${WF}"
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
}

@test "build-worker.yaml: build job checks out base worker source at job_workflow_sha into .worker-base (#802)" {
  # The cache-scope script the build job runs is fetched at the worker's own
  # ref, isolated in .worker-base so it never collides with the caller
  # checkout at the workspace root.
  run awk '/^  build:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'repository: ycpss91255-docker/base'
  assert_output --partial 'ref: ${{ github.job_workflow_sha }}'
  assert_output --partial 'path: .worker-base'
}

# ── Run-scoped names + cleanup, downstream half ────────────────

@test "build-worker.yaml: the workspace path it writes is keyed to the run (#900)" {
  # This is the downstream half of the same rule: every name CI creates
  # must differ between two runs that share a host. The worker builds with
  # `push: false` and no `tags:`, so it produces no NAMED docker artifact
  # today -- but it does write a fixed host path into the .env it
  # generates, and `runs-on: ${{ matrix.runner }}` is exactly the knob a
  # self-hosted migration turns.
  run grep -c 'WS_PATH=/tmp/workspace-ci-${{ github.run_id }}-${{ github.run_attempt }}' "${WF}"
  assert_success
  assert_output '1'
  run grep -n 'WS_PATH=/tmp/workspace$' "${WF}"
  assert_failure
}

@test "build-worker.yaml: the build job reclaims its own leftovers on if: always() (#900)" {
  # Reached through the SAME .worker-base checkout the cache-scope script
  # uses, so the collector is version-matched to the worker rather than
  # copied into every caller repo.
  run awk '/^  build:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'bash .worker-base/script/ci/reclaim.sh'
  assert_output --partial 'if: always()'
}

@test "build-worker.yaml: downstream cleanup is ownership-scoped too (#900)" {
  # A downstream self-hosted host is shared with every other repo in the
  # org. A blanket prune there is worse, not better. Comment lines are
  # stripped first -- the rationale for a prohibition names the command it
  # rules out.
  run bash -c "grep -vE '^[[:space:]]*#' '${WF}' \
    | grep -E 'docker system prune|image prune -a|docker volume prune'"
  assert_failure
}
