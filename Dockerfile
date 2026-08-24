# check=skip=SecretsUsedInArgOrEnv

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

FROM debian:13-slim AS base

ARG DEBIAN_MIRROR=mirrors.ustc.edu.cn
ARG S6_OVERLAY_VERSION=v3.2.3.0
ARG CODE_SERVER_VERSION=4.127.0
ARG TAILSCALE_VERSION=1.98.8
ARG FRPC_VERSION=0.71.0
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    GITHUB_USER=rabbit-dayi \
    UV_LINK_MODE=symlink \
    UV_COMPILE_BYTECODE=1 \
    UV_CACHE_DIR=/root/.rabbit-dev-container/uv \
    NPM_CONFIG_CACHE=/root/.rabbit-dev-container/npm \
    RCLONE_CONFIG=/root/.rabbit_container/rclone/rclone.conf \
    RCLONE_CACHE_DIR=/root/.rabbit-dev-container/rclone \
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
    CONTAINER_CONFIG_DIR=/root/.rabbit_container \
    CONTAINER_DATA_DIR=/opt/.rabbit_container \
    CONTAINER_STATE_DIR=/root/.rabbit-dev-container \
    TS_ENABLE=false \
    TS_STATE_DIR=/root/.rabbit-dev-container/tailscale \
    TS_AUTH_ONCE=true \
    TS_ACCEPT_DNS=false \
    TS_CONFIG_TIMEOUT=30 \
    DOCKERD_ROOTLESS_ENABLE=false \
    DOCKER_HOST=unix:///run/user/1000/docker.sock \
    DOCKERD_CONFIG_DIR=/opt/.rabbit_container/dockerd/config \
    DOCKERD_CACHE_DIR=/opt/.rabbit_container/dockerd/cache \
    STARTUP_BANNER=true \
    STARTUP_SELF_CHECK=true \
    STARTUP_CHECK_TIMEOUT=20 \
    RESOLV_WEB_ENABLE=true \
    RESOLV_WEB_ALLOW_UNAUTHENTICATED=false \
    RESOLV_WEB_PORT=8787 \
    MANAGER_ENABLE=true \
    MANAGER_PORT=8788 \
    MANAGER_CONFIG_DIR=/root/.rabbit_container \
    RESOLV_STATE_FILE=/root/.rabbit_container/resolver.json \
    DOCKERD_DATA_ROOT=/opt/.rabbit_container/docker \
    STATUS_INTERVAL=5 \
    ENV_MANAGER_ENABLE=true \
    ENV_MANAGER_BIND_ADDR=127.0.0.1:8789 \
    ENV_MANAGER_CONFIG_DIR=/root/.rabbit_container \
    ENV_MANAGER_USERNAME=admin \
    ENV_MANAGER_TLS_ENABLE=false \
    ENV_MANAGER_ALLOW_UNAUTHENTICATED=false \
    PLUGIN_FRPC_ENABLE=false \
    PLUGIN_CLOAKBROWSER_ENABLE=false \
    PLUGIN_CLOAKBROWSER_PORT=18180

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY --from=ghcr.io/astral-sh/uv:0.11.28 /uv /usr/local/bin/uv

