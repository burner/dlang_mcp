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

// -- Unit Tests --

/// RunTestsTool has correct name
unittest {
	auto tool = new RunTestsTool();
	assert(tool.name == "run_tests", "Expected name 'run_tests', got: " ~ tool.name);
}

/// RunTestsTool has non-empty description
unittest {
	auto tool = new RunTestsTool();
	assert(tool.description.length > 0, "Description should not be empty");
}

/// RunTestsTool schema has expected properties
unittest {
	import std.format : format;

	auto tool = new RunTestsTool();
	auto schema = tool.inputSchema;
	assert(schema["type"].str == "object", "Schema type should be 'object'");
	auto props = schema["properties"];
	assert("project_path" in props, "Schema should have project_path");
	assert("compiler" in props, "Schema should have compiler");
	assert("configuration" in props, "Schema should have configuration");
	assert("verbose" in props, "Schema should have verbose");
	assert("filter" in props, "Schema should have filter");
}

/// parseTestFailure with standard AssertError format
unittest {
	import std.format : format;

	auto tool = new RunTestsTool();
	auto result = tool.parseTestFailure(
			"core.exception.AssertError@source/file.d(42): assertion message");
	assert(result.type != JSONType.null_, "Should parse standard AssertError");
	assert(result["file"].str == "source/file.d",
			"Expected file 'source/file.d', got: " ~ result["file"].str);
	assert(result["line"].integer == 42,
			format!"Expected line 42, got: %s"(result["line"].integer));
	assert(result["message"].str == "assertion message",
			"Expected 'assertion message', got: " ~ result["message"].str);
}

/// parseTestFailure with no message after AssertError
unittest {
	auto tool = new RunTestsTool();
	auto result = tool.parseTestFailure("core.exception.AssertError@source/foo.d(10)");
	assert(result.type != JSONType.null_, "Should parse AssertError without message");
	assert(result["file"].str == "source/foo.d");
	assert(result["line"].integer == 10);
	assert(result["message"].str == "assertion failure",
			"Expected default message 'assertion failure', got: " ~ result["message"].str);
}

/// parseTestFailure with assertion failure text (generic pattern)
unittest {
	auto tool = new RunTestsTool();
	auto result = tool.parseTestFailure("Assertion failure in some test");
	assert(result.type != JSONType.null_, "Should parse generic assertion failure");
	assert("message" in result, "Should have message field");
}

/// parseTestFailure with assertion failure and file location
unittest {
	auto tool = new RunTestsTool();
	auto result = tool.parseTestFailure("assertion failure@source/bar.d(99): expected 5 got 3");
	// This should match the generic pattern since it doesn't start with AssertError@
	assert(result.type != JSONType.null_, "Should parse assertion failure with location");
}

/// parseTestFailure with non-matching line returns null
unittest {
	auto tool = new RunTestsTool();
	auto result = tool.parseTestFailure("Building dlang_mcp ~master...");
	assert(result.type == JSONType.null_, "Non-assertion line should return null");
}

/// parseTestFailure with empty string returns null
unittest {
	auto tool = new RunTestsTool();
	auto result = tool.parseTestFailure("");
	assert(result.type == JSONType.null_, "Empty string should return null");
}

/// parseTestFailure with AssertError containing path with spaces
unittest {
	auto tool = new RunTestsTool();
	auto result = tool.parseTestFailure(
			"core.exception.AssertError@source/my module.d(7): bad value");
	assert(result.type != JSONType.null_, "Should parse path with spaces");
	assert(result["file"].str == "source/my module.d");
	assert(result["line"].integer == 7);
	assert(result["message"].str == "bad value");
}

/// formatTestResult with successful test run (all modules passed)
unittest {
	import std.format : format;
	import utils.process : ProcessResult;

	auto tool = new RunTestsTool();
	ProcessResult pr;
	pr.status = 0;
	pr.output = "Running tests...\n42 modules passed unittests";
	pr.stderrOutput = "";

	auto result = tool.formatTestResult(pr);
	assert(!result.isError, "Successful test run should not be an error");
	assert(result.content.length > 0, "Should have content");

	auto json = parseJSON(result.content[0].text);
	assert(json["success"].type == JSONType.true_, "success should be true");
	assert(json["tests_passed"].integer == 42,
			format("Expected 42 tests passed, got: %s", json["tests_passed"].integer));
	assert(json["tests_run"].integer == 42,
			format("Expected 42 tests run, got: %s", json["tests_run"].integer));
	assert(json["tests_failed"].integer == 0,
			format("Expected 0 tests failed, got: %s", json["tests_failed"].integer));
}

