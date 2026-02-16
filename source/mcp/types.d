/**
 * MCP protocol type definitions for JSON-RPC 2.0 communication.
 *
 * Defines the core data structures used throughout the MCP server for
 * request/response serialization, error reporting, tool definitions,
 * and server capability negotiation.
 */
module mcp.types;

import std.json : JSONValue, JSONType;

/** Standard JSON-RPC 2.0 error codes as defined by the specification. */
enum JsonRpcErrorCode {
	ParseError = -32700,
	InvalidRequest = -32600,
	MethodNotFound = -32601,
	InvalidParams = -32602,
	InternalError = -32603
}

/** A JSON-RPC 2.0 request message received from a client. */
struct JsonRpcRequest {
	string jsonrpc; /// Protocol version string, always "2.0".
	JSONValue id; /// Request identifier (string, number, or null per JSON-RPC 2.0). Absent for notifications.
	string method; /// The method name to invoke (e.g. "tools/call").
	JSONValue params; /// Optional parameters for the method.
	bool isNotification; /// True if this is a notification (no "id" field).

	/**
	 * Deserializes a `JsonRpcRequest` from a parsed JSON object.
	 *
	 * Handles string, integer, and null id values per JSON-RPC 2.0.
	 * If "id" is absent, the request is treated as a notification.
	 *
	 * Params:
	 *     json = A `JSONValue` object containing jsonrpc, method, and optionally id and params fields.
	 *
	 * Returns: A populated `JsonRpcRequest` struct.
	 */
	static JsonRpcRequest fromJSON(JSONValue json)
	{
		JsonRpcRequest req;
		req.jsonrpc = json["jsonrpc"].str;
		req.method = json["method"].str;

		if("id" in json)
		{
			req.id = json["id"];
			req.isNotification = false;
		}
		else
		{
			req.id = JSONValue(null);
			req.isNotification = true;
		}

		if("params" in json)
			req.params = json["params"];
		return req;
	}
}

/** A JSON-RPC 2.0 error object included in error responses. */
struct JsonRpcError {
	int code; /// Numeric error code (see `JsonRpcErrorCode`).
	string message; /// Human-readable error description.
	JSONValue data; /// Optional additional error data.

	/**
	 * Serializes this error to a JSON object.
	 *
	 * Returns: A `JSONValue` containing code, message, and optionally data fields.
	 */
	JSONValue toJSON() const
	{
		JSONValue result;
		result["code"] = JSONValue(code);
		result["message"] = JSONValue(message);
		if(data.type != JSONType.null_)
			result["data"] = data;
		return result;
	}
}

/**
 * A JSON-RPC 2.0 response message sent back to a client.
 *
 * Contains either a `result` (on success) or an `error` (on failure), never both.
 */
struct JsonRpcResponse {
	string jsonrpc; /// Protocol version string, always "2.0".
	JSONValue id; /// Request identifier matching the originating request.
	JSONValue result; /// The result payload on success.
	JSONValue error; /// The error payload on failure.

	/**
	 * Serializes this response to a JSON object.
	 *
	 * Returns: A `JSONValue` containing jsonrpc, id, and either result or error.
	 */
	JSONValue toJSON() const
	{
		JSONValue json;
		json["jsonrpc"] = JSONValue(jsonrpc);
		json["id"] = id;

		if(error.type != JSONType.null_) {
			json["error"] = error;
		} else {
			json["result"] = result;
		}
		return json;
	}
}

/** Metadata about the MCP server, sent during the initialize handshake. */
struct ServerInfo {
	string name; /// The server's display name.
	string version_; /// The server's version string.

	/**
	 * Serializes this server info to a JSON object.
	 *
	 * Returns: A `JSONValue` with name and version fields.
	 */
	JSONValue toJSON() const
	{
		JSONValue json;
		json["name"] = JSONValue(name);
		json["version"] = JSONValue(version_);
		return json;
	}
}

/** Declares the server's tool-related capabilities. */
struct ToolsCapability {
	bool listChanged = false; /// Whether the server supports tool list change notifications.

	/**
	 * Serializes this capability to a JSON object.
	 *
	 * Returns: A `JSONValue` with the listChanged field.
	 */
	JSONValue toJSON() const
	{
		JSONValue json;
		json["listChanged"] = JSONValue(listChanged);
		return json;
	}
}

/** Aggregates all server capabilities advertised during initialization. */
struct ServerCapabilities {
	ToolsCapability tools; /// Tool-related capabilities.

	/**
	 * Serializes all capabilities to a JSON object.
	 *
	 * Returns: A `JSONValue` containing the tools capability.
	 */
	JSONValue toJSON() const
	{
		JSONValue json;
		json["tools"] = tools.toJSON();
		return json;
	}
}

/** A single content block within a tool result, typically containing text output. */
struct Content {
	string type; /// The content type (e.g. "text").
	string text; /// The content payload.

	/**
	 * Serializes this content block to a JSON object.
	 *
	 * Returns: A `JSONValue` with type and text fields.
	 */
	JSONValue toJSON() const
	{
		JSONValue json;
		json["type"] = JSONValue(type);
		json["text"] = JSONValue(text);
		return json;
	}
}

/** The result returned by a tool execution, containing one or more content blocks. */
struct ToolResult {
	Content[] content; /// The output content blocks produced by the tool.
	bool isError = false; /// Whether the result represents an error condition.

	/**
	 * Serializes this tool result to a JSON object.
	 *
	 * Returns: A `JSONValue` with content array and isError flag.
	 */
	JSONValue toJSON() const
	{
		JSONValue json;
		JSONValue[] contentArray;
		foreach(c; content) {
			contentArray ~= c.toJSON();
		}
		json["content"] = JSONValue(contentArray);
		json["isError"] = JSONValue(isError);
		return json;
	}
}

/** Describes a tool's metadata for the `tools/list` response. */
struct ToolDefinition {
	string name; /// The unique tool identifier.
	string description; /// Human-readable description of what the tool does.
	JSONValue inputSchema; /// JSON Schema describing the tool's expected input parameters.

	/**
	 * Serializes this tool definition to a JSON object.
	 *
	 * Returns: A `JSONValue` with name, description, and inputSchema fields.
	 */
	JSONValue toJSON() const
	{
		JSONValue json;
		json["name"] = JSONValue(name);
		json["description"] = JSONValue(description);
		json["inputSchema"] = inputSchema;
		return json;
	}
}
