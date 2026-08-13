#!/usr/bin/env bash
set -Eeuo pipefail

trap 'rc=$?; printf "Smoke test failed at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2; exit "$rc"' ERR

image="${1:?usage: tests/smoke.sh IMAGE [standard|cuda]}"
variant="${2:-standard}"
case "$variant" in
    standard) expect_cuda=false ;;
    cuda) expect_cuda=true ;;
    *)
        echo "Unsupported image variant: $variant" >&2
        exit 2
        ;;
esac
container="rabbit-dev-container-smoke-${RANDOM}"
tls_container="${container}-tls"
hostkey_container="${container}-hostkeys"
persistence_container="${container}-persistence"
mount_container="${container}-mounts"
tmpdir="$(mktemp -d)"
cleanup() {
    docker rm -f "$container" >/dev/null 2>&1 || true
    docker rm -f "$tls_container" >/dev/null 2>&1 || true
    docker rm -f "$hostkey_container" >/dev/null 2>&1 || true
    docker rm -f "$persistence_container" >/dev/null 2>&1 || true
    docker rm -f "$mount_container" >/dev/null 2>&1 || true
    if command -v sudo >/dev/null 2>&1; then
        sudo rm -rf -- "$tmpdir"
    else
        rm -rf -- "$tmpdir"
    fi
}
trap cleanup EXIT

assert_config() {
    local pattern=$1
    grep -qE "$pattern" "$tmpdir/sshd-config" || {
        echo "Missing sshd setting: $pattern" >&2
        exit 1
    }
}

