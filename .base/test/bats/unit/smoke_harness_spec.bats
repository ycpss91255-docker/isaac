#!/usr/bin/env bats
#
# Static checks for the LOCAL smoke harness -- `just test smoke`, the
# dockerfile/Dockerfile.smoke image behind it, and the compose service that
# builds it. The harness exists so the shipped smoke specs
# (dist/test/bats/smoke/) can be run in one command instead of being
# hand-reproduced with raw `docker build` / `docker run` every time someone
# needs to know whether one of them actually works.
#
# A harness is only worth having if it stays FAITHFUL to the Dockerfile
# `-test` stage it stands in for, so the load-bearing test here is not
# "the recipe exists" -- it is the COPY-set parity check below, which fails
# the moment the shipped devel-test stage populates /lint or /smoke_test
# from a path the harness does not. The behavioural half (the specs really
# run, they really run non-root, and a failing spec really fails the build)
# needs a docker daemon and lives in
# test/bats/system/smoke_harness_spec.bats.
#
# Pure file reads, no docker: Unit level (ADR-00000018).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  ROOT=/source
  # The shipped template, whose devel-test stage is what the harness
  # stands in for.
  TEMPLATE_DOCKERFILE="${ROOT}/dist/dockerfile/Dockerfile"
  # The harness itself.
  HARNESS_DOCKERFILE="${ROOT}/dockerfile/Dockerfile.smoke"
  JUSTFILE_TEST="${ROOT}/script/test/justfile.test"
  COMPOSE="${ROOT}/compose.yaml"
}

# ── helpers ─────────────────────────────────────────────────────────────────

# _devel_test_copy_lines -- every uncommented `COPY` line of the shipped
# template's devel-test stage, one per line, whitespace-collapsed.
#
# Bounded by the stage header and the next `FROM` so a COPY belonging to
# runtime-test (or to devel) can never be read as devel-test's.
_devel_test_copy_lines() {
  awk '
    /^FROM devel AS devel-test/ { in_stage = 1; next }
    in_stage && /^FROM / { in_stage = 0 }
    in_stage && /^COPY / {
      line = $0
      gsub(/[ \t]+/, " ", line)
      print line
    }
  ' "${TEMPLATE_DOCKERFILE}"
}

# _harness_copy_lines -- the same, for the harness (single stage, so every
# uncommented COPY counts).
_harness_copy_lines() {
  awk '
    /^COPY / {
      line = $0
      gsub(/[ \t]+/, " ", line)
      print line
    }
  ' "${HARNESS_DOCKERFILE}"
}

# _copy_src <line> / _copy_dest <line> -- the source and destination of a
# whitespace-collapsed COPY line, with any leading `--flag` arguments
# dropped. Multi-source COPY is not used by either file; if it ever is, the
# source read here is the first one and the parity check below reports a
# mismatch rather than passing silently.
_copy_src() {
  local _line="${1}" _tok
  # Word-split with globbing OFF: `COPY script/*.sh /lint/` is a real COPY
  # source, and an unguarded split would expand it against the current
  # directory into whatever happens to be there.
  set -f
  # shellcheck disable=SC2086  # deliberate word split over the collapsed line
  set -- ${_line}
  set +f
  shift  # the COPY verb itself
  for _tok in "$@"; do
    [[ "${_tok}" == --* ]] && continue
    printf '%s\n' "${_tok}"
    return 0
  done
}

_copy_dest() {
  local _line="${1}"
  printf '%s\n' "${_line##* }"
}

# _template_to_harness_src <src> -- the path a consumer's `.base/dist/...`
# COPY source is called inside base's own checkout. base IS the template
# source, so it carries no `.base/` subtree (ADR-00000011 sec.4): the
# vendored copy a consumer reads at `.base/dist/X` is base's own `dist/X`.
# Everything else is passed through unchanged.
_template_to_harness_src() {
  printf '%s\n' "${1#.base/}"
}

