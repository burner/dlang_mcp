/**
 * Abstract transport interface for MCP client-server communication.
 *
 * Defines the contract that all transport implementations (stdio, HTTP/SSE)
 * must fulfill to exchange JSON-RPC messages with the MCP server.
 */
module mcp.transport_interface;

/**
 * Transport abstraction for reading and writing JSON-RPC messages.
 *
 * Implementations handle the underlying I/O mechanism (e.g. stdin/stdout,
 * HTTP request/response, or Server-Sent Events).
 */
interface Transport {
	/**
	 * Reads the next JSON-RPC message from the client.
	 *
	 * Blocks until a complete message is available.
	 *
	 * Returns: The raw JSON string of the incoming message.
	 *
	 * Throws: `EOFException` if the client has disconnected.
	 */
	string readMessage();

	/**
	 * Writes a JSON-RPC response message back to the client.
	 *
	 * Params:
	 *     jsonMessage = The serialized JSON string to send.
	 */
	void writeMessage(string jsonMessage);

	/** Closes the transport, releasing any underlying resources. */
	void close();
}
