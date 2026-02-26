/**
 * MCP tool for building D projects using dub.
 *
 * Executes `dub build` with configurable options and returns structured results
 * including success/failure status, parsed compiler errors with file locations,
 * and the full build output.
 */
module tools.build_project;

import std.json : JSONValue, parseJSON, JSONType;
import std.path : absolutePath;
import tools.base : BaseTool;
import mcp.types : ToolResult;
import utils.process : executeCommandInDir, ProcessResult;
import utils.diagnostic : mergeOutput, collectDiagnostics;

/**
 * Tool that builds a D/dub project and reports structured build results.
 *
 * Supports configuration selection, build type (debug/release), compiler
 * choice (dmd/ldc2), and forced rebuilds. Parses compiler diagnostic
 * output into structured error/warning records.
 */
class BuildProjectTool : BaseTool {
	@property string name()
	{
		return "build_project";
	}

	@property string description()
	{
		return "Build a D/dub project. Runs 'dub build' and returns structured results including "
			~ "success/failure status, compiler errors with file/line/message, and build output. "
			~ "Supports configuration selection, build type, compiler choice, and force rebuild.";
	}

	@property JSONValue inputSchema()
	{
		return parseJSON(`{
            "type": "object",
            "properties": {
                "project_path": {
                    "type": "string",
                    "default": ".",
                    "description": "Project root directory (must contain dub.json or dub.sdl)"
                },
                "compiler": {
                    "type": "string",
                    "enum": ["dmd", "ldc2", "gdc"],
                    "description": "Which D compiler to use (default: project default)"
                },
                "build_type": {
                    "type": "string",
                    "enum": ["debug", "release", "release-debug", "plain"],
                    "description": "Build type (default: debug)"
                },
                "configuration": {
                    "type": "string",
                    "description": "Build configuration name"
                },
                "force": {
                    "type": "boolean",
                    "default": false,
                    "description": "Force rebuild even if up-to-date"
                }
            }
        }`);
	}

	ToolResult execute(JSONValue arguments)
	{
		try {
			import std.path : absolutePath;
			import utils.security : validateCompiler;

			string projectPath = ".";
			if("project_path" in arguments && arguments["project_path"].type == JSONType.string)
				projectPath = arguments["project_path"].str;

			projectPath = absolutePath(projectPath);

			string[] cmd = ["dub", "build", "--root=" ~ projectPath];

			if("compiler" in arguments && arguments["compiler"].type == JSONType.string)
				cmd ~= [
				"--compiler=" ~ validateCompiler(arguments["compiler"].str)
			];

			if("build_type" in arguments && arguments["build_type"].type == JSONType.string)
				cmd ~= ["--build=" ~ arguments["build_type"].str];

			if("configuration" in arguments && arguments["configuration"].type == JSONType.string)
				cmd ~= ["--config=" ~ arguments["configuration"].str];

			if("force" in arguments && arguments["force"].type == JSONType.true_)
				cmd ~= "--force";

			auto result = executeCommandInDir(cmd);

			return formatBuildResult(result);
		} catch(Exception e) {
			return createErrorResult("Error running dub build: " ~ e.msg);
		}
	}

private:
	ToolResult formatBuildResult(ProcessResult result)
	{
		string fullOutput = mergeOutput(result);
		bool success = result.status == 0;

		auto diags = collectDiagnostics(fullOutput);

		auto resp = JSONValue([
			"success": JSONValue(success),
			"errors": JSONValue(diags.errors),
			"warnings": JSONValue(diags.warnings),
			"error_count": JSONValue(diags.errors.length),
			"warning_count": JSONValue(diags.warnings.length),
			"output": JSONValue(fullOutput),
		]);

		return createTextResult(resp.toString());
	}
}

// -- Unit Tests --

/// BuildProjectTool has correct name
unittest {
	auto tool = new BuildProjectTool();
	assert(tool.name == "build_project", "Expected name 'build_project', got: " ~ tool.name);
}

/// BuildProjectTool has non-empty description
unittest {
	auto tool = new BuildProjectTool();
	assert(tool.description.length > 0, "Description should not be empty");
}

/// BuildProjectTool inputSchema has correct type and all expected properties
unittest {
	import std.format : format;

	auto tool = new BuildProjectTool();
	auto schema = tool.inputSchema;
	assert(schema["type"].str == "object",
			format!"Schema type should be 'object', got '%s'"(schema["type"].str));
	auto props = schema["properties"];
	assert("project_path" in props, "Schema should have project_path");
	assert("compiler" in props, "Schema should have compiler");
	assert("build_type" in props, "Schema should have build_type");
	assert("configuration" in props, "Schema should have configuration");
	assert("force" in props, "Schema should have force");
}

/// BuildProjectTool inputSchema project_path has default value
unittest {
	import std.format : format;

	auto tool = new BuildProjectTool();
	auto schema = tool.inputSchema;
	auto pp = schema["properties"]["project_path"];
	assert(pp["type"].str == "string",
			format!"project_path type should be 'string', got '%s'"(pp["type"].str));
	assert(pp["default"].str == ".",
			format!"project_path default should be '.', got '%s'"(pp["default"].str));
}

