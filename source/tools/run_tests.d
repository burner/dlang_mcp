/**
 * MCP tool for running tests in D/dub projects.
 *
 * Executes `dub test` with configurable options and returns structured
 * results including pass/fail status, parsed test output, compiler errors
 * if the build fails, and a summary.
 */
module tools.run_tests;

import std.json : JSONValue, parseJSON, JSONType;
import std.path : absolutePath;
import std.string : strip;
import std.array : appender, split;
import std.conv : to;
import std.algorithm.searching : canFind;
import tools.base : BaseTool;
import mcp.types : ToolResult;
import utils.process : executeCommandInDir, ProcessResult;
import utils.diagnostic : mergeOutput, parseDiagnostic;

/**
 * Tool that runs tests for a D/dub project and reports structured results.
 *
 * Supports configuration selection, compiler choice, unit test name filtering,
 * and verbose output mode. Parses both compiler diagnostics and test failure
 * messages into structured records.
 */
class RunTestsTool : BaseTool {
	@property string name()
	{
		return "run_tests";
	}

	@property string description()
	{
		return "Run tests for a D/dub project. Executes 'dub test' and returns structured results "
			~ "including pass/fail status, test output, compiler errors if build fails, and summary. "
			~ "Supports configuration selection, compiler choice, and verbose mode.";
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
                "configuration": {
                    "type": "string",
                    "description": "Build configuration name"
                },
                "verbose": {
                    "type": "boolean",
                    "default": false,
                    "description": "Show verbose test output"
                },
                "filter": {
                    "type": "string",
                    "description": "Unit test name filter (only run matching tests)"
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

			string[] cmd = ["dub", "test", "--root=" ~ projectPath];

			if("compiler" in arguments && arguments["compiler"].type == JSONType.string)
				cmd ~= [
				"--compiler=" ~ validateCompiler(arguments["compiler"].str)
			];

			if("configuration" in arguments && arguments["configuration"].type == JSONType.string)
				cmd ~= ["--config=" ~ arguments["configuration"].str];

			// dub test passes extra args after -- to the test runner
			bool hasExtraArgs = false;

			if("verbose" in arguments && arguments["verbose"].type == JSONType.true_) {
				cmd ~= "--";
				cmd ~= "-v";
				hasExtraArgs = true;
			}

			if("filter" in arguments && arguments["filter"].type == JSONType.string) {
				if(!hasExtraArgs)
					cmd ~= "--";
				cmd ~= ["--filter", arguments["filter"].str];
			}

			auto result = executeCommandInDir(cmd);

			return formatTestResult(result);
		} catch(Exception e) {
			return createErrorResult("Error running dub test: " ~ e.msg);
		}
	}

private:
	ToolResult formatTestResult(ProcessResult result)
	{
		string fullOutput = mergeOutput(result);
		bool success = result.status == 0;

		// Parse errors (from compilation failures)
		auto errors = appender!(JSONValue[]);
		auto warnings = appender!(JSONValue[]);

		// Parse test results
		auto testFailures = appender!(JSONValue[]);
		int testsRun = 0;
		int testsPassed = 0;
		int testsFailed = 0;

		string phase = "build"; // build -> test

		foreach(line; fullOutput.split("\n")) {
			// Detect transition from build to test phase
			if(line.canFind("Running") && line.canFind("test"))
				phase = "test";

			// Parse compilation errors
			auto diag = parseDiagnostic(line);
			if(diag.type != JSONType.null_ && "file" in diag) {
				if(diag["severity"].str == "error")
					errors ~= diag;
				else
					warnings ~= diag;
				continue;
			}

			// Parse test runner output
			// D's built-in test runner outputs lines like:
			// core.exception.AssertError@source/file.d(42): assertion failure
			// Also "X modules passed unittests" or "N/M modules FAILED"
			if(line.canFind("modules passed unittests")) {
				// "42 modules passed unittests"
				auto parts = line.strip().split(" ");
				if(parts.length > 0) {
					try {
						testsPassed = parts[0].to!int;
					} catch(Exception) {
					}
				}
			} else if(line.canFind("modules FAILED")) {
				// "2/42 modules FAILED unittests"
				auto parts = line.strip().split(" ");
				if(parts.length > 0) {
					auto fraction = parts[0].split("/");
					if(fraction.length == 2) {
						try {
							testsFailed = fraction[0].to!int;
							testsRun = fraction[1].to!int;
						} catch(Exception) {
						}
					}
				}
			} else if(line.canFind("AssertError")
					|| line.canFind("assertion failure") || line.canFind("Assertion failure")) {
				auto failure = parseTestFailure(line);
				if(failure.type != JSONType.null_)
					testFailures ~= failure;
			}
		}

		// If we got passed count but no failed, calculate totals
		if(testsPassed > 0 && testsRun == 0)
			testsRun = testsPassed;
		if(testsFailed > 0 && testsRun > testsPassed)
			testsPassed = testsRun - testsFailed;

		auto resp = JSONValue([
			"success": JSONValue(success),
			"phase": JSONValue(errors.data.length > 0 && !success ? "compilation" : "test"),
			"tests_run": JSONValue(testsRun),
			"tests_passed": JSONValue(testsPassed),
			"tests_failed": JSONValue(testsFailed),
			"compilation_errors": JSONValue(errors.data),
			"compilation_warnings": JSONValue(warnings.data),
			"test_failures": JSONValue(testFailures.data),
			"output": JSONValue(fullOutput),
		]);

		return createTextResult(resp.toString());
	}

	/**
     * Parse assertion failure lines like:
     * core.exception.AssertError@source/file.d(42): assertion message
     */
	JSONValue parseTestFailure(string line)
	{
		import std.regex : regex, matchFirst;

		auto re = regex(`AssertError@(.+?)\((\d+)\)(?::\s*(.*))?`);
		auto m = matchFirst(line, re);

		if(m.empty) {
			// Try a more generic pattern
			auto re2 = regex(
					`([Aa]ssertion [Ff]ailure|AssertError).*?(?:@(.+?)\((\d+)\))?(?::\s*(.*))?`);
			auto m2 = matchFirst(line, re2);
			if(m2.empty)
				return JSONValue(null);

			auto entry = JSONValue(string[string].init);
			if(m2[2].length > 0)
				entry["file"] = JSONValue(m2[2].idup);
			if(m2[3].length > 0) {
				try {
					entry["line"] = JSONValue(m2[3].to!int);
				} catch(Exception) {
				}
			}
			string msg = m2[4].length > 0 ? m2[4].idup : line.strip();
			entry["message"] = JSONValue(msg);
			return entry;
		}

		auto entry = JSONValue(string[string].init);
		entry["file"] = JSONValue(m[1].idup);
		entry["line"] = JSONValue(m[2].to!int);
		string msg = m[3].length > 0 ? m[3].idup.strip() : "assertion failure";
		entry["message"] = JSONValue(msg);

		return entry;
	}
}
