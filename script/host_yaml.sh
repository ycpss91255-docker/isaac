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

# _hy_extract <file> -- print the public_ip scalar with inline comment,
# quotes, and surrounding whitespace removed. Empty if the key is absent.
_hy_extract() {
  awk -F': *' '
    /^[[:space:]]*public_ip:/ {
      v = $2
      sub(/[[:space:]]*#.*$/, "", v)            # drop inline comment
      gsub(/"/, "", v)                          # drop quotes
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v) # trim
      print v
      exit
    }
  ' "$1" 2>/dev/null || true
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
