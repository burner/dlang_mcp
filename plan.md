# D Language MCP Server Implementation Plan
## Exposing dscanner and dfmt via stdio

---

## 1. Project Overview

### 1.1 Objective
Build a Model Context Protocol (MCP) server in D language that:
- Communicates via stdio (JSON-RPC 2.0)
- Exposes dscanner (static code analyzer) as an MCP tool
- Exposes dfmt (code formatter) as an MCP tool
- Follows MCP specification for tool discovery and execution

### 1.2 Target Architecture
```
┌─────────────────┐         stdio          ┌──────────────────┐
│   MCP Client    │ ←──────────────────────→ │   D MCP Server   │
│  (Claude, etc)  │    JSON-RPC Messages    │                  │
└─────────────────┘                         └──────────────────┘
                                                     │
                                                     ├─→ dscanner
                                                     └─→ dfmt
```

---

## 2. Prerequisites and Dependencies

### 2.1 System Requirements
- D compiler (DMD, LDC, or GDC)
- dub (D package manager)
- dscanner installed and in PATH
- dfmt installed and in PATH

### 2.2 D Language Dependencies
```json
{
  "dependencies": {
    "vibe-d:data": "~>0.9.5",    // JSON parsing and serialization
    "std.json": "built-in"        // Alternative: built-in std.json
  }
}
```

### 2.3 External Tools
- **dscanner**: https://github.com/dlang-community/D-Scanner
- **dfmt**: https://github.com/dlang-community/dfmt

---

## 3. MCP Protocol Understanding

### 3.1 Core Concepts
- **Transport**: stdio using JSON-RPC 2.0
- **Message Format**: Line-delimited JSON
- **Required Methods**:
  - `initialize` - Server initialization
  - `tools/list` - Discover available tools
  - `tools/call` - Execute a specific tool

### 3.2 Message Flow
```
Client → Server: initialize request
Server → Client: initialize response (server capabilities)

Client → Server: tools/list request
Server → Client: tools/list response (available tools)

Client → Server: tools/call request (with tool name and arguments)
Server → Client: tools/call response (tool output)
```

### 3.3 JSON-RPC 2.0 Message Structure
```json
// Request
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "dscanner",
    "arguments": {
      "file": "source.d",
      "checks": ["style", "syntax"]
    }
  }
}

// Response
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Analysis results..."
      }
    ]
  }
}
```

---

## 4. Project Structure

```
dlang-mcp-server/
├── dub.json                    # Project configuration
├── source/
│   ├── app.d                   # Main entry point
│   ├── mcp/
│   │   ├── server.d            # MCP server implementation
│   │   ├── protocol.d          # JSON-RPC protocol handling
│   │   ├── transport.d         # stdio transport layer
│   │   └── types.d             # MCP type definitions
│   ├── tools/
│   │   ├── base.d              # Abstract tool interface
│   │   ├── dscanner.d          # dscanner tool implementation
│   │   └── dfmt.d              # dfmt tool implementation
│   └── utils/
│       ├── process.d           # Process execution utilities
│       └── logging.d           # Logging utilities (stderr only)
├── tests/
│   ├── mcp_tests.d
│   ├── dscanner_tests.d
│   └── dfmt_tests.d
└── README.md
```

---

## 5. Core Component Implementation

### 5.1 Main Entry Point (`app.d`)

**Purpose**: Initialize server and start message loop

**Key Responsibilities**:
- Set up stdio transport
- Initialize MCP server
- Register tools (dscanner, dfmt)
- Start message processing loop
- Handle graceful shutdown

**Pseudocode**:
```d
void main()
{
    // Redirect logging to stderr (stdout is for JSON-RPC)
    setupStderrLogging();
    
    // Create MCP server instance
    auto server = new MCPServer();
    
    // Register tools
    server.registerTool(new DscannerTool());
    server.registerTool(new DfmtTool());
    
    // Create stdio transport
    auto transport = new StdioTransport(stdin, stdout);
    
    // Start server
    server.start(transport);
}
```

