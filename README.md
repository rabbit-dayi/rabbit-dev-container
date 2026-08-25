# Rabbit Dev Container 🐇

一个面向远程开发的 Debian 13 Docker 镜像，支持 `linux/amd64` 和 `linux/arm64`。兔子标记代表可随时进入、随时维护的开发环境，内置：

- `s6-overlay`：作为容器内的 init / supervisor，启动和守护服务
- `OpenSSH Server`：使用公钥登录，并启用协议层 keepalive
- `code-server`：在浏览器中使用 VS Code
- `Nginx`：统一 HTTPS Web 入口，默认将 HTTP 重定向到 HTTPS，并提供运行状态、DNS 和证书管理页面
- `Tailscale`：可选的容器内 tailnet 接入服务
- 插件：由 s6 直接监督的可选附加服务，默认内置 `frpc`（反向代理客户端）和 CloakBrowser-Manager（第三方，需自备账号）两个插件，均默认关闭
- `Docker CLI`、Buildx、Compose plugin，以及可选的 rootless Docker-in-Docker daemon
- CUDA 镜像：包含 `nvcc`、CUDA 开发库和 `cuda-gdb`，不捆绑 GUI profiler；镜像不包含 NVIDIA 驱动
- `uv`：Python 包管理/运行工具
- 常用工具：`git`、`curl`、`wget`、`vim`、`tmux`、`ping`、`iproute2`、`net-tools`、`traceroute`、`procps`
- 开发与调试工具：`bubblewrap`、`build-essential`、`pkg-config`、`cmake`、`ninja`、`meson`、`gdb`、`strace`、`ltrace`、`valgrind`、`shellcheck`
- 网络与文件工具：`jq`、`rsync`、`socat`、`lsof`、`tree`、`ncdu`、`dnsutils`、`mtr`、`tcpdump`、`nmap`、`netcat`、`whois`、`ripgrep`、`fd`、`bat`、`git-lfs`、`lftp`、`aria2c`、`iperf3`、`ethtool`、`tracepath`、`brctl`
- 终端监控与效率工具：`htop`、`btop`、`iotop`、`iftop`、`sysstat`、`nethogs`、`screen`、`zsh`、`fish`、`fzf`、`entr`、`parallel`、`direnv`
- 压缩与数据工具：`sqlite3`、`uuidgen`、`bsdtar`、`zstd`、`pigz`、`rename`、`python3-yaml`、`python3-requests`
- Python 与构建依赖：`python3`、`pip3`、`venv`、`python3-dev`、`gawk`、`gettext`、`man-db` 以及 OpenSSL、SQLite、zlib、bz2、readline、lzma 开发库

其中 Debian 的命令名分别是 `fdfind` 和 `batcat`，对应软件包为 `fd-find` 和 `bat`。
- `Node.js`、`npm`、`npx`：JavaScript/TypeScript 运行与包管理
- `SSHFS`、`rclone`、`davfs2`：挂载 SSH、WebDAV 和常见对象存储
- 常用工具：`git`、`curl`、`wget`、`vim`、`tmux`、`ping`、`iproute2`、`net-tools`、`traceroute`、`procps`，以及上面列出的完整开发工具集
- 交互式 Bash：彩色两行提示符、Git 分支状态、`fzf` 键绑定，以及 `ll`、`la`、`gs`、`gd`、`gl`、`bat` 等快捷别名

镜像提供两个变体：标准版 `latest` 不包含 CUDA，CUDA 版 `cuda` 默认提供 CUDA 13.3，并同时面向 `linux/amd64` 和 `linux/arm64` 构建。CUDA 版运行程序时，仍需由宿主机安装兼容的 NVIDIA 驱动，并通过 NVIDIA Container Toolkit 将 GPU 暴露给容器；镜像只提供编译、调试和用户态开发依赖。构建时可通过 `--build-arg CUDA_VERSION=13-3` 选择 NVIDIA 仓库中可用的 CUDA 系列。

构建默认使用 USTC 的 Debian 与 Docker CE 镜像源；可用 `--build-arg DEBIAN_MIRROR=...` 覆盖 Debian 源。

