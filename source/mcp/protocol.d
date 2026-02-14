module mcp.protocol;

import std.json : JSONValue, parseJSON, JSONType;
import mcp.types : JsonRpcRequest, JsonRpcResponse, JsonRpcError, JsonRpcErrorCode;
import utils.logging : logError;

class ProtocolException : Exception
{
    this(string msg) pure nothrow @safe
    {
        super(msg);
    }
}

JsonRpcRequest parseRequest(string jsonLine)
{
    JSONValue json;
    try
    {
        json = parseJSON(jsonLine);
    }
    catch (Exception e)
    {
        throw new ProtocolException("Invalid JSON: " ~ e.msg);
    }

    if (json.type != JSONType.object)
    {
        throw new ProtocolException("Request must be a JSON object");
    }

    if (!("jsonrpc" in json) || json["jsonrpc"].str != "2.0")
    {
        throw new ProtocolException("Invalid or missing jsonrpc version");
    }

    if (!("method" in json))
    {
        throw new ProtocolException("Missing method field");
    }

    return JsonRpcRequest.fromJSON(json);
}

string serializeResponse(JsonRpcResponse response)
{
    return response.toJSON().toString();
}

JsonRpcResponse createErrorResponse(int id, int code, string message, JSONValue data = JSONValue.init)
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

JsonRpcResponse createParseErrorResponse(int id)
{
    return createErrorResponse(id, JsonRpcErrorCode.ParseError, "Parse error");
}

JsonRpcResponse createInvalidRequestResponse(int id, string message)
{
    return createErrorResponse(id, JsonRpcErrorCode.InvalidRequest, message);
}

JsonRpcResponse createMethodNotFoundResponse(int id, string method)
{
    return createErrorResponse(id, JsonRpcErrorCode.MethodNotFound, "Method not found: " ~ method);
}

JsonRpcResponse createInvalidParamsResponse(int id, string message)
{
    return createErrorResponse(id, JsonRpcErrorCode.InvalidParams, message);
}

JsonRpcResponse createInternalErrorResponse(int id, string message)
{
    return createErrorResponse(id, JsonRpcErrorCode.InternalError, message);
}

JSONValue nullJSON()
{
    JSONValue[string] empty;
    return JSONValue(empty);
}