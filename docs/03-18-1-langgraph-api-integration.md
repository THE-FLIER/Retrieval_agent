# LangGraph 项目 API 接入说明

当前项目在运行 `langgraph dev` 后，会在 **http://127.0.0.1:8123** 暴露 LangGraph 服务，交互式 API 文档在 **http://127.0.0.1:8123/docs**。

## 一、基本概念

- **Base URL**：`http://127.0.0.1:8123`（本地 dev 默认端口，以你实际启动为准）
- **API 文档**：`http://127.0.0.1:8123/docs`（OpenAPI/Swagger）
- **本项目的两个图（Assistants）**：在 `langgraph.json` 中定义，对应接口里的 `assistant_id`：
  - `indexer`：索引图，用于上传文档并建索引
  - `retrieval_graph`：检索对话图，基于已索引文档做问答

本地开发环境一般**不需要** `X-Api-Key`；若部署到 LangSmith 等环境，需在请求头中加上 `X-Api-Key`。

---

## 二、常用接口

### 1. 创建会话（Thread）

创建一条会话，后续「在会话上跑图」的请求都会用这个 `thread_id`。

```bash
curl -X POST "http://127.0.0.1:8123/threads" \
  -H "Content-Type: application/json" \
  -d '{}'
```

响应示例：

```json
{
  "thread_id": "550e8400-e29b-41d4-a716-446655440000",
  "created_at": "...",
  "updated_at": "...",
  "metadata": {},
  "status": "idle"
}
```

### 2. 在会话上流式执行（Thread Run Stream）

在指定 thread 上调用某个图（assistant），并以流式返回结果。

**检索对话图 `retrieval_graph`**（用户发一条消息，得到回复）：

```bash
curl -X POST "http://127.0.0.1:8123/threads/{thread_id}/runs/stream" \
  -H "Content-Type: application/json" \
  -d '{
    "assistant_id": "retrieval_graph",
    "input": {
      "messages": [
        {"role": "human", "content": "你好，我的猫会 Python 吗？"}
      ]
    },
    "stream_mode": "updates",
    "config": {
      "configurable": {
        "user_id": "user-001"
      }
    }
  }'
```

- `assistant_id`：固定为 `retrieval_graph`（本项目对话图）
- `input.messages`：本轮用户输入，LangChain 消息格式，通常用 `role` + `content`
- `stream_mode`：可选 `updates`（按节点更新）、`values`（完整状态）、`messages`（仅消息）等，见 `/docs` 中的说明
- `config.configurable.user_id`：用于检索时按用户过滤文档，必填

**索引图 `indexer`**（上传文档建索引）：

```bash
curl -X POST "http://127.0.0.1:8123/threads/{thread_id}/runs/stream" \
  -H "Content-Type: application/json" \
  -d '{
    "assistant_id": "indexer",
    "input": {
      "docs": [
        {"page_content": "My cat knows python."},
        {"page_content": "I have 1 cat."}
      ]
    },
    "stream_mode": "updates",
    "config": {
      "configurable": {
        "user_id": "user-001"
      }
    }
  }'
```

- `assistant_id`：固定为 `indexer`
- `input.docs`：文档列表，每项可为 `{"page_content": "..."}` 或直接字符串 `"一段文字"`
- `config.configurable.user_id`：这些文档归属的用户 ID，检索时会按此过滤

### 3. 无状态执行（Stateless Run，可选）

若不需要保留会话状态，可直接调用「无状态」执行接口（若你的部署开放了该端点）：

- 接口形态类似 `/runs/stream`，但不需要先创建 thread，每次请求独立执行。
- 具体路径与参数以 **http://127.0.0.1:8123/docs** 中 “Stateless Runs” 为准。

---

## 三、Python 接入示例

### 方式一：使用 `requests`（不依赖 LangGraph SDK）

```python
import requests

BASE = "http://127.0.0.1:8123"

# 1. 创建 thread
r = requests.post(f"{BASE}/threads", json={})
thread_id = r.json()["thread_id"]

# 2. 先索引文档（indexer）
requests.post(
    f"{BASE}/threads/{thread_id}/runs/stream",
    json={
        "assistant_id": "indexer",
        "input": {
            "docs": [{"page_content": "My cat knows python."}]
        },
        "stream_mode": "updates",
        "config": {"configurable": {"user_id": "user-001"}},
    },
    stream=True,
)

# 3. 再在同一个 thread 上做检索问答（retrieval_graph）
resp = requests.post(
    f"{BASE}/threads/{thread_id}/runs/stream",
    json={
        "assistant_id": "retrieval_graph",
        "input": {
            "messages": [{"role": "human", "content": "我的猫会什么？"}]
        },
        "stream_mode": "updates",
        "config": {"configurable": {"user_id": "user-001"}},
    },
    stream=True,
)
for line in resp.iter_lines():
    if line:
        print(line.decode("utf-8"))
```

### 方式二：使用 `langgraph-sdk`（需安装）

```bash
uv add langgraph-sdk
```

```python
import asyncio
from langgraph_sdk import get_client

async def main():
    client = get_client(url="http://127.0.0.1:8123")

    # 创建 thread
    thread = await client.threads.create()
    thread_id = thread["thread_id"]

    # 流式执行 retrieval_graph
    async for chunk in client.runs.stream(
        thread_id,
        "retrieval_graph",
        input={
            "messages": [{"role": "human", "content": "我的猫会什么？"}]
        },
        config={"configurable": {"user_id": "user-001"}},
        stream_mode="updates",
    ):
        print(chunk)

asyncio.run(main())
```

---

## 四、本项目的 Input / Config 对照

| 图名 (assistant_id) | 用途           | input 主要字段 | config.configurable 必填 |
|--------------------|----------------|----------------|---------------------------|
| `indexer`          | 上传文档建索引 | `docs`: `[{ "page_content": "..." }]` 或 `["string"]` | `user_id` |
| `retrieval_graph`  | 检索问答       | `messages`: `[{ "role": "human", "content": "..." }]` | `user_id` |

- 检索图会按 `user_id` 只检索该用户索引过的文档，因此索引和问答时请使用**同一个** `user_id`。
- 更多参数（如 `stream_mode`、超时等）以 **http://127.0.0.1:8123/docs** 中对应接口为准。

---

## 五、推荐接入步骤

1. 浏览器打开 **http://127.0.0.1:8123/docs**，确认服务已启动。
2. 在文档中查看 **Threads**、**Thread Runs**（或 **Stateless Runs**）的请求体 schema。
3. 先用 **indexer** + 固定 `user_id` 索引几条文档。
4. 再用 **retrieval_graph** + 同一 `user_id` 发 `messages` 做一次流式调用，验证返回。
5. 按需在请求头中增加 `X-Api-Key`（部署到远程/ LangSmith 时）。

以上即当前 LangGraph 项目 API 的接入方式；具体字段与枚举以本地 **http://127.0.0.1:8123/docs** 为准。
