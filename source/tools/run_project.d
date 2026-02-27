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
		return "Build and execute a D/dub project, returning its output and exit code. Use when asked "
			~ "to run, execute, launch, or try a D program. Builds if needed, then runs the binary. "
			~ "Returns stdout, stderr, exit code, and compiler errors if build fails. Requires "
			~ "dub.json or dub.sdl. For building without running use build_project; for tests use run_tests.";
	}

	@property JSONValue inputSchema()
	{
		return parseJSON(`{
            "type": "object",
            "properties": {
                "project_path": {
                    "type": "string",
                    "default": ".",
                    "description": "Path to the project root containing dub.json or dub.sdl (default: current directory)."
                },
                "compiler": {
                    "type": "string",
                    "enum": ["dmd", "ldc2", "gdc"],
                    "description": "D compiler to use. Defaults to project setting."
                },
                "build_type": {
                    "type": "string",
                    "enum": ["debug", "release", "release-debug", "plain"],
                    "description": "Build type: debug (default), release (optimized), release-debug, plain."
                },
                "configuration": {
                    "type": "string",
                    "description": "Dub build configuration name. Omit to use default."
                },
                "args": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Command-line arguments passed to the program (e.g., [\"--port\", \"8080\"])."
                },
                "force": {
                    "type": "boolean",
                    "default": false,
                    "description": "Force rebuild before running (default: false)."
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
	package ToolResult formatRunResult(ProcessResult result)
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

// -- Unit Tests --

/// formatRunResult with successful run (status 0, build completed, ran program)
unittest {
	import std.format : format;

	auto tool = new RunProjectTool();
	string stdout = "Building project...\nLinking...\nRunning ./myapp\nHello, World!";
	auto pr = ProcessResult(0, stdout, "");
	auto result = tool.formatRunResult(pr);
	assert(!result.isError, "Successful run should not be an error result");
	assert(result.content.length > 0, "Should have content");

	auto resp = parseJSON(result.content[0].text);
	assert(resp["success"].type == JSONType.true_, "success should be true for status 0");
	assert(resp["phase"].str == "run",
			format!"phase should be 'run' when build completed, got '%s'"(resp["phase"].str));
	assert(resp["exit_code"].integer == 0,
			format!"exit_code should be 0, got %d"(resp["exit_code"].integer));
	assert(resp["error_count"].integer == 0,
			format!"error_count should be 0, got %d"(resp["error_count"].integer));
	assert(resp["warning_count"].integer == 0,
			format!"warning_count should be 0, got %d"(resp["warning_count"].integer));
}

/// formatRunResult detects run phase via "Linking..." marker
unittest {
	import std.format : format;

	auto tool = new RunProjectTool();
	string stdout = "Compiling...\nLinking...\nProgram output here";
	auto pr = ProcessResult(0, stdout, "");
	auto result = tool.formatRunResult(pr);

	auto resp = parseJSON(result.content[0].text);
	assert(resp["phase"].str == "run",
			format!"phase should be 'run' when Linking... detected, got '%s'"(resp["phase"].str));
}

/// formatRunResult with build failure containing compilation errors
unittest {
	import std.format : format;

	auto tool = new RunProjectTool();
	string stderr = "source/app.d(10,5): Error: undefined identifier 'foo'\n"
		~ "source/app.d(20): Error: type mismatch";
	auto pr = ProcessResult(1, "", stderr);
	auto result = tool.formatRunResult(pr);
	assert(!result.isError, "formatRunResult wraps in text result, not error result");

	auto resp = parseJSON(result.content[0].text);
	assert(resp["success"].type == JSONType.false_, "success should be false for status 1");
	assert(resp["phase"].str == "build",
			format!"phase should be 'build' when errors present, got '%s'"(resp["phase"].str));
	assert(resp["error_count"].integer == 2,
			format!"error_count should be 2, got %d"(resp["error_count"].integer));
	assert(resp["compilation_errors"].array.length == 2,
			format!"compilation_errors should have 2 entries, got %d"(
				resp["compilation_errors"].array.length));

	// Verify first error details
	auto err0 = resp["compilation_errors"].array[0];
	assert(err0["file"].str == "source/app.d",
			format!"First error file should be 'source/app.d', got '%s'"(err0["file"].str));
	assert(err0["line"].integer == 10,
			format!"First error line should be 10, got %d"(err0["line"].integer));
}

/// formatRunResult with compilation warnings (before build completes)
unittest {
	import std.format : format;

	auto tool = new RunProjectTool();
	string stderr = "source/foo.d(5,3): Warning: implicit conversion\n"
		~ "source/bar.d(12): Deprecation: old syntax";
	auto pr = ProcessResult(0, "", stderr);
	auto result = tool.formatRunResult(pr);

	auto resp = parseJSON(result.content[0].text);
	assert(resp["warning_count"].integer == 2,
			format!"warning_count should be 2, got %d"(resp["warning_count"].integer));
	assert(resp["compilation_warnings"].array.length == 2,
			format!"compilation_warnings should have 2 entries, got %d"(
				resp["compilation_warnings"].array.length));
	assert(resp["error_count"].integer == 0,
			format!"error_count should be 0, got %d"(resp["error_count"].integer));
}

/// formatRunResult with runtime failure (build succeeds, program exits non-zero)
unittest {
	import std.format : format;

	auto tool = new RunProjectTool();
	string stdout = "Building...\nLinking...\nRunning ./myapp\nSegmentation fault";
	auto pr = ProcessResult(139, stdout, "");
	auto result = tool.formatRunResult(pr);

	auto resp = parseJSON(result.content[0].text);
	assert(resp["success"].type == JSONType.false_, "success should be false for non-zero exit");
	assert(resp["phase"].str == "run",
			format!"phase should be 'run' when build completed but program failed, got '%s'"(
				resp["phase"].str));
	assert(resp["exit_code"].integer == 139,
			format!"exit_code should be 139, got %d"(resp["exit_code"].integer));
	assert(resp["error_count"].integer == 0,
			format!"error_count should be 0 (runtime failure, not build), got %d"(
				resp["error_count"].integer));
}

/// formatRunResult with empty output
unittest {
	import std.format : format;

	auto tool = new RunProjectTool();
	auto pr = ProcessResult(0, "", "");
	auto result = tool.formatRunResult(pr);

	auto resp = parseJSON(result.content[0].text);
	assert(resp["success"].type == JSONType.true_, "success should be true for status 0");
	assert(resp["phase"].str == "build",
			format!"phase should be 'build' when no Running marker seen, got '%s'"(
				resp["phase"].str));
	assert(resp["output"].str == "", "output should be empty");
}

/// formatRunResult with mixed errors and warnings before build completion
unittest {
	import std.format : format;

	auto tool = new RunProjectTool();
	string stderr = "source/app.d(1): Error: bad thing\n"
		~ "source/app.d(2,5): Warning: sketchy thing\n" ~ "source/app.d(3): Deprecation: old thing";
	auto pr = ProcessResult(1, "", stderr);
	auto result = tool.formatRunResult(pr);

	auto resp = parseJSON(result.content[0].text);
	assert(resp["error_count"].integer == 1,
			format!"error_count should be 1, got %d"(resp["error_count"].integer));
	assert(resp["warning_count"].integer == 2,
			format!"warning_count should be 2 (warning + deprecation), got %d"(
				resp["warning_count"].integer));
	assert(resp["phase"].str == "build",
			format!"phase should be 'build' when errors present, got '%s'"(resp["phase"].str));
}

/// formatRunResult ignores diagnostics after build phase marker
unittest {
	import std.format : format;

	auto tool = new RunProjectTool();
	// Error line appears AFTER "Running " marker, so should be ignored
	string stdout = "Compiling...\nRunning ./myapp\nsource/app.d(10): Error: this should be ignored";
	auto pr = ProcessResult(1, stdout, "");
	auto result = tool.formatRunResult(pr);

	auto resp = parseJSON(result.content[0].text);
	assert(resp["error_count"].integer == 0,
			format!"error_count should be 0 (errors after Running marker ignored), got %d"(
				resp["error_count"].integer));
	assert(resp["phase"].str == "run",
			format!"phase should be 'run' since Running marker was found, got '%s'"(
				resp["phase"].str));
}

/// formatRunResult with non-zero status and no errors sets phase to build
unittest {
	import std.format : format;

	auto tool = new RunProjectTool();
	auto pr = ProcessResult(1, "some non-diagnostic output", "");
	auto result = tool.formatRunResult(pr);

	auto resp = parseJSON(result.content[0].text);
	assert(resp["success"].type == JSONType.false_, "success should be false");
	assert(resp["phase"].str == "build",
			format!"phase should be 'build' when no build completion marker and no errors, got '%s'"(
				resp["phase"].str));
}

/// formatRunResult merges stdout and stderr into output field
unittest {
	auto tool = new RunProjectTool();
	auto pr = ProcessResult(0, "stdout content", "stderr content");
	auto result = tool.formatRunResult(pr);

	auto resp = parseJSON(result.content[0].text);
	assert(resp["output"].str == "stdout content\nstderr content",
			"output should contain both stdout and stderr merged");
}

/// formatRunResult result content is valid JSON with all expected keys
unittest {
	import std.format : format;

	auto tool = new RunProjectTool();
	auto pr = ProcessResult(0, "Running ./app\nOK", "");
	auto result = tool.formatRunResult(pr);

	auto resp = parseJSON(result.content[0].text);
	assert("success" in resp, "response should have 'success' key");
	assert("phase" in resp, "response should have 'phase' key");
	assert("exit_code" in resp, "response should have 'exit_code' key");
	assert("compilation_errors" in resp, "response should have 'compilation_errors' key");
	assert("compilation_warnings" in resp, "response should have 'compilation_warnings' key");
	assert("error_count" in resp, "response should have 'error_count' key");
	assert("warning_count" in resp, "response should have 'warning_count' key");
	assert("output" in resp, "response should have 'output' key");
}
