/**
 * MCP tool for analyzing D code coverage from `.lst` files.
 *
 * Parses coverage files produced by `dmd -cov` or `ldc2 --cov`,
 * identifies functions with uncovered lines, and reports per-function
 * coverage statistics sorted by number of uncovered lines.
 */
module tools.coverage_analysis;

import std.json : JSONValue, JSONType;
import tools.base : BaseTool;
import mcp.types : ToolResult;

class CoverageAnalysisTool : BaseTool {
	override @property string name()
	{
		return "coverage_analysis";
	}

	override @property string description()
	{
		return "Analyze D code coverage from .lst files produced by dmd -cov or ldc2 --cov. Use when "
			~ "asked 'what code isn't tested?', 'show coverage gaps', or 'which functions need more "
			~ "tests?'. Returns per-function coverage statistics sorted by most uncovered lines first. "
			~ "Provide a single .lst file or a directory to scan all .lst files. Run run_tests with "
			~ "coverage flags first to generate .lst files.";
	}

	override @property JSONValue inputSchema()
	{
		return JSONValue([
			"type": JSONValue("object"),
			"properties": JSONValue([
				"file_path": JSONValue([
					"type": JSONValue("string"),
					"description": JSONValue(
							"Path to a single .lst coverage file (e.g., 'source-app.lst'). Use for analyzing one module.")
				]),
				"directory": JSONValue([
					"type": JSONValue("string"),
					"description": JSONValue(
							"Directory to scan for all .lst files (e.g., '.'). Use for project-wide coverage analysis.")
				]),
				"min_uncovered": JSONValue([
					"type": JSONValue("integer"),
					"description": JSONValue("Minimum uncovered lines to include a function in results (default: 1). Increase to focus on biggest gaps."),
					"default": JSONValue(1)
				])
			])
		]);
	}

	override ToolResult execute(JSONValue arguments)
	{
		import std.file : readText, dirEntries, SpanMode, exists, isDir, isFile;
		import std.algorithm : sort;
		import std.array : array, appender;

		bool hasFile = "file_path" in arguments && arguments["file_path"].type == JSONType.string;
		bool hasDir = "directory" in arguments && arguments["directory"].type == JSONType.string;

		if(!hasFile && !hasDir)
			return createErrorResult("Either 'file_path' or 'directory' must be provided.");

		if(hasFile && hasDir)
			return createErrorResult("Provide either 'file_path' or 'directory', not both.");

		int minUncoveredRaw = 1;
		if("min_uncovered" in arguments && arguments["min_uncovered"].type == JSONType.integer)
			minUncoveredRaw = arguments["min_uncovered"].get!int;
		size_t minUncovered = minUncoveredRaw > 0 ? cast(size_t)minUncoveredRaw : 0;

		string[] lstFiles;

		if(hasFile) {
			string fp = arguments["file_path"].str;
			if(!exists(fp))
				return createErrorResult("File not found: " ~ fp);
			if(!isFile(fp))
				return createErrorResult("Not a file: " ~ fp);
			lstFiles ~= fp;
		}

		if(hasDir) {
			string dir = arguments["directory"].str;
			if(!exists(dir))
				return createErrorResult("Directory not found: " ~ dir);
			if(!isDir(dir))
				return createErrorResult("Not a directory: " ~ dir);

			import std.path : baseName;

			foreach(entry; dirEntries(dir, "*.lst", SpanMode.shallow)) {
				auto base = baseName(entry.name);
				// Skip dependency library .lst files (their names start with ".."
				// because dmd/ldc encodes relative paths like ../../.dub/packages/...
				// as ..-..-..-.dub-packages-... in the .lst filename).
				if(base.length >= 2 && base[0 .. 2] == "..")
					continue;
				lstFiles ~= entry.name;
			}

			if(lstFiles.length == 0)
				return createErrorResult("No .lst files found in: " ~ dir);
		}

		auto results = appender!(JSONValue[]);

		foreach(lstPath; lstFiles) {
			try {
				auto fileResult = analyzeFile(lstPath, minUncovered);
				if(fileResult.type != JSONType.null_)
					results ~= fileResult;
			} catch(Exception e) {
				results ~= JSONValue([
					"file": JSONValue(lstPath),
					"error": JSONValue("Failed to analyze: " ~ e.msg)
				]);
			}
		}

		auto resp = JSONValue([
			"files_analyzed": JSONValue(lstFiles.length),
			"results": JSONValue(results[])
		]);

		return createTextResult(resp.toPrettyString());
	}

