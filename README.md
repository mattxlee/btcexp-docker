# intgrow 一体化部署（btcidx + btcexp + btcexpfr）

使用 Docker Compose 在同一自定义网络 `btcexp-net` 中启动 intgrow 的三个组件，镜像从 GitHub Container Registry（`ghcr.io/mattxlee/*`）拉取，无需本地源码或构建。**仅前端 Web 网关发布到宿主机回环地址**，其余服务仅在内部网络互相访问。若需要从宿主机外访问，请由 TLS 反向代理转发该回环端口。

| 服务 | 组件 | 作用 | 对外暴露 |
|---|---|---|---|
| `btcexpfr` | [`../btcexpfr`](../btcexpfr) | 前端 Web UI（nginx），托管 SPA 并同源反代 API | ✅ 容器 80 → 宿主机 `127.0.0.1:PUB_WEB_PORT` |
| `btcexp` | [`../btcexp`](../btcexp) | 业务 API 层（REST + WebSocket） | ❌ 仅内部 `:3000` |
| `btcidx` | [`../btcidx`](../btcidx) | Bitcoin 地址索引器 / Electrum 服务器 / REST | ❌ 仅内部 `:8080`、`:50001` |
| `redis` | `redis:7-alpine` | 共享缓存 | ❌ 仅内部 `:6379` |

调用链路：

```
浏览器 ──► btcexpfr:80 ──(同源 /api 反代)──► btcexp:3000 ──(REST + Electrum TCP)──► btcidx:8080/50001 ──► bitcoind (宿主机)
                                                     └──────────────► redis:6379 ◄──────────┘
```

`btcexpfr` 的 nginx 把 `/api/`、`/swagger-ui/`、`/api-docs` 反代到 `btcexp:3000`，把 `/price/` 反代到价格上游，因此前端与后端同源，无需 CORS，也无需对外暴露 API 端口。

---

## 目录结构

```
btcexp-docker/
├── docker-compose.yml        # 编排定义
├── .env.example              # 配置模板（复制为 .env）
├── .env                      # 实际生效的配置（含凭据，勿提交）
├── nginx.conf                # btcexpfr 的 nginx 模板覆盖（修正 Docker DNS）
└── README.md
```

---

## 前置条件

1. Docker Engine 与 Compose v2（`docker compose version`）。
2. 一个可用的 **bitcoind**，并开启 JSON-RPC：
   - 常见 RPC 端口：mainnet `8332`、signet `38332`、传统 testnet3 `18332`、testnet4 `48332`、regtest `18443`；始终以节点实际配置为准。
   - 建议启用 `txindex=1`。
3. 推荐为 bitcoind 开启 ZMQ（否则 btcidx 回退轮询，仍可用）。ZMQ 没有认证；不要绑定到 `0.0.0.0` 或公网接口。请绑定到 Docker 网桥或其他仅供容器访问的私有接口（地址因宿主机、rootless Docker/Podman 和自定义网络而异）。

   在对应 bitcoind 实例的 `bitcoin.conf` 中设置三类通知，例如主网：
   ```conf
   # 将 <docker-bridge-ip> 替换为该宿主机供容器访问的私有地址。
   zmqpubhashblock=tcp://<docker-bridge-ip>:28332
   zmqpubhashtx=tcp://<docker-bridge-ip>:28332
   zmqpubrawtx=tcp://<docker-bridge-ip>:28332
   ```
   三个通知可以、也应当使用**同一个**地址和端口：它们是同一个 ZMQ 发布端点上的不同主题，不需要为每种通知单独开端口。

   若通过命令行启动 bitcoind，配置项名称前必须加 `-`：
   ```bash
   bitcoind \
     -zmqpubhashblock=tcp://<docker-bridge-ip>:28332 \
     -zmqpubhashtx=tcp://<docker-bridge-ip>:28332 \
     -zmqpubrawtx=tcp://<docker-bridge-ip>:28332
   ```
   修改 `bitcoin.conf` 后重启对应 bitcoind 实例；使用命令行参数时，重启命令时带上这些参数。随后在该部署的环境文件中使用相同端点：
   ```env
   BTCIDX_ZMQ_ENABLED=true
   BTCIDX_ZMQ_ENDPOINT=tcp://host.docker.internal:28332
   ```

   同机运行 mainnet 和 testnet4 时，两个 **bitcoind 实例之间**必须使用不同的 ZMQ 端口；例如 testnet4 可使用 `28333`。同一个 testnet4 实例的三类通知仍可共用该端口：
   ```conf
   # testnet4 的 bitcoin.conf
   zmqpubhashblock=tcp://<docker-bridge-ip>:28333
   zmqpubhashtx=tcp://<docker-bridge-ip>:28333
   zmqpubrawtx=tcp://<docker-bridge-ip>:28333
   ```
   对应的命令行形式为 `-zmqpubhashblock=tcp://<docker-bridge-ip>:28333`、`-zmqpubhashtx=tcp://<docker-bridge-ip>:28333` 和 `-zmqpubrawtx=tcp://<docker-bridge-ip>:28333`。并将 testnet4 环境文件中的 `BTCIDX_ZMQ_ENDPOINT` 设为 `tcp://host.docker.internal:28333`。确认实际监听地址和端口后再启动 Compose。