镜像使用 `/init` 作为 PID 1。启动时将 `/root`、`/workspace`、`/opt` 和 `/home` 视为已有的持久化数据，不恢复、清空或覆盖其中的文件；只会在缺失时创建所需的专用状态目录和 SSH host key。GitHub SSH 公钥仅在没有本地 `authorized_keys` 时下载到临时运行目录。随后由 s6-overlay 分别管理 `sshd`、`code-server`、`nginx`、DNS 管理页、可选的 `tailscaled` 和 rootless `dockerd`。

普通 SSH/code-server 模式不需要 `privileged`、systemd、`/sys/fs/cgroup` 或 Compose 的 `init: true`。启用 Tailscale 内核网络时才需要 `/dev/net/tun`、`NET_ADMIN` 和 `NET_RAW`；启用 rootless Docker-in-Docker 时需要外层容器使用 `--privileged`，具体原因和使用方式见下文。

## 基础维护工具

镜像预装以下无需额外服务的维护工具：

- 进程与文件：`htop`、`pstree`、`lsof`、`strace`
- 磁盘与目录：`ncdu`、`tree`
- DNS 与网络诊断：`dig`、`mtr`、`tcpdump`、`socat`
- 数据、同步与脚本：`jq`、`rsync`、`node`、`npm`、`npx`

`tcpdump` 抓包需要容器具备 `NET_RAW` 能力；受默认 seccomp 或 ptrace 限制的运行环境中，`strace` 可能需要额外授予调试权限。

### 启动横幅

容器启动时会输出一个带网关地址、SSH 入口、工作目录和可选服务状态的启动横幅。所有服务进入启动阶段后，还会执行一次只读自检，在日志中以 `OK`、`WARN` 和 `SKIP` 汇总工具链、SSH、Web、配置目录、持久化挂载点、CUDA、Tailscale 和 rootless Docker。自检告警不会阻止容器启动。

```yaml
environment:
  STARTUP_BANNER: "false"
  STARTUP_SELF_CHECK: "false"
```

自检默认最多等待核心服务 20 秒；可用 `STARTUP_CHECK_TIMEOUT` 调整为 1–120 秒。查看结果：

```bash
docker logs rabbit-dev-container 2>&1 | grep '\[startup-check\]'
```

### `dev` 运维命令

镜像内置一个只读的统一运维入口，默认执行 `dev status`：

```bash
dev status      # 组件、工作区和 FUSE 状态
dev mounts      # SSHFS、rclone 和其他 FUSE 挂载
dev versions    # 主要工具版本
```

### SSHFS、rclone 与 WebDAV 远程目录

镜像预装 `sshfs`、`rclone`、`davfs2`、`fuse3` 和 `fusermount3`。SSHFS 与 `rclone mount` 需要把宿主机的 FUSE 设备和挂载能力传入容器：

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

通过 rclone 挂载 WebDAV：

```bash
rclone config
mkdir -p /workspace/webdav
rclone mount my-webdav: /workspace/webdav \
  --daemon --vfs-cache-mode writes
fusermount3 -u /workspace/webdav
```

也可以使用内核挂载命令调用 `davfs2`：

```bash
# root 用户需要非交互挂载时，将凭据写入 /etc/davfs2/secrets 并设为 0600：
# https://dav.example.com/remote.php/dav/files/user/ user password
mkdir -p /workspace/webdav
mount -t davfs https://dav.example.com/remote.php/dav/files/user/ \
  /workspace/webdav
umount /workspace/webdav
```

`RCLONE_CONFIG` 默认是 `/root/.rabbit_container/rclone/rclone.conf`，rclone VFS 缓存默认在 `/root/.rabbit-dev-container/rclone`；持久化 `/root` 后 remote 定义和缓存都能保留。不要把 WebDAV 密码直接写进 Compose 文件或提交到仓库，优先执行 `rclone config` 并保护 `/root` 卷。`davfs2` 的 root 非交互凭据位于 `/etc/davfs2/secrets`，如需跨容器保留，应单独通过 secret 或只读文件挂载提供。

Compose 用户可叠加专用的 FUSE 配置：

