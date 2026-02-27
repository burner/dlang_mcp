/**
 * HTTP server for MCP communication over HTTP and Server-Sent Events.
 *
 * Provides an alternative to the stdio transport, exposing the MCP server
 * over HTTP with support for SSE-based streaming sessions and direct
 * JSON-RPC POST endpoints. Built on the vibe.d HTTP server.
 */
module mcp.http_server;

import vibe.http.server;
import vibe.http.router;
import vibe.http.common;
import vibe.core.core : runApplication, sleep;
import vibe.core.stream;
import vibe.stream.operations : readAll;
import mcp.server : MCPServer;
import mcp.http_transport : SSETransport, StreamableHTTPTransport, HTTPRequest;
import mcp.protocol : parseRequest, serializeResponse,
	createParseErrorResponse, ProtocolException;
import mcp.types : JsonRpcRequest;
import std.logger : info, error;
import std.json : JSONValue;
import std.conv : to;
import std.datetime : dur;

// ---------------------------------------------------------------------------
// HTTP Server
// ---------------------------------------------------------------------------

/**
 * HTTP server that wraps an `MCPServer` and exposes it over HTTP endpoints.
 *
 * Supports three communication modes:
 * $(UL
 *     $(LI `GET /sse` — Server-Sent Events for long-lived streaming sessions)
 *     $(LI `POST /messages` — JSON-RPC messages routed to an existing SSE session)
 *     $(LI `POST /mcp` — Stateless JSON-RPC endpoint for direct request/response)
 * )
 */
class MCPHTTPServer {
	private MCPServer _mcpServer;
	private StreamableHTTPTransport _transport;
	private ushort _port;
	private string _host;

	/**
	 * Constructs an HTTP server wrapping the given MCP server.
	 *
	 * Params:
	 *     mcpServer  = The MCP server to delegate requests to.
	 *     host       = The network interface to bind to.
	 *     port       = The TCP port to listen on.
	 */
	this(MCPServer mcpServer, string host = "127.0.0.1", ushort port = 3000)
	{
		_mcpServer = mcpServer;
		_transport = new StreamableHTTPTransport(mcpServer);
		_host = host;
		_port = port;
	}

	/**
	 * Starts the HTTP server and enters the vibe.d event loop.
	 *
	 * Registers routes for `/sse`, `/messages`, `/mcp`, and `/health`,
	 * then begins accepting connections. This method does not return until
	 * the application is terminated.
	 */
	void start()
	{
		auto settings = new HTTPServerSettings;
		settings.port = _port;
		settings.bindAddresses = [_host];

		auto router = new URLRouter;
		router.get("/sse", &handleSSE);
		router.post("/messages", &handleMessages);
		router.post("/mcp", &handleMCP);
		router.get("/health", &handleHealth);

		listenHTTP(settings, router);
		info("MCP HTTP server listening on " ~ _host ~ ":" ~ _port.to!string);

		runApplication();
	}

	// -----------------------------------------------------------------------
	// Route handlers
	// -----------------------------------------------------------------------

	/**
	 * Handles `GET /health` requests, returning a simple JSON status object.
	 *
	 * Params:
	 *     req = The incoming HTTP request.
	 *     res = The HTTP response to write to.
	 */
	void handleHealth(HTTPServerRequest req, HTTPServerResponse res)
	{
		res.headers["Content-Type"] = "application/json";
		JSONValue health;
		health["status"] = JSONValue("ok");
		health["version"] = JSONValue("1.0.0");
		res.writeBody(health.toString());
	}

