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

version(unittest) {
	import tools.run_project : RunProjectTool;
	import tools.fetch_package : FetchPackageTool;
	import tools.upgrade_deps : UpgradeDependenciesTool;
	import tools.build_project : BuildProjectTool;
	import tools.run_tests : RunTestsTool;
	import tools.analyze_project : AnalyzeProjectTool;
}

/// RunProjectTool has correct name and description
unittest {
	auto tool = new RunProjectTool();
	assert(tool.name == "run_project", "Expected name 'run_project', got: " ~ tool.name);
	assert(tool.description.length > 0, "Description should not be empty");
}

/// RunProjectTool schema has all expected properties
unittest {
	auto tool = new RunProjectTool();
	auto schema = tool.inputSchema;
	assert(schema["type"].str == "object", "Schema type should be 'object'");
	auto props = schema["properties"];
	assert("project_path" in props, "Schema should have project_path");
	assert("compiler" in props, "Schema should have compiler");
	assert("build_type" in props, "Schema should have build_type");
	assert("configuration" in props, "Schema should have configuration");
	assert("args" in props, "Schema should have args");
	assert("force" in props, "Schema should have force");
}

/// RunProjectTool handles nonexistent path without crashing
unittest {
	import std.json : parseJSON;

	auto tool = new RunProjectTool();
	auto args = parseJSON(`{"project_path": "/nonexistent/path/that/does/not/exist"}`);
	auto result = tool.execute(args);
	assert(result.content.length > 0, "Should return content");
}

/// FetchPackageTool has correct name and description
unittest {
	auto tool = new FetchPackageTool();
	assert(tool.name == "fetch_package", "Expected name 'fetch_package', got: " ~ tool.name);
	assert(tool.description.length > 0, "Description should not be empty");
}

/// FetchPackageTool schema has expected properties and required fields
unittest {
	auto tool = new FetchPackageTool();
	auto schema = tool.inputSchema;
	assert(schema["type"].str == "object", "Schema type should be 'object'");
	auto props = schema["properties"];
	assert("package_name" in props, "Schema should have package_name");
	assert("version_" in props, "Schema should have version_");
	assert("required" in schema, "Schema should have required array");
	bool hasRequired = false;
	foreach(r; schema["required"].array) {
		if(r.str == "package_name")
			hasRequired = true;
	}
	assert(hasRequired, "package_name should be required");
}

/// FetchPackageTool returns error when package_name is missing
unittest {
	import std.json : parseJSON;
	import std.algorithm.searching : canFind;

	auto tool = new FetchPackageTool();
	auto args = parseJSON(`{}`);
	auto result = tool.execute(args);
	assert(result.isError, "Should return error when package_name is missing");
	assert(result.content.length > 0, "Should have error content");
	assert(result.content[0].text.canFind("package_name"), "Error should mention package_name");
}

/// FetchPackageTool returns error when package_name is whitespace
unittest {
	import std.json : parseJSON;

	auto tool = new FetchPackageTool();
	auto args = parseJSON(`{"package_name": "   "}`);
	auto result = tool.execute(args);
	assert(result.isError, "Should return error when package_name is whitespace");
}

/// UpgradeDependenciesTool has correct name and description
unittest {
	auto tool = new UpgradeDependenciesTool();
	assert(tool.name == "upgrade_dependencies",
			"Expected name 'upgrade_dependencies', got: " ~ tool.name);
	assert(tool.description.length > 0, "Description should not be empty");
}

/// UpgradeDependenciesTool schema has expected properties
unittest {
	auto tool = new UpgradeDependenciesTool();
	auto schema = tool.inputSchema;
	assert(schema["type"].str == "object", "Schema type should be 'object'");
	auto props = schema["properties"];
	assert("project_path" in props, "Schema should have project_path");
	assert("missing_only" in props, "Schema should have missing_only");
	assert("verify" in props, "Schema should have verify");
}

