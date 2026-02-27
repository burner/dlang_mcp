/**
 * Security-focused unit tests for MCP tools.
 *
 * Tests argument injection prevention, input validation,
 * JSON type confusion, MCP error result format, temp file cleanup,
 * missing database handling, compiler validation, and process timeout.
 */
module utils.security_tests;

version(unittest)  : import std.json;
import std.algorithm.searching : canFind;
import std.file : exists, tempDir, dirEntries, SpanMode;
import std.string : startsWith;
import mcp.types : ToolResult, Content;
import tools.compile_check : CompileCheckTool;
import tools.outline : ModuleOutlineTool;
import tools.dscanner : DscannerTool;
import tools.dfmt : DfmtTool;
import tools.fetch_package : FetchPackageTool;
import tools.run_project : RunProjectTool;
import tools.package_search : PackageSearchTool;
import tools.base : BaseTool;
import mcp.server : MCPServer;
import test_helpers : ThrowingTool;

// ============================================================
// Helper functions
// ============================================================

/// Counts dcheck_*.d files in temp directory
private int countTempFiles()
{
	int count = 0;
	try {
		foreach(entry; dirEntries(tempDir, SpanMode.shallow)) {
			import std.path : baseName;

			auto name = baseName(entry.name);
			if(name.startsWith("dcheck_") && name.canFind(".d"))
				count++;
		}
	} catch(Exception) {
		// Ignore errors reading temp dir
	}
	return count;
}

/// Counts dscanner temp files in temp directory
private int countDscannerTempFiles()
{
	int count = 0;
	try {
		foreach(entry; dirEntries(tempDir, SpanMode.shallow)) {
			import std.path : baseName;

			auto name = baseName(entry.name);
			if(name.startsWith("dscanner_") && name.canFind(".d"))
				count++;
		}
	} catch(Exception) {
		// Ignore errors reading temp dir
	}
	return count;
}

// ============================================================
// Path Traversal Prevention
// ============================================================

/// testOutlinePathTraversalRelative
unittest {
	auto tool = new ModuleOutlineTool();
	auto args = parseJSON(`{"file_path": "../../etc/passwd"}`);
	auto result = tool.execute(args);
	// Should return an error (file not found or not a .d file)
	// The tool tries absolutePath("../../etc/passwd") and checks exists()
	assert(result.content.length > 0, "Should return content");
}

/// testOutlinePathTraversalAbsolute
unittest {
	auto tool = new ModuleOutlineTool();
	auto args = parseJSON(`{"file_path": "/etc/passwd"}`);
	auto result = tool.execute(args);
	// /etc/passwd exists but is not a .d file — dscanner will fail to parse it
	assert(result.content.length > 0, "Should return content without crashing");
}

/// testCompileCheckPathTraversal
unittest {
	auto tool = new CompileCheckTool();
	auto args = parseJSON(`{"file_path": "/etc/shadow"}`);
	auto result = tool.execute(args);
	// /etc/shadow is not readable or is not a .d file — should fail gracefully
	assert(result.content.length > 0, "Should return content without crashing");
}

/// testCompileCheckDubProjectTraversal
unittest {
	auto tool = new CompileCheckTool();
	auto args = parseJSON(`{"code": "void main(){}", "dub_project": "/etc"}`);
	auto result = tool.execute(args);
	// /etc is not a dub project — dub describe will fail, tool handles gracefully
	assert(result.content.length > 0, "Should return content without crashing");
}

/// testDscannerConfigPathTraversal
unittest {
	auto tool = new DscannerTool();
	auto args = parseJSON(`{"code": "void main(){}", "config": "/etc/passwd"}`);
	auto result = tool.execute(args);
	// /etc/passwd is not a valid dscanner config — dscanner handles it
	assert(result.content.length > 0, "Should return content without crashing");
}

// ============================================================
// Argument Injection Prevention
// ============================================================

/// testCompileCheckImportPathInjection
unittest {
	auto tool = new CompileCheckTool();
	auto args = parseJSON(`{"code": "void main(){}", "import_paths": ["--help"]}`);
	auto result = tool.execute(args);
	// D's std.process uses array-based execution, so "--help" becomes "-I--help"
	// which is a single argument. Should not interpret --help as a separate flag.
	assert(result.content.length > 0, "Should return content without crashing");
}

/// testCompileCheckVersionInjection
unittest {
	auto tool = new CompileCheckTool();
	auto args = parseJSON(`{"code": "void main(){}", "versions": ["; rm -rf /"]}`);
	auto result = tool.execute(args);
	// Passed as "-version=; rm -rf /" - a single argument
	// Should not execute shell commands due to array-based execution
	assert(result.content.length > 0, "Should return content without crashing");
}