---

### 5.2 Protocol Handler (`mcp/protocol.d`)

**Purpose**: Parse and validate JSON-RPC messages

**Key Components**:

#### 5.2.1 Message Types
```d
struct JsonRpcRequest
{
    string jsonrpc;  // Must be "2.0"
    int id;          // Request ID
    string method;   // Method name
    JSONValue params; // Optional parameters
}

struct JsonRpcResponse
{
    string jsonrpc;  // Must be "2.0"
    int id;          // Matching request ID
    JSONValue result; // Success result
    JSONValue error;  // Error object (if failed)
}

struct JsonRpcError
{
    int code;
    string message;
    JSONValue data; // Optional additional info
}
```

#### 5.2.2 Error Codes
```d
enum JsonRpcErrorCode
{
    ParseError = -32700,
    InvalidRequest = -32600,
    MethodNotFound = -32601,
    InvalidParams = -32602,
    InternalError = -32603
}
```

#### 5.2.3 Protocol Parser
```d
class ProtocolHandler
{
    JsonRpcRequest parseRequest(string jsonLine);
    string serializeResponse(JsonRpcResponse response);
    JsonRpcResponse createErrorResponse(int id, int code, string message);
}
```

---

### 5.3 Transport Layer (`mcp/transport.d`)

**Purpose**: Handle stdio communication

**Key Responsibilities**:
- Read line-delimited JSON from stdin
- Write JSON responses to stdout
- Handle EOF and errors
- Ensure stdout is only used for JSON-RPC (logging goes to stderr)

**Implementation**:
```d
class StdioTransport
{
    private File input;
    private File output;
    
    this(File input, File output)
    {
        this.input = input;
        this.output = output;
        
        // Ensure stdout is in line-buffered mode
        output.setvbuf(0, _IOLBF);
    }
    
    string readMessage()
    {
        // Read one line from stdin
        string line = input.readln();
        if (line is null) throw new EOFException();
        return line.strip();
    }
    
    void writeMessage(string jsonMessage)
    {
        // Write JSON + newline to stdout
        output.writeln(jsonMessage);
        output.flush();
    }
}
```

---

### 5.4 MCP Server (`mcp/server.d`)

**Purpose**: Core server logic and request routing

**Key Responsibilities**:
- Handle `initialize` method
- Handle `tools/list` method
- Handle `tools/call` method
- Route requests to appropriate handlers
- Manage tool registry

**Implementation Outline**:
```d
class MCPServer
{
    private Tool[string] tools;
    private bool initialized = false;
    
    void registerTool(Tool tool)
    {
        tools[tool.name] = tool;
    }
    
    void start(StdioTransport transport)
    {
        while (true)
        {
            try
            {
                string message = transport.readMessage();
                auto request = parseRequest(message);
                auto response = handleRequest(request);
                transport.writeMessage(serializeResponse(response));
            }
            catch (EOFException e)
            {
                break; // Client disconnected
            }
            catch (Exception e)
            {
                logError(e.msg); // Log to stderr
            }
        }
    }
    
    JsonRpcResponse handleRequest(JsonRpcRequest request)
    {
        switch (request.method)
        {
            case "initialize":
                return handleInitialize(request);
            case "tools/list":
                return handleToolsList(request);
            case "tools/call":
                return handleToolsCall(request);
            default:
                return createMethodNotFoundError(request.id);
        }
    }
    
    JsonRpcResponse handleInitialize(JsonRpcRequest request);
    JsonRpcResponse handleToolsList(JsonRpcRequest request);
    JsonRpcResponse handleToolsCall(JsonRpcRequest request);
}
```

---

### 5.5 MCP Type Definitions (`mcp/types.d`)

**Purpose**: Define MCP-specific data structures