docker run --rm -i --entrypoint /bin/bash -e EXPECT_CUDA="$expect_cuda" "$image" -se <<'IMAGE_SMOKE'
    set -e
    trap 'rc=$?; printf "Image smoke failed at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2; exit "$rc"' ERR
    command -v /init sshd code-server uv tailscale tailscaled cloudflared nginx openssl \
        /usr/local/bin/docker-image-banner \
        /usr/local/bin/configure-resolv /usr/local/bin/resolver-web.js \
        /usr/local/bin/dev /usr/local/bin/update-status \
        /usr/local/bin/docker-image-manager /usr/local/bin/docker-image-env-manager \
        docker dockerd dockerd-rootless.sh newuidmap newgidmap \
        slirp4netns fuse-overlayfs ldd \
        htop jq lsof ncdu tree dig mtr tcpdump rsync socat pstree strace aria2c \
        sshfs fusermount3 rclone mount.davfs node npm npx \
        bwrap btop iotop iftop sar nethogs killall \
        pip3 rg fdfind batcat cmake ninja meson gcc gdb ltrace valgrind shellcheck \
        git-lfs gawk gettext man screen zsh fish fzf entr parallel direnv sqlite3 \
        uuidgen lftp iperf3 ethtool tracepath brctl bsdtar zstd pigz rename >/dev/null
    test -x /usr/bin/true
    if [ "$EXPECT_CUDA" = true ]; then
        command -v nvcc cuda-gdb >/dev/null
        nvcc --version | grep -q 'Cuda compilation tools'
        bash -lc 'command -v nvcc cuda-gdb >/dev/null'
    else
        ! command -v nvcc >/dev/null
        ! test -e /etc/profile.d/cuda.sh
    fi
    command -v docker-rootlesskit >/dev/null || command -v rootlesskit >/dev/null
    getent passwd dockerd | grep "^dockerd:x:1000:1000:" >/dev/null
    grep -qx "dockerd:100000:65536" /etc/subuid
    grep -qx "dockerd:100000:65536" /etc/subgid
    docker buildx version >/dev/null
    docker compose version >/dev/null
    test "$PWD" = /workspace
    ! test -e /usr/share/root_backup.tar.gz
    bash -n /etc/s6-overlay/scripts/init-root \
        /etc/s6-overlay/scripts/configure-nginx \
        /etc/s6-overlay/scripts/configure-tailscale \
        /etc/rabbit-terminal.bash \
        /etc/profile.d/rabbit-terminal.sh \
        /usr/local/bin/configure-resolv \
        /usr/local/bin/docker-image-banner \
        /usr/local/bin/startup-self-check \
        /usr/local/bin/dev /usr/local/bin/update-status \
        /etc/s6-overlay/s6-rc.d/runtime-status/run \
        /etc/s6-overlay/s6-rc.d/code-server/run \
        /etc/s6-overlay/s6-rc.d/dockerd-rootless/run \
        /etc/s6-overlay/s6-rc.d/manager/run \
        /etc/s6-overlay/s6-rc.d/nginx/run \
        /etc/s6-overlay/s6-rc.d/resolver-web/run \
        /etc/s6-overlay/s6-rc.d/tailscaled/run
    node --check /usr/local/bin/resolver-web.js
    bash --noprofile --norc -ic '
        source /etc/rabbit-terminal.bash
        alias ll | grep -F "ls -alF" >/dev/null
        alias gs | grep -F "git status --short --branch" >/dev/null
        alias bat | grep -F batcat >/dev/null
        [[ "$PS1" == *rabbit* ]]
    ' >/dev/null 2>&1
    test "${CONTAINER_CONFIG_DIR}" = /root/.rabbit_container
    test "${CONTAINER_DATA_DIR}" = /opt/.rabbit_container
    test "${CONTAINER_STATE_DIR}" = /root/.rabbit-dev-container
    test "${CODE_SERVER_USER_DATA_DIR}" = /root/.rabbit-dev-container/code-server
    test "${RESOLV_STATE_FILE}" = /root/.rabbit_container/resolver.json
    test "${TS_STATE_DIR}" = /root/.rabbit-dev-container/tailscale
    test "${ENV_MANAGER_BIND_ADDR}" = 127.0.0.1:8789
    test "${ENV_MANAGER_CONFIG_DIR}" = /root/.rabbit_container
    test "${DOCKERD_DATA_ROOT}" = /opt/.rabbit_container/docker
    test "${DOCKERD_CONFIG_DIR}" = /opt/.rabbit_container/dockerd/config
    test "${DOCKERD_CACHE_DIR}" = /opt/.rabbit_container/dockerd/cache
    test "${NPM_CONFIG_CACHE}" = /root/.rabbit-dev-container/npm
    test "${UV_CACHE_DIR}" = /root/.rabbit-dev-container/uv
    test "${RCLONE_CONFIG}" = /root/.rabbit_container/rclone/rclone.conf
    test "${RCLONE_CACHE_DIR}" = /root/.rabbit-dev-container/rclone
    test "${MANAGER_CONFIG_DIR}" = /root/.rabbit_container
    grep -Fq -- "--user-data-dir \"\$user_data_dir\"" /etc/s6-overlay/s6-rc.d/code-server/run
    grep -Fq '/root/.rabbit_container/resolver.json' /usr/local/bin/configure-resolv
    grep -Fq '/root/.rabbit-dev-container/tailscale' /etc/s6-overlay/s6-rc.d/tailscaled/run
    grep -Fq "data_dir=\"\${DOCKERD_DATA_ROOT:-\${data_root}/docker}\"" \
        /etc/s6-overlay/s6-rc.d/dockerd-rootless/run
    grep -Fq -- "--data-root=\"\$data_dir\"" \
        /etc/s6-overlay/s6-rc.d/dockerd-rootless/run
    resolv_test_file="$(mktemp)"
    printf 'nameserver 9.9.9.9\n' >"$resolv_test_file"
    resolv_before="$(sha256sum "$resolv_test_file")"
    RESOLV_CONFIG_FILE="$resolv_test_file" RESOLV_AUTO_CONFIG=false \
        /usr/local/bin/configure-resolv >/dev/null
    [ "$resolv_before" = "$(sha256sum "$resolv_test_file")" ]
    rm -f "$resolv_test_file"
    resolv_test_dir="$(mktemp -d)"
    resolv_test_file="$resolv_test_dir/resolv.conf"
    printf "search internal.example\nnameserver 9.9.9.9\n" >"$resolv_test_file"
    printf "#!/bin/sh\necho \\;\\; SERVER:\n" >"$resolv_test_dir/dig"
    chmod 755 "$resolv_test_dir/dig"
    PATH="$resolv_test_dir:$PATH" \
        RESOLV_CONFIG_FILE="$resolv_test_file" \
        /usr/local/bin/configure-resolv >/dev/null
    grep -q "^nameserver 127.0.0.1$" "$resolv_test_file"
    grep -q "^nameserver 1.1.1.1$" "$resolv_test_file"
    [ "$(grep -c "^nameserver 9.9.9.9$" "$resolv_test_file")" = 1 ]
    [ "$(stat -c "%a" "$resolv_test_file")" = 644 ]
    rm -rf "$resolv_test_dir"
    banner="$(NGINX_SERVER_NAMES=code.example.test \
        NGINX_SERVICE_LINKS="Echo|/echo|127.0.0.1:8080" \
        RESOLV_WEB_PASSWORD=smoke-secret \
        /usr/local/bin/docker-image-banner)"
    grep -Fq 'RABBIT DEV CONTAINER' <<<"$banner"
    grep -Fq 'https://code.example.test:443/services/' <<<"$banner"
    grep -Fq 'https://code.example.test:443/dns/' <<<"$banner"
    /usr/local/bin/docker-image-banner | grep -F 'DNS       disabled' >/dev/null
    [ -z "$(STARTUP_BANNER=false /usr/local/bin/docker-image-banner)" ]
    /usr/local/bin/dev help | grep -F 'status' >/dev/null
    NGINX_SERVER_NAMES=code.example.test \
        NGINX_SERVICE_LINKS="Echo|/echo|127.0.0.1:8080" \
        /etc/s6-overlay/scripts/configure-nginx
    ! grep -Fq "location = /dns/" /run/nginx/nginx.conf
    ! grep -Fq "location ^~ /dns/api/" /run/nginx/nginx.conf
    NGINX_SERVER_NAMES=code.example.test \
        RESOLV_WEB_ALLOW_UNAUTHENTICATED=true \
        /etc/s6-overlay/scripts/configure-nginx
    grep -Fq "location = /dns/" /run/nginx/nginx.conf
    ! grep -Fq "auth_basic_user_file" /run/nginx/nginx.conf
    NGINX_SERVER_NAMES=code.example.test \
        NGINX_SERVICE_LINKS="Echo|/echo|127.0.0.1:8080" \
        RESOLV_WEB_PASSWORD=smoke-secret \
        /etc/s6-overlay/scripts/configure-nginx
    nginx -t -q -c /run/nginx/nginx.conf
    openssl x509 -in /run/nginx/default-certificate/tls.crt -noout -ext subjectAltName \
        | grep "DNS:code.example.test" >/dev/null
    grep -Fq "location ^~ /echo/" /run/nginx/nginx.conf
    grep -Fq "proxy_pass http://127.0.0.1:8080/;" /run/nginx/nginx.conf
    grep -Fq "location = / {" /run/nginx/nginx.conf
    grep -Fq "try_files /services/index.html =404;" /run/nginx/nginx.conf
    grep -Fq "location ^~ /workspace/" /run/nginx/nginx.conf
    grep -Fq "href=\"/workspace/\"" /run/nginx/services/index.html
    grep -Fq "href=\"/echo/\"" /run/nginx/services/index.html
    grep -Fq "href=\"/status/\"" /run/nginx/services/index.html
    grep -Fq "location = /status/" /run/nginx/nginx.conf
    grep -Fq status.json /run/nginx/status/index.html
    grep -Fq "location = /dns/" /run/nginx/nginx.conf
    grep -Fq "location ^~ /dns/api/" /run/nginx/nginx.conf
    grep -Fq "proxy_read_timeout 20s" /run/nginx/nginx.conf
    grep -Fq "auth_basic_user_file /run/nginx/resolver.htpasswd;" /run/nginx/nginx.conf
    test "$(stat -c "%a %U %G" /run/nginx/resolver.htpasswd)" = "640 root www-data"
    test -s /run/nginx/dns/index.html
    test -s /run/nginx/status/status.json
    PASSWORD=smoke-secret \
        NGINX_SERVER_NAMES=code.example.test \
        NGINX_SERVICE_LINKS="Echo|/echo|127.0.0.1:8080" \
        /etc/s6-overlay/scripts/configure-nginx
    nginx -t -q -c /run/nginx/nginx.conf
    grep -Fq "auth_basic \"Rabbit Dev Container\";" /run/nginx/nginx.conf
    grep -Fq "auth_basic_user_file /run/nginx/gateway.htpasswd;" /run/nginx/nginx.conf
    grep -Fq "location = /healthz" /run/nginx/nginx.conf
    grep -Fq "location ^~ /manage/api/" /run/nginx/nginx.conf
    grep -Fq "proxy_set_header Host \$http_host;" /run/nginx/nginx.conf
    grep -Fq "auth_basic off;" /run/nginx/nginx.conf
    ! test -e /run/nginx/resolver.htpasswd
    test "$(stat -c "%a %U %G" /run/nginx/gateway.htpasswd)" = "640 root www-data"
    STATUS_ONCE=true \
        NGINX_SERVICE_LINKS="Echo|/echo|127.0.0.1:8080" \
        /usr/local/bin/update-status
    jq -e ".services | length == 2" \
        /run/nginx/status/status.json >/dev/null
    jq -e '.fuse_mounts == 0 and .sshfs_mounts == 0' \
        /run/nginx/status/status.json >/dev/null
    /usr/local/bin/dev routes | grep -F 'Echo' >/dev/null
    /usr/local/bin/dev versions | grep -F 'rclone:' >/dev/null

    tunnel_test_dir="$(mktemp -d)"
    printf "%s\n" \
        "#!/bin/bash" \
        "trap \"exit 0\" TERM INT" \
        "printf \"https://smoke-test.trycloudflare.com\\n\" >&2" \
        "while :; do sleep 1; done" \
        >"$tunnel_test_dir/cloudflared"
    chmod 755 "$tunnel_test_dir/cloudflared"
    CLOUDFLARED_BIN="$tunnel_test_dir/cloudflared" \
        RESOLV_WEB_PORT=18787 \
        RESOLV_STATE_FILE="$tunnel_test_dir/resolver.json" \
        node /usr/local/bin/resolver-web.js >"$tunnel_test_dir/first.log" 2>&1 &
    resolver_pid=$!
    for _ in $(seq 1 30); do
        curl -fsS http://127.0.0.1:18787/api/tunnel >/dev/null 2>&1 && break
        sleep 0.1
    done
    tunnel_result="$(curl -fsS -X POST \
        -H "Content-Type: application/json" \
        --data "{\"target\":\"127.0.0.1:8080\"}" \
        http://127.0.0.1:18787/api/tunnel/start)"
    tunnel_pid="$(printf "%s\n" "$tunnel_result" | jq -r .pid)"
    kill -0 "$tunnel_pid"
    kill -KILL "$resolver_pid"
    wait "$resolver_pid" 2>/dev/null || true
    kill -0 "$tunnel_pid"
    CLOUDFLARED_BIN="$tunnel_test_dir/cloudflared" \
        RESOLV_WEB_PORT=18787 \
        RESOLV_STATE_FILE="$tunnel_test_dir/resolver.json" \
        node /usr/local/bin/resolver-web.js >"$tunnel_test_dir/second.log" 2>&1 &
    resolver_pid=$!
    for _ in $(seq 1 60); do
        if curl -fsS http://127.0.0.1:18787/api/tunnel 2>/dev/null \
            | jq -e ".running == false" >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done
    curl -fsS http://127.0.0.1:18787/api/tunnel | jq -e ".running == false" >/dev/null
    ! kill -0 "$tunnel_pid" 2>/dev/null
    kill -TERM "$resolver_pid"
    wait "$resolver_pid"
    rm -rf "$tunnel_test_dir"

    NGINX_HTTP_PORT=8081 NGINX_HTTPS_PORT=8443 \
        /etc/s6-overlay/scripts/configure-nginx
    nginx -t -q -c /run/nginx/nginx.conf
    grep -Fq "return 308 https://\$host:8443\$request_uri;" /run/nginx/nginx.conf
    NGINX_HTTP_PORT=8081 NGINX_HTTPS_PORT=8443 NGINX_HTTP_REDIRECT=false \
        /etc/s6-overlay/scripts/configure-nginx
    nginx -t -q -c /run/nginx/nginx.conf
    grep -Fq "proxy_set_header X-Forwarded-Proto http;" /run/nginx/nginx.conf
    if NGINX_SERVER_NAMES="bad;name" /etc/s6-overlay/scripts/configure-nginx >/dev/null 2>&1; then
        echo "Invalid NGINX_SERVER_NAMES was accepted" >&2
        exit 1
    fi
    if NGINX_SERVICE_LINKS="bad|/services|127.0.0.1:8080" \
        /etc/s6-overlay/scripts/configure-nginx >/dev/null 2>&1; then
        echo "Reserved NGINX_SERVICE_LINKS path was accepted" >&2
        exit 1
    fi
    if NGINX_SERVICE_LINKS="bad|/status|127.0.0.1:8080" \
        /etc/s6-overlay/scripts/configure-nginx >/dev/null 2>&1; then
        echo "Reserved status path was accepted" >&2
        exit 1
    fi
    if NGINX_SERVICE_LINKS="bad|/status.json|127.0.0.1:8080" \
        /etc/s6-overlay/scripts/configure-nginx >/dev/null 2>&1; then
        echo "Reserved status JSON path was accepted" >&2
        exit 1
    fi
    if NGINX_SERVICE_LINKS="bad|/dns|127.0.0.1:8080" \
        /etc/s6-overlay/scripts/configure-nginx >/dev/null 2>&1; then
        echo "Reserved DNS path was accepted" >&2
        exit 1
    fi
    GITHUB_USER= /etc/s6-overlay/scripts/init-root >/dev/null
    sshd -t
IMAGE_SMOKE
docker run --rm --entrypoint /bin/bash \
    -e GITHUB_USER= \
    "$image" -c '/etc/s6-overlay/scripts/init-root >/dev/null; exec /usr/sbin/sshd -T' \
    >"$tmpdir/sshd-config"
assert_config '^clientaliveinterval 60$'
assert_config '^clientalivecountmax 3$'
assert_config '^tcpkeepalive yes$'
assert_config '^passwordauthentication no$'
assert_config '^pubkeyauthentication yes$'
assert_config '^permitrootlogin (without-password|prohibit-password)$'
assert_config '^authorizedkeysfile /root/.ssh/authorized_keys /run/sshd/authorized_keys$'
assert_config '^hostkey /root/.ssh/ssh_host_rsa_key$'
assert_config '^hostkey /root/.ssh/ssh_host_ecdsa_key$'
assert_config '^hostkey /root/.ssh/ssh_host_ed25519_key$'

for persistent_path in root workspace opt home; do
    mkdir -p "$tmpdir/persistent/$persistent_path"
    printf '%s\n' "preserve-$persistent_path" >"$tmpdir/persistent/$persistent_path/marker"
done
docker run -d \
    --name "$persistence_container" \
    -e GITHUB_USER= \
    -e CODE_SERVER_AUTH=none \
    -v "$tmpdir/persistent/root:/root" \
    -v "$tmpdir/persistent/workspace:/workspace" \
    -v "$tmpdir/persistent/opt:/opt" \
    -v "$tmpdir/persistent/home:/home" \
    "$image" >/dev/null
for _ in {1..30}; do
    if docker logs "$persistence_container" 2>&1 | grep -F 'Initialization done.' >/dev/null; then
        break
    fi
    sleep 1
done
docker logs "$persistence_container" 2>&1 | grep -F 'Initialization done.' >/dev/null
for _ in {1..30}; do
    if docker logs "$persistence_container" 2>&1 \
        | grep -F '[startup-check] Summary:' >/dev/null; then
        break
    fi
    sleep 1
done
docker logs "$persistence_container" 2>&1 | grep -F '[startup-check] Summary:' >/dev/null
for persistent_path in root workspace opt home; do
    grep -Fxq "preserve-$persistent_path" "$tmpdir/persistent/$persistent_path/marker"
done
docker exec "$persistence_container" test -s /root/.ssh/ssh_host_ed25519_key
docker exec "$persistence_container" test -d /root/.rabbit_container/rclone
docker exec "$persistence_container" test -d /root/.rabbit-dev-container/rclone
docker rm -f "$persistence_container" >/dev/null

ssh-keygen -q -t ed25519 -N '' -f "$tmpdir/id_ed25519"
cp "$tmpdir/id_ed25519.pub" "$tmpdir/authorized_keys"
chmod 444 "$tmpdir/authorized_keys"
# GitHub-hosted runners bind-mount files as the runner user, not root.
chown 1001:1001 "$tmpdir/authorized_keys"
original_keys="$(sha256sum "$tmpdir/authorized_keys")"
ssh_state_dir="$tmpdir/root-state"
mkdir -p "$ssh_state_dir/.ssh"
cp "$tmpdir/authorized_keys" "$ssh_state_dir/.ssh/authorized_keys"
chmod 700 "$ssh_state_dir/.ssh"
chmod 600 "$ssh_state_dir/.ssh/authorized_keys"

docker run -d \
    --name "$container" \
    -e GITHUB_USER= \
    -e PASSWORD=smoke-secret \
    -e NGINX_SERVER_NAMES=smoke.example.test \
    -e NGINX_SERVICE_LINKS='Echo|/echo|127.0.0.1:8080;Environment|/env|127.0.0.1:8789' \
    -e TS_ENABLE=false \
    -p 127.0.0.1::22 \
    -p 127.0.0.1::80 \
    -p 127.0.0.1::443 \
    -v "$tmpdir/authorized_keys:/root/.ssh/authorized_keys:ro" \
    "$image" >/dev/null

ssh_port="$(docker port "$container" 22/tcp | sed 's/.*://')"
http_port="$(docker port "$container" 80/tcp | sed 's/.*://')"
https_port="$(docker port "$container" 443/tcp | sed 's/.*://')"
for _ in {1..30}; do
    if ssh -i "$tmpdir/id_ed25519" -p "$ssh_port" \
        -o BatchMode=yes -o ConnectTimeout=2 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        root@127.0.0.1 true 2>/dev/null; then
        break
    fi
    sleep 1
done
ssh -i "$tmpdir/id_ed25519" -p "$ssh_port" \
    -o BatchMode=yes -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    root@127.0.0.1 'test "$(ps -p 1 -o comm=)" = s6-svscan'

ssh -tt -i "$tmpdir/id_ed25519" -p "$ssh_port" \
    -o BatchMode=yes -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    root@127.0.0.1 2>&1 <<<"exit" | grep -F 'RABBIT DEV CONTAINER' >/dev/null

for _ in {1..30}; do
    if docker logs "$container" 2>&1 | grep -F 'RABBIT DEV CONTAINER' >/dev/null; then
        break
    fi
    sleep 1
done
docker logs "$container" 2>&1 | grep -F 'RABBIT DEV CONTAINER' >/dev/null

for _ in {1..30}; do
    curl --noproxy '*' -fkS \
        --resolve "smoke.example.test:${https_port}:127.0.0.1" \
        "https://smoke.example.test:${https_port}/healthz" >/dev/null 2>&1 && break
    sleep 1
done
curl --noproxy '*' -fkS \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/healthz" >/dev/null
portal_page="$(curl --noproxy '*' -fkS \
    -u admin:smoke-secret \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/services/")"
