/**
 * MCP tool for analyzing D project structure and configuration.
 *
 * Uses `dub describe` to extract project metadata including dependencies,
 * source files, import paths, and build settings, with a fallback to
 * parsing `dub.json`/`dub.sdl` directly if dub is unavailable.
 */
module tools.analyze_project;

import std.json : JSONValue, parseJSON, JSONType;
import std.file : exists, readText, dirEntries, SpanMode;
import std.path : buildPath, absolutePath, relativePath, stripExtension, pathSplitter;
import std.string : strip, replace, endsWith, join;
import std.array : appender, array;
import std.conv : text;
import std.algorithm.iteration : map, filter;
import tools.base : BaseTool;
import mcp.types : ToolResult;
import utils.process : executeCommand;

/**
 * Tool that analyzes a D/dub project's structure and returns a comprehensive report.
 *
 * Reports include the project name, dependencies, source file listing,
 * import paths, build configuration, and module inventory. Accepts a
 * `project_path` argument pointing to a directory containing a dub project file.
 */
class AnalyzeProjectTool : BaseTool {
	@property string name()
	{
		return "analyze_project";
	}

	@property string description()
	{
		return "Analyze a D project's structure. Returns project name, dependencies, source files, "
			~ "import paths, build configuration, and module list. Uses 'dub describe' for accurate "
			~ "information, with fallback to parsing dub.json directly.";
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

			// Try dub describe first for the most accurate info
			auto dubResult = tryDubDescribe(projectPath);
			if(dubResult.type != JSONType.null_) {
				return createTextResult(formatDubDescribe(dubResult, projectPath));
			}

			// Fallback: parse dub.json directly
			auto dubJsonPath = buildPath(projectPath, "dub.json");
			if(exists(dubJsonPath)) {
				return createTextResult(formatDubJson(dubJsonPath, projectPath));
			}

			// Fallback: parse dub.sdl if it exists
			auto dubSdlPath = buildPath(projectPath, "dub.sdl");
			if(exists(dubSdlPath)) {
				return createTextResult(formatMinimalProject(projectPath,
						"dub.sdl found but SDL parsing is limited"));
			}

			return createTextResult(formatMinimalProject(projectPath,
					"No dub.json or dub.sdl found"));
		} catch(Exception e) {
			return createErrorResult("Error analyzing project: " ~ e.msg);
		}
	}

