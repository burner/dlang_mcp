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
		return "Format D source code to consistent style with configurable brace placement, indentation, and line length. Use when asked to format, prettify, beautify, or fix indentation of D code. Returns the complete reformatted source as text. Does not detect bugs or verify correctness — for linting and static analysis use dscanner; for compilation error checking use compile_check.";
	}

	@property JSONValue inputSchema()
	{
		return parseJSON(`{
            "type": "object",
            "properties": {
                "code": {
                    "type": "string",
                    "description": "D source code to format. Required — paste the raw source."
                },
                "brace_style": {
                    "type": "string",
                    "enum": ["allman", "otbs", "stroustrup"],
                    "description": "Brace placement style: allman (default, braces on own line), otbs (opening brace on same line), stroustrup (like otbs but closing brace on own line).",
                    "default": "allman"
                },
                "indent_size": {
                    "type": "integer",
                    "description": "Spaces per indentation level (1-8, default: 4).",
                    "default": 4,
                    "minimum": 1,
                    "maximum": 8
                },
                "max_line_length": {
                    "type": "integer",
                    "description": "Wrap lines longer than this (default: 120, minimum: 40).",
                    "default": 120,
                    "minimum": 40
                }
            },
            "required": ["code"]
        }`);
	}

	/// Build the dfmt command array from the given JSON arguments.
	/// Exposed for unit testing without invoking an external process.
	package string[] buildCommand(JSONValue arguments)
	{
		string[] command = ["dfmt"];

		if("brace_style" in arguments && arguments["brace_style"].type == JSONType.string) {
			command ~= "--brace_style=" ~ arguments["brace_style"].str;
		}

		if("indent_size" in arguments && arguments["indent_size"].type == JSONType.integer) {
			import std.conv : text;

			command ~= "--indent_size=" ~ text(arguments["indent_size"].integer);
		}

		if("max_line_length" in arguments && arguments["max_line_length"].type == JSONType.integer) {
			import std.conv : text;

			command ~= "--max_line_length=" ~ text(arguments["max_line_length"].integer);
		}

		return command;
	}

	ToolResult execute(JSONValue arguments)
	{
		try {
			if(arguments.type != JSONType.object || !("code" in arguments)) {
				return createErrorResult("Missing required 'code' parameter");
			}

			string code = arguments["code"].str;
			string[] command = buildCommand(arguments);

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

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

/// DfmtTool has the correct tool name.
unittest {
	auto tool = new DfmtTool();
	assert(tool.name == "dfmt", "Expected name 'dfmt', got: " ~ tool.name);
}

/// DfmtTool description is non-empty and mentions formatting.
unittest {
	import std.algorithm.searching : canFind;

	auto tool = new DfmtTool();
	assert(tool.description.length > 0, "Description should not be empty");
	assert(tool.description.canFind("Format"), "Description should mention formatting");
}

/// inputSchema is a valid object schema with required properties.
unittest {
	auto tool = new DfmtTool();
	auto schema = tool.inputSchema;
	assert(schema["type"].str == "object", "Schema type should be 'object'");

	auto props = schema["properties"];
	assert("code" in props, "Schema should have 'code' property");
	assert("brace_style" in props, "Schema should have 'brace_style' property");
	assert("indent_size" in props, "Schema should have 'indent_size' property");
	assert("max_line_length" in props, "Schema should have 'max_line_length' property");

	// "code" must be listed as required
	bool codeRequired = false;
	foreach(r; schema["required"].array) {
		if(r.str == "code")
			codeRequired = true;
	}
	assert(codeRequired, "'code' should be in the required array");
}

/// inputSchema brace_style enum contains the three expected values.
unittest {
	import std.format : format;

	auto tool = new DfmtTool();
	auto schema = tool.inputSchema;
	auto braceEnum = schema["properties"]["brace_style"]["enum"].array;
	assert(braceEnum.length == 3,
			format!"Expected 3 brace_style enum values, got %d"(braceEnum.length));

	string[] expected = ["allman", "otbs", "stroustrup"];
	foreach(i, exp; expected) {
		assert(braceEnum[i].str == exp,
				format!"Expected brace_style[%d] == '%s', got '%s'"(i, exp, braceEnum[i].str));
	}
}

/// inputSchema indent_size has correct bounds.
unittest {
	import std.format : format;

	auto tool = new DfmtTool();
	auto schema = tool.inputSchema;
	auto indentProp = schema["properties"]["indent_size"];
	assert(indentProp["minimum"].integer == 1,
			format!"Expected indent_size minimum 1, got %d"(indentProp["minimum"].integer));
	assert(indentProp["maximum"].integer == 8,
			format!"Expected indent_size maximum 8, got %d"(indentProp["maximum"].integer));
	assert(indentProp["default"].integer == 4,
			format!"Expected indent_size default 4, got %d"(indentProp["default"].integer));
}

/// inputSchema max_line_length has correct bounds.
unittest {
	import std.format : format;

	auto tool = new DfmtTool();
	auto schema = tool.inputSchema;
	auto mlProp = schema["properties"]["max_line_length"];
	assert(mlProp["minimum"].integer == 40,
			format!"Expected max_line_length minimum 40, got %d"(mlProp["minimum"].integer));
	assert(mlProp["default"].integer == 120,
			format!"Expected max_line_length default 120, got %d"(mlProp["default"].integer));
}

/// execute returns error when arguments is not an object (null JSON).
unittest {
	import std.algorithm.searching : canFind;

	auto tool = new DfmtTool();
	auto args = JSONValue(null);
	auto result = tool.execute(args);
	assert(result.isError, "Should return error for null arguments");
	assert(result.content.length > 0, "Should have error content");
	assert(result.content[0].text.canFind("Missing required 'code' parameter"),
			"Error message should mention missing code parameter");
}

/// execute returns error when 'code' key is absent.
unittest {
	import std.algorithm.searching : canFind;

	auto tool = new DfmtTool();
	auto args = parseJSON(`{"brace_style": "allman"}`);
	auto result = tool.execute(args);
	assert(result.isError, "Should return error when code is missing");
	assert(result.content[0].text.canFind("Missing required 'code' parameter"),
			"Error message should mention missing code parameter");
}

/// execute returns error when arguments is a JSON array instead of object.
unittest {
	auto tool = new DfmtTool();
	auto args = parseJSON(`[1, 2, 3]`);
	auto result = tool.execute(args);
	assert(result.isError, "Should return error for array arguments");
}

/// execute returns error when arguments is a JSON string instead of object.
unittest {
	auto tool = new DfmtTool();
	auto args = JSONValue("just a string");
	auto result = tool.execute(args);
	assert(result.isError, "Should return error for string arguments");
}

/// buildCommand returns only ["dfmt"] when no optional args are provided.
unittest {
	auto tool = new DfmtTool();
	auto args = parseJSON(`{"code": "void main() {}"}`);
	auto cmd = tool.buildCommand(args);
	assert(cmd == ["dfmt"], "Default command should be just ['dfmt']");
}

/// buildCommand includes --brace_style when provided.
unittest {
	import std.format : format;
	import std.algorithm.searching : canFind;

	auto tool = new DfmtTool();
	foreach(style; ["allman", "otbs", "stroustrup"]) {
		auto args = parseJSON(format!`{"code": "x", "brace_style": "%s"}`(style));
		auto cmd = tool.buildCommand(args);
		auto expected = "--brace_style=" ~ style;
		assert(cmd.canFind(expected), format!"Command should contain '%s', got %s"(expected, cmd));
	}
}

/// buildCommand includes --indent_size when provided.
unittest {
	import std.format : format;
	import std.algorithm.searching : canFind;

	auto tool = new DfmtTool();
	auto args = parseJSON(`{"code": "x", "indent_size": 2}`);
	auto cmd = tool.buildCommand(args);
	assert(cmd.canFind("--indent_size=2"),
			format!"Command should contain '--indent_size=2', got %s"(cmd));
}

/// buildCommand includes --max_line_length when provided.
unittest {
	import std.format : format;
	import std.algorithm.searching : canFind;

	auto tool = new DfmtTool();
	auto args = parseJSON(`{"code": "x", "max_line_length": 80}`);
	auto cmd = tool.buildCommand(args);
	assert(cmd.canFind("--max_line_length=80"),
			format!"Command should contain '--max_line_length=80', got %s"(cmd));
}

/// buildCommand includes all optional parameters when all are provided.
unittest {
	import std.format : format;
	import std.algorithm.searching : canFind;

	auto tool = new DfmtTool();
	auto args = parseJSON(`{
		"code": "void main() {}",
		"brace_style": "otbs",
		"indent_size": 2,
		"max_line_length": 80
	}`);
	auto cmd = tool.buildCommand(args);
	assert(cmd.length == 4, format!"Expected 4 command parts, got %d"(cmd.length));
	assert(cmd[0] == "dfmt");
	assert(cmd.canFind("--brace_style=otbs"));
	assert(cmd.canFind("--indent_size=2"));
	assert(cmd.canFind("--max_line_length=80"));
}

/// buildCommand ignores brace_style when it is not a string type.
unittest {
	auto tool = new DfmtTool();
	auto args = parseJSON(`{"code": "x", "brace_style": 42}`);
	auto cmd = tool.buildCommand(args);
	assert(cmd == ["dfmt"], "Non-string brace_style should be ignored");
}

/// buildCommand ignores indent_size when it is not an integer type.
unittest {
	auto tool = new DfmtTool();
	auto args = parseJSON(`{"code": "x", "indent_size": "four"}`);
	auto cmd = tool.buildCommand(args);
	assert(cmd == ["dfmt"], "Non-integer indent_size should be ignored");
}

/// buildCommand ignores max_line_length when it is not an integer type.
unittest {
	auto tool = new DfmtTool();
	auto args = parseJSON(`{"code": "x", "max_line_length": "eighty"}`);
	auto cmd = tool.buildCommand(args);
	assert(cmd == ["dfmt"], "Non-integer max_line_length should be ignored");
}

/// DfmtTool can be instantiated and used through the Tool interface.
unittest {
	import tools.base : Tool;

	Tool tool = new DfmtTool();
	assert(tool.name == "dfmt");
	assert(tool.description.length > 0);
	auto schema = tool.inputSchema;
	assert(schema["type"].str == "object");
}
