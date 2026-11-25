#!/usr/bin/env fish

set -l repo_dir (path resolve (status dirname)/..)
set -l source_app "$repo_dir/dist/OpenContexts.app"
set -l target_app "/Applications/OpenContexts.app"

if not test -d "$source_app"
    echo "Built app not found: $source_app" >&2
    echo "Run ./scripts/build-app.sh debug first." >&2
    exit 1
end

pkill OpenContexts 2>/dev/null; or true
rm -rf "$target_app"; or exit 1
ditto "$source_app" "$target_app"; or exit 1
open "$target_app"
