# intgrow 一体化部署（btcidx + btcexp + btcexpfr）

使用 Docker Compose 在同一自定义网络 `btcexp-net` 中启动 intgrow 的三个组件：

| 服务 | 组件 | 作用 | 容器端口 | 宿主机端口（可配置） |
|---|---|---|---|---|
| `btcidx` | [`../btcidx`](../btcidx) | Bitcoin 地址索引器 / Electrum 服务器 / REST API | 8080（HTTP）、50001（Electrum TCP）、9090（Metrics） | `PUB_BTCIDX_HTTP_PORT` / `PUB_BTCIDX_ELECTRUM_PORT` / `PUB_BTCIDX_METRICS_PORT` |
| `btcexp` | [`../btcexp`](../btcexp) | 业务 API 层（REST + WebSocket） | 3000 | `PUB_API_PORT` |
| `btcexpfr` | [`../btcexpfr`](../btcexpfr) | 前端 Web UI（nginx，托管 SPA 并代理 API） | 80 | `PUB_WEB_PORT` |
| `redis` | `redis:7-alpine` | 共享缓存（btcexp 与 btcidx 使用） | 6379 | 不对外发布 |

调用链路：

```
浏览器 ──► btcexpfr:80 ──(同源 /api 反代)──► btcexp:3000 ──(REST + Electrum TCP)──► btcidx:8080/50001 ──► bitcoind (宿主机)
                                                     └──────────────► redis:6379 ◄──────────┘
```

`btcexpfr` 的 nginx 把 `/api/`、`/swagger-ui/`、`/api-docs` 反代到 `btcexp:3000`，把 `/price/` 反代到 `PRICE_PROXY`，因此前端与后端同源，无需 CORS。

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

三个组件镜像从 GitHub Container Registry 拉取，无需本地源码或构建，因此本目录可独立部署：`ghcr.io/mattxlee/btcidx`、`ghcr.io/mattxlee/btcexp`、`ghcr.io/mattxlee/btcexpfr`。

---

## 前置条件

1. Docker Engine 与 Compose v2（`docker compose version`）。
2. 一个可用的 **bitcoind**，并开启 JSON-RPC：
   - 各链默认 RPC 端口：mainnet `8332`、signet `38332`、testnet `18332`、regtest `18443`。
   - 建议启用 `txindex=1`。
3. 推荐为 bitcoind 开启 ZMQ（否则 btcidx 回退轮询，仍可用）：
   ```conf
   zmqpubhashblock=tcp://0.0.0.0:28332
   zmqpubhashtx=tcp://0.0.0.0:28332
   zmqpubrawtx=tcp://0.0.0.0:28332
   ```
4. bitcoind 可被容器通过 `host.docker.internal` 访问（compose 已加 `host-gateway` 映射）。

---

## 快速开始

```bash
cd btcexp-docker

# 1. 生成配置并按需修改（RPC 端口、凭据、存储路径、端口等）
cp .env.example .env
$EDITOR .env

# 2. 准备宿主机数据目录并授予容器用户权限（首次必须执行）
mkdir -p "$(sed -n 's/^HOST_BTCIDX_DATA_DIR=//p' .env)" \
         "$(sed -n 's/^HOST_REDIS_DATA_DIR=//p' .env)"
sudo chown -R 10000:10000 data/btcidx    # btcidx 镜像以 UID 10000 运行
sudo chown -R 999:999   data/redis       # redis:7-alpine 以 UID 999 运行

# 3. 拉取 ghcr 镜像并启动
docker compose pull
docker compose up -d

# 4. 查看状态
docker compose ps
docker compose logs -f btcidx
```

首次启动 btcidx 会从 genesis 同步整条链，追平（`utxo_ready=true`）后查询才返回数据；同步期间接口返回 `503`。同步耗时取决于链与磁盘。

### 访问地址

