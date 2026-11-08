#!/usr/bin/env bash
# stream_smoke.sh -- producer-side GPU smoke for the stream stage.
#
# Verifies the GPU-only path that hosted CI runners cannot: the Isaac Sim
# stream container boots, its WebRTC streaming server starts, AND it
# survives a real client attaching to it. No frame assertion -- that is
# Tier B (#173). Runs on a GPU host or a self-hosted GPU runner.
#
# Flow: `./script/run.sh -t stream -d` (idle container + viewer via post-run
# hook) -> `docker exec -d runheadless-host-config.sh` (launch Isaac) ->
# wait for the stream-server + app-loaded markers in OUR Isaac's kit log ->
# attach a client -> wait for the stream-start sequence -> hold the
# connection for a dwell window asserting Kit stays alive and the client is
# not dropped -> PASS / FAIL -> tear down (always).
#
# Why the client attach exists (#233): until it did, this script asserted
# only that the server came up. "Port is listening" and "streaming actually
# works" are different claims. A Kit that boots, opens the signaling
# socket, then is SIGKILLed the moment the media pipeline allocates on
# first client attach (observed on the GPU host: a container left with only
# the default 64 MB private /dev/shm) satisfied the first claim while
# failing the second, and Tier A still went green. Any regression in the
# media path -- shm, encoder, GPU capability flags, device bindings -- was
# invisible.
#
# Readiness is asserted from OUR container's redirected kit log, not from a
# host port: the container runs with `network=host`, so `ss :PORT` would also
# match any unrelated Isaac left on the host (false pass), and the signaling
# socket binds early in startup -- before the stream server is actually up.
# Kit 110 (Isaac Sim 6.x, omni.kit.livestream.app 10.x) logs
# `Started primary stream server on signal port N ...` once the server is up,
# then `<App> is loaded.` once the app finished booting; both are scoped to
# our log. (Kit 107 / Isaac Sim 5.x logged `Streaming server started.`
# instead; that line no longer exists, which is why every run after the 6.0.1
# upgrade timed out at 600 s -- isaac#291.)
#
# The pass/fail decision logic lives in stream_smoke_lib.sh so it is unit
# tested on every image build (test/bats/smoke/stream_smoke_lib_spec.bats)
# even though this GPU path only runs nightly.
#
# Env knobs:
#   SMOKE_TIMEOUT          seconds to wait for the ready markers (default 600)
#   SMOKE_CONNECT_TIMEOUT  seconds to wait for the stream-start sequence
#                          after the client attaches (default 120)
#   SMOKE_DWELL            seconds to hold the connection (default 30)
#   SMOKE_POLL             poll interval for both waits (default 5)
#   SMOKE_LOG_TAIL         kit log lines printed on failure (default 60)
#   SMOKE_READY_MARKERS    newline-separated ordered kit-log markers that
#                          define "the stream server is up and the app booted"
#   SMOKE_STREAM_MARKERS   newline-separated ordered kit-log markers that
#                          define "a client is really streaming"
#   SMOKE_CLIENT_CMD       shell command (run on the host, detached) that
#                          attaches the client; replaces the default client
#   SMOKE_VIEWER_IMAGE     web-viewer image the default client loads the page
#                          from (default: a pinned GHCR release)
#   SMOKE_BROWSER_IMAGE    image providing headless Chromium for the default
#                          client (default: a pinned Playwright image)
#   SMOKE_REAP_PROJECT_PREFIX
#                          compose-project prefix owned by this smoke (CI sets
#                          `isaac-smoke-`). When set, containers of any OTHER
#                          project with that prefix -- a previous smoke run
#                          whose teardown never ran (SIGKILL, cancelled job)
#                          -- are removed before bring-up. Unset (local runs)
#                          => nothing outside this run's project is touched.
#   SMOKE_LIB              path to stream_smoke_lib.sh (default: alongside)
#   HOST_YAML_LIB          path to host_yaml.sh (default: ../host_yaml.sh)
#
# The default client is a real WebRTC peer: headless Chromium loading the
# stream-only web-viewer page. A bare WebSocket handshake cannot do this
# job: Kit 110's signaling server answers anything but
# `/sign_in?peer_id=...` with `501 Not Implemented`, and even a correct
# sign_in only yields the server's SDP offer -- the peer connection (and the
# media-pipeline allocation #233 is about) needs a client that answers the
# offer and completes ICE/DTLS. The earlier curl probe therefore never
# produced a single attach marker (isaac#291). This is still not a frame
# assertion (Tier B): only Kit-log markers are asserted. Both client
# containers are per-run (`<project>-client-*`) and the page is served on a
# per-run free port, so a co-hosted viewer already holding 5173 cannot
# capture the client.
#
# Exit 0 = a client streamed and Kit survived the dwell; 1 = container
# died / timed out / client dropped (kit log tailed on every failure).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
timeout_s="${SMOKE_TIMEOUT:-600}"
connect_timeout_s="${SMOKE_CONNECT_TIMEOUT:-120}"
dwell_s="${SMOKE_DWELL:-30}"
poll_s="${SMOKE_POLL:-5}"
log_tail_n="${SMOKE_LOG_TAIL:-60}"
viewer_image="${SMOKE_VIEWER_IMAGE:-ghcr.io/ycpss91255-docker/omniverse_web_viewer:0.3.0}"
browser_image="${SMOKE_BROWSER_IMAGE:-mcr.microsoft.com/playwright:v1.62.1-noble}"

