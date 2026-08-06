# Rabbit Dev Container 🐇

一个面向远程开发的 Debian 13 Docker 镜像，支持 `linux/amd64` 和 `linux/arm64`。兔子标记代表可随时进入、随时维护的开发环境，内置：

- `s6-overlay`：作为容器内的 init / supervisor，启动和守护服务
- `OpenSSH Server`：使用公钥登录，并启用协议层 keepalive
- `code-server`：在浏览器中使用 VS Code
- `Nginx`：统一 HTTPS Web 入口，默认将 HTTP 重定向到 HTTPS，并提供运行状态、DNS 和证书管理页面
- `Tailscale`：可选的容器内 tailnet 接入服务
- `Docker CLI`、Buildx、Compose plugin，以及可选的 rootless Docker-in-Docker daemon
- `uv`：Python 包管理/运行工具
- 常用工具：`git`、`curl`、`wget`、`vim`、`tmux`、`ping`、`iproute2`、`net-tools`、`traceroute`、`procps`
- 开发与调试工具：`bubblewrap`、`build-essential`、`pkg-config`、`cmake`、`ninja`、`meson`、`gdb`、`strace`、`ltrace`、`valgrind`、`shellcheck`
- 网络与文件工具：`jq`、`rsync`、`socat`、`lsof`、`tree`、`ncdu`、`dnsutils`、`mtr`、`tcpdump`、`nmap`、`netcat`、`whois`、`ripgrep`、`fd`、`bat`、`git-lfs`、`lftp`、`iperf3`、`ethtool`、`tracepath`、`brctl`
- 终端监控与效率工具：`htop`、`btop`、`iotop`、`iftop`、`sysstat`、`nethogs`、`screen`、`zsh`、`fish`、`fzf`、`entr`、`parallel`、`direnv`
- 压缩与数据工具：`sqlite3`、`uuidgen`、`bsdtar`、`zstd`、`pigz`、`rename`、`python3-yaml`、`python3-requests`
- Python 与构建依赖：`python3`、`pip3`、`venv`、`python3-dev`、`gawk`、`gettext`、`man-db` 以及 OpenSSL、SQLite、zlib、bz2、readline、lzma 开发库

其中 Debian 的命令名分别是 `fdfind` 和 `batcat`，对应软件包为 `fd-find` 和 `bat`。
- `Node.js`、`npm`、`npx`：JavaScript/TypeScript 运行与包管理
- `SSHFS`：通过 SSH 挂载远程目录
- 常用工具：`git`、`curl`、`wget`、`vim`、`tmux`、`ping`、`iproute2`、`net-tools`、`traceroute`、`procps`，以及上面列出的完整开发工具集

镜像使用 `/init` 作为 PID 1。启动时会恢复空的 `/root` 配置、读取 `/root/.rabbit-dev-container` 下的持久化状态、更新 GitHub SSH 公钥、生成 SSH host keys 和默认 TLS 证书，然后由 s6-overlay 分别管理 `sshd`、`code-server`、`nginx`、DNS 管理页、可选的 `tailscaled` 和 rootless `dockerd`。

普通 SSH/code-server 模式不需要 `privileged`、systemd、`/sys/fs/cgroup` 或 Compose 的 `init: true`。启用 Tailscale 内核网络时才需要 `/dev/net/tun`、`NET_ADMIN` 和 `NET_RAW`；启用 rootless Docker-in-Docker 时需要外层容器使用 `--privileged`，具体原因和使用方式见下文。

## 基础维护工具

镜像预装以下无需额外服务的维护工具：

- 进程与文件：`htop`、`pstree`、`lsof`、`strace`
- 磁盘与目录：`ncdu`、`tree`
- DNS 与网络诊断：`dig`、`mtr`、`tcpdump`、`socat`
- 数据、同步与脚本：`jq`、`rsync`、`node`、`npm`、`npx`

`tcpdump` 抓包需要容器具备 `NET_RAW` 能力；受默认 seccomp 或 ptrace 限制的运行环境中，`strace` 可能需要额外授予调试权限。

### 启动横幅

容器启动时会输出一个带网关地址、SSH 入口、工作目录和可选服务状态的启动横幅。默认启用；不需要时设置：

```yaml
environment:
  STARTUP_BANNER: "false"
```

### `dev` 运维命令

镜像内置一个只读的统一运维入口，默认执行 `dev status`：

```bash
dev status      # 组件、工作区和 SSHFS 状态
dev mounts      # FUSE/SSHFS 挂载
dev versions    # 主要工具版本
```

### SSHFS 远程目录