4. bitcoind 可被容器通过 `host.docker.internal` 访问（compose 已加 `host-gateway` 映射）。RPC 也应通过 `rpcbind` / `rpcallowip` 仅允许 Docker 网段，而不应暴露到公网。

---

## 快速开始

```bash
cd btcexp-docker

# 1. 将模板复制到 checkout 外的私有路径并按需修改。
sudo install -d -m 700 /etc/btcexp
sudo install -m 600 .env.example /etc/btcexp/signet.env
sudoedit /etc/btcexp/signet.env
# 将 BTCIDX_ENV_FILE 改为 /etc/btcexp/signet.env，并设置唯一的
# COMPOSE_PROJECT_NAME、数据目录、Web 端口和 bitcoind RPC/ZMQ 配置。

# 2. 准备该实例的数据目录并授予容器用户权限（首次必须执行）。
sudo mkdir -p /srv/btcexp/signet/{btcidx,redis}
sudo chown -R 10000:10000 /srv/btcexp/signet/btcidx
sudo chown -R 999:999 /srv/btcexp/signet/redis

# 3. 显式指定配置文件和项目名，拉取镜像并启动。
docker compose --env-file /etc/btcexp/signet.env -p btcexp-signet pull
docker compose --env-file /etc/btcexp/signet.env -p btcexp-signet up -d

# 4. 查看该实例的状态。
docker compose --env-file /etc/btcexp/signet.env -p btcexp-signet ps
docker compose --env-file /etc/btcexp/signet.env -p btcexp-signet logs -f btcidx
```

首次启动 btcidx 会从 genesis 同步整条链，追平（`utxo_ready=true`）后查询才返回数据；同步期间接口返回 `503`。同步耗时取决于链与磁盘。

### 访问地址

- Web UI：<http://localhost:8088>（由 `PUB_WEB_PORT` 决定）
- Swagger UI（经前端同源反代）：<http://localhost:8088/swagger-ui/>

btcexp、btcidx、redis 均不对外发布端口，只能通过上述 Web 网关或容器内部访问。Web 网关本身仅监听宿主机 `127.0.0.1`；从其他机器访问时，请配置 TLS 反向代理。

---

## 配置说明（`.env`）

仅保留部署相关、必须由用户决定的设置；其余参数在 `docker-compose.yml` 中固定。

Docker Compose 通过 `--env-file` 读取该文件做变量插值；`BTCIDX_ENV_FILE` 必须设置为同一个绝对路径，Compose 才会把该文件注入 `btcidx` 容器。因此其中的 `BTCIDX_*`（RPC/ZMQ）项即为该实例的 btcidx 连接配置。单实例兼容方式仍可复制 `.env.example` 为 `.env` 并保留默认 `BTCIDX_ENV_FILE=.env`。

### 存储路径

| 变量 | 默认 | 说明 |
|---|---|---|
| `HOST_BTCIDX_DATA_DIR` | `./data/btcidx` | btcidx RocksDB 数据目录（挂载到容器 `/var/lib/btcidx/data`） |
| `HOST_REDIS_DATA_DIR` | `./data/redis` | Redis 持久化目录（挂载到容器 `/data`） |

相对路径以本 compose 目录为基准。多实例部署必须使用不重叠的**绝对路径**；两个 btcidx 绝不能共享 RocksDB 目录，两个 Redis 实例也绝不能共享持久化目录。

### 容器镜像

| 变量 | 默认 | 说明 |
|---|---|---|
| `IMAGE_TAG` | `latest` | 三个 intgrow 镜像统一使用的标签（可固定为具体版本，如 `v1.2.3`） |
| `BTCIDX_IMAGE` | `ghcr.io/mattxlee/btcidx` | btcidx 镜像名（一般无需修改） |
| `BTCEXP_IMAGE` | `ghcr.io/mattxlee/btcexp` | btcexp 镜像名（一般无需修改） |
| `BTCEXPFR_IMAGE` | `ghcr.io/mattxlee/btcexpfr` | btcexpfr 镜像名（一般无需修改） |

完整镜像引用为 `${*_IMAGE}:${IMAGE_TAG}`。若 GHCR 包为私有，需先登录：

```bash
echo "$GHCR_TOKEN" | docker login ghcr.io -u <github-user> --password-stdin
docker compose --env-file /etc/btcexp/mainnet.env -p btcexp-mainnet pull
```