# shellcheck source=stream_smoke_lib.sh
. "${SMOKE_LIB:-$(dirname "${BASH_SOURCE[0]}")/stream_smoke_lib.sh}"

# Ordered kit-log markers of a booted stream server, as logged by Kit 110 on
# the GPU host (isaac#291): server listening -> app fully loaded. Attaching
# only after the app loaded keeps a slow cold-cache boot out of the connect
# budget.
ready_markers=(
  'Started primary stream server'
  'App is loaded.'
)
if [[ -n "${SMOKE_READY_MARKERS:-}" ]]; then
  mapfile -t ready_markers <<< "${SMOKE_READY_MARKERS}"
fi

# Ordered kit-log markers of a healthy attach, as logged by Kit 110 on the
# GPU host with a real browser peer (isaac#291): signaling headers received
# -> WebRTC peer connected. (Kit 107 logged onSignalingHeaders ->
# NVST_CCE_CONNECTED -> All Streams connected. instead.)
stream_markers=(
  'signaling headers'
  'Client connected to WebRTC server'
)
if [[ -n "${SMOKE_STREAM_MARKERS:-}" ]]; then
  mapfile -t stream_markers <<< "${SMOKE_STREAM_MARKERS}"
fi

# Identity + workspace from .env.generated (base A2 model), .env overlays.
# WS_PATH (not repo_root) anchors the bind-mounted kit/logs: the compose mount
# is ${WS_PATH}/isaac-sim/kit/logs, and WS_PATH may differ from the repo root.
USER_NAME=""
IMAGE_NAME="isaac"
WS_PATH=""
# shellcheck source=/dev/null
[ -f "${repo_root}/.env.generated" ] && . "${repo_root}/.env.generated"
# shellcheck source=/dev/null
[ -f "${repo_root}/.env" ] && . "${repo_root}/.env"