grep -Fq 'href="/echo/"' <<<"$portal_page"
grep -Fq 'href="/env/"' <<<"$portal_page"
grep -Fq 'href="/workspace/"' <<<"$portal_page"
curl --noproxy '*' -fkS \
    -u admin:smoke-secret \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/echo/healthz" >/dev/null
redirect_headers="$(curl --noproxy '*' -skSI \
    --resolve "smoke.example.test:${http_port}:127.0.0.1" \
    "http://smoke.example.test:${http_port}/healthz" | tr -d '\r')"
grep -qE '^HTTP/.* 308' <<<"$redirect_headers"
grep -qi '^location: https://smoke.example.test/healthz$' <<<"$redirect_headers"
root_page="$(curl --noproxy '*' -fkS -u admin:smoke-secret \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/")"
grep -Fq 'Internal services' <<<"$root_page"
grep -Fq 'href="/workspace/"' <<<"$root_page"
workspace_redirect="$(curl --noproxy '*' -skSI \
    -u admin:smoke-secret \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/workspace/" | tr -d '\r')"
grep -qE '^HTTP/.* 302' <<<"$workspace_redirect"
grep -Fqi 'location: ./?folder=/workspace' <<<"$workspace_redirect"
workspace_page=''
for _ in {1..30}; do
    workspace_page="$(curl --noproxy '*' -fkS \
        -u admin:smoke-secret \
        --resolve "smoke.example.test:${https_port}:127.0.0.1" \
        "https://smoke.example.test:${https_port}/workspace/?folder=/workspace")"
    if grep -Fq 'vscode-workbench-web-configuration' <<<"$workspace_page"; then
        break
    fi
    sleep 1