镜像预装 `sshfs` 和 `fusermount3`。启动容器时需要把宿主机的 FUSE 设备和挂载能力传入容器：

```bash
docker run -d \
  --name rabbit-dev-container-sshfs \
  --device /dev/fuse \
  --cap-add SYS_ADMIN \
  -e GITHUB_USER=rabbit-dayi \
  -e PASSWORD='change-this-password' \
  -p 2222:22 \
  -p 80:80 \
  -p 443:443 \
  ghcr.io/rabbit-dayi/rabbit-dev-container:latest
```

进入容器后即可挂载远程目录，挂载点也能直接被 code-server 使用：

```bash
mkdir -p /workspace/remote
sshfs -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3 \
  user@example.com:/srv/data /workspace/remote
fusermount3 -u /workspace/remote
```

如果宿主机的 seccomp 或 AppArmor 策略仍阻止 FUSE 挂载，需要按宿主机安全策略额外放行；不要把 `--privileged` 作为 SSHFS 的默认参数。

### DNS 管理与检测

容器启动时会检查 `/etc/resolv.conf`，并探测 `RESOLV_LOCAL_NAMESERVER:53` 与 `RESOLV_FALLBACK_NAMESERVER:53` 是否真的响应。默认行为是：只有确认本地 DNS 响应时，才把它放到前面；如果备用 DNS 也可用，则一并补入。原有 `nameserver`、`search` 和 `options` 内容会保留。

普通 Docker 容器不会因为这个功能被强制改成公共 DNS：如果没有检测到本地 DNS，默认保留 Docker 注入的 DNS（通常是 `127.0.0.11`）。确实需要在本地 DNS 不响应时也尝试备用 DNS，可设置 `RESOLV_FALLBACK_ALWAYS=true`。对于 Docker 的文件挂载，脚本会在原子替换失败时尝试原地写入；符号链接、只读挂载或无法写入时，只记录提示并保留原文件。

当没有通过环境变量锁定 DNS 参数时，可访问 `https://<域名>/dns/` 打开 DNS 管理页，填写参数后执行“测试 DNS”或“保存并应用”。配置默认持久化到 `/root/.rabbit-dev-container/resolver.json`；挂载 `/root` 即可跨容器重建保留全部配置。设置 `RESOLV_AUTO_CONFIG`、`RESOLV_LOCAL_NAMESERVER`、`RESOLV_FALLBACK_NAMESERVER`、`RESOLV_FALLBACK_ALWAYS` 或 `RESOLV_CHECK_DOMAIN` 后，对应字段由环境变量控制，页面不会覆盖它们。

管理页优先使用 `RESOLV_WEB_PASSWORD` 生成 Nginx Basic Auth；未设置时使用已有的 `PASSWORD`。如果两者都没有，页面和 API 默认完全关闭。只在受信任网络内临时测试时，才应显式设置 `RESOLV_WEB_ALLOW_UNAUTHENTICATED=true` 跳过认证。

## 镜像地址

```text
ghcr.io/rabbit-dayi/rabbit-dev-container:latest
```

## 快速开始

### Docker

```bash
docker run -d \
  --name rabbit-dev-container \
  -e GITHUB_USER=rabbit-dayi \
  -e PASSWORD='change-this-password' \
  -e NGINX_SERVER_NAMES=code.example.com \
  -p 2222:22 \
  -p 80:80 \
  -p 443:443 \
  -v rabbit-dev-container-root:/root \
  -v rabbit-dev-container-workspace:/workspace \
  ghcr.io/rabbit-dayi/rabbit-dev-container:latest
```

### Docker Compose

```yaml
services:
  dev:
    image: ghcr.io/rabbit-dayi/rabbit-dev-container:latest
    environment:
      GITHUB_USER: rabbit-dayi
      PASSWORD: change-this-password
      NGINX_SERVER_NAMES: code.example.com
    ports:
      - "2222:22"
      - "80:80"
      - "443:443"
    volumes:
      - rabbit-dev-container-root:/root
      - rabbit-dev-container-workspace:/workspace
    restart: unless-stopped

volumes:
  rabbit-dev-container-root:
  rabbit-dev-container-workspace:
```

不要为此服务设置 `init: true`；s6-overlay 提供的 `/init` 必须保持 PID 1。

## Nginx HTTPS 统一入口

Nginx 默认启用，是容器 Web 服务的 HTTPS 入口：容器内 code-server 默认只绑定 `127.0.0.1:8080`，HTTP `80` 会以 `308` 重定向到 HTTPS `443`。浏览器可通过 HTTPS 访问 code-server；`/status/` 提供自动刷新的运行状态页，`/dns/` 提供 DNS 测试和持久化配置页，`/manage/` 和 `/env/` 提供管理功能。

