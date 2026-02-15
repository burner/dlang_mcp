module mcp.server;

import std.json : JSONValue, parseJSON, JSONType;
import mcp.types : JsonRpcResponse, JsonRpcRequest, ServerCapabilities,
	ServerInfo, ToolsCapability, ToolDefinition, ToolResult;
import mcp.protocol : parseRequest, serializeResponse, createErrorResponse,
	createMethodNotFoundResponse, createInvalidParamsResponse,
	createInternalErrorResponse, nullJSON;
import mcp.transport : StdioTransport, EOFException;
import mcp.transport_interface : Transport;
import tools.base : Tool;
import utils.logging : logInfo, logError;

class MCPServer {
	private Tool[string] tools;
	private bool initialized = false;

	void registerTool(Tool tool)
	{
		tools[tool.name] = tool;
	}

	void start(Transport transport)
	{
		logInfo("MCP Server starting");

		while(true) {
			try {
				string message = transport.readMessage();
				logInfo("Received: " ~ message);

				auto request = parseRequest(message);
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

	JsonRpcResponse handleRequest(ref const JsonRpcRequest request)
	{
		JsonRpcResponse response;
		response.jsonrpc = "2.0";
		response.id = request.id;

		switch(request.method) {
		case "initialize":
			return handleInitialize(request.id, request.params);
		case "tools/list":
			return handleToolsList(request.id);
		case "tools/call":
			return handleToolsCall(request.id, request.params);
		case "notifications/initialized":
			return JsonRpcResponse("2.0", request.id, nullJSON(), nullJSON());
		default:
			return createMethodNotFoundResponse(request.id, request.method);
		}
	}

	JsonRpcResponse handleInitialize(int id, JSONValue params)
	{
		initialized = true;

		ServerCapabilities caps;
		caps.tools = ToolsCapability(false);

		JSONValue result;
		result["protocolVersion"] = JSONValue("2024-11-05");
		result["capabilities"] = caps.toJSON();
		result["serverInfo"] = ServerInfo("dlang_mcp", "1.0.0").toJSON();

		JsonRpcResponse response;
		response.jsonrpc = "2.0";
		response.id = id;
		response.result = result;
		return response;
	}

	JsonRpcResponse handleToolsList(int id)
	{
		JSONValue[] toolArray;
		foreach(tool; tools.byValue) {
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

	JsonRpcResponse handleToolsCall(int id, JSONValue params)
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
			return createInternalErrorResponse(id, "Tool execution failed: " ~ e.msg);
		}
	}
}