done
grep -Fq 'vscode-workbench-web-configuration' <<<"$workspace_page"
env_page="$(curl --noproxy '*' -fkS \
    -u admin:smoke-secret \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/env/")"
grep -Fq 'id="config-form"' <<<"$env_page"
env_config="$(curl --noproxy '*' -fkS \
    -u admin:smoke-secret \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/env/api/config")"
printf '%s\n' "$env_config" | jq -e '.settings | map(select(.name == "PASSWORD" and .value_set == true and .masked_value == "********")) | length == 1' >/dev/null
env_update="$(curl --noproxy '*' -fkS -X PUT \
    -u admin:smoke-secret \
    -H 'Content-Type: application/json' \
    -H 'X-Requested-With: docker-image-env-manager' \
    --data '{"values":{"CODE_SERVER_WORKDIR":"/workspace/smoke"}}' \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/env/api/config")"
printf '%s\n' "$env_update" | jq -e '.reloads | map(select(.service == "code-server" and .status == "reloaded")) | length == 1' >/dev/null
docker exec "$container" bash -c 'source /usr/local/bin/load-managed-env; test "$CODE_SERVER_WORKDIR" = /workspace/smoke'
docker exec "$container" test -s /root/.rabbit_container/env-manager.env
[ "$original_keys" = "$(sha256sum "$tmpdir/authorized_keys")" ]

