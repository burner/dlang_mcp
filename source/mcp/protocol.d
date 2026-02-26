/**
 * JSON-RPC 2.0 protocol helpers for parsing requests and creating responses.
 *
 * Provides functions for deserializing JSON-RPC requests, serializing responses,
 * and constructing standardized error responses for common failure modes.
 */
module mcp.protocol;

import std.json : JSONValue, parseJSON, JSONType;
import mcp.types : JsonRpcRequest, JsonRpcResponse, JsonRpcError, JsonRpcErrorCode;
import utils.logging : logError;

/** Exception thrown when a protocol-level error is encountered during parsing. */
class ProtocolException : Exception {
	this(string msg) pure nothrow @safe
	{
		super(msg);
	}
}

/**
 * Parses a raw JSON string into a `JsonRpcRequest`.
 *
 * Validates the JSON structure, checks for the required "jsonrpc" version
 * and "method" fields, and deserializes into the request struct.
 *
 * Params:
 *     jsonLine = A single line of JSON text representing a JSON-RPC 2.0 request.
 *
 * Returns: A populated `JsonRpcRequest` struct.
 *
 * Throws: `ProtocolException` if the JSON is invalid or missing required fields.
 */
JsonRpcRequest parseRequest(string jsonLine)
{
	JSONValue json;
	try {
		json = parseJSON(jsonLine);
	} catch(Exception e) {
		throw new ProtocolException("Invalid JSON: " ~ e.msg);
	}

	if(json.type != JSONType.object) {
		throw new ProtocolException("Request must be a JSON object");
	}

	if(!("jsonrpc" in json) || json["jsonrpc"].str != "2.0") {
		throw new ProtocolException("Invalid or missing jsonrpc version");
	}

	if(!("method" in json)) {
		throw new ProtocolException("Missing method field");
	}

	return JsonRpcRequest.fromJSON(json);
}

/**
 * Serializes a `JsonRpcResponse` to its JSON string representation.
 *
 * Params:
 *     response = The response struct to serialize.
 *
 * Returns: A JSON string suitable for sending over a transport.
 */
string serializeResponse(JsonRpcResponse response)
{
	return response.toJSON().toString();
}

/**
 * Creates a JSON-RPC error response with the given error code and message.
 *
 * Params:
 *     id = The request identifier to include in the response (string, integer, or null).
 *     code = The numeric JSON-RPC error code.
 *     message = A human-readable error description.
 *     data = Optional additional error data.
 *
 * Returns: A `JsonRpcResponse` with the error field populated.
 */
JsonRpcResponse createErrorResponse(JSONValue id, int code, string message,
		JSONValue data = JSONValue.init)
{
	JsonRpcResponse response;
	response.jsonrpc = "2.0";
	response.id = id;

	JsonRpcError error;
	error.code = code;
	error.message = message;
	error.data = data;
	response.error = error.toJSON();

	return response;
}

/**
 * Creates a parse error response (code -32700).
 *
 * Uses null id since the request could not be parsed to extract one.
 *
 * Returns: A `JsonRpcResponse` indicating a JSON parse error.
 */
JsonRpcResponse createParseErrorResponse()
{
	return createErrorResponse(JSONValue(null), JsonRpcErrorCode.ParseError, "Parse error");
}

/**
 * Creates an invalid request error response (code -32600).
 *
 * Params:
 *     id = The request identifier.
 *     message = Description of what made the request invalid.
 *
 * Returns: A `JsonRpcResponse` indicating an invalid request.
 */
JsonRpcResponse createInvalidRequestResponse(JSONValue id, string message)
{
	return createErrorResponse(id, JsonRpcErrorCode.InvalidRequest, message);
}

/**
 * Creates a method not found error response (code -32601).
 *
 * Params:
 *     id = The request identifier.
 *     method = The method name that was not found.
 *
 * Returns: A `JsonRpcResponse` indicating the method does not exist.
 */
JsonRpcResponse createMethodNotFoundResponse(JSONValue id, string method)
{
	return createErrorResponse(id, JsonRpcErrorCode.MethodNotFound, "Method not found: " ~ method);
}