SSH 仍独立使用 `22` 端口。正常部署只需映射 `22`、`80` 和 `443`，不要再映射 `8080`。

### 域名

将 DNS 的 A/AAAA 记录指向宿主机后，设置逗号分隔的域名列表：

```yaml
environment:
  NGINX_SERVER_NAMES: code.example.com,*.dev.example.com
ports:
  - "80:80"
  - "443:443"
```

`NGINX_SERVER_NAMES` 只接受精确域名和 `*.example.com` 形式的通配域名，避免把环境变量直接当作 Nginx 配置注入。未设置时为 `_`，可用于本地访问；默认自签名证书的名称是 `localhost`。

### 运行状态页

访问 `https://<域名>/status/` 可以查看 SSH、Nginx、code-server、rootless DIND、Tailscale 的状态，以及工作区占用和 SSHFS 挂载数量。页面每 5 秒刷新一次；对应的机器可读接口是 `/status.json`。状态服务只写入这些运行指标，不会暴露密码、auth key 或其他环境变量。

### 证书管理页

设置 `PASSWORD` 后访问 `https://<域名>/manage/`，可以查看当前证书的域名、签发者、有效期和指纹，并上传新的证书链和未加密私钥。上传后会在 `/root/.rabbit-dev-container/tls/versions/` 保存版本，原子切换 `current` 链接并热加载 Nginx；如果校验或热加载失败，会自动恢复上一版。通过 `NGINX_TLS_CERT_FILE`/`NGINX_TLS_KEY_FILE` 或 `/etc/nginx/certs` 提供的证书属于外部托管，只读展示，不允许页面覆盖。证书文件上传和管理接口默认只在统一 Nginx 登录后可见。

### TLS 证书

没有提供证书时，容器每次创建会自动生成一个有效期 10 年的自签名证书，放在临时目录 `/run/nginx/default-certificate/`。它让 HTTPS 开箱可用，但浏览器会显示不受信任警告，不应作为生产证书。

生产部署可只读挂载证书目录，Nginx 会优先使用其中的 `tls.crt` 和 `tls.key`：

```bash
docker run -d \
  --name rabbit-dev-container \
  -e GITHUB_USER=rabbit-dayi \
  -e PASSWORD='change-this-password' \
  -e NGINX_SERVER_NAMES=code.example.com \
  -p 80:80 \
  -p 443:443 \
  -v ./certs:/etc/nginx/certs:ro \
  -v rabbit-dev-container-root:/root \
  -v rabbit-dev-container-workspace:/workspace \
  ghcr.io/rabbit-dayi/rabbit-dev-container:latest
```

其中 `./certs/tls.crt` 应是完整证书链，`./certs/tls.key` 是未加密私钥。使用其他挂载路径或文件名时，同时设置 `NGINX_TLS_CERT_FILE` 与 `NGINX_TLS_KEY_FILE`。证书续期后重启容器即可加载新文件。

若要保留旧的直连方式，显式关闭 Nginx 并将 code-server 改回公开监听：

```bash
docker run -d \
  --name rabbit-dev-container-direct \
  -e GITHUB_USER=rabbit-dayi \
  -e PASSWORD='change-this-password' \
  -e NGINX_ENABLE=false \
  -e CODE_SERVER_BIND_ADDR=0.0.0.0:8080 \
  -p 8080:8080 \
  ghcr.io/rabbit-dayi/rabbit-dev-container:latest
```

## Rootless Docker-in-Docker

镜像始终内置 Docker CLI、Buildx 和 Compose plugin，但 rootless daemon 默认关闭。要在容器内构建、运行和管理独立的 Docker 容器，显式启用 `DOCKERD_ROOTLESS_ENABLE=true`：

```bash
docker run -d \
  --name rabbit-dev-container-dind \
  --privileged \
  -e GITHUB_USER=rabbit-dayi \
  -e PASSWORD='change-this-password' \
  -e DOCKERD_ROOTLESS_ENABLE=true \
  -p 2222:22 \
  -p 80:80 \
  -p 443:443 \
  -v rabbit-dev-container-root:/root \
  -v rabbit-dev-container-workspace:/workspace \
  ghcr.io/rabbit-dayi/rabbit-dev-container:latest
```

`dockerd` 以镜像内 UID 1000 的 `dockerd` 用户运行；root 的 SSH、终端和 code-server 已预设 `DOCKER_HOST=unix:///run/user/1000/docker.sock`，Docker 数据默认位于 `/root/.rabbit-dev-container/docker`，进入后可直接执行：

