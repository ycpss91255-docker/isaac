#!/usr/bin/env bash
# drivers/readme_sync.sh - "the localized READMEs are still in sync with the
# English one" per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_readme_sync, the read-only twin of ../sync-readme-hashes.sh -- the
# same relationship check_test_md_drift.sh has with sync-doc-counts.sh: the
# generator writes the derived value, this validates it and never writes.
#
# Contract: runs INSIDE the ci (test-tools) container where test.sh
# invokes it. References ${REPO_ROOT} (a global exported by test.sh).
# Follows drivers/issueref.sh / drivers/adr_numbering.sh / drivers/
# stale_setup_conf.sh conventions (sourced lib, uses ${REPO_ROOT}, _log_* /
# _die, no main).
#
# Why: an English README edit can silently leave doc/readme/README.{zh-TW,
# zh-CN,ja}.md behind, and nothing detected it. It already happened at the
# scale of an entire section -- the field-deployment section was rewritten in
# place while the three translations kept describing the superseded deploy
# model, caught only by a manual review. A headings-only structural check
# would not have caught it (the heading never changed), so the guard is a
# per-section fingerprint: each translated section records the hash of the
# English section it was translated against, and this lint compares that
# record against the current English text.
#
# A marker records BOTH sides: the English section's hash and the translated
# section's own. That second field is what makes a re-stamp mean something --
# see ../sync-readme-hashes.sh -- and this lint keeps it honest, so the
# generator can trust "the translation moved" as evidence rather than as an
# assumption.
#
# What it reports, per file and per SECTION (never just "this file is out of
# date"):
#   STALE       the recorded English hash no longer matches the English
#               section
#   UNRECORDED  the translated section no longer matches the translation
#               hash it was stamped with -- the prose was edited and the
#               generator was never re-run, so the record has decayed
#   UNSTAMPED   a marker carries an id but not both hashes (the generator
#               never ran, or ran before the translation side was recorded)
#   MISSING     an English section that this translation neither translates
#               (a `sync:` marker) nor declares untranslated (`sync-skip:`)
#   UNKNOWN     a marker naming an id that is not an English section -- a
#               typo, or an English heading that was renamed or removed
#   DUPLICATE   one id claimed twice in the same translation
#   MISPLACED   a `sync:` marker that does not sit immediately above a
#               heading
#   AMBIGUOUS   two English headings that slug to the same id, so no marker
#               could name either of them unambiguously
#
# The marker grammar, the section-id derivation and the exact hash input are
# documented in ../sync-readme-hashes.sh, which this sources so the validator
# and the generator can never disagree about them.
#
# Scope: README.md against doc/readme/README.*.md. A fourth language file is
# covered the day it lands (the translation set is a glob, not a list). Both
# roots must exist and at least one translation must be found: an empty scan
# would pass vacuously and silently disable the guard.

_README_SYNC_DRIVER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
readonly _README_SYNC_DRIVER_DIR

# shellcheck source=script/test/sync-readme-hashes.sh
source "${_README_SYNC_DRIVER_DIR}/../sync-readme-hashes.sh"

# ── Localized README sync lint ───────────────────────────────────────────────

