/**
 * Core MCP server that dispatches JSON-RPC requests to registered tools.
 *
 * Implements the Model Context Protocol server lifecycle including initialization,
 * tool registration, tool listing, and tool invocation. Communicates with clients
 * over a pluggable `Transport` abstraction.
 */
module mcp.server;

import std.algorithm : sort;
import std.array : array;
import std.json : JSONValue, parseJSON;
import mcp.types : JsonRpcResponse, JsonRpcRequest, ServerCapabilities,
	ServerInfo, ToolsCapability, ToolDefinition, ToolResult;
import mcp.protocol : parseRequest, serializeResponse, createErrorResponse, createMethodNotFoundResponse,
	createInvalidParamsResponse, createInternalErrorResponse,
	createParseErrorResponse, ProtocolException;
import mcp.transport : StdioTransport, EOFException;
import mcp.transport_interface : Transport;
import tools.base : Tool;
import utils.logging : logInfo, logError, logDebug;

/**
 * The MCP server that manages tool registration and handles JSON-RPC requests.
 *
 * Supports the MCP protocol methods: `initialize`, `tools/list`, `tools/call`,
 * and `notifications/initialized`. Tools are registered before starting the
 * server, and requests are dispatched to the appropriate handler based on
 * the JSON-RPC method name.
 */
class MCPServer {
	private Tool[string] tools;
	private bool initialized = false;

	/**
	 * Registers a tool that can be invoked via `tools/call` requests.
	 *
	 * Params:
	 *     tool = The tool instance to register, keyed by its name.
	 */
	void registerTool(Tool tool)
	{
		tools[tool.name] = tool;
	}

	/**
	 * Starts the server's main request loop on the given transport.
	 *
	 * Reads JSON-RPC messages from the transport, dispatches them to `handleRequest`,
	 * and writes serialized responses back. Notifications (requests without an id)
	 * are processed but produce no response. The loop terminates when the client
	 * disconnects (EOF) or the transport is closed.
	 *
	 * Parse errors and invalid requests produce proper JSON-RPC error responses
	 * instead of being silently swallowed.
	 *
	 * Params:
	 *     transport = The message transport to read from and write to.
	 */
	void start(Transport transport)
	{
		logInfo("MCP Server starting");

		while(true) {
			try {
				string message = transport.readMessage();
				logDebug("Received: " ~ message);

				JsonRpcRequest request;
				try {
					request = parseRequest(message);
				} catch(ProtocolException e) {
					// Send a JSON-RPC parse/invalid-request error back to the client
					logError("Parse error: " ~ e.msg);
					auto errResponse = createParseErrorResponse();
					transport.writeMessage(serializeResponse(errResponse));
					continue;
				}

				// Notifications (no id) must not receive a response per JSON-RPC 2.0
				if(request.isNotification) {
					handleNotification(request);
					continue;
				}

				auto response = handleRequest(request);
				transport.writeMessage(serializeResponse(response));
			} catch(EOFException e) {
				logInfo("Client disconnected");
				break;
			} catch(Exception e) {
				logError("Error: " ~ e.msg);
			}
		}
	}

	/**
	 * Handles a JSON-RPC notification (a request with no id).
	 *
	 * Per JSON-RPC 2.0, notifications must not produce a response.
	 * Currently recognizes `notifications/initialized`.
	 *
	 * Params:
	 *     request = The notification request.
	 */
	package void handleNotification(ref const JsonRpcRequest request)
	{
		switch(request.method) {
		case "notifications/initialized":
			logDebug("Client sent notifications/initialized");
			break;
		default:
			logDebug("Unknown notification: " ~ request.method);
			break;
		}
	}