/// testFetchPackageNameInjection
unittest {
	auto tool = new FetchPackageTool();
	auto args = parseJSON(`{"package_name": "--help"}`);
	auto result = tool.execute(args);
	// "dub fetch --help" will show help text or error, not crash
	assert(result.content.length > 0, "Should return content without crashing");
}

/// testFetchPackageNameWithSpaces
unittest {
	auto tool = new FetchPackageTool();
	auto args = parseJSON(`{"package_name": "foo bar baz"}`);
	auto result = tool.execute(args);
	// Should not split into multiple arguments. dub receives "foo bar baz"
	// as a single argument and returns an error.
	assert(result.content.length > 0, "Should return content without crashing");
}

/// testRunProjectArgsInjection
unittest {
	auto tool = new RunProjectTool();
	auto args = parseJSON(`{"project_path": "/nonexistent", "args": ["--root=/etc", "--force"]}`);
	auto result = tool.execute(args);
	// These args go after "--" separator, so dub passes them to the program
	// (not to dub itself). The project path doesn't exist so it will fail at build.
	assert(result.content.length > 0, "Should return content without crashing");
}

/// testCompileCheckCompilerValidation
unittest {
	auto tool = new CompileCheckTool();
	auto args = parseJSON(`{"code": "void main(){}", "compiler": "/usr/bin/evil"}`);
	auto result = tool.execute(args);
	assert(result.isError, "Should return error for invalid compiler");
	assert(result.content[0].text.canFind("dmd")
			|| result.content[0].text.canFind("ldc2"), "Error should mention valid compilers");
}

/// testCompileCheckCompilerValidation2
unittest {
	auto tool = new CompileCheckTool();
	auto args = parseJSON(`{"code": "void main(){}", "compiler": "dmd; echo pwned"}`);
	auto result = tool.execute(args);
	assert(result.isError, "Should return error for injected compiler string");
}

// ============================================================
// Input Validation and Edge Cases
// ============================================================

/// testCompileCheckEmptyCode
unittest {
	auto tool = new CompileCheckTool();
	auto args = parseJSON(`{"code": ""}`);
	auto result = tool.execute(args);
	// Empty code compiles or gives a warning, should not crash
	assert(result.content.length > 0, "Should return content for empty code");
}

/// testCompileCheckBothCodeAndFile
unittest {
	auto tool = new CompileCheckTool();
	auto args = parseJSON(`{"code": "void main(){}", "file_path": "/tmp/nonexistent_x.d"}`);
	auto result = tool.execute(args);
	// file_path is checked first (hasFile); since the file doesn't exist, it errors
	assert(result.content.length > 0, "Should return content without crashing");
}

/// testOutlineEmptyCode
unittest {
	auto tool = new ModuleOutlineTool();
	auto args = parseJSON(`{"code": ""}`);
	auto result = tool.execute(args);
	// Empty code produces empty outline, should not crash
	assert(result.content.length > 0, "Should return content for empty code");
}

/// testOutlineNoParams
unittest {
	auto tool = new ModuleOutlineTool();
	auto args = parseJSON(`{}`);
	auto result = tool.execute(args);
	assert(result.isError, "Should return error with no params");
	assert(result.content[0].text.canFind("file_path")
			|| result.content[0].text.canFind("code"), "Error should mention required parameters");
}

/// testCompileCheckNoParams
unittest {
	auto tool = new CompileCheckTool();
	auto args = parseJSON(`{}`);
	auto result = tool.execute(args);
	assert(result.isError, "Should return error with no params");
	assert(result.content[0].text.canFind("code")
			|| result.content[0].text.canFind("file_path"),
			"Error should mention required parameters");
}

/// testFetchPackageEmptyString
unittest {
	auto tool = new FetchPackageTool();
	auto args = parseJSON(`{"package_name": ""}`);
	auto result = tool.execute(args);
	assert(result.isError, "Should return error for empty package name");
	assert(result.content[0].text.canFind("package_name"), "Error should mention package_name");
}

/// testFetchPackageWhitespace
unittest {
	auto tool = new FetchPackageTool();
	auto args = parseJSON(`{"package_name": "   "}`);
	auto result = tool.execute(args);
	assert(result.isError, "Should return error for whitespace-only package name");
}

/// testDscannerEmptyCode
unittest {
	auto tool = new DscannerTool();
	auto args = parseJSON(`{"code": ""}`);
	auto result = tool.execute(args);
	// Empty code should not crash
	assert(result.content.length > 0, "Should return content for empty code");
}

/// testDscannerNoCodeNoFile
unittest {
	auto tool = new DscannerTool();
	auto args = parseJSON(`{}`);
	auto result = tool.execute(args);
	assert(result.isError, "Should return error with no code/file_path");
}

