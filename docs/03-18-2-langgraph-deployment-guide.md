# LangGraph 原生 API 项目部署方案

> 适用于不使用 FastAPI 重封装、直接使用 langgraph-cli 内置 HTTP 服务的项目。

## 核心架构

```
[客户端] → HTTP/WS → [langgraph dev :8123] → [Graph 逻辑] → [Elasticsearch / LLM]
```

langgraph-cli 内置了符合 LangGraph Platform 规范的 REST + WebSocket 服务器，无需手动编写路由。

---

## 项目结构

```
project/
├── src/
│   └── your_graph/
│       ├── __init__.py
│       ├── graph.py          # graph = StateGraph(...).compile()
│       ├── index_graph.py    # 可选：索引 graph
│       ├── configuration.py
│       ├── state.py
│       └── utils.py
├── langgraph.json            # 注册 graph 入口
├── pyproject.toml
├── uv.lock
├── Dockerfile
├── docker-compose.yml
└── .env
```

> **约定**：源码必须放在 `src/` 目录下，因为容器中使用 `PYTHONPATH=/app/src` 解析模块。

---

## 关键配置文件

### langgraph.json

注册所有 Graph 的入口，格式为 `"graph_id": "文件路径:变量名"`。

```json
{
  "$schema": "https://langgra.ph/schema.json",
  "dependencies": ["."],
  "graphs": {
    "indexer": "./src/your_graph/index_graph.py:graph",
    "your_graph": "./src/your_graph/graph.py:graph"
  },
  "env": ".env"
}
```

### pyproject.toml

`langgraph-cli` 仅用于开发和容器启动，放在 `dev` 依赖组，不污染生产依赖。

```toml
[project]
name = "your-graph"
version = "0.0.1"
requires-python = ">=3.10"
dependencies = [
    "langgraph>=1.0.0,<2.0.0",
    "langchain-openai>=0.1.22",
    # ... 其他业务依赖
]

[build-system]
requires = ["setuptools>=73.0.0", "wheel"]
build-backend = "setuptools.build_meta"

[tool.setuptools.package-dir]
"your_graph" = "src/your_graph"

[dependency-groups]
dev = [
    "langgraph-cli[inmem]>=0.1.71",
    "pytest>=8.3.5",
]
```

### Dockerfile

```dockerfile
FROM python:3.12-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

# 用 pip 安装 uv 包管理器
RUN pip install uv

WORKDIR /app

# 先拷贝依赖文件（利用 Docker 层缓存）
COPY pyproject.toml uv.lock* ./

# 只安装依赖，不安装项目本身（避免 protobuf 版本冲突）
RUN uv sync --frozen --no-dev --no-install-project
ENV PATH="/app/.venv/bin:$PATH"

# 单独安装 langgraph-cli（含运行时服务器）
RUN uv pip install "langgraph-cli[inmem]"

# 拷贝源码和配置
COPY src/ ./src/
COPY langgraph.json ./

# 用 PYTHONPATH 替代 pip install -e .，避免 protobuf 降级冲突
ENV PYTHONPATH="/app/src"

# 非 root 用户运行（安全）
RUN useradd -m -u 1000 appuser && chown -R appuser:appuser /app
USER appuser

EXPOSE 8123

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8123/info || exit 1

# 启动服务（注意：是 langgraph dev，不是 langgraph up）
CMD ["langgraph", "dev", "--host", "0.0.0.0", "--port", "8123"]
```

### docker-compose.yml

以下为包含 Elasticsearch 的完整示例，可按需裁剪。

```yaml
services:
  your-agent:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: your-agent
    restart: unless-stopped
    ports:
      - "8123:8123"
    environment:
      - OPENAI_API_KEY=${OPENAI_API_KEY}
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
      - ELASTICSEARCH_URL=http://elasticsearch:9200
      - ELASTICSEARCH_USER=elastic
      - ELASTICSEARCH_PASSWORD=${ELASTIC_PASSWORD:-changeme}
      - LANGSMITH_PROJECT=${LANGSMITH_PROJECT:-your-agent}
      - LANGSMITH_API_KEY=${LANGSMITH_API_KEY:-}
    depends_on:
      elasticsearch:
        condition: service_healthy
    networks:
      - agent-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8123/info"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s

  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.12.0
    container_name: elasticsearch
    restart: unless-stopped
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=true
      - xpack.security.http.ssl.enabled=false
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD:-changeme}
      - "ES_JAVA_OPTS=-Xms512m -Xmx512m"
    ports:
      - "9200:9200"
    volumes:
      - elasticsearch_data:/usr/share/elasticsearch/data
    networks:
      - agent-network
    healthcheck:
      test: ["CMD-SHELL", "curl -s -u elastic:${ELASTIC_PASSWORD:-changeme} http://localhost:9200/_cluster/health || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

volumes:
  elasticsearch_data:
    driver: local

networks:
  agent-network:
    driver: bridge
```