```d
// Server capabilities
struct ServerCapabilities
{
    ToolsCapability tools;
}

struct ToolsCapability
{
    bool listChanged = false; // Whether tools can change dynamically
}

// Tool definition
struct ToolDefinition
{
    string name;
    string description;
    JSONValue inputSchema; // JSON Schema for parameters
}

// Tool result
struct ToolResult
{
    Content[] content;
    bool isError = false;
}

struct Content
{
    string type;  // "text" or "image" or "resource"
    string text;  // For text content
    // ... other fields for other content types
}
```

---

## 6. Tool Implementations

### 6.1 Base Tool Interface (`tools/base.d`)

```d
interface Tool
{
    // Tool metadata
    @property string name();
    @property string description();
    @property JSONValue inputSchema();
    
    // Execute the tool
    ToolResult execute(JSONValue arguments);
}

abstract class BaseTool : Tool
{
    protected ToolResult createTextResult(string text)
    {
        return ToolResult([
            Content("text", text)
        ]);
    }
    
    protected ToolResult createErrorResult(string errorMessage)
    {
        return ToolResult([
            Content("text", errorMessage)
        ], true);
    }
}
```

---

### 6.2 Dscanner Tool (`tools/dscanner.d`)

#### 6.2.1 Tool Metadata
```d
class DscannerTool : BaseTool
{
    @property string name() { return "dscanner"; }
    
    @property string description()
    {
        return "Analyze D source code for issues, style violations, and potential bugs. " ~
               "Can check syntax, style, and run static analysis.";
    }
    
    @property JSONValue inputSchema()
    {
        return parseJSON(`{
            "type": "object",
            "properties": {
                "code": {
                    "type": "string",
                    "description": "D source code to analyze"
                },
                "file_path": {
                    "type": "string",
                    "description": "Optional file path (for context in error messages)"
                },
                "checks": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Specific checks to run (e.g., 'style', 'syntax', 'all')",
                    "default": ["all"]
                },
                "config": {
                    "type": "string",
                    "description": "Optional path to dscanner.ini config file"
                }
            },
            "required": ["code"]
        }`);
    }
}
```

#### 6.2.2 Execution Logic
```d
ToolResult execute(JSONValue arguments)
{
    try
    {
        // Extract parameters
        string code = arguments["code"].str;
        string filePath = arguments.get("file_path", "source.d").str;
        auto checks = arguments.get("checks", parseJSON(`["all"]`)).array;
        
        // Write code to temporary file
        string tempFile = writeTempFile(code, filePath);
        scope(exit) removeTempFile(tempFile);
        
        // Build dscanner command
        string[] command = ["dscanner", "--styleCheck"];
        
        if (hasConfig(arguments))
        {
            command ~= ["--config", arguments["config"].str];
        }
        
        command ~= tempFile;
        
        // Execute dscanner
        auto result = executeProcess(command);
        
        // Parse and format output
        string formattedOutput = formatDscannerOutput(
            result.output, 
            filePath
        );
        
        if (result.status == 0)
        {
            return createTextResult(formattedOutput.length > 0 
                ? formattedOutput 
                : "No issues found.");
        }
        else
        {
            return createErrorResult(
                "dscanner failed: " ~ result.output
            );
        }
    }
    catch (Exception e)
    {
        return createErrorResult("Error executing dscanner: " ~ e.msg);
    }
}
```

#### 6.2.3 Helper Functions
```d
private string formatDscannerOutput(string rawOutput, string filePath)
{
    // Parse dscanner output and format for better readability
    // Convert file references from temp paths to user-provided path
    // Group issues by severity
    // Add summary statistics
}

private string writeTempFile(string code, string originalPath)
{
    import std.file : tempDir;
    import std.path : baseName;
    
    string tempPath = tempDir ~ "/" ~ baseName(originalPath);
    std.file.write(tempPath, code);
    return tempPath;
}
```

---

### 6.3 Dfmt Tool (`tools/dfmt.d`)