/// testDfmtEmptyCode
unittest {
	auto tool = new DfmtTool();
	auto args = parseJSON(`{"code": ""}`);
	auto result = tool.execute(args);
	// Empty code should not crash
	assert(result.content.length > 0, "Should return content for empty code");
}

// ============================================================
// JSON Type Confusion
// ============================================================

/// testCompileCheckCodeAsInt
unittest {
	auto tool = new CompileCheckTool();
	auto args = parseJSON(`{"code": 42}`);
	auto result = tool.execute(args);
	// "code" has wrong type (integer, not string). The hasCode check uses
	// type == JSONType.string, so it won't see the code field.
	// Should fall through to "Either code or file_path required" error.
	assert(result.isError, "Should return error for non-string code");
}

/// testFetchPackageNameAsArray
unittest {
	auto tool = new FetchPackageTool();
	auto args = parseJSON(`{"package_name": ["a","b"]}`);
	auto result = tool.execute(args);
	// Type check: arguments["package_name"].type != JSONType.string
	assert(result.isError, "Should return error for array-type package_name");
}

/// testRunProjectPathAsInt
unittest {
	import std.file : getcwd, chdir, mkdir, rmdirRecurse;
	import std.exception : collectException;
	import std.path : buildPath;
	import std.process : thisProcessID;
	import std.conv : to;

	// Run from a temp dir with no dub.json so dub run fails fast
	// instead of launching the MCP server (which blocks on stdin)
	string tmpDir = buildPath(tempDir(), "dlang_mcp_test_run_" ~ to!string(thisProcessID));
	if(!exists(tmpDir))
		mkdir(tmpDir);

	string origDir = getcwd();
	chdir(tmpDir);
	scope(exit)
		chdir(origDir);
	scope(exit)
		collectException(rmdirRecurse(tmpDir));

	auto tool = new RunProjectTool();
	auto args = parseJSON(`{"project_path": 999}`);
	auto result = tool.execute(args);
	// Type check skips non-string, uses default "." path
	// In temp dir with no dub.json, dub run fails fast
	assert(result.content.length > 0, "Should return content without crashing");
}

/// testCompileCheckImportPathsAsString
unittest {
	auto tool = new CompileCheckTool();
	auto args = parseJSON(`{"code": "void main(){}", "import_paths": "not-an-array"}`);
	auto result = tool.execute(args);
	// import_paths type check requires array, so string is skipped
	assert(result.content.length > 0, "Should return content without crashing");
}

// ============================================================
// Tool Error Result Format (MCP Spec Compliance)
// ============================================================

/// testToolErrorIsNotJsonRpcError
unittest {
	import std.logger : globalLogLevel, LogLevel;

	auto savedLevel = globalLogLevel;
	globalLogLevel = LogLevel.off;
	scope(exit)
		globalLogLevel = savedLevel;

	// A tool that throws during execute() should produce a successful
	// JSON-RPC response with isError: true in the result, NOT a JSON-RPC error.
	auto server = new MCPServer();

	// Use a helper class that throws
	server.registerTool(new ThrowingTool());
	server.handleInitialize(JSONValue(1), JSONValue(cast(string[string])null));

	auto params = parseJSON(`{"name":"throwing_tool","arguments":{}}`);
	auto resp = server.handleToolsCall(JSONValue(2), params);

	// Should be a successful JSON-RPC response (no error field)
	assert(resp.error.type == JSONType.null_, "Tool failure should NOT produce JSON-RPC error");

	// Result should have isError: true
	assert(resp.result["isError"].type == JSONType.true_, "Tool result should have isError: true");

	// Content should contain the exception message
	auto content = resp.result["content"].array;
	assert(content.length > 0, "Should have error content");
	assert(content[0]["text"].str.canFind("test throw"), "Content should contain exception message");
}

// ============================================================
// Temp File Cleanup
// ============================================================

/// testCompileCheckTempFileCleanup
unittest {
	auto tool = new CompileCheckTool();
	auto args = parseJSON(`{"code": "void main(){}"}`);

	// Count dcheck_ files before
	int before = countTempFiles();

	auto result = tool.execute(args);

	// Count dcheck_ files after
	int after = countTempFiles();

	assert(after <= before, "No new dcheck_ temp files should remain after execution");
}

/// testDscannerTempFileCleanup
unittest {
	auto tool = new DscannerTool();
	auto args = parseJSON(`{"code": "void main(){}", "mode": "lint"}`);

	// Count dscanner temp files before
	int before = countDscannerTempFiles();

	auto result = tool.execute(args);

	// Count dscanner temp files after
	int after = countDscannerTempFiles();

	assert(after <= before, "No new dscanner temp files should remain");
}

