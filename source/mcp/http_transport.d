/**
 * HTTP and SSE transport implementations for MCP communication.
 *
 * Provides transport layers for HTTP-based MCP communication, including
 * Server-Sent Events (SSE) for streaming and a streamable HTTP transport
 * that manages multiple concurrent SSE sessions.
 */
module mcp.http_transport;

import mcp.transport_interface : Transport;
import mcp.transport : EOFException;
import mcp.server : MCPServer;
import mcp.protocol : parseRequest, serializeResponse,
	createParseErrorResponse, ProtocolException;
import mcp.types : JsonRpcResponse;
import std.json : JSONValue, parseJSON, JSONType;
import std.conv : to;
import std.uuid : randomUUID;
import std.datetime : SysTime, Duration;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.thread;
import std.logger : error;

/** Metadata for an active Server-Sent Events session. */
struct SSESession {
	string sessionId; /// Unique identifier for this session.
	void delegate(string) sender; /// Delegate used to push messages to the SSE client.
	SysTime lastActivity; /// Timestamp of the last activity on this session.
}

/**
 * Transport that communicates with a single client via Server-Sent Events.
 *
 * Supports bidirectional communication where incoming messages are received
 * via `receiveMessage` (called from an HTTP POST handler) and outgoing
 * messages are pushed as SSE events. Uses mutex-based synchronization for
 * thread-safe message passing between the HTTP handler and the SSE stream.
 */
final class SSETransport : Transport {
	private string _sessionId;
	private string[] _messageQueue;
	private bool _connected = true;
	private Mutex _mutex;
	private Condition _messageReady;
	private Condition _messageSent;
	private string _outputBuffer;
	private bool _hasOutput = false;

	/** Constructs a new SSE transport with a unique session ID. */
	this()
	{
		_sessionId = randomUUID().toString();
		_mutex = new Mutex();
		_messageReady = new Condition(_mutex);
		_messageSent = new Condition(_mutex);
	}

	/** Returns the unique session identifier for this transport. */
	@property string sessionId() const @safe pure nothrow
	{
		return _sessionId;
	}

	/**
	 * Sets the delegate used to push SSE events to the client.
	 *
	 * Params:
	 *     sender = A delegate that accepts an SSE-formatted string.
	 */
	void setSender(void delegate(string) sender)
	{
		_sender = sender;
	}

	/**
	 * Enqueues an incoming message from an HTTP POST handler for processing.
	 *
	 * Notifies the SSE stream thread that a message is available.
	 *
	 * Params:
	 *     message = The raw JSON-RPC message string.
	 */
	void receiveMessage(string message)
	{
		synchronized(_mutex) {
			_messageQueue ~= message;
			_messageReady.notify();
		}
	}

	/**
	 * Sends a named SSE event with the given data payload.
	 *
	 * Params:
	 *     event = The SSE event name.
	 *     data = The event data payload.
	 */
	void sendEvent(string event, string data)
	{
		synchronized(_mutex) {
			_outputBuffer = "event: " ~ event ~ "\ndata: " ~ data ~ "\n\n";
			_hasOutput = true;
			_messageSent.notify();
		}
	}

	/**
	 * Sends a "message" SSE event with the given data payload.
	 *
	 * Params:
	 *     data = The message data to send.
	 */
	void sendMessage(string data)
	{
		sendEvent("message", data);
	}

	/**
	 * Reads the next pending message, blocking until one is available.
	 *
	 * Returns: The raw JSON-RPC message string.
	 *
	 * Throws: `EOFException` if the transport has been closed.
	 */
	string readMessage()
	{
		synchronized(_mutex) {
			while(_messageQueue.length == 0 && _connected) {
				_messageReady.wait();
			}
			if(!_connected)
				throw new EOFException();

			auto msg = _messageQueue[0];
			_messageQueue = _messageQueue[1 .. $];
			return msg;
		}
	}

	/**
	 * Writes a JSON-RPC response by sending it as an SSE message event.
	 *
	 * Params:
	 *     jsonMessage = The serialized JSON-RPC response.
	 */
	void writeMessage(string jsonMessage)
	{
		sendMessage(jsonMessage);
	}

	/** Closes this transport, waking any blocked readers or writers. */
	void close()
	{
		synchronized(_mutex) {
			_connected = false;
			_messageReady.notify();
			_messageSent.notify();
		}
	}