	/**
	 * Dispatches a parsed JSON-RPC request to the appropriate handler method.
	 *
	 * Params:
	 *     request = The parsed request containing method name and parameters.
	 *
	 * Returns: A `JsonRpcResponse` with the result or an error.
	 */
	JsonRpcResponse handleRequest(ref const JsonRpcRequest request)
	{
		switch(request.method) {
		case "initialize":
			return handleInitialize(request.id, request.params);
		case "tools/list":
			return handleToolsList(request.id);
		case "tools/call":
			return handleToolsCall(request.id, request.params);
		case "ping":
			JsonRpcResponse pingResponse;
			pingResponse.jsonrpc = "2.0";
			pingResponse.id = request.id;
			pingResponse.result = JSONValue(cast(string[string])null);
			return pingResponse;
		case "resources/list":
			JsonRpcResponse resListResponse;
			resListResponse.jsonrpc = "2.0";
			resListResponse.id = request.id;
			JSONValue resListResult;
			resListResult["resources"] = JSONValue(cast(JSONValue[])[]);
			resListResponse.result = resListResult;
			return resListResponse;
		case "prompts/list":
			JsonRpcResponse promptsResponse;
			promptsResponse.jsonrpc = "2.0";
			promptsResponse.id = request.id;
			JSONValue promptsResult;
			promptsResult["prompts"] = JSONValue(cast(JSONValue[])[]);
			promptsResponse.result = promptsResult;
			return promptsResponse;
		default:
			return createMethodNotFoundResponse(request.id, request.method);
		}
	}

	/**
	 * Handles the `initialize` method, performing the MCP handshake.
	 *
	 * Returns server capabilities and version info to the client.
	 *
	 * Params:
	 *     id = The JSON-RPC request identifier.
	 *     params = Initialization parameters from the client (currently unused).
	 *
	 * Returns: A response containing protocol version, capabilities, and server info.
	 */
	JsonRpcResponse handleInitialize(JSONValue id, JSONValue params)
	{
		initialized = true;

		ServerCapabilities caps;
		caps.tools = ToolsCapability(false);

		auto serverInfo = ServerInfo("dlang_mcp", "1.0.0").toJSON();

		JSONValue result;
		result["protocolVersion"] = JSONValue("2024-11-05");
		result["capabilities"] = caps.toJSON();
		result["serverInfo"] = serverInfo;

		JsonRpcResponse response;
		response.jsonrpc = "2.0";
		response.id = id;
		response.result = result;
		return response;
	}

	/**
	 * Handles the `tools/list` method, returning all registered tool definitions.
	 *
	 * Tools are returned in sorted order by name for deterministic output.
	 *
	 * Params:
	 *     id = The JSON-RPC request identifier.
	 *
	 * Returns: A response containing an array of tool definitions with names,
	 *          descriptions, and input schemas.
	 */
	JsonRpcResponse handleToolsList(JSONValue id)
	{
		if(!initialized) {
			return createInvalidParamsResponse(id, "Server not initialized");
		}

		// Sort tool names for deterministic ordering
		auto sortedNames = tools.keys.array.sort().array;

		JSONValue[] toolArray;
		foreach(name; sortedNames) {
			auto tool = tools[name];
			toolArray ~= ToolDefinition(tool.name, tool.description, tool.inputSchema).toJSON();
		}

		JSONValue result;
		result["tools"] = JSONValue(toolArray);

		JsonRpcResponse response;
		response.jsonrpc = "2.0";
		response.id = id;
		response.result = result;
		return response;
	}

	/**
	 * Handles the `tools/call` method, executing a named tool with the given arguments.
	 *
	 * Validates that the server is initialized, the tool name exists, and delegates
	 * execution to the tool's `execute` method. Returns the tool's result or an
	 * appropriate error response.
	 *
	 * Params:
	 *     id = The JSON-RPC request identifier.
	 *     params = Must contain a "name" field and optionally an "arguments" object.
	 *
	 * Returns: A response containing the tool result or an error.
	 */
	JsonRpcResponse handleToolsCall(JSONValue id, JSONValue params)
	{
		if(!initialized) {
			return createInvalidParamsResponse(id, "Server not initialized");
		}

		string toolName;
		try {
			toolName = params["name"].str;
		} catch(Exception e) {
			return createInvalidParamsResponse(id, "Missing 'name' in params");
		}

		if(toolName !in tools) {
			return createInvalidParamsResponse(id, "Unknown tool: " ~ toolName);
		}

		JSONValue arguments;
		try {
			arguments = params["arguments"];
		} catch(Exception e) {
			JSONValue[string] empty;
			arguments = JSONValue(empty);
		}

		try {
			auto result = tools[toolName].execute(arguments);
			JsonRpcResponse response;
			response.jsonrpc = "2.0";
			response.id = id;
			response.result = result.toJSON();
			return response;
		} catch(Exception e) {
			logError("Tool execution error: " ~ e.msg);
			// Return a successful JSON-RPC response with isError: true.
			// Per MCP spec, tool execution failures should NOT be JSON-RPC errors;
			// those are reserved for protocol-level issues.
			import mcp.types : Content;

			auto errorResult = ToolResult([
				Content("text", "Tool execution failed: " ~ e.msg)
			], true);
			JsonRpcResponse response;
			response.jsonrpc = "2.0";
			response.id = id;
			response.result = errorResult.toJSON();
			return response;
		}
	}
}

