#!/usr/bin/env bats
#
# Integration test: the field-deploy generator end-to-end across components
# (ADR-00000023; ISTQB Integration level, ADR-00000018). Drives the REAL
# _setup_deploy -> _generate_deploy_bundle flow over the filesystem against a
# fixture repo (a repo-root .setup.conf, a Dockerfile with a runtime stage,
# a config/<component>/deploy.manifest declaring one operator-tunable path)
# and asserts the produced OUTPUT FOLDER is correct:
# deploy/<repo>-<stage>-<version>/ with deploy.sh, a self-contained
# compose.yaml, an editable config/, a README, and image.tar.xz.
#
# This exercises the manifest -> resolve -> resolved-compose -> bundle-files
# WIRING as a flow, distinct from the isolated-function unit specs. It needs
# no real docker: a PATH-shim fakes the docker build/save/create/cp/rm calls
# (the same daemon-free pattern the unit dry-run tests use) so the real
# generator's file-writing + install path runs for real. The heavier
# build->load->compose-up->override lifecycle is the System-level sibling
# (test/bats/system/deploy_bundle_e2e_spec.bats), which needs host docker.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  # shellcheck disable=SC1091
  source /source/dist/script/docker/wrapper/setup.sh

  # The repo dir basename becomes the image name (detect_image_name's
  # @basename rule), so name it deterministically.
  TMP_ROOT="$(mktemp -d)"
  REPO="${TMP_ROOT}/fielddemo"
  mkdir -p "${REPO}"
  git -C "${REPO}" init -q
  git -C "${REPO}" config user.email t@t
  git -C "${REPO}" config user.name t

  # Repo-root .setup.conf (post-relocation location).
  printf '%s\n' \
    "[deploy]" "gpu_mode = off" "dri_groups = off" \
    "[gui]" "mode = off" \
    > "${REPO}/.setup.conf"

  cat > "${REPO}/Dockerfile" <<'DOCK'
FROM scratch AS sys
FROM sys AS devel
FROM devel AS runtime
CMD ["/app"]
DOCK

  # Tunable-config manifest: one operator-tunable container path for runtime.
  mkdir -p "${REPO}/config/camera"
  printf '%s\n' "[runtime]" "/etc/app/camera.yaml" \
    > "${REPO}/config/camera/deploy.manifest"

  git -C "${REPO}" add -A
  git -C "${REPO}" commit -qm init
  git -C "${REPO}" tag v0.0.1

  # docker PATH-shim: fakes the daemon calls so the real generator produces
  # a real output folder without a docker daemon. save writes the -o target
  # (real xz then compresses it); cp writes the extracted baked default.
  SHIM="$(mktemp -d)"
  cat > "${SHIM}/docker" <<'SH'
#!/usr/bin/env bash
case "$1" in
  build) exit 0 ;;
  save)
    shift
    while [[ $# -gt 0 ]]; do
      [[ "$1" == "-o" ]] && printf 'fake-image-archive\n' > "$2"
      shift
    done
    exit 0 ;;
  create) echo fakecid ; exit 0 ;;
  cp) printf 'baked-default\n' > "$3" ; exit 0 ;;
  rm) exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "${SHIM}/docker"

  # xz PATH-shim: the ci image has no xz; fake the compress by renaming the
  # saved (shimmed) image tar so the real generator's file path completes.
  cat > "${SHIM}/xz" <<'SH'
#!/usr/bin/env bash
_f=""
for _a in "$@"; do _f="${_a}"; done
[[ -f "${_f}" ]] && mv "${_f}" "${_f}.xz"
exit 0
SH
  chmod +x "${SHIM}/xz"

  # Run the real deploy flow (folder naming + generation) with docker shimmed.
  # Each bats test runs in its own process, so prepending the shim to PATH
  # here is scoped to this test.
  export PATH="${SHIM}:${PATH}"
  run _setup_deploy --base-path "${REPO}" --stage runtime -y
  DEPLOY_RUN_STATUS="${status}"
  DEPLOY_RUN_OUTPUT="${output}"
  BUNDLE="${REPO}/deploy/fielddemo-runtime-v0.0.1"
  export TMP_ROOT REPO SHIM BUNDLE DEPLOY_RUN_STATUS DEPLOY_RUN_OUTPUT
}

teardown() {
  [[ -n "${TMP_ROOT:-}" ]] && rm -rf "${TMP_ROOT}"
  [[ -n "${SHIM:-}" ]] && rm -rf "${SHIM}"
}

@test "deploy flow: produces the version-named output folder with all bundle files (field-deploy)" {
  [ "${DEPLOY_RUN_STATUS}" -eq 0 ]
  [ -d "${BUNDLE}" ]
  [ -f "${BUNDLE}/compose.yaml" ]
  [ -x "${BUNDLE}/deploy.sh" ]
  [ -f "${BUNDLE}/README" ]
  [ -f "${BUNDLE}/image.tar.xz" ]
  [ -d "${BUNDLE}/config" ]
}