docker run -d \
    --name "$hostkey_container" \
    -e GITHUB_USER= \
    -e CODE_SERVER_AUTH=none \
    -p 127.0.0.1::22 \
    -v "$ssh_state_dir:/root" \
    "$image" >/dev/null
hostkey_ssh_port="$(docker port "$hostkey_container" 22/tcp | sed 's/.*://')"
for _ in {1..30}; do
    if ssh -i "$tmpdir/id_ed25519" -p "$hostkey_ssh_port" \
        -o BatchMode=yes -o ConnectTimeout=2 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        root@127.0.0.1 true 2>/dev/null; then
        break
    fi
    sleep 1
done
ssh -i "$tmpdir/id_ed25519" -p "$hostkey_ssh_port" \
    -o BatchMode=yes -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    root@127.0.0.1 true
docker exec "$hostkey_container" test -s /root/.ssh/ssh_host_rsa_key
docker exec "$hostkey_container" test -s /root/.ssh/ssh_host_ecdsa_key
docker exec "$hostkey_container" test -s /root/.ssh/ssh_host_ed25519_key
hostkey_fingerprint="$(docker exec "$hostkey_container" \
    ssh-keygen -lf /root/.ssh/ssh_host_ed25519_key | awk '{print $2}')"
docker rm -f "$hostkey_container" >/dev/null
docker run -d \
    --name "$hostkey_container" \
    -e GITHUB_USER= \
    -e CODE_SERVER_AUTH=none \
    -v "$ssh_state_dir:/root" \
    "$image" >/dev/null
for _ in {1..30}; do
    if docker exec "$hostkey_container" test -s /root/.ssh/ssh_host_ed25519_key \
        && docker logs "$hostkey_container" 2>&1 | grep -F 'Initialization done.' >/dev/null; then
        break
    fi
    sleep 1
done
docker logs "$hostkey_container" 2>&1 | grep -F 'Initialization done.' >/dev/null
[ "$hostkey_fingerprint" = "$(docker exec "$hostkey_container" \
    ssh-keygen -lf /root/.ssh/ssh_host_ed25519_key | awk '{print $2}')" ]
docker rm -f "$hostkey_container" >/dev/null
status_page="$(curl --noproxy '*' -fkS \
    -u admin:smoke-secret \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/status/")"
grep -Fq 'id="components"' <<<"$status_page"
grep -Fq 'href="/workspace/"' <<<"$status_page"
status_json="$(curl --noproxy '*' -fkS \
    -u admin:smoke-secret \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/status.json")"