// ===========================================================================
// Unit tests
// ===========================================================================

version(unittest)  : import test_helpers : MockTool, FailingTool;
import std.algorithm.searching : canFind;
import std.json : JSONType;
import mcp.types : JsonRpcErrorCode;

private MCPServer createTestServer()
{
	auto server = new MCPServer();
	server.registerTool(new MockTool());
	server.registerTool(new FailingTool());
	return server;
}

private void initTestServer(MCPServer server)
{
	server.handleInitialize(JSONValue(1), JSONValue(cast(string[string])null));
}

private JsonRpcRequest makeTestRequest(string method, JSONValue id,
		JSONValue params = JSONValue.init)
{
	JsonRpcRequest req;
	req.jsonrpc = "2.0";
	req.method = method;
	req.id = id;
	req.params = params;
	req.isNotification = false;
	return req;
}

private JsonRpcRequest makeTestNotification(string method)
{
	JsonRpcRequest req;
	req.jsonrpc = "2.0";
	req.method = method;
	req.id = JSONValue(null);
	req.isNotification = true;
	return req;
}

// --- Initialization Lifecycle ---

/// tools/list before initialization returns InvalidParams error
unittest {
	auto server = createTestServer();
	auto resp = server.handleToolsList(JSONValue(1));
	assert(resp.error.type != JSONType.null_, "Should return error before init");
	assert(resp.error["code"].integer == JsonRpcErrorCode.InvalidParams,
			"Should be InvalidParams error");
}

/// tools/call before initialization returns InvalidParams error
unittest {
	auto server = createTestServer();
	auto params = parseJSON(`{"name":"test_tool","arguments":{"input":"hi"}}`);
	auto resp = server.handleToolsCall(JSONValue(1), params);
	assert(resp.error.type != JSONType.null_, "Should return error before init");
	assert(resp.error["code"].integer == JsonRpcErrorCode.InvalidParams,
			"Should be InvalidParams error");
}

/// initialize succeeds and returns a result
unittest {
	auto server = createTestServer();
	auto resp = server.handleInitialize(JSONValue(1), JSONValue(cast(string[string])null));
	assert(resp.error.type == JSONType.null_, "Initialize should not return error");
	assert(resp.result.type != JSONType.null_, "Initialize should return result");
}

/// initialize response has correct structure
unittest {
	auto server = createTestServer();
	auto resp = server.handleInitialize(JSONValue(1), JSONValue(cast(string[string])null));
	auto result = resp.result;

	assert(result["protocolVersion"].str == "2024-11-05", "Protocol version should be '2024-11-05'");
	assert("capabilities" in result, "Should have capabilities");
	assert("tools" in result["capabilities"], "Capabilities should have tools");
	assert("serverInfo" in result, "Should have serverInfo");
	assert(result["serverInfo"]["name"].str.length > 0, "Server name should not be empty");
}

/// double initialize succeeds
unittest {
	auto server = createTestServer();
	auto resp1 = server.handleInitialize(JSONValue(1), JSONValue(cast(string[string])null));
	auto resp2 = server.handleInitialize(JSONValue(2), JSONValue(cast(string[string])null));
	assert(resp2.error.type == JSONType.null_, "Second initialize should also succeed");
}

/// tools/list after initialization succeeds
unittest {
	auto server = createTestServer();
	initTestServer(server);
	auto resp = server.handleToolsList(JSONValue(1));
	assert(resp.error.type == JSONType.null_, "Should not return error after init");
	auto tools = resp.result["tools"].array;
	assert(tools.length >= 2, "Should have at least 2 registered tools");
}

