# dlang_mcp - D Language MCP Server

MCP (Model Context Protocol) server for D language tools with semantic package search.

## Status
- mostly vibe coded in a day
- only tested on linux
- PR's welcome
- actually not really sure if correctly used by the LLM or really useful
- if you have something better, please tell me

## Features

### Code Analysis Tools
- **dscanner** - Static code analysis for D
- **dfmt** - Code formatting
- **ctags_search** - Symbol definition search
- **compile_check** - Compile-check D source code without linking (syntax, type errors)
- **ddoc_analyze** - Project-wide DDoc documentation analysis via DMD JSON

### Build & Project Tools
- **build_project** - Build a D/dub project with structured error reporting
- **run_tests** - Run dub project tests with structured pass/fail results
- **run_project** - Run a D/dub project, passing arguments to the built program
- **fetch_package** - Fetch a package from the dub registry by name
- **upgrade_dependencies** - Upgrade project dependencies to latest allowed versions
- **analyze_project** - Analyze project structure (dependencies, source files, modules)

### Code Navigation Tools
- **get_module_outline** - Get a structured outline of all symbols in a D source file
- **list_project_modules** - List all modules in a project with their public API

### Semantic Search Tools (require database)
- **search_packages** - Search D packages by name/description
- **search_functions** - Search D functions by signature/docs
- **search_types** - Search classes/structs/interfaces
- **search_examples** - Search code examples
- **get_imports** - Get import statements for symbols

### Status
- **get_feature_status** - Check which runtime features are enabled

## Quick Start

### Prerequisites
- DMD 2.100+ or LDC
- dub package manager
- dscanner and dfmt (for code analysis tools)
- SQLite 3.40+ with FTS5 support

### Build

```bash
dub build
```

### One-Command Setup

```bash
chmod +x setup.sh && ./setup.sh
```

This builds the project, installs optional components (sqlite-vec, ONNX), and ingests example packages. Use `--skip-onnx` for a minimal TF-IDF-only setup, or `--skip-packages` to skip package ingestion.

### Minimal Manual Setup

```bash
# 1. Build
dub build

# 2. Initialize database
./bin/dlang_mcp --init-db

# 3. Ingest some packages
./bin/dlang_mcp --ingest --package=phobos
./bin/dlang_mcp --ingest --package=intel-intrinsics

# 4. Train TF-IDF embeddings
./bin/dlang_mcp --train-embeddings

# 5. Run the MCP server
./bin/dlang_mcp
```