RUN set -eux; \
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
      sed -i \
        -e "s|security.debian.org/debian-security|${DEBIAN_MIRROR}/debian-security|g" \
        -e "s|deb.debian.org/debian-security|${DEBIAN_MIRROR}/debian-security|g" \
        -e "s|deb.debian.org|${DEBIAN_MIRROR}|g" \
        /etc/apt/sources.list.d/debian.sources; \
    else \
      sed -i \
        -e "s|security.debian.org/debian-security|${DEBIAN_MIRROR}/debian-security|g" \
        -e "s|deb.debian.org/debian-security|${DEBIAN_MIRROR}/debian-security|g" \
        -e "s|deb.debian.org|${DEBIAN_MIRROR}|g" \
        /etc/apt/sources.list; \
    fi; \
    apt-get update; \
    apt-get -y upgrade; \
    apt-get install -y --no-install-recommends \
      openssh-server git curl wget aria2 vim ca-certificates tzdata tmux xz-utils \
      inetutils-ping iproute2 net-tools traceroute procps \
      bubblewrap bash-completion build-essential pkg-config cmake ninja-build meson \
      gdb strace ltrace valgrind shellcheck jq less file unzip zip rsync socat lsof \
      htop btop iotop iftop sysstat nethogs psmisc tree ncdu dnsutils mtr-tiny \
      tcpdump nmap netcat-openbsd whois ripgrep fd-find bat git-lfs \
      python3 python3-pip python3-venv python3-dev gawk gettext man-db \
      libssl-dev libffi-dev libsqlite3-dev zlib1g-dev libbz2-dev libreadline-dev \
      liblzma-dev screen zsh fish fzf entr parallel direnv sqlite3 uuid-runtime \
      lftp iperf3 ethtool iputils-tracepath bridge-utils libarchive-tools zstd \
      pigz rename python3-yaml python3-requests nodejs npm fuse3 fuse-overlayfs sshfs \
      rclone davfs2 \
      slirp4netns uidmap nginx-light openssl; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL --retry 3 --retry-all-errors \
      https://download.docker.com/linux/debian/gpg \
      -o /etc/apt/keyrings/docker.asc; \
    chmod a+r /etc/apt/keyrings/docker.asc; \
    . /etc/os-release; \
    printf '%s\n' \
      'Types: deb' \
      'URIs: https://mirrors.ustc.edu.cn/docker-ce/linux/debian' \
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
    target_arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "${target_arch}" in \
      amd64) s6_arch="x86_64"; code_arch="amd64"; code_sha256="a1cb96f64d5c68736764726cd3b0c9b6e500bdc30cfefebc05f59259149380e2"; \
        frpc_arch="amd64"; frpc_sha256="84f27e39f11169f7adcef8e8b70c9329de17747b1f14dad9fb95eef5682ea716" ;; \
      arm64) s6_arch="aarch64"; code_arch="arm64"; code_sha256="e705774c0680e1feb573d38da3b838dde1466573f8621ce4b2414fcf3e64a01f"; \
        frpc_arch="arm64"; frpc_sha256="f33c293c275d8fc68c654b6fba8f10b2551d6463d09a9fc9cffb7227eae82266" ;; \
      *) echo "Unsupported target architecture: ${target_arch}" >&2; exit 1 ;; \
    esac; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
      docker-ce-rootless-extras "tailscale=${TAILSCALE_VERSION}" cloudflared; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd --gid 1000 dockerd; \
    useradd --uid 1000 --gid dockerd --home-dir /run/user/1000/home \
      --no-create-home --shell /usr/sbin/nologin dockerd; \
    printf '%s\n' 'dockerd:100000:65536' >> /etc/subuid; \
    printf '%s\n' 'dockerd:100000:65536' >> /etc/subgid; \
    ln -fs /usr/share/zoneinfo/${TZ} /etc/localtime; \
    dpkg-reconfigure -f noninteractive tzdata; \
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
    curl -fsSLo /tmp/frpc.tar.gz --retry 3 --retry-all-errors \
      "https://github.com/fatedier/frp/releases/download/v${FRPC_VERSION}/frp_${FRPC_VERSION}_linux_${frpc_arch}.tar.gz"; \
    echo "${frpc_sha256}  /tmp/frpc.tar.gz" | sha256sum -c -; \
    tar -C /tmp -xzf /tmp/frpc.tar.gz "frp_${FRPC_VERSION}_linux_${frpc_arch}/frpc"; \
    install -m 0755 "/tmp/frp_${FRPC_VERSION}_linux_${frpc_arch}/frpc" /usr/local/bin/frpc; \
    rm -rf /tmp/frpc.tar.gz "/tmp/frp_${FRPC_VERSION}_linux_${frpc_arch}"; \
    mkdir -p /run/sshd /run/tailscale /run/user /run/env-manager; \
    install -d -m 0755 /etc/nginx/certs; \
    install -d -m 0700 -o dockerd -g dockerd /run/user/1000; \
    true

