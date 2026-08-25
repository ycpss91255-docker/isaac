#!/usr/bin/env bash
#
# logrotate.sh -- shared glog-style log-rotation primitives.
#
# Pure, side-effect-free functions (no strict-mode assumptions, no
# source-time actions) shared by the two log producers that both want
# "newest per-start real file + stable symlink + bounded history":
#
#   - the wrapper transcript (host-side lib/transcript.sh): real file
#     `log/<verb>/<ts>-<traceid8>.log`, stable symlink `latest.log`.
#   - the container-log tee (in-image runtime/logging.sh): real file
#     `log/<svc>/<svc>_<ts>.log`, stable symlink `log/<svc>/<svc>.log`.
#
# Both need to (a) repoint a stable symlink at the run's real file so
# `tail <symlink>` always shows the current run, and (b) prune old
# per-start real files by keep-count AND age (stricter wins) without
# ever touching the symlink. That logic used to live only inside
# transcript.sh (_transcript_prune + the latest.log ln); it is extracted
# here so the container-log tee reuses it verbatim instead of a second
# parallel implementation. The symlink NAME, dir, keep, and days are all
# parameters, so each producer keeps its own naming scheme.
#
# The file is COPY'd into every image at /usr/local/lib/base/logrotate.sh
# (alongside logging.sh) so the in-image container-log tee can source it;
# host-side, lib/transcript.sh sources it via ../runtime/logrotate.sh.
#
# Refs:    ADR-00000021, ADR-00000007.

# Guard against double-sourcing (transcript.sh and logging.sh may both be
# in the same source graph in a unit spec).
if [[ -n "${_DOCKER_RUNTIME_LOGROTATE_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_RUNTIME_LOGROTATE_SOURCED=1

# _logrotate_repoint <real_file> <symlink_name>
#   Point <dir>/<symlink_name> at <real_file>, where <dir> is the
#   directory holding <real_file>. The link target is the RELATIVE
#   basename (not an absolute path) so the symlink survives the whole
#   log dir being moved (e.g. a bind-mount remap). `ln -sfn` atomically
#   replaces any pre-existing file/symlink of that name. Repointing does
#   NOT delete the previously-linked file -- history is retained; the old
#   real files age out via _logrotate_prune. Best-effort: a failure
#   leaves the previous symlink untouched and never aborts the caller.
_logrotate_repoint() {
  local _real="${1:?_logrotate_repoint: missing real file}"
  local _link="${2:?_logrotate_repoint: missing symlink name}"
  local _dir
  _dir="$(dirname -- "${_real}")"
  ln -sfn "$(basename -- "${_real}")" "${_dir}/${_link}" 2>/dev/null || true
}

# _logrotate_prune <dir> <symlink_name> <keep> <days>
#   Retention for the per-start *.log real files in <dir>: keep at most
#   <keep> most-recent AND drop any older than <days> days -- the
#   stricter of the two wins. NO symlink is ever removed -- neither the
#   caller's own <symlink_name> nor a sibling service's stable symlink
#   sharing the dir (both passes exclude symlinks).
#
#   Known limitation (pooled keep): both passes glob every *.log real file
#   in <dir>, so when multiple services share one /var/log/<repo>/ dir the
#   <keep>/<days> caps are POOLED across services, not per-service. Under
#   the one-service-per-repo model this is rare and out of scope here;
#   revisit if a repo runs many services teeing into the same dir.
#
#   Failure-safe (best-effort); a missing dir is a no-op.
_logrotate_prune() {
  local _dir="${1:?_logrotate_prune: missing dir}"
  local _link="${2:?_logrotate_prune: missing symlink name}"
  local _keep="${3:-20}" _days="${4:-14}"
  [[ -d "${_dir}" ]] || return 0

  # Age-based drop: real *.log files older than <days> days. Portable
  # `find -mtime` (busybox + GNU); `-type f` matches only regular files,
  # so the stable symlink is skipped even though its name ends in .log.
  find "${_dir}" -maxdepth 1 -type f -name '*.log' -mtime "+${_days}" \
    -exec rm -f -- {} + 2>/dev/null || true

  # Count-based drop: keep the <keep> newest real files, remove the rest.
  # `ls -t` is newest-first and portable. Skip ANY symlink (`-h`), not just
  # the caller's own by name: a shared /var/log/<repo>/ dir can hold a
  # SIBLING service's stable `<other>.log` symlink, which is not a real
  # per-start file and must never be pruned (mirrors the age pass's
  # `-type f`, so prune is symlink-safe regardless of name).
  local -a _files=()
  local _f
  while IFS= read -r _f; do
    [[ -z "${_f}" ]] && continue
    [[ -h "${_f}" ]] && continue
    [[ "$(basename -- "${_f}")" == "${_link}" ]] && continue
    _files+=("${_f}")
  done < <(ls -1t -- "${_dir}"/*.log 2>/dev/null)

  local _n=${#_files[@]}
  if (( _n > _keep )); then
    local _i
    for (( _i=_keep; _i<_n; _i++ )); do
      rm -f -- "${_files[_i]}" 2>/dev/null || true
    done
  fi
  return 0
}