printf '%s\n' "$status_json" | jq -e '.services | map(select(.name == "Echo")) | length == 1' >/dev/null
printf '%s\n' "$status_json" | jq -e '.components.code_server == "up"' >/dev/null
root_unauthenticated_status="$(curl --noproxy '*' -skS -o /dev/null -w '%{http_code}' \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/")"
[ "$root_unauthenticated_status" = 401 ]
for _ in {1..30}; do
    if curl --noproxy '*' -fkS -u admin:smoke-secret \
        --resolve "smoke.example.test:${https_port}:127.0.0.1" \
        "https://smoke.example.test:${https_port}/" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
curl --noproxy '*' -fkS \
    -u admin:smoke-secret \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/" >/dev/null
dns_unauthenticated_status="$(curl --noproxy '*' -skS -o /dev/null -w '%{http_code}' \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/dns/api/resolver")"
[ "$dns_unauthenticated_status" = 401 ]
dns_page="$(curl --noproxy '*' -fkS \
    -u admin:smoke-secret \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/dns/")"
grep -Fq 'id="resolver-form"' <<<"$dns_page"
grep -Fq 'https://try.cloudflare.com/' <<<"$dns_page"
grep -Fq 'id="tunnel-start"' <<<"$dns_page"
dns_json="$(curl --noproxy '*' -fkS \
    -u admin:smoke-secret \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/dns/api/resolver")"
printf '%s\n' "$dns_json" | jq -e '.config.local_nameserver == "127.0.0.1"' >/dev/null
tunnel_json="$(curl --noproxy '*' -fkS \
    -u admin:smoke-secret \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/dns/api/tunnel")"
printf '%s\n' "$tunnel_json" | jq -e '.running == false and .default_target == "http://127.0.0.1:8080"' >/dev/null
tunnel_invalid="$(curl --noproxy '*' -skS -X POST \
    -u admin:smoke-secret \
    -H 'Content-Type: application/json' \
    --data '{"target":"file:///etc/passwd"}' \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/dns/api/tunnel/start")"
printf '%s\n' "$tunnel_invalid" | jq -e '.error | contains("HTTP(S)")' >/dev/null
dns_apply="$(curl --noproxy '*' -fkS -X POST \
    -u admin:smoke-secret \
    -H 'Content-Type: application/json' \
    --data '{"auto_config":false,"local_nameserver":"127.0.0.1","fallback_nameserver":"1.1.1.1","fallback_always":false,"check_domain":"example.com"}' \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/dns/api/resolver/apply")"
printf '%s\n' "$dns_apply" | jq -e '.applied == true' >/dev/null
docker exec "$container" jq -e '.auto_config == false' /root/.rabbit_container/resolver.json >/dev/null
manager_page="$(curl --noproxy '*' -fkS \
    -u admin:smoke-secret \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/manage/")"
grep -Fq 'id="upload-form"' <<<"$manager_page"
certificate_json="$(curl --noproxy '*' -fkS \
    -u admin:smoke-secret \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/manage/api/certificate")"
printf '%s\n' "$certificate_json" | jq -e '.source == "generated" and .upload_enabled == true' >/dev/null
openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 30 \
    -keyout "$tmpdir/uploaded.key" \
    -out "$tmpdir/uploaded.crt" \
    -subj '/CN=uploaded.example.test' \
    -addext 'subjectAltName=DNS:uploaded.example.test' >/dev/null 2>&1
uploaded_json="$(curl --noproxy '*' -fkS -X POST \
    -u admin:smoke-secret \
    -H 'X-Requested-With: docker-image-manager' \
    -H "Origin: https://smoke.example.test:${https_port}" \
    -F certificate=@"$tmpdir/uploaded.crt" \
    -F private_key=@"$tmpdir/uploaded.key" \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/manage/api/certificate")"
printf '%s\n' "$uploaded_json" | jq -e '.source == "uploaded" and (.names | index("uploaded.example.test")) != null' >/dev/null
docker exec "$container" test -L /root/.rabbit_container/tls/current
docker exec "$container" test -f /root/.rabbit_container/tls/current/tls.crt
docker exec "$container" dev status | grep -F 'components:' >/dev/null
docker exec "$container" dev routes | grep -F 'Echo' >/dev/null
docker exec "$container" pgrep -x sshd >/dev/null
docker exec "$container" pgrep -f code-server >/dev/null
for _ in {1..30}; do
    if docker exec "$container" pgrep -af code-server 2>/dev/null \
        | grep -F -- '--auth none' >/dev/null; then
        break
    fi
    sleep 1
done
docker exec "$container" pgrep -af code-server | grep -F -- '--auth none' >/dev/null
docker exec "$container" pgrep -af code-server \
    | grep -F -- '--user-data-dir /root/.rabbit-dev-container/code-server' >/dev/null
docker exec "$container" pgrep -x nginx >/dev/null
docker exec "$container" openssl x509 \
    -in /root/.rabbit_container/tls/current/tls.crt -noout -subject \
    | grep -F 'uploaded.example.test' >/dev/null
! docker exec "$container" pgrep -x dockerd >/dev/null
[ "$(docker inspect -f '{{.RestartCount}}' "$container")" = 0 ]

# A mounted certificate pair takes precedence over the generated default.
mkdir -p "$tmpdir/certs"
openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 1 \
    -keyout "$tmpdir/certs/tls.key" \
    -out "$tmpdir/certs/tls.crt" \
    -subj '/CN=custom.example.test' >/dev/null 2>&1
docker run -d \
    --name "$tls_container" \
    -e GITHUB_USER= \
    -e CODE_SERVER_AUTH=none \
    -e NGINX_SERVER_NAMES=custom.example.test \
    -p 127.0.0.1::443 \
    -v "$tmpdir/certs:/etc/nginx/certs:ro" \
    "$image" >/dev/null