/**
 * Creates an invalid params error response (code -32602).
 *
 * Params:
 *     id = The request identifier.
 *     message = Description of the parameter validation failure.
 *
 * Returns: A `JsonRpcResponse` indicating invalid parameters.
 */
JsonRpcResponse createInvalidParamsResponse(JSONValue id, string message)
{
	return createErrorResponse(id, JsonRpcErrorCode.InvalidParams, message);
}

/**
 * Creates an internal error response (code -32603).
 *
 * Params:
 *     id = The request identifier.
 *     message = Description of the internal error.
 *
 * Returns: A `JsonRpcResponse` indicating a server-side error.
 */
JsonRpcResponse createInternalErrorResponse(JSONValue id, string message)
{
	return createErrorResponse(id, JsonRpcErrorCode.InternalError, message);
}

/**
 * Creates a JSON null value for use as an empty result.
 *
 * Returns: A `JSONValue` containing JSON null.
 */
JSONValue nullJSON()
{
	return JSONValue(null);
}

// -- Unit Tests --

/// Parse a valid JSON-RPC request
unittest {
	auto req = parseRequest(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`);
	assert(req.method == "initialize", "Expected method 'initialize', got: " ~ req.method);
	assert(req.id.integer == 1, "Expected id 1");
	assert(!req.isNotification, "Should not be a notification");
}

/// Parse a request with a string id
unittest {
	auto req = parseRequest(`{"jsonrpc":"2.0","id":"abc","method":"ping"}`);
	assert(req.id.str == "abc", "Expected id 'abc'");
	assert(!req.isNotification, "Should not be a notification");
}

/// Parse a notification (no id field)
unittest {
	auto req = parseRequest(`{"jsonrpc":"2.0","method":"notifications/initialized"}`);
	assert(req.isNotification, "Should be a notification");
	assert(req.method == "notifications/initialized", "Expected method 'notifications/initialized'");
}

/// Parse a request with no params
unittest {
	auto req = parseRequest(`{"jsonrpc":"2.0","id":1,"method":"ping"}`);
	// params should be null/init when not present
	assert(req.params.type == JSONType.null_, "Expected null params when not provided");
}

/// Parse a request with explicit null id
unittest {
	auto req = parseRequest(`{"jsonrpc":"2.0","id":null,"method":"ping"}`);
	// Explicit null id is a valid request per JSON-RPC 2.0 (not a notification)
	assert(!req.isNotification, "Explicit null id should not be treated as notification");
}

/// Parse an empty string throws ProtocolException
unittest {
	bool threw = false;
	try {
		parseRequest("");
	} catch(ProtocolException e) {
		threw = true;
	}
	assert(threw, "Expected ProtocolException for empty string");
}

/// Parse invalid JSON throws ProtocolException
unittest {
	bool threw = false;
	try {
		parseRequest("not json at all");
	} catch(ProtocolException e) {
		threw = true;
	}
	assert(threw, "Expected ProtocolException for invalid JSON");
}

/// Parse a JSON array throws ProtocolException
unittest {
	import std.algorithm.searching : canFind;

	bool threw = false;
	try {
		parseRequest("[1,2,3]");
	} catch(ProtocolException e) {
		threw = true;
		assert(e.msg.canFind("JSON object"), "Error should mention 'JSON object', got: " ~ e.msg);
	}
	assert(threw, "Expected ProtocolException for JSON array");
}

/// Parse a JSON primitive throws ProtocolException
unittest {
	bool threw = false;
	try {
		parseRequest("42");
	} catch(ProtocolException e) {
		threw = true;
	}
	assert(threw, "Expected ProtocolException for JSON primitive");
}

/// Parse request missing jsonrpc field throws ProtocolException
unittest {
	bool threw = false;
	try {
		parseRequest(`{"id":1,"method":"ping"}`);
	} catch(ProtocolException e) {
		threw = true;
	}
	assert(threw, "Expected ProtocolException for missing jsonrpc");
}

/// Parse request with wrong jsonrpc version throws ProtocolException
unittest {
	bool threw = false;
	try {
		parseRequest(`{"jsonrpc":"1.0","id":1,"method":"ping"}`);
	} catch(ProtocolException e) {
		threw = true;
	}
	assert(threw, "Expected ProtocolException for wrong jsonrpc version");
}

/// Parse request missing method field throws ProtocolException
unittest {
	bool threw = false;
	try {
		parseRequest(`{"jsonrpc":"2.0","id":1}`);
	} catch(ProtocolException e) {
		threw = true;
	}
	assert(threw, "Expected ProtocolException for missing method");
}

/// Parse request with non-string jsonrpc throws exception
unittest {
	bool threw = false;
	try {
		parseRequest(`{"jsonrpc":2,"id":1,"method":"ping"}`);
	} catch(Exception e) {
		threw = true;
	}
	assert(threw, "Expected exception for non-string jsonrpc");
}

/// Parse request with non-string method throws exception
unittest {
	bool threw = false;
	try {
		parseRequest(`{"jsonrpc":"2.0","id":1,"method":123}`);
	} catch(Exception e) {
		threw = true;
	}
	assert(threw, "Expected exception for non-string method");
}

/// Serialize a success response contains result but not error
unittest {
	import std.algorithm.searching : canFind;

	JsonRpcResponse resp;
	resp.jsonrpc = "2.0";
	resp.id = JSONValue(1);
	resp.result = parseJSON(`{"key":"value"}`);

	string json = serializeResponse(resp);
	assert(json.canFind(`"result"`), "Success response should contain 'result'");
	assert(!json.canFind(`"error"`), "Success response should NOT contain 'error'");
}

/// Serialize an error response contains error but not result
unittest {
	import std.algorithm.searching : canFind;

	auto resp = createErrorResponse(JSONValue(1), -32600, "Invalid Request");

	string json = serializeResponse(resp);
	assert(json.canFind(`"error"`), "Error response should contain 'error'");
	assert(!json.canFind(`"result"`), "Error response should NOT contain 'result'");
}

/// Serialization preserves integer id
unittest {
	JsonRpcResponse resp;
	resp.jsonrpc = "2.0";
	resp.id = JSONValue(42);
	resp.result = JSONValue("ok");

	auto json = parseJSON(serializeResponse(resp));
	assert(json["id"].integer == 42, "Serialized id should be 42");
}

/// Serialization preserves string id
unittest {
	JsonRpcResponse resp;
	resp.jsonrpc = "2.0";
	resp.id = JSONValue("abc");
	resp.result = JSONValue("ok");

	auto json = parseJSON(serializeResponse(resp));
	assert(json["id"].str == "abc", "Serialized id should be 'abc'");
}

/// Serialization preserves null id
unittest {
	JsonRpcResponse resp;
	resp.jsonrpc = "2.0";
	resp.id = JSONValue(null);
	resp.result = JSONValue("ok");

	auto json = parseJSON(serializeResponse(resp));
	assert(json["id"].type == JSONType.null_, "Serialized id should be null");
}

/// Create parse error response has null id and code -32700
unittest {
	auto resp = createParseErrorResponse();
	assert(resp.id.type == JSONType.null_, "Parse error id should be null");
	assert(resp.error["code"].integer == -32700, "Parse error code should be -32700");
}

/// Create invalid request response has code -32600
unittest {
	auto resp = createInvalidRequestResponse(JSONValue(1), "bad request");
	assert(resp.error["code"].integer == -32600, "Invalid request code should be -32600");
	assert(resp.id.integer == 1, "Id should be preserved");
}

/// Create method not found response has code -32601 and includes method name
unittest {
	import std.algorithm.searching : canFind;

	auto resp = createMethodNotFoundResponse(JSONValue(1), "foo");
	assert(resp.error["code"].integer == -32601, "Method not found code should be -32601");
	assert(resp.error["message"].str.canFind("foo"),
			"Error message should contain method name 'foo'");
}

/// Create invalid params response has code -32602
unittest {
	auto resp = createInvalidParamsResponse(JSONValue(1), "missing field");
	assert(resp.error["code"].integer == -32602, "Invalid params code should be -32602");
}

/// Create internal error response has code -32603
unittest {
	auto resp = createInternalErrorResponse(JSONValue(1), "boom");
	assert(resp.error["code"].integer == -32603, "Internal error code should be -32603");
}