### .env 模板

```env
OPENAI_API_KEY=your_openai_key
ANTHROPIC_API_KEY=
ELASTIC_PASSWORD=changeme
LANGSMITH_PROJECT=your-agent
LANGSMITH_API_KEY=
```

> ⚠️ `.env` 必须加入 `.gitignore`，禁止提交真实密钥。

---

## 部署操作

### 首次启动

```bash
# 构建镜像并后台启动所有服务
docker compose up -d --build

# 查看服务状态
docker compose ps

# 查看应用日志
docker compose logs -f your-agent

# 验证服务健康
curl http://localhost:8123/info
```

### 日常更新

```bash
# 代码有改动时重新构建并滚动更新
docker compose up -d --build your-agent

# 仅重启服务（无代码改动）
docker compose restart your-agent
```

### 停止服务

```bash
# 停止并保留数据卷
docker compose down

# 停止并删除数据卷（慎用）
docker compose down -v
```

---

## LangGraph 内置 API 端点

服务启动后自动提供以下标准接口：

| 方法 | 路径 | 说明 |
|------|------|------|
| `GET` | `/info` | 服务信息、版本 |
| `GET` | `/assistants` | 列出所有注册的 graph |
| `POST` | `/threads` | 创建会话线程 |
| `POST` | `/threads/{id}/runs` | 发起一次运行（同步） |
| `POST` | `/threads/{id}/runs/stream` | 流式运行（SSE） |
| `GET` | `/threads/{id}/runs/{run_id}` | 查询运行状态 |

调用示例：

```bash
# 查看服务信息
curl http://localhost:8123/info

# 创建线程并发起对话
curl -X POST http://localhost:8123/threads \
  -H "Content-Type: application/json" \
  -d '{}'

curl -X POST http://localhost:8123/threads/{thread_id}/runs \
  -H "Content-Type: application/json" \
  -d '{
    "assistant_id": "your_graph",
    "input": {
      "messages": [{"role": "user", "content": "你好"}]
    }
  }'
```

---

## 踩坑记录

| 坑 | 现象 | 正确做法 |
|---|---|---|
| 使用 `langgraph up --host` | `Error: No such option: --host` | 改用 `langgraph dev --host 0.0.0.0 --port 8123` |
| 使用 `pip install -e .` 安装项目 | protobuf 被降到 5.x，与 langgraph-api 需要的 6.x 冲突，启动报 `VersionError` | 改用 `ENV PYTHONPATH="/app/src"` |
| `uv sync` 不加 `--no-install-project` | 构建阶段 `src/` 还未拷贝，报 `package directory does not exist` | 加 `--no-install-project`，依赖先装，src 后拷贝 |
| 忘记 `--no-dev` | dev 依赖（ruff、pytest 等）被装入镜像，体积虚大 | 加 `--no-dev` |

---

## 本地开发

```bash
# 安装依赖（含 dev）
uv sync

# 启动本地开发服务器（支持热重载）
langgraph dev

# 访问 LangGraph Studio（可视化调试）
# 浏览器打开 https://smith.langchain.com/studio/?baseUrl=http://localhost:8123
```

---

## 新项目复用 Checklist

- [ ] 源码放在 `src/your_graph/` 目录下
- [ ] `graph.py` 末尾暴露 `graph = builder.compile()` 变量
- [ ] `langgraph.json` 中注册正确的文件路径和 graph 变量名
- [ ] `pyproject.toml` 的 `[tool.setuptools.package-dir]` 映射 `your_graph = src/your_graph`
- [ ] `langgraph-cli[inmem]` 放在 `[dependency-groups] dev` 中
- [ ] `Dockerfile` 使用 `uv sync --frozen --no-dev --no-install-project` + `PYTHONPATH=/app/src`
- [ ] 启动命令为 `langgraph dev --host 0.0.0.0 --port 8123`
- [ ] `.env` 加入 `.gitignore`
