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