# Sources the devel-test stage COPYs into /lint or /smoke_test that the
# harness deliberately does NOT reproduce, each with the reason. Anything
# NOT listed here has to be in the harness -- that is what makes a new COPY
# in the shipped stage fail this spec instead of quietly leaving the
# harness a stage behind.
_HARNESS_EXEMPT_SRCS=(
  # Lint inputs, consumed by the stage's shellcheck / hadolint RUN lines,
  # never by a smoke spec. base's own lint gate covers both (`just test
  # lint`), against dist/.hadolint.yaml and the real template Dockerfile.
  '.hadolint.yaml'
  'Dockerfile'
  # The per-repo smoke overlay. It is the CONSUMER's spec tree; base ships
  # none (test/bats/smoke/ does not exist here), and inventing one would
  # make the harness assert against a fixture instead of the shipped specs.
  'test/bats/smoke/shared/'
  'test/bats/smoke/devel-test/'
)

# ── the harness exists and is wired through the docker namespace ────────────

@test "the smoke harness ships a dockerfile and a compose service that builds it" {
  assert [ -f "${HARNESS_DOCKERFILE}" ]
  run grep -nE '^\s{2}smoke:' "${COMPOSE}"
  assert_success
  run grep -nE 'dockerfile:\s*dockerfile/Dockerfile\.smoke' "${COMPOSE}"
  assert_success
}

@test "just test smoke builds through the docker namespace, not a raw docker build (ADR-00000011 sec.5)" {
  # The same rule `just test system` follows: the tooling image and the
  # harness both go through the wrapper consumers use, so the local run and
  # the shipped path cannot drift into two different build commands.
  run grep -nE 'just docker build .*--target smoke' "${JUSTFILE_TEST}"
  assert_success
  run grep -nE 'docker build .* -f dockerfile/Dockerfile\.smoke' "${JUSTFILE_TEST}"
  assert_failure
}

@test "just test smoke resolves the tooling image and names the compose project (#896, #891)" {
  # TEST_TOOLS_IMAGE has no default anywhere -- not in compose.yaml, not in
  # the wrapper -- so every entry point resolves it or is refused. The
  # project name is the same story for the checkout's containers: without
  # it compose falls back to the directory BASENAME and two checkouts share
  # one project.
  local _recipe
  _recipe="$(awk '/^smoke( |:)/ { in_r = 1; next } in_r && /^[a-z]/ { in_r = 0 } in_r' \
    "${JUSTFILE_TEST}")"
  [[ "${_recipe}" == *'test.sh --test-tools-image'* ]]
  [[ "${_recipe}" == *'test.sh --compose-project-name'* ]]
  [[ "${_recipe}" == *'export TEST_TOOLS_IMAGE'* ]]
  [[ "${_recipe}" == *'export COMPOSE_PROJECT_NAME'* ]]
}

@test "just test smoke names the image it builds after the resolved project, not the directory (#891)" {
  # COMPOSE_PROJECT_NAME alone does NOT reach this build: it goes through
  # the wrapper, which passes `docker compose -p "${PROJECT_NAME}"`
  # explicitly, and with nothing set that falls back to the checkout
  # DIRECTORY BASENAME -- so two same-named checkouts write one
  # `<project>-smoke` tag. The recipe seeds PROJECT_NAME from the same
  # resolved value the rest of the self-test uses.
  local _recipe
  _recipe="$(awk '/^smoke( |:)/ { in_r = 1; next } in_r && /^[a-z]/ { in_r = 0 } in_r' \
    "${JUSTFILE_TEST}")"
  [[ "${_recipe}" == *'PROJECT_NAME="${COMPOSE_PROJECT_NAME}"'* ]]
  [[ "${_recipe}" == *'export PROJECT_NAME'* ]]
}

