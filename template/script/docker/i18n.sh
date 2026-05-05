#!/usr/bin/env bash
# i18n.sh - Shared i18n helpers for Docker scripts
#
# Sourced by: build.sh, run.sh, exec.sh, stop.sh, setup.sh
#
# Provides:
#   _detect_lang     — detect language from $LANG env var
#                      output: "zh-TW" | "zh-CN" | "ja" | "en"
#   _sanitize_lang   — warn + fall back to "en" when an unsupported
#                      --lang value is given. Non-fatal; lets the user
#                      see the typo but keeps going in English.
#
# After sourcing, _LANG is set (caller can override via SETUP_LANG env var).

_detect_lang() {
  local _sys_lang="${LANG:-}"
  case "${_sys_lang}" in
    zh_TW*) echo "zh-TW" ;;
    zh_CN*|zh_SG*) echo "zh-CN" ;;
    ja*) echo "ja" ;;
    *) echo "en" ;;
  esac
}

# _sanitize_lang <outvar_name> [<script_name>]
#
# Reads the current value of the nameref, and if it's not in
# {en, zh-TW, zh-CN, ja} prints a warning to stderr and rewrites
# the nameref to "en". Callers invoke this right after parsing
# --lang so typos don't silently fall through to English at message
# lookup time (visible warning, safe default, non-fatal).
#
# Warning language: the user just demonstrated they don't know the
# right --lang value, so we can't trust _LANG (it holds the invalid
# input). Instead we re-detect from the system's $LANG env var so
# the warning appears in the user's actual locale.
_sanitize_lang() {
  local -n _sl_ref="${1:?"${FUNCNAME[0]}: missing outvar name"}"
  local _who="${2:-tui}"
  case "${_sl_ref}" in
    en|zh-TW|zh-CN|ja) return 0 ;;
  esac
  local _sys_lang
  _sys_lang="$(_detect_lang)"
  case "${_sys_lang}" in
    zh-TW)
      printf "[%s] 警告：不支援的 --lang 值 %q，改用 'en'\n" "${_who}" "${_sl_ref}" >&2
      printf "[%s]       可用值：en | zh-TW | zh-CN | ja\n" "${_who}" >&2
      ;;
    zh-CN)
      printf "[%s] 警告：不支持的 --lang 值 %q，改用 'en'\n" "${_who}" "${_sl_ref}" >&2
      printf "[%s]       可用值：en | zh-TW | zh-CN | ja\n" "${_who}" >&2
      ;;
    ja)
      printf "[%s] 警告: サポート外の --lang 値 %q, 'en' にフォールバックします\n" "${_who}" "${_sl_ref}" >&2
      printf "[%s]       利用可能: en | zh-TW | zh-CN | ja\n" "${_who}" >&2
      ;;
    *)
      printf "[%s] WARNING: unsupported --lang value %q, falling back to 'en'\n" "${_who}" "${_sl_ref}" >&2
      printf "[%s]          allowed: en | zh-TW | zh-CN | ja\n" "${_who}" >&2
      ;;
  esac
  _sl_ref="en"
}

_LANG="${SETUP_LANG:-$(_detect_lang)}"
