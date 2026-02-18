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
