# dlang_mcp - D Language MCP Server

MCP (Model Context Protocol) server for D language tools with semantic package search.

## Features

### Code Analysis Tools
- **dscanner** - Static code analysis for D
- **dfmt** - Code formatting
- **ctags_search** - Symbol definition search

### Semantic Search Tools
- **search_packages** - Search D packages by name/description
- **search_functions** - Search D functions by signature/docs
- **search_types** - Search classes/structs/interfaces
- **search_examples** - Search code examples
- **get_imports** - Get import statements for symbols

## Installation

### Prerequisites
- DMD 2.100+ or LDC
- dub package manager
- dscanner and dfmt (for code analysis tools)
- SQLite 3.40+ with FTS5 support

### Build

```bash
dub build
```

## Usage

### MCP Server Mode

Run as an MCP server (for use with Claude, etc.):

```bash
./bin/dlang_mcp
```

#Usage

```sh
# Full setup (recommended)
./setup.sh
# Minimal setup (TF-IDF only)
./setup.sh --skip-onnx
# Just build, no packages
./setup.sh --skip-packages
# Test search
./bin/dlang_mcp --test-search "hash table lookup"
# Run MCP server
./bin/dlang_mcp## Command Line
```

```bash
# Initialize the search database
./bin/dlang_mcp --init-db

# Show database statistics
./bin/dlang_mcp --stats

# Ingest a single package from code.dlang.org
./bin/dlang_mcp --ingest silly

# Ingest all packages from code.dlang.org
./bin/dlang_mcp --ingest

# Ingest with limit
./bin/dlang_mcp --ingest --limit 50

# Show ingestion progress
./bin/dlang_mcp --ingest-status

# Mine usage patterns from indexed data
./bin/dlang_mcp --mine-patterns

# Show help
./bin/dlang_mcp --help
```

### MCP Client Configuration

For Claude Desktop, add to `~/.config/claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "dlang": {
      "command": "/path/to/dlang_mcp"
    }
  }
}
```

## Vector Search (Optional)

The server supports vector-based semantic search using **sqlite-vec**. This enables more accurate similarity searches beyond keyword matching.

### Installing sqlite-vec

**Option 1: Build from source**

```bash
cd /tmp
git clone https://github.com/asg017/sqlite-vec
cd sqlite-vec
make loadable
cp dist/vec0.so /path/to/dlang_mcp/data/models/
```

**Option 2: Use environment variable**

```bash
# Set custom path
export SQLITE_VEC_PATH=/path/to/vec0.so
./bin/dlang_mcp --init-db
```

**Auto-detection paths:**
- `data/models/vec0.so` (Linux)
- `data/models/vec0.dylib` (macOS)
- `data/models/vec0.dll` (Windows)
- `/usr/local/lib/vec0.*`
- `/usr/lib/vec0.*`

### Verify Installation

```bash
./bin/dlang_mcp --init-db
# Should show: "Vector search enabled (sqlite-vec)"
```

## ONNX Embeddings (Optional)

For semantic embeddings using neural networks:

```bash
# Download ONNX model (all-MiniLM-L6-v2)
wget -O data/models/model.onnx \
  https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/main/onnx/model.onnx

# Download BERT vocabulary
wget -O data/models/vocab.txt \
  https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/raw/main/vocab.txt

# Install ONNX Runtime library
cd /tmp
wget https://github.com/microsoft/onnxruntime/releases/download/v1.18.0/onnxruntime-linux-x64-1.18.0.tgz
tar xzf onnxruntime-linux-x64-1.18.0.tgz
mkdir -p lib
cp onnxruntime-linux-x64-1.18.0/lib/libonnxruntime.so.1.18.0 lib/
cd lib && ln -sf libonnxruntime.so.1.18.0 onnxruntime.so
```

The binary has an embedded rpath (`$ORIGIN/../lib`) so it will automatically find the ONNX Runtime library when placed in `lib/` next to the `bin/` directory.