	private JSONValue analyzeFile(string lstPath, size_t minUncovered)
	{
		import std.file : readText;
		import std.algorithm : sort;
		import std.array : array, appender;
		import std.math : round;
		import utils.coverage_parser : parseLstContent;
		import utils.function_range_visitor : extractFunctionRanges, FunctionRange;

		string content = readText(lstPath);
		auto coverage = parseLstContent(content, lstPath);

		if(coverage.lines.length == 0)
			return JSONValue(null);

		FunctionRange[] funcRanges;
		try
			funcRanges = extractFunctionRanges(coverage.reconstructedSource,
					coverage.sourceFileName);
		catch(Exception e)
			return JSONValue([
			"file": JSONValue(lstPath),
			"source_file": JSONValue(coverage.sourceFileName),
			"error": JSONValue("Failed to parse source: " ~ e.msg)
		]);

		auto funcResults = appender!(JSONValue[]);

		foreach(ref fr; funcRanges) {
			if(fr.kind == "unittest")
				continue;

			size_t executableLines = 0;
			size_t uncoveredLines = 0;

			foreach(lineIdx; fr.startLine - 1 .. fr.endLine) {
				if(lineIdx >= coverage.lines.length)
					break;
				auto line = coverage.lines[lineIdx];
				if(line.isExecutable) {
					executableLines++;
					if(!line.isCovered)
						uncoveredLines++;
				}
			}

			if(uncoveredLines < minUncovered)
				continue;

			double coveragePct = executableLines > 0 ? (
					cast(double)(executableLines - uncoveredLines) / executableLines) * 100.0
				: 100.0;

			auto funcJson = JSONValue([
				"name": JSONValue(fr.name),
				"start_line": JSONValue(fr.startLine),
				"end_line": JSONValue(fr.endLine),
				"executable_lines": JSONValue(executableLines),
				"uncovered_lines": JSONValue(uncoveredLines),
				"coverage_pct": JSONValue(round(coveragePct * 10.0) / 10.0)
			]);

			if(fr.parentName.length > 0)
				funcJson["parent"] = JSONValue(fr.parentName);

			funcResults ~= funcJson;
		}

		// Sort by uncovered_lines descending
		auto sorted = funcResults[].array;
		sorted.sort!((a, b) => a["uncovered_lines"].get!long > b["uncovered_lines"].get!long);

		double fileCoveragePct = coverage.executableCount() > 0
			? (cast(double)coverage.coveredCount() / coverage.executableCount()) * 100.0 : 100.0;

		return JSONValue([
			"file": JSONValue(lstPath),
			"source_file": JSONValue(coverage.sourceFileName),
			"total_lines": JSONValue(coverage.lines.length),
			"executable_lines": JSONValue(coverage.executableCount()),
			"covered_lines": JSONValue(coverage.coveredCount()),
			"uncovered_lines": JSONValue(coverage.uncoveredCount()),
			"file_coverage_pct": JSONValue(round(fileCoveragePct * 10.0) / 10.0),
			"functions": JSONValue(sorted)
		]);
	}
}

unittest {
	// Test: tool metadata
	auto tool = new CoverageAnalysisTool();
	assert(tool.name == "coverage_analysis");
	assert(tool.description.length > 0);

	auto schema = tool.inputSchema;
	assert("properties" in schema);
	assert("file_path" in schema["properties"]);
	assert("directory" in schema["properties"]);
	assert("min_uncovered" in schema["properties"]);
}

unittest {
	// Test: missing arguments returns error
	auto tool = new CoverageAnalysisTool();
	auto result = tool.execute(JSONValue(["foo": JSONValue("bar")]));
	assert(result.isError);
}

unittest {
	// Test: nonexistent file returns error
	auto tool = new CoverageAnalysisTool();
	auto result = tool.execute(JSONValue([
		"file_path": JSONValue("/tmp/nonexistent_12345.lst")
	]));
	assert(result.isError);
}

