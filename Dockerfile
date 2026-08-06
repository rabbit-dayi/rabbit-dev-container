FROM golang:1.26.5-bookworm AS manager-builder

WORKDIR /src
COPY go.mod ./
COPY cmd/manager/ ./cmd/manager/
COPY cmd/env-manager/ ./cmd/env-manager/
RUN go test ./... && \
    CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' \
      -o /out/docker-image-manager ./cmd/manager && \
    CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' \
      -o /out/docker-image-env-manager ./cmd/env-manager

FROM debian:13-slim

ARG DEBIAN_MIRROR=deb.debian.org
ARG S6_OVERLAY_VERSION=v3.2.3.0
ARG CODE_SERVER_VERSION=4.127.0
ARG TAILSCALE_VERSION=1.98.8
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    GITHUB_USER=rabbit-dayi \
    UV_LINK_MODE=symlink \
    UV_COMPILE_BYTECODE=1 \
    UV_CACHE_DIR=/root/.rabbit-dev-container/uv \
    NPM_CONFIG_CACHE=/root/.rabbit-dev-container/npm \
    S6_KEEP_ENV=1 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    CODE_SERVER_BIND_ADDR=127.0.0.1:8080 \
    CODE_SERVER_WORKDIR=/workspace \
    CODE_SERVER_USER_DATA_DIR=/root/.rabbit-dev-container/code-server \
    NGINX_ENABLE=true \
    NGINX_HTTP_PORT=80 \
    NGINX_HTTPS_PORT=443 \
    NGINX_HTTP_REDIRECT=true \
    NGINX_UNIFIED_AUTH=true \
    NGINX_SERVER_NAMES=_ \
    NGINX_UPSTREAM=127.0.0.1:8080 \
    NGINX_SERVICE_LINKS=Environment|/env|127.0.0.1:8789 \
    CONTAINER_STATE_DIR=/root/.rabbit-dev-container \
    TS_ENABLE=false \
    TS_STATE_DIR=/root/.rabbit-dev-container/tailscale \
    TS_AUTH_ONCE=true \
    TS_ACCEPT_DNS=false \
    TS_CONFIG_TIMEOUT=30 \
    DOCKERD_ROOTLESS_ENABLE=false \
    DOCKER_HOST=unix:///run/user/1000/docker.sock \
    DOCKERD_CONFIG_DIR=/root/.rabbit-dev-container/dockerd/config \
    DOCKERD_CACHE_DIR=/root/.rabbit-dev-container/dockerd/cache \
    STARTUP_BANNER=true \
    RESOLV_WEB_ENABLE=true \
    RESOLV_WEB_ALLOW_UNAUTHENTICATED=false \
    RESOLV_WEB_PORT=8787 \
    MANAGER_ENABLE=true \
    MANAGER_PORT=8788 \
    MANAGER_CONFIG_DIR=/root/.rabbit-dev-container \
    RESOLV_STATE_FILE=/root/.rabbit-dev-container/resolver.json \
    DOCKERD_DATA_ROOT=/root/.rabbit-dev-container/docker \
    STATUS_INTERVAL=5 \
    ENV_MANAGER_ENABLE=true \
    ENV_MANAGER_BIND_ADDR=127.0.0.1:8789 \
    ENV_MANAGER_CONFIG_DIR=/root/.rabbit-dev-container \
    ENV_MANAGER_USERNAME=admin \
    ENV_MANAGER_TLS_ENABLE=false \
    ENV_MANAGER_ALLOW_UNAUTHENTICATED=false

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY --from=ghcr.io/astral-sh/uv:0.11.28 /uv /usr/local/bin/uv