/// BuildProjectTool inputSchema compiler has enum values
unittest {
	import std.format : format;
	import std.algorithm.searching : canFind;

	auto tool = new BuildProjectTool();
	auto schema = tool.inputSchema;
	auto compilerEnum = schema["properties"]["compiler"]["enum"].array;
	string[] compilers;
	foreach(v; compilerEnum)
		compilers ~= v.str;
	assert(compilers.canFind("dmd"), "compiler enum should include 'dmd'");
	assert(compilers.canFind("ldc2"), "compiler enum should include 'ldc2'");
	assert(compilers.canFind("gdc"), "compiler enum should include 'gdc'");
	assert(compilers.length == 3,
			format!"compiler enum should have 3 entries, got %d"(compilers.length));
}

/// BuildProjectTool inputSchema build_type has enum values
unittest {
	import std.format : format;
	import std.algorithm.searching : canFind;

	auto tool = new BuildProjectTool();
	auto schema = tool.inputSchema;
	auto btEnum = schema["properties"]["build_type"]["enum"].array;
	string[] buildTypes;
	foreach(v; btEnum)
		buildTypes ~= v.str;
	assert(buildTypes.canFind("debug"), "build_type enum should include 'debug'");
	assert(buildTypes.canFind("release"), "build_type enum should include 'release'");
	assert(buildTypes.canFind("release-debug"), "build_type enum should include 'release-debug'");
	assert(buildTypes.canFind("plain"), "build_type enum should include 'plain'");
	assert(buildTypes.length == 4,
			format!"build_type enum should have 4 entries, got %d"(buildTypes.length));
}

/// BuildProjectTool inputSchema force has boolean type and default false
unittest {
	import std.format : format;

	auto tool = new BuildProjectTool();
	auto schema = tool.inputSchema;
	auto force = schema["properties"]["force"];
	assert(force["type"].str == "boolean",
			format!"force type should be 'boolean', got '%s'"(force["type"].str));
	assert(force["default"].type == JSONType.false_, "force default should be false");
}

/// formatBuildResult with successful build (status 0, no errors)
unittest {
	import std.format : format;

	auto tool = new BuildProjectTool();
	auto pr = ProcessResult(0, "Building project...\nLinking...", "");
	auto result = tool.formatBuildResult(pr);
	assert(!result.isError, "Successful build should not be an error result");
	assert(result.content.length > 0, "Should have content");

	auto resp = parseJSON(result.content[0].text);
	assert(resp["success"].type == JSONType.true_, "success should be true for status 0");
	assert(resp["error_count"].integer == 0,
			format!"error_count should be 0, got %d"(resp["error_count"].integer));
	assert(resp["warning_count"].integer == 0,
			format!"warning_count should be 0, got %d"(resp["warning_count"].integer));
	assert(resp["errors"].array.length == 0, "errors array should be empty");
	assert(resp["warnings"].array.length == 0, "warnings array should be empty");
}

/// formatBuildResult with failed build (status 1, compiler errors)
unittest {
	import std.format : format;

	auto tool = new BuildProjectTool();
	string stderr = "source/app.d(10,5): Error: undefined identifier 'foo'\n"
		~ "source/app.d(20): Error: type mismatch";
	auto pr = ProcessResult(1, "", stderr);
	auto result = tool.formatBuildResult(pr);
	assert(!result.isError, "formatBuildResult returns text result, not error result");

	auto resp = parseJSON(result.content[0].text);
	assert(resp["success"].type == JSONType.false_, "success should be false for status 1");
	assert(resp["error_count"].integer == 2,
			format!"error_count should be 2, got %d"(resp["error_count"].integer));
	assert(resp["errors"].array.length == 2,
			format!"errors array should have 2 entries, got %d"(resp["errors"].array.length));

	// Verify first error details
	auto err0 = resp["errors"].array[0];
	assert(err0["file"].str == "source/app.d",
			format!"First error file should be 'source/app.d', got '%s'"(err0["file"].str));
	assert(err0["line"].integer == 10,
			format!"First error line should be 10, got %d"(err0["line"].integer));
	assert(err0["column"].integer == 5,
			format!"First error column should be 5, got %d"(err0["column"].integer));
	assert(err0["severity"].str == "error",
			format!"First error severity should be 'error', got '%s'"(err0["severity"].str));
}

/// formatBuildResult with warnings
unittest {
	import std.format : format;

	auto tool = new BuildProjectTool();
	string stderr = "source/lib.d(15,3): Warning: implicit conversion\n"
		~ "source/lib.d(30): Deprecation: use of old syntax";
	auto pr = ProcessResult(0, "Build succeeded", stderr);
	auto result = tool.formatBuildResult(pr);

	auto resp = parseJSON(result.content[0].text);
	assert(resp["success"].type == JSONType.true_, "success should be true");
	assert(resp["warning_count"].integer == 2,
			format!"warning_count should be 2, got %d"(resp["warning_count"].integer));
	assert(resp["error_count"].integer == 0,
			format!"error_count should be 0, got %d"(resp["error_count"].integer));
	assert(resp["warnings"].array.length == 2,
			format!"warnings array should have 2 entries, got %d"(resp["warnings"].array.length));
}