- Web UI：<http://localhost:8088>（由 `PUB_WEB_PORT` 决定）
- btcexp API / Swagger：<http://localhost:3000/swagger-ui/>
- btcidx REST：<http://localhost:8080/api/v1/status>
- btcidx Metrics：<http://localhost:9090/metrics>
- Electrum（钱包可连）：`localhost:50001`

---

## 配置说明（`.env`）

Docker Compose 自身读取该文件做变量插值；同时整个文件也通过 `env_file` 注入 `btcidx` 容器，因此其中所有 `BTCIDX_*` 项即为 btcidx 的配置项。

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
docker compose pull
```

### 存储路径

| 变量 | 默认 | 说明 |
|---|---|---|
| `HOST_BTCIDX_DATA_DIR` | `./data/btcidx` | btcidx RocksDB 数据目录（挂载到容器 `/var/lib/btcidx/data`） |
| `HOST_REDIS_DATA_DIR` | `./data/redis` | Redis 持久化目录（挂载到容器 `/data`） |

相对路径以本 compose 目录为基准。容器内路径固定为 `/var/lib/btcidx/data`，通过 `BTCIDX_STORE_PATH` 指定。

### 网络与端口

| 变量 | 默认 | 说明 |
|---|---|---|
| `NETWORK` | `signet` | 链网络，`mainnet`/`signet`/`testnet`/`regtest`，同时下发给 btcidx 与 btcexp |
| `PUB_WEB_PORT` | `8088` | 前端对外端口（→ 容器 80） |
| `PUB_API_PORT` | `3000` | btcexp 对外端口（→ 容器 3000） |
| `PUB_BTCIDX_HTTP_PORT` | `8080` | btcidx REST 对外端口 |
| `PUB_BTCIDX_ELECTRUM_PORT` | `50001` | btcidx Electrum TCP 对外端口 |
| `PUB_BTCIDX_METRICS_PORT` | `9090` | btcidx Prometheus 对外端口 |

### bitcoind 连接

| 变量 | 默认 | 说明 |
|---|---|---|
| `BTCIDX_RPC_URL` | `http://host.docker.internal:8332` | bitcoind JSON-RPC 地址；**注意按链改端口** |
| `BTCIDX_RPC_USER` / `BTCIDX_RPC_PASS` | `bitcoin` / `change-me` | RPC 用户名密码 |
| `BTCIDX_RPC_COOKIE_FILE` | 注释 | 改用 cookie 认证时：注释掉上面的 USER/PASS，再启用此项 |
| `BTCIDX_ZMQ_ENABLED` | `true` | 是否使用 ZMQ 实时通知 |
| `BTCIDX_ZMQ_ENDPOINT` | `tcp://host.docker.internal:28332` | bitcoind ZMQ 端点 |

### btcidx 调优

`BTCIDX_STORE_CACHE_SIZE_MB`、`BTCIDX_STORE_WRITE_BUFFER_MANAGER_MB`、`BTCIDX_ELECTRUM_MAX_CONNECTIONS`、`BTCIDX_METRICS_ENABLED` 等，完整列表见 [`../btcidx/src/config.rs`](../btcidx/src/config.rs) 与 [`../btcidx/deploy/btcidx.env.example`](../btcidx/deploy/btcidx.env.example)。

> 若使用 cookie 认证：`.env` 中注释掉 `BTCIDX_RPC_USER`/`BTCIDX_RPC_PASS`、启用 `BTCIDX_RPC_COOKIE_FILE` 后需 `docker compose up -d` 重建容器，使变量不再注入。

### btcexp API

| 变量 | 默认 | 说明 |
|---|---|---|
| `RATE_LIMIT_PER_MIN` | `60` | 匿名 IP 限流 |
| `API_KEY` | （空） | 设置后 `/api/v1/*` 需携带 `X-API-Key` |
| `ENABLE_TX_BROADCAST` | `false` | 是否允许 `POST /api/v1/tx` 广播 |
| `TIP_POLL_SECS` | `5` | 链尖轮询间隔 |
| `MAX_LAG_BLOCKS` | `6` | 超过该落后块数 `/ready` 返回 503 |
| `RUST_LOG` | `info` | 日志级别 |

