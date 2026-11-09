# intgrow 拆分部署（btcidx 局域网 + btcexp 外网 + rathole）

本仓库提供**两套相互独立的 Docker Compose 编排**，分别运行在两台主机上：

| 编排文件 | 运行位置 | 服务 | 对外端口 |
|---|---|---|---|
| [`docker-compose.btcidx.yml`](docker-compose.btcidx.yml) | 局域网主机（与 bitcoind 同机） | `btcidx`、`redis`、`rathole-client` | **不发布任何端口**，仅主动外连公网主机 |
| [`docker-compose.btcexp.yml`](docker-compose.btcexp.yml) | 外网（公网）主机 | `btcexp`、`redis`、`rathole-server` | `127.0.0.1:PUB_WEB_PORT`（Web UI/`/ws`）与 `RATHOLE_CONTROL_PORT`（隧道控制端口） |

btcexp 通过 [rathole](https://github.com/rapiz1/rathole) 隧道访问 btcidx 的 REST
（`:8080`）与 Electrum TCP（`:50001`）。隧道由局域网侧的 `rathole-client`
**主动外连**公网侧的 `rathole-server`，因此局域网不需要任何公网入站端口。

```
浏览器
   │  https（反向代理）
   ▼
┌─ 外网主机 docker-compose.btcexp.yml ──────────────────────────────┐
│  btcexp:3000 ──────────────► redis:6379   （btcexp 自己的缓存）   │
│      │                                                            │
│      ├── REST     http://rathole-server:5202 ─┐                   │
│      └── Electrum rathole-server:5203 ────────┤                   │
│                                    rathole-server                 │
│                                     ▲ :2333 控制端口（发布到宿主机）│
└─────────────────────────────────────┼─────────────────────────────┘
                                      │ Noise 加密隧道（LAN 主动外连）
┌─ 局域网主机 docker-compose.btcidx.yml ┼───────────────────────────┐
│                                rathole-client                     │
│                                     │                             │
│                     ┌───────────────┴───────────────┐             │
│                     ▼                               ▼             │
│  btcidx:8080（REST）/ :50001（Electrum） ──► redis:6379（btcidx 缓存）│
│      │                                                            │
│      └──► bitcoind（宿主机，JSON-RPC + ZMQ）                      │
└───────────────────────────────────────────────────────────────────┘
```

> **为什么 Redis 两边各放一个？**
> btcidx 与 btcexp 都各自使用 Redis 作为缓存：btcidx 缓存 tx/header/merkle
> 证明，btcexp 缓存自己的响应。原来的单机编排让两者共享一个 Redis；拆分后
> 跨公网共享缓存只会增加延迟和故障域，因此每套编排各带一个本地 Redis。
> 两者都可以不配置 Redis：btcidx 会降级为“无缓存”，btcexp 回退到进程内内存
> 缓存。当前编排默认两边都启用。

> **历史说明**
> 原 `btcexpfr` 前端已并入 btcexp；旧的单文件 `docker-compose.yml` 已拆分为
> 上面的两套编排，迁移方法见文末。

---

## 目录结构

```
btcexp-docker/
├── docker-compose.btcidx.yml       # 局域网主机：btcidx + redis + rathole-client
├── docker-compose.btcexp.yml       # 外网主机：btcexp + redis + rathole-server
├── env/
│   ├── btcidx-mainnet.env.example  # 局域网主机配置模板
│   ├── btcidx-testnet4.env.example
│   ├── btcexp-mainnet.env.example  # 外网主机配置模板
│   └── btcexp-testnet4.env.example
├── rathole/
│   ├── client.toml.example         # 局域网侧隧道配置模板
│   └── server.toml.example         # 外网侧隧道配置模板
└── README.md
```

`.env`、`data/`、真实的 `rathole/*.toml` 均已加入 `.gitignore`，不要提交。

---

## 前置条件

1. 两台主机均安装 Docker Engine 与 Compose v2（`docker compose version`）。
2. 局域网主机上有一个可用的 **bitcoind**：
   - 常见 RPC 端口：mainnet `8332`、signet `38332`、传统 testnet3 `18332`、
     testnet4 `48332`、regtest `18443`；始终以节点实际配置为准。
   - 建议启用 `txindex=1`。
   - RPC 只允许 Docker 网段访问（`rpcbind` / `rpcallowip`），不要暴露到公网。
3. 推荐为 bitcoind 开启 ZMQ（否则 btcidx 回退轮询，仍可用）。ZMQ 没有认证，
   不要绑定到 `0.0.0.0` 或公网接口；请绑定到 Docker 网桥或其他仅供容器访问的
   私有接口。

   在对应 bitcoind 实例的 `bitcoin.conf` 中设置三类通知，例如主网：
   ```conf
   # 将 <docker-bridge-ip> 替换为该宿主机供容器访问的私有地址。
   zmqpubhashblock=tcp://<docker-bridge-ip>:28332
   zmqpubhashtx=tcp://<docker-bridge-ip>:28332
   zmqpubrawtx=tcp://<docker-bridge-ip>:28332
   ```
   三个通知可以、也应当使用**同一个**地址和端口：它们是同一个 ZMQ 发布端点上
   的不同主题，不需要为每种通知单独开端口。

   命令行启动 bitcoind 时，配置项名称前必须加 `-`：
   ```bash
   bitcoind \
     -zmqpubhashblock=tcp://<docker-bridge-ip>:28332 \
     -zmqpubhashtx=tcp://<docker-bridge-ip>:28332 \
     -zmqpubrawtx=tcp://<docker-bridge-ip>:28332
   ```
   同机运行 mainnet 和 testnet4 时，两个 **bitcoind 实例之间**必须使用不同的
   ZMQ 端口（例如 testnet4 用 `28333`）；同一实例的三类通知仍可共用端口。
4. bitcoind 可被容器通过 `host.docker.internal` 访问（btcidx 编排已加
   `host-gateway` 映射）。
5. 外网主机的防火墙允许局域网主机访问 `RATHOLE_CONTROL_PORT`（默认 `2333`）。
   这是外网主机**唯一**新增的入站端口，应尽量只放行局域网主机的公网出口地址。
   外网主机还需能访问外部 BTC 报价服务（`PRICE_API_URL`）。

---

## rathole 隧道准备

rathole 的客户端与服务端使用同名服务条目、共享 token，并用 Noise 协议加密
并认证隧道。两端配置中的服务名必须完全一致。

### 1. 生成密钥与 token（只需一次，可任选一台主机执行）

```bash
# Noise 密钥对：服务端保存 Private Key，客户端配置 Public Key。
docker run --rm rapiz1/rathole:v0.5.0 --genkey

# 共享 token：两端 default_token 必须相同。
openssl rand -hex 32
```

> 不要使用任何示例或网上公开的密钥。

### 2. 外网主机：rathole 服务端配置

```bash
sudo install -d -m 700 /etc/btcexp
sudo install -m 600 rathole/server.toml.example /etc/btcexp/btcexp-mainnet-rathole.toml
sudoedit /etc/btcexp/btcexp-mainnet-rathole.toml
```

填写：

- `[server].default_token`：上一步生成的 token。
- `[server.transport.noise].local_private_key`：`--genkey` 输出的 Private Key。
- `[server.services.*].bind_addr`：保持 `5202`（REST）与 `5203`（Electrum）；
  btcexp 固定使用 `rathole-server:5202` / `:5203`。这些端口只在 Docker 网络内
  可达，不会发布到宿主机。
- `[server].bind_addr` 保持 `0.0.0.0:2333`，与 Compose 中容器端口一致。

### 3. 局域网主机：rathole 客户端配置

```bash
sudo install -m 600 rathole/client.toml.example /etc/btcexp/btcidx-mainnet-rathole.toml
sudoedit /etc/btcexp/btcidx-mainnet-rathole.toml
```

填写：

- `[client].remote_addr`：外网主机的域名或 IP + 其发布的控制端口
  （如 `explorer.example.com:2333`）。
- `[client].default_token`：与服务端相同。
- `[client.transport.noise].remote_public_key`：`--genkey` 输出的 Public Key。
- `[client.services.*].local_addr`：保持 `btcidx:8080` / `btcidx:50001`（容器内
  服务名，不是 `127.0.0.1`）。

> 多实例（mainnet/testnet4）使用各自的 token 与密钥对，并分别指定不同的
> rathole 配置文件。两套隧道互不影响。

---

## 部署步骤

先启动局域网侧（btcidx），再启动外网侧（btcexp）。rathole 客户端会自动重连，
启动顺序并非强制要求，但 btcidx 就绪后 btcexp 立即有可用上游。

### A. 局域网主机（btcidx）

```bash
cd btcexp-docker

# 1. 私有环境文件与数据目录（首次执行）。
sudo install -d -m 700 /etc/btcexp
sudo install -m 600 env/btcidx-mainnet.env.example /etc/btcexp/btcidx-mainnet.env
sudoedit /etc/btcexp/btcidx-mainnet.env
#    按需修改 COMPOSE_PROJECT_NAME、BTCIDX_ENV_FILE（必须等于此文件的绝对
#    路径）、RATHOLE_CONFIG_FILE、数据目录与 RPC/ZMQ 配置。

sudo mkdir -p /srv/btcexp/mainnet/{btcidx,redis}
sudo chown -R 10000:10000 /srv/btcexp/mainnet/btcidx
sudo chown -R 999:999 /srv/btcexp/mainnet/redis

# 2. 启动（只拉取镜像，不构建）。
docker compose -f docker-compose.btcidx.yml \
  --env-file /etc/btcexp/btcidx-mainnet.env -p btcidx-mainnet pull
docker compose -f docker-compose.btcidx.yml \
  --env-file /etc/btcexp/btcidx-mainnet.env -p btcidx-mainnet up -d

# 3. 检查。
docker compose -f docker-compose.btcidx.yml \
  --env-file /etc/btcexp/btcidx-mainnet.env -p btcidx-mainnet ps
docker compose -f docker-compose.btcidx.yml \
  --env-file /etc/btcexp/btcidx-mainnet.env -p btcidx-mainnet logs -f btcidx rathole-client
```

首次启动 btcidx 会从 genesis 同步整条链，追平（`utxo_ready=true`）后查询才返回
数据；同步期间接口返回 `503`。

### B. 外网主机（btcexp）

```bash
cd btcexp-docker

sudo install -d -m 700 /etc/btcexp
sudo install -m 600 env/btcexp-mainnet.env.example /etc/btcexp/btcexp-mainnet.env
sudoedit /etc/btcexp/btcexp-mainnet.env
#    RATHOLE_CONFIG_FILE 指向服务端 rathole 配置；
#    RATHOLE_CONTROL_PORT 与客户端 remote_addr 的端口一致；
#    APP_URL / GA_ID / PRICE_* / API_* 按站点设置。

sudo mkdir -p /srv/btcexp/mainnet/redis
sudo chown -R 999:999 /srv/btcexp/mainnet/redis

docker compose -f docker-compose.btcexp.yml \
  --env-file /etc/btcexp/btcexp-mainnet.env -p btcexp-mainnet pull
docker compose -f docker-compose.btcexp.yml \
  --env-file /etc/btcexp/btcexp-mainnet.env -p btcexp-mainnet up -d
```

### 验证整条链路

```bash
# btcexp 自身的健康与就绪（/ready 在 btcidx 追平前返回 503）。
curl -fsS http://127.0.0.1:8088/health
curl -fsS http://127.0.0.1:8088/ready

# 通过隧道直接查询 btcidx 的 REST 状态，验证 rathole 两端都正常。
docker compose -f docker-compose.btcexp.yml \
  --env-file /etc/btcexp/btcexp-mainnet.env -p btcexp-mainnet \
  exec btcexp curl -fsS http://rathole-server:5202/api/v1/status
```

### 访问地址

- Web UI：<http://localhost:8088/>（由 `PUB_WEB_PORT` 决定）。默认只绑定
  `127.0.0.1`，供本机 TLS 反向代理转发；若要让 btcexp 直接提供 HTTP，将
  `PUB_WEB_BIND` 设为 `0.0.0.0`（或某个具体网卡地址），见下方“对外提供
  HTTP 的方式”
- 健康检查：`/health`、`/ready`（含 indexer lag）、`/metrics`（Prometheus）
- 实时提示：页面自动连接 `ws://localhost:8088/ws?topics=blocks,mempool`
- JSON API（仅 `API_ENABLED=true`）：`/api/v1/*`、`/swagger-ui/`

### 对外提供 HTTP 的方式

btcexp 容器内固定监听 `0.0.0.0:3000`（如需改动可在编排中加入
`BIND_ADDR`，同时相应修改 `ports` 的容器端口）。能否从外部访问只取决于
`ports` 的宿主机地址与端口：

1. **TLS 反向代理（推荐）**：保持默认 `PUB_WEB_BIND=127.0.0.1`，由同机的
   nginx/Caddy 转发到 `http://127.0.0.1:8088`。反向代理必须转发
   `Upgrade`/`Connection` 头，否则 `/ws` 实时提示不可用。
2. **btcexp 直接提供 HTTP**：在外网主机的环境文件中设置
   ```env
   PUB_WEB_BIND=0.0.0.0     # 或某个具体网卡 IP
   PUB_WEB_PORT=8088
   ```
   重建容器后在防火墙放行该端口，访问 `http://<主机>:8088/`。注意此方式没有
   TLS；若使用 Cloudflare 等 CDN 终止 TLS，请关闭其缓存对 `/ws` 的干扰，并让
   源站只接受 CDN 回源地址。
3. **路由器/NAT 端口映射**：主机位于 NAT 后时，同样需要
   `PUB_WEB_BIND=0.0.0.0`，再把外网端口转发到该主机的 `PUB_WEB_PORT`。

多个实例在同一台外网主机上时，`PUB_WEB_BIND` 可以相同，但 `PUB_WEB_PORT`
必须不同（如 mainnet `8088`、testnet4 `8089`）。

---

## 配置说明

Compose 通过 `--env-file` 读取环境文件做变量插值。btcidx 编排还会把该文件整体
注入 `btcidx` 容器（`BTCIDX_ENV_FILE`），因此其中的 `BTCIDX_*` 即该实例的
RPC/ZMQ 配置；`BTCIDX_ENV_FILE` 必须等于 `--env-file` 的绝对路径。

### 局域网主机（btcidx）

| 变量 | 默认 | 说明 |
|---|---|---|
| `COMPOSE_PROJECT_NAME` | `btcidx` | Compose 项目名；每个实例唯一 |
| `BTCIDX_ENV_FILE` | `.env` | 注入 btcidx 的环境文件；必须等于 `--env-file` 路径 |
| `HOST_BTCIDX_DATA_DIR` | `./data/btcidx` | btcidx RocksDB 数据目录（挂载到 `/var/lib/btcidx/data`） |
| `HOST_REDIS_DATA_DIR` | `./data/redis` | 本机 Redis 持久化目录（挂载到 `/data`） |
| `IMAGE_TAG` | `latest` | intgrow 镜像标签（可固定为具体版本） |
| `BTCIDX_IMAGE` | `ghcr.io/mattxlee/btcidx` | btcidx 镜像（一般无需修改） |
| `NETWORK` | `signet` | `mainnet`/`signet`/`testnet`/`regtest`；Bitcoin Core testnet4 用 `testnet` |
| `RATHOLE_CONFIG_FILE` | `./rathole/client.toml` | rathole 客户端配置（含 token 与公钥） |
| `RATHOLE_IMAGE` / `RATHOLE_VERSION` | `rapiz1/rathole` / `v0.5.0` | 隧道镜像 |
| `BTCIDX_RPC_URL` | `http://host.docker.internal:8332` | bitcoind JSON-RPC 地址（按链改端口） |
| `BTCIDX_RPC_USER` / `BTCIDX_RPC_PASS` | `bitcoin` / `change-me` | RPC 凭据 |
| `BTCIDX_RPC_COOKIE_FILE` | 注释 | 改用 cookie 认证时启用，并注释掉 USER/PASS |
| `BTCIDX_ZMQ_ENABLED` | `true` | 是否使用 ZMQ 实时通知 |
| `BTCIDX_ZMQ_ENDPOINT` | `tcp://host.docker.internal:28332` | bitcoind ZMQ 端点 |

> cookie 认证：注释掉 `BTCIDX_RPC_USER`/`BTCIDX_RPC_PASS`、启用
> `BTCIDX_RPC_COOKIE_FILE` 后，用同一组参数 `up -d` 重建容器，使变量不再注入。

### 外网主机（btcexp）

| 变量 | 默认 | 说明 |
|---|---|---|
| `COMPOSE_PROJECT_NAME` | `btcexp` | Compose 项目名；每个实例唯一 |
| `HOST_REDIS_DATA_DIR` | `./data/redis` | 本机 Redis 持久化目录 |
| `IMAGE_TAG` | `latest` | intgrow 镜像标签 |
| `BTCEXP_IMAGE` | `ghcr.io/mattxlee/btcexp` | btcexp 镜像（一般无需修改） |
| `NETWORK` | `signet` | 必须与局域网侧 `NETWORK` 一致 |
| `PUB_WEB_PORT` | `8088` | btcexp 的 Web UI / `/ws` / ops 端口（宿主机侧） |
| `PUB_WEB_BIND` | `127.0.0.1` | 宿主机侧绑定地址；`0.0.0.0` 或具体 IP 表示直接对外提供 HTTP，默认仅回环供反向代理使用 |
| `RATHOLE_CONFIG_FILE` | `./rathole/server.toml` | rathole 服务端配置（含私钥与 token） |
| `RATHOLE_CONTROL_PORT` | `2333` | 发布到宿主机的隧道控制端口；每个实例唯一，且客户端 `remote_addr` 必须指向它 |
| `APP_URL` | 空 | 对外站点根地址（无尾斜杠），用于 canonical/OG、`robots.txt`、`sitemap.xml`；为空则保持相对路径并禁用 sitemap |
| `GA_ID` | 空 | GA4 measurement ID；为空不加载统计脚本 |
| `PRICE_API_URL` / `PRICE_INST_ID` | `https://price.intgrow.com` / `BTC-USDT` | BTC 报价端点；`PRICE_API_URL` 为空则首页价格卡片显示“—” |
| `MAINNET_URL` / `TESTNET4_URL` | 空 | 顶栏网络切换链接；为空隐藏对应链接 |
| `API_ENABLED` / `API_KEY` | `false` / 空 | 挂载 `/api/v1/*` 与 Swagger；对外暴露时应同时设置 `API_KEY` |
| `WS_MAX_CONNS_PER_IP` | 由镜像默认 `5` | 每 IP 并发 `/ws` 连接上限 |
| `ELECTRUM_CONNECT_TIMEOUT_SECS` / `ELECTRUM_READ_TIMEOUT_SECS` | `10` / `20` | 可选；隧道 RTT 较高时可调大 Electrum 连接/读取超时 |

### 固定的内部配置

写死在编排文件中，通常无需修改：

- btcidx：容器内存储 `/var/lib/btcidx/data`、HTTP `:8080`、Electrum `:50001`、
  Redis `redis://redis:6379`、日志级别、`nofile` 65536。
- btcexp：监听 `0.0.0.0:3000`、`INDEXER_BACKEND=btcidx`、上游
  `http://rathole-server:5202` 与 `rathole-server:5203`、Redis
  `redis://redis:6379`。
- rathole 服务端：控制端口容器内固定 `2333`，服务端口固定 `5202`/`5203`；
  只有控制端口发布到宿主机。
- 局域网编排不发布任何端口；外网编排只发布 `PUB_WEB_BIND:PUB_WEB_PORT`
  （默认 `127.0.0.1`）与 `RATHOLE_CONTROL_PORT`。

如需调整这些值，请直接修改对应的 `docker-compose.*.yml` 与 rathole 配置。

---

## 同时部署 mainnet 与 testnet4

四个模板分别对应两台主机上的两个实例：

| 主机 | 实例 | 模板 | 项目名 | 端口 |
|---|---|---|---|---|
| 外网 | mainnet | `env/btcexp-mainnet.env.example` | `btcexp-mainnet` | Web `8088`，控制 `2333` |
| 外网 | testnet4 | `env/btcexp-testnet4.env.example` | `btcexp-testnet4` | Web `8089`，控制 `2334` |
| 局域网 | mainnet | `env/btcidx-mainnet.env.example` | `btcidx-mainnet` | 无发布端口 |
| 局域网 | testnet4 | `env/btcidx-testnet4.env.example` | `btcidx-testnet4` | 无发布端口 |

要点：

- 每个实例使用**独立的**数据目录、Redis 目录、项目名与 rathole 配置
  （各自的 token 与密钥对）。两个 btcidx 绝不能共享 RocksDB 目录，两个 Redis
  也绝不能共享持久化目录。
- testnet4 的 `NETWORK=testnet`（Bitcoin Core 的链实例叫 testnet4，应用配置值
  是通用的 `testnet`）。
- 两个实例的 bitcoind RPC/ZMQ 端口、隧道控制端口都必须不同。
- 反向代理使用不同上游：`mainnet.example.com` → `127.0.0.1:8088`，
  `testnet4.example.com` → `127.0.0.1:8089`。

---

## 常用命令

以下以 mainnet 为例。局域网侧把 `-f` / `-p` / `--env-file` 换成 btcidx 对应值。

```bash
# 外网主机
COMPOSE=(docker compose -f docker-compose.btcexp.yml \
         --env-file /etc/btcexp/btcexp-mainnet.env -p btcexp-mainnet)
"${COMPOSE[@]}" pull                          # 拉取/更新镜像
"${COMPOSE[@]}" up -d                          # 启动全部服务
"${COMPOSE[@]}" up -d --force-recreate btcexp  # 用新镜像重建某个服务
"${COMPOSE[@]}" logs -f btcexp rathole-server  # 跟踪日志
"${COMPOSE[@]}" ps                             # 查看状态
"${COMPOSE[@]}" down                           # 停止并删除容器（保留数据目录）

# 局域网主机
COMPOSE=(docker compose -f docker-compose.btcidx.yml \
         --env-file /etc/btcexp/btcidx-mainnet.env -p btcidx-mainnet)
"${COMPOSE[@]}" logs -f btcidx rathole-client
"${COMPOSE[@]}" ps

# 通过隧道检查 btcidx 状态（在外网主机执行）
docker compose -f docker-compose.btcexp.yml \
  --env-file /etc/btcexp/btcexp-mainnet.env -p btcexp-mainnet \
  exec btcexp curl -fsS http://rathole-server:5202/api/v1/status

# 清空 mainnet btcidx 索引重新同步（危险；在局域网主机执行）
"${COMPOSE[@]}" stop btcidx
sudo rm -rf /srv/btcexp/mainnet/btcidx/* && sudo chown -R 10000:10000 /srv/btcexp/mainnet/btcidx
"${COMPOSE[@]}" up -d btcidx
```

---

## 故障排查

**btcexp 无法连接 btcidx / 返回 502 或上游不可用**
先看两侧隧道日志。外网主机 `logs rathole-server`，局域网主机 `logs
rathole-client`。常见原因：

- 客户端 `remote_addr` 指向的域名/端口错误，或外网防火墙未放行
  `RATHOLE_CONTROL_PORT`；
- 两端 `default_token` 不一致（日志会提示认证失败）；
- Noise 密钥不匹配：服务端 `local_private_key` 与客户端 `remote_public_key`
  必须来自同一次 `rathole --genkey`；
- 两端服务名不一致（见 rathole `.toml` 中的 `[*.services.btcidx-http]` 与
  `[*.services.btcidx-electrum]`）。

**隧道正常但页面返回 503**
btcidx 尚在同步或正处于 reorg。用上面的 `exec btcexp curl … /api/v1/status`
查看 `utxo_ready` 与 `tip_height`。

**最近区块/内存池页面没有自动提示**
确认浏览器能连上 `ws://<host>:<port>/ws`；反向代理需转发 `Upgrade`/`Connection`
头。断线与 `lagged` 会显示提示并计数（`ws_lagged_total`）。

**`/api/v1/*` 返回 404**
这是默认行为。需要 API 时在外网主机的环境文件中设置 `API_ENABLED=true` 并重建
btcexp 容器；对外暴露时同时设置 `API_KEY`。

**btcidx 启动即退出，日志提示存储不可写**
宿主机数据目录权限不足：`sudo chown -R 10000:10000 /srv/btcexp/mainnet/btcidx`
（Redis 目录为 `999:999`）。

**RPC 认证失败 / 连接被拒**
确认 `BTCIDX_RPC_URL` 的端口与 `NETWORK` 匹配，且 bitcoind 的
`rpcbind`/`rpcallowip` 允许 Docker 网段访问。btcidx 只运行在局域网主机上，
RPC 端点使用 `host.docker.internal` 即可。

**Redis 启动日志提示 `Memory overcommit must be enabled`**
宿主机内核参数 `vm.overcommit_memory=0` 导致的告警，Redis 容器无法修改它。在两台
主机上分别执行并持久化：

```bash
echo 'vm.overcommit_memory = 1' | sudo tee /etc/sysctl.d/99-redis-overcommit.conf
sudo sysctl --system
```

Redis 只作为各自栈内的缓存；出现该告警时最坏情况是后台 RDB 保存失败、缓存丢失
（可自动重建），不影响 btcidx 的索引数据。

**高延迟**
隧道本身引入公网 RTT。页面与 `/ws` 通常不受影响；若 Electrum 查询超时，可在
btcexp 编排中适当提高 `ELECTRUM_CONNECT_TIMEOUT_SECS` /
`ELECTRUM_READ_TIMEOUT_SECS`（镜像默认 10s/20s）。这些不是必填项。

---

## 从旧单机编排迁移

旧版本只有一个 `docker-compose.yml`，三个服务在同一主机、同一网络。拆分后：

1. 在旧主机上停止旧项目（项目名以旧环境文件中的 `COMPOSE_PROJECT_NAME` 为准）：
   ```bash
   docker compose -p btcexp-mainnet down
   ```
   数据目录（如 `/srv/btcexp/mainnet/btcidx`）保留。
2. 把旧环境文件的内容拆成两份：
   - `BTCIDX_*`、`HOST_BTCIDX_DATA_DIR`、`NETWORK` → 局域网主机的
     `btcidx-<instance>.env`；
   - `PUB_WEB_PORT`、`APP_URL`、`GA_ID`、`PRICE_*`、`MAINNET_URL`、
     `TESTNET4_URL`、`API_*`、`HOST_REDIS_DATA_DIR` → 外网主机的
     `btcexp-<instance>.env`。
3. 在局域网主机沿用原 btcidx 数据目录（`chown 10000:10000` 保持不变）；旧的
   Redis 目录只属于旧共享缓存，可保留或清空。外网主机需要新建一个空的 Redis
   目录（`chown 999:999`）。
4. 生成 rathole 密钥/token 并按上文配置两端，然后先启动 btcidx 编排，再启动
   btcexp 编排。

---

## 备注

- 各组件镜像均从 GHCR 拉取；rathole 从 Docker Hub 拉取。本目录不含源码，可独立
  部署。
- `btcexpfr` 已废弃：旧部署中的该服务、`nginx.conf` 和 `BTCEXPFR_IMAGE` 变量
  可删除。
- 真实的 `rathole/*.toml` 含隧道 token 与私钥，`.env` 含凭据，`data/` 含运行
  数据，均不应提交到版本库。