```bash
PASSWORD='change-this-password' docker compose \
  -f compose.yml -f compose.fuse.yml up -d
```

如果宿主机的 seccomp 或 AppArmor 策略仍阻止 FUSE 挂载，需要按宿主机安全策略额外放行；不要把 `--privileged` 作为 SSHFS 或 rclone 的默认参数。`davfs2` 同样要求 `SYS_ADMIN`，但不依赖 `/dev/fuse`。

### DNS 管理与检测

容器启动时会检查 `/etc/resolv.conf`，并探测 `RESOLV_LOCAL_NAMESERVER:53` 与 `RESOLV_FALLBACK_NAMESERVER:53` 是否真的响应。默认行为是：只有确认本地 DNS 响应时，才把它放到前面；如果备用 DNS 也可用，则一并补入。原有 `nameserver`、`search` 和 `options` 内容会保留。

普通 Docker 容器不会因为这个功能被强制改成公共 DNS：如果没有检测到本地 DNS，默认保留 Docker 注入的 DNS（通常是 `127.0.0.11`）。确实需要在本地 DNS 不响应时也尝试备用 DNS，可设置 `RESOLV_FALLBACK_ALWAYS=true`。对于 Docker 的文件挂载，脚本会在原子替换失败时尝试原地写入；符号链接、只读挂载或无法写入时，只记录提示并保留原文件。

当没有通过环境变量锁定 DNS 参数时，可访问 `https://<域名>/dns/` 打开 DNS 管理页，填写参数后执行“测试 DNS”或“保存并应用”。配置默认持久化到 `/root/.rabbit_container/resolver.json`；挂载 `/root` 即可跨容器重建保留全部配置。设置 `RESOLV_AUTO_CONFIG`、`RESOLV_LOCAL_NAMESERVER`、`RESOLV_FALLBACK_NAMESERVER`、`RESOLV_FALLBACK_ALWAYS` 或 `RESOLV_CHECK_DOMAIN` 后，对应字段由环境变量控制，页面不会覆盖它们。

管理页优先使用 `RESOLV_WEB_PASSWORD` 生成 Nginx Basic Auth；未设置时使用已有的 `PASSWORD`。如果两者都没有，页面和 API 默认完全关闭。只在受信任网络内临时测试时，才应显式设置 `RESOLV_WEB_ALLOW_UNAUTHENTICATED=true` 跳过认证。

### Cloudflare 临时隧道

`/dns/` 页面同一位置提供 Cloudflare 临时隧道（`cloudflared tunnel --url`），把容器内任意 `host:port` 临时映射到一个随机的 `*.trycloudflare.com` 地址，用于快速对外测试。每个内部地址各自对应一条独立隧道，可以同时新建多条；停止或容器重启后地址不会保留，也不写入持久化配置。

隧道默认使用 `--protocol http2`，而不是 cloudflared 自身默认的 QUIC：QUIC 依赖出站 UDP，在容器网络或防火墙环境中经常被限制或不稳定，是隧道“偶尔连接失败”的常见原因；HTTP/2（TCP）在这类环境下更可靠。需要时可通过 `CLOUDFLARED_PROTOCOL` 覆盖为 `quic` 或 `auto`。启动隧道最多重试 3 次，每次等待 15 秒获取公网地址，失败或断开会明确标记在页面上，不会静默保留过期状态。

## 镜像地址

```text
ghcr.io/rabbit-dayi/rabbit-dev-container:latest
ghcr.io/rabbit-dayi/rabbit-dev-container:cuda
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

仓库根目录提供了可直接启动的 [`compose.yml`](compose.yml)，默认持久化 `/root`、`/workspace`、`/opt` 和 `/home`：

```bash
PASSWORD='change-this-password' NGINX_SERVER_NAMES=code.example.com docker compose up -d
```

等价配置如下：

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
      - rabbit-dev-container-opt:/opt
      - rabbit-dev-container-home:/home
    restart: unless-stopped

volumes:
  rabbit-dev-container-root:
  rabbit-dev-container-workspace:
  rabbit-dev-container-opt:
  rabbit-dev-container-home:
```

