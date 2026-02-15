module tools.ctags;

import std.json : JSONValue, parseJSON, JSONType;
import std.file : exists, getTimes, timeLastModified, DirEntry, dirEntries, SpanMode;
import std.path : buildPath, absolutePath;
import std.string : strip;
import std.array : appender;
import std.conv : text;
import std.algorithm.iteration : splitter;
import std.string : lineSplitter;
import tools.base : BaseTool;
import mcp.types : ToolResult;
import utils.process : executeCommand;
import utils.ctags_parser : CtagsEntry, parseCtagsFile, searchEntries, formatEntry;

class CtagsSearchTool : BaseTool {
	@property string name()
	{
		return "ctags_search";
	}

	@property string description()
	{
		return "Search for symbol definitions across the project using ctags. Automatically generates or regenerates the tags file when needed (if missing or outdated).";
	}

	@property JSONValue inputSchema()
	{
		return parseJSON(`{
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Symbol name to search for"
                },
                "project_path": {
                    "type": "string",
                    "default": ".",
                    "description": "Project root directory"
                },
                "match_type": {
                    "type": "string",
                    "enum": ["exact", "prefix", "regex"],
                    "default": "exact",
                    "description": "Match type: exact (equality), prefix (starts with), or regex pattern"
                },
                "kind": {
                    "type": "string",
                    "description": "Filter by symbol kind: f=function, c=class, s=struct, g=enum, i=interface, v=variable, e=enum member"
                }
            },
            "required": ["query"]
        }`);
	}

	ToolResult execute(JSONValue arguments)
	{
		try {
			if(arguments.type != JSONType.object || !("query" in arguments)) {
				return createErrorResult("Missing required 'query' parameter");
			}

			string query = arguments["query"].str;

			string projectPath = ".";
			if("project_path" in arguments && arguments["project_path"].type == JSONType.string) {
				projectPath = arguments["project_path"].str;
			}

			projectPath = absolutePath(projectPath);
			string tagsPath = buildPath(projectPath, "tags");

			string matchType = "exact";
			if("match_type" in arguments && arguments["match_type"].type == JSONType.string) {
				matchType = arguments["match_type"].str;
			}

			string kindFilter;
			if("kind" in arguments && arguments["kind"].type == JSONType.string) {
				kindFilter = arguments["kind"].str;
			}

			if(needsRegeneration(projectPath, tagsPath)) {
				string error = generateCtags(projectPath, tagsPath);
				if(error.length > 0) {
					return createErrorResult(error);
				}
			}

			auto entries = parseCtagsFile(tagsPath);
			auto results = searchEntries(entries, query, matchType, kindFilter);

			return formatResults(results, query);
		} catch(Exception e) {
			return createErrorResult("Error searching ctags: " ~ e.msg);
		}
	}

private:
	bool needsRegeneration(string projectPath, string tagsPath)
	{
		if(!exists(tagsPath))
			return true;

		auto tagsTime = timeLastModified(tagsPath);

		auto sourceDir = buildPath(projectPath, "source");
		if(!exists(sourceDir))
			return false;

		foreach(entry; dirEntries(sourceDir, "*.d", SpanMode.depth)) {
			if(timeLastModified(entry.name) > tagsTime)
				return true;
		}

		return false;
	}

	string generateCtags(string projectPath, string tagsPath)
	{
		auto sourceDir = buildPath(projectPath, "source");
		if(!exists(sourceDir)) {
			return "Source directory not found: " ~ sourceDir;
		}

		string[] sourceFiles;
		foreach(entry; dirEntries(sourceDir, "*.d", SpanMode.depth)) {
			sourceFiles ~= entry.name;
		}

		if(sourceFiles.length == 0) {
			return "No D source files found in: " ~ sourceDir;
		}

		auto outputApp = appender!string;
		outputApp ~= "!_TAG_FILE_FORMAT\t2\n";
		outputApp ~= "!_TAG_FILE_SORTED\t1\n";
		outputApp ~= "!_TAG_FILE_AUTHOR\tBrian Schott\n";
		outputApp ~= "!_TAG_PROGRAM_URL\thttps://github.com/dlang-community/D-Scanner/\n";

		foreach(file; sourceFiles) {
			auto result = executeCommand(["dscanner", "--ctags", file]);
			if(result.status == 0 && result.output.length > 0) {
				bool hasTags = false;
				foreach(line; result.output.lineSplitter) {
					if(line.strip().length > 0 && line[0] != '!') {
						outputApp ~= line ~ "\n";
						hasTags = true;
					}
				}
			}
		}

		import std.stdio : File;
		import std.file : write;

		write(tagsPath, outputApp.data);

		return null;
	}

	ToolResult formatResults(CtagsEntry[] results, string query)
	{
		if(results.length == 0) {
			return createTextResult("No symbols found matching '" ~ query ~ "'");
		}

		auto outputApp = appender!string;
		outputApp ~= "Found " ~ text(results.length) ~ " match" ~ (results.length > 1
				? "es" : "") ~ ":\n\n";

		foreach(entry; results) {
			outputApp ~= formatEntry(entry) ~ "\n";
		}

		return createTextResult(outputApp.data);
	}
}