#### 6.3.1 Tool Metadata
```d
class DfmtTool : BaseTool
{
    @property string name() { return "dfmt"; }
    
    @property string description()
    {
        return "Format D source code according to style guidelines. " ~
               "Returns formatted code with consistent indentation, spacing, and style.";
    }
    
    @property JSONValue inputSchema()
    {
        return parseJSON(`{
            "type": "object",
            "properties": {
                "code": {
                    "type": "string",
                    "description": "D source code to format"
                },
                "brace_style": {
                    "type": "string",
                    "enum": ["allman", "otbs", "stroustrup"],
                    "description": "Brace style to use",
                    "default": "allman"
                },
                "indent_size": {
                    "type": "integer",
                    "description": "Number of spaces for indentation",
                    "default": 4,
                    "minimum": 1,
                    "maximum": 8
                },
                "max_line_length": {
                    "type": "integer",
                    "description": "Maximum line length",
                    "default": 120,
                    "minimum": 40
                },
                "config": {
                    "type": "string",
                    "description": "Optional path to dfmt.toml config file"
                }
            },
            "required": ["code"]
        }`);
    }
}
```

#### 6.3.2 Execution Logic
```d
ToolResult execute(JSONValue arguments)
{
    try
    {
        // Extract parameters
        string code = arguments["code"].str;
        
        // Build dfmt command
        string[] command = ["dfmt"];
        
        // Add options
        if ("brace_style" in arguments)
        {
            command ~= ["--brace_style", arguments["brace_style"].str];
        }
        
        if ("indent_size" in arguments)
        {
            command ~= ["--indent_size", 
                       to!string(arguments["indent_size"].integer)];
        }
        
        if ("max_line_length" in arguments)
        {
            command ~= ["--max_line_length", 
                       to!string(arguments["max_line_length"].integer)];
        }
        
        if ("config" in arguments)
        {
            command ~= ["--config", arguments["config"].str];
        }
        
        // Execute dfmt with code as stdin
        auto result = executeProcessWithInput(command, code);
        
        if (result.status == 0)
        {
            return createTextResult(result.output);
        }
        else
        {
            return createErrorResult(
                "dfmt failed: " ~ result.output
            );
        }
    }
    catch (Exception e)
    {
        return createErrorResult("Error executing dfmt: " ~ e.msg);
    }
}
```

---

### 6.4 Process Utilities (`utils/process.d`)

**Purpose**: Execute external commands safely

```d
struct ProcessResult
{
    int status;
    string output;
}

ProcessResult executeProcess(string[] command)
{
    import std.process : execute;
    auto result = execute(command);
    return ProcessResult(result.status, result.output);
}

ProcessResult executeProcessWithInput(string[] command, string input)
{
    import std.process : pipeProcess, Redirect, wait;
    import std.stdio : File;
    
    auto pipes = pipeProcess(command, 
                            Redirect.stdin | Redirect.stdout | Redirect.stderr);
    
    // Write input to stdin
    pipes.stdin.write(input);
    pipes.stdin.close();
    
    // Read output
    string output = pipes.stdout.byLine.join("\n").to!string;
    
    // Wait for process
    int status = wait(pipes.pid);
    
    return ProcessResult(status, output);
}
```

---

## 7. Configuration and Build

### 7.1 dub.json
```json
{
    "name": "dlang-mcp-server",
    "description": "MCP server exposing dscanner and dfmt tools",
    "authors": ["Your Name"],
    "license": "MIT",
    "targetType": "executable",
    "targetPath": "bin",
    "targetName": "dlang-mcp-server",
    
    "dependencies": {
        "vibe-d:data": "~>0.9.5"
    },
    
    "configurations": [
        {
            "name": "application",
            "targetType": "executable"
        },
        {
            "name": "unittest",
            "targetType": "executable",
            "dflags": ["-unittest"]
        }
    ],
    
    "buildTypes": {
        "release": {
            "buildOptions": ["releaseMode", "optimize", "inline"],
            "dflags": ["-O3"]
        },
        "debug": {
            "buildOptions": ["debugMode", "debugInfo"],
            "dflags": ["-g"]
        }
    }
}
```