RUN set -eux; \
    printf '%s\n' \
      'Acquire::Retries "3";' \
      'Acquire::https::Timeout "30";' \
      'Acquire::http::Timeout "30";' \
      > /etc/apt/apt.conf.d/80-rabbit-network; \
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
      sed -i "s|http://${DEBIAN_MIRROR}|https://${DEBIAN_MIRROR}|g" \
        /etc/apt/sources.list.d/debian.sources; \
    else \
      sed -i "s|http://${DEBIAN_MIRROR}|https://${DEBIAN_MIRROR}|g" \
        /etc/apt/sources.list; \
    fi

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
      /usr/local/bin/startup-self-check \
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
      /etc/s6-overlay/s6-rc.d/tailscaled/run \
      /etc/s6-overlay/s6-rc.d/plugin-frpc/run \
      /etc/s6-overlay/s6-rc.d/plugin-cloakbrowser/run; \
    printf '\n# Rabbit interactive terminal defaults\n[ -r /etc/rabbit-terminal.bash ] && . /etc/rabbit-terminal.bash\n' \
      >> /etc/bash.bashrc; \
    install -d -m 0700 /root/.ssh; \
    ssh-keygen -q -t rsa -b 4096 -N '' -f /root/.ssh/ssh_host_rsa_key; \
    ssh-keygen -q -t ecdsa -b 521 -N '' -f /root/.ssh/ssh_host_ecdsa_key; \
    ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/ssh_host_ed25519_key; \
    /usr/sbin/sshd -t; \
    rm -f /root/.ssh/ssh_host_rsa_key /root/.ssh/ssh_host_rsa_key.pub \
      /root/.ssh/ssh_host_ecdsa_key /root/.ssh/ssh_host_ecdsa_key.pub \
      /root/.ssh/ssh_host_ed25519_key /root/.ssh/ssh_host_ed25519_key.pub; \
    rmdir /root/.ssh; \
    /usr/sbin/nginx -t

WORKDIR /workspace

EXPOSE 22 80 443

ENTRYPOINT ["/init"]

FROM base AS cuda

ARG TARGETARCH
ARG CUDA_VERSION=13-3

ENV PATH=/usr/local/cuda/bin:${PATH} \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64

RUN set -eux; \
    target_arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "${target_arch}" in \
      amd64) cuda_arch="x86_64" ;; \
      arm64) cuda_arch="sbsa" ;; \
      *) echo "Unsupported CUDA target architecture: ${target_arch}" >&2; exit 1 ;; \
    esac; \
    curl -fsSLo /tmp/cuda-keyring.deb --retry 3 --retry-all-errors \
      "https://developer.download.nvidia.com/compute/cuda/repos/debian13/${cuda_arch}/cuda-keyring_1.1-1_all.deb"; \
    dpkg -i /tmp/cuda-keyring.deb; \
    rm -f /tmp/cuda-keyring.deb; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      "cuda-compiler-${CUDA_VERSION}" \
      "cuda-gdb-${CUDA_VERSION}" \
      "cuda-libraries-dev-${CUDA_VERSION}"; \
    rm -rf /var/lib/apt/lists/*; \
    test -x /usr/local/cuda/bin/nvcc; \
    test -x /usr/local/cuda/bin/cuda-gdb

RUN set -eux; \
    printf '%s\n' \
      'case ":${PATH}:" in' \
      '  *:/usr/local/cuda/bin:*) ;;' \
      '  *) PATH="/usr/local/cuda/bin:${PATH}" ;;' \
      'esac' \
      'case ":${LD_LIBRARY_PATH:-}:" in' \
      '  *:/usr/local/cuda/lib64:*) ;;' \
      '  *) LD_LIBRARY_PATH="/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" ;;' \
      'esac' \
      'export PATH LD_LIBRARY_PATH' \
      > /etc/profile.d/cuda.sh

FROM base AS standard
