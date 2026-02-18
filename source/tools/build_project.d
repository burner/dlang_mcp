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
