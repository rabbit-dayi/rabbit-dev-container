# Plugins

A plugin is an optional, opt-in add-on service built into the image at build
time and toggled at runtime by a `PLUGIN_<NAME>_ENABLE` environment variable
-- the same convention already used for Tailscale (`TS_ENABLE`) and rootless
Docker-in-Docker (`DOCKERD_ROOTLESS_ENABLE`). There is no runtime
install-arbitrary-code mechanism: adding a plugin means adding a few files to
this repo and rebuilding the image, which keeps every plugin auditable and
gives it the same s6 supervision (auto-restart, clean shutdown, no crash
loops) as every other service.

This directory holds the plugin-authoring convention and a copyable
template. It is not shipped into the built image -- `rootfs/` is.

## Anatomy of a plugin

| Piece | Location |
| --- | --- |
| s6 service | `rootfs/etc/s6-overlay/s6-rc.d/plugin-<id>/{run,type,dependencies.d/}` |
| Boot registration | `rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/plugin-<id>` (empty marker file) |
| Registry entry | `rootfs/etc/rabbit-plugins/registry.json` |
| Panel toggle (optional) | a `PLUGIN_<ID>_ENABLE` entry in `cmd/env-manager/main.go`'s `definitions` |
| Docs | a paragraph in `README.md` + a doc-sync line in `tests/repository.sh` |
| Tests | a lifecycle scenario in `tests/smoke.sh` |

`scripts/new-plugin.sh <plugin-id>` generates the first two rows from
`plugins/TEMPLATE/`. The rest are manual because they're plugin-specific.

## Conventions

- **Enable var**: `PLUGIN_<ID>_ENABLE` (uppercase, underscores), default
  `false`. Read it via `${PLUGIN_X_ENABLE:-false} != "true"` at the top of
  the `run` script, matching every other optional service.
- **Never exit non-zero from `run`.** If the plugin is disabled, a
  precondition is missing (a required config file, another service's socket,
  a credential), or anything else means it shouldn't start yet: log one line
  explaining what's missing and `exec sleep infinity`. s6 treats a non-zero
  exit as a crash and restart-loops it; `sleep infinity` is how every
  optional service here stays idle instead.
- **Run the real process in the foreground with `exec`.** Don't
  daemonize/background it (no `docker run -d`, no `&`). s6 supervises
  whatever `run` execs and restarts it on unexpected exit -- that's the
  auto-restart behavior you get for free, the same way tailscaled and
  dockerd-rootless get it.
- **Source `load-managed-env` first.** That's what makes a plugin's enable
  var respond to the env-manager panel (`/env/`) without a full container
  restart -- see `rootfs/usr/local/bin/load-managed-env`.
- **Config lives under `/root/.rabbit_container/plugins/<id>/`.** `/root` is
  the one directory this image guarantees persists across restarts (see the
  top-level README). If your plugin needs user-supplied config (an API key,
  a TOML file), read it from there and idle with a clear message if it's
  missing, rather than inventing defaults for something that can't be
  defaulted safely.
- **A web UI is just another nginx service link.** If the plugin exposes an
  HTTP UI/API, set `web_path` (must start with `/plugins/`) and `web_port` in
  its registry entry; `configure-nginx` and `update-status` pick it up
  automatically -- proxied under `web_path`, listed in `/services/`, and
  probed for its status. Leave both `null` for a plugin with no UI (see
  `frpc`, which only makes outbound connections).
- **`registry.json` is the one place that ties a plugin's pieces together.**
  `configure-nginx`, `update-status`, and `docker-image-banner` all read it
  generically -- adding a plugin there is what makes it show up in the
  portal, in `/status.json`, and in the boot banner's plugin count, without
  editing any of those three scripts.

## registry.json fields

```jsonc
{
  "id": "frpc",                 // matches the plugin-<id> service name
  "name": "frpc",                // display name; must match the nginx
                                  // service-name pattern (letters, digits,
                                  // ._- , no spaces) if it has a web UI
  "description": "...",          // shown in the Plugins panel
  "enable_env": "PLUGIN_FRPC_ENABLE",
  "service": "plugin-frpc",      // the s6-rc.d directory name
  "requires": [],                // other s6 service names this depends on,
                                  // for display only (e.g. ["dockerd-rootless"])
  "config_path": "/root/.rabbit_container/plugins/frpc/frpc.toml", // or null
  "process_name": "frpc",        // for `pgrep -x` status, or null if it has
                                  // a web_path instead (that's a better signal)
  "web_path": null,              // "/plugins/<id>" or null
  "web_port": null,              // upstream port on 127.0.0.1, or null
  "docs_url": "https://github.com/fatedier/frp"
}
```

## Worked examples

- **`frpc`** (`rootfs/etc/s6-overlay/s6-rc.d/plugin-frpc/`): no web UI, no
  other service dependency. Waits for a user-supplied `frpc.toml`, then
  `exec frpc -c <path>`. The binary is fetched in the `Dockerfile` the same
  way `code-server`/`tailscale` are (pinned version, sha256-checked).
- **`cloakbrowser`** (`rootfs/etc/s6-overlay/s6-rc.d/plugin-cloakbrowser/`):
  has a web UI and depends on `dockerd-rootless`. Waits for the rootless
  Docker socket, then `exec docker run --rm ...` the vendor's own published
  image in the foreground -- s6 supervises the `docker run` process itself,
  so a crashed container gets restarted the same as a crashed binary would.
  This is the pattern to follow for wrapping any third-party container as a
  plugin instead of installing it into the image directly.

## Adding a plugin, end to end

1. `scripts/new-plugin.sh <id>` to scaffold the s6 service.
2. Fill in the generated `run` script's TODOs.
3. Add a `registry.json` entry.
4. If it needs a binary baked into the image, add a download step to the
   `Dockerfile` (see the `frpc` block) and add the new `run` script to the
   Dockerfile's `chmod +x` list.
5. If it should be toggleable from the `/env/` panel (not just via
   `docker run -e`), add its `PLUGIN_<ID>_ENABLE` (and any other settings) to
   `cmd/env-manager/main.go`'s `definitions`, with `Reload: "plugin"` and
   `Service: "plugin-<id>"`.
6. Document the new env var(s) in the top-level `README.md`, and add a
   `git grep -q -- 'PLUGIN_<ID>_ENABLE' -- README.md` line to
   `tests/repository.sh` so the docs can't drift out of sync.
7. Add a lifecycle scenario to `tests/smoke.sh`: start the image with the
   plugin disabled and assert it stays idle (no crash loop), then with it
   enabled and assert the expected process/route appears. Use a fake binary
   on `PATH` (see how the `cloudflared` and `frpc` smoke tests do it) instead
   of depending on the real upstream service if the plugin talks to the
   network.
