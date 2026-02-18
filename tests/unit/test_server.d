/**
 * Unit tests for MCP server request dispatch, lifecycle, tool invocation,
 * and notification handling.
 *
 * Tests cover mcp.server module using mock tools.
 */
module tests.unit.test_server;

import std.stdio;
import std.json;
import std.algorithm.searching : canFind;
import mcp.server;
import mcp.protocol;
import mcp.types;
import tools.base;

// ============================================================
// Mock Tools
// ============================================================

/// A mock tool that echoes back its input for testing.
class MockTool : BaseTool {
	@property string name()
	{
		return "test_tool";
	}

	@property string description()
	{
		return "A mock tool for testing";
	}

	@property JSONValue inputSchema()
	{
		return parseJSON(
				`{"type":"object","properties":{"input":{"type":"string"}},"required":["input"]}`);
	}

	ToolResult execute(JSONValue arguments)
	{
		if("input" in arguments && arguments["input"].type == JSONType.string)
			return createTextResult("echo: " ~ arguments["input"].str);
		return createTextResult("no input");
	}
}

/// A mock tool that always throws during execution.
class FailingTool : BaseTool {
	@property string name()
	{
		return "failing_tool";
	}

	@property string description()
	{
		return "A tool that always fails";
	}

	@property JSONValue inputSchema()
	{
		return parseJSON(`{"type":"object","properties":{}}`);
	}

	ToolResult execute(JSONValue arguments)
	{
		throw new Exception("Intentional test failure");
	}
}

class ServerTests {
	void runAll()
	{
		// Initialization Lifecycle
		testToolsListBeforeInit();
		testToolsCallBeforeInit();
		testInitialize();
		testInitializeResponseStructure();
		testDoubleInitialize();
		testToolsListAfterInit();

		// Request Dispatch
		testDispatchInitialize();
		testDispatchToolsList();
		testDispatchToolsCall();
		testDispatchPing();
		testDispatchResourcesList();
		testDispatchPromptsList();
		testDispatchUnknownMethod();

		// Notification Handling
		testNotificationNoResponse();
		testNotificationInitialized();
		testNotificationCancelled();
		testNotificationUnknown();

		// Tool Invocation
		testToolsCallSuccess();
		testToolsCallMissingName();
		testToolsCallUnknownTool();
		testToolsCallMissingArguments();
		testToolsCallToolThrows();
		testToolsCallToolThrowsHasErrorMessage();

		// Tools List Response Structure
		testToolsListContainsAllRegistered();
		testToolsListToolStructure();

		writeln("  All server tests passed.");
	}

	/// Creates a fresh server with MockTool and FailingTool registered.
	private MCPServer createServer()
	{
		auto server = new MCPServer();
		server.registerTool(new MockTool());
		server.registerTool(new FailingTool());
		return server;
	}

	/// Helper to initialize a server (calls handleInitialize).
	private void initServer(MCPServer server)
	{
		server.handleInitialize(JSONValue(1), JSONValue(cast(string[string])null));
	}