/// UpgradeDependenciesTool handles nonexistent path without crashing
unittest {
	import std.json : parseJSON;

	auto tool = new UpgradeDependenciesTool();
	auto args = parseJSON(`{"project_path": "/nonexistent/path/that/does/not/exist"}`);
	auto result = tool.execute(args);
	assert(result.content.length > 0, "Should return content");
}

/// BuildProjectTool has correct name, description, and schema
unittest {
	auto tool = new BuildProjectTool();
	assert(tool.name == "build_project", "Expected name 'build_project', got: " ~ tool.name);
	assert(tool.description.length > 0, "Description should not be empty");
	auto schema = tool.inputSchema;
	assert(schema["type"].str == "object");
}

/// RunTestsTool has correct name, description, and schema
unittest {
	auto tool = new RunTestsTool();
	assert(tool.name == "run_tests", "Expected name 'run_tests', got: " ~ tool.name);
	assert(tool.description.length > 0, "Description should not be empty");
	auto schema = tool.inputSchema;
	assert(schema["type"].str == "object");
}

/// AnalyzeProjectTool has correct name, description, and schema
unittest {
	auto tool = new AnalyzeProjectTool();
	assert(tool.name == "analyze_project", "Expected name 'analyze_project', got: " ~ tool.name);
	assert(tool.description.length > 0, "Description should not be empty");
	auto schema = tool.inputSchema;
	assert(schema["type"].str == "object");
}

// -- CLI tool execution tests --
// These test the tool execute + toJSON flow used by the CLI --tool flags.

version(unittest) {
	import tools.dfmt : DfmtTool;
	import tools.dscanner : DscannerTool;
	import tools.compile_check : CompileCheckTool;
	import tools.outline : ModuleOutlineTool;
}

/// DfmtTool produces valid JSON result via execute + toJSON
unittest {
	import std.json : parseJSON, JSONType;

	auto tool = new DfmtTool();
	auto args = parseJSON(`{"code":"int x=1;"}`);
	auto result = tool.execute(args);
	auto json = result.toJSON();
	assert("content" in json, "Result should have 'content' field");
	assert("isError" in json, "Result should have 'isError' field");
	assert(json["isError"].type == JSONType.false_, "dfmt with valid code should not be an error");
	assert(json["content"].array.length > 0, "Result should have at least one content block");
	assert(json["content"][0]["type"].str == "text", "Content type should be 'text'");
}

/// DscannerTool works with mode parameter via JSON args
unittest {
	import std.json : parseJSON, JSONType;

	auto tool = new DscannerTool();
	auto args = parseJSON(`{"code":"void main(){}", "mode":"sloc"}`);
	auto result = tool.execute(args);
	auto json = result.toJSON();
	assert(json["isError"].type == JSONType.false_, "dscanner sloc mode should not error");
	assert(json["content"].array.length > 0, "Should have content");
}

/// Tool returning error sets isError=true in JSON output
unittest {
	import std.json : parseJSON, JSONType;

	auto tool = new FetchPackageTool();
	auto args = parseJSON(`{}`);
	auto result = tool.execute(args);
	auto json = result.toJSON();
	assert(json["isError"].type == JSONType.true_,
			"Missing required param should produce isError=true");
}

/// ModuleOutlineTool produces valid JSON for inline code
unittest {
	import std.json : parseJSON, JSONType;

	auto tool = new ModuleOutlineTool();
	auto args = parseJSON(`{"code":"module test; void foo() {}"}`);
	auto result = tool.execute(args);
	auto json = result.toJSON();
	assert(json["isError"].type == JSONType.false_, "module outline should succeed");
	assert(json["content"].array.length > 0, "Should have content");
}

/// CompileCheckTool produces valid JSON for inline code
unittest {
	import std.json : parseJSON, JSONType;

	auto tool = new CompileCheckTool();
	auto args = parseJSON(`{"code":"void main() { int x = 1; }"}`);
	auto result = tool.execute(args);
	auto json = result.toJSON();
	assert("content" in json, "Result should have 'content'");
	assert("isError" in json, "Result should have 'isError'");
}