custom_https_port="$(docker port "$tls_container" 443/tcp | sed 's/.*://')"
for _ in {1..30}; do
    curl --noproxy '*' -fkS \
        --resolve "custom.example.test:${custom_https_port}:127.0.0.1" \
        "https://custom.example.test:${custom_https_port}/healthz" >/dev/null 2>&1 && break
    sleep 1
done
curl --noproxy '*' -fkS \
    --resolve "custom.example.test:${custom_https_port}:127.0.0.1" \
    "https://custom.example.test:${custom_https_port}/healthz" >/dev/null
printf '\n' | openssl s_client \
    -connect "127.0.0.1:${custom_https_port}" \
    -servername custom.example.test 2>/dev/null \
    | openssl x509 -noout -subject \
    | grep -F 'custom.example.test' >/dev/null
docker rm -f "$tls_container" >/dev/null

# Tailscale is optional: enabling it without a TUN device must not take down SSH/code-server.
docker rm -f "$container" >/dev/null
docker run -d \
    --name "$container" \
    -e GITHUB_USER= \
    -e CODE_SERVER_AUTH=none \
    -e TS_ENABLE=true \
    "$image" >/dev/null
sleep 3
docker exec "$container" pgrep -x sshd >/dev/null
docker exec "$container" pgrep -f code-server >/dev/null
docker logs "$container" 2>&1 | grep '/dev/net/tun is unavailable' >/dev/null
[ "$(docker inspect -f '{{.State.Running}}' "$container")" = true ]

# When the runner exposes TUN, also exercise the enabled daemon path without
# joining a tailnet. This verifies the state directory and LocalAPI socket.
if [ -c /dev/net/tun ]; then
    docker rm -f "$container" >/dev/null
    docker run -d \
        --name "$container" \
        --device /dev/net/tun:/dev/net/tun \
        --cap-add NET_ADMIN \
        --cap-add NET_RAW \
        -e GITHUB_USER= \
        -e CODE_SERVER_AUTH=none \
        -e TS_ENABLE=true \
        "$image" >/dev/null
    for _ in {1..30}; do
        if docker exec "$container" test -S /run/tailscale/tailscaled.sock \
            && docker exec "$container" tailscale \
                --socket=/run/tailscale/tailscaled.sock status --json >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    docker exec "$container" test -S /run/tailscale/tailscaled.sock
    docker exec "$container" tailscale \
        --socket=/run/tailscale/tailscaled.sock status --json >/dev/null
    docker exec "$container" pgrep -x tailscaled >/dev/null
    docker exec "$container" pgrep -x sshd >/dev/null
    docker exec "$container" pgrep -f code-server >/dev/null
fi

# Exercise real SSHFS and rclone/WebDAV FUSE mounts when the Docker host makes
# /dev/fuse available. GitHub-hosted runners commonly omit it, while local and
# self-hosted runners can cover the full mount lifecycle.
fuse_capable=1
if ! docker run --rm --privileged --entrypoint /bin/bash "$image" -c 'test -c /dev/fuse && test -r /dev/fuse && test -w /dev/fuse'; then
    fuse_capable=0
    echo "Skipping FUSE mount integration: runner does not expose /dev/fuse." >&2
fi

if [ "$fuse_capable" -eq 1 ]; then
    docker run --rm --name "$mount_container" --privileged -i \
        --entrypoint /bin/bash "$image" -se <<'FUSE_MOUNT_SMOKE'
set -Eeuo pipefail

workdir="$(mktemp -d)"
cleanup_mounts() {
    fusermount3 -u "$workdir/sshfs-mount" >/dev/null 2>&1 || true
    fusermount3 -u "$workdir/rclone-mount" >/dev/null 2>&1 || true
    if mountpoint -q "$workdir/davfs-mount"; then
        umount "$workdir/davfs-mount" >/dev/null 2>&1 || true
    fi
    [ -n "${webdav_pid:-}" ] && kill "$webdav_pid" >/dev/null 2>&1 || true
    [ -n "${sshd_pid:-}" ] && kill "$sshd_pid" >/dev/null 2>&1 || true
    rm -rf "$workdir"
}
trap cleanup_mounts EXIT

mkdir -p "$workdir"/{ssh-source,sshfs-mount,webdav-source,rclone-mount,davfs-mount,cache,sshd}
printf '%s\n' 'sshfs-read-ok' >"$workdir/ssh-source/remote.txt"
ssh-keygen -q -t ed25519 -N '' -f "$workdir/client-key"
ssh-keygen -q -t ed25519 -N '' -f "$workdir/host-key"
cp "$workdir/client-key.pub" "$workdir/authorized_keys"
chmod 600 "$workdir/client-key" "$workdir/authorized_keys"
cat >"$workdir/sshd_config" <<EOF
Port 2222
ListenAddress 127.0.0.1
PidFile $workdir/sshd.pid
HostKey $workdir/host-key
AuthorizedKeysFile $workdir/authorized_keys
StrictModes no
PermitRootLogin prohibit-password
PasswordAuthentication no
UsePAM no
Subsystem sftp internal-sftp
EOF
/usr/sbin/sshd -D -e -f "$workdir/sshd_config" >"$workdir/sshd.log" 2>&1 &
sshd_pid=$!
for _ in {1..50}; do
    ssh -i "$workdir/client-key" -p 2222 -o BatchMode=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        root@127.0.0.1 true >/dev/null 2>&1 && break
    sleep 0.1
done
sshfs -p 2222 \
    -o IdentityFile="$workdir/client-key" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@127.0.0.1:$workdir/ssh-source" "$workdir/sshfs-mount"
grep -Fxq 'sshfs-read-ok' "$workdir/sshfs-mount/remote.txt"
printf '%s\n' 'sshfs-write-ok' >"$workdir/sshfs-mount/write.txt"
grep -Fxq 'sshfs-write-ok' "$workdir/ssh-source/write.txt"
awk -v path="$workdir/sshfs-mount" '$2 == path && $3 == "fuse.sshfs" {found=1} END {exit !found}' /proc/mounts
fusermount3 -u "$workdir/sshfs-mount"

