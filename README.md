# dlang_mcp - D Language MCP Server

MCP (Model Context Protocol) server for D language tools with semantic package search.

## Status
- mostly vibe coded in a day
- only tested on linux
- PR's welcome
- actually not really sure if correctly used by the LLM or really useful
- if you have something better, please tell me

## Features (20 MCP Tools)

### Code Quality & Analysis

- **dscanner** — Static analysis for bugs, style issues, and complexity. Supports multiple modes: lint (default), syntax validation, import listing, line counts, AST generation, and ctags output. Configurable check presets (default, strict, minimal).
- **dfmt** — Format D source code with configurable brace style (allman, otbs, stroustrup), indentation, and line length. Paste code in, get formatted code back.
- **compile_check** — Compile-check D code without linking or running. Catches type errors, undefined identifiers, and syntax errors. Accepts inline code or a file path; set `dub_project` for automatic import path resolution. Supports dmd and ldc2.
- **coverage_analysis** — Analyze code coverage from `.lst` files produced by `dmd -cov` or `ldc2 --cov`. Reports per-function coverage stats sorted by most uncovered lines. Point it at a single file or a directory to scan all `.lst` files.

### Build, Test & Run

- **build_project** — Build a D/dub project and get structured results: success/failure, compiler errors with file/line/message, and warnings. Supports debug/release builds, compiler selection (dmd/ldc2), and force rebuild.
- **run_tests** — Run unit tests for a D/dub project. Returns pass/fail count, test output, and compiler errors if the build fails. Supports test name filtering and verbose output.
- **run_project** — Build and execute a D/dub project, returning stdout, stderr, and exit code. Pass arguments through to the built program.

### Package & Dependency Management

- **fetch_package** — Download a D package from the dub registry to the local cache. Optionally specify a version.
- **upgrade_dependencies** — Upgrade project dependencies to their latest allowed versions. Supports `missing_only` (fetch without upgrading) and `verify` (check consistency without modifying).
- **analyze_project** — Analyze a D/dub project's build configuration: project name, dependency versions, source files, import paths, and build settings. Uses `dub describe` with fallback to direct file parsing.

### Code Navigation & Structure

- **ctags_search** — Search for symbol definitions (functions, classes, structs, enums) by name across a project. Supports exact, prefix, and regex matching with kind filtering. Auto-generates the tags file when needed.
- **get_module_outline** — Get a hierarchical outline of every symbol in a D source file: names, kinds, line numbers, visibility, attributes (`@safe`, `@nogc`, `nothrow`, `pure`), return types, parameters, and ddoc comments. Accepts a file path or inline code.
- **list_project_modules** — List all modules in a project with summaries of their public APIs (functions, classes, structs, enums with signatures).
- **ddoc_analyze** — Analyze documentation coverage and attribute usage across a project using DMD's JSON output. Reports per-module doc coverage percentages, function/type counts, and template statistics.

### Semantic Search (requires indexed database)

These tools search a local SQLite database of indexed D packages. Use `--ingest` to populate the database, and optionally enable ONNX neural embeddings or sqlite-vec vector similarity for better results (see [Semantic Search Setup](#semantic-search-setup-optional)).

- **search_packages** — Search indexed D packages by name, description, or tags. Find libraries for a given task.
- **search_functions** — Search function definitions by name, signature, or description across all indexed packages. Find how to do things in D.
- **search_types** — Search type definitions (classes, structs, interfaces, enums) by name or description. Filter by kind.
- **search_examples** — Search for runnable D code examples by description or code pattern. Returns complete snippets with required imports.
- **get_imports** — Look up the required import statements for D symbols. Pass a symbol name, get back the `import` line.

### Diagnostics

- **get_feature_status** — Check which optional runtime features are available: database, ONNX embeddings, sqlite-vec, external tools (dscanner, dfmt), and active search mode. Useful for diagnosing issues.

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

### GitHub Copilot (VS Code)

Add to `.vscode/mcp.json` in your workspace:

```json
{
  "servers": {
    "dlang-mcp": {
      "type": "stdio",
      "command": "/path/to/dlang_mcp/bin/dlang_mcp"
    }
  }
}
```

### GitHub Copilot CLI

Add to `~/.config/github-copilot/github-copilot-cli/mcp.json`:

```json
{
  "servers": {
    "dlang-mcp": {
      "type": "stdio",
      "command": "/path/to/dlang_mcp/bin/dlang_mcp"
    }
  }
}
```

### OpenAI Codex CLI

Add to `~/.codex/config.json`:

```json
{
  "mcpServers": {
    "dlang-mcp": {
      "type": "stdio",
      "command": "/path/to/dlang_mcp/bin/dlang_mcp"
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

## Command Line Reference

```bash
# Run as MCP server over stdio (default)
./bin/dlang_mcp

# Run as MCP server over HTTP (SSE + streamable endpoints)
./bin/dlang_mcp --http --port=3000 --host=127.0.0.1

# Initialize the search database
./bin/dlang_mcp --init-db

# Show database statistics
./bin/dlang_mcp --stats

# Show runtime feature status
./bin/dlang_mcp --feature-status

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

# Analyze a D project (standalone, no MCP)
./bin/dlang_mcp --analyze-project=/path/to/project
./bin/dlang_mcp --ddoc-analyze=/path/to/project

# Test search with a query
./bin/dlang_mcp --test-search="hash table lookup"

# Verbose logging (--verbose for info, --vverbose for trace)
./bin/dlang_mcp --verbose

# Set process execution timeout (default: 30s)
./bin/dlang_mcp --timeout=60

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

BOOST — see [LICENSE](LICENSE) for the full text.