### 网络与端口

| 变量 | 默认 | 说明 |
|---|---|---|
| `COMPOSE_PROJECT_NAME` | `btcexp` | Compose 项目名；每个实例必须唯一，用于隔离容器与网络 |
| `BTCIDX_ENV_FILE` | `.env` | 注入 `btcidx` 的环境文件；必须等于启动时 `--env-file` 的同一文件（外部文件使用绝对路径） |
| `NETWORK` | `signet` | 链网络，`mainnet`/`signet`/`testnet`/`regtest`，同时下发给 btcidx 与 btcexp，必须与 bitcoind 一致；Bitcoin Core testnet4 使用 `testnet` |
| `PUB_WEB_PORT` | `8088` | 唯一宿主机发布端口：前端 Web UI（仅绑定 `127.0.0.1`，容器端口固定为 80）；每个实例必须不同 |

### bitcoind 连接

| 变量 | 默认 | 说明 |
|---|---|---|
| `BTCIDX_RPC_URL` | `http://host.docker.internal:8332` | bitcoind JSON-RPC 地址；**注意按链改端口**。testnet4 常见默认值是 `48332`（以节点实际配置为准，不要沿用 testnet3 的 `18332`） |
| `BTCIDX_RPC_USER` / `BTCIDX_RPC_PASS` | `bitcoin` / `change-me` | RPC 用户名密码 |
| `BTCIDX_RPC_COOKIE_FILE` | 注释 | 改用 cookie 认证时：注释掉上面的 USER/PASS，再启用此项 |
| `BTCIDX_ZMQ_ENABLED` | `true` | 是否使用 ZMQ 实时通知 |
| `BTCIDX_ZMQ_ENDPOINT` | `tcp://host.docker.internal:28332` | bitcoind ZMQ 端点 |

> 若使用 cookie 认证：所选实例环境文件中注释掉 `BTCIDX_RPC_USER`/`BTCIDX_RPC_PASS`、启用 `BTCIDX_RPC_COOKIE_FILE` 后，使用该实例对应的 `docker compose --env-file … -p … up -d` 重建容器，使变量不再注入。

### 固定的内部配置

以下内容无需用户干预，已写死在 `docker-compose.yml`：

- btcidx：容器内存储路径 `/var/lib/btcidx/data`、HTTP `:8080`、Electrum TCP `:50001`、Redis 缓存地址、日志级别。
- btcexp：绑定 `0.0.0.0:3000`、索引后端 `btcidx`、上游 `btcidx:8080` / `btcidx:50001`、Redis 地址、限流/日志等使用内置默认值。
- btcexpfr：`API_PROXY=http://btcexp:3000`、`PRICE_PROXY=https://price.intgrow.com`。
- 除 `PUB_WEB_PORT` 外不发布任何端口；该 Web 端口仅绑定宿主机 `127.0.0.1`。若需从宿主机外访问，请由 TLS 反向代理转发；btcidx 的 Prometheus 指标默认关闭。

如需调整这些值，请直接修改 `docker-compose.yml`。

---

## 同时部署 mainnet 与 testnet4

使用同一份 checkout 时，为每个链创建一个 checkout 外的私有环境文件。仓库中的
[`env/mainnet.env.example`](env/mainnet.env.example) 与
[`env/testnet4.env.example`](env/testnet4.env.example) 是无凭据模板。

```bash
cd btcexp-docker
sudo install -d -m 700 /etc/btcexp
sudo install -m 600 env/mainnet.env.example /etc/btcexp/mainnet.env
sudo install -m 600 env/testnet4.env.example /etc/btcexp/testnet4.env
sudoedit /etc/btcexp/mainnet.env
sudoedit /etc/btcexp/testnet4.env

# 目录不能共享；按模板创建后设置镜像运行用户的权限。
sudo mkdir -p /srv/btcexp/mainnet/{btcidx,redis} \
              /srv/btcexp/testnet4/{btcidx,redis}
sudo chown -R 10000:10000 /srv/btcexp/mainnet/btcidx /srv/btcexp/testnet4/btcidx
sudo chown -R 999:999 /srv/btcexp/mainnet/redis /srv/btcexp/testnet4/redis

# 每条链使用不同项目名，因此拥有独立容器和 btcexp-net 网络。
docker compose --env-file /etc/btcexp/mainnet.env -p btcexp-mainnet up -d
docker compose --env-file /etc/btcexp/testnet4.env -p btcexp-testnet4 up -d
```

主网模板使用 `NETWORK=mainnet`、`127.0.0.1:8088` 和
`/srv/btcexp/mainnet/*`；testnet4 模板使用 `NETWORK=testnet`、
`127.0.0.1:8089` 和 `/srv/btcexp/testnet4/*`。`testnet4` 是 Bitcoin Core
链实例的名称，而 btcexp/btcidx 的应用配置值是通用的 `testnet`。

