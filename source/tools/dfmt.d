/**
 * MCP tool for formatting D source code using dfmt.
 *
 * Pipes D source code through the `dfmt` formatter with configurable
 * brace style, indentation, and line length options.
 */
module tools.dfmt;

import std.json : JSONValue, parseJSON, JSONType;
import std.string : strip;
import tools.base : BaseTool;
import mcp.types : ToolResult;
import utils.process : executeCommandWithInput;

/**
 * Tool that formats D source code according to configurable style guidelines.
 *
 * Accepts source code as input and returns the formatted result. Supports
 * brace style (allman, otbs, stroustrup), indent size, and maximum line
 * length configuration.
 */
class DfmtTool : BaseTool {
	@property string name()
	{
		return "dfmt";
	}

	@property string description()
	{
		return "Format D source code according to style guidelines. Returns formatted code with consistent indentation, spacing, and style.";
	}

	@property JSONValue inputSchema()
	{
		return parseJSON(`{
            "type": "object",
            "properties": {
                "code": {
                    "type": "string",
                    "description": "D source code to format"
                },
                "brace_style": {
                    "type": "string",
                    "enum": ["allman", "otbs", "stroustrup"],
                    "description": "Brace style to use",
                    "default": "allman"
                },
                "indent_size": {
                    "type": "integer",
                    "description": "Number of spaces for indentation",
                    "default": 4,
                    "minimum": 1,
                    "maximum": 8
                },
                "max_line_length": {
                    "type": "integer",
                    "description": "Maximum line length",
                    "default": 120,
                    "minimum": 40
                }
            },
            "required": ["code"]
        }`);
	}

	ToolResult execute(JSONValue arguments)
	{
		try {
			if(arguments.type != JSONType.object || !("code" in arguments)) {
				return createErrorResult("Missing required 'code' parameter");
			}

			string code = arguments["code"].str;
			string[] command = ["dfmt"];

			if("brace_style" in arguments && arguments["brace_style"].type == JSONType.string) {
				command ~= "--brace_style=" ~ arguments["brace_style"].str;
			}

			if("indent_size" in arguments && arguments["indent_size"].type == JSONType.integer) {
				import std.conv : text;

				command ~= "--indent_size=" ~ text(arguments["indent_size"].integer);
			}

			if("max_line_length" in arguments
					&& arguments["max_line_length"].type == JSONType.integer) {
				import std.conv : text;

				command ~= "--max_line_length=" ~ text(arguments["max_line_length"].integer);
			}

			auto result = executeCommandWithInput(command, code);

			if(result.status == 0 && result.output.length > 0) {
				return createTextResult(result.output);
			} else {
				string errorMsg = result.stderrOutput.length > 0 ? result.stderrOutput
					: result.output;
				return createErrorResult("dfmt failed: " ~ errorMsg);
			}
		} catch(Exception e) {
			return createErrorResult("Error executing dfmt: " ~ e.msg);
		}
	}
}
