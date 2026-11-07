# PROVENANCE —— 构建溯源与可复现说明

本包是 **Tailscale 官方静态二进制的原样重打包**（repackaging），不修改上游代码，
不做 UPX 加壳，不嵌入任何第三方二进制。

## 1. 上游

| 项 | 值 |
|---|---|
| 项目 | Tailscale（BSD-3-Clause） |
| 版本 | 1.104.5（commit `78838476328d1a97dc05400ad23086a9dbe616da`） |
| 官方分发 | `https://pkgs.tailscale.com/stable/tailscale_1.104.5_<arch>.tgz` |
| 源码 | `https://github.com/tailscale/tailscale/tree/v1.104.5` |
| 上游 Release 说明 | `https://github.com/tailscale/tailscale/releases/tag/v1.104.5` |

> 说明：Tailscale 的 GitHub Release **不附二进制资产**，官方唯一分发渠道是
> `pkgs.tailscale.com`。因此本包直接取官方静态包，并以 sha256 双重钉死
> （见 `config.env` 的 `SHA256_TARBALL_AMD64/ARM64`），构建脚本拒绝任何不匹配的下载。

## 2. 二进制清单（与上游逐字节一致）

| 架构 | 资产 | sha256 |
|---|---|---|
| x86_64 | `tailscale_1.104.5_amd64.tgz` | `720cbbccbfc03d8b55df72afc19e5a72e31b0f65934700aa6fa38074d4ad7bf7` |
| aarch64 | `tailscale_1.104.5_arm64.tgz` | `e900b0e6e25023a1e504b2c237ce2a32ea0535e006f8c1a1097a490886493b6c` |

包内 `/usr/local/tailscale/bin/tailscaled` 与 `bin/tailscale` 直接从上述 tar 包解出，
**未做 strip / 未重编译 / 未加壳**。校验方式：

```bash
# 与上游 tarball 内的文件逐字节比对
tar xzOf tailscale_1.104.5_amd64.tgz tailscale_1.104.5_amd64/tailscaled | sha256sum
sha256sum /usr/local/tailscale/bin/tailscaled
```

## 3. 我们改动了什么（仅打包层）

- 新增 TOS 规范文件：`config.ini`、`tailscale.lang`（23 语）、`images/icons/tailscale.svg`、
  `init.d/tailscale.service`、`nginx/tailscale.conf`、`webui.bz2`（入口页）。
- 自写 systemd 单元，替代上游 `tailscaled.service`：改为**专用非 root 用户 + 最小能力**
  （`AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW`），并按 TOS 规范去掉 `Restart=`。
- 新增 `tailscale-web.service`：以同一用户运行上游 `tailscale web`，仅监听 `127.0.0.1:8088`。
- `preinst/postinst`：幂等建用户、创建 TOS 缺失的 `/dev/net/tun` 设备节点、nginx 校验回滚。
- 未修改 `tailscaled` / `tailscale` 二进制的任何行为参数（除命令行 flag 外）。

## 4. 可复现构建

```bash
./build.sh all     # fetch（下载 + sha256 双校验）→ stage → verify → deb
```

构建只需 `bash`、`python3`（tarfile，GNU_FORMAT）、`ar`、`xz`；**不需要 dpkg/docker**。
同版本重复构建产物字节一致（脚本对 tar 成员 uid/gid=0、mtime=0、排序固定）。

## 5. 已知与上游的差异

1. 运行身份：上游默认 root；本包用 `tailscale` 用户 + `CAP_NET_ADMIN/CAP_NET_RAW`。
2. 状态目录：同为 `/var/lib/tailscale`（systemd `StateDirectory=`）。
3. MagicDNS 依赖 systemd-resolved 的 D-Bus 授权，随包提供最小 polkit 规则
   （`/etc/polkit-1/rules.d/49-tailscale-resolved.rules`），仅放行 DNS 相关 action。
4. 控制台入口：上游 `tailscale web` 默认 `localhost:8088`，本包经 TOS nginx 反代到
   `/tailscale/ui/`，并在 `/tailscale/` 提供入口页。
