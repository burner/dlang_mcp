/**
 * Standard I/O transport for MCP communication over stdin/stdout.
 *
 * Implements the `Transport` interface using line-based JSON-RPC messaging,
 * reading one JSON message per line from stdin and writing responses to stdout.
 */
module mcp.transport;

import std.stdio : stdin, stdout, EOF;
import std.string : stripRight;
import mcp.transport_interface : Transport;

/**
 * Signals that the input stream has reached end-of-file.
 *
 * Thrown by transports when the client disconnects or stdin is closed.
 */
class EOFException : Exception {
	this() pure nothrow @safe
	{
		super("End of input stream");
	}
}

/**
 * Transport that communicates via standard input and output streams.
 *
 * Each JSON-RPC message is a single line on stdin. Responses are written
 * as single lines to stdout, followed by a flush to ensure delivery.
 */
class StdioTransport : Transport {
	/**
	 * Reads one line from stdin and returns it as a JSON-RPC message.
	 *
	 * Returns: The trimmed input line.
	 *
	 * Throws: `EOFException` if stdin has been closed.
	 */
	string readMessage()
	{
		auto line = stdin.readln();
		if(line is null) {
			throw new EOFException();
		}
		return line.stripRight();
	}

	/**
	 * Writes a JSON-RPC message to stdout, followed by a newline and flush.
	 *
	 * Params:
	 *     jsonMessage = The serialized JSON string to send.
	 */
	void writeMessage(string jsonMessage)
	{
		stdout.writeln(jsonMessage);
		stdout.flush();
	}

	/** Closes the stdio transport. No-op since stdin/stdout are process-global. */
	void close()
	{
	}
}