private:
	JSONValue tryDubDescribe(string projectPath)
	{
		auto result = executeCommand(["dub", "describe", "--root=" ~ projectPath]);
		if(result.status != 0 || result.output.length == 0)
			return JSONValue(null);

		try {
			return parseJSON(result.output);
		} catch(Exception) {
			return JSONValue(null);
		}
	}

	string formatDubDescribe(JSONValue desc, string projectPath)
	{
		auto output = appender!string;

		// Root package info
		string rootPkgName = "";
		if("rootPackage" in desc)
			rootPkgName = desc["rootPackage"].str;

		output ~= "# Project: " ~ rootPkgName ~ "\n\n";

		// Platform info
		if("platform" in desc) {
			auto platform = desc["platform"].array.map!(p => p.str).join(", ");
			output ~= "Platform: " ~ platform ~ "\n";
		}
		if("architecture" in desc) {
			auto arch = desc["architecture"].array.map!(a => a.str).join(", ");
			output ~= "Architecture: " ~ arch ~ "\n";
		}
		if("configuration" in desc) {
			output ~= "Configuration: " ~ desc["configuration"].str ~ "\n";
		}
		output ~= "\n";

		// Find root package in packages array
		if("packages" in desc) {
			foreach(pkg; desc["packages"].array) {
				if(pkg["name"].str == rootPkgName) {
					formatPackageInfo(output, pkg, projectPath);
					break;
				}
			}

			// List all dependency packages
			output ~= "## Dependencies\n\n";
			bool hasDeps = false;
			foreach(pkg; desc["packages"].array) {
				if(pkg["name"].str != rootPkgName) {
					hasDeps = true;
					string ver = "";
					if("version" in pkg)
						ver = pkg["version"].str;
					output ~= "- " ~ pkg["name"].str;
					if(ver.length > 0)
						output ~= " " ~ ver;
					output ~= "\n";
				}
			}
			if(!hasDeps)
				output ~= "(none)\n";
			output ~= "\n";
		}

		return output.data;
	}

	void formatPackageInfo(ref typeof(appender!string()) output, JSONValue pkg, string projectPath)
	{
		// Basic info
		if("description" in pkg && pkg["description"].type == JSONType.string
				&& pkg["description"].str.length > 0) {
			output ~= "Description: " ~ pkg["description"].str ~ "\n";
		}
		if("targetType" in pkg) {
			output ~= "Target type: " ~ pkg["targetType"].str ~ "\n";
		}
		if("targetName" in pkg) {
			output ~= "Target name: " ~ pkg["targetName"].str ~ "\n";
		}

		// Direct dependencies
		if("dependencies" in pkg && pkg["dependencies"].type == JSONType.array) {
			output ~= "Direct dependencies: " ~ pkg["dependencies"].array.map!(d => d.str)
				.join(", ") ~ "\n";
		}

		// Import paths
		if("importPaths" in pkg && pkg["importPaths"].type == JSONType.array) {
			output ~= "Import paths: " ~ pkg["importPaths"].array.map!(p => p.str).join(", ") ~ "\n";
		}

		// Version identifiers
		if("versions" in pkg && pkg["versions"].type == JSONType.array
				&& pkg["versions"].array.length > 0) {
			output ~= "Version identifiers: " ~ pkg["versions"].array.map!(v => v.str)
				.join(", ") ~ "\n";
		}

		output ~= "\n";

		// Source files grouped by directory
		if("files" in pkg && pkg["files"].type == JSONType.array) {
			output ~= "## Source Files\n\n";
			foreach(f; pkg["files"].array) {
				if("role" in f && f["role"].str == "source") {
					string path = f["path"].str;
					string moduleName = pathToModuleName(path);
					output ~= "- " ~ path;
					if(moduleName.length > 0)
						output ~= " (" ~ moduleName ~ ")";
					output ~= "\n";
				}
			}
			output ~= "\n";
		}
	}

	string formatDubJson(string dubJsonPath, string projectPath)
	{
		auto dubJson = parseJSON(readText(dubJsonPath));
		auto output = appender!string;

		string name = "unknown";
		if("name" in dubJson)
			name = dubJson["name"].str;

		output ~= "# Project: " ~ name ~ " (from dub.json, dub describe unavailable)\n\n";

		if("description" in dubJson && dubJson["description"].type == JSONType.string) {
			output ~= "Description: " ~ dubJson["description"].str ~ "\n";
		}

		if("targetType" in dubJson) {
			output ~= "Target type: " ~ dubJson["targetType"].str ~ "\n";
		}

		// Dependencies
		output ~= "\n## Dependencies\n\n";
		if("dependencies" in dubJson && dubJson["dependencies"].type == JSONType.object) {
			foreach(depName, depVal; dubJson["dependencies"].object) {
				output ~= "- " ~ depName;
				if(depVal.type == JSONType.string)
					output ~= " " ~ depVal.str;
				else if(depVal.type == JSONType.object && "version" in depVal)
					output ~= " " ~ depVal["version"].str;
				output ~= "\n";
			}
		} else {
			output ~= "(none)\n";
		}

		// Source files
		output ~= "\n## Source Files\n\n";
		string[] sourcePaths = ["source", "src"];
		if("importPaths" in dubJson && dubJson["importPaths"].type == JSONType.array) {
			sourcePaths = [];
			foreach(p; dubJson["importPaths"].array)
				sourcePaths ~= p.str;
		} else if("sourcePaths" in dubJson && dubJson["sourcePaths"].type == JSONType.array) {
			sourcePaths = [];
			foreach(p; dubJson["sourcePaths"].array)
				sourcePaths ~= p.str;
		}

		foreach(srcPath; sourcePaths) {
			auto fullPath = buildPath(projectPath, srcPath);
			if(!exists(fullPath))
				continue;

			foreach(entry; dirEntries(fullPath, "*.d", SpanMode.depth)) {
				auto relPath = relativePath(entry.name, projectPath);
				string moduleName = pathToModuleName(relPath);
				output ~= "- " ~ relPath;
				if(moduleName.length > 0)
					output ~= " (" ~ moduleName ~ ")";
				output ~= "\n";
			}
		}
		output ~= "\n";

		return output.data;
	}

	string formatMinimalProject(string projectPath, string note)
	{
		auto output = appender!string;
		output ~= "# Project at: " ~ projectPath ~ "\n";
		output ~= "Note: " ~ note ~ "\n\n";

		// Try to find source files anyway
		output ~= "## Source Files\n\n";
		foreach(dirName; ["source", "src"]) {
			auto fullPath = buildPath(projectPath, dirName);
			if(!exists(fullPath))
				continue;

			foreach(entry; dirEntries(fullPath, "*.d", SpanMode.depth)) {
				auto relPath = relativePath(entry.name, projectPath);
				output ~= "- " ~ relPath ~ "\n";
			}
		}
		output ~= "\n";

		return output.data;
	}

	static string pathToModuleName(string path)
	{
		// Convert source/foo/bar.d -> foo.bar
		// Convert source/foo/package.d -> foo
		import std.algorithm.searching : startsWith;

		string p = path.replace("\\", "/");

		// Strip leading source/ or src/
		if(p.startsWith("source/"))
			p = p[7 .. $];
		else if(p.startsWith("src/"))
			p = p[4 .. $];

		if(!p.endsWith(".d"))
			return "";

		p = p[0 .. $ - 2]; // strip .d

		if(p.endsWith("/package"))
			p = p[0 .. $ - 8]; // strip /package

		return p.replace("/", ".");
	}
}
