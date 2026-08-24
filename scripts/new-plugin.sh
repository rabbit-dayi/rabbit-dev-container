#!/usr/bin/env bash
# Scaffolds a new plugin from plugins/TEMPLATE/. Intended for maintainers (human
# or AI agents) working on this repo -- it does not run inside the built image.
#
# Usage: scripts/new-plugin.sh <plugin-id>
#
# <plugin-id> becomes the s6 service name (plugin-<plugin-id>) and the
# PLUGIN_<PLUGIN_ID>_ENABLE environment variable. See plugins/README.md for
# the full convention this generates.
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/new-plugin.sh <plugin-id>

<plugin-id> must be lowercase letters, digits, and hyphens only (e.g. "frpc",
"my-tool"). Creates:

  rootfs/etc/s6-overlay/s6-rc.d/plugin-<plugin-id>/run
  rootfs/etc/s6-overlay/s6-rc.d/plugin-<plugin-id>/type
  rootfs/etc/s6-overlay/s6-rc.d/plugin-<plugin-id>/dependencies.d/init-root
  rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/plugin-<plugin-id>

After running, see plugins/README.md for the remaining manual steps: add a
registry.json entry, wire up any Dockerfile install step, document the new
env var in README.md + tests/repository.sh, and cover it in tests/smoke.sh.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -ne 1 ]; then
    usage
    exit "$([ $# -eq 1 ] && echo 0 || echo 2)"
fi

plugin_id="$1"
if [[ ! "$plugin_id" =~ ^[a-z][a-z0-9-]{0,30}$ ]]; then
    echo "error: plugin id must be lowercase letters, digits, and hyphens, starting with a letter" >&2
    exit 1
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
template_dir="${repo_root}/plugins/TEMPLATE"
service_dir="${repo_root}/rootfs/etc/s6-overlay/s6-rc.d/plugin-${plugin_id}"
enable_var="PLUGIN_$(printf '%s' "$plugin_id" | tr '[:lower:]-' '[:upper:]_')_ENABLE"

if [ -e "$service_dir" ]; then
    echo "error: ${service_dir} already exists" >&2
    exit 1
fi

install -d -m 0755 "$service_dir/dependencies.d"
sed -e "s/__PLUGIN_ID__/${plugin_id}/g" -e "s/__PLUGIN_ENABLE_VAR__/${enable_var}/g" \
    "$template_dir/run" > "$service_dir/run"
chmod 0755 "$service_dir/run"
cp "$template_dir/type" "$service_dir/type"
cp "$template_dir/dependencies.d/init-root" "$service_dir/dependencies.d/init-root"
touch "${repo_root}/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/plugin-${plugin_id}"

cat <<EOF
Created rootfs/etc/s6-overlay/s6-rc.d/plugin-${plugin_id}/ (enable var: ${enable_var}).

Remaining steps (see plugins/README.md for details):
  1. Edit ${service_dir}/run: fill in the preconditions and the exec line.
  2. Add an entry to rootfs/etc/rabbit-plugins/registry.json.
  3. If the plugin needs a binary/package baked into the image, add an
     install step to the Dockerfile (see how frpc is fetched for a template)
     and chmod +x the new run script in the Dockerfile's chmod list.
  4. Add ${enable_var} (and any other new env vars) to the Dockerfile's ENV
     block and to cmd/env-manager/main.go's definitions if it should be
     toggleable from the Plugins panel.
  5. Document ${enable_var} in README.md, and add a matching
     'git grep -q -- ${enable_var} -- README.md' line to tests/repository.sh.
  6. Add lifecycle coverage to tests/smoke.sh (model it on the frpc/Tailscale
     enable-disable scenarios).
EOF
