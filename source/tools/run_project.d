/**
 * MCP tool for running D projects using dub.
 *
 * Executes `dub run` with configurable options and returns structured results
 * including success/failure status, parsed compiler errors if the build fails,
 * the program's runtime output, and the exit code.
 */
module tools.run_project;

import std.json : JSONValue, parseJSON, JSONType;
import std.path : absolutePath;
import std.array : appender, split;
import std.algorithm.searching : canFind;
import tools.base : BaseTool;
import mcp.types : ToolResult;
import utils.process : executeCommandInDir, ProcessResult;
import utils.diagnostic : mergeOutput, parseDiagnostic;

/**
 * Tool that runs a D/dub project and reports structured results.
 *
 * Supports configuration selection, build type (debug/release), compiler
 * choice (dmd/ldc2), and passing arguments through to the built program.
 * Parses compiler diagnostic output into structured error/warning records
 * when the build phase fails.
 */
class RunProjectTool : BaseTool {
	@property string name()
	{
		return "run_project";
	}

	@property string description()
	{
		return "Run a D/dub project. Executes 'dub run' and returns structured results including "
			~ "success/failure status, compiler errors if build fails, program output, and exit code. "
			~ "Supports configuration selection, build type, compiler choice, and passing arguments "
			~ "to the built program.";
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
                "args": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Arguments to pass to the built program (after the -- separator)"
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

			string[] cmd = ["dub", "run", "--root=" ~ projectPath];

			if("compiler" in arguments && arguments["compiler"].type == JSONType.string)
				cmd ~= "--compiler=" ~ validateCompiler(arguments["compiler"].str);

			if("build_type" in arguments && arguments["build_type"].type == JSONType.string)
				cmd ~= "--build=" ~ arguments["build_type"].str;

			if("configuration" in arguments && arguments["configuration"].type == JSONType.string)
				cmd ~= "--config=" ~ arguments["configuration"].str;

			if("force" in arguments && arguments["force"].type == JSONType.true_)
				cmd ~= "--force";

			// Pass program arguments after the -- separator
			if("args" in arguments && arguments["args"].type == JSONType.array) {
				auto programArgs = arguments["args"].array;
				if(programArgs.length > 0) {
					cmd ~= "--";
					foreach(arg; programArgs) {
						if(arg.type == JSONType.string)
							cmd ~= arg.str;
					}
				}
			}

			auto result = executeCommandInDir(cmd);

			return formatRunResult(result);
		} catch(Exception e) {
			return createErrorResult("Error running dub run: " ~ e.msg);
		}
	}

private:
	ToolResult formatRunResult(ProcessResult result)
	{
		string fullOutput = mergeOutput(result);
		bool success = result.status == 0;

		// Parse compiler errors from the output (build phase failures)
		auto errors = appender!(JSONValue[]);
		auto warnings = appender!(JSONValue[]);

		// Detect which phase failed
		bool buildCompleted = false;

		foreach(line; fullOutput.split("\n")) {
			// Detect transition from build to run phase
			// dub outputs "Running ./binary" or similar when build succeeds
			if(!buildCompleted && (line.canFind("Running ") || line.canFind("Linking..."))) {
				buildCompleted = true;
			}

			// Parse compilation errors (only meaningful during build phase)
			if(!buildCompleted) {
				auto diag = parseDiagnostic(line);
				if(diag.type != JSONType.null_) {
					if("file" in diag && diag["severity"].str == "error")
						errors ~= diag;
					else if("file" in diag)
						warnings ~= diag;
				}
			}
		}

		auto resp = JSONValue([
			"success": JSONValue(success),
			"phase": JSONValue(!success && errors.data.length > 0
					? "build" : (buildCompleted ? "run" : "build")),
			"exit_code": JSONValue(result.status),
			"compilation_errors": JSONValue(errors.data),
			"compilation_warnings": JSONValue(warnings.data),
			"error_count": JSONValue(errors.data.length),
			"warning_count": JSONValue(warnings.data.length),
			"output": JSONValue(fullOutput),
		]);

		return createTextResult(resp.toString());
	}
}