_run_readme_sync() {
  echo "--- Running localized README sync lint ---"
  local _violations=0

  local _src="${REPO_ROOT}/${_README_SYNC_SOURCE_REL}"
  if [[ ! -f "${_src}" ]]; then
    _die ci_readme_sync \
      "English source '${_README_SYNC_SOURCE_REL}' not found under ${REPO_ROOT} -- there is nothing to compare the translations against, so the lint would pass vacuously."
    return 1
  fi
  if [[ ! -d "${REPO_ROOT}/${_README_SYNC_DIR_REL}" ]]; then
    _die ci_readme_sync \
      "translation directory '${_README_SYNC_DIR_REL}/' not found under ${REPO_ROOT} -- the lint would pass vacuously. Point it at the localized READMEs."
    return 1
  fi

  local -a _files=()
  mapfile -t _files < <(_readme_translation_files "${REPO_ROOT}")
  if [[ "${#_files[@]}" -eq 0 ]]; then
    _die ci_readme_sync \
      "no '${_README_SYNC_DIR_REL}/${_README_SYNC_GLOB}' found under ${REPO_ROOT} -- the lint would pass vacuously. Update the glob if the localized READMEs moved."
    return 1
  fi

  # English index: id -> current hash, plus document order for stable
  # MISSING reporting. A repeated slug is AMBIGUOUS -- a marker naming it
  # could mean either section, so the id contract is broken at the source.
  local -A _en=()
  local -a _en_order=()
  local _slug _hash
  while IFS=$'\t' read -r _slug _hash; do
    if [[ -n "${_en[${_slug}]+x}" ]]; then
      printf "%s: AMBIGUOUS section id '%s' (two English headings slug to it)\\n" \
        "${_README_SYNC_SOURCE_REL}" "${_slug}"
      _violations=$(( _violations + 1 ))
    else
      _en_order+=( "${_slug}" )
    fi
    _en["${_slug}"]="${_hash}"
  done < <(_readme_index "${_src}")

  local _file _rel _lineno _kind _id _rec_en _rec_tr _cur_tr _follow
  for _file in "${_files[@]}"; do
    _rel="${_file#"${REPO_ROOT}"/}"
    local -A _claimed=()
    while IFS=$'\t' read -r \
        _lineno _kind _id _rec_en _rec_tr _cur_tr _follow; do
      if [[ -n "${_claimed[${_id}]+x}" ]]; then
        printf "%s:%s: DUPLICATE marker for section '%s'\\n" \
          "${_rel}" "${_lineno}" "${_id}"
        _violations=$(( _violations + 1 ))
        continue
      fi
      _claimed["${_id}"]=1

      if [[ -z "${_en[${_id}]+x}" ]]; then
        printf "%s:%s: UNKNOWN section id '%s' (no such section in %s -- renamed, removed, or a typo)\\n" \
          "${_rel}" "${_lineno}" "${_id}" "${_README_SYNC_SOURCE_REL}"
        _violations=$(( _violations + 1 ))
        continue
      fi

      # A skip declaration is a deliberate "this section has no translation";
      # it carries no hash and sits nowhere in particular.
      [[ "${_kind}" == 'skip' ]] && continue

      if [[ "${_follow}" != 'yes' ]]; then
        printf "%s:%s: MISPLACED marker for section '%s' (it must sit immediately above the translated heading)\\n" \
          "${_rel}" "${_lineno}" "${_id}"
        _violations=$(( _violations + 1 ))
        continue
      fi
      # Both hashes or none: a half-stamped marker records no usable
      # translation baseline, so it cannot be told apart from one whose
      # translation never moved.
      if [[ "${_rec_en}" == '-' || "${_rec_tr}" == '-' ]]; then
        printf "%s:%s: UNSTAMPED marker for section '%s' (needs both the English and the translation hash)\\n" \
          "${_rel}" "${_lineno}" "${_id}"
        _violations=$(( _violations + 1 ))
        continue
      fi
      if [[ "${_rec_en}" != "${_en[${_id}]}" ]]; then
        printf "%s:%s: section '%s' is STALE (recorded %s, English is now %s)\\n" \
          "${_rel}" "${_lineno}" "${_id}" "${_rec_en}" "${_en[${_id}]}"
        _violations=$(( _violations + 1 ))
        continue
      fi
      # The translation moved without the generator being re-run. Left
      # alone the record decays, and a later English edit would read this
      # unrelated translation edit as proof of a re-translation it was not.
      if [[ "${_rec_tr}" != "${_cur_tr}" ]]; then
        printf "%s:%s: section '%s' is UNRECORDED (translation stamped as %s, now %s)\\n" \
          "${_rel}" "${_lineno}" "${_id}" "${_rec_tr}" "${_cur_tr}"
        _violations=$(( _violations + 1 ))
      fi
    done < <(_readme_file_markers "${_file}")

    for _slug in "${_en_order[@]}"; do
      [[ -n "${_claimed[${_slug}]+x}" ]] && continue
      printf "%s: section '%s' is MISSING (no sync marker and no sync-skip declaration)\\n" \
        "${_rel}" "${_slug}"
      _violations=$(( _violations + 1 ))
    done
  done

  if [[ "${_violations}" -gt 0 ]]; then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_readme_sync \
      "${_violations} localized-README sync defect(s). Update the named translated section(s) from ${_README_SYNC_SOURCE_REL}, then run 'just test sync-readme' to re-stamp -- never hand-edit a hash. Re-stamping alone will NOT clear a STALE section: the generator refuses to move an English hash while the translation stands still, and 'just test sync-readme --accept <id>' is how you say the English change needs no re-translation. A section that deliberately has no translation is declared once with '<!-- sync-skip: <id> -- <why> -->'."
    return 1
  fi
  echo "localized README sync lint: clean"
}