RUN set -eux; \
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
      sed -i "s|deb.debian.org|${DEBIAN_MIRROR}|g" /etc/apt/sources.list.d/debian.sources; \
      sed -i "s|security.debian.org|${DEBIAN_MIRROR}/debian-security|g" /etc/apt/sources.list.d/debian.sources; \
    else \
      sed -i "s|deb.debian.org|${DEBIAN_MIRROR}|g" /etc/apt/sources.list; \
      sed -i "s|security.debian.org|${DEBIAN_MIRROR}/debian-security|g" /etc/apt/sources.list; \
    fi; \
    apt-get update; \
    apt-get -y upgrade; \
    apt-get install -y --no-install-recommends \
      openssh-server git curl wget vim ca-certificates tzdata tmux xz-utils \
      inetutils-ping iproute2 net-tools traceroute procps \
      bubblewrap bash-completion build-essential pkg-config cmake ninja-build meson \
      gdb strace ltrace valgrind shellcheck jq less file unzip zip rsync socat lsof \
      htop btop iotop iftop sysstat nethogs psmisc tree ncdu dnsutils mtr-tiny \
      tcpdump nmap netcat-openbsd whois ripgrep fd-find bat git-lfs \
      python3 python3-pip python3-venv python3-dev gawk gettext man-db \
      libssl-dev libffi-dev libsqlite3-dev zlib1g-dev libbz2-dev libreadline-dev \
      liblzma-dev screen zsh fish fzf entr parallel direnv sqlite3 uuid-runtime \
      lftp iperf3 ethtool iputils-tracepath bridge-utils libarchive-tools zstd \
      pigz rename python3-yaml python3-requests nodejs npm fuse-overlayfs sshfs \
      slirp4netns uidmap nginx-light openssl; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL --retry 3 --retry-all-errors \
      https://download.docker.com/linux/debian/gpg \
      -o /etc/apt/keyrings/docker.asc; \
    chmod a+r /etc/apt/keyrings/docker.asc; \
    . /etc/os-release; \
    printf '%s\n' \
      'Types: deb' \
      'URIs: https://download.docker.com/linux/debian' \
      "Suites: ${VERSION_CODENAME}" \
      'Components: stable' \
      "Architectures: $(dpkg --print-architecture)" \
      'Signed-By: /etc/apt/keyrings/docker.asc' \
      > /etc/apt/sources.list.d/docker.sources; \
    curl -fsSL --retry 3 --retry-all-errors \
      https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
      -o /usr/share/keyrings/tailscale-archive-keyring.gpg; \
    curl -fsSL --retry 3 --retry-all-errors \
      https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list \
      -o /etc/apt/sources.list.d/tailscale.list; \
    curl -fsSL --retry 3 --retry-all-errors \
      https://pkg.cloudflare.com/cloudflare-main.gpg \
      -o /usr/share/keyrings/cloudflare-main.gpg; \
    printf '%s\n' \
      'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
      > /etc/apt/sources.list.d/cloudflared.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
      docker-ce-rootless-extras "tailscale=${TAILSCALE_VERSION}" cloudflared; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd --gid 1000 dockerd; \
    useradd --uid 1000 --gid dockerd --create-home --shell /usr/sbin/nologin dockerd; \
    printf '%s\n' 'dockerd:100000:65536' >> /etc/subuid; \
    printf '%s\n' 'dockerd:100000:65536' >> /etc/subgid; \
    ln -fs /usr/share/zoneinfo/${TZ} /etc/localtime; \
    dpkg-reconfigure -f noninteractive tzdata; \
    case "${TARGETARCH:-amd64}" in \
      amd64) s6_arch="x86_64"; code_arch="amd64"; code_sha256="a1cb96f64d5c68736764726cd3b0c9b6e500bdc30cfefebc05f59259149380e2" ;; \
      arm64) s6_arch="aarch64"; code_arch="arm64"; code_sha256="e705774c0680e1feb573d38da3b838dde1466573f8621ce4b2414fcf3e64a01f" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSLO --retry 3 --retry-all-errors \
      "https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz"; \
    curl -fsSLO --retry 3 --retry-all-errors \
      "https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz.sha256"; \
    curl -fsSLO --retry 3 --retry-all-errors \
      "https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-${s6_arch}.tar.xz"; \
    curl -fsSLO --retry 3 --retry-all-errors \
      "https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-${s6_arch}.tar.xz.sha256"; \
    sha256sum -c s6-overlay-noarch.tar.xz.sha256; \
    sha256sum -c "s6-overlay-${s6_arch}.tar.xz.sha256"; \
    tar -C / -Jxpf s6-overlay-noarch.tar.xz; \
    tar -C / -Jxpf "s6-overlay-${s6_arch}.tar.xz"; \
    rm -f s6-overlay-*.tar.xz s6-overlay-*.tar.xz.sha256; \
    curl -fsSLo /tmp/code-server.deb --retry 3 --retry-all-errors \
      "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server_${CODE_SERVER_VERSION}_${code_arch}.deb"; \
    echo "${code_sha256}  /tmp/code-server.deb" | sha256sum -c -; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/code-server.deb; \
    rm -f /tmp/code-server.deb; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /run/sshd /run/tailscale /run/user /run/env-manager /root/.ssh /workspace; \
    install -d -m 0755 /etc/nginx/certs; \
    install -d -m 0700 -o dockerd -g dockerd /run/user/1000; \
    touch /root/.ssh/authorized_keys; \
    chmod 700 /root/.ssh; \
    chmod 600 /root/.ssh/authorized_keys; \
    cp /etc/skel/.bashrc /root/.bashrc; \
    cp /etc/skel/.profile /root/.profile; \
    { \
        echo ""; \
        echo "# --- Docker Injected Env Vars ---"; \
        echo "export TZ=${TZ}"; \
        echo "export LANG=${LANG}"; \
        echo "export UV_LINK_MODE=${UV_LINK_MODE}"; \
        echo "export UV_COMPILE_BYTECODE=${UV_COMPILE_BYTECODE}"; \
        echo "export DOCKER_HOST=${DOCKER_HOST}"; \
        echo '# UV Auto Completion'; \
        echo 'eval "$(uv generate-shell-completion bash)"'; \
    } >> /root/.bashrc; \
    tar -czf /usr/share/root_backup.tar.gz -C / root