```bash
docker info
docker run --rm hello-world
docker buildx version
docker compose version
```

Docker API 默认不监听 TCP 端口，也不需要挂载宿主机的 `/var/run/docker.sock`。镜像中的 Docker 数据位于 `/root/.rabbit-dev-container/docker`，与其他应用状态统一放在 `/root/.rabbit-dev-container`。

Docker 官方的 rootless Docker-in-Docker 运行方式仍要求外层容器放开 seccomp、AppArmor 和 mount mask；本镜像使用文档推荐的 `--privileged` 方式。rootless 仅确保内层 `dockerd` 不以外层容器的 root 身份运行，不能抵消 `--privileged` 带来的外层容器风险。因此只应为受信任的开发或 CI 工作负载启用此模式。

### Docker Compose

```yaml
services:
  dev:
    image: ghcr.io/rabbit-dayi/rabbit-dev-container:latest
    privileged: true
    environment:
      GITHUB_USER: rabbit-dayi
      PASSWORD: change-this-password
      DOCKERD_ROOTLESS_ENABLE: "true"
    ports:
      - "2222:22"
      - "80:80"
      - "443:443"
    volumes:
      - rabbit-dev-container-root:/root
      - rabbit-dev-container-workspace:/workspace
    restart: unless-stopped

volumes:
  rabbit-dev-container-root:
  rabbit-dev-container-workspace:
```

启用前，宿主机必须允许非特权 user namespace；服务启动时还会检查 `/dev/fuse`。条件不满足时 rootless `dockerd` 会保持 idle，SSH 和 code-server 不受影响。rootless Docker 的已知限制仍然适用，例如默认不能发布低于 1024 的端口，且没有 systemd/cgroup v2 委派时部分容器级资源限制不会生效。

## 访问方式

### SSH

容器默认允许 root 使用公钥登录，禁用 SSH 密码登录：

```bash
ssh root@localhost -p 2222
```

服务端默认配置：

```text
ClientAliveInterval 60
ClientAliveCountMax 3
TCPKeepAlive yes
```

这会周期性发送 SSH 协议层探测，减少 NAT、防火墙、VPN 等中间设备清理空闲连接的概率；它不会因为用户暂时没有输入而主动登出正常客户端。

建议连接端也配置 keepalive：

```sshconfig
Host rabbit-dev-container
    HostName localhost
    Port 2222
    User root
    ServerAliveInterval 60
    ServerAliveCountMax 3
```

默认会从下面的地址下载公开 SSH 公钥：

```text
https://github.com/rabbit-dayi.keys
```

使用其他 GitHub 用户时设置：

```bash
-e GITHUB_USER=<github-user>
```

### code-server

浏览器打开：

```text
https://localhost
```

默认只需设置一个 `PASSWORD`。Nginx 会统一保护 code-server、服务跳转页、状态页和 DNS 管理页，用户名为 `admin`；浏览器在同一域名下认证一次后即可访问全部页面。code-server 此时自动使用 `auth=none`，不会再显示第二个登录页：

```yaml
environment:
  PASSWORD: change-this-password
```

设置 `NGINX_UNIFIED_AUTH=false` 可关闭统一认证并恢复 code-server 自带登录页。显式设置 `CODE_SERVER_AUTH` 会覆盖自动选择；如果选择 `password` 但没有提供 `PASSWORD` 或 `HASHED_PASSWORD`，code-server 会保持 idle，不会反复重启刷日志。显式指定 `CODE_SERVER_AUTH=password` 时会保留 code-server 自带的第二层登录；希望一次密码访问全部页面时不要覆盖默认的自动设置。只有 `HASHED_PASSWORD` 时无法生成 Nginx Basic Auth 文件，因此仍使用 code-server 自带登录。

本地使用默认自签名证书时，需要在浏览器确认一次证书警告；命令行检查可使用 `curl -k https://localhost/healthz`。部署域名和正式证书后，访问 `https://<你的域名>`。

### 环境变量管理面板

浏览器打开 `https://localhost/env/` 进入环境变量管理面板；根路径 `/` 现在是统一服务入口。Nginx 负责 HTTPS 和外层 Basic Auth，用户名默认为 `admin`，密码使用 `PASSWORD`。没有设置密码时，统一 Web 入口不会开放管理页面。

面板只显示镜像支持的配置变量，敏感变量只显示是否已设置，不会回显密码或 Tailscale auth key。保存后配置会原子写入 `/root/.rabbit-dev-container/env-manager.env`，推荐持久化挂载 `/root`。