	/**
	 * Handles `GET /sse` requests, establishing a Server-Sent Events session.
	 *
	 * Creates a new SSE session, sends the endpoint URL to the client, and then
	 * enters a loop that forwards tool responses as SSE events. Sends keepalive
	 * comments every 30 seconds to maintain the connection.
	 *
	 * Params:
	 *     req = The incoming HTTP request.
	 *     res = The HTTP response used for streaming SSE events.
	 */
	void handleSSE(HTTPServerRequest req, HTTPServerResponse res)
	{
		info("SSE connection established");

		auto session = _transport.createSession();
		string sessionId = session.sessionId;

		res.headers["Content-Type"] = "text/event-stream";
		res.headers["Cache-Control"] = "no-cache";
		res.headers["Connection"] = "keep-alive";
		res.headers["mcp-session-id"] = sessionId;

		auto writer = res.bodyWriter();
		writer.write("event: endpoint\ndata: /messages?sessionId=" ~ sessionId ~ "\n\n");

		while(session.connected()) {
			string output;
			if(session.waitForOutput(output, dur!"seconds"(30))) {
				try {
					writer.write(output);
				} catch(Exception e) {
					info("SSE connection closed: " ~ e.msg);
					break;
				}
			} else {
				try {
					writer.write(": keepalive\n\n");
				} catch(Exception e) {
					info("SSE keepalive failed, connection closed");
					break;
				}
			}
		}

		_transport.removeSession(sessionId);
		info("SSE session ended: " ~ sessionId);
	}

	/**
	 * Handles `POST /messages` requests, routing JSON-RPC messages to an SSE session.
	 *
	 * Requires a `sessionId` query parameter or `mcp-session-id` header to identify
	 * which SSE session should process the message. Returns the JSON-RPC response.
	 *
	 * Params:
	 *     req = The incoming HTTP request containing the JSON-RPC message body.
	 *     res = The HTTP response to write the result to.
	 */
	void handleMessages(HTTPServerRequest req, HTTPServerResponse res)
	{
		string sessionId;

		if("sessionId" in req.query) {
			sessionId = req.query["sessionId"];
		} else if("mcp-session-id" in req.headers) {
			sessionId = req.headers["mcp-session-id"];
		} else {
			res.statusCode = HTTPStatus.badRequest;
			res.headers["Content-Type"] = "application/json";
			JSONValue error;
			error["error"] = JSONValue("Missing sessionId");
			res.writeBody(error.toString());
			return;
		}

		auto body_ = cast(string)readAll(req.bodyReader);

		try {
			auto request = parseRequest(body_);
			// Notifications must not receive a response per JSON-RPC 2.0
			if(request.isNotification) {
				_mcpServer.handleNotification(request);
				res.statusCode = HTTPStatus.noContent;
				return;
			}
			auto response = _mcpServer.handleRequest(request);
			res.headers["Content-Type"] = "application/json";
			res.writeBody(serializeResponse(response));
		} catch(ProtocolException e) {
			error("Parse error handling message: " ~ e.msg);
			res.headers["Content-Type"] = "application/json";
			res.writeBody(serializeResponse(createParseErrorResponse()));
		} catch(Exception e) {
			error("Error handling message: " ~ e.msg);
			res.statusCode = HTTPStatus.internalServerError;
			res.headers["Content-Type"] = "application/json";
			res.writeBody(serializeResponse(createParseErrorResponse()));
		}
	}

	/**
	 * Handles `POST /mcp` requests, providing a stateless JSON-RPC endpoint.
	 *
	 * Processes the request body as a JSON-RPC message without requiring a session.
	 * Suitable for simple request/response interactions without SSE streaming.
	 *
	 * Params:
	 *     req = The incoming HTTP request containing the JSON-RPC message body.
	 *     res = The HTTP response to write the result to.
	 */
	void handleMCP(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto body_ = cast(string)readAll(req.bodyReader);

		try {
			auto request = parseRequest(body_);
			// Notifications must not receive a response per JSON-RPC 2.0
			if(request.isNotification) {
				_mcpServer.handleNotification(request);
				res.statusCode = HTTPStatus.noContent;
				return;
			}
			auto response = _mcpServer.handleRequest(request);
			res.headers["Content-Type"] = "application/json";
			res.writeBody(serializeResponse(response));
		} catch(ProtocolException e) {
			error("Parse error handling MCP request: " ~ e.msg);
			res.headers["Content-Type"] = "application/json";
			res.writeBody(serializeResponse(createParseErrorResponse()));
		} catch(Exception e) {
			error("Error handling MCP request: " ~ e.msg);
			res.statusCode = HTTPStatus.internalServerError;
			res.headers["Content-Type"] = "application/json";
			res.writeBody(serializeResponse(createParseErrorResponse()));
		}
	}
}
