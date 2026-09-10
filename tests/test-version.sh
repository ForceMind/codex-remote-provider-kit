#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../lib.sh
source "$repo_dir/lib.sh"

version=$(read_kit_version "$repo_dir")
[[ "$version" == '1.0.0' ]]
[[ $(bash "$repo_dir/setup.sh" version) == "codex-remote-provider-kit $version" ]]
[[ $(bash "$repo_dir/setup.sh" --version) == "codex-remote-provider-kit $version" ]]
grep -Fq "## $version - 2026-08-12" "$repo_dir/CHANGELOG.md"
grep -Fq "当前稳定版本：**$version**" "$repo_dir/README.md"

printf 'release version consistency: ok\n'
