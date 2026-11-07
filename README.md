# Tailscale for TOS 7

把 [Tailscale](https://tailscale.com/) 官方静态二进制封装成 **TerraMaster TOS 7**
应用中心的 deb 安装包：装上就能让 NAS 加入你的 tailnet，用固定的 `100.x` 地址从任何
地方访问，**不需要公网 IP、不需要端口映射**。

> 非官方移植包，由 Moechz 打包；与 TerraMaster、Tailscale Inc. 均无隶属关系。

## 特性

- **开箱即用**：桌面图标 → 浏览器登录 → NAS 上线，全程不需要命令行。
- **官方组件**：`tailscaled` / `tailscale` 直接取自上游官方静态包（sha256 钉死，逐字节一致）。
- **最小权限**：以专用非 root 用户 `tailscale` 运行，仅保留 `CAP_NET_ADMIN`、`CAP_NET_RAW`；
  不在 root 下跑守护进程。
- **不额外开端口**：控制台只监听 `127.0.0.1:8088`，经 TOS 网页服务反代到 `/tailscale/`。
- **双架构**：`x86_64`（amd64）与 `aarch64`（arm64）。
- **数据可控**：节点身份保存在 `/var/lib/tailscale`；`apt remove` 保留，`apt purge` 清除。

## 安装

从 [Releases](https://github.com/Moechz/tailscale/releases) 下载对应架构的包：

| 架构 | 资产 |
|---|---|
| x86_64 | `tailscale_x86_64.deb` |
| aarch64 | `tailscale_aarch64.deb` |

然后二选一：

1. **应用中心** → 设置 → 应用 → 手动安装，选择 deb；
2. 命令行：`sudo apt install ./tailscale_x86_64.deb`

装完打开 TOS 桌面上的 **Tailscale** 图标，或在浏览器访问：

```
https://<NAS 的 IP>:5443/tailscale/
```

点「Log in」按提示在 Tailscale 授权页登录，回到控制台即可看到本机上线。

## 使用

- 控制台：状态、登录/登出、Tailscale SSH、子网路由、出口节点、更新。
- 命令行（可选）：

```bash
/usr/local/tailscale/bin/tailscale status
/usr/local/tailscale/bin/tailscale up
/usr/local/tailscale/bin/tailscale ip -4
```

- 从其它设备访问：`ssh <用户名>@<本机 Tailscale IP>`，或直接访问
  `http://<本机 Tailscale IP>:8181/`。

## 配置

- `/usr/local/tailscale/tailscale.env` —— 传给 tailscaled 的 `TS_*` 环境变量（可选）。
- `/etc/systemd/system/tailscale.service` —— 服务单元；改端口/网卡名时复制到
  `/etc/systemd/system/` 再改，`systemctl daemon-reload && systemctl restart tailscale`。
- 状态目录：`/var/lib/tailscale`（`tailscaled.state` 含节点密钥，注意备份与权限）。

### 已知限制

- **MagicDNS 默认关闭**（`--accept-dns=false`）。TOS 的 systemd-resolved 是 uplink 模式，
  `/etc/resolv.conf` 属 `systemd-resolve`，非 root 的 tailscaled 无法安全接管 DNS。
  需要在本机解析 tailnet 名称时，可把 TOS 的 DNS 指向 `100.100.100.100`。
  从**其它设备**访问本机名称不受影响。
- TOS 自带的 `tnas0` 占用 `100.82.124.0/22`（与 Tailscale 的 `100.64.0.0/10` 重叠）。
  若本机被分配的 Tailscale IP 恰好落在该 /22，会出现不可达；重新登录换一个 IP 即可。

## 卸载

```bash
sudo apt remove tailscale    # 保留 /var/lib/tailscale（重装免重新登录）
sudo apt purge tailscale     # 连节点身份一起删除
```

## 从源码构建

```bash
./build.sh info          # 版本 / 架构 / 端口 / 校验值
./build.sh all           # fetch → stage → verify → deb（默认 amd64）
TARGET_ARCH=arm64 ./build.sh all
```

构建只依赖 `bash`、`python3`、`ar`、`xz`、`curl`；**不需要 dpkg/docker**。
二进制来源与校验值见 `config.env` 与 `assets/PROVENANCE.md`。

## 许可

- 打包脚本与本仓库内容：MIT
- 随包二进制：[Tailscale](https://github.com/tailscale/tailscale)，BSD-3-Clause
- 图标：Tailscale 官方标识，仅用于标识本软件（商标归 Tailscale Inc. 所有）

## 隐私

本应用不收集任何用户数据；网络行为与上游一致（协调服务器、DERP 中继）。
详见随包 `privacy-policy.html`。
