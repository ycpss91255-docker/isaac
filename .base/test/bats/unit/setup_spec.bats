#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/setup_spec_helper"

# ════════════════════════════════════════════════════════════════════
# detect_gpu_count
# ════════════════════════════════════════════════════════════════════
@test "template setup.conf devices opt-in (#466): device_1 is a commented example, not a default" {
  # F2: /dev:/dev is no longer bound by default -- repos that need
  # device access uncomment it or add via `setup.sh add devices.device`.
  run grep -E '^device_1 = /dev:/dev$' /source/dist/.setup.conf
  assert_failure
  run grep -E '^# device_1 = /dev:/dev$' /source/dist/.setup.conf
  assert_success
}

@test "[devices] opt-in (#466): empty section + slim template emits no devices block" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[devices]
EOF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -E '^    devices:' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

@test "template setup.conf [deploy] enables ALL GPU capabilities by default" {
  # Dev-friendly: reserve every GPU capability so new repos get
  # compute + utility + graphics out of the box (no need to tick boxes
  # in TUI). Users narrow it down via ./setup_tui.sh deploy if they want
  # a minimal reservation.
  run grep -E '^gpu_capabilities = gpu compute utility graphics$' /source/dist/.setup.conf
  assert_success
}

@test "setup.sh apply emits top-level name: in compose.yaml (#472)" {
  # End-to-end: apply renders a top-level name: interpolating the same
  # PROJECT_NAME it just resolved into .env.generated, so non-wrapper tools
  # resolve the wrapper's project name from the same value.
  printf '[security]\nprivileged = false\n' > "${TEMP_DIR}/.setup.conf"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -F 'name: ${PROJECT_NAME}' "${TEMP_DIR}/compose.yaml"
  assert_success
  run grep -E '^PROJECT_NAME=.+$' "${TEMP_DIR}/.env.generated"
  assert_success
}

# ── [lifecycle] restart policy ─────────────────────────────────────────
#
# The key is DEPLOY-scoped: a devel container is the interactive shell
# itself, so a restart policy on it relaunches the shell on every `exit`.
# Only deployable stages (ADR-00000023 sec.4) carry `restart:`.

# A minimal Dockerfile carrying one deployable stage next to devel, so
# apply has somewhere legitimate to emit the policy.
_write_deployable_dockerfile() {
  cat > "${TEMP_DIR}/Dockerfile" <<'DOCK'
FROM scratch AS sys
FROM sys AS devel
FROM devel AS runtime
DOCK
}

@test "[lifecycle] restart = always lands on the deployable stage, never on devel (#478, #840)" {
  printf '[lifecycle]\nrestart = always\n' > "${TEMP_DIR}/.setup.conf"
  _write_deployable_dockerfile
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -cE '^    restart: always$' "${TEMP_DIR}/compose.yaml"
  assert_output "1"
  # The single occurrence belongs to the runtime service; devel carries
  # none for `extends: devel` to inherit.
  run bash -c "
    sed -n '/^  devel:/,/^  runtime:/p' '${TEMP_DIR}/compose.yaml' \
      | grep -cE '^    restart:'
  "
  assert_output "0"
}