	/**
	 * Waits for output to become available within the given timeout.
	 *
	 * Used by the SSE stream handler to check for pending responses
	 * before sending them to the client.
	 *
	 * Params:
	 *     output = Receives the SSE-formatted output string if available.
	 *     timeout = Maximum time to wait for output.
	 *
	 * Returns: `true` if output was available, `false` on timeout or disconnect.
	 */
	bool waitForOutput(ref string output, Duration timeout)
	{
		synchronized(_mutex) {
			while(!_hasOutput && _connected) {
				if(!_messageSent.wait(timeout))
					return false;
			}
			if(!_connected)
				return false;

			output = _outputBuffer;
			_outputBuffer = null;
			_hasOutput = false;
			return true;
		}
	}

	/** Returns whether this transport is still connected. */
	bool connected() const @safe pure nothrow
	{
		return _connected;
	}

	private void delegate(string) _sender;
}

/** An HTTP request received by the streamable HTTP transport. */
struct HTTPRequest {
	string body; /// The request body containing a JSON-RPC message.
	string sessionId; /// Optional session identifier for SSE-based routing.
}

/** An HTTP response produced by the streamable HTTP transport. */
struct HTTPResponse {
	string body; /// The response body.
	string contentType; /// The MIME content type (e.g. "application/json").
	string[string] headers; /// Additional response headers.
	bool isSSE; /// Whether this response should be delivered as an SSE stream.
}

/**
 * HTTP transport that manages multiple concurrent SSE sessions.
 *
 * Acts as a facade over the `MCPServer`, routing incoming HTTP requests
 * either to an existing SSE session (by session ID) or processing them
 * directly as stateless JSON-RPC calls. Does not support the `readMessage`
 * or `writeMessage` methods directly—use `handleRequest` instead.
 */
final class StreamableHTTPTransport : Transport {
	private MCPServer _server;
	private bool _useSSE = false;
	private SSETransport[string] _sessions;
	private Mutex _mutex;

	/**
	 * Constructs a streamable HTTP transport wrapping the given MCP server.
	 *
	 * Params:
	 *     server = The MCP server to delegate request handling to.
	 */
	this(MCPServer server)
	{
		_server = server;
		_mutex = new Mutex();
	}

	/**
	 * Handles an incoming HTTP request, routing it to the appropriate session
	 * or processing it as a direct JSON-RPC call.
	 *
	 * Params:
	 *     req = The HTTP request containing body and optional session ID.
	 *
	 * Returns: An `HTTPResponse` with the result, content type, and SSE flag.
	 */
	HTTPResponse handleRequest(ref HTTPRequest req)
	{
		HTTPResponse response;
		response.contentType = "application/json";

		if(req.sessionId.length > 0) {
			synchronized(_mutex) {
				if(auto session = req.sessionId in _sessions) {
					(*session).receiveMessage(req.body);

					string output;
					if((*session).waitForOutput(output, dur!"msecs"(5000))) {
						response.body = output;
						response.isSSE = true;
						response.contentType = "text/event-stream";
					}
					return response;
				}
			}
		}

		try {
			auto request = parseRequest(req.body);
			auto rpcResponse = _server.handleRequest(request);
			response.body = serializeResponse(rpcResponse);
		} catch(ProtocolException e) {
			error("HTTP parse error: " ~ e.msg);
			response.body = serializeResponse(createParseErrorResponse());
		} catch(Exception e) {
			error("HTTP request error: " ~ e.msg);
			response.body = serializeResponse(createParseErrorResponse());
		}

		return response;
	}

	/**
	 * Creates a new SSE session and registers it for future message routing.
	 *
	 * Returns: The newly created `SSETransport` instance.
	 */
	SSETransport createSession()
	{
		auto session = new SSETransport();
		synchronized(_mutex) {
			_sessions[session.sessionId] = session;
		}
		return session;
	}

	/**
	 * Removes and closes an SSE session by its identifier.
	 *
	 * Params:
	 *     sessionId = The session to remove.
	 */
	void removeSession(string sessionId)
	{
		synchronized(_mutex) {
			if(sessionId in _sessions) {
				_sessions[sessionId].close();
				_sessions.remove(sessionId);
			}
		}
	}

	/**
	 * Not supported. Always throws an exception.
	 *
	 * Throws: `Exception` indicating direct readMessage is not supported.
	 */
	string readMessage()
	{
		throw new Exception("StreamableHTTPTransport does not support direct readMessage");
	}

	/**
	 * Not supported. Always throws an exception.
	 *
	 * Throws: `Exception` indicating direct writeMessage is not supported.
	 */
	void writeMessage(string jsonMessage)
	{
		throw new Exception("StreamableHTTPTransport does not support direct writeMessage");
	}

	/** Closes all active SSE sessions and clears the session registry. */
	void close()
	{
		synchronized(_mutex) {
			foreach(session; _sessions.byValue) {
				session.close();
			}
			_sessions.clear();
		}
	}
}
