#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
forbidden="$(printf 'miho%s' mo)"

for path in "compose.${forbidden}.yml" "compose.${forbidden}.env.example"; do
    if [ -e "$repo_root/$path" ]; then
        echo "legacy proxy artifact remains: $path" >&2
        exit 1
    fi
done

if git -C "$repo_root" grep -n -i -- "$forbidden" -- .; then
    echo "legacy proxy references remain in the repository" >&2
    exit 1
else
    rg_status=$?
    if [ "$rg_status" -ne 1 ]; then
        echo "repository scan failed" >&2
        exit "$rg_status"
    fi
fi

git -C "$repo_root" grep -q -- 'ENV_MANAGER_ENABLE' -- README.md
git -C "$repo_root" grep -q -- 'tests/smoke\.sh' -- README.md
git -C "$repo_root" grep -q -- 'ARG DEBIAN_MIRROR=mirrors\.ustc\.edu\.cn' -- Dockerfile
git -C "$repo_root" grep -q -- 'CONTAINER_CONFIG_DIR=/root/\.rabbit_container' -- Dockerfile
git -C "$repo_root" grep -q -- 'STARTUP_SELF_CHECK=true' -- Dockerfile
grep -q -- 'rabbit-dev-container-opt:/opt' "$repo_root/compose.yml"
grep -q -- 'rabbit-dev-container-home:/home' "$repo_root/compose.yml"
printf 'Repository tests passed.\n'
