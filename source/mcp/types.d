module mcp.types;

import std.json : JSONValue, JSONType;

enum JsonRpcErrorCode {
	ParseError = -32700,
	InvalidRequest = -32600,
	MethodNotFound = -32601,
	InvalidParams = -32602,
	InternalError = -32603
}

struct JsonRpcRequest {
	string jsonrpc;
	int id;
	string method;
	JSONValue params;

	static JsonRpcRequest fromJSON(JSONValue json)
	{
		JsonRpcRequest req;
		req.jsonrpc = json["jsonrpc"].str;
		req.id = cast(int)json["id"].integer;
		req.method = json["method"].str;
		if("params" in json)
			req.params = json["params"];
		return req;
	}
}

struct JsonRpcError {
	int code;
	string message;
	JSONValue data;

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

struct JsonRpcResponse {
	string jsonrpc;
	int id;
	JSONValue result;
	JSONValue error;

	JSONValue toJSON() const
	{
		JSONValue json;
		json["jsonrpc"] = JSONValue(jsonrpc);

		JSONValue idVal;
		idVal.integer = id;
		json["id"] = idVal;

		if(error.type != JSONType.null_) {
			json["error"] = error;
		} else {
			json["result"] = result;
		}
		return json;
	}
}

struct ServerInfo {
	string name;
	string version_;

	JSONValue toJSON() const
	{
		JSONValue json;
		json["name"] = JSONValue(name);
		json["version"] = JSONValue(version_);
		return json;
	}
}

struct ToolsCapability {
	bool listChanged = false;

	JSONValue toJSON() const
	{
		JSONValue json;
		json["listChanged"] = JSONValue(listChanged);
		return json;
	}
}

struct ServerCapabilities {
	ToolsCapability tools;

	JSONValue toJSON() const
	{
		JSONValue json;
		json["tools"] = tools.toJSON();
		return json;
	}
}

struct Content {
	string type;
	string text;

	JSONValue toJSON() const
	{
		JSONValue json;
		json["type"] = JSONValue(type);
		json["text"] = JSONValue(text);
		return json;
	}
}

struct ToolResult {
	Content[] content;
	bool isError = false;

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

struct ToolDefinition {
	string name;
	string description;
	JSONValue inputSchema;

	JSONValue toJSON() const
	{
		JSONValue json;
		json["name"] = JSONValue(name);
		json["description"] = JSONValue(description);
		json["inputSchema"] = inputSchema;
		return json;
	}
}