`code-server` 和 Tailscale 变量保存后会自动重载对应服务；`GITHUB_USER`、`TZ` 和 `LANG` 等初始化变量会保存并提示重启容器后生效。修改 `CODE_SERVER_BIND_ADDR` 时仍需同步调整宿主机端口映射。

如需只在受信任网络临时使用无认证面板，可设置 `ENV_MANAGER_ALLOW_UNAUTHENTICATED=true` 并同时关闭外层认证；公网或 Tailscale 网络不应这样配置。

## 内置 Tailscale

Tailscale 默认关闭。启用后，容器中的 SSH 和 Nginx HTTPS 入口可以通过该容器自己的 Tailscale IP 访问；原有端口映射仍可作为本地或故障恢复入口。

### Docker Compose 示例

将 auth key 放在未提交到 Git 的 `.env` 或其他 secret 管理工具中：

```dotenv
TS_AUTHKEY=tskey-auth-...
```

```yaml
services:
  dev:
    image: ghcr.io/rabbit-dayi/rabbit-dev-container:latest
    environment:
      GITHUB_USER: rabbit-dayi
      PASSWORD: change-this-password
      TS_ENABLE: "true"
      TS_AUTHKEY: ${TS_AUTHKEY}
      TS_AUTH_ONCE: "true"
      TS_HOSTNAME: dev-container
      TS_ACCEPT_DNS: "false"
    devices:
      - /dev/net/tun:/dev/net/tun
    cap_add:
      - NET_ADMIN
      - NET_RAW
    ports:
      - "2222:22"
      - "80:80"
      - "443:443"
    volumes:
      - rabbit-dev-container-root:/root
      - rabbit-dev-container-workspace:/workspace
    restart: unless-stopped

volumes:
  rabbit-dev-container-root:
  rabbit-dev-container-workspace:
```

不需要 `privileged: true`。Tailscale 节点身份和状态默认持久化到 `/root/.rabbit-dev-container/tailscale`，因此只需持久化 `/root`。LocalAPI socket 位于临时目录 `/run/tailscale/tailscaled.sock`，不应持久化。

Tailscale 是附加服务：缺少 auth key、控制面不可达、认证失败、缺少 TUN 或 capabilities 时，SSH 和 code-server 仍会继续运行。可以进入容器后手工检查：

```bash
docker exec rabbit-dev-container tailscale \
  --socket=/run/tailscale/tailscaled.sock status
```

或手工认证：

