# Development Guide

Developer and contributor reference for dlang_mcp.

## Building

```bash
# Debug build
dub build

# Release build
dub build --build=release

# Force rebuild
dub build --force

# Clean build artifacts
dub clean
```

## Testing

Run the default unit tests:

```bash
dub test
```

Or use the dedicated test runner configuration:

```bash
dub build --config=test
./bin/dlang_mcp_test
```

The test suite covers storage CRUD, D source parsing, TF-IDF embeddings,
tool instantiation/error handling, compiler diagnostic parsing, and an end-to-end ingestion pipeline.

## Project Structure

```
dlang_mcp/
├── source/
│   ├── app.d              # Entry point and CLI driver
│   ├── mcp/               # MCP protocol
│   │   ├── server.d       # MCP server (tool registry, request dispatch)
│   │   ├── protocol.d     # JSON-RPC request/response parsing
│   │   ├── transport.d    # Stdio transport
│   │   ├── transport_interface.d
│   │   ├── http_server.d  # HTTP transport (SSE + streamable)
│   │   ├── http_transport.d
│   │   └── types.d        # JSON-RPC and MCP type definitions
│   ├── tools/             # MCP tools
│   │   ├── base.d         # Tool interface and BaseTool
│   │   ├── search_base.d  # Search tool base class (lazy DB)
│   │   ├── dscanner.d     # Static analysis
│   │   ├── dfmt.d         # Code formatting
│   │   ├── ctags.d        # Symbol search
│   │   ├── compile_check.d # Compile checking
│   │   ├── build_project.d # dub build
│   │   ├── run_tests.d    # dub test
│   │   ├── run_project.d  # dub run
│   │   ├── fetch_package.d # dub fetch
│   │   ├── upgrade_deps.d # dub upgrade
│   │   ├── analyze_project.d # dub describe / project analysis
│   │   ├── ddoc_analyze.d # DDoc project analysis
│   │   ├── outline.d      # Module outline
│   │   ├── list_modules.d # Module listing
│   │   ├── feature_status.d # Runtime feature status
│   │   ├── package_search.d
│   │   ├── function_search.d
│   │   ├── type_search.d
│   │   ├── example_search.d
│   │   └── import_tool.d
│   ├── storage/           # Database layer
│   │   ├── connection.d   # SQLite wrapper
│   │   ├── schema.d       # Table definitions
│   │   ├── crud.d         # CRUD operations
│   │   └── search.d       # Hybrid search
│   ├── ingestion/         # Data pipeline
│   │   ├── dub_crawler.d  # code.dlang.org crawler
│   │   ├── pipeline.d     # Ingestion orchestration
│   │   ├── ddoc_project_parser.d  # DMD JSON parser
│   │   ├── http_client.d
│   │   └── pattern_miner.d
│   ├── embeddings/        # Vector embeddings
│   │   ├── embedder.d     # Interface
│   │   ├── tfidf_embedder.d
│   │   ├── onnx_embedder.d
│   │   └── manager.d
│   ├── models/            # Data structures
│   │   └── types.d
│   └── utils/             # Utilities
│       ├── ctags_parser.d
│       ├── diagnostic.d   # Compiler diagnostic parsing
│       ├── logging.d
│       └── process.d      # Command execution
├── tests/                 # Test suite
│   ├── runner.d
│   ├── unit/
│   │   ├── test_embeddings.d
│   │   ├── test_parser.d
│   │   ├── test_storage.d
│   │   ├── test_tools.d
│   │   └── test_diagnostic.d
│   └── integration/
│       └── test_e2e_pipeline.d
├── data/                  # Runtime data
│   ├── search.db          # SQLite database
│   ├── cache/             # Package cache
│   └── models/            # Extensions and models
│       ├── vec0.so        # sqlite-vec extension
│       └── model.onnx     # ONNX model (optional)
└── dub.json
```

## Architecture

```
┌─────────────────────────────────────┐
│           MCP Server                 │
│  (JSON-RPC over stdio or HTTP)       │
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
│  │ Crawler  │→ │DMD JSON  │       │
│  │          │  │ Parser   │       │
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

## Database Schema

The ingestion pipeline uses DMD's `-X` JSON output to extract full function signatures,
type definitions, doc comments, performance attributes (`@safe`, `@nogc`, `nothrow`, `pure`),
and unittest blocks from each package. All of this is stored in:

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

## MCP Protocol

The server supports two transport modes:

- **stdio** (default) — JSON-RPC 2.0 over stdin/stdout. Used by most MCP clients (Claude Desktop, opencode, Zed).
- **HTTP** (`--http`) — Exposes three endpoints:
  - `GET /sse` — Server-Sent Events for long-lived streaming sessions
  - `POST /messages` — Send JSON-RPC messages to an SSE session (requires `sessionId` query parameter)
  - `POST /mcp` — Streamable HTTP transport (stateless, no session required)
  - `GET /health` — Health check

Request dispatch is handled in `mcp/server.d`. The `handleRequest()` method routes by JSON-RPC method name (`initialize`, `tools/list`, `tools/call`, `ping`, etc.). Notifications (messages without an `id`) are handled separately via `handleNotification()` and produce no response.

## Adding a New Tool

1. Create a new file in `source/tools/`, e.g. `my_tool.d`
2. Implement the `Tool` interface (or extend `BaseTool`):

```d
module tools.my_tool;

import std.json : JSONValue, parseJSON;
import tools.base : BaseTool;
import mcp.types : ToolResult;

class MyTool : BaseTool {
    @property string name() { return "my_tool"; }

    @property string description() {
        return "Description of what the tool does.";
    }

    @property JSONValue inputSchema() {
        return parseJSON(`{
            "type": "object",
            "properties": {
                "param1": {
                    "type": "string",
                    "description": "A required parameter"
                }
            },
            "required": ["param1"]
        }`);
    }

    ToolResult execute(JSONValue arguments) {
        string param1 = arguments["param1"].str;
        // ... do work ...
        return createTextResult("Result: " ~ param1);
    }
}
```

3. Register it in `source/app.d`:

```d
import tools.my_tool : MyTool;
// ...
server.registerTool(new MyTool());
```

For tools that need the search database, extend `SearchBaseTool` from `tools/search_base.d` instead, which provides lazy database connection management.