For semantic search with neural embeddings (ONNX) or vector similarity (sqlite-vec), see [Semantic Search Setup](#semantic-search-setup-optional) below.

## MCP Client Configuration

### Claude Desktop

Add to `~/.config/claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "dlang": {
      "command": "/path/to/dlang_mcp/bin/dlang_mcp"
    }
  }
}
```

### opencode

Add to `~/.config/opencode/opencode.json`:

```json
{
  "mcp": {
    "dlang-mcp": {
      "type": "local",
      "command": ["/path/to/dlang_mcp/bin/dlang_mcp"],
      "enabled": true
    }
  }
}
```

### Zed

Add to `~/.config/zed/settings.json`:

```json
{
  "context_servers": {
    "dlang-mcp": {
      "command": {
        "path": "/path/to/dlang_mcp/bin/dlang_mcp",
        "args": []
      },
      "settings": {}
    }
  }
}
```

## Security

### Authentication

When running in HTTP mode, you can require bearer token authentication:

```bash
./bin/dlang_mcp --http --auth-token=my-secret-token
```

Clients must include the `Authorization: Bearer my-secret-token` header on all requests. The `/health` endpoint is excluded from authentication.

### Path Sandboxing

By default, all file and directory access is restricted to the current working directory. You can change the allowed root:

```bash
./bin/dlang_mcp --sandbox-root=/home/user/projects
```

### HTTPS / TLS

The MCP server listens on plain HTTP. For production deployments, place a reverse proxy in front to handle TLS termination.

**nginx example:**

```nginx
server {
    listen 443 ssl;
    server_name mcp.example.com;

    ssl_certificate     /etc/letsencrypt/live/mcp.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/mcp.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 86400;  # SSE connections are long-lived
    }
}
```

**Caddy example (automatic TLS):**

```
mcp.example.com {
    reverse_proxy 127.0.0.1:3000
}
```

### CORS

When serving browser-based MCP clients, set the allowed origin:

```bash
./bin/dlang_mcp --http --cors-origin=http://localhost:8080
```

### Rate Limiting

HTTP mode includes built-in per-IP rate limiting (100 requests per 60-second window). Requests exceeding the limit receive HTTP 429.

### Process Timeout

All subprocess executions (compiler, dscanner, dfmt, etc.) are limited to a configurable timeout:

```bash
./bin/dlang_mcp --timeout=60  # 60 seconds (default: 30)
```

## Command Line Reference

```bash
# Run as MCP server (default)
./bin/dlang_mcp

# Initialize the search database
./bin/dlang_mcp --init-db

# Show database statistics
./bin/dlang_mcp --stats

# Ingest a single package from code.dlang.org
./bin/dlang_mcp --ingest --package=silly

# Ingest all packages from code.dlang.org
./bin/dlang_mcp --ingest

# Ingest with limit and fresh start
./bin/dlang_mcp --ingest --limit=50 --fresh

# Show ingestion progress
./bin/dlang_mcp --ingest-status

# Build vector embeddings
./bin/dlang_mcp --train-embeddings

# Mine usage patterns from indexed data
./bin/dlang_mcp --mine-patterns

# Test search with a query
./bin/dlang_mcp --test-search="hash table lookup"

# Show help
./bin/dlang_mcp --help
```

## Semantic Search Setup (Optional)

The search tools work out of the box with TF-IDF keyword search. For better results, you can optionally enable vector similarity search and/or neural embeddings.

### sqlite-vec (Vector Similarity)

Enables vector-based semantic similarity search beyond keyword matching.

**Build from source:**

```bash
cd /tmp
git clone https://github.com/asg017/sqlite-vec
cd sqlite-vec
make loadable
cp dist/vec0.so /path/to/dlang_mcp/data/models/
```

**Or use an environment variable:**

```bash
export SQLITE_VEC_PATH=/path/to/vec0.so
./bin/dlang_mcp --init-db
```

Auto-detection paths:
- `data/models/vec0.so` (Linux) / `vec0.dylib` (macOS) / `vec0.dll` (Windows)
- `/usr/local/lib/vec0.*`
- `/usr/lib/vec0.*`

Verify with `./bin/dlang_mcp --init-db` — should show "Vector search enabled (sqlite-vec)".

### ONNX Embeddings (Neural Search)

For semantic embeddings using the all-MiniLM-L6-v2 model:

```bash
# Download ONNX model and vocabulary
wget -O data/models/model.onnx \
  https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/main/onnx/model.onnx
wget -O data/models/vocab.txt \
  https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/raw/main/vocab.txt

# Install ONNX Runtime library
cd /tmp
wget https://github.com/microsoft/onnxruntime/releases/download/v1.18.0/onnxruntime-linux-x64-1.18.0.tgz
tar xzf onnxruntime-linux-x64-1.18.0.tgz
mkdir -p /path/to/dlang_mcp/lib
cp onnxruntime-linux-x64-1.18.0/lib/libonnxruntime.so.1.18.0 /path/to/dlang_mcp/lib/
cd /path/to/dlang_mcp/lib && ln -sf libonnxruntime.so.1.18.0 onnxruntime.so
```

The binary has an embedded rpath (`$ORIGIN/../lib`) so it finds the ONNX Runtime library automatically when placed in `lib/` next to the `bin/` directory.

When the ONNX model and library are available, the server uses neural embeddings for better semantic search. Otherwise, TF-IDF is used as fallback.

### Indexing Packages

```bash
# Index a single package
./bin/dlang_mcp --ingest --package=silly

# Index all packages (takes a while)
./bin/dlang_mcp --ingest

# Resume interrupted ingestion (automatic)
./bin/dlang_mcp --ingest

# Start fresh
./bin/dlang_mcp --ingest --fresh

# Check ingestion progress
./bin/dlang_mcp --ingest-status

# Mine usage patterns after ingesting
./bin/dlang_mcp --mine-patterns
```

## Troubleshooting

### "Vector search disabled"

Make sure sqlite-vec is installed:
```bash
ls -la data/models/vec0.so
```

If missing, build it:
```bash
cd /tmp
git clone https://github.com/asg017/sqlite-vec
cd sqlite-vec
make loadable
cp dist/vec0.so /path/to/dlang_mcp/data/models/
```

### "Failed to load sqlite-vec"

Check the extension is compatible with your SQLite version:
```bash
sqlite3 --version
```

The extension requires SQLite 3.40+.

### Ingestion fails for a package

Some packages may have unusual structures. Check the error message and try:
```bash
# Clear cache and retry
rm -rf data/cache/sources/<package-name>
./bin/dlang_mcp --ingest --package=<package>
```

## License

AGPL-3.0-or-later — see [LICENSE](LICENSE) for the full text.
