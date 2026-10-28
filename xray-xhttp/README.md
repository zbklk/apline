# Xray-core · VLESS + XHTTP + REALITY 一键安装

独立的中文交互式一键安装与管理脚本。安装时从 **XTLS/Xray-core 官方 GitHub Releases** 查询最新稳定版；自动识别系统、CPU 架构及服务管理方式。**与仓库根目录的 sing-box 脚本互不影响。**

> 本脚本已完成 Bash 语法检查和本地模拟测试，尚未在实际 VPS 上完成全流程联网安装/客户端连通性验证。请先在测试机上试用，并备份已有配置。

## 一、快速安装（root 用户）

适用于 Debian、Ubuntu、Alpine、Rocky Linux、AlmaLinux 等带有 systemd 或 OpenRC 的 VPS。通过 SSH 登录服务器后执行：

```bash
curl -fsSLo /tmp/xray-xhttp-onekey.sh https://raw.githubusercontent.com/zbklk/apline/main/xray-xhttp/xray-xhttp-onekey.sh && bash /tmp/xray-xhttp-onekey.sh
```

普通用户可以先下载，再以 sudo 运行（请确保有 sudo 权限）：

```bash
curl -fsSLo /tmp/xray-xhttp-onekey.sh https://raw.githubusercontent.com/zbklk/apline/main/xray-xhttp/xray-xhttp-onekey.sh
sudo bash /tmp/xray-xhttp-onekey.sh
```

如果没有 curl，可先安装 curl，或使用 wget 下载后运行：

```bash
wget -O /tmp/xray-xhttp-onekey.sh https://raw.githubusercontent.com/zbklk/apline/main/xray-xhttp/xray-xhttp-onekey.sh && bash /tmp/xray-xhttp-onekey.sh
```

**建议先阅读脚本再以 root 执行。** 一键命令来自本仓库公开的源文件，并不内置专属节点密钥。

## 二、交互菜单

| 编号 | 功能 |
| --- | --- |
| 1 | 一键安装 / 重新生成节点 |
| 2 | 查看节点参数、VLESS 导入链接及可选二维码 |
| 3 | 启动服务 |
| 4 | 停止服务 |
| 5 | 重启服务 |
| 6 | 更新 Xray-core 至官方最新稳定版（保留现有节点信息） |
| 7 | 查看服务日志 |
| 8 | 修改监听端口（保留 UUID / 密钥 / XHTTP 路径） |
| 9 | 卸载本脚本管理的独立实例 |
| 0 | 退出 |

## 三、功能与兼容性

- Linux 发行版：Debian / Ubuntu / Alpine / RHEL / Fedora / Rocky / AlmaLinux / CentOS 等。
- 架构：x86_64、aarch64 / ARM64、ARMv7。
- 服务管理：systemd / OpenRC（未检测到支持的服务管理方式时拒绝安装）。
- 自动下载官方 Xray-core 稳定版；通过 GitHub Release 提供的 SHA-256 摘要验证压缩包。
- 自动生成 UUID、REALITY X25519 密钥、Short ID 和随机 XHTTP 路径。
- 交互设置公网 IP/域名、TCP 端口和 REALITY 目标 SNI；默认端口 443，默认 SNI 为 `www.microsoft.com`。
- 使用 `xray run -test` 验证配置；更新/变更失败时尽可能回滚原配置和二进制。
- 在 UFW 或 firewalld 已启用的情况下尝试放行所选 **TCP** 端口；不自动更改云厂商安全组、iptables 或 nftables。
- XHTTP 模式为 `auto`，使用 VLESS + XHTTP + REALITY，**不启用 `xtls-rprx-vision`**。

## 四、文件位置

| 内容 | 路径 |
| --- | --- |
| 服务名称 | `xray-xhttp` |
| 内核二进制 | `/usr/local/libexec/xray-xhttp/xray` |
| 服务端配置 | `/etc/xray-xhttp/config.json` |
| 节点导入参数 | `/etc/xray-xhttp/node.json` |
| systemd 服务文件 | `/etc/systemd/system/xray-xhttp.service` |
| OpenRC 服务文件 | `/etc/init.d/xray-xhttp` |

脚本不会覆盖标准 `xray`、`sing-box`、`x-ui` 服务，使用独立配置与二进制。若计划与其他节点共存，请选择**未被占用**的 TCP 端口。

## 五、注意事项

1. **务必在服务商安全组中放行选定的 TCP 端口**，同时保留 SSH 管理端口。
2. REALITY 目标站点应支持 TLS 1.3 和 HTTP/2，并适合 REALITY 使用；脚本检查域名格式但无法保证目标站点长期适用。
3. 客户端需要支持 **VLESS + XHTTP + REALITY**；并非所有版本的客户端或官方 sing-box 都支持。
4. 选择“重新生成节点”会替换 UUID、密钥及路径，旧链接失效；升级内核或修改端口不会重新生成密钥。
5. `/etc/xray-xhttp/node.json`、VLESS 链接属于敏感节点信息，请勿上传至 GitHub 或公开分享。
6. 此脚本不会删除此前放行的防火墙端口，也不会管理其他服务。
7. 建议在重要 VPS 上安装前制作快照，保持 SSH 会话可用。
8. 完整测试状态：已通过脚本语法检查与本地模拟校验；未在真实 VPS 上验证所有发行版与连通性。

## 六、官方参考

- [Xray-core](https://github.com/XTLS/Xray-core)
- [官方 XHTTP + REALITY 示例](https://github.com/XTLS/Xray-examples/tree/main/VLESS-XHTTP-Reality/minimal-steal_others)

脚本整理时间：2026-10-28。安装和升级以官方 Release API 当前返回的最新稳定版为准。