// --- Request Dispatch ---

/// dispatch initialize
unittest {
	auto server = createTestServer();
	auto req = makeTestRequest("initialize", JSONValue(1), JSONValue(cast(string[string])null));
	auto resp = server.handleRequest(req);
	assert(resp.error.type == JSONType.null_, "Initialize dispatch should succeed");
	assert("protocolVersion" in resp.result, "Should have protocolVersion in result");
}

/// dispatch tools/list
unittest {
	auto server = createTestServer();
	initTestServer(server);
	auto req = makeTestRequest("tools/list", JSONValue(2));
	auto resp = server.handleRequest(req);
	assert(resp.error.type == JSONType.null_, "tools/list dispatch should succeed");
	assert("tools" in resp.result, "Should have tools in result");
}

/// dispatch tools/call
unittest {
	auto server = createTestServer();
	initTestServer(server);
	auto params = parseJSON(`{"name":"test_tool","arguments":{"input":"hello"}}`);
	auto req = makeTestRequest("tools/call", JSONValue(3), params);
	auto resp = server.handleRequest(req);
	assert(resp.error.type == JSONType.null_, "tools/call dispatch should succeed");
}

/// dispatch ping
unittest {
	auto server = createTestServer();
	auto req = makeTestRequest("ping", JSONValue(4));
	auto resp = server.handleRequest(req);
	assert(resp.error.type == JSONType.null_, "ping should succeed");
	assert(resp.result.type == JSONType.object, "Ping result should be an object");
}

/// dispatch resources/list
unittest {
	auto server = createTestServer();
	auto req = makeTestRequest("resources/list", JSONValue(5));
	auto resp = server.handleRequest(req);
	assert(resp.error.type == JSONType.null_, "resources/list should succeed");
	assert("resources" in resp.result, "Should have resources key");
	assert(resp.result["resources"].array.length == 0, "Resources should be empty");
}

/// dispatch prompts/list
unittest {
	auto server = createTestServer();
	auto req = makeTestRequest("prompts/list", JSONValue(6));
	auto resp = server.handleRequest(req);
	assert(resp.error.type == JSONType.null_, "prompts/list should succeed");
	assert("prompts" in resp.result, "Should have prompts key");
	assert(resp.result["prompts"].array.length == 0, "Prompts should be empty");
}

/// dispatch unknown method returns MethodNotFound
unittest {
	auto server = createTestServer();
	auto req = makeTestRequest("nonexistent/method", JSONValue(7));
	auto resp = server.handleRequest(req);
	assert(resp.error.type != JSONType.null_, "Unknown method should return error");
	assert(resp.error["code"].integer == JsonRpcErrorCode.MethodNotFound,
			"Should be MethodNotFound error (-32601)");
}

// --- Notification Handling ---

/// notification has isNotification flag
unittest {
	auto req = parseRequest(`{"jsonrpc":"2.0","method":"notifications/initialized"}`);
	assert(req.isNotification, "Notification should have isNotification == true");
}

/// notifications/initialized parses correctly
unittest {
	auto req = parseRequest(`{"jsonrpc":"2.0","method":"notifications/initialized"}`);
	assert(req.isNotification, "notifications/initialized should be a notification");
	assert(req.method == "notifications/initialized", "Method should match");
}

/// notifications/cancelled parses correctly
unittest {
	auto req = parseRequest(`{"jsonrpc":"2.0","method":"notifications/cancelled"}`);
	assert(req.isNotification, "notifications/cancelled should be a notification");
	assert(req.method == "notifications/cancelled", "Method should match");
}

/// unknown notification still parses as notification
unittest {
	auto req = parseRequest(`{"jsonrpc":"2.0","method":"notifications/unknown"}`);
	assert(req.isNotification, "Unknown notification should still be a notification");
}

// --- Tool Invocation ---