### 7.2 Build Commands
```bash
# Build debug version
dub build

# Build release version
dub build --build=release

# Run tests
dub test

# Clean build artifacts
dub clean
```

---

## 8. Testing Strategy

### 8.1 Unit Tests

#### 8.1.1 Protocol Tests (`tests/mcp_tests.d`)
```d
unittest
{
    // Test JSON-RPC request parsing
    auto handler = new ProtocolHandler();
    
    string validRequest = `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`;
    auto request = handler.parseRequest(validRequest);
    assert(request.method == "tools/list");
    assert(request.id == 1);
    
    // Test error response generation
    auto errorResponse = handler.createErrorResponse(
        1, 
        JsonRpcErrorCode.MethodNotFound, 
        "Method not found"
    );
    assert(errorResponse.error["code"].integer == -32601);
}
```

#### 8.1.2 Dscanner Tool Tests (`tests/dscanner_tests.d`)
```d
unittest
{
    auto tool = new DscannerTool();
    
    // Test valid code
    auto args = parseJSON(`{
        "code": "void main() { writeln(\"Hello\"); }"
    }`);
    
    auto result = tool.execute(args);
    assert(!result.isError);
    
    // Test invalid code
    args = parseJSON(`{
        "code": "void main( { }"  // Syntax error
    }`);
    
    result = tool.execute(args);
    // Should detect syntax error
}
```

#### 8.1.3 Dfmt Tool Tests (`tests/dfmt_tests.d`)
```d
unittest
{
    auto tool = new DfmtTool();
    
    // Test formatting
    auto args = parseJSON(`{
        "code": "void main(){writeln(\"test\");}"
    }`);
    
    auto result = tool.execute(args);
    assert(!result.isError);
    
    // Result should be properly formatted
    string formatted = result.content[0].text;
    assert(formatted.canFind("void main()"));
    assert(formatted.canFind("    writeln"));
}
```

### 8.2 Integration Tests

#### 8.2.1 End-to-End MCP Communication Test
```d
unittest
{
    import std.process : pipe, pipeProcess;
    
    // Start server as subprocess
    auto pipes = pipeProcess(["./bin/dlang-mcp-server"]);
    
    // Send initialize
    pipes.stdin.writeln(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`);
    string response = pipes.stdout.readln();
    auto initResponse = parseJSON(response);
    assert("result" in initResponse);
    
    // Send tools/list
    pipes.stdin.writeln(`{"jsonrpc":"2.0","id":2,"method":"tools/list"}`);
    response = pipes.stdout.readln();
    auto listResponse = parseJSON(response);
    assert(listResponse["result"]["tools"].array.length == 2);
    
    // Cleanup
    pipes.stdin.close();
    wait(pipes.pid);
}
```

### 8.3 Manual Testing Script

Create `test_server.sh`:
```bash
#!/bin/bash

# Build server
dub build

# Test initialization
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | ./bin/dlang-mcp-server

# Test tools list
echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | ./bin/dlang-mcp-server

# Test dscanner
cat <<EOF | ./bin/dlang-mcp-server
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"dscanner","arguments":{"code":"void main() { writeln(\\"test\\"); }"}}}
EOF

