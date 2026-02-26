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
		return "Analyze D code coverage from .lst files. Parses coverage files "
			~ "produced by `dmd -cov` or `ldc2 --cov`, identifies functions "
			~ "with uncovered lines, and reports per-function coverage "
			~ "statistics sorted by number of uncovered lines.";
	}

	override @property JSONValue inputSchema()
	{
		return JSONValue([
			"type": JSONValue("object"),
			"properties": JSONValue([
				"file_path": JSONValue([
					"type": JSONValue("string"),
					"description": JSONValue("Path to a single .lst coverage file")
				]),
				"directory": JSONValue([
					"type": JSONValue("string"),
					"description": JSONValue("Directory to scan for .lst coverage files")
				]),
				"min_uncovered": JSONValue([
					"type": JSONValue("integer"),
					"description": JSONValue(
							"Only show functions with at least this many " ~ "uncovered lines (default: 1)"),
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

		int minUncovered = 1;
		if("min_uncovered" in arguments && arguments["min_uncovered"].type == JSONType.integer)
			minUncovered = arguments["min_uncovered"].get!int;

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

			foreach(entry; dirEntries(dir, "*.lst", SpanMode.shallow))
				lstFiles ~= entry.name;

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

	private JSONValue analyzeFile(string lstPath, int minUncovered)
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