# Compose-project isolation (owv#55). base v0.42.0 removed --instance
# (base#666); isolation is now a DISTINCT resolved PROJECT_NAME. The nightly
# smoke pins one (default `<derived>-smoke`, override SMOKE_PROJECT for a
# per-run-unique value e.g. the CI run id) into the derived .env.generated
# cache run.sh reads, brings the stack up with a plain `run.sh -t stream -d`
# under that project, resolves its stream container BY PROJECT, and tears the
# whole project down. A distinct project fully contains run.sh's project-wide
# EXIT-trap teardown, so the smoke can never reap a co-hosted manually-run
# DEFAULT stream stack (`./script/run.sh -t stream -d`) on a shared GPU host,
# nor no-op on the stale pre-isaac#238 literal `owv` viewer name.
#
# We pin via a surgical sed of the PROJECT_NAME= line (the same post-apply sed
# the CI WS_PATH pin uses) rather than `setup.sh apply` with a .setup.conf.local
# override, because a second apply here would re-run detection and clobber the
# CI WS_PATH pin the prior apply step wrote.
_default_project="${DOCKER_HUB_USER:-local}-${IMAGE_NAME}"
smoke_project="${SMOKE_PROJECT:-${PROJECT_NAME:-${_default_project}}-smoke}"
if [ -f "${repo_root}/.env.generated" ]; then
  sed -i "s|^PROJECT_NAME=.*|PROJECT_NAME=${smoke_project}|" \
    "${repo_root}/.env.generated"
fi

# Print the isaac-owned per-project name suffix, derived the same way
# post/run.sh derives it: empty for the default project, "-<remainder>"
# otherwise.
#
# Usage: project_suffix <project>
project_suffix() {
  if [ "$1" != "${_default_project}" ]; then
    printf -- '-%s' "${1#"${_default_project}-"}"
  fi
}

_suffix="$(project_suffix "${smoke_project}")"
viewer="${USER_NAME}-${IMAGE_NAME}-owv${_suffix}"
client_viewer="${smoke_project}-client-viewer"
client_browser="${smoke_project}-client-browser"
smoke_log="${WS_PATH:-${repo_root}}/isaac-sim/kit/logs/stream-smoke.log"
compose_file="${repo_root}/compose.yaml"
compose_backup=""
cid=""
client_pid=""

# Per-run stream container name (isaac#291). base v0.42.0 compose_emit.sh
# emits a fixed `container_name: ${USER_NAME}-<image>-stream` that ignores
# PROJECT_NAME, so a distinct project alone does not make the name unique:
# any other stream stack on the host -- a developer's, running or merely
# exited -- holds that name and `compose up` fails with "Conflict. The
# container name ... is already in use" before Isaac ever starts. Renaming
# OUR copy (the derived compose.yaml, regenerated by every `setup.sh apply`,
# restored on exit) to the per-project suffix removes the collision without
# touching anyone else's container. The post-run hook is told the new name
# via ISAAC_STREAM_CONTAINER. base v0.43.0 stops emitting container_name
# (base#920); then the line is absent and this is a no-op.
_fixed_stream_line="    container_name: \${USER_NAME}-${IMAGE_NAME}-stream"
if [ -n "${_suffix}" ] && [ -f "${compose_file}" ] \
    && grep -qxF "${_fixed_stream_line}" "${compose_file}"; then
  compose_backup="$(mktemp)"
  cp "${compose_file}" "${compose_backup}"
  sed -i "s|^\(${_fixed_stream_line}\)\$|\1${_suffix}|" "${compose_file}"
  export ISAAC_STREAM_CONTAINER="${USER_NAME}-${IMAGE_NAME}-stream${_suffix}"
fi

# Project-scoped compose invocation (the -p / --env-file / -f the wrappers
# use), so `ps -q` / `down` address THIS run's project and nothing else.
compose_smoke() {
  docker compose -p "${smoke_project}" \
    --env-file "${repo_root}/.env.generated" \
    -f "${compose_file}" "$@"
}

# Project-scoped teardown. COMPOSE_PROFILES='*' is required: the stream
# service sits behind `profiles: [stream]`, and a plain `compose down` skips
# services of inactive profiles, so it silently left the stream container
# (and the Kit inside it) running -- every run leaked one, and the leak held
# the fixed name for the next run (isaac#291). Same flag base's own run.sh
# teardown uses.
compose_smoke_down() {
  COMPOSE_PROFILES='*' compose_smoke down -t 0 --remove-orphans
}