# Test dfmt
cat <<EOF | ./bin/dlang-mcp-server
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"dfmt","arguments":{"code":"void main(){writeln(\\"test\\");}"}}}
EOF
```

---

## 9. Error Handling Strategy

### 9.1 Error Categories

1. **Protocol Errors**: Invalid JSON-RPC format
2. **Tool Execution Errors**: dscanner/dfmt failures
3. **System Errors**: File I/O, process execution
4. **Validation Errors**: Invalid parameters

### 9.2 Error Response Format

```d
JsonRpcResponse createToolExecutionError(int id, string toolName, string error)
{
    return JsonRpcResponse(
        "2.0",
        id,
        JSONValue.init,
        parseJSON(format(`{
            "code": -32603,
            "message": "Tool execution failed",
            "data": {
                "tool": "%s",
                "error": "%s"
            }
        }`, toolName, error))
    );
}
```

### 9.3 Logging Strategy

```d
// All logging to stderr only (stdout is for JSON-RPC)
void logError(string message)
{
    stderr.writefln("[ERROR] %s: %s", 
                    Clock.currTime().toISOExtString(), 
                    message);
}

void logInfo(string message)
{
    stderr.writefln("[INFO] %s: %s", 
                    Clock.currTime().toISOExtString(), 
                    message);
}

void logDebug(string message)
{
    debug stderr.writefln("[DEBUG] %s: %s", 
                         Clock.currTime().toISOExtString(), 
                         message);
}
```

---

## 10. Deployment and Usage

### 10.1 Installation

```bash
# Clone repository
git clone https://github.com/yourusername/dlang-mcp-server.git
cd dlang-mcp-server

# Install dependencies
dub fetch

# Build release version
dub build --build=release

# Install dscanner and dfmt if not already installed
dub fetch dscanner
dub build dscanner
dub fetch dfmt
dub build dfmt

# Add to PATH or copy binaries
sudo cp bin/dlang-mcp-server /usr/local/bin/
```

### 10.2 MCP Configuration

For Claude Desktop or other MCP clients, add to configuration:

**~/.config/claude/claude_desktop_config.json**:
```json
{
  "mcpServers": {
    "dlang-tools": {
      "command": "/usr/local/bin/dlang-mcp-server",
      "args": [],
      "env": {
        "PATH": "/usr/local/bin:/usr/bin:/bin"
      }
    }
  }
}
```

### 10.3 Usage Examples

Once configured, users can interact with the tools through Claude:

**User**: "Can you analyze this D code for issues?"
```d
void main()
{
    int x=5;
    writeln( x );
}
```

**Claude**: Uses dscanner tool to analyze and reports:
- Style issues (spacing around `=`, spacing in function calls)
- Suggests improvements

**User**: "Format this D code properly"

**Claude**: Uses dfmt tool to return formatted code

---

## 11. Advanced Features (Future Enhancements)

### 11.1 Configuration File Support
- Allow users to provide custom dscanner.ini
- Support dfmt.toml configurations
- Server-level configuration file

### 11.2 Batch Processing
- Analyze multiple files at once
- Support for project-wide analysis
- Caching of analysis results

### 11.3 Incremental Analysis
- Only re-analyze changed code
- Store analysis state between calls

### 11.4 Additional Tools
- **dub**: Package management and building
- **dmd**: Direct compilation with error reporting
- **dcd**: Auto-completion daemon integration
- **ddox**: Documentation generation

### 11.5 Resource Support
- Expose D documentation as MCP resources
- Provide access to standard library docs
- Link to language reference

---

## 12. Implementation Timeline

### Phase 1: Foundation (Week 1)
- [ ] Set up project structure
- [ ] Implement JSON-RPC protocol handler
- [ ] Implement stdio transport
- [ ] Basic MCP server with initialize and tools/list
- [ ] Unit tests for protocol layer

### Phase 2: Core Tools (Week 2)
- [ ] Implement dscanner tool
- [ ] Implement dfmt tool
- [ ] Process execution utilities
- [ ] Tool unit tests
- [ ] Integration tests

### Phase 3: Polish and Testing (Week 3)
- [ ] Error handling improvements
- [ ] Logging system
- [ ] End-to-end tests
- [ ] Documentation
- [ ] Manual testing with MCP clients

### Phase 4: Release (Week 4)
- [ ] Build scripts
- [ ] Installation documentation
- [ ] Example configurations
- [ ] GitHub repository setup
- [ ] CI/CD pipeline

---

## 13. Key Implementation Details

### 13.1 Thread Safety
Since MCP over stdio is single-threaded (sequential request/response), no special thread safety measures needed.

### 13.2 Memory Management
- Use D's garbage collector for most allocations
- Explicitly clean up temp files
- No special memory management needed for short-lived process

### 13.3 Performance Considerations
- Minimize temp file I/O
- Consider keeping dscanner/dfmt processes warm (future optimization)
- Cache JSON schemas

### 13.4 Security Considerations
- Validate all input parameters
- Sanitize file paths (prevent directory traversal)
- Limit code size to prevent DOS
- Use temp directory for file operations
- Never execute user-provided code directly

---

## 14. Success Criteria

The implementation will be considered successful when:

1. ✓ Server correctly implements MCP protocol over stdio
2. ✓ dscanner tool successfully analyzes D code and returns issues
3. ✓ dfmt tool successfully formats D code
4. ✓ All unit tests pass
5. ✓ Integration tests with actual MCP client work
6. ✓ Error handling is robust and user-friendly
7. ✓ Documentation is complete and clear
8. ✓ Installation process is straightforward

---

## 15. Resources and References

### MCP Specification
- https://modelcontextprotocol.io/
- https://github.com/anthropics/model-context-protocol

### D Language Tools
- dscanner: https://github.com/dlang-community/D-Scanner
- dfmt: https://github.com/dlang-community/dfmt
- D language: https://dlang.org/

### JSON-RPC 2.0
- https://www.jsonrpc.org/specification

### Example MCP Servers
- https://github.com/modelcontextprotocol/servers
- Study existing implementations for patterns

---

## Appendix A: Complete Message Examples

### Initialize Request/Response
```json
// Request
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2024-11-05",
    "capabilities": {},
    "clientInfo": {
      "name": "claude-desktop",
      "version": "1.0.0"
    }
  }
}