/// Happy-path integration test: write a realistic .lst file, call execute(),
/// parse the JSON output, and verify the full result structure.
unittest {
	import std.file : write, remove, tempDir;
	import std.path : buildPath;
	import std.process : thisProcessID;
	import std.conv : to;
	import std.json : parseJSON;
	import std.exception : collectException;
	import std.format : format;

	// Realistic .lst content: a Calculator class with covered and uncovered methods.
	// Format: 7-char count field | source line
	//   "       |" = non-executable (comment, blank, declaration)
	//   "0000000|" = executable but uncovered
	//   "      N|" = executed N times
	enum lstContent = "       |// Calculator module\n" ~ "       |module source.calculator;\n" ~ "       |\n"
		~ "       |class Calculator\n" ~ "       |{\n" // add: fully covered (lines 6-10)
		 ~ "       |    int add(int a, int b)\n"
		~ "       |    {\n" ~ "      5|        return a + b;\n" ~ "       |    }\n"
		~ "       |\n" // multiply: fully covered (lines 11-15)
		 ~ "       |    int multiply(int a, int b)\n" ~ "       |    {\n"
		~ "      3|        return a * b;\n" ~ "       |    }\n" ~ "       |\n" // divide: partially covered - 4 uncovered lines (lines 16-25)

		

		~ "       |    int divide(int a, int b)\n" ~ "       |    {\n" ~ "      2|        if (b == 0)\n"
		~ "       |        {\n" ~ "0000000|            import std.stdio;\n"
		~ "0000000|            writeln(\"error: division by zero\");\n"
		~ "0000000|            return -1;\n"
		~ "       |        }\n" ~ "0000000|        return a / b;\n" ~ "       |    }\n"
		~ "       |\n" // subtract: partially covered - 2 uncovered lines (lines 26-33)
		 ~ "       |    int subtract(int a, int b)\n" ~ "       |    {\n"
		~ "      1|        if (a < b)\n" ~ "0000000|            return 0;\n"
		~ "0000000|        int result = a - b;\n" ~ "      1|        return result;\n"
		~ "       |    }\n" ~ "       |\n" // end class
		 ~ "       |}\n" ~ "       |\n" // main: fully covered (lines 36-41)

		

		~ "       |void main()\n" ~ "       |{\n" ~ "      1|    auto c = new Calculator();\n"
		~ "      1|    c.add(1, 2);\n" ~ "      1|    c.multiply(3, 4);\n"
		~ "       |}\n" ~ "       |\n" // unittest block: should be skipped in output (lines 43-47)
		 ~ "       |unittest\n" ~ "       |{\n"
		~ "      1|    auto c = new Calculator();\n"
		~ "      1|    assert(c.add(1, 1) == 2);\n" ~ "       |}\n"
		~ "source/calculator.d is 60% covered\n";

	string lstPath = buildPath(tempDir(), "coverage_test_" ~ to!string(thisProcessID) ~ ".lst");
	scope(exit)
		collectException(remove(lstPath));

	write(lstPath, lstContent);

	auto tool = new CoverageAnalysisTool();
	auto result = tool.execute(JSONValue(["file_path": JSONValue(lstPath)]));

	// Should succeed, not be an error
	assert(!result.isError, "Expected successful result, got error");
	assert(result.content.length > 0, "Expected content in result");

	auto json = parseJSON(result.content[0].text);

	// files_analyzed should be 1
	assert(json["files_analyzed"].get!long == 1,
			"Expected files_analyzed=1, got " ~ to!string(json["files_analyzed"].get!long));

	// results should have 1 entry (one file)
	auto results = json["results"].array;
	assert(results.length == 1, "Expected 1 result entry, got " ~ to!string(results.length));

	auto fileResult = results[0];

	// File-level fields should be present and reasonable
	assert("source_file" in fileResult);
	assert("total_lines" in fileResult);
	assert("executable_lines" in fileResult);
	assert("covered_lines" in fileResult);
	assert("uncovered_lines" in fileResult);
	assert("file_coverage_pct" in fileResult);
	assert("functions" in fileResult);

	assert(fileResult["total_lines"].get!long > 0, "total_lines should be > 0");
	assert(fileResult["executable_lines"].get!long > 0, "executable_lines should be > 0");
	assert(fileResult["uncovered_lines"].get!long > 0, "uncovered_lines should be > 0");

	// With default min_uncovered=1, only divide (4 uncovered) and subtract (2 uncovered)
	// should appear. add, multiply, and main are fully covered (0 uncovered).
	// unittest block should be skipped entirely.
	auto functions = fileResult["functions"].array;
	assert(functions.length == 2,
			format("Expected 2 functions with uncovered lines, got %d", functions.length));

	// Sorted by uncovered_lines descending: divide first, then subtract
	auto func0 = functions[0];
	auto func1 = functions[1];

	assert(func0["name"].str == "divide",
			"Expected first function to be 'divide', got '" ~ func0["name"].str ~ "'");
	assert(func1["name"].str == "subtract",
			"Expected second function to be 'subtract', got '" ~ func1["name"].str ~ "'");

	// Verify function fields are present
	foreach(idx, func; functions) {
		assert("name" in func, format("Function %d missing 'name'", idx));
		assert("start_line" in func, format("Function %d missing 'start_line'", idx));
		assert("end_line" in func, format("Function %d missing 'end_line'", idx));
		assert("executable_lines" in func, format("Function %d missing 'executable_lines'", idx));
		assert("uncovered_lines" in func, format("Function %d missing 'uncovered_lines'", idx));
		assert("coverage_pct" in func, format("Function %d missing 'coverage_pct'", idx));
	}

	// divide should have 4 uncovered lines
	assert(func0["uncovered_lines"].get!long == 4,
			format("Expected divide to have 4 uncovered lines, got %d",
				func0["uncovered_lines"].get!long));

	// subtract should have 2 uncovered lines
	assert(func1["uncovered_lines"].get!long == 2,
			format("Expected subtract to have 2 uncovered lines, got %d",
				func1["uncovered_lines"].get!long));

	// Both should have parent == "Calculator"
	assert("parent" in func0, "divide should have a 'parent' field");
	assert(func0["parent"].str == "Calculator",
			"Expected divide parent to be 'Calculator', got '" ~ func0["parent"].str ~ "'");
	assert("parent" in func1, "subtract should have a 'parent' field");
	assert(func1["parent"].str == "Calculator",
			"Expected subtract parent to be 'Calculator', got '" ~ func1["parent"].str ~ "'");

	// coverage_pct should be between 0 and 100
	foreach(func; functions) {
		double pct = func["coverage_pct"].type == JSONType.float_
			? func["coverage_pct"].get!double : cast(double)func["coverage_pct"].get!long;
		assert(pct >= 0.0 && pct <= 100.0, format("coverage_pct out of range: %f", pct));
	}

	// end_line should be > start_line
	foreach(func; functions) {
		assert(func["end_line"].get!long > func["start_line"].get!long,
				format("end_line (%d) should be > start_line (%d)",
					func["end_line"].get!long, func["start_line"].get!long));
	}
}