	/// Creates a JsonRpcRequest struct for testing.
	private JsonRpcRequest makeRequest(string method, JSONValue id,
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

	/// Creates a notification request (no id).
	private JsonRpcRequest makeNotification(string method)
	{
		JsonRpcRequest req;
		req.jsonrpc = "2.0";
		req.method = method;
		req.id = JSONValue(null);
		req.isNotification = true;
		return req;
	}

	// ============================================================
	// Initialization Lifecycle
	// ============================================================

	void testToolsListBeforeInit()
	{
		auto server = createServer();
		// Don't call handleInitialize
		auto resp = server.handleToolsList(JSONValue(1));
		assert(resp.error.type != JSONType.null_, "Should return error before init");
		assert(resp.error["code"].integer == JsonRpcErrorCode.InvalidParams,
				"Should be InvalidParams error");
		writeln("    [PASS] testToolsListBeforeInit");
	}

	void testToolsCallBeforeInit()
	{
		auto server = createServer();
		auto params = parseJSON(`{"name":"test_tool","arguments":{"input":"hi"}}`);
		auto resp = server.handleToolsCall(JSONValue(1), params);
		assert(resp.error.type != JSONType.null_, "Should return error before init");
		assert(resp.error["code"].integer == JsonRpcErrorCode.InvalidParams,
				"Should be InvalidParams error");
		writeln("    [PASS] testToolsCallBeforeInit");
	}

	void testInitialize()
	{
		auto server = createServer();
		auto resp = server.handleInitialize(JSONValue(1), JSONValue(cast(string[string])null));
		assert(resp.error.type == JSONType.null_, "Initialize should not return error");
		assert(resp.result.type != JSONType.null_, "Initialize should return result");
		writeln("    [PASS] testInitialize");
	}

	void testInitializeResponseStructure()
	{
		auto server = createServer();
		auto resp = server.handleInitialize(JSONValue(1), JSONValue(cast(string[string])null));
		auto result = resp.result;

		assert(result["protocolVersion"].str == "2024-11-05",
				"Protocol version should be '2024-11-05'");
		assert("capabilities" in result, "Should have capabilities");
		assert("tools" in result["capabilities"], "Capabilities should have tools");
		assert("serverInfo" in result, "Should have serverInfo");
		assert(result["serverInfo"]["name"].str.length > 0, "Server name should not be empty");
		writeln("    [PASS] testInitializeResponseStructure");
	}

	void testDoubleInitialize()
	{
		auto server = createServer();
		auto resp1 = server.handleInitialize(JSONValue(1), JSONValue(cast(string[string])null));
		auto resp2 = server.handleInitialize(JSONValue(2), JSONValue(cast(string[string])null));
		assert(resp2.error.type == JSONType.null_, "Second initialize should also succeed");
		writeln("    [PASS] testDoubleInitialize");
	}

	void testToolsListAfterInit()
	{
		auto server = createServer();
		initServer(server);
		auto resp = server.handleToolsList(JSONValue(1));
		assert(resp.error.type == JSONType.null_, "Should not return error after init");
		auto tools = resp.result["tools"].array;
		assert(tools.length >= 2, "Should have at least 2 registered tools");
		writeln("    [PASS] testToolsListAfterInit");
	}

	// ============================================================
	// Request Dispatch
	// ============================================================

	void testDispatchInitialize()
	{
		auto server = createServer();
		auto req = makeRequest("initialize", JSONValue(1), JSONValue(cast(string[string])null));
		auto resp = server.handleRequest(req);
		assert(resp.error.type == JSONType.null_, "Initialize dispatch should succeed");
		assert("protocolVersion" in resp.result, "Should have protocolVersion in result");
		writeln("    [PASS] testDispatchInitialize");
	}

	void testDispatchToolsList()
	{
		auto server = createServer();
		initServer(server);
		auto req = makeRequest("tools/list", JSONValue(2));
		auto resp = server.handleRequest(req);
		assert(resp.error.type == JSONType.null_, "tools/list dispatch should succeed");
		assert("tools" in resp.result, "Should have tools in result");
		writeln("    [PASS] testDispatchToolsList");
	}

	void testDispatchToolsCall()
	{
		auto server = createServer();
		initServer(server);
		auto params = parseJSON(`{"name":"test_tool","arguments":{"input":"hello"}}`);
		auto req = makeRequest("tools/call", JSONValue(3), params);
		auto resp = server.handleRequest(req);
		assert(resp.error.type == JSONType.null_, "tools/call dispatch should succeed");
		writeln("    [PASS] testDispatchToolsCall");
	}

	void testDispatchPing()
	{
		auto server = createServer();
		auto req = makeRequest("ping", JSONValue(4));
		auto resp = server.handleRequest(req);
		assert(resp.error.type == JSONType.null_, "ping should succeed");
		// Ping returns empty object {}
		assert(resp.result.type == JSONType.object, "Ping result should be an object");
		writeln("    [PASS] testDispatchPing");
	}

	void testDispatchResourcesList()
	{
		auto server = createServer();
		auto req = makeRequest("resources/list", JSONValue(5));
		auto resp = server.handleRequest(req);
		assert(resp.error.type == JSONType.null_, "resources/list should succeed");
		assert("resources" in resp.result, "Should have resources key");
		assert(resp.result["resources"].array.length == 0, "Resources should be empty");
		writeln("    [PASS] testDispatchResourcesList");
	}

	void testDispatchPromptsList()
	{
		auto server = createServer();
		auto req = makeRequest("prompts/list", JSONValue(6));
		auto resp = server.handleRequest(req);
		assert(resp.error.type == JSONType.null_, "prompts/list should succeed");
		assert("prompts" in resp.result, "Should have prompts key");
		assert(resp.result["prompts"].array.length == 0, "Prompts should be empty");
		writeln("    [PASS] testDispatchPromptsList");
	}

	void testDispatchUnknownMethod()
	{
		auto server = createServer();
		auto req = makeRequest("nonexistent/method", JSONValue(7));
		auto resp = server.handleRequest(req);
		assert(resp.error.type != JSONType.null_, "Unknown method should return error");
		assert(resp.error["code"].integer == JsonRpcErrorCode.MethodNotFound,
				"Should be MethodNotFound error (-32601)");
		writeln("    [PASS] testDispatchUnknownMethod");
	}

	// ============================================================
	// Notification Handling
	// ============================================================

	void testNotificationNoResponse()
	{
		// Verify that notifications have isNotification == true,
		// which the main loop uses to skip response generation.
		auto req = parseRequest(`{"jsonrpc":"2.0","method":"notifications/initialized"}`);
		assert(req.isNotification, "Notification should have isNotification == true");
		writeln("    [PASS] testNotificationNoResponse");
	}

	void testNotificationInitialized()
	{
		// Verify that a notification for "notifications/initialized" parses correctly
		// and has the isNotification flag set. The server's main loop uses this flag
		// to route to handleNotification (package-visible) instead of handleRequest.
		auto req = parseRequest(`{"jsonrpc":"2.0","method":"notifications/initialized"}`);
		assert(req.isNotification, "notifications/initialized should be a notification");
		assert(req.method == "notifications/initialized", "Method should match");
		writeln("    [PASS] testNotificationInitialized");
	}

	void testNotificationCancelled()
	{
		// Verify notification parsing for cancelled
		auto req = parseRequest(`{"jsonrpc":"2.0","method":"notifications/cancelled"}`);
		assert(req.isNotification, "notifications/cancelled should be a notification");
		assert(req.method == "notifications/cancelled", "Method should match");
		writeln("    [PASS] testNotificationCancelled");
	}

	void testNotificationUnknown()
	{
		// Unknown notification methods should still parse as notifications
		auto req = parseRequest(`{"jsonrpc":"2.0","method":"notifications/unknown"}`);
		assert(req.isNotification, "Unknown notification should still be a notification");
		writeln("    [PASS] testNotificationUnknown");
	}

	// ============================================================
	// Tool Invocation
	// ============================================================

	void testToolsCallSuccess()
	{
		auto server = createServer();
		initServer(server);
		auto params = parseJSON(`{"name":"test_tool","arguments":{"input":"world"}}`);
		auto resp = server.handleToolsCall(JSONValue(1), params);
		assert(resp.error.type == JSONType.null_, "Successful tool call should not have error");
		// Result should contain the echo
		auto resultJson = resp.result;
		assert("content" in resultJson, "Tool result should have 'content'");
		auto content = resultJson["content"].array;
		assert(content.length > 0, "Should have content");
		assert(content[0]["text"].str.canFind("echo: world"), "Tool should echo back 'world'");
		writeln("    [PASS] testToolsCallSuccess");
	}

	void testToolsCallMissingName()
	{
		auto server = createServer();
		initServer(server);
		auto params = parseJSON(`{"arguments":{"input":"test"}}`);
		auto resp = server.handleToolsCall(JSONValue(1), params);
		assert(resp.error.type != JSONType.null_, "Missing name should return error");
		assert(resp.error["code"].integer == JsonRpcErrorCode.InvalidParams,
				"Should be InvalidParams error");
		writeln("    [PASS] testToolsCallMissingName");
	}

	void testToolsCallUnknownTool()
	{
		auto server = createServer();
		initServer(server);
		auto params = parseJSON(`{"name":"nonexistent_tool","arguments":{}}`);
		auto resp = server.handleToolsCall(JSONValue(1), params);
		assert(resp.error.type != JSONType.null_, "Unknown tool should return error");
		assert(resp.error["message"].str.canFind("Unknown tool"),
				"Error should mention 'Unknown tool'");
		writeln("    [PASS] testToolsCallUnknownTool");
	}

	void testToolsCallMissingArguments()
	{
		auto server = createServer();
		initServer(server);
		// Call test_tool with no "arguments" key - server provides empty {}
		auto params = parseJSON(`{"name":"test_tool"}`);
		auto resp = server.handleToolsCall(JSONValue(1), params);
		assert(resp.error.type == JSONType.null_,
				"Missing arguments should not crash - server provides empty {}");
		auto content = resp.result["content"].array;
		assert(content[0]["text"].str.canFind("no input"),
				"Tool should handle missing input gracefully");
		writeln("    [PASS] testToolsCallMissingArguments");
	}

	void testToolsCallToolThrows()
	{
		auto server = createServer();
		initServer(server);
		auto params = parseJSON(`{"name":"failing_tool","arguments":{}}`);
		auto resp = server.handleToolsCall(JSONValue(1), params);
		// Per MCP spec: tool execution failures are NOT JSON-RPC errors.
		// They return a successful JSON-RPC response with isError: true in the result.
		assert(resp.error.type == JSONType.null_, "Tool failure should NOT produce JSON-RPC error");
		assert(resp.result["isError"].type == JSONType.true_,
				"Tool result should have isError: true");
		writeln("    [PASS] testToolsCallToolThrows");
	}

	void testToolsCallToolThrowsHasErrorMessage()
	{
		auto server = createServer();
		initServer(server);
		auto params = parseJSON(`{"name":"failing_tool","arguments":{}}`);
		auto resp = server.handleToolsCall(JSONValue(1), params);
		auto content = resp.result["content"].array;
		assert(content.length > 0, "Should have error content");
		assert(content[0]["text"].str.canFind("Intentional test failure"),
				"Error content should contain the exception message");
		writeln("    [PASS] testToolsCallToolThrowsHasErrorMessage");
	}

	// ============================================================
	// Tools List Response Structure
	// ============================================================

	void testToolsListContainsAllRegistered()
	{
		auto server = createServer();
		initServer(server);
		auto resp = server.handleToolsList(JSONValue(1));
		auto tools = resp.result["tools"].array;
		assert(tools.length == 2,
				"Should have exactly 2 registered tools (test_tool and failing_tool)");
		writeln("    [PASS] testToolsListContainsAllRegistered");
	}

	void testToolsListToolStructure()
	{
		auto server = createServer();
		initServer(server);
		auto resp = server.handleToolsList(JSONValue(1));
		auto tools = resp.result["tools"].array;
		foreach(tool; tools) {
			assert("name" in tool, "Each tool should have 'name'");
			assert("description" in tool, "Each tool should have 'description'");
			assert("inputSchema" in tool, "Each tool should have 'inputSchema'");
			assert(tool["name"].str.length > 0, "Tool name should not be empty");
			assert(tool["description"].str.length > 0, "Tool description should not be empty");
		}
		writeln("    [PASS] testToolsListToolStructure");
	}
}