```bash
docker exec -it rabbit-dev-container tailscale \
  --socket=/run/tailscale/tailscaled.sock up
```

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `GITHUB_USER` | `rabbit-dayi` | 下载 `https://github.com/<user>.keys`；设为空可禁用自动下载。 |
| `CODE_SERVER_BIND_ADDR` | `127.0.0.1:8080` | code-server 监听地址。 |
| `CODE_SERVER_AUTH` | 自动 | 未设置时，有统一 Nginx 认证则使用 `none`，否则使用 `password`；也可显式设置 `password` 或 `none`。 |
| `PASSWORD` | 未设置 | 统一 Nginx 登录、code-server 和 DNS 管理页共用的明文密码。 |
| `HASHED_PASSWORD` | 未设置 | 仅供 code-server 自带登录使用的哈希密码，适合不启用统一认证的长期部署。 |
| `CODE_SERVER_WORKDIR` | `/workspace` | code-server 默认工作目录。 |
| `CODE_SERVER_USER_DATA_DIR` | `/root/.rabbit-dev-container/code-server` | code-server 用户数据、扩展和设置的持久化目录。 |
| `CONTAINER_STATE_DIR` | `/root/.rabbit-dev-container` | 应用默认持久化根目录；各服务的状态目录默认都在这里。 |
| `UV_CACHE_DIR` | `/root/.rabbit-dev-container/uv` | uv 包缓存目录。 |
| `NPM_CONFIG_CACHE` | `/root/.rabbit-dev-container/npm` | npm 包缓存目录。 |
| `NGINX_ENABLE` | `true` | 严格设为 `true` 时启用统一 HTTPS Web 入口。 |
| `NGINX_HTTP_PORT` | `80` | Nginx HTTP 监听端口。 |
| `NGINX_HTTPS_PORT` | `443` | Nginx HTTPS 监听端口。 |
| `NGINX_HTTP_REDIRECT` | `true` | 是否将 HTTP 以 308 重定向到 HTTPS。 |
| `NGINX_UNIFIED_AUTH` | `true` | 有 `PASSWORD` 时使用一次 Nginx Basic Auth 保护全部 Web 页面；用户名固定为 `admin`。 |
| `NGINX_SERVER_NAMES` | `_` | 逗号分隔的精确域名或通配域名，用于 Nginx `server_name` 和默认证书 SAN。 |
| `STATUS_INTERVAL` | `5` | 状态采样间隔，允许 `1`–`60` 秒。 |
| `RESOLV_WEB_ENABLE` | `true` | 是否允许启用 `/dns/` DNS 管理页和本地 API；仍需配置密码或显式允许无认证。 |
| `RESOLV_WEB_PORT` | `8787` | DNS 管理 API 仅监听容器内 `127.0.0.1` 的端口。 |
| `RESOLV_WEB_PASSWORD` | 未设置 | DNS 管理页的 Basic Auth 密码；未设置时回退使用 `PASSWORD`。 |
| `RESOLV_WEB_ALLOW_UNAUTHENTICATED` | `false` | 没有管理页密码时是否仍启用页面和 API；仅适合受信任网络内临时测试。 |
| `RESOLV_STATE_FILE` | `/root/.rabbit-dev-container/resolver.json` | DNS 页面保存的持久化配置文件。 |
| `RESOLV_AUTO_CONFIG` | `true` | 是否在启动时探测并补充 DNS；设为 `false` 可完全禁用。 |
| `RESOLV_LOCAL_NAMESERVER` | `127.0.0.1` | 本地 DNS 的 IPv4 地址，探测端口固定为 `53`。 |
| `RESOLV_FALLBACK_NAMESERVER` | `1.1.1.1` | 公共 DNS 备用 IPv4 地址，探测端口固定为 `53`。 |
| `RESOLV_FALLBACK_ALWAYS` | `false` | 本地 DNS 未响应时，是否仍探测并添加备用 DNS。 |
| `RESOLV_CHECK_DOMAIN` | `example.com` | DNS 探测使用的域名。 |
| `NGINX_TLS_CERT_FILE` | 未设置 | 自定义证书绝对路径；必须与 `NGINX_TLS_KEY_FILE` 一同设置。 |
| `NGINX_TLS_KEY_FILE` | 未设置 | 自定义未加密私钥绝对路径；必须与 `NGINX_TLS_CERT_FILE` 一同设置。 |
| `ENV_MANAGER_ENABLE` | `true` | 是否启用 `/env/` 环境变量管理面板。 |
| `ENV_MANAGER_BIND_ADDR` | `127.0.0.1:8789` | 环境变量管理 API 的容器内监听地址。 |
| `ENV_MANAGER_USERNAME` | `admin` | 环境变量管理面板 Basic Auth 用户名。 |
| `ENV_MANAGER_CONFIG_DIR` | `/root/.rabbit-dev-container` | 环境变量覆盖文件所在目录。 |
| `ENV_MANAGER_TLS_ENABLE` | `false` | 内部面板是否单独启用 TLS；默认由 Nginx 统一提供 HTTPS。 |
| `ENV_MANAGER_ALLOW_UNAUTHENTICATED` | `false` | 是否允许环境变量面板内部 API 无认证，仅适合受信任网络临时测试。 |
| `TS_ENABLE` | `false` | 设为严格的 `true` 才启用 Tailscale。 |
| `TS_STATE_DIR` | `/root/.rabbit-dev-container/tailscale` | Tailscale 节点身份和状态目录。 |
| `TS_AUTHKEY` | 未设置 | Tailscale auth key，只应在运行时安全注入。 |
| `TS_AUTH_ONCE` | `true` | 已有有效持久化登录时不重复使用 auth key。 |
| `TS_HOSTNAME` | 未设置 | 可选的 tailnet 节点名。 |
| `TS_ACCEPT_DNS` | `false` | 是否接受 Tailscale DNS 配置。 |
| `TS_ADVERTISE_TAGS` | 未设置 | 逗号分隔的 tags，例如 `tag:dev,tag:container`。 |
| `TS_CONFIG_TIMEOUT` | `30` | 等待和配置 Tailscale 的秒数，允许 5–300。 |
| `DOCKERD_ROOTLESS_ENABLE` | `false` | 严格设为 `true` 才启动镜像内的 rootless Docker daemon；需要外层容器使用 `--privileged`。 |
| `DOCKERD_DATA_ROOT` | `/root/.rabbit-dev-container/docker` | rootless Docker 镜像、容器、卷和构建缓存目录。 |
| `DOCKERD_CONFIG_DIR` | `/root/.rabbit-dev-container/dockerd/config` | rootless Docker 的 XDG 配置目录。 |
| `DOCKERD_CACHE_DIR` | `/root/.rabbit-dev-container/dockerd/cache` | rootless Docker 的 XDG 缓存目录。 |
| `MANAGER_ENABLE` | `true` | 是否启用 `/manage/` 证书管理页；需要 `PASSWORD` 和统一 Nginx 认证。 |
| `MANAGER_PORT` | `8788` | Go 证书管理 API 仅监听容器内 `127.0.0.1` 的端口。 |
| `MANAGER_CONFIG_DIR` | `/root/.rabbit-dev-container` | 证书版本和其他管理状态的持久化根目录。 |
| `DOCKER_HOST` | `unix:///run/user/1000/docker.sock` | 镜像内 Docker CLI 默认连接的 rootless daemon socket。 |
| `STARTUP_BANNER` | `true` | 是否在容器初始化日志中显示启动横幅。 |
| `TZ` | `Asia/Shanghai` | 容器时区。 |
| `LANG` | `C.UTF-8` | 容器语言环境。 |

