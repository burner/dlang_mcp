/**
 * Base interfaces and abstract classes for the MCP tool framework.
 *
 * Defines the `Tool` interface that all MCP tools must implement, and the
 * `BaseTool` abstract class that provides convenience methods for creating
 * tool results. Every tool registered with the MCP server implements `Tool`.
 */
module tools.base;

import std.json : JSONValue;
import mcp.types : ToolResult, ToolDefinition, Content;

/**
 * Interface that all MCP tools must implement.
 *
 * Each tool exposes a name, description, and JSON Schema for its input,
 * and can be executed with a set of JSON arguments.
 */
interface Tool {
	/** Returns the unique identifier for this tool (e.g. "compile_check"). */
	@property string name();

	/** Returns a human-readable description of what this tool does. */
	@property string description();

	/** Returns the JSON Schema describing the tool's expected input parameters. */
	@property JSONValue inputSchema();

	/**
	 * Executes the tool with the given arguments.
	 *
	 * Params:
	 *     arguments = A JSON object containing the tool's input parameters.
	 *
	 * Returns: A `ToolResult` containing the output content and error status.
	 */
	ToolResult execute(JSONValue arguments);
}

/**
 * Abstract base class for tools, providing helper methods for result construction.
 *
 * Subclasses should implement the `Tool` interface properties (`name`, `description`,
 * `inputSchema`) and the `execute` method, using `createTextResult` and
 * `createErrorResult` to build return values.
 */
abstract class BaseTool : Tool {
	/**
	 * Creates a successful tool result containing a single text content block.
	 *
	 * Params:
	 *     text = The text output to include in the result.
	 *
	 * Returns: A `ToolResult` with `isError` set to `false`.
	 */
	protected ToolResult createTextResult(string text)
	{
		return ToolResult([Content("text", text)], false);
	}

	/**
	 * Creates an error tool result containing an error message.
	 *
	 * Params:
	 *     errorMessage = The error description to include in the result.
	 *
	 * Returns: A `ToolResult` with `isError` set to `true`.
	 */
	protected ToolResult createErrorResult(string errorMessage)
	{
		return ToolResult([Content("text", errorMessage)], true);
	}
}