# Signal port the client attaches to. Resolve it the same way the post-run
# hook does (#231): config/host.yaml `livestream.ports.signal` wins, then an
# ISAAC_SIGNAL_PORT already in env, then Kit's own default. Probing the
# wrong port would look exactly like "the client never reached Kit".
# shellcheck source=../host_yaml.sh
. "${HOST_YAML_LIB:-${repo_root}/script/host_yaml.sh}"
signal_port="$(resolve_port "${repo_root}/config/host.yaml" signal)" || exit 1
signal_port="${signal_port:-${ISAAC_SIGNAL_PORT:-49100}}"

cleanup() {
  echo "[smoke] teardown: down project ${smoke_project} + remove viewer ${viewer} + client"
  if [[ -n "${client_pid}" ]]; then
    kill "${client_pid}" 2>/dev/null || true
  fi
  docker rm -f "${client_browser}" "${client_viewer}" >/dev/null 2>&1 || true
  # Project-scoped: cannot touch a globally-named manual/default stack.
  compose_smoke_down >/dev/null 2>&1 || true
  # The viewer runs out-of-compose (post/run.sh `docker run --name`), so the
  # project `down` above does not see it -- remove it by its isaac-owned name.
  docker rm -f "${viewer}" >/dev/null 2>&1 || true
  if [[ -n "${compose_backup}" ]]; then
    cp "${compose_backup}" "${compose_file}" 2>/dev/null || true
    rm -f "${compose_backup}"
  fi
}
trap cleanup EXIT INT TERM

# Remove what a previous smoke run left behind when its teardown never ran
# (runner SIGKILL, cancelled job, or the pre-#291 profile-blind `down`). A
# leftover keeps Kit bound to the signaling / media / API ports, so the next
# run's Kit cannot serve. Scope is deliberately narrow: only compose projects
# with the CI-owned SMOKE_REAP_PROJECT_PREFIX (never a developer project), only
# when this run's own project carries that prefix, never this run's project,
# plus those projects' viewers and clients by their per-run names. The
# workflow's `concurrency: stream-smoke` group guarantees no other smoke is
# live while this runs.
reap_stale_smoke_projects() {
  local _prefix="${SMOKE_REAP_PROJECT_PREFIX:-}"
  local _p="" _ids="" _name=""
  [ -n "${_prefix}" ] || return 0
  case "${smoke_project}" in
    "${_prefix}"*) ;;
    *)
      echo "[smoke] reap skipped: ${smoke_project} is not under ${_prefix}"
      return 0
      ;;
  esac
  while IFS= read -r _p; do
    case "${_p}" in
      "${_prefix}"*) ;;
      *) continue ;;
    esac
    [ "${_p}" != "${smoke_project}" ] || continue
    _ids="$(docker ps -aq --filter "label=com.docker.compose.project=${_p}")"
    if [ -n "${_ids}" ]; then
      echo "[smoke] reap stale smoke project ${_p}"
      # shellcheck disable=SC2086 # word-split the id list on purpose
      docker rm -f ${_ids} >/dev/null 2>&1 || true
    fi
  done < <(docker ps -a --filter label=com.docker.compose.project \
             --format '{{.Label "com.docker.compose.project"}}' | sort -u)
  local _viewer_glob
  _viewer_glob="${USER_NAME}-${IMAGE_NAME}-owv$(project_suffix "${_prefix}")"
  while IFS= read -r _name; do
    case "${_name}" in
      "${viewer}" | "${client_viewer}" | "${client_browser}") continue ;;
      "${_viewer_glob}"* | "${_prefix}"*-client-viewer \
        | "${_prefix}"*-client-browser) ;;
      *) continue ;;
    esac
    echo "[smoke] reap stale smoke container ${_name}"
    docker rm -f "${_name}" >/dev/null 2>&1 || true
  done < <(docker ps -a --format '{{.Names}}')
}