@test "[lifecycle] restart = always emits nothing when no stage is deployable (#840)" {
  printf '[lifecycle]\nrestart = always\n' > "${TEMP_DIR}/.setup.conf"
  cat > "${TEMP_DIR}/Dockerfile" <<'DOCK'
FROM scratch AS sys
FROM sys AS devel
FROM devel AS devel-test
DOCK
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -E '^    restart:' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

@test "[lifecycle] restart = no emits no restart: field (#478)" {
  printf '[lifecycle]\nrestart = no\n' > "${TEMP_DIR}/.setup.conf"
  _write_deployable_dockerfile
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -E '^    restart:' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

@test "[lifecycle] restart = on-failure:3 emits quoted value (#478)" {
  printf '[lifecycle]\nrestart = on-failure:3\n' > "${TEMP_DIR}/.setup.conf"
  _write_deployable_dockerfile
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -F -- '    restart: "on-failure:3"' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "template setup.conf ships [lifecycle] restart = unless-stopped (#478, #840)" {
  # The default is ON and written LITERALLY so an operator can see it:
  # a deployable stage / field bundle is meant to run forever, including
  # across a host reboot. Scoping (never devel, never *-test) is what
  # keeps the default safe, not an absent key.
  run grep -E '^restart = unless-stopped$' /source/dist/.setup.conf
  assert_success
}

@test "setup.sh set lifecycle.restart rejects an invalid policy (#478)" {
  printf '[lifecycle]\nrestart = no\n' > "${TEMP_DIR}/.setup.conf"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main set lifecycle.restart bogus --base-path '${TEMP_DIR}' 2>&1
  "
  assert_failure
}

# ── [lifecycle] init (PID1 reaper) ─────────────────────────────────────
@test "[lifecycle] init defaults ON: emits init: true under devel (#792)" {
  # conf has no [lifecycle] init key -> code default true -> init: true.
  printf '[lifecycle]\nrestart = no\n' > "${TEMP_DIR}/.setup.conf"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -E '^    init: true$' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "[lifecycle] init = false omits init: field (#792)" {
  printf '[lifecycle]\ninit = false\n' > "${TEMP_DIR}/.setup.conf"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -E '^    init:' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

@test "template setup.conf ships [lifecycle] init = true (#792)" {
  run grep -E '^init = true$' /source/dist/.setup.conf
  assert_success
}

@test "setup.sh set lifecycle.init rejects a non-boolean (#792)" {
  printf '[lifecycle]\ninit = true\n' > "${TEMP_DIR}/.setup.conf"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main set lifecycle.init maybe --base-path '${TEMP_DIR}' 2>&1
  "
  assert_failure
}

@test "setup.sh set lifecycle.restart accepts the 5 canonical values (#478)" {
  printf '[lifecycle]\nrestart = no\n' > "${TEMP_DIR}/.setup.conf"
  local _v
  for _v in no always unless-stopped on-failure on-failure:3; do
    run bash -c "
      source /source/dist/script/docker/wrapper/setup.sh
      main set lifecycle.restart '${_v}' --base-path '${TEMP_DIR}' 2>&1
    "
    assert_success
  done
}

# ── [deploy] dri_groups (non-NVIDIA iGPU /dev/dri access) ───────────────
@test "[deploy] dri_groups = auto + GUI emits group_add with numeric GIDs (#496)" {
  printf '[deploy]\ndri_groups = auto\n[gui]\nmode = force\n' \
    > "${TEMP_DIR}/.setup.conf"
  run bash -c "
    export SETUP_DETECT_DRI_GROUPS='44 992'
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -E '^    group_add:$' "${TEMP_DIR}/compose.yaml"
  assert_success
  run grep -F -- '- "44"' "${TEMP_DIR}/compose.yaml"
  assert_success
  run grep -F -- '- "992"' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "[deploy] dri_groups = auto with no /dev/dri emits no group_add (#496)" {
  printf '[deploy]\ndri_groups = auto\n[gui]\nmode = force\n' \
    > "${TEMP_DIR}/.setup.conf"
  run bash -c "
    export SETUP_DETECT_DRI_GROUPS=''
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -E '^    group_add:$' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

@test "[deploy] dri_groups = off emits no group_add even with GUI (#496)" {
  printf '[deploy]\ndri_groups = off\n[gui]\nmode = force\n' \
    > "${TEMP_DIR}/.setup.conf"
  run bash -c "
    export SETUP_DETECT_DRI_GROUPS='44 992'
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -E '^    group_add:$' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

@test "[deploy] dri_groups = auto without GUI emits no group_add (GUI-gated) (#496)" {
  printf '[deploy]\ndri_groups = auto\n[gui]\nmode = off\n' \
    > "${TEMP_DIR}/.setup.conf"
  run bash -c "
    export SETUP_DETECT_DRI_GROUPS='44 992'
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -E '^    group_add:$' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

@test "template setup.conf ships [deploy] dri_groups = auto (#496)" {
  run grep -E '^dri_groups = auto$' /source/dist/.setup.conf
  assert_success
}

# ── [deploy] runtime -> gpu_runtime (W3 permanent alias) ────────────────
@test "[deploy] gpu_runtime primary key emits runtime: nvidia (#481)" {
  printf '[deploy]\ngpu_runtime = nvidia\n' > "${TEMP_DIR}/.setup.conf"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -E '^    runtime: nvidia$' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "[deploy] legacy runtime key still works + warns (#481 W3 alias)" {
  printf '[deploy]\nruntime = nvidia\n' > "${TEMP_DIR}/.setup.conf"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -E '^    runtime: nvidia$' "${TEMP_DIR}/compose.yaml"
  assert_success
  # the legacy alias is consumed but a deprecation is surfaced
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_output --partial "gpu_runtime"
}

@test "[deploy] gpu_runtime wins when both keys present (#481)" {
  printf '[deploy]\ngpu_runtime = nvidia\nruntime = off\n' \
    > "${TEMP_DIR}/.setup.conf"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -E '^    runtime: nvidia$' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "template setup.conf ships [deploy] gpu_runtime = auto (#481)" {
  run grep -E '^gpu_runtime = auto$' /source/dist/.setup.conf
  assert_success
  run grep -E '^runtime = ' /source/dist/.setup.conf
  assert_failure
}

@test "per-stage override accepts deploy.gpu_runtime (#481)" {
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    _validate_stage_override_key deploy.gpu_runtime
  "
  assert_success
}

@test "per-stage override still accepts legacy deploy.runtime (#481 alias)" {
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    _validate_stage_override_key deploy.runtime
  "
  assert_success
}

@test "[security] cap_add opt-in (#466): empty section + slim template emits no cap_add" {
  # F2: the template no longer ships cap_add_* defaults, so a repo
  # with an empty [security] section (the omniverse case) falls back to a
  # SLIM template and gets NO cap_add block -- privileges are opt-in, not
  # silently inherited. Repos that need caps declare them explicitly
  # (covered by the regression test below).
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[security]
privileged = false
EOF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -F -- '- SYS_ADMIN' "${TEMP_DIR}/compose.yaml"
  assert_failure
  run grep -E '^    cap_add:' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

@test "[security] security_opt opt-in (#466): empty section + slim template emits no security_opt" {
  # F2: template no longer ships security_opt_1 = seccomp:unconfined,
  # so an empty [security] section yields no security_opt block.
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[security]
privileged = false
EOF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -F -- '- seccomp:unconfined' "${TEMP_DIR}/compose.yaml"
  assert_failure
  run grep -E '^    security_opt:' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

@test "[security] opt-in via wrapper: setup.sh add security.cap_add then apply emits cap_add (#466)" {
  # The slim template makes caps opt-in; the opt-in path is the wrapper,
  # not hand-editing commented lines. `setup.sh add` writes the entry into
  # the per-repo setup.conf, and the next apply emits it.
  printf '[security]\n' > "${TEMP_DIR}/.setup.conf"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main add security.cap_add SYS_ADMIN --base-path '${TEMP_DIR}' 2>&1
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -F -- '- SYS_ADMIN' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "[security] privileged defaults to false when key absent (#466 opt-in)" {
  # A repo that declares [security] (e.g. for cap_add) but omits the
  # privileged key must NOT silently get privileged=true. flips the
  # default to false so privilege is opt-in across the board.
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[security]
cap_add_1 = SYS_ADMIN
EOF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -E '^PRIVILEGED=false$' "${TEMP_DIR}/.env.generated"
  assert_success
}

@test "[security] opt-in still works via explicit declaration (#466 regression)" {
  # Repos that need privileges declare them (e.g. via `setup.sh add
  # security.cap_add SYS_ADMIN` or the TUI). The slim template only
  # changes the DEFAULT -- an explicit cap_add must still emit.
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[security]
privileged = false
cap_add_1 = SYS_ADMIN
security_opt_1 = seccomp:unconfined
EOF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -F -- '- SYS_ADMIN' "${TEMP_DIR}/compose.yaml"
  assert_success
  run grep -F -- '- seccomp:unconfined' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "[additional_contexts] omitted by default (back-compat: no block in compose.yaml)" {
  # Default template setup.conf has [additional_contexts] section but no
  # entries. Generated compose.yaml must NOT contain `additional_contexts:`
  # so existing repos see zero diff.
  cp /source/dist/.setup.conf "${TEMP_DIR}/.setup.conf"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -F -- 'additional_contexts:' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

@test "[additional_contexts] context_1 = NAME=PATH emits block under devel/test build" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS devel-base
FROM devel-base AS devel
FROM devel AS devel-test
EOF
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[additional_contexts]
context_1 = repo=..
context_2 = vendor=../third_party
EOF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  # Block appears at least once (devel + test, runtime is conditional on
  # Dockerfile having `AS runtime` which TEMP_DIR doesn't ship).
  run grep -c -F -- '      additional_contexts:' "${TEMP_DIR}/compose.yaml"
  assert_success
  [ "${output}" -ge 2 ]
  run grep -F -- '        repo: ..' "${TEMP_DIR}/compose.yaml"
  assert_success
  run grep -F -- '        vendor: ../third_party' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "[additional_contexts] runtime service inherits the block when Dockerfile declares AS runtime" {
  # Stub a Dockerfile with `AS runtime` so generate_compose_yaml emits
  # the runtime service. Then assert additional_contexts: appears 3 times
  # (once under each of devel / runtime / test). The `test` service comes
  # from the devel-test stage, so the fixture must declare it.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS runtime
FROM sys AS devel-test
EOF
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[additional_contexts]
context_1 = repo=..
EOF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -c -F -- '      additional_contexts:' "${TEMP_DIR}/compose.yaml"
  assert_success
  assert_output "3"
}

@test "[additional_contexts] entries sort by numeric suffix (context_2 / context_10)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[additional_contexts]
context_10 = ten=../ten
context_2 = two=../two
context_1 = one=../one
EOF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  # Extract first occurrence of the additional_contexts block (devel
  # service) and check the order of name lines within it.
  local _block
  _block="$(awk '
    /^      additional_contexts:$/ { in_block=1; next }
    in_block && /^[^ ]/             { exit }
    in_block && /^      [^ ]/       { exit }
    in_block                         { print }
  ' "${TEMP_DIR}/compose.yaml")"
  local _first _second _third
  _first="$(printf '%s\n'  "${_block}" | sed -n '1p')"
  _second="$(printf '%s\n' "${_block}" | sed -n '2p')"
  _third="$(printf '%s\n'  "${_block}" | sed -n '3p')"
  assert_equal "${_first}"  "        one: ../one"
  assert_equal "${_second}" "        two: ../two"
  assert_equal "${_third}"  "        ten: ../ten"
}

@test "[additional_contexts] empty value (cleared slot) is skipped" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[additional_contexts]
context_1 = repo=..
context_2 =
context_3 = vendor=../third_party
EOF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -F -- 'repo: ..' "${TEMP_DIR}/compose.yaml"
  assert_success
  run grep -F -- 'vendor: ../third_party' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "set logging.driver round-trips via show (#328)" {
  cp /source/dist/.setup.conf "${TEMP_DIR}/.setup.conf"
  run main set logging.driver journald --base-path "${TEMP_DIR}"
  assert_success
  run main show logging.driver --base-path "${TEMP_DIR}"
  assert_success
  assert_output "journald"
}

@test "set logging.compress accepts true/false; rejects others (#328)" {
  cp /source/dist/.setup.conf "${TEMP_DIR}/.setup.conf"
  run main set logging.compress true --base-path "${TEMP_DIR}"
  assert_success
  run main set logging.compress maybe --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "set logging.max_file rejects non-positive integers (#328)" {
  cp /source/dist/.setup.conf "${TEMP_DIR}/.setup.conf"
  run main set logging.max_file 5 --base-path "${TEMP_DIR}"
  assert_success
  run main set logging.max_file 0 --base-path "${TEMP_DIR}"
  assert_failure
  run main set logging.max_file -1 --base-path "${TEMP_DIR}"
  assert_failure
  run main set logging.max_file abc --base-path "${TEMP_DIR}"
  assert_failure
}

@test "set logging.max_size accepts num+unit; rejects malformed (#328)" {
  cp /source/dist/.setup.conf "${TEMP_DIR}/.setup.conf"
  run main set logging.max_size 50m --base-path "${TEMP_DIR}"
  assert_success
  run main set logging.max_size 1g --base-path "${TEMP_DIR}"
  assert_success
  run main set logging.max_size 10X --base-path "${TEMP_DIR}"
  assert_failure
  run main set logging.max_size abc --base-path "${TEMP_DIR}"
  assert_failure
}

@test "set logging.driver rejects whitespace/empty-shape names (#328)" {
  cp /source/dist/.setup.conf "${TEMP_DIR}/.setup.conf"
  run main set logging.driver "bad name" --base-path "${TEMP_DIR}"
  assert_failure
  run main set logging.driver "1starts-with-digit" --base-path "${TEMP_DIR}"
  assert_failure
}

@test "set logging.<svc>.<key> writes to per-service section (#328)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[logging]
driver = json-file
EOF
  run main set logging.runtime.driver journald --base-path "${TEMP_DIR}"
  assert_success
  # Per-service section now exists with the override.
  run grep -F "[logging.runtime]" "${TEMP_DIR}/.setup.conf"
  assert_success
  run main show logging.runtime.driver --base-path "${TEMP_DIR}"
  assert_success
  assert_output "journald"
}

@test "remove logging.<svc>.<key> deletes the per-service key (#328)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[logging]
driver = json-file

[logging.runtime]
driver = journald
max_file = 7
EOF
  run main remove logging.runtime.driver --base-path "${TEMP_DIR}"
  assert_success
  run grep -F "driver = journald" "${TEMP_DIR}/.setup.conf"
  assert_failure
  # Sibling key untouched.
  run grep -F "max_file = 7" "${TEMP_DIR}/.setup.conf"
  assert_success
}

@test "show logging prints the whole resolved [logging] section (#328)" {
  cp /source/dist/.setup.conf "${TEMP_DIR}/.setup.conf"
  run main show logging --base-path "${TEMP_DIR}"
  assert_success
  assert_output --partial "driver"
  assert_output --partial "max_size"
  assert_output --partial "max_file"
  assert_output --partial "compress"
}

@test "set logging.local_path accepts relative path (#328)" {
  cp /source/dist/.setup.conf "${TEMP_DIR}/.setup.conf"
  run main set logging.local_path ./logs/ --base-path "${TEMP_DIR}"
  assert_success
  run main show logging.local_path --base-path "${TEMP_DIR}"
  assert_success
  assert_output "./logs/"
}

@test "set logging.local_path accepts absolute path (#328)" {
  cp /source/dist/.setup.conf "${TEMP_DIR}/.setup.conf"
  run main set logging.local_path /srv/app-logs --base-path "${TEMP_DIR}"
  assert_success
  run main show logging.local_path --base-path "${TEMP_DIR}"
  assert_success
  assert_output "/srv/app-logs"
}

@test "set logging.local_path rejects whitespace-only value (#328)" {
  cp /source/dist/.setup.conf "${TEMP_DIR}/.setup.conf"
  run main set logging.local_path "   " --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "set logging.<svc>.local_path writes to per-service section (#328)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[logging]
driver = json-file
EOF
  run main set logging.devel.local_path ./devel-logs/ --base-path "${TEMP_DIR}"
  assert_success
  run grep -F "[logging.devel]" "${TEMP_DIR}/.setup.conf"
  assert_success
  run main show logging.devel.local_path --base-path "${TEMP_DIR}"
  assert_success
  assert_output "./devel-logs/"
}

@test "[security] cap_add_* explicit override: user-provided list is honored (no template fallback)" {
  # User set cap_add_1=ALL explicitly: compose should use THAT, not the
  # template's SYS_ADMIN/NET_ADMIN/MKNOD.
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[security]
privileged = false
cap_add_1 = ALL
EOF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -F -- '- ALL' "${TEMP_DIR}/compose.yaml"
  assert_success
  # Template's SYS_ADMIN/NET_ADMIN/MKNOD should NOT appear.
  run grep -F -- '- SYS_ADMIN' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# main --lang + error paths (unchanged behaviour)
# ════════════════════════════════════════════════════════════════════
@test "main rejects bare flag without subcommand (#49 Phase B-4 BREAKING)" {
  # Pre-B-4 the legacy fall-through aliased flag-only invocation to
  # `apply`. B-4 removes that — the user must now type the subcommand
  # explicitly. Hits the unknown-subcommand path of the dispatcher.
  run main --bogus
  assert_failure
  assert_output --partial "Unknown subcommand"
}

@test "apply subcommand returns error when --base-path value is missing" {
  run -127 bash -c "source /source/dist/script/docker/wrapper/setup.sh; main apply --base-path"
}

@test "apply subcommand returns error when --lang value is missing" {
  run -127 bash -c "source /source/dist/script/docker/wrapper/setup.sh; main apply --lang"
}

@test "apply --lang zh-TW sets Chinese messages for full run" {
  cp /source/dist/.setup.conf "${TEMP_DIR}/.setup.conf"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --lang zh-TW 2>&1
  "
  assert_success
  assert_output --partial "更新完成"
}

# ── Per-repo setup.conf missing / empty INFO ────────────────
@test "apply prints WARN when per-repo setup.conf is missing (#186)" {
  # No TEMP_DIR/.setup.conf created — apply should fall back to template
  # default and announce it once on stderr at WARN level.
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  assert_output --partial "[setup] WARN :"
  assert_output --partial "no per-repo setup.conf"
  # regression guard: the heads-up must NOT be demoted to INFO
  # (where it would scroll past). The env_done line legitimately uses
  # INFO level, so scope the refute to the warning's body.
  refute_output --partial "[setup] INFO: no per-repo setup.conf"
}

@test "apply prints WARN when per-repo setup.conf has no section headers (#186)" {
  # Comments-only file counts as effectively empty: nothing to override.
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
# only comments, no [section] headers
# template defaults apply for every section
EOF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  assert_output --partial "[setup] WARN :"
  assert_output --partial "per-repo setup.conf has no section"
}

@test "apply stays silent when per-repo setup.conf has at least one section" {
  # Partial override is normal usage — don't INFO-spam users who edited
  # only one section.
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gpu]
mode = auto
EOF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  refute_output --partial "no per-repo setup.conf"
  refute_output --partial "per-repo setup.conf has no section"
}

@test "apply --lang zh-TW prints WARN in Traditional Chinese when setup.conf missing (#186)" {
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --lang zh-TW 2>&1
  "
  assert_success
  assert_output --partial "[setup] WARN :"
  assert_output --partial "未找到"
}

@test "apply resolves default _base_path via BASH_SOURCE when --base-path omitted" {
  # apply without --base-path walks 3 levels up from its own location
  # (script/docker/../../.. = repo root).
  mkdir -p "${TEMP_DIR}/sandbox_repo/.base/dist/script/docker/lib" \
           "${TEMP_DIR}/sandbox_repo/.base/dist/script/docker/wrapper" \
           "${TEMP_DIR}/sandbox_repo/.base/dist/config/docker"
  cp /source/dist/script/docker/wrapper/setup.sh \
    "${TEMP_DIR}/sandbox_repo/.base/dist/script/docker/wrapper/setup.sh"
  cp /source/dist/script/docker/lib/i18n.sh \
    "${TEMP_DIR}/sandbox_repo/.base/dist/script/docker/lib/i18n.sh"
  cp /source/dist/script/docker/lib/_tui_conf.sh \
    "${TEMP_DIR}/sandbox_repo/.base/dist/script/docker/lib/_tui_conf.sh"
  # setup.sh sources _lib.sh for the _log_* helpers; _lib.sh
  # is an umbrella that sources lib/*.sh sub-libs
  cp /source/dist/script/docker/lib/_lib.sh \
    "${TEMP_DIR}/sandbox_repo/.base/dist/script/docker/lib/_lib.sh"
  cp /source/dist/script/docker/lib/* \
    "${TEMP_DIR}/sandbox_repo/.base/dist/script/docker/lib/"
  cp /source/dist/.setup.conf "${TEMP_DIR}/sandbox_repo/.base/dist/.setup.conf"

  run bash "${TEMP_DIR}/sandbox_repo/.base/dist/script/docker/wrapper/setup.sh" apply
  assert_success
  assert [ -f "${TEMP_DIR}/sandbox_repo/.env.generated" ]
}

# ════════════════════════════════════════════════════════════════════
# .env.generated cache + .env workload overlay (A2 file roles,)
# ════════════════════════════════════════════════════════════════════
@test "apply writes the derived cache to .env.generated (not .env)" {
  cp /source/dist/.setup.conf "${TEMP_DIR}/.setup.conf"
  run main apply --base-path "${TEMP_DIR}"
  assert_success
  assert [ -f "${TEMP_DIR}/.env.generated" ]
  run grep -E '^SETUP_CONF_HASH=' "${TEMP_DIR}/.env.generated"
  assert_success
}

@test "apply scaffolds a .env workload overlay when absent" {
  cp /source/dist/.setup.conf "${TEMP_DIR}/.setup.conf"
  refute [ -f "${TEMP_DIR}/.env" ]
  run main apply --base-path "${TEMP_DIR}"
  assert_success
  assert [ -f "${TEMP_DIR}/.env" ]
  # Scaffold carries guidance, not derived values (no SETUP_* metadata).
  run grep -E '^SETUP_CONF_HASH=' "${TEMP_DIR}/.env"
  assert_failure
}

@test "apply does NOT overwrite an existing hand-authored .env overlay" {
  cp /source/dist/.setup.conf "${TEMP_DIR}/.setup.conf"
  printf 'ROS_DOMAIN_ID=42\n' > "${TEMP_DIR}/.env"
  run main apply --base-path "${TEMP_DIR}"
  assert_success
  run cat "${TEMP_DIR}/.env"
  assert_output "ROS_DOMAIN_ID=42"
}

@test "apply migrates a legacy .env cache to .env.generated + backs it up" {
  cp /source/dist/.setup.conf "${TEMP_DIR}/.setup.conf"
  # layout: .env IS the cache (carries the auto-gen marker) and
  # .env.generated does not exist yet.
  cat > "${TEMP_DIR}/.env" <<'EOF'
IMAGE_NAME=legacycache
SETUP_CONF_HASH=deadbeef
EOF
  run main apply --base-path "${TEMP_DIR}"
  assert_success
  # The stale cache is backed up and a fresh derived cache is written.
  assert [ -f "${TEMP_DIR}/.env.bak" ]
  run grep -E '^IMAGE_NAME=legacycache$' "${TEMP_DIR}/.env.bak"
  assert_success
  assert [ -f "${TEMP_DIR}/.env.generated" ]
  # .env is no longer the cache: it is the scaffolded overlay (no marker).
  run grep -E '^SETUP_CONF_HASH=' "${TEMP_DIR}/.env"
  assert_failure
}

@test "apply emits env_file: - .env on the devel service (#502 overlay)" {
  cp /source/dist/.setup.conf "${TEMP_DIR}/.setup.conf"
  run main apply --base-path "${TEMP_DIR}"
  assert_success
  run grep -A1 -E '^    env_file:' "${TEMP_DIR}/compose.yaml"
  assert_success
  assert_output --partial "- .env"
}

# ════════════════════════════════════════════════════════════════════
# config/app/ structured app-config dev bind-mount (S4,)
# ════════════════════════════════════════════════════════════════════
@test "apply dev-binds config/app/ into the devel service when present (#504)" {
  cp /source/dist/.setup.conf "${TEMP_DIR}/.setup.conf"
  mkdir -p "${TEMP_DIR}/config/app"
  run main apply --base-path "${TEMP_DIR}"
  assert_success
  run grep -F './config/app:/opt/app/config' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "apply omits the config/app bind when the directory is absent (#504)" {
  cp /source/dist/.setup.conf "${TEMP_DIR}/.setup.conf"
  run main apply --base-path "${TEMP_DIR}"
  assert_success
  run grep -F '/opt/app/config' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

@test "main reset --yes works on first-time bootstrap (no prior .local or setup.conf) (#174)" {
  rm -f "${TEMP_DIR}/.setup.conf" "${TEMP_DIR}/.setup.conf"
  run main reset --yes --base-path "${TEMP_DIR}"
  assert_success
  # First-time bootstrap is a no-op: no override existed, no snapshot
  # existed, so nothing to clear and no .bak files written.
  refute [ -f "${TEMP_DIR}/.setup.conf.bak" ]
  refute [ -f "${TEMP_DIR}/.setup.conf.bak" ]
}

# ════════════════════════════════════════════════════════════════════
# i18n
# ════════════════════════════════════════════════════════════════════
@test "_setup_msg returns English messages by default" {
  _LANG="en"
  [[ "$(_setup_msg env "done")" =~ updated ]]
}

@test "_setup_msg returns Traditional Chinese messages when _LANG=zh-TW" {
  _LANG="zh-TW"
  [[ "$(_setup_msg env "done")" =~ 更新完成 ]]
}

@test "_setup_msg returns Simplified Chinese messages when _LANG=zh-CN" {
  _LANG="zh-CN"
  [[ "$(_setup_msg env "done")" =~ 更新完成 ]]
}

@test "_setup_msg returns Japanese messages when _LANG=ja" {
  _LANG="ja"
  [[ "$(_setup_msg env "done")" =~ 更新完了 ]]
}

@test "_setup_msg env_comment and unknown_arg are defined in zh" {
  _LANG="zh-TW"
  [[ "$(_setup_msg env comment)" =~ 自動偵測 ]]
  [[ "$(_setup_msg errors unknown_arg)" =~ 未知參數 ]]
}

@test "_setup_msg env_comment and unknown_arg are defined in zh-CN" {
  _LANG="zh-CN"
  [[ "$(_setup_msg env comment)" =~ 自动检测 ]]
  [[ "$(_setup_msg errors unknown_arg)" =~ 未知参数 ]]
}

@test "_setup_msg env_comment and unknown_arg are defined in ja" {
  _LANG="ja"
  [[ "$(_setup_msg env comment)" =~ 自動検出 ]]
  [[ "$(_setup_msg errors unknown_arg)" =~ 不明な引数 ]]
}

@test "_msg falls back to English when _LANG is unknown" {
  _LANG="xx"
  [[ "$(_setup_msg env "done")" =~ updated ]]
  [[ "$(_setup_msg env comment)" =~ Auto-detected ]]
  [[ "$(_setup_msg errors unknown_arg)" =~ "Unknown argument" ]]
}

# ════════════════════════════════════════════════════════════════════
# [build] section (arg_N KEY=VALUE schema)
# ════════════════════════════════════════════════════════════════════
@test "[build] template defaults ship TW mirrors via arg_N" {
  cp /source/dist/.setup.conf "${TEMP_DIR}/.setup.conf"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
    grep '^APT_MIRROR_UBUNTU=' '${TEMP_DIR}/.env.generated'
    grep '^APT_MIRROR_DEBIAN=' '${TEMP_DIR}/.env.generated'
  "
  assert_success
  assert_output --partial "APT_MIRROR_UBUNTU=tw.archive.ubuntu.com"
  assert_output --partial "APT_MIRROR_DEBIAN=mirror.twds.com.tw"
}

@test "[build] arg_N override replaces TW default when set" {
  cp /source/dist/.setup.conf "${TEMP_DIR}/.setup.conf"
  _upsert_conf_value "${TEMP_DIR}/.setup.conf" build arg_1 \
    "APT_MIRROR_UBUNTU=archive.ubuntu.com"
  _upsert_conf_value "${TEMP_DIR}/.setup.conf" build arg_2 \
    "APT_MIRROR_DEBIAN=deb.debian.org"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
    grep '^APT_MIRROR_UBUNTU=' '${TEMP_DIR}/.env.generated'
    grep '^APT_MIRROR_DEBIAN=' '${TEMP_DIR}/.env.generated'
  "
  assert_success
  assert_output --partial "APT_MIRROR_UBUNTU=archive.ubuntu.com"
  assert_output --partial "APT_MIRROR_DEBIAN=deb.debian.org"
}

@test "[build] back-compat: old apt_mirror_* named keys still read" {
  # Legacy repo setup.conf with the pre-arg_N schema must keep working
  # so users can upgrade template without rewriting setup.conf first.
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[build]
apt_mirror_ubuntu = mirror.example.com
tz = Asia/Tokyo
EOF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
    grep '^APT_MIRROR_UBUNTU=' '${TEMP_DIR}/.env.generated'
    grep '^TZ=' '${TEMP_DIR}/.env.generated'
  "
  assert_success
  assert_output --partial "APT_MIRROR_UBUNTU=mirror.example.com"
  assert_output --partial "TZ=Asia/Tokyo"
}

@test "[build] user-added arg_N propagates to .env" {
  # Dockerfile with `ARG PYTHON_VERSION` can pick up a user-added
  # build arg. Extra args land in .env so compose build.args can
  # reference them.
  cp /source/dist/.setup.conf "${TEMP_DIR}/.setup.conf"
  _upsert_conf_value "${TEMP_DIR}/.setup.conf" build arg_9 \
    "PYTHON_VERSION=3.12"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
    grep '^PYTHON_VERSION=' '${TEMP_DIR}/.env.generated'
  "
  assert_success
  assert_output --partial "PYTHON_VERSION=3.12"
}

@test "[build] target_arch = arm64 writes TARGET_ARCH to .env" {
  cp /source/dist/.setup.conf "${TEMP_DIR}/.setup.conf"
  _upsert_conf_value "${TEMP_DIR}/.setup.conf" build target_arch arm64
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep '^TARGET_ARCH=' '${TEMP_DIR}/.env.generated'
  "
  assert_success
  assert_output --partial "TARGET_ARCH=arm64"
}

@test "[build] target_arch empty omits TARGET_ARCH from .env" {
  cp /source/dist/.setup.conf "${TEMP_DIR}/.setup.conf"
  # Explicit empty value (the template's default)
  _upsert_conf_value "${TEMP_DIR}/.setup.conf" build target_arch ""
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -c '^TARGET_ARCH=' '${TEMP_DIR}/.env.generated'
  "
  # grep -c prints "0" and exits 1 when pattern missing; we want exactly that.
  assert_failure
  assert_output "0"
}

@test "[build] network = host writes BUILD_NETWORK to .env" {
  cp /source/dist/.setup.conf "${TEMP_DIR}/.setup.conf"
  _upsert_conf_value "${TEMP_DIR}/.setup.conf" build network host
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep '^BUILD_NETWORK=' '${TEMP_DIR}/.env.generated'
  "
  assert_success
  assert_output --partial "BUILD_NETWORK=host"
}

@test "[build] network empty omits BUILD_NETWORK from .env" {
  cp /source/dist/.setup.conf "${TEMP_DIR}/.setup.conf"
  _upsert_conf_value "${TEMP_DIR}/.setup.conf" build network ""
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -c '^BUILD_NETWORK=' '${TEMP_DIR}/.env.generated'
  "
  assert_failure
  assert_output "0"
}

# ════════════════════════════════════════════════════════════════════
# Workspace writeback (first-time / user edit / opt-out)
# ════════════════════════════════════════════════════════════════════
@test "workspace first-time: writes \${WS_PATH} variable form (portable)" {
  # Regression (v0.9.4): writeback used to bake the absolute host path
  # into setup.conf. Committing that file broke other machines whose
  # filesystem layout differed. Now we write the \${WS_PATH} variable
  # form so docker-compose resolves it per-machine from .env.
  local _repo="${TEMP_DIR}/repo"
  mkdir -p "${_repo}"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${_repo}' 2>&1
  "
  assert_success
  assert [ -f "${_repo}/.setup.conf" ]
  run grep '^mount_1' "${_repo}/.setup.conf"
  assert_output --partial '${WS_PATH}:/home/${USER_NAME}/work'
}

@test "workspace second-run: \${WS_PATH} form re-detects per machine" {
  # Round-trip: first-time writes \${WS_PATH} form → second run reads
  # setup.conf, sees the variable reference, and re-runs detect_ws_path
  # so WS_PATH in .env reflects THIS machine (not the one that first
  # committed the file).
  local _repo="${TEMP_DIR}/repo"
  mkdir -p "${_repo}"
  bash -c "source /source/dist/script/docker/wrapper/setup.sh; main apply --base-path '${_repo}'" \
    >/dev/null 2>&1
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${_repo}' 2>&1
    grep '^WS_PATH=' '${_repo}/.env.generated'
    grep '^mount_1' '${_repo}/.setup.conf'
  "
  assert_success
  # WS_PATH is a non-empty absolute path — exact value depends on the
  # sandbox, but it must not be the literal variable string.
  refute_output --partial 'WS_PATH=${WS_PATH}'
  assert_output --regexp 'WS_PATH=/[^[:space:]]+'
  # mount_1 stays as the portable variable form.
  assert_output --partial 'mount_1 = ${WS_PATH}:/home/${USER_NAME}/work'
}

@test "workspace second-run: respects user-pinned absolute path via setup.conf (#174)" {
  local _repo="${TEMP_DIR}/repo"
  local _pin="${TEMP_DIR}/custom_ws"
  mkdir -p "${_repo}" "${_pin}"
  bash -c "source /source/dist/script/docker/wrapper/setup.sh; main apply --base-path '${_repo}'" \
    >/dev/null 2>&1
  # user pins go into the override file (.local), not the
  # materialized snapshot.
  cat > "${_repo}/.setup.conf" <<EOF
[volumes]
mount_1 = ${_pin}:/home/\${USER_NAME}/work
EOF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${_repo}' 2>&1
    grep '^WS_PATH=' '${_repo}/.env.generated'
    grep '^mount_1' '${_repo}/.setup.conf'
  "
  assert_success
  # Effective WS_PATH on this machine is the user-pinned absolute path.
  assert_output --partial "WS_PATH=${_pin}"
  # The override file (.local) keeps the pinned form verbatim — apply
  # doesn't rewrite user intent.
  assert_output --partial "mount_1 = ${_pin}:"
}

@test "workspace second-run: stale setup.conf path is harmlessly overwritten (#174)" {
  # setup.conf was tracked → cross-machine clones inherited
  # alice's absolute path on bob's checkout, forcing setup.sh to
  # detect-and-rewrite. setup.conf is gitignored + a derived
  # snapshot, so the only way a "stale" path lands is a manual edit
  # between applies. Apply now silently regenerates setup.conf from
  # template + .local (which contain the portable form) — no warning
  # needed, the stale value is gone after one apply.
  local _repo="${TEMP_DIR}/repo"
  mkdir -p "${_repo}"
  bash -c "source /source/dist/script/docker/wrapper/setup.sh; main apply --base-path '${_repo}'" \
    >/dev/null 2>&1
  sed -i 's|^mount_1.*|mount_1 = /nonexistent/stale/ws:/home/${USER_NAME}/work|' \
    "${_repo}/.setup.conf"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${_repo}' 2>&1
    grep '^WS_PATH=' '${_repo}/.env.generated'
  "
  assert_success
  # Stale path does not leak into .env (apply regenerates from .local +
  # template + fresh ws_path detection, ignoring the manually-mutated
  # setup.conf entry for [volumes]).
  refute_output --partial "WS_PATH=/nonexistent/stale/ws"
}

@test "fresh bootstrap: empty dir + main apply emits workspace mount in compose.yaml (#201 regression)" {
  # bug: bootstrap wrote mount_1 to <repo>/.setup.conf, then
  # immediately reloaded via _load_setup_conf which only consulted
  # .setup.conf.local (empty) + template (empty mount_1). The just-written
  # value was lost and compose.yaml omitted the workspace mount.
  # (2-file model): bootstrap writes to <repo>/.setup.conf and
  # _load_setup_conf reads from the same file, so the reload picks up
  # the freshly-written mount_1.
  local _repo="${TEMP_DIR}/fresh"
  mkdir -p "${_repo}"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${_repo}' 2>&1
  "
  assert_success
  # compose.yaml contains the workspace mount line (portable form)
  run grep -F -- '${WS_PATH}:/home/${USER_NAME}/work' "${_repo}/compose.yaml"
  assert_success
}

@test "workspace opt-out: cleared mount_1 means no workspace mount in compose" {
  local _repo="${TEMP_DIR}/repo"
  mkdir -p "${_repo}"
  bash -c "source /source/dist/script/docker/wrapper/setup.sh; main apply --base-path '${_repo}'" \
    >/dev/null 2>&1
  # User clears mount_1 (opt-out)
  sed -i 's|^mount_1.*|mount_1 =|' "${_repo}/.setup.conf"
  bash -c "source /source/dist/script/docker/wrapper/setup.sh; main apply --base-path '${_repo}'" \
    >/dev/null 2>&1
  # mount_1 stays empty (not re-populated)
  run grep '^mount_1' "${_repo}/.setup.conf"
  assert_equal "${output}" "mount_1 ="
  # compose.yaml has no workspace mount
  run grep ':/home/${USER_NAME}/work' "${_repo}/compose.yaml"
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# — --quiet flag + success confirmation output
# ════════════════════════════════════════════════════════════════════
@test "setup.sh set: prints 3-line confirmation by default" {
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main set --base-path '${TEMP_DIR}' build.arg_4 ROS2_DISTRO=jazzy
  "
  assert_success
  assert_output --partial "[setup] set [build] arg_4 = ROS2_DISTRO=jazzy"
  assert_output --partial "[setup] file:"
  assert_output --partial "[setup] next: run 'just build' (auto-applies) or './setup.sh apply'"
}

@test "setup.sh set --quiet: produces empty stdout" {
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main set --quiet --base-path '${TEMP_DIR}' build.arg_4 ROS2_DISTRO=jazzy
  "
  assert_success
  assert_output ""
}

@test "setup.sh set -q: short form also suppresses output" {
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main set -q --base-path '${TEMP_DIR}' build.arg_4 ROS2_DISTRO=jazzy
  "
  assert_success
  assert_output ""
}

@test "setup.sh set --quiet: still writes the value (mutation not skipped)" {
  bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main set --quiet --base-path '${TEMP_DIR}' build.arg_4 ROS2_DISTRO=jazzy
  "
  run cat "${TEMP_DIR}/.setup.conf"
  assert_success
  assert_output --partial "arg_4 = ROS2_DISTRO=jazzy"
}

@test "setup.sh add: prints 3-line confirmation by default" {
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main add --base-path '${TEMP_DIR}' build.arg HARDWARE=arm64
  "
  assert_success
  assert_output --partial "[setup] add [build] arg_"
  assert_output --partial "[setup] file:"
  assert_output --partial "[setup] next: run 'just build' (auto-applies) or './setup.sh apply'"
}

@test "setup.sh add --quiet: produces empty stdout" {
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main add --quiet --base-path '${TEMP_DIR}' build.arg HARDWARE=arm64
  "
  assert_success
  assert_output ""
}

@test "setup.sh remove: prints 3-line confirmation by default" {
  cat > "${TEMP_DIR}/.setup.conf" <<EOC
[build]
arg_1 = HARDWARE=arm64
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main remove --base-path '${TEMP_DIR}' build.arg_1
  "
  assert_success
  assert_output --partial "[setup] remove [build] arg_1"
  assert_output --partial "[setup] file:"
  assert_output --partial "[setup] next: run 'just build' (auto-applies) or './setup.sh apply'"
}

@test "setup.sh remove --quiet: produces empty stdout" {
  cat > "${TEMP_DIR}/.setup.conf" <<EOC
[build]
arg_1 = HARDWARE=arm64
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main remove --quiet --base-path '${TEMP_DIR}' build.arg_1
  "
  assert_success
  assert_output ""
}

@test "setup.sh reset --yes: prints next: hint and file: by default" {
  : > "${TEMP_DIR}/.setup.conf"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main reset --yes --base-path '${TEMP_DIR}'
  "
  assert_success
  assert_output --partial "[setup]"
  assert_output --partial "[setup] file:"
  assert_output --partial "[setup] next: run 'just build' (auto-applies) or './setup.sh apply'"
}

@test "setup.sh reset --yes --quiet: produces empty stdout" {
  : > "${TEMP_DIR}/.setup.conf"
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main reset --yes --quiet --base-path '${TEMP_DIR}'
  "
  assert_success
  assert_output ""
}

@test "setup.sh apply --quiet: suppresses the env_done + USER=... summary" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOC'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --quiet --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  refute_output --partial "[setup] USER="
}

# ════════════════════════════════════════════════════════════════════
# setup.sh apply CLI flags (--gui / --no-x11-cookie / --print-resolved)
# ════════════════════════════════════════════════════════════════════
@test "apply --gui off overrides [gui] mode via print-resolved (#338)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = force
EOF
  # Baseline: mode=force resolves GUI_ENABLED=true regardless of host
  # GUI detection.
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --print-resolved 2>/dev/null
  "
  assert_success
  assert_output --partial "GUI_MODE=force"
  assert_output --partial "GUI_ENABLED=true"
  # CLI override flips GUI to off, ignoring setup.conf.
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --gui off --print-resolved 2>/dev/null
  "
  assert_success
  assert_output --partial "GUI_MODE=off"
  assert_output --partial "GUI_ENABLED=false"
}

@test "apply --gui=force enables GUI even when setup.conf says off (#338)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = off
EOF
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --gui=force --print-resolved 2>/dev/null
  "
  assert_success
  assert_output --partial "GUI_MODE=force"
  assert_output --partial "GUI_ENABLED=true"
}

@test "apply --gui rejects values outside auto|force|off (#338)" {
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --gui bogus 2>&1
  "
  assert_failure
  assert_output --partial "Invalid value"
}

@test "apply --print-resolved prints KEY=VALUE state without writing .env (#338)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = off
[deploy]
gpu_mode = off
EOF
  cat > "${TEMP_DIR}/Dockerfile" <<'EOC'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --print-resolved 2>/dev/null
  "
  assert_success
  # Expected resolved lines
  assert_output --partial "GUI_MODE=off"
  assert_output --partial "GUI_ENABLED=false"
  assert_output --partial "GPU_MODE=off"
  assert_output --partial "GPU_ENABLED=false"
  # And NO file was written.
  [[ ! -f "${TEMP_DIR}/.env.generated" ]]
  [[ ! -f "${TEMP_DIR}/compose.yaml" ]]
}

@test "apply --print-resolved respects --gui override in the dump (#338)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = auto
EOF
  cat > "${TEMP_DIR}/Dockerfile" <<'EOC'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    SETUP_DETECT_JETSON=false main apply --base-path '${TEMP_DIR}' --gui force --print-resolved 2>/dev/null
  "
  assert_success
  assert_output --partial "GUI_MODE=force"
  assert_output --partial "GUI_ENABLED=true"
}

@test "apply --no-x11-cookie records X11_COOKIE_SKIP=1 in print-resolved (#338)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = auto
EOF
  cat > "${TEMP_DIR}/Dockerfile" <<'EOC'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --no-x11-cookie --print-resolved 2>/dev/null
  "
  assert_success
  assert_output --partial "X11_COOKIE_SKIP=1"
}

@test "apply without --no-x11-cookie records X11_COOKIE_SKIP=0 (default) (#338)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = auto
EOF
  cat > "${TEMP_DIR}/Dockerfile" <<'EOC'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --print-resolved 2>/dev/null
  "
  assert_success
  assert_output --partial "X11_COOKIE_SKIP=0"
}

@test "apply SETUP_GUI env var overrides setup.conf when --gui not passed (#338)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = force
EOF
  cat > "${TEMP_DIR}/Dockerfile" <<'EOC'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    SETUP_GUI=off main apply --base-path '${TEMP_DIR}' --print-resolved 2>/dev/null
  "
  assert_success
  assert_output --partial "GUI_MODE=off"
  assert_output --partial "GUI_ENABLED=false"
}

@test "apply --gui CLI wins over SETUP_GUI env var (resolution order CLI > env) (#338)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = auto
EOF
  cat > "${TEMP_DIR}/Dockerfile" <<'EOC'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    SETUP_GUI=off main apply --base-path '${TEMP_DIR}' --gui force --print-resolved 2>/dev/null
  "
  assert_success
  # CLI --gui force wins
  assert_output --partial "GUI_MODE=force"
}

# ════════════════════════════════════════════════════════════════════
# P2: propagation + non-privileged guard
# ════════════════════════════════════════════════════════════════════
@test "apply warns when device propagation used without privileged (#450 P2)" {
  mkdir -p "${TEMP_DIR}"
  cat > "${TEMP_DIR}/.setup.conf" <<'EOC'
[security]
privileged = false
[devices]
device_1 = /dev:/dev:rslave
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --print-resolved 2>&1
  "
  assert_success
  assert_output --partial "propagation"
  assert_output --partial "privileged"
}

@test "apply suppresses propagation warning when privileged is true (#450 P2)" {
  mkdir -p "${TEMP_DIR}"
  cat > "${TEMP_DIR}/.setup.conf" <<'EOC'
[security]
privileged = true
[devices]
device_1 = /dev:/dev:rslave
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --print-resolved 2>&1
  "
  assert_success
  refute_output --partial "propagation"
}

# ════════════════════════════════════════════════════════════════════
# P4: duplicate device/volume target path detection
# ════════════════════════════════════════════════════════════════════
@test "apply warns when device and volume have same target path (#450 P4)" {
  mkdir -p "${TEMP_DIR}"
  cat > "${TEMP_DIR}/.setup.conf" <<'EOC'
[devices]
device_1 = /dev:/dev:rslave
[volumes]
mount_5 = /dev:/dev
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --print-resolved 2>&1
  "
  assert_success
  assert_output --partial "duplicate"
}

@test "apply does NOT warn duplicate when device and volume targets differ (#450 P4)" {
  mkdir -p "${TEMP_DIR}"
  cat > "${TEMP_DIR}/.setup.conf" <<'EOC'
[devices]
device_1 = /dev:/dev:rslave
[volumes]
mount_5 = /data:/data
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' --print-resolved 2>&1
  "
  assert_success
  refute_output --partial "duplicate"
}

# ════════════════════════════════════════════════════════════════════
# S7: runtime.env retired. apply no longer emits it; [environment]
# still reaches compose.yaml (and is baked as ENV for the field via S3).
# ════════════════════════════════════════════════════════════════════
@test "apply no longer emits runtime.env; [environment] still lands in compose.yaml (#507)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOC'
[environment]
env_1 = FOO=bar
env_2 = BAR=${FOO}_x
EOC
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  # runtime.env is retired -- it must NOT be created.
  assert [ ! -f "${TEMP_DIR}/runtime.env" ]
  # The resolved (cross-ref expanded) values still reach compose.yaml.
  run grep -F 'BAR=bar_x' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "_write_runtime_env is removed (#507)" {
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    declare -F _write_runtime_env
  "
  assert_failure
}