实现不接受任意 `TS_EXTRA_ARGS`，避免 shell 参数拆分和命令注入。需要增加新的 Tailscale 选项时，应在镜像中加入明确、经过校验的环境变量。

## SSH 公钥行为

### 自动下载

`GITHUB_USER` 非空时，容器启动会下载对应 GitHub 用户的公开 SSH keys。下载成功且内容非空时原子替换 `authorized_keys`；下载失败时保留已有文件并继续启动。

### 自己挂载 authorized_keys

将 `GITHUB_USER` 设为空，并可只读挂载文件：

```bash
docker run -d \
  --name rabbit-dev-container \
  -e GITHUB_USER= \
  -e PASSWORD='change-this-password' \
  -p 2222:22 \
  -p 80:80 \
  -p 443:443 \
  -v ./authorized_keys:/root/.ssh/authorized_keys:ro \
  ghcr.io/rabbit-dayi/rabbit-dev-container:latest
```

初始化逻辑不会强制覆盖只读挂载，也不会递归修改整个 `/root` 的属主。启动时会将该文件复制到 root 拥有的临时 SSH key 文件，因此宿主机挂载文件属于非 root 用户时，SSH 公钥登录同样可用。

## 数据卷

推荐的持久化路径：

| 路径 | 用途 |
| --- | --- |
| `/root` | 所有配置与应用状态。镜像实际使用 `/root/.rabbit-dev-container` 保存 DNS、证书、code-server 用户数据、Tailscale 身份、rootless Docker、uv 和 npm。 |
| `/workspace` | 项目代码和默认工作目录。 |

新的空 `/root` 目录会自动恢复 `.bashrc`、`.profile` 等默认配置；建议通过命名卷整体挂载 `/root`，其中的 `.rabbit-dev-container` 会保存镜像配置和应用状态。

容器内临时执行 `apt install` 只会写入当前容器的 writable layer；容器删除重建后会丢失。长期需要的包应写入派生镜像：

```dockerfile
FROM ghcr.io/rabbit-dayi/rabbit-dev-container:latest

RUN apt-get update \
  && apt-get install -y --no-install-recommends your-package \
  && rm -rf /var/lib/apt/lists/*
```

## 本地构建和测试

```bash
git clone https://github.com/rabbit-dayi/rabbit-dev-container.git
cd rabbit-dev-container
docker build -t rabbit-dev-container:local .
tests/smoke.sh rabbit-dev-container:local
```

smoke test 会检查：

- s6、SSH、code-server、Nginx、OpenSSL、uv 和 Tailscale 可执行文件
- Node.js、npm 和 npx
- 基础维护工具的可执行文件
- Docker CLI、Buildx、Compose plugin 和 rootless Docker 运行时依赖
- SSH 配置语法和有效的 keepalive/认证设置
- 默认自签名证书、域名 HTTPS、HTTP 到 HTTPS 跳转，以及挂载自定义 TLS 证书
- `/status/` 运行状态页和 `/dns/` DNS 管理页的测试、持久化和环境变量覆盖行为
- 状态采样服务、`dev` 运维命令和服务健康检查
- `/init`、sshd、code-server 和 nginx 的实际运行状态
- 只读 `authorized_keys` 挂载下的真实 SSH 公钥登录
- Tailscale 默认关闭，以及启用但缺少 TUN 时不会影响主服务
- runner 提供 `/dev/net/tun` 时，Tailscale daemon、LocalAPI socket 和主服务的实际运行状态
- 在 runner 提供 `/dev/fuse` 和非特权 user namespace 时，以 `--privileged` 运行并检查 rootless `dockerd` 的 socket、非 root daemon 身份，以及本地 scratch 镜像的构建和运行；能力受限的 runner 会明确跳过这部分集成检查