### btcexpfr 前端

| 变量 | 默认 | 说明 |
|---|---|---|
| `PRICE_PROXY` | `https://price.intgrow.com` | `/price/` 行情代理上游 |

> 前端 SEO 的 `canonical`/`sitemap` 使用构建进镜像的公开地址（由发布方的 `VITE_APP_URL` 决定），运行期不可更改。若需不同域名，请使用对应域名构建的镜像。

---

## 常用命令

```bash
docker compose pull                   # 拉取/更新 ghcr 镜像
docker compose up -d                  # 启动全部服务
docker compose up -d --force-recreate btcexp   # 用新镜像重建某个服务
docker compose logs -f btcidx         # 跟踪日志
docker compose ps                     # 查看状态
docker compose restart btcexp         # 重启
docker compose down                   # 停止并删除容器（保留 data/ 数据）
docker compose down -v                # 连同匿名卷一起删除（bind 挂载的数据目录仍在）

# 健康检查
curl -fsS localhost:8080/api/v1/status   # btcidx
curl -fsS localhost:3000/api/v1/ready    # btcexp（同步完成前 503）
curl -fsS localhost:8088/                # 前端

# 清空 btcidx 索引重新同步（危险）
docker compose stop btcidx
sudo rm -rf data/btcidx/* && sudo chown -R 10000:10000 data/btcidx
docker compose up -d btcidx
```

---

## 服务间连接与网络

- 三个组件与 redis 都接入 `btcexp-net` 网络，用**服务名**互相寻址：
  - `btcexp` 通过 `http://btcidx:8080` 与 `btcidx:50001` 访问索引器。
  - `btcexpfr` 通过 `http://btcexp:3000` 反代 API。
  - 两者通过 `redis://redis:6379` 使用共享缓存。
- `nginx.conf` 是 `btcexpfr/nginx.conf` 的覆盖版本：当 `proxy_pass` 使用变量时，nginx 需要 `resolver` 才能在请求时解析主机名；这里把 Docker 内嵌 DNS `127.0.0.11` 放在首位，使服务名 `btcexp` 可解析，同时外部域名（如 `price.intgrow.com`）仍能正常解析。
- bitcoind 在宿主机上，容器通过 `extra_hosts: host.docker.internal:host-gateway` 访问。

---

## 故障排查

**btcexp 报 `btcidx status: error sending request ... 127.0.0.1`**
容器内 `127.0.0.1` 是容器自身。本编排已使用服务名 `http://btcidx:8080`，若自行改动环境变量请勿写回 `127.0.0.1`。

**btcexpfr 返回 502 / nginx 日志 `no resolver defined` 或无法解析 `btcexp`**
确认挂载的 `./nginx.conf` 生效（`docker compose config` 中应有该 bind 挂载），其 `resolver` 指向 `127.0.0.11`。

**btcidx 启动即退出，日志提示存储不可写**
宿主机数据目录权限不足：`sudo chown -R 10000:10000 data/btcidx`（redis 同理 `999:999`）。

**查询返回 503**
btcidx 尚在同步或正处于 reorg。查看 `curl localhost:8080/api/v1/status` 的 `utxo_ready` 与 `tip_height`。

**RPC 认证失败 / 连接被拒**
确认 `BTCIDX_RPC_URL` 的端口与链匹配（signet 为 38332），且 bitcoind 的 `rpcbind`/`rpcallowip` 允许 Docker 网段访问。

**前端行情 502**
`PRICE_PROXY` 不可达或被墙；不影响链上数据功能。

---

## 备注

- 本目录不含 `btcidx` 的前端 `swapper-ui` 构建产物；`BTCIDX_HTTP_STATIC_DIR` 仅用于 btcidx 自带的静态托管，本编排的前端由 `btcexpfr` 提供。若不需要该功能可忽略其 404。
- `data/` 与 `.env` 含运行数据与凭据，请勿提交到版本库。