两个环境文件都必须设置其自身的 `COMPOSE_PROJECT_NAME` 与
`BTCIDX_ENV_FILE`，后者需与 `--env-file` 指定的绝对路径相同。每个实例还
必须指向自己的 bitcoind RPC/ZMQ 端点；不要共享 RPC/ZMQ 端口、认证信息或数据
目录。ZMQ 仍须只绑定 Docker 网桥或其他私有接口。

反向代理应使用不同上游，例如 `mainnet.example.com` → `127.0.0.1:8088`，
`testnet4.example.com` → `127.0.0.1:8089`。两个端口都仍然只绑定到宿主机回环地址。

---

## 常用命令

以下以 `/etc/btcexp/mainnet.env` 与 `btcexp-mainnet` 为例。对 testnet4 请将两者
替换为 `/etc/btcexp/testnet4.env` 与 `btcexp-testnet4`；不要省略这两个实例标识。

```bash
COMPOSE=(docker compose --env-file /etc/btcexp/mainnet.env -p btcexp-mainnet)
"${COMPOSE[@]}" pull                         # 拉取/更新 ghcr 镜像
"${COMPOSE[@]}" up -d                         # 启动全部服务
"${COMPOSE[@]}" up -d --force-recreate btcexp # 用新镜像重建某个服务
"${COMPOSE[@]}" logs -f btcidx                # 跟踪日志
"${COMPOSE[@]}" ps                            # 查看状态
"${COMPOSE[@]}" restart btcexp                # 重启
"${COMPOSE[@]}" down                          # 停止并删除容器（保留数据目录）

# 健康检查（通过容器内网络访问，无需对外端口）
"${COMPOSE[@]}" exec btcexp curl -fsS http://127.0.0.1:3000/api/v1/ready # btcexp（同步完成前 503）
"${COMPOSE[@]}" exec btcexp curl -fsS http://btcidx:8080/api/v1/status    # btcidx
curl -fsS http://127.0.0.1:8088/                                            # 前端

# 清空 mainnet btcidx 索引重新同步（危险；替换为本实例的实际目录）
"${COMPOSE[@]}" stop btcidx
sudo rm -rf /srv/btcexp/mainnet/btcidx/* && sudo chown -R 10000:10000 /srv/btcexp/mainnet/btcidx
"${COMPOSE[@]}" up -d btcidx
```

---

## 服务间连接与网络

- 四个容器都接入 `btcexp-net` 网络，用**服务名**互相寻址：
  - `btcexp` 通过 `http://btcidx:8080` 与 `btcidx:50001` 访问索引器。
  - `btcexpfr` 通过 `http://btcexp:3000` 反代 API。
  - btcexp 与 btcidx 通过 `redis://redis:6379` 使用共享缓存。
- `nginx.conf` 是 `btcexpfr/nginx.conf` 的覆盖版本：当 `proxy_pass` 使用变量时，nginx 需要 `resolver` 才能在请求时解析主机名；这里把 Docker 内嵌 DNS `127.0.0.11` 放在首位，使服务名 `btcexp` 可解析，同时外部域名（如 `price.intgrow.com`）仍能正常解析。
- bitcoind 在宿主机上，容器通过 `extra_hosts: host.docker.internal:host-gateway` 访问。

---

## 故障排查

**btcexp 无法连接 btcidx / 返回 502**
本编排使用服务名 `http://btcidx:8080`，容器内不要写 `127.0.0.1`（那是容器自身）。

**btcexpfr 返回 502 / nginx 日志 `no resolver defined` 或无法解析 `btcexp`**
确认挂载的 `./nginx.conf` 生效（`docker compose config` 中应有该 bind 挂载），其 `resolver` 指向 `127.0.0.11`。

**btcidx 启动即退出，日志提示存储不可写**
宿主机数据目录权限不足：`sudo chown -R 10000:10000 data/btcidx`（redis 同理 `999:999`）。

**查询返回 503**
btcidx 尚在同步或正处于 reorg。用 `docker compose exec btcexp curl -fsS http://btcidx:8080/api/v1/status` 查看 `utxo_ready` 与 `tip_height`。

**RPC 认证失败 / 连接被拒**
确认 `BTCIDX_RPC_URL` 的端口与 `NETWORK` 匹配（signet 为 38332），且 bitcoind 的 `rpcbind`/`rpcallowip` 允许 Docker 网段访问。

**前端行情 502**
价格上游 `https://price.intgrow.com` 不可达；不影响链上数据功能。

---

## 备注

- 三个组件镜像均从 GHCR 拉取，本目录不含源码，可独立部署。
- `data/` 与 `.env` 含运行数据和凭据，请勿提交到版本库。