printf '%s\n' 'webdav-read-ok' >"$workdir/webdav-source/remote.txt"
rclone serve webdav "$workdir/webdav-source" --addr 127.0.0.1:18443 \
    --log-file "$workdir/webdav.log" --log-level INFO &
webdav_pid=$!
for _ in {1..50}; do
    curl -fsS http://127.0.0.1:18443/ >/dev/null 2>&1 && break
    sleep 0.1
done
cat >"$workdir/rclone.conf" <<EOF
[webdav-smoke]
type = webdav
url = http://127.0.0.1:18443/
vendor = other
EOF
rclone --config "$workdir/rclone.conf" --cache-dir "$workdir/cache" \
    mount webdav-smoke: "$workdir/rclone-mount" --daemon --vfs-cache-mode writes
for _ in {1..50}; do
    [ -r "$workdir/rclone-mount/remote.txt" ] && break
    sleep 0.1
done
grep -Fxq 'webdav-read-ok' "$workdir/rclone-mount/remote.txt"
printf '%s\n' 'webdav-write-ok' >"$workdir/rclone-mount/write.txt"
for _ in {1..50}; do
    grep -Fxq 'webdav-write-ok' "$workdir/webdav-source/write.txt" 2>/dev/null && break
    sleep 0.1
done
grep -Fxq 'webdav-write-ok' "$workdir/webdav-source/write.txt"
awk -v path="$workdir/rclone-mount" '$2 == path && $3 == "fuse.rclone" {found=1} END {exit !found}' /proc/mounts
fusermount3 -u "$workdir/rclone-mount"

kill "$webdav_pid"
wait "$webdav_pid" 2>/dev/null || true
rclone serve webdav "$workdir/webdav-source" --addr 127.0.0.1:18443 \
    --user rabbit --pass mount-secret \
    --log-file "$workdir/davfs-webdav.log" --log-level INFO &
webdav_pid=$!
for _ in {1..50}; do
    curl -fsS -u rabbit:mount-secret http://127.0.0.1:18443/ >/dev/null 2>&1 && break
    sleep 0.1
done
printf '%s %s %s\n' \
    'http://127.0.0.1:18443/' rabbit mount-secret >>/etc/davfs2/secrets
chmod 600 /etc/davfs2/secrets
mount -t davfs http://127.0.0.1:18443/ "$workdir/davfs-mount" -o rw
grep -Fxq 'webdav-read-ok' "$workdir/davfs-mount/remote.txt"
printf '%s\n' 'davfs-write-ok' >"$workdir/davfs-mount/davfs-write.txt"
grep -Fxq 'davfs-write-ok' "$workdir/davfs-mount/davfs-write.txt"
umount "$workdir/davfs-mount"
grep -Fxq 'davfs-write-ok' "$workdir/webdav-source/davfs-write.txt"
FUSE_MOUNT_SMOKE
fi

# Rootless Docker needs the outer container's relaxed security profile and a
# runner that exposes FUSE plus unprivileged user namespaces. Keep the rest of
# the smoke test useful on hosted runners that intentionally restrict either.
rootless_capable=1
if ! docker run --rm --privileged --entrypoint /bin/bash "$image" -c '
    set -e
    test -c /dev/fuse
    /command/s6-setuidgid dockerd /usr/bin/unshare --user --map-root-user true >/dev/null 2>&1
'; then
    rootless_capable=0
    echo "Skipping rootless Docker integration: runner lacks /dev/fuse or unprivileged user namespaces." >&2
fi

if [ "$rootless_capable" -eq 1 ]; then
    docker rm -f "$container" >/dev/null
    docker run -d \
        --name "$container" \
        --privileged \
        -e GITHUB_USER= \
        -e CODE_SERVER_AUTH=none \
        -e DOCKERD_ROOTLESS_ENABLE=true \
        "$image" >/dev/null
    rootless_ready=0
    for _ in {1..60}; do
        if docker exec "$container" docker info --format '{{json .SecurityOptions}}' 2>/dev/null \
            | grep rootless >/dev/null; then
            rootless_ready=1
            break
        fi
        sleep 1
    done
    if [ "$rootless_ready" -ne 1 ]; then
        docker logs "$container" >&2
        exit 1
    fi
    docker exec "$container" test -S /run/user/1000/docker.sock
    docker exec "$container" docker info --format '{{json .SecurityOptions}}' \
        | grep rootless >/dev/null
    docker exec "$container" bash -c 'test "$(ps -C dockerd -o user= | tr -d " ")" = dockerd'
    docker exec -i "$container" /bin/bash -se <<'INNER_DOCKER_SMOKE'
set -o pipefail
context="$(mktemp -d)"
trap 'rm -rf "$context"' EXIT

mkdir -p "$context/rootfs"
cp --parents /usr/bin/true "$context/rootfs"
ldd /usr/bin/true \
    | sed -nE \
        -e 's/^[[:space:]]*(\/[^[:space:]]+).*/\1/p' \
        -e 's/.*=>[[:space:]]*(\/[^[:space:]]+).*/\1/p' \
    | sort -u \
    | while IFS= read -r library; do
    cp --parents "$library" "$context/rootfs"
done

docker build --quiet -t rootless-dind-smoke -f - "$context" <<'DOCKERFILE'
FROM scratch
COPY rootfs/ /
ENTRYPOINT ["/usr/bin/true"]
DOCKERFILE
docker run --rm rootless-dind-smoke
INNER_DOCKER_SMOKE
    docker exec "$container" pgrep -x sshd >/dev/null
    docker exec "$container" pgrep -f code-server >/dev/null
fi

echo "Smoke tests passed for $image"
