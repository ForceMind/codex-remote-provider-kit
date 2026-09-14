#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
version=$(tr -d '[:space:]' < "$repo_dir/VERSION")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || { printf 'VERSION is not semantic: %s\n' "$version" >&2; exit 1; }

for script in "$repo_dir"/*.sh "$repo_dir"/tests/*.sh "$repo_dir"/scripts/*.sh; do bash -n "$script"; done
bash "$repo_dir/tests/test-version.sh"

if [[ ${CODEX_RP_RELEASE_TAG:-} ]]; then
  [[ "$CODEX_RP_RELEASE_TAG" == "v$version" ]] || { printf 'Release tag must be v%s\n' "$version" >&2; exit 1; }
fi
if [[ ${CODEX_RP_REQUIRE_CLEAN_TREE:-0} == 1 ]] && [[ -n $(git -C "$repo_dir" status --porcelain) ]]; then
  printf 'Working tree must be clean for release preflight\n' >&2
  exit 1
fi

printf 'release preflight: version %s is ready for a separately reviewed release\n' "$version"
