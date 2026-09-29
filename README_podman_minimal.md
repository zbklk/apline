# Alpine / Podman 轻量版 sing-box 一键脚本

适用于磁盘和内存比较紧张的 Alpine Linux 容器/VPS，尤其是 Podman/LXC 一类实例。

这个版本专门解决普通一键脚本在小容器里执行 `apk add` 时被 `Killed` 的问题：

- **不执行 `apk add` / `apk update`**
- **不需要 `openssl`**
- **不需要 `jq`**
- 直接下载 SagerNet 官方 **musl** 版 sing-box 二进制
- 仅部署 **VLESS + Reality（TCP）**，降低依赖和资源占用
- 自动生成 UUID、Reality 密钥和 Short ID
- 自动创建 OpenRC 服务（检测不到完整 OpenRC 时自动回退到后台运行）
- 安装后提供 `sb` 管理命令

默认固定使用 sing-box **1.14.1**，避免自动追踪 alpha/testing 版本。可通过环境变量 `SINGBOX_VERSION` 手动指定其他版本。

## 一键安装

以 `root` 登录 Alpine 服务器后执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zbklk/apline/main/singbox_alpine_podman_minimal.sh)
```

如果机器没有 curl、但有 wget：

```bash
wget -qO /root/sb-install.sh https://raw.githubusercontent.com/zbklk/apline/main/singbox_alpine_podman_minimal.sh
bash /root/sb-install.sh
```

## 安装时会询问

脚本会依次询问：

1. **公网 IP 或域名**：默认自动检测公网 IPv4。
2. **VLESS Reality TCP 端口**：默认 `443`，可以输入任意未占用的 1–65535 TCP 端口。
3. **Reality SNI**：默认 `addons.mozilla.org`。
4. **节点名称**：默认 `Alpine-Reality`。

直接按回车即可接受默认值。

对于 Podman/NAT 实例，特别注意：**公网端口必须在服务商面板映射/放行到容器对应的 TCP 端口**。例如脚本使用 8443，则要确认公网 TCP 8443 能到达容器 TCP 8443；如果公网端口和容器端口不同，客户端应填写公网端口。

## 非交互安装

也可以直接预设参数：

```bash
SERVER_HOST=102.207.40.222 \
PORT=8443 \
REALITY_SNI=addons.mozilla.org \
NODE_NAME=My-Reality \
bash <(curl -fsSL https://raw.githubusercontent.com/zbklk/apline/main/singbox_alpine_podman_minimal.sh)
```

如需指定 sing-box 版本：

```bash
SINGBOX_VERSION=1.14.1 bash <(curl -fsSL https://raw.githubusercontent.com/zbklk/apline/main/singbox_alpine_podman_minimal.sh)
```

## 安装完成后

脚本会直接输出完整 VLESS Reality 导入链接，并保存到：

```text
/root/singbox-node.txt
/etc/sing-box/client-info.txt
```

主要管理命令：

```bash
sb status       # 查看服务状态
sb uri          # 查看节点参数和导入链接
sb restart      # 重启 sing-box
sb stop         # 停止 sing-box
sb start        # 启动 sing-box
sb check        # 校验配置文件
sb version      # 查看 sing-box 版本
sb config       # 查看服务端配置
sb logs         # 查看后台模式日志（如有）
sb uninstall    # 卸载
```

服务端配置文件：

```text
/etc/sing-box/config.json
```

如果重新运行脚本且检测到旧配置，会先备份到：

```text
/root/sing-box-backup-YYYYMMDD-HHMMSS/
```

## 适合的环境

推荐：

- Alpine Linux
- Podman / LXC / 小型容器 VPS
- x86_64 / amd64
- arm64
- armv7
- 386
- 根磁盘约 1 GB 也可以使用，只要剩余空间足够

脚本把下载文件放在 `/root` 临时目录，而不是 `/tmp`，避免某些容器把 `/tmp` 配置为 tmpfs 后额外占用内存。

## 常见问题

### 1. 原来的脚本为什么出现 `Killed`？

如果出现类似：

```text
apk add ...
Killed
```

通常不是 sing-box 本身报错，而是容器里的 `apk` 进程被 cgroup/OOM 杀掉。这个轻量脚本不会执行 `apk add`，所以绕开了这一段。

### 2. `sb status` 显示运行，但客户端连接不上

优先检查：

- 服务商面板是否开放/映射了脚本选择的 TCP 端口；
- 公网 IP 是否填写正确；
- 客户端的 UUID、Public Key、Short ID、SNI 是否与 `sb uri` 输出一致；
- 服务器系统时间是否明显不准确；
- 选择的端口是否被其他服务占用。

### 3. 如何改端口或重新生成节点？

最简单的方法是重新运行一键脚本。旧配置会自动备份，然后重新生成一套 Reality 参数。

## 说明

该脚本只负责部署 sing-box 服务端。请遵守所在地法律法规以及服务器供应商的使用条款。
