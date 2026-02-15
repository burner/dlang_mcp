module mcp.http_server;

import vibe.http.server;
import vibe.http.router;
import vibe.http.common;
import vibe.core.core : runApplication, sleep;
import vibe.core.stream;
import vibe.stream.operations : readAll;
import mcp.server : MCPServer;
import mcp.http_transport : SSETransport, StreamableHTTPTransport, HTTPRequest;
import mcp.protocol : parseRequest, serializeResponse;
import utils.logging : logInfo, logError;
import std.json : JSONValue;
import std.conv : to;
import std.datetime : dur;

class MCPHTTPServer {
	private MCPServer _mcpServer;
	private StreamableHTTPTransport _transport;
	private ushort _port;
	private string _host;

	this(MCPServer mcpServer, string host = "127.0.0.1", ushort port = 3000)
	{
		_mcpServer = mcpServer;
		_transport = new StreamableHTTPTransport(mcpServer);
		_host = host;
		_port = port;
	}

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
		logInfo("MCP HTTP server listening on " ~ _host ~ ":" ~ _port.to!string);

		runApplication();
	}

	void handleHealth(HTTPServerRequest req, HTTPServerResponse res)
	{
		res.headers["Content-Type"] = "application/json";
		JSONValue health;
		health["status"] = JSONValue("ok");
		health["version"] = JSONValue("1.0.0");
		res.writeBody(health.toString());
	}

	void handleSSE(HTTPServerRequest req, HTTPServerResponse res)
	{
		logInfo("SSE connection established");

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
					logInfo("SSE connection closed: " ~ e.msg);
					break;
				}
			} else {
				try {
					writer.write(": keepalive\n\n");
				} catch(Exception e) {
					logInfo("SSE keepalive failed, connection closed");
					break;
				}
			}
		}

		_transport.removeSession(sessionId);
		logInfo("SSE session ended: " ~ sessionId);
	}

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

		auto body = cast(string)readAll(req.bodyReader);

		try {
			auto request = parseRequest(body);
			auto response = _mcpServer.handleRequest(request);
			res.headers["Content-Type"] = "application/json";
			res.writeBody(serializeResponse(response));
		} catch(Exception e) {
			logError("Error handling message: " ~ e.msg);
			res.statusCode = HTTPStatus.internalServerError;
			res.headers["Content-Type"] = "application/json";
			JSONValue error;
			error["error"] = JSONValue(e.msg);
			res.writeBody(error.toString());
		}
	}

	void handleMCP(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto body = cast(string)readAll(req.bodyReader);

		try {
			auto request = parseRequest(body);
			auto response = _mcpServer.handleRequest(request);
			res.headers["Content-Type"] = "application/json";
			res.writeBody(serializeResponse(response));
		} catch(Exception e) {
			logError("Error handling MCP request: " ~ e.msg);
			res.statusCode = HTTPStatus.internalServerError;
			res.headers["Content-Type"] = "application/json";
			JSONValue error;
			error["error"] = JSONValue(e.msg);
			res.writeBody(error.toString());
		}
	}
}
