/**
 * MCP tool for searching symbol definitions using ctags.
 *
 * Generates and maintains a ctags index for D projects, supporting
 * symbol lookup by exact name, prefix, or regex pattern with optional
 * filtering by symbol kind (function, class, struct, etc.).
 */
module tools.ctags;

import std.json : JSONValue, parseJSON, JSONType;
import std.file : exists, getTimes, timeLastModified, DirEntry, dirEntries, SpanMode;
import std.path : buildPath;
import std.string : strip;
import std.array : appender;
import std.conv : text;
import std.algorithm.iteration : splitter;
import std.string : lineSplitter;
import tools.base : BaseTool;
import mcp.types : ToolResult;
import utils.process : executeCommand;
import utils.ctags_parser : CtagsEntry, parseCtagsFile, searchEntries, formatEntry;

/**
 * Tool that searches for symbol definitions across a D project using ctags.
 *
 * Automatically generates or regenerates the tags file when it is missing
 * or older than the source files. Supports exact, prefix, and regex matching
 * with optional kind filtering.
 */
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
                },
                "source_dirs": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Source directories to scan (relative to project_path). Auto-detected from dub config or defaults to ['source', 'src']."
                }
            },
            "required": ["query"]
        }`);
	}

	ToolResult execute(JSONValue arguments)
	{
		try {
			import std.path : absolutePath;

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

			string[] sourceDirs = resolveSourceDirs(projectPath, arguments);

			if(needsRegeneration(projectPath, tagsPath, sourceDirs)) {
				string error = generateCtags(projectPath, tagsPath, sourceDirs);
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
	string[] resolveSourceDirs(string projectPath, JSONValue arguments)
	{
		// If user explicitly provided source_dirs, use those
		if("source_dirs" in arguments && arguments["source_dirs"].type == JSONType.array) {
			string[] dirs;
			foreach(item; arguments["source_dirs"].array) {
				if(item.type == JSONType.string) {
					auto dir = buildPath(projectPath, item.str);
					if(exists(dir))
						dirs ~= dir;
				}
			}
			if(dirs.length > 0)
				return dirs;
		}

		// Try to auto-detect from dub.json
		auto dubJsonPath = buildPath(projectPath, "dub.json");
		if(exists(dubJsonPath)) {
			try {
				import std.file : readText;

				auto dubJson = parseJSON(readText(dubJsonPath));
				if("importPaths" in dubJson && dubJson["importPaths"].type == JSONType.array) {
					string[] dirs;
					foreach(item; dubJson["importPaths"].array) {
						if(item.type == JSONType.string) {
							auto dir = buildPath(projectPath, item.str);
							if(exists(dir))
								dirs ~= dir;
						}
					}
					if(dirs.length > 0)
						return dirs;
				}
				if("sourcePaths" in dubJson && dubJson["sourcePaths"].type == JSONType.array) {
					string[] dirs;
					foreach(item; dubJson["sourcePaths"].array) {
						if(item.type == JSONType.string) {
							auto dir = buildPath(projectPath, item.str);
							if(exists(dir))
								dirs ~= dir;
						}
					}
					if(dirs.length > 0)
						return dirs;
				}
			} catch(Exception) {
				// Fall through to defaults
			}
		}

		// Default: try source/ then src/
		string[] defaults;
		auto sourceDir = buildPath(projectPath, "source");
		if(exists(sourceDir))
			defaults ~= sourceDir;
		auto srcDir = buildPath(projectPath, "src");
		if(exists(srcDir))
			defaults ~= srcDir;

		return defaults;
	}

	bool needsRegeneration(string projectPath, string tagsPath, string[] sourceDirs)
	{
		if(!exists(tagsPath))
			return true;

		auto tagsTime = timeLastModified(tagsPath);

		foreach(sourceDir; sourceDirs) {
			if(!exists(sourceDir))
				continue;

			foreach(entry; dirEntries(sourceDir, "*.d", SpanMode.depth)) {
				if(timeLastModified(entry.name) > tagsTime)
					return true;
			}
		}

		return false;
	}

	string generateCtags(string projectPath, string tagsPath, string[] sourceDirs)
	{
		string[] sourceFiles;
		foreach(sourceDir; sourceDirs) {
			if(!exists(sourceDir))
				continue;
			foreach(entry; dirEntries(sourceDir, "*.d", SpanMode.depth)) {
				sourceFiles ~= entry.name;
			}
		}

		if(sourceFiles.length == 0) {
			return "No D source files found in project: " ~ projectPath;
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