/// Integration test: min_uncovered filtering narrows results
unittest {
	import std.file : write, remove, tempDir;
	import std.path : buildPath;
	import std.process : thisProcessID;
	import std.conv : to;
	import std.json : parseJSON;
	import std.exception : collectException;
	import std.format : format;

	// Same realistic .lst content as the happy-path test
	enum lstContent = "       |module source.calc2;\n" ~ "       |\n"
		~ "       |class Calculator\n" ~ "       |{\n" // divide: 4 uncovered lines
		 ~ "       |    int divide(int a, int b)\n"
		~ "       |    {\n" ~ "      2|        if (b == 0)\n"
		~ "       |        {\n" ~ "0000000|            import std.stdio;\n"
		~ "0000000|            writeln(\"error\");\n"
		~ "0000000|            return -1;\n"
		~ "       |        }\n"
		~ "0000000|        return a / b;\n" ~ "       |    }\n" ~ "       |\n" // subtract: 2 uncovered lines

		

		~ "       |    int subtract(int a, int b)\n" ~ "       |    {\n"
		~ "      1|        if (a < b)\n" ~ "0000000|            return 0;\n"
		~ "0000000|        int result = a - b;\n" ~ "      1|        return result;\n"
		~ "       |    }\n" ~ "       |\n" // add: fully covered (0 uncovered)
		 ~ "       |    int add(int a, int b)\n"
		~ "       |    {\n" ~ "      5|        return a + b;\n"
		~ "       |    }\n" ~ "       |}\n" ~ "source/calc2.d is 50% covered\n";

	string lstPath = buildPath(tempDir(),
			"coverage_filter_test_" ~ to!string(thisProcessID) ~ ".lst");
	scope(exit)
		collectException(remove(lstPath));

	write(lstPath, lstContent);

	auto tool = new CoverageAnalysisTool();

	// With min_uncovered=3, only divide (4 uncovered) should appear.
	// subtract (2 uncovered) and add (0 uncovered) should be filtered out.
	auto result = tool.execute(JSONValue([
		"file_path": JSONValue(lstPath),
		"min_uncovered": JSONValue(3)
	]));

	assert(!result.isError, "Expected successful result, got error");

	auto json = parseJSON(result.content[0].text);
	auto results = json["results"].array;
	assert(results.length == 1, "Expected 1 file result");

	auto functions = results[0]["functions"].array;
	assert(functions.length == 1,
			format("Expected 1 function with min_uncovered=3, got %d", functions.length));
	assert(functions[0]["name"].str == "divide",
			"Expected only 'divide' to pass min_uncovered=3 filter, got '"
			~ functions[0]["name"].str ~ "'");
	assert(functions[0]["uncovered_lines"].get!long >= 3, "divide should have >= 3 uncovered lines");

	// With min_uncovered=0, all functions including fully covered ones should appear
	auto result0 = tool.execute(JSONValue([
		"file_path": JSONValue(lstPath),
		"min_uncovered": JSONValue(0)
	]));

	assert(!result0.isError, "Expected successful result for min_uncovered=0");
	auto json0 = parseJSON(result0.content[0].text);
	auto functions0 = json0["results"].array[0]["functions"].array;
	assert(functions0.length == 3,
			format("Expected 3 functions with min_uncovered=0, got %d", functions0.length));
}