/// formatBuildResult with mixed errors and warnings
unittest {
	import std.format : format;

	auto tool = new BuildProjectTool();
	string stderr = "source/a.d(1): Error: bad type\n"
		~ "source/b.d(2,5): Warning: sketchy thing\n" ~ "source/c.d(3): Deprecation: old thing";
	auto pr = ProcessResult(1, "", stderr);
	auto result = tool.formatBuildResult(pr);

	auto resp = parseJSON(result.content[0].text);
	assert(resp["success"].type == JSONType.false_, "success should be false");
	assert(resp["error_count"].integer == 1,
			format!"error_count should be 1, got %d"(resp["error_count"].integer));
	assert(resp["warning_count"].integer == 2,
			format!"warning_count should be 2 (warning + deprecation), got %d"(
				resp["warning_count"].integer));
}

/// formatBuildResult with empty output
unittest {
	import std.format : format;

	auto tool = new BuildProjectTool();
	auto pr = ProcessResult(0, "", "");
	auto result = tool.formatBuildResult(pr);

	auto resp = parseJSON(result.content[0].text);
	assert(resp["success"].type == JSONType.true_, "success should be true");
	assert(resp["error_count"].integer == 0,
			format!"error_count should be 0, got %d"(resp["error_count"].integer));
	assert(resp["warning_count"].integer == 0,
			format!"warning_count should be 0, got %d"(resp["warning_count"].integer));
	assert(resp["output"].str == "", "output should be empty string");
}

/// formatBuildResult merges stdout and stderr into output field
unittest {
	import std.format : format;
	import std.algorithm.searching : canFind;

	auto tool = new BuildProjectTool();
	auto pr = ProcessResult(0, "stdout content", "stderr content");
	auto result = tool.formatBuildResult(pr);

	auto resp = parseJSON(result.content[0].text);
	assert(resp["output"].str.canFind("stdout content"),
			format!"output should contain 'stdout content', got '%s'"(resp["output"].str));
	assert(resp["output"].str.canFind("stderr content"),
			format!"output should contain 'stderr content', got '%s'"(resp["output"].str));
}

/// formatBuildResult output contains the full compiler error text
unittest {
	import std.algorithm.searching : canFind;

	auto tool = new BuildProjectTool();
	string stderr = "source/app.d(5): Error: cannot implicitly convert";
	auto pr = ProcessResult(1, "", stderr);
	auto result = tool.formatBuildResult(pr);

	auto resp = parseJSON(result.content[0].text);
	assert(resp["output"].str.canFind("cannot implicitly convert"),
			"output field should contain the full error text");
}

/// formatBuildResult with non-diagnostic output lines (ignored in errors/warnings)
unittest {
	import std.format : format;

	auto tool = new BuildProjectTool();
	string output = "Building dlang_mcp ~master: building...\n"
		~ "Compiling source/app.d\n" ~ "Linking...\n" ~ "Build complete.";
	auto pr = ProcessResult(0, output, "");
	auto result = tool.formatBuildResult(pr);

	auto resp = parseJSON(result.content[0].text);
	assert(resp["success"].type == JSONType.true_, "success should be true");
	assert(resp["error_count"].integer == 0,
			format!"Non-diagnostic lines should not create errors, got %d"(
				resp["error_count"].integer));
	assert(resp["warning_count"].integer == 0,
			format!"Non-diagnostic lines should not create warnings, got %d"(
				resp["warning_count"].integer));
}

/// formatBuildResult result content is valid JSON
unittest {
	auto tool = new BuildProjectTool();
	auto pr = ProcessResult(2, "some output", "some error");
	auto result = tool.formatBuildResult(pr);

	assert(result.content.length == 1, "Should have exactly 1 content block");
	assert(result.content[0].type == "text", "Content type should be 'text'");

	// Should parse without exception
	auto resp = parseJSON(result.content[0].text);
	assert("success" in resp, "JSON should have 'success' key");
	assert("errors" in resp, "JSON should have 'errors' key");
	assert("warnings" in resp, "JSON should have 'warnings' key");
	assert("error_count" in resp, "JSON should have 'error_count' key");
	assert("warning_count" in resp, "JSON should have 'warning_count' key");
	assert("output" in resp, "JSON should have 'output' key");
}

/// formatBuildResult with non-zero status and no diagnostic output
unittest {
	import std.format : format;

	auto tool = new BuildProjectTool();
	auto pr = ProcessResult(2, "", "dub: command not found");
	auto result = tool.formatBuildResult(pr);

	auto resp = parseJSON(result.content[0].text);
	assert(resp["success"].type == JSONType.false_, "success should be false for non-zero status");
	assert(resp["error_count"].integer == 0,
			format!"Non-diagnostic stderr should not count as errors, got %d"(
				resp["error_count"].integer));
	assert(resp["output"].str == "dub: command not found",
			format!"output should contain stderr text, got '%s'"(resp["output"].str));
}