// ============================================================
// Search Tool Database Missing
// ============================================================

/// testSearchToolMissingDB
unittest {
	import std.file : getcwd, chdir, mkdir, rmdirRecurse;
	import std.exception : collectException;
	import std.path : buildPath;
	import std.process : thisProcessID;
	import std.conv : to;

	// Create a unique temp directory where data/search.db won't exist
	string tmpDir = buildPath(tempDir(), "dlang_mcp_test_" ~ to!string(thisProcessID));
	if(!exists(tmpDir))
		mkdir(tmpDir);

	// Save current directory and switch to temp dir
	string origDir = getcwd();
	chdir(tmpDir);

	scope(exit)
		chdir(origDir);
	scope(exit)
		collectException(rmdirRecurse(tmpDir));

	auto tool = new PackageSearchTool();
	auto args = parseJSON(`{"query": "test"}`);
	auto result = tool.execute(args);
	// Without data/search.db, should return an error, not crash
	assert(result.isError, "Should return error when database is missing");
	assert(result.content[0].text.canFind("database")
			|| result.content[0].text.canFind("Search") || result.content[0].text.canFind("search"),
			"Error should mention the search database");
}

// ============================================================
// Compiler Validation
// ============================================================

/// testBuildProjectRejectsInvalidCompiler
unittest {
	import tools.build_project : BuildProjectTool;

	auto tool = new BuildProjectTool();
	auto args = parseJSON(`{"compiler": "evil"}`);
	auto result = tool.execute(args);
	assert(result.isError, "BuildProject should reject invalid compiler");
	assert(result.content[0].text.canFind("dmd")
			|| result.content[0].text.canFind("ldc2"), "Error should mention valid compilers");
}

/// testRunProjectRejectsInvalidCompiler
unittest {
	import std.file : getcwd, chdir, mkdir, rmdirRecurse;
	import std.exception : collectException;
	import std.path : buildPath;
	import std.process : thisProcessID;
	import std.conv : to;

	// Use temp dir to avoid launching the actual MCP server
	string tmpDir = buildPath(tempDir(), "dlang_mcp_test_runproj_" ~ to!string(thisProcessID));
	if(!exists(tmpDir))
		mkdir(tmpDir);

	string origDir = getcwd();
	chdir(tmpDir);
	scope(exit)
		chdir(origDir);
	scope(exit)
		collectException(rmdirRecurse(tmpDir));

	auto tool = new RunProjectTool();
	auto args = parseJSON(`{"compiler": "/bin/sh"}`);
	auto result = tool.execute(args);
	assert(result.isError, "RunProject should reject invalid compiler");
}

/// testRunTestsRejectsInvalidCompiler
unittest {
	import tools.run_tests : RunTestsTool;

	auto tool = new RunTestsTool();
	auto args = parseJSON(`{"compiler": "gcc"}`);
	auto result = tool.execute(args);
	assert(result.isError, "RunTests should reject invalid compiler");
}

/// testValidateCompilerAcceptsDmd
unittest {
	import utils.security : validateCompiler;

	string result = validateCompiler("dmd");
	assert(result == "dmd", "validateCompiler should accept 'dmd'");
}

/// testValidateCompilerAcceptsLdc2
unittest {
	import utils.security : validateCompiler;

	string result = validateCompiler("ldc2");
	assert(result == "ldc2", "validateCompiler should accept 'ldc2'");
}

/// testValidateCompilerAcceptsGdc
unittest {
	import utils.security : validateCompiler;

	string result = validateCompiler("gdc");
	assert(result == "gdc", "validateCompiler should accept 'gdc'");
}

// ============================================================
// Process Timeout
// ============================================================

/// testProcessTimeoutKillsHungProcess
unittest {
	import utils.process : executeCommand, ProcessTimeoutException, setProcessTimeout;
	import core.time : dur;

	// Save original timeout and set a short one
	setProcessTimeout(dur!"seconds"(1));
	scope(exit)
		setProcessTimeout(dur!"seconds"(30));

	bool timedOut = false;
	try {
		executeCommand(["sleep", "999"]);
	} catch(ProcessTimeoutException) {
		timedOut = true;
	}
	assert(timedOut, "Should throw ProcessTimeoutException for hung process");
}

/// testProcessTimeoutAllowsFastProcess
unittest {
	import utils.process : executeCommand;

	// A fast process should complete without timeout
	auto result = executeCommand(["echo", "hello"]);
	assert(result.status == 0, "Fast process should succeed");
	assert(result.output.canFind("hello"), "Output should contain 'hello'");
}