/// Test: providing both file_path and directory returns error (line 64)
unittest {
	import std.file : tempDir;

	auto tool = new CoverageAnalysisTool();
	auto result = tool.execute(JSONValue([
		"file_path": JSONValue("/tmp/some_file.lst"),
		"directory": JSONValue(tempDir())
	]));
	assert(result.isError, "Expected error when both file_path and directory are provided");
}

/// Test: file_path pointing to a directory returns "Not a file" error (line 78)
unittest {
	import std.file : tempDir;

	auto tool = new CoverageAnalysisTool();
	auto result = tool.execute(JSONValue(["file_path": JSONValue(tempDir())]));
	assert(result.isError, "Expected error when file_path points to a directory");
}

/// Test: directory with .lst files succeeds (lines 82-94)
unittest {
	import std.file : write, remove, tempDir, mkdir, rmdirRecurse;
	import std.path : buildPath;
	import std.process : thisProcessID;
	import std.conv : to;
	import std.json : parseJSON;
	import std.exception : collectException;
	import std.format : format;

	string dir = buildPath(tempDir(), "cov_dir_test_" ~ to!string(thisProcessID));
	mkdir(dir);
	scope(exit)
		collectException(rmdirRecurse(dir));

	// Two minimal .lst files with at least one executable line each
	enum lstContent1 = "       |module source.a;\n" ~ "       |void foo()\n" ~ "       |{\n"
		~ "      1|    return;\n" ~ "       |}\n" ~ "source/a.d is 100% covered\n";

	enum lstContent2 = "       |module source.b;\n" ~ "       |void bar()\n" ~ "       |{\n"
		~ "      1|    return;\n" ~ "       |}\n" ~ "source/b.d is 100% covered\n";

	write(buildPath(dir, "a.lst"), lstContent1);
	write(buildPath(dir, "b.lst"), lstContent2);

	auto tool = new CoverageAnalysisTool();
	auto result = tool.execute(JSONValue(["directory": JSONValue(dir)]));

	assert(!result.isError, "Expected success for directory with .lst files");
	auto json = parseJSON(result.content[0].text);
	assert(json["files_analyzed"].get!long == 2,
			format("Expected files_analyzed=2, got %d", json["files_analyzed"].get!long));
}

