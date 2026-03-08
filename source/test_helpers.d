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
	this()
	{
		super(parseJSON(
				`{"type":"object","properties":{"input":{"type":"string"}},"required":["input"]}`));
	}

	@property string name()
	{
		return "test_tool";
	}

	@property string description()
	{
		return "A mock tool for testing";
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
	this()
	{
		super(parseJSON(`{"type":"object","properties":{}}`));
	}

	@property string name()
	{
		return "failing_tool";
	}

	@property string description()
	{
		return "A tool that always fails";
	}

	ToolResult execute(JSONValue arguments)
	{
		throw new Exception("Intentional test failure");
	}
}

/// A tool that always throws, used for MCP spec compliance testing.
class ThrowingTool : BaseTool {
	this()
	{
		super(parseJSON(`{"type":"object","properties":{}}`));
	}

	@property string name()
	{
		return "throwing_tool";
	}

	@property string description()
	{
		return "A tool that throws for testing";
	}

	ToolResult execute(JSONValue arguments)
	{
		throw new Exception("test throw");
	}
}