@test "just test smoke is NOT wired into the default just test gate" {
  # Deliberate, and asserted rather than left to habit: the shipped smoke
  # specs are build-time assertions of a Dockerfile stage, a different test
  # level from the self-test the default gate runs, and the harness needs a
  # docker daemon plus an image build. Folding it in would make the fast
  # gate a docker build. The `default` recipe therefore stays test.sh only.
  local _default
  _default="$(awk '/^default:/ { in_r = 1; next } in_r && /^[a-z]/ { in_r = 0 } in_r' \
    "${JUSTFILE_TEST}")"
  [[ "${_default}" != *smoke* ]]
}

# ── fidelity: the COPY set ──────────────────────────────────────────────────

@test "the harness reproduces every devel-test COPY into /lint and /smoke_test" {
  # The load-bearing assertion. A harness whose COPY set has fallen behind
  # the stage it stands in for is worse than no harness: it reports green
  # for a stage that would be red. Adding a COPY to the shipped devel-test
  # stage therefore fails HERE until the harness follows it (or the source
  # is added to _HARNESS_EXEMPT_SRCS with a reason).
  local _harness_lines
  _harness_lines="$(_harness_copy_lines)"

  local _line _src _dest _want _exempt _matched _checked=0
  while IFS= read -r _line; do
    [[ -n "${_line}" ]] || continue
    # `COPY --from=<stage>` brings the toolchain in from the test-tools
    # image; the harness IS that image, so it has nothing to copy.
    [[ "${_line}" == *"--from="* ]] && continue
    _src="$(_copy_src "${_line}")"
    _dest="$(_copy_dest "${_line}")"
    [[ "${_dest}" == /lint* || "${_dest}" == /smoke_test* ]] || continue

    _matched=false
    for _exempt in "${_HARNESS_EXEMPT_SRCS[@]}"; do
      [[ "${_src}" == "${_exempt}" ]] && _matched=true && break
    done
    [[ "${_matched}" == true ]] && continue

    _checked=$(( _checked + 1 ))
    _want="$(_template_to_harness_src "${_src}") ${_dest}"
    if [[ "${_harness_lines}" != *"${_want}"* ]]; then
      batslib_print_kv_single_or_multi 12 \
        "stage COPY" "${_line}" \
        "harness needs" "COPY ${_want}" \
        "harness has" "${_harness_lines}" \
        | batslib_decorate "smoke harness does not reproduce a devel-test COPY" \
        | fail
    fi
  done <<< "$(_devel_test_copy_lines)"

  # A parity loop that examined nothing would pass. The shipped stage
  # populates /lint from the wrappers + lib and /smoke_test from two spec
  # directories, so anything under four means the extraction broke.
  assert [ "${_checked}" -ge 4 ]
}

@test "every harness COPY exemption is still a real devel-test COPY" {
  # The other direction: an exemption whose COPY has since been deleted is
  # a licence to skip a source that no longer needs skipping, and the next
  # COPY added at that path would inherit the hole.
  local _stage_lines _exempt _found _line
  _stage_lines="$(_devel_test_copy_lines)"
  for _exempt in "${_HARNESS_EXEMPT_SRCS[@]}"; do
    _found=false
    while IFS= read -r _line; do
      [[ -n "${_line}" ]] || continue
      [[ "$(_copy_src "${_line}")" == "${_exempt}" ]] && _found=true && break
    done <<< "${_stage_lines}"
    if [[ "${_found}" != true ]]; then
      batslib_print_kv_single 12 "source" "${_exempt}" \
        | batslib_decorate "harness exemption names a COPY the devel-test stage no longer has" \
        | fail
    fi
  done
}

@test "the harness installs the entrypoint the shared smoke baseline asserts" {
  # smoke/shared/entrypoint.bats asserts /entrypoint.sh exists and is
  # executable. In a consumer that file arrives from the devel stage
  # (COPY --chmod=0755 "./${ENTRYPOINT_FILE}" "/entrypoint.sh"), which the
  # harness does not inherit -- so it installs the same shipped script
  # itself, from the path init.sh seeds a consumer's copy from.
  run grep -nE '^COPY --chmod=0755 dist/script/docker/runtime/entrypoint\.sh /entrypoint\.sh$' \
    "${HARNESS_DOCKERFILE}"
  assert_success
}

