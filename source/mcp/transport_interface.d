module mcp.transport_interface;

interface Transport {
	string readMessage();

	void writeMessage(string jsonMessage);

	void close();
}