// Response
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2024-11-05",
    "capabilities": {
      "tools": {
        "listChanged": false
      }
    },
    "serverInfo": {
      "name": "dlang-mcp-server",
      "version": "1.0.0"
    }
  }
}
```

### Tools List Request/Response
```json
// Request
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/list"
}

// Response
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "tools": [
      {
        "name": "dscanner",
        "description": "Analyze D source code for issues, style violations, and potential bugs.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "code": {
              "type": "string",
              "description": "D source code to analyze"
            }
          },
          "required": ["code"]
        }
      },
      {
        "name": "dfmt",
        "description": "Format D source code according to style guidelines.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "code": {
              "type": "string",
              "description": "D source code to format"
            }
          },
          "required": ["code"]
        }
      }
    ]
  }
}
```

### Tools Call Request/Response (dscanner)
```json
// Request
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "dscanner",
    "arguments": {
      "code": "void main() { int x=5; writeln(x); }"
    }
  }
}

// Response
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Style Issues Found:\n\nLine 1: [style] Operator '=' should be surrounded by spaces\nLine 1: [style] Function call arguments should have consistent spacing\n\n2 issues found."
      }
    ]
  }
}
```

---

## Appendix B: Code Style Guidelines

Follow D language best practices:
- Use 4 spaces for indentation
- Brace style: Allman (opening brace on new line)
- CamelCase for classes, camelCase for functions/variables
- Maximum line length: 120 characters
- Use `@property` for getters
- Document public APIs with DDoc comments

Example:
```d
/**
 * Represents an MCP tool that can be executed.
 */
interface Tool
{
    /// Returns the unique name of the tool
    @property string name();
    
    /// Returns a human-readable description
    @property string description();
    
    /**
     * Execute the tool with given arguments.
     * 
     * Params:
     *   arguments = JSON object containing tool parameters
     * 
     * Returns: The result of tool execution
     */
    ToolResult execute(JSONValue arguments);
}
```

---

## End of Plan