@test "the harness exports BATS_LIB_PATH like the devel-test stage does" {
  # The shared test_helper does `bats_load_library bats-support` /
  # `bats-assert`; without the library path they are not found and every
  # spec errors in setup.
  run grep -nE '^ENV BATS_LIB_PATH=' "${HARNESS_DOCKERFILE}"
  assert_success
  run grep -nE '^ENV BATS_LIB_PATH=' "${TEMPLATE_DOCKERFILE}"
  assert_success
}

# ── fidelity: who runs the specs ────────────────────────────────────────────

@test "the harness runs the specs as a non-root user, after the COPYs" {
  # The whole point of the fidelity argument. The real stage COPYs as root
  # and then drops to ${USER} before `RUN bats`, so a spec that needs write
  # access to /lint fails there. A harness that ran the same specs as root
  # would be green in exactly that case.
  local _user_line _bats_line
  _user_line="$(grep -n '^USER ' "${HARNESS_DOCKERFILE}" | tail -n1)"
  assert [ -n "${_user_line}" ]
  # Neither root by name nor by uid.
  [[ "${_user_line}" != *' root'* ]]
  [[ ! "${_user_line}" =~ USER[[:space:]]+\"?0 ]]

  # And the bats run comes after it, not before.
  _bats_line="$(grep -n '^RUN bats ' "${HARNESS_DOCKERFILE}" | head -n1)"
  assert [ -n "${_bats_line}" ]
  assert [ "${_user_line%%:*}" -lt "${_bats_line%%:*}" ]
}

@test "the harness asserts at BUILD time, exactly like the stage it stands in for" {
  # `RUN bats /smoke_test/` -- not a CMD a `docker run` may or may not
  # reach, and not a `|| true`. A failing spec has to fail the build, which
  # is what makes `just test smoke` a gate rather than a report.
  run grep -nE '^RUN bats /smoke_test/$' "${HARNESS_DOCKERFILE}"
  assert_success
  run grep -nE '^RUN bats .*\|\|' "${HARNESS_DOCKERFILE}"
  assert_failure
  run grep -nE '^RUN bats /smoke_test/$' "${TEMPLATE_DOCKERFILE}"
  assert_success
}

@test "the harness has no compose image name to displace a sibling checkout's (#891)" {
  # Every other service in this file names `${TEST_TOOLS_IMAGE}`; the
  # harness names nothing, so compose tags the build under the run's own
  # project. That is what keeps two checkouts (and two CI runs) from
  # writing one tag, and what makes the run-keyed CI teardown able to
  # reclaim it by name.
  local _svc
  _svc="$(awk '/^  smoke:/ { in_s = 1; next } in_s && /^  [a-z]/ { in_s = 0 } in_s' \
    "${COMPOSE}")"
  [[ -n "${_svc}" ]]
  [[ "${_svc}" != *$'\n    image:'* ]]
}

# ── scope: which stages the harness covers ──────────────────────────────────

@test "runtime-test ships no specs, which is why the harness covers devel-test only" {
  # The harness deliberately takes no stage argument: devel-test is the
  # only `-test` stage with shipped specs. runtime-test's real base is the
  # MINIMAL runtime image, so running the shared baseline against this
  # devel-shaped harness and calling the result "runtime-test" would be the
  # false green the harness exists to avoid.
  #
  # When runtime-test does gain specs, this fails -- which is the point:
  # that is the moment the stage argument (and a second harness image) has
  # to be decided, not the moment someone notices the specs never ran.
  run bash -c 'ls /source/dist/test/bats/smoke/runtime-test/*.bats 2>/dev/null'
  assert_failure
}