## GitHub Actions

Pull Request 和 push 都会先构建 `linux/amd64` 测试镜像并运行 smoke test。测试通过后再构建 `linux/amd64`、`linux/arm64`；非 PR 构建会发布到：

```text
ghcr.io/rabbit-dayi/rabbit-dev-container:latest
```

触发条件包括 push 到 `main`、`v*.*.*` tag、Pull Request 和手动触发。

## 排障

### SSH 登录失败

1. 检查 `2222:22` 端口映射。
2. 检查 `GITHUB_USER` 和 `https://github.com/<user>.keys`。
3. 检查容器日志：`docker logs rabbit-dev-container`。
4. 使用 `GITHUB_USER=` 时，确认挂载的 `authorized_keys` 内容、权限和公钥匹配。

### SSH 仍然断开

镜像已经配置服务端 SSH keepalive；连接端仍建议配置 `ServerAliveInterval`。如果断开时容器重启、sshd 被杀死、宿主网络变化或发生 OOM，keepalive 无法保留原 TCP 会话。检查：

```bash
docker inspect rabbit-dev-container \
  --format 'running={{.State.Running}} oom={{.State.OOMKilled}} restarts={{.RestartCount}}'
docker logs --since 10m rabbit-dev-container
```

### code-server 无法访问

默认模式下确认映射了 `443:443`，并使用 `https://<域名>` 访问。检查 `PASSWORD`/`HASHED_PASSWORD`，或明确使用 `CODE_SERVER_AUTH=none`；使用默认自签名证书时浏览器还需要确认一次证书警告。

```bash
docker logs rabbit-dev-container
docker exec rabbit-dev-container nginx -t -c /run/nginx/nginx.conf
```

仅在 `NGINX_ENABLE=false` 时才需要映射 `8080`，并将 `CODE_SERVER_BIND_ADDR` 设为 `0.0.0.0:8080`。

### Tailscale 没有上线

检查：

```bash
ls -l /dev/net/tun
docker logs rabbit-dev-container
docker exec rabbit-dev-container tailscale \
  --socket=/run/tailscale/tailscaled.sock status
```

确认设置了 `TS_ENABLE=true`、映射 `/dev/net/tun`、添加 `NET_ADMIN`/`NET_RAW`，并提供有效 auth key。若状态卷已经登录，通常不需要再次提供 key。

### rootless Docker 不可用

确认设置了 `DOCKERD_ROOTLESS_ENABLE=true`，且外层容器使用了 `--privileged`（Compose 为 `privileged: true`）。查看 daemon 日志和状态：

```bash
docker logs rabbit-dev-container
docker exec rabbit-dev-container docker info
docker exec rabbit-dev-container ls -l /run/user/1000/docker.sock /dev/fuse
```

若日志提示 user namespace 不可用，需要由宿主机管理员启用非特权 user namespace；若提示 `/dev/fuse` 不可用，通常表示外层容器没有使用 `--privileged`。不要通过挂载宿主机 Docker socket 来替代这些条件，那会让容器直接控制宿主机 daemon。

### DNS 或 GitHub 暂时不可用

GitHub SSH key 下载和 Tailscale 配置失败都不会让 SSH/code-server 无限重启。可以修复 Docker DNS，或手工挂载 `/root/.ssh/authorized_keys`；应用状态统一保存在 `/root/.rabbit-dev-container`。

## 安全说明

- GitHub `.keys` 地址只包含公开 SSH 公钥，不是私钥。
- 不要把 SSH 私钥、GitHub PAT、密码或 `TS_AUTHKEY` 写入 Dockerfile、README、镜像层或提交到 Git。
- 默认 TLS 证书是运行时生成的自签名证书，仅用于开箱访问；公网部署应挂载受信任 CA 签发的证书和私钥。
- auth key 应尽量使用一次性、短期、ephemeral 或受 tag 限制的 key；泄露后立即在 Tailscale 管理控制台吊销。
- 对外暴露 code-server 时应使用强密码，并限制在 Tailscale 或受信任内网中访问。
- 不建议在公网关闭统一认证后直接使用 `CODE_SERVER_AUTH=none`。
- Tailscale 模式本身只需要有限 capabilities，不需要 `privileged: true`。
- rootless Docker-in-Docker 的 daemon 不是外层 root，但该模式的外层容器仍需 `--privileged`；不要将其用于不受信任的代码或多租户环境。
