module mcp.http_transport;

import mcp.transport_interface : Transport;
import mcp.server : MCPServer;
import mcp.protocol : parseRequest, serializeResponse;
import mcp.types : JsonRpcResponse;
import std.json : JSONValue, parseJSON, JSONType;
import std.conv : to;
import std.uuid : randomUUID;
import std.datetime : SysTime, Duration;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.thread;
import utils.logging : logInfo, logError;

class EOFException : Exception {
	this() pure nothrow @safe
	{
		super("End of input stream");
	}
}

struct SSESession {
	string sessionId;
	void delegate(string) sender;
	SysTime lastActivity;
}

final class SSETransport : Transport {
	private string _sessionId;
	private string _pendingMessage;
	private bool _connected = true;
	private Mutex _mutex;
	private Condition _messageReady;
	private Condition _messageSent;
	private string _outputBuffer;
	private bool _hasOutput = false;

	this()
	{
		_sessionId = randomUUID().toString();
		_mutex = new Mutex();
		_messageReady = new Condition(_mutex);
		_messageSent = new Condition(_mutex);
	}

	@property string sessionId() const @safe pure nothrow
	{
		return _sessionId;
	}

	void setSender(void delegate(string) sender)
	{
		_sender = sender;
	}

	void receiveMessage(string message)
	{
		synchronized(_mutex) {
			_pendingMessage = message;
			_messageReady.notify();
		}
	}

	void sendEvent(string event, string data)
	{
		synchronized(_mutex) {
			_outputBuffer = "event: " ~ event ~ "\ndata: " ~ data ~ "\n\n";
			_hasOutput = true;
			_messageSent.notify();
		}
	}

	void sendMessage(string data)
	{
		sendEvent("message", data);
	}

	string readMessage()
	{
		synchronized(_mutex) {
			while(_pendingMessage is null && _connected) {
				_messageReady.wait();
			}
			if(!_connected)
				throw new EOFException();

			auto msg = _pendingMessage;
			_pendingMessage = null;
			return msg;
		}
	}

	void writeMessage(string jsonMessage)
	{
		sendMessage(jsonMessage);
	}

	void close()
	{
		synchronized(_mutex) {
			_connected = false;
			_messageReady.notify();
			_messageSent.notify();
		}
	}

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

	bool connected() const @safe pure nothrow
	{
		return _connected;
	}

	private void delegate(string) _sender;
}

struct HTTPRequest {
	string body;
	string sessionId;
}

struct HTTPResponse {
	string body;
	string contentType;
	string[string] headers;
	bool isSSE;
}

final class StreamableHTTPTransport : Transport {
	private MCPServer _server;
	private bool _useSSE = false;
	private SSETransport[string] _sessions;
	private Mutex _mutex;

	this(MCPServer server)
	{
		_server = server;
		_mutex = new Mutex();
	}

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
		} catch(Exception e) {
			logError("HTTP request error: " ~ e.msg);
			JSONValue errorJson;
			errorJson["jsonrpc"] = JSONValue("2.0");
			errorJson["error"] = JSONValue(e.msg);
			response.body = errorJson.toString();
		}

		return response;
	}

	SSETransport createSession()
	{
		auto session = new SSETransport();
		synchronized(_mutex) {
			_sessions[session.sessionId] = session;
		}
		return session;
	}

	void removeSession(string sessionId)
	{
		synchronized(_mutex) {
			if(sessionId in _sessions) {
				_sessions[sessionId].close();
				_sessions.remove(sessionId);
			}
		}
	}

	string readMessage()
	{
		throw new Exception("StreamableHTTPTransport does not support direct readMessage");
	}

	void writeMessage(string jsonMessage)
	{
		throw new Exception("StreamableHTTPTransport does not support direct writeMessage");
	}

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