### Running with ONNX

```bash
# Just run directly - library is found automatically
./bin/dlang_mcp --test-search "hash table lookup"
```

When ONNX model and library are available, the server will use neural embeddings for better semantic search. Otherwise, TF-IDF is used as fallback.

## Indexing Packages

### From code.dlang.org

```bash
# Index a single package
./bin/dlang_mcp --ingest silly

# Index multiple packages
./bin/dlang_mcp --ingest vibe-d
./bin/dlang_mcp --ingest mir-algorithm

# Index all packages (takes a while)
./bin/dlang_mcp --ingest

# Resume interrupted ingestion
./bin/dlang_mcp --ingest
```

### Ingestion Progress

The ingestion pipeline tracks progress in the database. You can check status:

```bash
./bin/dlang_mcp --ingest-status
```

If ingestion is interrupted, running `--ingest` again will resume from where it stopped. Use `--fresh` to start over:

```bash
./bin/dlang_mcp --ingest --fresh
```

### Pattern Mining

After ingesting packages, mine usage patterns:

```bash
./bin/dlang_mcp --mine-patterns
```

This analyzes import combinations and function relationships to provide better suggestions.

## Example Usage

### Quick Start Guide

#### Option 1: Minimal Setup (TF-IDF only)

Basic keyword search - no external dependencies required.

```bash
# 1. Build
dub build

# 2. Initialize database
./bin/dlang_mcp --init-db

# 3. Ingest packages
./bin/dlang_mcp --ingest phobos
./bin/dlang_mcp --ingest intel-intrinsics

# 4. Train TF-IDF embeddings
./bin/dlang_mcp --train-embeddings

# 5. Run MCP server
./bin/dlang_mcp
```

#### Option 2: Full Setup (Semantic Search with ONNX)

Neural embeddings for better semantic understanding.

```bash
# 1. Build
dub build

# 2. Install sqlite-vec for vector similarity
cd /tmp && git clone --depth 1 https://github.com/asg017/sqlite-vec && cd sqlite-vec && make loadable
mkdir -p /path/to/dlang_mcp/data/models
cp dist/vec0.so /path/to/dlang_mcp/data/models/

# 3. Install ONNX Runtime
cd /tmp
wget https://github.com/microsoft/onnxruntime/releases/download/v1.18.0/onnxruntime-linux-x64-1.18.0.tgz
tar xzf onnxruntime-linux-x64-1.18.0.tgz
mkdir -p /path/to/dlang_mcp/lib
cp onnxruntime-linux-x64-1.18.0/lib/libonnxruntime.so.1.18.0 /path/to/dlang_mcp/lib/
cd /path/to/dlang_mcp/lib && ln -sf libonnxruntime.so.1.18.0 onnxruntime.so

# 4. Download ONNX model and vocabulary
cd /path/to/dlang_mcp
wget -O data/models/model.onnx \
  https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/main/onnx/model.onnx
wget -O data/models/vocab.txt \
  https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/raw/main/vocab.txt

# 5. Initialize and ingest
./bin/dlang_mcp --init-db
./bin/dlang_mcp --ingest phobos
./bin/dlang_mcp --ingest intel-intrinsics

# 6. Train embeddings and mine patterns
./bin/dlang_mcp --train-embeddings
./bin/dlang_mcp --mine-patterns

# 7. Test search
./bin/dlang_mcp --test-search "hash table lookup"

# 8. Run MCP server
./bin/dlang_mcp
```

#### One-Command Setup

```bash
chmod +x setup.sh && ./setup.sh
```

This installs all optional components and ingests example packages.

## Project Structure