/// Test: non-existent directory returns error (line 85)
unittest {
	auto tool = new CoverageAnalysisTool();
	auto result = tool.execute(JSONValue([
		"directory": JSONValue("/tmp/nonexistent_dir_xyz123")
	]));
	assert(result.isError, "Expected error for non-existent directory");
}

/// Test: directory argument pointing to a regular file returns "Not a directory" error (line 87)
unittest {
	import std.file : write, remove, tempDir;
	import std.path : buildPath;
	import std.process : thisProcessID;
	import std.conv : to;
	import std.exception : collectException;

	string fp = buildPath(tempDir(), "not_a_dir_" ~ to!string(thisProcessID) ~ ".txt");
	write(fp, "hello");
	scope(exit)
		collectException(remove(fp));

	auto tool = new CoverageAnalysisTool();
	auto result = tool.execute(JSONValue(["directory": JSONValue(fp)]));
	assert(result.isError, "Expected error when directory points to a regular file");
}

/// Test: empty directory (no .lst files) returns error (line 92-93)
unittest {
	import std.file : tempDir, mkdir, rmdirRecurse;
	import std.path : buildPath;
	import std.process : thisProcessID;
	import std.conv : to;
	import std.exception : collectException;

	string dir = buildPath(tempDir(), "empty_dir_test_" ~ to!string(thisProcessID));
	mkdir(dir);
	scope(exit)
		collectException(rmdirRecurse(dir));

	auto tool = new CoverageAnalysisTool();
	auto result = tool.execute(JSONValue(["directory": JSONValue(dir)]));
	assert(result.isError, "Expected error for directory with no .lst files");
}

/// Test: .lst file with no pipe characters yields null from analyzeFile (line 132)
/// The file is analyzed (files_analyzed == 1) but produces no results entry.
unittest {
	import std.file : write, remove, tempDir;
	import std.path : buildPath;
	import std.process : thisProcessID;
	import std.conv : to;
	import std.json : parseJSON;
	import std.exception : collectException;
	import std.format : format;

	// Content with no pipe characters — every line is treated as summary,
	// so parseLstContent produces lines.length == 0.
	enum lstContent = "source/foo.d is 100% covered\n";

	string lstPath = buildPath(tempDir(), "empty_cov_" ~ to!string(thisProcessID) ~ ".lst");
	write(lstPath, lstContent);
	scope(exit)
		collectException(remove(lstPath));

	auto tool = new CoverageAnalysisTool();
	auto result = tool.execute(JSONValue(["file_path": JSONValue(lstPath)]));

	assert(!result.isError, "Expected success for .lst with no executable lines");
	auto json = parseJSON(result.content[0].text);
	assert(json["files_analyzed"].get!long == 1,
			format("Expected files_analyzed=1, got %d", json["files_analyzed"].get!long));
	// The null return from analyzeFile is skipped, so results array should be empty
	assert(json["results"].array.length == 0,
			format("Expected 0 results (null skipped), got %d", json["results"].array.length));
}

