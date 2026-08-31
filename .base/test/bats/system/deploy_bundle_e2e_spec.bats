#!/usr/bin/env bats
#
# System-level end-to-end: a REAL field deploy (ISTQB System level,
# ADR-00000018; ADR-00000023). Exercises the full orchestration for real --
# generate the bundle (real docker build + docker save | xz), docker-load
# the image, run the generated deploy.sh up (real docker compose up -d),
# assert the container is Up, then assert the tunable-config override applies
# at the mounted container path (edit the bundle config/, re-up, read it back
# in the container), and tear down with deploy.sh down.
#
# Minimal + fast on purpose: a tiny alpine `runtime` stage that runs a
# long-lived `sleep` and bakes one tunable config file. The point is the
# orchestration (build -> save -> load -> compose up -> mount-wins override
# -> down), not a heavy image.
#
# The fixture repo is a REAL git tree with a tag, and its basename is
# run-unique: the deploy stamp then resolves to that tag instead of the
# `unknown` fallback (so the version-scoped image identity is what gets
# built, loaded and asserted), and no container left behind by a crashed
# earlier run can share this run's `docker ps --filter name=` namespace.
#
# Requires the ci-system compose service (mounts host /var/run/docker.sock +
# the docker compose plugin + xz in the test-tools image). Auto-skips when
# the socket / plugin / xz is absent so accidental invocation via the default
# `ci` service is harmless. Run it with `just test system`.
#
# Plain-bash assertions only (status / output), matching the sibling
# runtime_test_smoke_spec.bats: the system bats environment ships no
# bats-assert / bats-support and loads no test_helper.

