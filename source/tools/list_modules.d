/**
 * MCP tool for listing all modules in a D project with their public API summaries.
 *
 * Scans a D project's source directories, identifies all modules, and uses
 * D-Scanner ctags to extract public symbols (functions, classes, structs,
 * enums, interfaces) with their signatures.
 */
module tools.list_modules;

import std.json : JSONValue, parseJSON, JSONType;
import std.file : exists, dirEntries, SpanMode;
import std.path : buildPath, absolutePath, relativePath;
import std.string : strip, replace, endsWith, startsWith, lineSplitter, join;
import std.array : appender, array;
import std.conv : text;
import std.algorithm.iteration : map, filter;
import std.algorithm.sorting : sort;
import tools.base : BaseTool;
import mcp.types : ToolResult;
import utils.process : executeCommand;
import utils.ctags_parser : CtagsEntry, parseCtagsLine;

/**
 * Tool that lists all modules in a D project with a summary of their public API.
 *
 * For each module, reports the file path, module name, and public symbols
 * with their kinds and signatures. Uses D-Scanner's ctags mode for fast
 * symbol extraction.
 */
class ListProjectModulesTool : BaseTool {
	@property string name()
	{
		return "list_project_modules";
	}

	@property string description()
	{
		return "List all modules in a D project with a summary of their public API. "
			~ "For each module, shows the file path, module name, and public symbols "
			~ "(functions, classes, structs, enums, interfaces) with their kinds and signatures. "
			~ "Uses dscanner ctags for fast symbol extraction.";
	}

	@property JSONValue inputSchema()
	{
		return parseJSON(`{
            "type": "object",
            "properties": {
                "project_path": {
                    "type": "string",
                    "default": ".",
                    "description": "Project root directory"
                },
                "include_private": {
                    "type": "boolean",
                    "default": false,
                    "description": "Include private/protected symbols in the output"
                }
            }
        }`);
	}

	ToolResult execute(JSONValue arguments)
	{
		try {
			import std.path : absolutePath;

			string projectPath = ".";
			if("project_path" in arguments && arguments["project_path"].type == JSONType.string) {
				projectPath = arguments["project_path"].str;
			}

			projectPath = absolutePath(projectPath);

			bool includePrivate = false;
			if("include_private" in arguments && arguments["include_private"].type == JSONType
					.true_) {
				includePrivate = true;
			}

			// Find source files
			string[] sourceFiles = findSourceFiles(projectPath);

			if(sourceFiles.length == 0) {
				return createErrorResult("No D source files found in project: " ~ projectPath);
			}

			// Process each file
			auto result = JSONValue(cast(JSONValue[])[]);

			foreach(filePath; sourceFiles) {
				auto moduleInfo = processFile(filePath, projectPath, includePrivate);
				if(moduleInfo.type != JSONType.null_)
					result.array ~= moduleInfo;
			}

			return createTextResult(result.toPrettyString());
		} catch(Exception e) {
			return createErrorResult("Error listing modules: " ~ e.msg);
		}
	}

private:

	string[] findSourceFiles(string projectPath)
	{
		string[] files;

		// Try to get source paths from dub.json
		auto dubJsonPath = buildPath(projectPath, "dub.json");
		string[] sourceDirs;

		if(exists(dubJsonPath)) {
			try {
				import std.file : readText;

				auto dubJson = parseJSON(readText(dubJsonPath));
				if("importPaths" in dubJson && dubJson["importPaths"].type == JSONType.array) {
					foreach(item; dubJson["importPaths"].array) {
						if(item.type == JSONType.string)
							sourceDirs ~= item.str;
					}
				} else if("sourcePaths" in dubJson && dubJson["sourcePaths"].type == JSONType.array) {
					foreach(item; dubJson["sourcePaths"].array) {
						if(item.type == JSONType.string)
							sourceDirs ~= item.str;
					}
				}
			} catch(Exception) {
			}
		}

		// Default directories
		if(sourceDirs.length == 0) {
			sourceDirs = ["source", "src"];
		}

		foreach(dirName; sourceDirs) {
			auto fullPath = buildPath(projectPath, dirName);
			if(!exists(fullPath))
				continue;

			foreach(entry; dirEntries(fullPath, "*.d", SpanMode.depth)) {
				files ~= entry.name;
			}
		}

		files.sort();
		return files;
	}

	JSONValue processFile(string filePath, string projectPath, bool includePrivate)
	{
		auto relPath = relativePath(filePath, projectPath);
		string moduleName = pathToModuleName(relPath);

		// Run dscanner --ctags on this file
		auto ctagsResult = executeCommand(["dscanner", "--ctags", filePath]);
		if(ctagsResult.status != 0) {
			// Still include the module, just without symbols
			auto obj = JSONValue(cast(string[string])null);
			obj["file"] = relPath;
			if(moduleName.length > 0)
				obj["module"] = moduleName;
			obj["symbols"] = JSONValue(cast(JSONValue[])[]);
			return obj;
		}

		// Parse ctags output
		CtagsEntry[] entries;
		foreach(line; ctagsResult.output.lineSplitter) {
			auto stripped = line.strip();
			if(stripped.length == 0 || stripped[0] == '!')
				continue;

			auto entry = parseCtagsLine(stripped);
			if(entry.symbol.length == 0)
				continue;

			// Filter by visibility
			if(!includePrivate && (entry.access == "private" || entry.access == "protected"))
				continue;

			entries ~= entry;
		}

		// Build JSON output
		auto obj = JSONValue(cast(string[string])null);
		obj["file"] = relPath;
		if(moduleName.length > 0)
			obj["module"] = moduleName;

		auto symbolArr = JSONValue(cast(JSONValue[])[]);
		foreach(ref entry; entries) {
			auto symObj = JSONValue(cast(string[string])null);
			symObj["name"] = entry.symbol;
			if(entry.kind.length > 0)
				symObj["kind"] = kindToFullName(entry.kind);
			if(entry.signature.length > 0)
				symObj["signature"] = entry.signature;
			if(entry.scopeName.length > 0)
				symObj["scope"] = entry.scopeName;
			if(entry.line > 0)
				symObj["line"] = JSONValue(entry.line);
			if(includePrivate && entry.access.length > 0)
				symObj["access"] = entry.access;
			symbolArr.array ~= symObj;
		}

		obj["symbols"] = symbolArr;
		return obj;
	}

	static string pathToModuleName(string path)
	{
		string p = path.replace("\\", "/");

		if(p.startsWith("source/"))
			p = p[7 .. $];
		else if(p.startsWith("src/"))
			p = p[4 .. $];

		if(!p.endsWith(".d"))
			return "";

		p = p[0 .. $ - 2];

		if(p.endsWith("/package"))
			p = p[0 .. $ - 8];

		return p.replace("/", ".");
	}

	static string kindToFullName(string kind)
	{
		switch(kind) {
		case "f":
			return "function";
		case "c":
			return "class";
		case "s":
			return "struct";
		case "g":
			return "enum";
		case "i":
			return "interface";
		case "v":
			return "variable";
		case "e":
			return "enum_member";
		case "m":
			return "member";
		case "p":
			return "property";
		default:
			return kind;
		}
	}
}