# Bind the library's fail-closed liveness hook to this run's container,
# resolved by the compose project id (base v0.42.0 base-fixed the stream
# container name, so address it by the resolved id, never a global name).
smoke_alive() {
  [ -n "${cid}" ] || return 1
  [ "$(docker inspect -f '{{.State.Running}}' "${cid}" 2>/dev/null)" = "true" ]
}

fail() {
  printf '[smoke] FAIL: %s\n' "$*"
  smoke_log_tail "${smoke_log}" "${log_tail_n}"
  exit 1
}

# Print the first TCP port in [<lo>, <hi>] nothing on 127.0.0.1 listens on.
#
# Usage: free_port <lo> <hi>
free_port() {
  local _p
  for (( _p = $1; _p <= $2; _p++ )); do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/${_p}") 2>/dev/null; then
      printf '%s\n' "${_p}"
      return 0
    fi
  done
  return 1
}

# Default client: a per-run stream-only viewer on a free port, dialing OUR
# Kit's signaling port, loaded by headless Chromium for <hold_s> seconds.
#
# Usage: start_default_client <hold_s>
start_default_client() {
  local _hold="$1" _serve="" _i
  _serve="$(free_port 5180 5299)" \
    || fail "no free port in 5180-5299 for the client viewer"
  echo "[smoke] client viewer ${client_viewer} on :${_serve} -> signal ${signal_port}"
  docker run -d --rm --name "${client_viewer}" --network host \
    -e SIGNALING_SERVER=127.0.0.1 \
    -e "SIGNALING_PORT=${signal_port}" \
    -e "SERVE_PORT=${_serve}" \
    -e VIEWER_UI_MODE=stream-only \
    "${viewer_image}" >/dev/null \
    || fail "client viewer (${viewer_image}) did not start"
  for (( _i = 0; _i < 60; _i++ )); do
    if (exec 3<>"/dev/tcp/127.0.0.1/${_serve}") 2>/dev/null; then
      break
    fi
    sleep 1
  done
  (( _i < 60 )) || fail "client viewer never served on :${_serve}"
  echo "[smoke] client browser ${client_browser} (${browser_image})"
  # shellcheck disable=SC2016 # $1 expands inside the container's sh
  docker run -d --rm --name "${client_browser}" --network host \
    --user pwuser --entrypoint sh "${browser_image}" -c \
    'set -- /ms-playwright/chromium-*/chrome-linux*/chrome
     exec timeout "'"${_hold}"'" "$1" --headless=new --no-sandbox \
       --disable-gpu --mute-audio --disable-background-networking \
       --autoplay-policy=no-user-gesture-required \
       --disable-features=WebRtcHideLocalIpsWithMdns \
       --remote-debugging-port=0 --user-data-dir=/tmp/smoke-profile \
       "http://127.0.0.1:'"${_serve}"'/"' >/dev/null \
    || fail "client browser (${browser_image}) did not start"
}

# Start clean: reap leftovers of previous smoke runs (CI only), tear down any
# stale stack in this project + drop a stale viewer / client from a prior run
# so we never mistake a leftover for this run's Isaac, and so the kit log is
# fresh.
reap_stale_smoke_projects
echo "[smoke] pre-clean stale project ${smoke_project} + viewer ${viewer} + client"
compose_smoke_down >/dev/null 2>&1 || true
docker rm -f "${viewer}" "${client_browser}" "${client_viewer}" \
  >/dev/null 2>&1 || true
rm -f "${smoke_log}" 2>/dev/null || true

# Pull the default client's images up front so a cold pull never eats into
# the connect budget.
if [[ -z "${SMOKE_CLIENT_CMD:-}" ]]; then
  for _img in "${viewer_image}" "${browser_image}"; do
    docker image inspect "${_img}" >/dev/null 2>&1 \
      || docker pull -q "${_img}" >/dev/null \
      || fail "cannot pull client image ${_img}"
  done
