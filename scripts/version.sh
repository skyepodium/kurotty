#!/usr/bin/env bash
# Resolves the release version without a checked-in VERSION file.
#
# The git tag is the release. It always was: the release workflow passes
# `${GITHUB_REF_NAME#v}` straight to package-release.sh, and the artifact
# verifier compares the built Info.plist against that same tag. The VERSION file
# only ever served as the fallback for an argument-less local run, yet keeping it
# in sync cost a commit and two pull requests before every single release.
#
# Order: an explicit argument, then the tag on HEAD, then the nearest tag plus a
# commit count for an untagged working build, then a plain dev marker.
kurotty_resolve_version() {
  local explicit="${1:-}"
  local resolved=""

  if [[ -n "$explicit" ]]; then
    resolved="$explicit"
  elif resolved="$(git describe --tags --exact-match HEAD 2>/dev/null)"; then
    :
  elif resolved="$(git describe --tags --dirty 2>/dev/null)"; then
    :
  else
    resolved="0.0.0-dev"
  fi

  printf '%s' "${resolved#v}"
}