/// tools/call succeeds with valid input
unittest {
	auto server = createTestServer();
	initTestServer(server);
	auto params = parseJSON(`{"name":"test_tool","arguments":{"input":"world"}}`);
	auto resp = server.handleToolsCall(JSONValue(1), params);
	assert(resp.error.type == JSONType.null_, "Successful tool call should not have error");
	auto resultJson = resp.result;
	assert("content" in resultJson, "Tool result should have 'content'");
	auto content = resultJson["content"].array;
	assert(content.length > 0, "Should have content");
	assert(content[0]["text"].str.canFind("echo: world"), "Tool should echo back 'world'");
}

/// tools/call with missing name returns InvalidParams
unittest {
	auto server = createTestServer();
	initTestServer(server);
	auto params = parseJSON(`{"arguments":{"input":"test"}}`);
	auto resp = server.handleToolsCall(JSONValue(1), params);
	assert(resp.error.type != JSONType.null_, "Missing name should return error");
	assert(resp.error["code"].integer == JsonRpcErrorCode.InvalidParams,
			"Should be InvalidParams error");
}

/// tools/call with unknown tool returns error
unittest {
	auto server = createTestServer();
	initTestServer(server);
	auto params = parseJSON(`{"name":"nonexistent_tool","arguments":{}}`);
	auto resp = server.handleToolsCall(JSONValue(1), params);
	assert(resp.error.type != JSONType.null_, "Unknown tool should return error");
	assert(resp.error["message"].str.canFind("Unknown tool"), "Error should mention 'Unknown tool'");
}

/// tools/call with missing arguments provides empty object
unittest {
	auto server = createTestServer();
	initTestServer(server);
	auto params = parseJSON(`{"name":"test_tool"}`);
	auto resp = server.handleToolsCall(JSONValue(1), params);
	assert(resp.error.type == JSONType.null_,
			"Missing arguments should not crash - server provides empty {}");
	auto content = resp.result["content"].array;
	assert(content[0]["text"].str.canFind("no input"),
			"Tool should handle missing input gracefully");
}

/// tools/call with throwing tool returns isError: true (not JSON-RPC error)
unittest {
	import utils.logging : setLogLevel, getLogLevel, LogLevel;

	auto savedLevel = getLogLevel();
	setLogLevel(LogLevel.silent);
	scope(exit)
		setLogLevel(savedLevel);

	auto server = createTestServer();
	initTestServer(server);
	auto params = parseJSON(`{"name":"failing_tool","arguments":{}}`);
	auto resp = server.handleToolsCall(JSONValue(1), params);
	assert(resp.error.type == JSONType.null_, "Tool failure should NOT produce JSON-RPC error");
	assert(resp.result["isError"].type == JSONType.true_, "Tool result should have isError: true");
}

/// tools/call with throwing tool includes error message in content
unittest {
	import utils.logging : setLogLevel, getLogLevel, LogLevel;

	auto savedLevel = getLogLevel();
	setLogLevel(LogLevel.silent);
	scope(exit)
		setLogLevel(savedLevel);

	auto server = createTestServer();
	initTestServer(server);
	auto params = parseJSON(`{"name":"failing_tool","arguments":{}}`);
	auto resp = server.handleToolsCall(JSONValue(1), params);
	auto content = resp.result["content"].array;
	assert(content.length > 0, "Should have error content");
	assert(content[0]["text"].str.canFind("Intentional test failure"),
			"Error content should contain the exception message");
}

// --- Tools List Response Structure ---

/// tools/list contains all registered tools
unittest {
	auto server = createTestServer();
	initTestServer(server);
	auto resp = server.handleToolsList(JSONValue(1));
	auto tools = resp.result["tools"].array;
	assert(tools.length == 2, "Should have exactly 2 registered tools (test_tool and failing_tool)");
}

/// tools/list tool entries have correct structure
unittest {
	auto server = createTestServer();
	initTestServer(server);
	auto resp = server.handleToolsList(JSONValue(1));
	auto tools = resp.result["tools"].array;
	foreach(tool; tools) {
		assert("name" in tool, "Each tool should have 'name'");
		assert("description" in tool, "Each tool should have 'description'");
		assert("inputSchema" in tool, "Each tool should have 'inputSchema'");
		assert(tool["name"].str.length > 0, "Tool name should not be empty");
		assert(tool["description"].str.length > 0, "Tool description should not be empty");
	}
}