fi

echo "[smoke] bring up stream stage (idle container + viewer)"
# Direct wrapper call (matches the repo's own CI convention; no `just`
# dependency on the runner). The justfile `run` recipe is a 1:1 forward to
# this. run.sh reads the pinned PROJECT_NAME from .env.generated, so the whole
# stack lands in ${smoke_project}.
( cd "${repo_root}" && ./script/run.sh -t stream -d )

# Resolve the stream container BY PROJECT (base v0.42.0 base-fixed its name;
# address the compose-resolved id so a co-hosted stack is never touched).
cid="$(compose_smoke ps -q stream 2>/dev/null | head -1)"

echo "[smoke] launch Isaac (detached) in ${cid:-<unresolved>}"
# Source the per-host livestream port env the post-run hook copied in when
# host.yaml pins any port (#231); absent => no-op, runheadless-host-config.sh
# (unchanged) falls back to its ISAAC_*_PORT-from-env defaults.
docker exec -d "${cid}" \
  sh -c 'set -a; [ -f /etc/isaac/livestream-ports.env ] && . /etc/isaac/livestream-ports.env; set +a; /usr/local/bin/runheadless-host-config.sh > /isaac-sim/kit/logs/stream-smoke.log 2>&1'

echo "[smoke] wait up to ${timeout_s}s for the stream server + app boot:"
printf '[smoke]   -> %s\n' "${ready_markers[@]}"
rc=0
smoke_wait_for "${smoke_log}" "${timeout_s}" "${poll_s}" \
  "${ready_markers[@]}" || rc=$?
case "${rc}" in
  0) echo "[smoke] OK: Isaac WebRTC stream server up and app loaded" ;;
  2) fail "stream container (${cid:-<unresolved>}) is no longer running" ;;
  *) fail "stream server / app did not come up within ${timeout_s}s" ;;
esac

# Hold the client for the whole assertion window plus margin, so it cannot
# time out on its own and make the dwell look like a stream drop.
client_hold_s=$(( connect_timeout_s + dwell_s + 30 ))

echo "[smoke] attach client to signaling port ${signal_port}"
if [[ -n "${SMOKE_CLIENT_CMD:-}" ]]; then
  sh -c "${SMOKE_CLIENT_CMD}" >/dev/null 2>&1 &
  client_pid=$!
else
  start_default_client "${client_hold_s}"
fi

echo "[smoke] wait up to ${connect_timeout_s}s for the stream-start sequence:"
printf '[smoke]   -> %s\n' "${stream_markers[@]}"
rc=0
smoke_wait_for "${smoke_log}" "${connect_timeout_s}" "${poll_s}" \
  "${stream_markers[@]}" || rc=$?
case "${rc}" in
  0) echo "[smoke] OK: client attached, WebRTC peer connected" ;;
  2) fail "Kit died while the client was attaching (the #233 regression)" ;;
  *) fail "streams did not start within ${connect_timeout_s}s of the attach" ;;
esac

# Anchor the drop scan at the connect line so a stale disconnect from an
# earlier session (or this run's own pre-connect noise) cannot fail us.
anchor_line="$(smoke_sequence_line "${smoke_log}" "${stream_markers[@]}")"

echo "[smoke] hold the connection for ${dwell_s}s (poll ${poll_s}s)"
rc=0
smoke_dwell "${smoke_log}" "${dwell_s}" "${poll_s}" "${anchor_line}" || rc=$?
case "${rc}" in
  0) : ;;
  2) fail "Kit died during the ${dwell_s}s dwell (the #233 regression)" ;;
  3) fail "streams stopped during the ${dwell_s}s dwell" ;;
  *) fail "dwell failed with rc ${rc}" ;;
esac

echo "[smoke] PASS: client streamed and Kit survived the ${dwell_s}s dwell"
exit 0