不要为此服务设置 `init: true`；s6-overlay 提供的 `/init` 必须保持 PID 1。

## Nginx HTTPS 统一入口

Nginx 默认启用，是容器 Web 服务的 HTTPS 入口：容器内 code-server 默认只绑定 `127.0.0.1:8080`，HTTP `80` 会以 `308` 重定向到 HTTPS `443`。打开 `https://<域名>/` 会进入服务引导页；工作区通过 `/workspace/` 访问，`/status/` 提供自动刷新的运行状态页，`/dns/` 提供 DNS 测试和持久化配置页，`/manage/` 和 `/env/` 提供管理功能。

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

访问 `https://<域名>/status/` 可以查看 SSH、Nginx、code-server、rootless DIND、Tailscale 的状态，以及工作区占用、全部 FUSE 和 SSHFS 挂载数量。页面每 5 秒刷新一次；对应的机器可读接口是 `/status.json`。状态服务只写入这些运行指标，不会暴露密码、auth key 或其他环境变量。

### 证书管理页

设置 `PASSWORD` 后访问 `https://<域名>/manage/`，可以查看当前证书的域名、签发者、有效期和指纹，并上传新的证书链和未加密私钥。上传后会在 `/root/.rabbit_container/tls/versions/` 保存版本，原子切换 `current` 链接并热加载 Nginx；如果校验或热加载失败，会自动恢复上一版。通过 `NGINX_TLS_CERT_FILE`/`NGINX_TLS_KEY_FILE` 或 `/etc/nginx/certs` 提供的证书属于外部托管，只读展示，不允许页面覆盖。证书文件上传和管理接口默认只在统一 Nginx 登录后可见。同一页面下方还有一个只读的“插件”目录，列出已注册插件及其当前运行状态，详见下方[插件](#插件)一节。

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

`dockerd` 以镜像内 UID 1000 的 `dockerd` 用户运行；root 的 SSH、终端和 code-server 已预设 `DOCKER_HOST=unix:///run/user/1000/docker.sock`，Docker 数据默认位于 `/opt/.rabbit_container/docker`，进入后可直接执行：

```bash
docker info
docker run --rm hello-world
docker buildx version
docker compose version
```

Docker API 默认不监听 TCP 端口，也不需要挂载宿主机的 `/var/run/docker.sock`。镜像中的 Docker 数据位于 `/opt/.rabbit_container/docker`，随 `/opt` 卷持久化，并且不会要求放宽 `/root` 的权限。

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
      - rabbit-dev-container-opt:/opt
      - rabbit-dev-container-home:/home
    restart: unless-stopped

volumes:
  rabbit-dev-container-root:
  rabbit-dev-container-workspace:
  rabbit-dev-container-opt:
  rabbit-dev-container-home:
```

启用前，宿主机必须允许非特权 user namespace；服务启动时还会检查 `/dev/fuse`。条件不满足时 rootless `dockerd` 会保持 idle，SSH 和 code-server 不受影响。rootless Docker 的已知限制仍然适用，例如默认不能发布低于 1024 的端口，且没有 systemd/cgroup v2 委派时部分容器级资源限制不会生效。

## 插件

插件是构建时打包进镜像、运行时通过 `PLUGIN_<NAME>_ENABLE` 开关启用的可选附加服务，沿用 Tailscale（`TS_ENABLE`）和 rootless Docker-in-Docker（`DOCKERD_ROOTLESS_ENABLE`）已有的约定：由 s6 直接监督对应进程（自动重启、干净退出、不会因为被禁用而反复崩溃重启），没有运行时安装任意代码的机制，因此每个插件都能在镜像构建时被审查。带 Web UI 的插件会像 `NGINX_SERVICE_LINKS` 里的自定义服务一样，自动出现在 `/services/` 门户、`/status.json` 和启动横幅中。

开关状态可以在 `/env/` 环境变量管理面板中修改（保存后只重启该插件自身的服务并热加载 Nginx，不需要重启整个容器），也可以在启动容器时通过 `-e PLUGIN_<NAME>_ENABLE=true` 直接设置。`/manage/` 页面下方的插件目录展示每个已注册插件的说明、依赖和当前运行状态（只读，实际开关仍在 `/env/`）。

新增插件的约定、模板和生成脚本见仓库内的 [`plugins/README.md`](plugins/README.md)（`scripts/new-plugin.sh <id>` 可以直接生成骨架），本节只说明已经内置的两个插件。

### frpc

[fatedier/frp](https://github.com/fatedier/frp) 的客户端 `frpc`，用于把容器内服务反向代理到你自己的 `frps` 服务端；本身没有 Web UI。二进制在镜像构建时按固定版本和 SHA-256 校验下载。设置 `PLUGIN_FRPC_ENABLE=true` 并把配置文件放到 `PLUGIN_FRPC_CONFIG`（默认 `/root/.rabbit_container/plugins/frpc/frpc.toml`）后即可启用；持久化 `/root` 后配置会跨容器重建保留。配置文件不存在时插件保持 idle 并在日志中提示，不会反复崩溃重启。

### CloakBrowser-Manager（第三方，默认关闭）

[CloakHQ/CloakBrowser-Manager](https://github.com/CloakHQ/CloakBrowser-Manager) 是一个第三方的隔离浏览器配置文件管理工具，不由本项目维护；启用即表示你已了解并同意该项目自己的条款，并自备账号/许可证。插件以官方 `cloakhq/cloakbrowser-manager` 镜像原样运行，不做任何修改。

启用需要先打开 rootless Docker-in-Docker（`DOCKERD_ROOTLESS_ENABLE=true`），再设置 `PLUGIN_CLOAKBROWSER_ENABLE=true`；插件会等待内层 `dockerd` 的 socket 就绪后，以前台方式启动容器，由 s6 直接监督（容器异常退出会被重新拉起，与 tailscaled、dockerd-rootless 相同）。任一前置条件不满足时插件保持 idle 并给出明确提示。默认通过 `127.0.0.1:${PLUGIN_CLOAKBROWSER_PORT:-18180}` 暴露，并在 Nginx 中代理到 `/plugins/cloakbrowser/`；可选的 `CLOAKBROWSER_LICENSE_KEY` 用于 Pro 版许可证，留空则使用免费版。

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
https://localhost/
```

默认只需设置一个 `PASSWORD`。Nginx 会统一保护工作区、服务引导页、状态页和 DNS 管理页，用户名为 `admin`；浏览器在同一域名下认证一次后即可访问全部页面。code-server 此时自动使用 `auth=none`，不会再显示第二个登录页：

```yaml
environment:
  PASSWORD: change-this-password
```

设置 `NGINX_UNIFIED_AUTH=false` 可关闭统一认证并恢复 code-server 自带登录页。显式设置 `CODE_SERVER_AUTH` 会覆盖自动选择；如果选择 `password` 但没有提供 `PASSWORD` 或 `HASHED_PASSWORD`，code-server 会保持 idle，不会反复重启刷日志。显式指定 `CODE_SERVER_AUTH=password` 时会保留 code-server 自带的第二层登录；希望一次密码访问全部页面时不要覆盖默认的自动设置。只有 `HASHED_PASSWORD` 时无法生成 Nginx Basic Auth 文件，因此仍使用 code-server 自带登录。

本地使用默认自签名证书时，需要在浏览器确认一次证书警告；命令行检查可使用 `curl -k https://localhost/healthz`。部署域名和正式证书后，访问 `https://<你的域名>`，即可先进入服务引导页。

### 环境变量管理面板

浏览器打开 `https://localhost/env/` 进入环境变量管理面板；根路径 `/` 会进入服务引导页，工作区地址为 `/workspace/`。Nginx 负责 HTTPS 和外层 Basic Auth，用户名默认为 `admin`，密码使用 `PASSWORD`。没有设置密码时，统一 Web 入口不会开放管理页面。

面板只显示镜像支持的配置变量，敏感变量只显示是否已设置，不会回显密码或 Tailscale auth key。保存后配置会原子写入 `/root/.rabbit_container/env-manager.env`，推荐持久化挂载 `/root`。

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
      - rabbit-dev-container-opt:/opt
      - rabbit-dev-container-home:/home
    restart: unless-stopped

volumes:
  rabbit-dev-container-root:
  rabbit-dev-container-workspace:
  rabbit-dev-container-opt:
  rabbit-dev-container-home:
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
| `CONTAINER_CONFIG_DIR` | `/root/.rabbit_container` | DNS、证书和环境覆盖等轻量配置的持久化根目录。 |
| `CONTAINER_DATA_DIR` | `/opt/.rabbit_container` | rootless Docker 等非 root 服务数据的持久化根目录。 |
| `CONTAINER_STATE_DIR` | `/root/.rabbit-dev-container` | code-server、Tailscale、uv 和 npm 缓存的持久化根目录。 |
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
| `RESOLV_STATE_FILE` | `/root/.rabbit_container/resolver.json` | DNS 页面保存的持久化配置文件。 |
| `RESOLV_AUTO_CONFIG` | `true` | 是否在启动时探测并补充 DNS；设为 `false` 可完全禁用。 |
| `RESOLV_LOCAL_NAMESERVER` | `127.0.0.1` | 本地 DNS 的 IPv4 地址，探测端口固定为 `53`。 |
| `RESOLV_FALLBACK_NAMESERVER` | `1.1.1.1` | 公共 DNS 备用 IPv4 地址，探测端口固定为 `53`。 |
| `RESOLV_FALLBACK_ALWAYS` | `false` | 本地 DNS 未响应时，是否仍探测并添加备用 DNS。 |
| `RESOLV_CHECK_DOMAIN` | `example.com` | DNS 探测使用的域名。 |
| `CLOUDFLARED_PROTOCOL` | `http2` | 临时隧道使用的 cloudflared 传输协议；可选 `quic` 或 `auto`，默认 `http2` 以避免 QUIC 所需的出站 UDP 在部分网络中被限制。 |
| `NGINX_TLS_CERT_FILE` | 未设置 | 自定义证书绝对路径；必须与 `NGINX_TLS_KEY_FILE` 一同设置。 |
| `NGINX_TLS_KEY_FILE` | 未设置 | 自定义未加密私钥绝对路径；必须与 `NGINX_TLS_CERT_FILE` 一同设置。 |
| `ENV_MANAGER_ENABLE` | `true` | 是否启用 `/env/` 环境变量管理面板。 |
| `ENV_MANAGER_BIND_ADDR` | `127.0.0.1:8789` | 环境变量管理 API 的容器内监听地址。 |
| `ENV_MANAGER_USERNAME` | `admin` | 环境变量管理面板 Basic Auth 用户名。 |
| `ENV_MANAGER_CONFIG_DIR` | `/root/.rabbit_container` | 环境变量覆盖文件所在目录。 |
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
| `DOCKERD_DATA_ROOT` | `/opt/.rabbit_container/docker` | rootless Docker 镜像、容器、卷和构建缓存目录。 |
| `DOCKERD_CONFIG_DIR` | `/opt/.rabbit_container/dockerd/config` | rootless Docker 的 XDG 配置目录。 |
| `DOCKERD_CACHE_DIR` | `/opt/.rabbit_container/dockerd/cache` | rootless Docker 的 XDG 缓存目录。 |
| `MANAGER_ENABLE` | `true` | 是否启用 `/manage/` 证书管理页；需要 `PASSWORD` 和统一 Nginx 认证。 |
| `MANAGER_PORT` | `8788` | Go 证书管理 API 仅监听容器内 `127.0.0.1` 的端口。 |
| `MANAGER_CONFIG_DIR` | `/root/.rabbit_container` | 证书版本和其他管理配置的持久化根目录。 |
| `DOCKER_HOST` | `unix:///run/user/1000/docker.sock` | 镜像内 Docker CLI 默认连接的 rootless daemon socket。 |
| `PLUGIN_FRPC_ENABLE` | `false` | 严格设为 `true` 才启用 frpc 插件。 |
| `PLUGIN_FRPC_CONFIG` | `/root/.rabbit_container/plugins/frpc/frpc.toml` | frpc 配置文件路径；不存在时插件保持 idle。 |
| `PLUGIN_CLOAKBROWSER_ENABLE` | `false` | 严格设为 `true` 才启用 CloakBrowser-Manager 插件（第三方组件）；需要先启用 `DOCKERD_ROOTLESS_ENABLE`。 |
| `PLUGIN_CLOAKBROWSER_PORT` | `18180` | CloakBrowser-Manager Web UI 在容器内 `127.0.0.1` 监听的端口。 |
| `CLOAKBROWSER_LICENSE_KEY` | 未设置 | CloakBrowser Pro 许可证密钥，留空则使用免费版。 |
| `STARTUP_BANNER` | `true` | 是否在容器初始化日志中显示启动横幅。 |
| `STARTUP_SELF_CHECK` | `true` | 是否在服务启动后执行只读自检并输出到容器日志。 |
| `STARTUP_CHECK_TIMEOUT` | `20` | 自检等待核心服务就绪的秒数，允许 1–120。 |
| `TZ` | `Asia/Shanghai` | 容器时区。 |
| `LANG` | `C.UTF-8` | 容器语言环境。 |

实现不接受任意 `TS_EXTRA_ARGS`，避免 shell 参数拆分和命令注入。需要增加新的 Tailscale 选项时，应在镜像中加入明确、经过校验的环境变量。

## SSH 公钥行为

### 自动下载

当 `/root/.ssh/authorized_keys` 不存在或不可读且 `GITHUB_USER` 非空时，容器会下载对应 GitHub 用户的公开 SSH keys 到 `/run/sshd` 作为本次运行的临时回退。它不会替换或修改 `/root` 中任何文件；下载失败时继续启动。

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

`sshd` 主路径直接读取 `/root/.ssh/authorized_keys`，因此保存在 `/root` 卷中的公钥修改无需重建容器即可生效。初始化逻辑不会强制覆盖只读挂载、修改已有文件的属主或递归修改整个 `/root`；对于宿主机以非 root 用户拥有的只读单文件挂载，启动时会保留一份 root 拥有的运行时副本作为兼容回退，因此 SSH 公钥登录同样可用。

### 服务端 Host Key 持久化

服务端 RSA、ECDSA 和 Ed25519 host key 保存在 `/root/.ssh/ssh_host_*_key`。将 `/root` 挂载为命名卷或主机目录后，容器重建仍会保持相同的 SSH 主机指纹，客户端不会因重建收到 host key changed 警告。首次启动需要 `/root/.ssh` 可写以生成缺失的 host key。

SSH 登录会显示兔子主题 MOTD。

## 数据卷

推荐的持久化路径：

| 路径 | 用途 |
| --- | --- |
| `/root` | SSH 公钥和 host keys；`/root/.rabbit_container` 保存轻量配置，`/root/.rabbit-dev-container` 保存 code-server、Tailscale 和用户缓存。启动时只创建缺失的专用文件。 |
| `/workspace` | 项目代码和默认工作目录；启动时不会创建、清空或填充。 |
| `/opt` | 用户自行安装的工具或运行时；`/opt/.rabbit_container` 用于 UID 1000 的 rootless Docker 数据。 |
| `/home` | 用户家目录；镜像启动不会修改。 |

建议通过命名卷整体挂载这四个目录。终端配置来自 `/etc/profile.d` 和 `/etc/bash.bashrc`，因此不需要向持久化的用户 `.bashrc` 写入任何内容。

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

docker build --target cuda -t rabbit-dev-container:cuda-local .
tests/smoke.sh rabbit-dev-container:cuda-local cuda
```

smoke test 会检查：

- s6、SSH、code-server、Nginx、OpenSSL、uv 和 Tailscale 可执行文件
- 标准版不包含 CUDA；CUDA 版包含 `nvcc` 和 `cuda-gdb`
- Node.js、npm 和 npx
- 基础维护工具的可执行文件
- SSHFS、rclone、davfs2、FUSE 工具和持久化配置目录
- Docker CLI、Buildx、Compose plugin 和 rootless Docker 运行时依赖
- SSH 配置语法和有效的 keepalive/认证设置
- 默认自签名证书、域名 HTTPS、HTTP 到 HTTPS 跳转，以及挂载自定义 TLS 证书
- `/status/` 运行状态页和 `/dns/` DNS 管理页的测试、持久化和环境变量覆盖行为
- 状态采样服务、`dev` 运维命令和服务健康检查
- 启动自检日志、配置目录与四个持久化挂载点
- runner 提供 `/dev/fuse` 时，通过本地 SFTP 和 WebDAV 服务实际检查 SSHFS、rclone FUSE 与 davfs2 的挂载、读写和卸载
- `/init`、sshd、code-server 和 nginx 的实际运行状态
- `/root/.ssh/authorized_keys`（含只读挂载回退）的真实 SSH 公钥登录、host key 持久化和登录 MOTD
- Tailscale 默认关闭，以及启用但缺少 TUN 时不会影响主服务
- runner 提供 `/dev/net/tun` 时，Tailscale daemon、LocalAPI socket 和主服务的实际运行状态
- 在 runner 提供 `/dev/fuse` 和非特权 user namespace 时，以 `--privileged` 运行并检查 rootless `dockerd` 的 socket、非 root daemon 身份，以及本地 scratch 镜像的构建和运行；能力受限的 runner 会明确跳过这部分集成检查

## GitHub Actions

Pull Request 和 push 都会构建 `linux/amd64` 标准版和 CUDA 版并运行 smoke test。测试通过后再构建 `linux/amd64`、`linux/arm64`；每次非 PR push 都会发布对应分支或标签的标准版和 CUDA 版，默认分支额外发布：

```text
ghcr.io/rabbit-dayi/rabbit-dev-container:latest
ghcr.io/rabbit-dayi/rabbit-dev-container:cuda
```

版本标签的 CUDA 变体使用 `-cuda` 后缀，例如 `v1.2.3-cuda`。

触发条件包括所有分支 push、`v*.*.*` tag、Pull Request 和手动触发。

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

### SSHFS 或 rclone 挂载失败

先检查设备、能力和启动自检：

```bash
docker exec rabbit-dev-container ls -l /dev/fuse
docker exec rabbit-dev-container dev versions
docker exec rabbit-dev-container dev mounts
docker logs rabbit-dev-container 2>&1 | grep '\[startup-check\]'
```

确保容器带有 `/dev/fuse` 与 `SYS_ADMIN`；Compose 可叠加 `compose.fuse.yml`。`fusermount3: permission denied` 通常表示宿主机的 seccomp、AppArmor 或容器设备策略仍在拦截。WebDAV 连通但 rclone 无法写入时，还要检查 remote 是否只读以及 `--vfs-cache-mode writes` 是否启用。

### DNS 或 GitHub 暂时不可用

GitHub SSH key 下载和 Tailscale 配置失败都不会让 SSH/code-server 无限重启。可以修复 Docker DNS，或手工挂载 `/root/.ssh/authorized_keys`；轻量配置保存在 `/root/.rabbit_container`，应用运行数据保存在 `/root/.rabbit-dev-container`。

## 安全说明

- GitHub `.keys` 地址只包含公开 SSH 公钥，不是私钥。
- 不要把 SSH 私钥、GitHub PAT、密码或 `TS_AUTHKEY` 写入 Dockerfile、README、镜像层或提交到 Git。
- 默认 TLS 证书是运行时生成的自签名证书，仅用于开箱访问；公网部署应挂载受信任 CA 签发的证书和私钥。
- auth key 应尽量使用一次性、短期、ephemeral 或受 tag 限制的 key；泄露后立即在 Tailscale 管理控制台吊销。
- 对外暴露 code-server 时应使用强密码，并限制在 Tailscale 或受信任内网中访问。
- 不建议在公网关闭统一认证后直接使用 `CODE_SERVER_AUTH=none`。
- Tailscale 模式本身只需要有限 capabilities，不需要 `privileged: true`。
- rootless Docker-in-Docker 的 daemon 不是外层 root，但该模式的外层容器仍需 `--privileged`；不要将其用于不受信任的代码或多租户环境。