COPY rootfs/ /
COPY --from=manager-builder /out/docker-image-manager /usr/local/bin/docker-image-manager
COPY --from=manager-builder /out/docker-image-env-manager /usr/local/bin/docker-image-env-manager

RUN set -eux; \
    chmod 755 /etc /usr; \
    find /etc/s6-overlay /etc/ssh /usr/local -type d -exec chmod 755 {} +; \
    chmod +x \
      /etc/s6-overlay/scripts/init-root \
      /etc/s6-overlay/scripts/configure-nginx \
      /etc/s6-overlay/scripts/configure-tailscale \
      /etc/s6-overlay/s6-rc.d/runtime-status/run \
      /etc/s6-overlay/s6-rc.d/resolver-web/run \
      /etc/s6-overlay/s6-rc.d/manager/run \
      /etc/s6-overlay/s6-rc.d/env-manager/run \
      /usr/local/bin/docker-image-banner \
      /usr/local/bin/configure-resolv \
      /usr/local/bin/resolver-web.js \
      /usr/local/bin/dev \
      /usr/local/bin/update-status \
      /usr/local/bin/load-managed-env \
      /usr/local/bin/reload-tailscale \
      /etc/s6-overlay/s6-rc.d/sshd/run \
      /etc/s6-overlay/s6-rc.d/code-server/run \
      /etc/s6-overlay/s6-rc.d/dockerd-rootless/run \
      /etc/s6-overlay/s6-rc.d/nginx/run \
      /etc/s6-overlay/s6-rc.d/tailscaled/run; \
    /usr/sbin/sshd -t; \
    /usr/sbin/nginx -t

WORKDIR /workspace

EXPOSE 22 80 443

ENTRYPOINT ["/init"]