@test "deploy flow: the resolved compose is self-contained and pins the versioned image (field-deploy)" {
  run cat "${BUNDLE}/compose.yaml"
  assert_success
  # Fully resolved -- no compose variable interpolation survives.
  refute_output --partial '${'
  assert_output --partial "image: fielddemo:runtime-v0.0.1"
  assert_output --partial "container_name: fielddemo-runtime"
  assert_output --partial "restart: unless-stopped"
}

@test "deploy flow: the manifest path is delivered as an editable copy + a mount-wins bind (field-deploy)" {
  # The compose binds the tunable file over its baked default.
  run cat "${BUNDLE}/compose.yaml"
  assert_output --partial "- ./config/camera.yaml:/etc/app/camera.yaml"
  # The baked default was extracted into the editable config/ folder.
  [ -f "${BUNDLE}/config/camera.yaml" ]
  run cat "${BUNDLE}/config/camera.yaml"
  assert_output --partial "baked-default"
}

@test "deploy flow: the thin launcher drives docker load + compose up/down (field-deploy)" {
  run cat "${BUNDLE}/deploy.sh"
  assert_success
  assert_output --partial "docker load"
  assert_output --partial "docker compose up -d"
  assert_output --partial "docker compose down"
  # No inlined docker run flags -- the compose carries everything.
  refute_output --partial "docker run"
}

@test "deploy flow: the bundle compose carries the watchdog env + the configured restart end to end (#840)" {
  # Re-run the real flow over a conf that sets the [lifecycle] knobs, so the
  # resolve -> resolved-compose -> bundle wiring is exercised, not just the
  # isolated emitter.
  printf '%s\n' \
    "[deploy]" "gpu_mode = off" "dri_groups = off" \
    "[gui]" "mode = off" \
    "[lifecycle]" "restart = on-failure:5" "watchdog_check = pgrep -f my_node" \
    "watchdog_interval = 30" \
    > "${REPO}/.setup.conf"
  run _setup_deploy --base-path "${REPO}" --stage runtime -y
  assert_success
  # The tree is now dirty, so the version stamp gains the -dirty suffix.
  local _bundle="${REPO}/deploy/fielddemo-runtime-v0.0.1-dirty"
  run cat "${_bundle}/compose.yaml"
  assert_success
  assert_output --partial "WATCHDOG_CHECK=pgrep -f my_node"
  assert_output --partial "WATCHDOG_INTERVAL=30"
  assert_output --partial 'restart: "on-failure:5"'
  refute_output --partial "restart: unless-stopped"
}

@test "deploy flow: [environment] is baked as ENV into a stage that is not named runtime (#840)" {
  # Capture the Dockerfile the generator hands to `docker build -f`, so the
  # ENV bake is observable (the generated Dockerfile lives in a temp dir).
  cat > "${SHIM}/docker" <<SH
#!/usr/bin/env bash
case "\$1" in
  build)
    shift
    while [[ \$# -gt 0 ]]; do
      [[ "\$1" == "-f" ]] && cp "\$2" "${TMP_ROOT}/build.Dockerfile"
      shift
    done
    exit 0 ;;
  save)
    shift
    while [[ \$# -gt 0 ]]; do
      [[ "\$1" == "-o" ]] && printf 'fake-image-archive\n' > "\$2"
      shift
    done
    exit 0 ;;
  create) echo fakecid ; exit 0 ;;
  cp) printf 'baked-default\n' > "\$3" ; exit 0 ;;
  rm) exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "${SHIM}/docker"
  cat > "${REPO}/Dockerfile" <<'DOCK'
FROM scratch AS sys
FROM sys AS devel
FROM sys AS field
CMD ["/app"]
DOCK
  printf '%s\n' \
    "[deploy]" "gpu_mode = off" "dri_groups = off" \
    "[gui]" "mode = off" \
    "[environment]" "env_1 = ROS_DOMAIN_ID=42" \
    > "${REPO}/.setup.conf"
  # The manifest declares runtime paths only; scope it to the new stage so
  # the bundle's config extraction still has something to do.
  printf '%s\n' "[field]" "/etc/app/camera.yaml" \
    > "${REPO}/config/camera/deploy.manifest"
  run _setup_deploy --base-path "${REPO}" --stage field -y
  assert_success
  run cat "${TMP_ROOT}/build.Dockerfile"
  assert_success
  assert_output --partial 'ENV ROS_DOMAIN_ID="42"'
  run grep -A 2 '^FROM sys AS field$' "${TMP_ROOT}/build.Dockerfile"
  assert_output --partial 'ENV ROS_DOMAIN_ID="42"'
}

@test "deploy flow: the README names the versioned image + the tunable config workflow (field-deploy)" {
  run cat "${BUNDLE}/README"
  assert_success
  assert_output --partial "fielddemo:runtime-v0.0.1"
  assert_output --partial "config/"
}