/// Test: function with only non-executable lines gets coveragePct == 100.0 (line 170)
unittest {
	import std.file : write, remove, tempDir;
	import std.path : buildPath;
	import std.process : thisProcessID;
	import std.conv : to;
	import std.json : parseJSON, JSONType;
	import std.exception : collectException;
	import std.format : format;

	// A function where every line inside is non-executable (all "       |").
	// The function body has declarations/comments only — no executable lines.
	// We need at least one executable line somewhere so the file isn't empty.
	enum lstContent = "       |module source.noexec;\n" ~ "       |\n"
		~ "       |void emptyFunc()\n" ~ "       |{\n" ~ "       |    // just a comment\n"
		~ "       |    // another comment\n" ~ "       |}\n" ~ "       |\n"
		~ "       |void realFunc()\n" ~ "       |{\n" ~ "      1|    return;\n"
		~ "       |}\n" ~ "source/noexec.d is 100% covered\n";

	string lstPath = buildPath(tempDir(), "noexec_cov_" ~ to!string(thisProcessID) ~ ".lst");
	write(lstPath, lstContent);
	scope(exit)
		collectException(remove(lstPath));

	auto tool = new CoverageAnalysisTool();
	// min_uncovered=0 so that functions with 0 uncovered lines (including emptyFunc) appear
	auto result = tool.execute(JSONValue([
		"file_path": JSONValue(lstPath),
		"min_uncovered": JSONValue(0)
	]));

	assert(!result.isError, "Expected success");
	auto json = parseJSON(result.content[0].text);
	auto results = json["results"].array;
	assert(results.length == 1, "Expected 1 file result");

	auto functions = results[0]["functions"].array;

	// Find emptyFunc in the results
	bool foundEmptyFunc = false;
	foreach(func; functions) {
		if(func["name"].str == "emptyFunc") {
			foundEmptyFunc = true;
			assert(func["executable_lines"].get!long == 0,
					format("Expected 0 executable lines, got %d",
						func["executable_lines"].get!long));
			double pct = func["coverage_pct"].type == JSONType.float_
				? func["coverage_pct"].get!double : cast(double)func["coverage_pct"].get!long;
			assert(pct == 100.0,
					format("Expected coverage_pct=100.0 for function with no executable lines, got %f",
						pct));
		}
	}
	assert(foundEmptyFunc, "Expected to find 'emptyFunc' in results with min_uncovered=0");
}

/// Test: directory scan filters out dependency .lst files (base name starts with "..")
unittest {
	import std.file : write, remove, tempDir, mkdir, rmdirRecurse;
	import std.path : buildPath;
	import std.process : thisProcessID;
	import std.conv : to;
	import std.json : parseJSON;
	import std.exception : collectException;
	import std.format : format;

	string dir = buildPath(tempDir(), "cov_filter_test_" ~ to!string(thisProcessID));
	mkdir(dir);
	scope(exit)
		collectException(rmdirRecurse(dir));

	// Project .lst file — should be analyzed
	enum projectLst = "       |module source.a;\n" ~ "       |void foo()\n" ~ "       |{\n"
		~ "      1|    return;\n" ~ "       |}\n" ~ "source/a.d is 100% covered\n";

	// Dependency .lst file — should be SKIPPED (base name starts with "..")
	enum depLst = "       |module vibe.http.server;\n" ~ "       |void handle()\n" ~ "       |{\n"
		~ "      1|    return;\n" ~ "       |}\n" ~ "vibe/http/server.d is 100% covered\n";

	write(buildPath(dir, "source-a.lst"), projectLst);
	write(buildPath(dir,
			"..-..-..-.dub-packages-vibe-http-1.0.0-source-vibe-http-server.lst"), depLst);

	auto tool = new CoverageAnalysisTool();
	auto result = tool.execute(JSONValue(["directory": JSONValue(dir)]));

	assert(!result.isError, "Expected success");
	auto json = parseJSON(result.content[0].text);
	assert(json["files_analyzed"].get!long == 1,
			format("Expected 1 file analyzed (dependency skipped), got %d",
				json["files_analyzed"].get!long));
}

/// Test: directory with only dependency .lst files returns error (all filtered out)
unittest {
	import std.file : write, remove, tempDir, mkdir, rmdirRecurse;
	import std.path : buildPath;
	import std.process : thisProcessID;
	import std.conv : to;
	import std.exception : collectException;

	string dir = buildPath(tempDir(), "cov_deponly_test_" ~ to!string(thisProcessID));
	mkdir(dir);
	scope(exit)
		collectException(rmdirRecurse(dir));

	// Only dependency .lst files
	enum depLst = "       |module dep;\n" ~ "      1|    return;\n" ~ "dep.d is 100% covered\n";
	write(buildPath(dir, "..-..-..-.dub-packages-dep-1.0.0-source-dep.lst"), depLst);

	auto tool = new CoverageAnalysisTool();
	auto result = tool.execute(JSONValue(["directory": JSONValue(dir)]));
	assert(result.isError, "Expected error when all .lst files are dependency files");
}