/// formatTestResult with failed test run (modules FAILED)
unittest {
	import std.format : format;
	import utils.process : ProcessResult;

	auto tool = new RunTestsTool();
	ProcessResult pr;
	pr.status = 1;
	pr.output = "2/10 modules FAILED unittests";
	pr.stderrOutput = "";

	auto result = tool.formatTestResult(pr);
	assert(!result.isError, "formatTestResult wraps in text result, not error result");

	auto json = parseJSON(result.content[0].text);
	assert(json["success"].type == JSONType.false_, "success should be false for failed tests");
	assert(json["tests_failed"].integer == 2,
			format("Expected 2 failed, got: %s", json["tests_failed"].integer));
	assert(json["tests_run"].integer == 10, format("Expected 10 run, got: %s",
			json["tests_run"].integer));
	// testsPassed should be calculated: 10 - 2 = 8
	assert(json["tests_passed"].integer == 8,
			format("Expected 8 passed, got: %s", json["tests_passed"].integer));
}

/// formatTestResult with compilation errors
unittest {
	import std.format : format;
	import utils.process : ProcessResult;

	auto tool = new RunTestsTool();
	ProcessResult pr;
	pr.status = 1;
	pr.output = "";
	pr.stderrOutput = "source/app.d(10): Error: undefined identifier 'foo'";

	auto result = tool.formatTestResult(pr);
	auto json = parseJSON(result.content[0].text);
	assert(json["success"].type == JSONType.false_,
			"success should be false for compilation failure");
	assert(json["phase"].str == "compilation",
			"Phase should be 'compilation' when there are errors, got: " ~ json["phase"].str);
	assert(json["compilation_errors"].array.length == 1,
			format("Expected 1 compilation error, got: %s", json["compilation_errors"].array.length));
}

/// formatTestResult with compilation warnings
unittest {
	import std.format : format;
	import utils.process : ProcessResult;

	auto tool = new RunTestsTool();
	ProcessResult pr;
	pr.status = 0;
	pr.output = "source/app.d(5,3): Warning: implicit conversion\n10 modules passed unittests";
	pr.stderrOutput = "";

	auto result = tool.formatTestResult(pr);
	auto json = parseJSON(result.content[0].text);
	assert(json["success"].type == JSONType.true_);
	assert(json["compilation_warnings"].array.length == 1,
			format("Expected 1 warning, got: %s", json["compilation_warnings"].array.length));
}

/// formatTestResult with AssertError in output
unittest {
	import std.format : format;
	import utils.process : ProcessResult;

	auto tool = new RunTestsTool();
	ProcessResult pr;
	pr.status = 1;
	pr.output
		= "core.exception.AssertError@source/test.d(42): expected 5 got 3\n1/5 modules FAILED unittests";
	pr.stderrOutput = "";

	auto result = tool.formatTestResult(pr);
	auto json = parseJSON(result.content[0].text);
	assert(json["test_failures"].array.length == 1,
			format("Expected 1 test failure, got: %s", json["test_failures"].array.length));
	auto failure = json["test_failures"].array[0];
	assert(failure["file"].str == "source/test.d");
	assert(failure["line"].integer == 42);
}

/// formatTestResult with empty output (no tests)
unittest {
	import utils.process : ProcessResult;

	auto tool = new RunTestsTool();
	ProcessResult pr;
	pr.status = 0;
	pr.output = "";
	pr.stderrOutput = "";

	auto result = tool.formatTestResult(pr);
	auto json = parseJSON(result.content[0].text);
	assert(json["success"].type == JSONType.true_);
	assert(json["tests_run"].integer == 0);
	assert(json["tests_passed"].integer == 0);
	assert(json["tests_failed"].integer == 0);
}

