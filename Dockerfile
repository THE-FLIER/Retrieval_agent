FROM python:3.12-slim

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

# Install uv
RUN pip install uv

WORKDIR /app

# Copy dependency files first for better caching
COPY pyproject.toml uv.lock* ./

# Create virtual environment and install dependencies only (not the project itself)
RUN uv sync --frozen --no-dev --no-install-project
ENV PATH="/app/.venv/bin:$PATH"

# Install langgraph-cli for running the server
RUN uv pip install "langgraph-cli[inmem]"

# Copy source code and config
COPY src/ ./src/
COPY langgraph.json ./

# Add src to PYTHONPATH so retrieval_graph module can be found
ENV PYTHONPATH="/app/src"

# Create non-root user for security
RUN useradd -m -u 1000 appuser && chown -R appuser:appuser /app
USER appuser

EXPOSE 8123

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8123/info || exit 1

# Start LangGraph server
CMD ["langgraph", "dev", "--host", "0.0.0.0", "--port", "8123"]
