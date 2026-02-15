module mcp.transport;

import std.stdio : stdin, stdout, EOF;
import std.string : stripRight;
import mcp.transport_interface : Transport;

class EOFException : Exception {
	this() pure nothrow @safe
	{
		super("End of input stream");
	}
}

class StdioTransport : Transport {
	string readMessage()
	{
		auto line = stdin.readln();
		if(line is null) {
			throw new EOFException();
		}
		return line.stripRight();
	}

	void writeMessage(string jsonMessage)
	{
		stdout.writeln(jsonMessage);
		stdout.flush();
	}

	void close()
	{
	}
}