/// formatTestResult phase detection (test phase when no compilation errors)
unittest {
	import utils.process : ProcessResult;

	auto tool = new RunTestsTool();
	ProcessResult pr;
	pr.status = 1;
	pr.output = "1/5 modules FAILED unittests";
	pr.stderrOutput = "";

	auto result = tool.formatTestResult(pr);
	auto json = parseJSON(result.content[0].text);
	assert(json["phase"].str == "test",
			"Phase should be 'test' when no compilation errors, got: " ~ json["phase"].str);
}

/// formatTestResult with multiple AssertErrors
unittest {
	import std.format : format;
	import utils.process : ProcessResult;

	auto tool = new RunTestsTool();
	ProcessResult pr;
	pr.status = 1;
	pr.output = "core.exception.AssertError@source/a.d(10): first failure\n"
		~ "core.exception.AssertError@source/b.d(20): second failure\n"
		~ "2/5 modules FAILED unittests";
	pr.stderrOutput = "";

	auto result = tool.formatTestResult(pr);
	auto json = parseJSON(result.content[0].text);
	assert(json["test_failures"].array.length == 2,
			format("Expected 2 test failures, got: %s", json["test_failures"].array.length));
}

/// formatTestResult with Running line triggers test phase detection
unittest {
	import utils.process : ProcessResult;

	auto tool = new RunTestsTool();
	ProcessResult pr;
	pr.status = 0;
	pr.output = "Running ./test-runner\n5 modules passed unittests";
	pr.stderrOutput = "";

	auto result = tool.formatTestResult(pr);
	auto json = parseJSON(result.content[0].text);
	assert(json["tests_passed"].integer == 5);
}

/// formatTestResult preserves full output in response
unittest {
	import std.algorithm.searching : canFind;
	import utils.process : ProcessResult;

	auto tool = new RunTestsTool();
	ProcessResult pr;
	pr.status = 0;
	pr.output = "some output here";
	pr.stderrOutput = "some stderr";

	auto result = tool.formatTestResult(pr);
	auto json = parseJSON(result.content[0].text);
	assert(json["output"].str.canFind("some output here"), "Output should contain stdout");
	assert(json["output"].str.canFind("some stderr"), "Output should contain stderr");
}

/// formatTestResult with mixed compilation errors and test failures
unittest {
	import std.format : format;
	import utils.process : ProcessResult;

	auto tool = new RunTestsTool();
	ProcessResult pr;
	pr.status = 1;
	pr.output = "source/app.d(5): Error: syntax error\n"
		~ "core.exception.AssertError@source/test.d(15): bad assert";
	pr.stderrOutput = "";

	auto result = tool.formatTestResult(pr);
	auto json = parseJSON(result.content[0].text);
	assert(json["compilation_errors"].array.length == 1,
			format("Expected 1 compilation error, got: %s", json["compilation_errors"].array.length));
	assert(json["test_failures"].array.length == 1,
			format("Expected 1 test failure, got: %s", json["test_failures"].array.length));
}

/// formatTestResult only passed count sets testsRun to same value
unittest {
	import std.format : format;
	import utils.process : ProcessResult;

	auto tool = new RunTestsTool();
	ProcessResult pr;
	pr.status = 0;
	pr.output = "15 modules passed unittests";
	pr.stderrOutput = "";

	auto result = tool.formatTestResult(pr);
	auto json = parseJSON(result.content[0].text);
	// When only passed count is available, testsRun should equal testsPassed
	assert(json["tests_run"].integer == 15,
			format("Expected tests_run=15, got: %s", json["tests_run"].integer));
	assert(json["tests_passed"].integer == 15,
			format("Expected tests_passed=15, got: %s", json["tests_passed"].integer));
}

/// parseTestFailure with AssertError@ containing colon but no message text
unittest {
	auto tool = new RunTestsTool();
	auto result = tool.parseTestFailure("core.exception.AssertError@source/x.d(1):");
	assert(result.type != JSONType.null_, "Should parse AssertError with trailing colon");
	assert(result["file"].str == "source/x.d");
	assert(result["line"].integer == 1);
}

/// parseTestFailure with generic 'assertion failure' (lowercase)
unittest {
	auto tool = new RunTestsTool();
	auto result = tool.parseTestFailure("assertion failure in module foo");
	assert(result.type != JSONType.null_, "Should match lowercase 'assertion failure'");
}
