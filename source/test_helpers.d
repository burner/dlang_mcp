/**
 * Test helper classes for unittest blocks.
 * Only compiled under version(unittest).
 */
module test_helpers;

version(unittest)  : import std.json;
import tools.base : BaseTool;
import mcp.types : ToolResult;

/// A mock tool that echoes back its input for testing.
class MockTool : BaseTool {
	@property string name()
	{
		return "test_tool";
	}

	@property string description()
	{
		return "A mock tool for testing";
	}

	@property JSONValue inputSchema()
	{
		return parseJSON(
				`{"type":"object","properties":{"input":{"type":"string"}},"required":["input"]}`);
	}

	ToolResult execute(JSONValue arguments)
	{
		if("input" in arguments && arguments["input"].type == JSONType.string)
			return createTextResult("echo: " ~ arguments["input"].str);
		return createTextResult("no input");
	}
}

/// A mock tool that always throws during execution.
class FailingTool : BaseTool {
	@property string name()
	{
		return "failing_tool";
	}

	@property string description()
	{
		return "A tool that always fails";
	}

	@property JSONValue inputSchema()
	{
		return parseJSON(`{"type":"object","properties":{}}`);
	}

	ToolResult execute(JSONValue arguments)
	{
		throw new Exception("Intentional test failure");
	}
}

/// A tool that always throws, used for MCP spec compliance testing.
class ThrowingTool : BaseTool {
	@property string name()
	{
		return "throwing_tool";
	}

	@property string description()
	{
		return "A tool that throws for testing";
	}

	@property JSONValue inputSchema()
	{
		return parseJSON(`{"type":"object","properties":{}}`);
	}

	ToolResult execute(JSONValue arguments)
	{
		throw new Exception("test throw");
	}
}