```
dlang_mcp/
├── source/
│   ├── app.d              # Entry point
│   ├── mcp/               # MCP protocol
│   │   ├── server.d       # MCP server
│   │   ├── transport.d   # stdio transport
│   │   ├── types.d        # JSON-RPC types
│   │   └── protocol.d    # Request handling
│   ├── tools/             # MCP tools
│   │   ├── dscanner.d    # Code analysis
│   │   ├── dfmt.d        # Formatting
│   │   ├── ctags.d       # Symbol search
│   │   ├── package_search.d
│   │   ├── function_search.d
│   │   ├── type_search.d
│   │   ├── example_search.d
│   │   └── import_tool.d
│   ├── storage/           # Database layer
│   │   ├── connection.d  # SQLite wrapper
│   │   ├── schema.d      # Table definitions
│   │   ├── crud.d        # CRUD operations
│   │   └── search.d      # Hybrid search
│   ├── ingestion/         # Data pipeline
│   │   ├── dub_crawler.d # code.dlang.org crawler
│   │   ├── pipeline.d    # Ingestion orchestration
│   │   ├── ddoc_parser.d # D documentation parser
│   │   └── pattern_miner.d
│   ├── embeddings/        # Vector embeddings
│   │   ├── tfidf_embedder.d
│   │   ├── onnx_embedder.d
│   │   └── manager.d
│   └── models/             # Data structures
│       └── types.d
├── tests/                 # Test suite
├── data/                  # Runtime data
│   ├── search.db         # SQLite database
│   ├── cache/            # Package cache
│   └── models/           # Extensions and models
│       ├── vec0.so       # sqlite-vec extension
│       └── model.onnx    # ONNX model (optional)
└── dub.json
```

## Database Schema

The database uses:
- **Core tables**: packages, modules, functions, types, code_examples
- **FTS5 tables**: Full-text search for packages, functions, types, examples
- **Vector tables**: sqlite-vec for semantic similarity (when available)
- **Relationships**: function_relationships, type_relationships, usage_patterns
- **Progress tracking**: ingestion_progress for resumable ingestion

## Embedding Strategies

| Strategy | Dependencies | Quality | Speed |
|----------|--------------|---------|-------|
| TF-IDF | None | Good for keywords | Fast |
| ONNX | ONNX Runtime, model file | Semantic understanding | Medium |
| Hybrid (sqlite-vec) | sqlite-vec extension | Vector similarity | Fast |

## Testing

```bash
dub run --config=test
```

## Architecture

```
┌─────────────────────────────────────┐
│           MCP Server                 │
│  (JSON-RPC over stdio)              │
└──────────────┬──────────────────────┘
                │
        ┌───────┴────────┐
        │                │
┌──────▼──────┐  ┌─────▼─────────┐
│   Search    │  │   Embedding   │
│   Engine    │  │   Generator   │
│  (Hybrid)   │  │ (TF-IDF/ONNX) │
└──────┬──────┘  └───────────────┘
       │
┌──────▼───────────────────────────┐
│         SQLite Database           │
│  ┌──────────┐  ┌──────────┐      │
│  │   FTS5   │  │sqlite-vec│      │
│  │ Keywords │  │ Vectors  │      │
│  └──────────┘  └──────────┘      │
│  ┌──────────┐  ┌──────────┐      │
│  │ Relations│  │ Progress │      │
│  │  Graphs  │  │ Tracking │      │
│  └──────────┘  └──────────┘      │
└───────────────────────────────────┘
       ▲
       │
┌──────┴───────────────────────────┐
│        Ingestion Pipeline          │
│  ┌──────────┐  ┌──────────┐       │
│  │ Crawler  │→ │  Parser  │       │
│  └──────────┘  └──────────┘       │
│  ┌──────────┐  ┌──────────┐       │
│  │ Embedder │→ │  Miner   │       │
│  └──────────┘  └──────────┘       │
└───────────────────────────────────┘
       ▲
       │
┌──────┴──────┐
│ code.dlang  │
│    .org     │
└─────────────┘
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
./bin/dlang_mcp --ingest <package>
```

## License

MIT