setup_file() {
  # Every test in this file drives ONE bundle and ONE container name, so they
  # must not run concurrently with each other: two `deploy.sh up` calls racing
  # for the same container name make the loser fail with a name conflict. The
  # suite still parallelizes across FILES.
  export BATS_NO_PARALLELIZE_WITHIN_FILE=true

  if [[ ! -S /var/run/docker.sock ]]; then
    skip "system test: /var/run/docker.sock not mounted (run via 'just test system')"
  fi
  if ! command -v docker >/dev/null 2>&1; then
    skip "system test: docker CLI not present"
  fi
  if ! docker compose version >/dev/null 2>&1; then
    skip "system test: docker compose plugin not present"
  fi
  if ! command -v xz >/dev/null 2>&1; then
    skip "system test: xz not present"
  fi

  export LOG_FORMAT=text
  # shellcheck disable=SC1091
  source /source/dist/script/docker/wrapper/setup.sh

  # Fixture repo: the dir basename becomes the image name (detect_image_name
  # @basename rule). A tiny runtime stage that bakes one tunable config file
  # and runs a long-lived process.
  #
  # Build the bundle under the SAME-PATH host mount (see compose.yaml
  # ci-system): the generated deploy.sh runs `docker compose up`, whose
  # bind-mount sources the HOST daemon resolves -- a bundle in this
  # container's private /tmp is invisible to that daemon. Placing it at a
  # path mounted identically on host + container makes the config bind
  # resolve. Outside ci-system (a plain local daemon) it is just a temp dir.
  local _align="/tmp/base-deploy-e2e"
  mkdir -p "${_align}"
  # The same-path mount is shared across runs and teardown_file only removes
  # this run's TMP_ROOT, so fixture dirs left behind by a crashed run would
  # accumulate on the host forever. Prune the old ones, age-bounded so a
  # concurrently running invocation's live dir is never touched.
  find "${_align}" -maxdepth 1 -type d -name 'e2e-*' -mmin +120 \
    -exec rm -rf {} + >/dev/null 2>&1 || true
  TMP_ROOT="$(mktemp -d "${_align}/e2e-XXXXXX")"
  # Run-unique repo basename: it becomes BOTH the image name and the
  # container name, so a container leaked by a crashed earlier run can never
  # satisfy (or break) this run's `docker ps --filter name=` assertions.
  # Lowercased because an image reference must be lowercase.
  local _uniq; _uniq="$(printf '%s' "${TMP_ROOT##*/e2e-}" | tr '[:upper:]' '[:lower:]')"
  REPO="${TMP_ROOT}/deploydemo-${_uniq}"
  mkdir -p "${REPO}/config/app_cfg"

  printf '%s\n' \
    "[deploy]" "gpu_mode = off" "dri_groups = off" \
    "[gui]" "mode = off" \
    > "${REPO}/.setup.conf"

  cat > "${REPO}/Dockerfile" <<'DOCK'
FROM alpine:3.20 AS sys
FROM sys AS runtime
RUN mkdir -p /etc/app && printf 'baked-default\n' > /etc/app/host.yaml
RUN mkdir -p /var/lib/app && printf 'baked-calib\n' > /var/lib/app/calib.yaml
CMD ["sleep", "infinity"]
DOCK

  # Tunable-config manifest: one operator-tunable path with the default
  # (read-only) access, one that explicitly opts into container writes.
  printf '%s\n' "[runtime]" "/etc/app/host.yaml" "/var/lib/app/calib.yaml rw" \
    > "${REPO}/config/app_cfg/deploy.manifest"

  # Make the fixture a REAL tagged git tree so _resolve_deploy_version
  # resolves the tag and the whole e2e exercises the version-scoped image
  # identity `<repo>:<stage>-<version>` -- the collision avoidance the stamp
  # exists for. Left un-inited it degraded to `unknown`, so the one real
  # end-to-end test only ever covered the fallback. Everything is committed
  # before the stamp is read, so the tree is clean (no `-dirty` suffix); the
  # generated deploy/ folder lands untracked, which `describe --dirty`
  # ignores.
  FIXTURE_TAG="v1.4.2"
  git -C "${REPO}" init -q
  git -C "${REPO}" config user.email e2e@test
  git -C "${REPO}" config user.name e2e
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -qm "e2e fixture"
  git -C "${REPO}" tag "${FIXTURE_TAG}"

  local _repo_name="${REPO##*/}"
  VERSION="$(_resolve_deploy_version "${REPO}")"
  BUNDLE="${REPO}/deploy/${_repo_name}-runtime-${VERSION}"
  CNAME="${_repo_name}-runtime"
  IMAGE="${_repo_name}:runtime-${VERSION}"
  export TMP_ROOT REPO BUNDLE CNAME IMAGE VERSION FIXTURE_TAG

  # Belt and braces on top of the run-unique name: never inherit a container
  # that some earlier run left holding this exact name.
  docker rm -f "${CNAME}" >/dev/null 2>&1 || true

  # Generate the bundle for real (docker build + save | xz + config extract).
  # A failure here is a genuine deploy bug (the socket/plugin/xz are present),
  # so fail loudly with the captured output rather than skipping.
  local _gen_out=""
  if ! _gen_out="$(_setup_deploy --base-path "${REPO}" --stage runtime -y -q 2>&1)"; then
    printf 'bundle generation FAILED:\n%s\n' "${_gen_out}" >&2
    return 1
  fi
}

teardown_file() {
  if [[ -n "${BUNDLE:-}" && -f "${BUNDLE}/deploy.sh" ]]; then
    "${BUNDLE}/deploy.sh" down >/dev/null 2>&1 || true
  fi
  # The run-unique name means nothing else can own it -- remove it even when
  # deploy.sh down could not (a half-created container leaks otherwise).
  [[ -n "${CNAME:-}" ]] && docker rm -f "${CNAME}" >/dev/null 2>&1 || true
  [[ -n "${IMAGE:-}" ]] && docker rmi -f "${IMAGE}" >/dev/null 2>&1 || true
  [[ -n "${TMP_ROOT:-}" ]] && rm -rf "${TMP_ROOT}"
}

@test "field-deploy e2e: the image identity is version-stamped, not the 'unknown' fallback" {
  # The stamp is the collision avoidance for loading multiple field versions
  # on one host, so the e2e must run against a real tagged tree.
  [ "${VERSION}" = "${FIXTURE_TAG}" ]
  [[ "${IMAGE}" == *":runtime-${FIXTURE_TAG}" ]]
  [[ "${IMAGE}" != *"unknown"* ]]
  [[ "${BUNDLE}" == *"-runtime-${FIXTURE_TAG}" ]]
}

@test "field-deploy e2e: the generator produced a self-contained bundle folder" {
  [ -d "${BUNDLE}" ]
  [ -f "${BUNDLE}/image.tar.xz" ]
  [ -x "${BUNDLE}/deploy.sh" ]
  [ -f "${BUNDLE}/config/host.yaml" ]
  [ -f "${BUNDLE}/config/calib.yaml" ]

  run cat "${BUNDLE}/compose.yaml"
  [ "${status}" -eq 0 ]
  # Fully resolved -- no compose variable interpolation survives.
  [[ "${output}" != *'${'* ]]
  [[ "${output}" == *"image: ${IMAGE}"* ]]
  [[ "${output}" == *"restart: unless-stopped"* ]]
  [[ "${output}" == *"- ./config/host.yaml:/etc/app/host.yaml:ro"* ]]
  [[ "${output}" == *"- ./config/calib.yaml:/var/lib/app/calib.yaml:rw"* ]]
}

@test "field-deploy e2e: deploy.sh up loads the image, runs the container, and the tunable override applies" {
  # Real load + compose up. Echo output on failure so a genuine deploy bug
  # is debuggable in the CI log rather than a bare non-zero status.
  run "${BUNDLE}/deploy.sh" up
  [ "${status}" -eq 0 ] || { echo "deploy.sh up failed (status=${status}):"; echo "${output}"; false; }

  # The image the field host loaded really carries the version-scoped ref.
  run docker image inspect "${IMAGE}"
  [ "${status}" -eq 0 ] || { echo "loaded image ${IMAGE} not present: ${output}"; false; }

  # The container is actually running.
  run docker ps --filter "name=${CNAME}" --filter "status=running" --format '{{.Names}}'
  [[ "${output}" == *"${CNAME}"* ]] || { echo "container not running; docker ps: ${output}"; false; }

  # The mounted editable copy carries the image's baked default.
  run docker exec "${CNAME}" cat /etc/app/host.yaml
  [ "${status}" -eq 0 ] || { echo "exec failed: ${output}"; false; }
  [[ "${output}" == *"baked-default"* ]]

  # Edit the bundle config in the "field" and re-up: the mount wins over the
  # baked default, so the container now sees the edited value (no rebuild).
  printf 'edited-in-field\n' > "${BUNDLE}/config/host.yaml"
  run "${BUNDLE}/deploy.sh" up
  [ "${status}" -eq 0 ] || { echo "deploy.sh re-up failed (status=${status}):"; echo "${output}"; false; }
  run docker exec "${CNAME}" cat /etc/app/host.yaml
  [ "${status}" -eq 0 ] || { echo "exec after override failed: ${output}"; false; }
  [[ "${output}" == *"edited-in-field"* ]] || { echo "override not applied; got: ${output}"; false; }

  # deploy.sh down stops it.
  run "${BUNDLE}/deploy.sh" down
  [ "${status}" -eq 0 ] || { echo "deploy.sh down failed: ${output}"; false; }
  run docker ps --filter "name=${CNAME}" --filter "status=running" --format '{{.Names}}'
  [[ "${output}" != *"${CNAME}"* ]]
}

@test "field-deploy e2e: a container write to an undeclared-rw tunable really FAILS, a declared rw one lands on the host" {
  # The whole point of the read-only default is that the failure is real and
  # immediate, so this asserts the container's write, not the `:ro` string.
  run "${BUNDLE}/deploy.sh" up
  [ "${status}" -eq 0 ] || { echo "deploy.sh up failed (status=${status}):"; echo "${output}"; false; }

  local _before
  _before="$(cat "${BUNDLE}/config/host.yaml")"

  # Default access: the container cannot write the mounted config at all.
  run docker exec "${CNAME}" sh -c 'printf container-wrote > /etc/app/host.yaml'
  [ "${status}" -ne 0 ] || { echo "write to a read-only tunable SUCCEEDED: ${output}"; false; }
  [[ "${output}" == *"ead-only file system"* ]] || { echo "unexpected write error: ${output}"; false; }
  # ... and the operator's copy on the host is untouched.
  [ "$(cat "${BUNDLE}/config/host.yaml")" = "${_before}" ]

  # Declared `rw`: the write succeeds and reaches the host-side bundle copy.
  run docker exec "${CNAME}" sh -c 'printf container-wrote > /var/lib/app/calib.yaml'
  [ "${status}" -eq 0 ] || { echo "write to a declared-rw tunable failed: ${output}"; false; }
  run cat "${BUNDLE}/config/calib.yaml"
  [[ "${output}" == *"container-wrote"* ]] || { echo "rw write did not reach the host copy: ${output}"; false; }

  run "${BUNDLE}/deploy.sh" down
  [ "${status}" -eq 0 ] || { echo "deploy.sh down failed: ${output}"; false; }
}
