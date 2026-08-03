#!/usr/bin/env bash
# host_yaml.sh -- shared host.yaml `network.public_ip` extraction +
# validation. Sourced by both call sites so they never drift (#104):
#   - script/run_instance.sh        (host side, sourced from script_dir)
#   - script/runheadless-host-config.sh (container side, sourced from
#                                        /usr/local/lib/host_yaml.sh)
#
# The parsed value flows into Kit's --/app/livestream/publicEndpointAddress
# and the web-viewer SIGNALING_SERVER, so it must be clean: a trailing
# inline `# comment`, surrounding quotes, and stray whitespace are
# stripped, and the result is charset-validated before use. A present-but-
# unparseable key warns (localhost-only) rather than silently passing a
# garbage value that breaks WebRTC with no diagnostic.

# _hy_extract_scalar <file> <key> -- print the first `<key>:` scalar value
# with inline comment, surrounding quotes, and whitespace removed. Empty if
# the key is absent or present-but-blank. The key is matched at any
# indentation (the file has a single `public_ip` and a single
# `livestream.ports` block, so a leaf-name match is unambiguous).
_hy_extract_scalar() {
  awk -v key="$2" '
    $0 ~ ("^[[:space:]]*" key ":") {
      sub(/^[[:space:]]*[^:]*:[[:space:]]*/, "")  # strip key + colon + ws
      sub(/[[:space:]]*#.*$/, "")                 # drop inline comment
      gsub(/"/, "")                               # drop quotes
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")     # trim
      print
      exit
    }
  ' "$1" 2>/dev/null || true
}

# _hy_extract <file> -- print the public_ip scalar with inline comment,
# quotes, and surrounding whitespace removed. Empty if the key is absent.
_hy_extract() {
  _hy_extract_scalar "$1" public_ip
}

# _hy_has_key <file> -- succeed if a public_ip: key line exists at all
# (used to tell "not configured" apart from "configured but unparseable").
_hy_has_key() {
  grep -qE '^[[:space:]]*public_ip:' "$1" 2>/dev/null
}

# resolve_public_ip <file> -- echo a validated public_ip, or nothing.
#   - file absent / key absent      -> empty, rc 0 (localhost-only, silent)
#   - key present but empty/garbage -> empty, rc 0, WARN on stderr
#   - value present but invalid     -> rc 1, ERROR on stderr (caller aborts)
#   - value valid                   -> echo value, rc 0
resolve_public_ip() {
  local file="$1" val
  [ -f "${file}" ] || return 0
  val="$(_hy_extract "${file}")"
  if [ -z "${val}" ]; then
    if _hy_has_key "${file}"; then
      printf '[host.yaml] WARN: public_ip present but empty/unparseable in %s; remote browser access disabled (localhost only).\n' \
        "${file}" >&2
    fi
    return 0
  fi
  if ! printf '%s' "${val}" | grep -qE '^[A-Za-z0-9.-]+$'; then
    printf '[host.yaml] ERROR: invalid public_ip %s in %s (expected IPv4 / hostname chars A-Za-z0-9.-).\n' \
      "'${val}'" "${file}" >&2
    return 1
  fi
  printf '%s' "${val}"
}

# resolve_port <file> <signal|media|serve|api> (#231) -- echo a validated
# livestream port, or nothing. Absent/omitted keys reproduce today's
# defaults at the call site, so:
#   - file absent / key absent / value blank -> empty, rc 0 (omit => default)
#   - value present but non-numeric / out of 1..65535 -> rc 1, ERROR on
#     stderr (caller aborts, same discipline as resolve_public_ip)
#   - valid port -> echo value, rc 0
resolve_port() {
  local file="$1" key="$2" val
  [ -f "${file}" ] || return 0
  val="$(_hy_extract_scalar "${file}" "${key}")"
  [ -n "${val}" ] || return 0
  if ! printf '%s' "${val}" | grep -qE '^[0-9]+$' \
    || [ "${val}" -lt 1 ] || [ "${val}" -gt 65535 ]; then
    printf '[host.yaml] ERROR: invalid %s port %s in %s (expected an integer 1..65535).\n' \
      "${key}" "'${val}'" "${file}" >&2
    return 1
  fi
  printf '%s' "${val}"
}
