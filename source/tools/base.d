module tools.base;

import std.json : JSONValue;
import mcp.types : ToolResult, ToolDefinition, Content;

interface Tool {
	@property string name();
	@property string description();
	@property JSONValue inputSchema();
	ToolResult execute(JSONValue arguments);
}

abstract class BaseTool : Tool {
	protected ToolResult createTextResult(string text)
	{
		return ToolResult([Content("text", text)], false);
	}

	protected ToolResult createErrorResult(string errorMessage)
	{
		return ToolResult([Content("text", errorMessage)], true);
	}
}
