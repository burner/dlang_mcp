/**
 * Shared DMD JSON parser for extracting structured documentation from D projects.
 *
 * Extracts functions, types, modules, and unittests from DMD's `-X` JSON output
 * with full deco type decoding, DDoc section parsing, and unittest association.
 * Used by both the `ddoc_analyze` MCP tool and the ingestion pipeline.
 */
module ingestion.ddoc_project_parser;

import std.json : JSONValue, parseJSON, JSONType;
import std.file : exists, readText, dirEntries, SpanMode, tempDir, remove,
	isFile, mkdirRecurse, rmdirRecurse;
import std.path : buildPath, absolutePath, baseName;
import std.string : strip, replace, join, startsWith, toLower, format, indexOf,
	lastIndexOf, splitLines, empty;
import std.array : appender, array;
import std.conv : text, to;
import std.algorithm.iteration : map, filter, splitter;
import std.algorithm.searching : canFind;
import std.regex : regex, matchAll;
import models.types : FunctionDoc, TypeDoc, ModuleDoc, CodeExample,
	PerformanceInfo, TemplateConstraint;
import utils.process : executeCommand, executeCommandInDir;

/** Parsed DDoc comment sections. */
struct DdocSections {
	/** First paragraph summary. */
	string summary;
	/** Named sections: "Returns", "Params", "Throws", etc. */
	string[string] sections;
}

/** Parsed originalType string components. */
struct ParsedOrigType {
	/** The return type extracted from an originalType string. */
	string returnType;
	/** Just the type portion of each parameter (names stripped). */
	string[] paramTypes;
}

/** Extracted information about a function or method. */
struct FuncInfo {
	/** Function name. */
	string name;
	/** Full built signature, e.g. "int foo(string s, int n) @safe @nogc". */
	string signature;
	/** Return type as a string. */
	string returnType;
	/** Raw DDoc comment text. */
	string docComment;
	/** All attributes as strings (e.g. "@safe", "pure", "nothrow"). */
	string[] attributes;
	/** Parameter strings, e.g. ["string s", "int n"]. */
	string[] parameters;
	/** Whether this is a template function. */
	bool isTemplate;
	/** Whether the function is marked `@safe`. */
	bool isSafe;
	/** Whether the function is marked `@nogc`. */
	bool isNogc;
	/** Whether the function is marked `nothrow`. */
	bool isNothrow;
	/** Whether the function is marked `pure`. */
	bool isPure;
	/** Inferred complexity from doc comment, e.g. "O(n)", "O(1)". */
	string timeComplexity;
	/** Source line number. */
	int line;
	/** Source file path. */
	string file;
	/** Parsed DDoc sections (summary + named sections). */
	DdocSections ddocSections;
	/** Whether a unittest was associated with this function. */
	bool hasUnittest;
	/** Line number of the associated unittest. */
	int unittestLine;
}

/** Extracted information about a type (class, struct, interface, enum). */
struct ParsedType {
	/** Type name. */
	string name;
	/** One of: "class", "struct", "interface", "enum". */
	string kind;
	/** Raw DDoc comment text. */
	string docComment;
	/** Base classes (from JSON "base" field). */
	string[] baseClasses;
	/** Implemented interfaces. */
	string[] interfaces;
	/** Methods declared within the type. */
	FuncInfo[] methods;
	/** Source line number. */
	int line;
	/** Source file path. */
	string file;
	/** Parsed DDoc sections. */
	DdocSections ddocSections;
	/** Whether a unittest was associated with this type. */
	bool hasUnittest;
	/** Line number of the associated unittest. */
	int unittestLine;
}

/** A unittest block found in a module. */
struct UnittestEntry {
	/** Line number of the unittest block. */
	int line;
	/** DDoc comment on the unittest (if any). */
	string docComment;
}

/** Extracted documentation for a single module. */
struct ParsedModule {
	/** Fully qualified module name. */
	string name;
	/** Module-level DDoc comment. */
	string docComment;
	/** Top-level functions in the module. */
	FuncInfo[] functions;
	/** Top-level types (classes, structs, interfaces, enums). */
	ParsedType[] types;
	/** Unittest blocks found in the module. */
	UnittestEntry[] unittests;
}

/** Result of running project discovery and DMD JSON generation. */
struct ProjectParseResult {
	/** Project name (from dub describe or directory name). */
	string projectName;
	/** Parsed module information. */
	ParsedModule[] modules;
	/** Error message if parsing failed, or empty on success. */
	string error;
}

/** Standard DDoc section names. */
immutable string[] ddocSectionNames = [
	"Authors", "Bugs", "Date", "Deprecated", "Examples", "History", "License",
	"Params", "Returns", "See_Also", "Standards", "Throws", "Version", "Note",
	"Warning"
];

// =====================================================================
// Project-level parsing (dub describe + DMD invocation)
// =====================================================================

/**
 * Parse a D project at the given path, extracting all module/function/type docs.
 *
 * Runs `dub describe` to discover project structure and import paths, then
 * invokes DMD with `-X` to generate JSON AST, and parses the result.
 *
 * Params:
 *     projectPath = Filesystem path to the project root (must contain dub.json or dub.sdl).
 *
 * Returns:
 *     A `ProjectParseResult` containing the parsed modules or an error message.
 */
ProjectParseResult parseProject(string projectPath)
{
	ProjectParseResult result;
	projectPath = absolutePath(projectPath);

	// Get project info from dub describe
	auto dubInfo = tryDubDescribe(projectPath);

	// Find source files and import paths
	string[] importPaths;
	string[] sourceFiles;
	string[] versionIds;
	result.projectName = baseName(projectPath);

	if(dubInfo.type != JSONType.null_) {
		extractDubInfo(dubInfo, projectPath, result.projectName, importPaths,
				sourceFiles, versionIds);
	}

	// Fallback: scan for source files if dub describe didn't provide them
	if(sourceFiles.length == 0) {
		sourceFiles = findSourceFiles(projectPath);
		if(importPaths.length == 0) {
			foreach(dir; ["source", "src"]) {
				auto fullDir = buildPath(projectPath, dir);
				if(exists(fullDir))
					importPaths ~= fullDir;
			}
		}
	}

	if(sourceFiles.length == 0) {
		result.error = "No D source files found in project at " ~ projectPath;
		return result;
	}

	// Run dmd -X to generate JSON AST
	auto jsonAst = generateDmdJson(sourceFiles, importPaths, versionIds, projectPath);
	if(jsonAst.type == JSONType.null_) {
		result.error
			= "Failed to generate DMD JSON output. The project may have compilation errors.";
		return result;
	}

	// Parse into module docs
	result.modules = parseModules(jsonAst);
	return result;
}

/**
 * Parse a D project with pre-discovered source files and import paths.
 *
 * Use this overload for non-dub projects (e.g. compiler-bundled libraries like
 * phobos, druntime) where `dub describe` is not available and the source layout
 * doesn't follow the `source/`/`src/` convention.
 *
 * Params:
 *     projectPath = Filesystem path to the source root directory.
 *     sourceFiles = Pre-discovered list of `.d` source file paths.
 *     importPaths = Import paths for the compiler (`-I` flags).
 *     compiler = Compiler to use for JSON generation (`"dmd"` or `"ldc2"`).
 *                Defaults to `"dmd"`. Must match the source files' origin —
 *                LDC's phobos contains LDC-specific extensions that DMD cannot compile.
 *
 * Returns:
 *     A `ProjectParseResult` containing the parsed modules or an error message.
 */
ProjectParseResult parseProject(string projectPath, string[] sourceFiles,
		string[] importPaths, string compiler = "dmd")
{
	ProjectParseResult result;
	projectPath = absolutePath(projectPath);
	result.projectName = baseName(projectPath);

	if(sourceFiles.length == 0) {
		result.error = "No D source files provided for project at " ~ projectPath;
		return result;
	}

	// Run compiler -X to generate JSON AST
	auto jsonAst = generateDmdJson(sourceFiles, importPaths, [], projectPath, compiler);
	if(jsonAst.type == JSONType.null_) {
		result.error = "Failed to generate JSON output from " ~ compiler
			~ ". The project may have compilation errors.";
		return result;
	}

	// Parse into module docs
	result.modules = parseModules(jsonAst);
	return result;
}

// =====================================================================
// Dub describe integration
// =====================================================================

/**
 * Try to run `dub describe` on the project and return parsed JSON.
 *
 * Params:
 *     projectPath = Path to the project root.
 *
 * Returns:
 *     Parsed JSON from dub describe, or null JSON on failure.
 */
JSONValue tryDubDescribe(string projectPath)
{
	auto result = executeCommand(["dub", "describe", "--root=" ~ projectPath]);
	if(result.status != 0 || result.output.length == 0)
		return JSONValue(null);

	try
		return parseJSON(result.output);
	catch(Exception)
		return JSONValue(null);
}

/**
 * Extract project metadata from dub describe JSON output.
 *
 * Params:
 *     desc = Parsed dub describe JSON.
 *     projectPath = Project root path for resolving relative paths.
 *     projectName = Output: project name from rootPackage.
 *     importPaths = Output: all import paths from all packages.
 *     sourceFiles = Output: source files from the root package.
 *     versionIds = Output: version identifiers from the root package.
 */
void extractDubInfo(JSONValue desc, string projectPath, ref string projectName,
		ref string[] importPaths, ref string[] sourceFiles, ref string[] versionIds)
{
	// Get project name
	if("rootPackage" in desc)
		projectName = desc["rootPackage"].str;

	if("packages" !in desc)
		return;

	// Iterate ALL packages to collect import paths (DMD needs dependency imports too)
	foreach(pkg; desc["packages"].array) {
		auto pkgName = pkg["name"].str;

		// Collect import paths from every package
		if("importPaths" in pkg && pkg["importPaths"].type == JSONType.array) {
			// Get the package's path prefix for resolving relative paths
			string pkgPath = projectPath;
			if("path" in pkg && pkg["path"].type == JSONType.string)
				pkgPath = pkg["path"].str;

			foreach(p; pkg["importPaths"].array) {
				auto ip = p.str;
				if(!ip.startsWith("/"))
					ip = buildPath(pkgPath, ip);
				importPaths ~= ip;
			}
		}

		// Only extract source files and versions from the root package
		if(pkgName != projectName)
			continue;

		// Version identifiers
		if("versions" in pkg && pkg["versions"].type == JSONType.array) {
			foreach(v; pkg["versions"].array)
				versionIds ~= v.str;
		}

		// Source files
		if("files" in pkg && pkg["files"].type == JSONType.array) {
			foreach(f; pkg["files"].array) {
				if("role" in f && f["role"].str == "source") {
					auto path = f["path"].str;
					if(!path.startsWith("/"))
						path = buildPath(projectPath, path);
					sourceFiles ~= path;
				}
			}
		}
	}
}

// =====================================================================
// Source file discovery fallback
// =====================================================================

/**
 * Scan standard D source directories for `.d` files.
 *
 * Params:
 *     projectPath = Project root path.
 *
 * Returns:
 *     Array of absolute paths to D source files found.
 */
string[] findSourceFiles(string projectPath)
{
	string[] files;
	foreach(dirName; ["source", "src"]) {
		auto fullPath = buildPath(projectPath, dirName);
		if(!exists(fullPath))
			continue;

		foreach(entry; dirEntries(fullPath, "*.d", SpanMode.depth)) {
			if(entry.isFile)
				files ~= entry.name;
		}
	}
	return files;
}

// =====================================================================
// DMD/LDC JSON generation
// =====================================================================

/**
 * Run a D compiler with `-X` to generate JSON AST output for the given source files.
 *
 * Uses the specified compiler (defaulting to `dmd`). This matters for compiler-
 * bundled libraries: LDC's phobos contains LDC-specific extensions that DMD
 * cannot compile, so LDC source files must be parsed with `ldc2`.
 *
 * Params:
 *     sourceFiles = Array of D source file paths.
 *     importPaths = Import paths for dependency resolution.
 *     versionIds = Version identifiers to define.
 *     projectPath = Project root for working directory.
 *     compiler = Compiler to use (`"dmd"` or `"ldc2"`). Defaults to `"dmd"`.
 *
 * Returns:
 *     Parsed JSON from compiler output, or null JSON on failure.
 */
JSONValue generateDmdJson(string[] sourceFiles, string[] importPaths,
		string[] versionIds, string projectPath, string compiler = "dmd")
{
	import std.uuid : randomUUID;

	auto id = randomUUID().toString();

	// Create temp file for JSON output
	auto tmpFile = buildPath(tempDir(), "dlang_mcp_ddoc_" ~ id ~ ".json");
	// Create temp directory for ddoc HTML output (discarded, but -D is required
	// for comment fields to appear in JSON; using -Dd avoids file collisions
	// when compiling multiple modules that share package.d names)
	auto tmpDdocDir = buildPath(tempDir(), "dlang_mcp_ddoc_html_" ~ id);
	mkdirRecurse(tmpDdocDir);
	scope(exit) {
		import std.exception : collectException;

		if(exists(tmpFile))
			collectException(remove(tmpFile));
		if(exists(tmpDdocDir))
			collectException(rmdirRecurse(tmpDdocDir));
	}

	// Build compiler command
	string[] cmd = [compiler];
	cmd ~= "-X";
	cmd ~= "-Xf=" ~ tmpFile;
	cmd ~= "-o-"; // don't generate object files
	cmd ~= "-c"; // compile only
	cmd ~= "-D"; // enable ddoc generation (required for comment fields in JSON)
	cmd ~= "-Dd" ~ tmpDdocDir; // write ddoc HTML to temp dir (discarded)

	// Add import paths
	foreach(ip; importPaths)
		cmd ~= "-I" ~ ip;

	// Add version identifiers
	foreach(v; versionIds)
		cmd ~= "-version=" ~ v;

	// Add source files
	foreach(f; sourceFiles)
		cmd ~= f;

	executeCommandInDir(cmd, projectPath);

	if(exists(tmpFile)) {
		try {
			auto content = readText(tmpFile);
			return parseJSON(content);
		} catch(Exception) {
			return JSONValue(null);
		}
	}

	return JSONValue(null);
}

// =====================================================================
// DDoc section parsing
// =====================================================================

/**
 * Parse a DDoc comment string into structured sections.
 *
 * Extracts the summary paragraph and named sections like Params, Returns,
 * Throws, etc.
 *
 * Params:
 *     comment = The raw DDoc comment text.
 *
 * Returns:
 *     A `DdocSections` with the parsed summary and named sections.
 */
DdocSections parseDdocSections(string comment)
{
	DdocSections result;
	if(comment.length == 0)
		return result;

	auto lines = comment.splitLines();
	string currentSection = "";
	auto sectionContent = appender!string;
	bool inSummary = true;
	auto summaryBuf = appender!string;

	foreach(rawLine; lines) {
		auto line = rawLine.strip();

		// Check if this line starts a new section
		string foundSection = "";
		foreach(sname; ddocSectionNames) {
			if(line.length > sname.length && line[0 .. sname.length] == sname
					&& line[sname.length] == ':') {
				foundSection = sname;
				break;
			}
		}

		if(foundSection.length > 0) {
			// Save previous section
			if(currentSection.length > 0)
				result.sections[currentSection] = sectionContent.data.strip();
			else if(inSummary) {
				result.summary = summaryBuf.data.strip();
				inSummary = false;
			}

			currentSection = foundSection;
			sectionContent = appender!string;
			// Content after the colon on the same line
			auto colonIdx = line.indexOf(':');
			if(colonIdx >= 0 && colonIdx + 1 < cast(ptrdiff_t)line.length)
				sectionContent ~= line[colonIdx + 1 .. $].strip();
		} else if(currentSection.length > 0) {
			if(sectionContent.data.length > 0)
				sectionContent ~= "\n";
			sectionContent ~= rawLine;
		} else if(inSummary) {
			if(line.length == 0 && summaryBuf.data.length > 0) {
				result.summary = summaryBuf.data.strip();
				inSummary = false;
			} else if(line.length > 0) {
				if(summaryBuf.data.length > 0)
					summaryBuf ~= " ";
				summaryBuf ~= line;
			}
		}
	}

	// Finalize
	if(currentSection.length > 0)
		result.sections[currentSection] = sectionContent.data.strip();
	if(inSummary && summaryBuf.data.length > 0)
		result.summary = summaryBuf.data.strip();

	return result;
}

// =====================================================================
// originalType parsing
// =====================================================================

/**
 * Parse an originalType string like "pure nothrow @nogc @safe size_t(string s, string t)".
 *
 * Params:
 *     origType = The originalType field from DMD JSON.
 *
 * Returns:
 *     A `ParsedOrigType` with extracted return type and parameter types.
 */
ParsedOrigType parseOriginalType(string origType)
{
	ParsedOrigType result;
	if(origType.length == 0)
		return result;

	// Find the opening paren for parameters
	auto parenIdx = origType.indexOf('(');
	if(parenIdx < 0)
		return result;

	// Everything before '(' is attrs + return type
	// Strip known attributes from the prefix
	string prefix = origType[0 .. parenIdx].strip();
	static immutable string[] knownAttrs = [
		"pure", "nothrow", "@nogc", "@safe", "@trusted", "@system", "ref",
		"const", "immutable", "inout", "shared"
	];

	// Repeatedly strip leading known attributes
	bool changed = true;
	while(changed) {
		changed = false;
		prefix = prefix.strip();
		foreach(attr; knownAttrs) {
			if(prefix.length >= attr.length && prefix[0 .. attr.length] == attr) {
				// Make sure it's a whole word (followed by space or end)
				if(prefix.length == attr.length || prefix[attr.length] == ' ') {
					prefix = prefix[attr.length .. $];
					changed = true;
					break;
				}
			}
		}
	}
	result.returnType = prefix.strip();

	// Parse parameters between parens
	auto closeIdx = origType.lastIndexOf(')');
	if(closeIdx <= parenIdx)
		return result;

	string paramStr = origType[parenIdx + 1 .. closeIdx];
	result.paramTypes = splitParamTypes(paramStr);

	return result;
}

/**
 * Split parameter string by commas respecting nested parens, then extract just the type.
 *
 * Params:
 *     paramStr = The comma-separated parameter string.
 *
 * Returns:
 *     Array of type-only strings.
 */
string[] splitParamTypes(string paramStr)
{
	string[] result;
	if(paramStr.strip().length == 0)
		return result;

	int depth = 0;
	size_t start = 0;

	for(size_t i = 0; i < paramStr.length; i++) {
		auto ch = paramStr[i];
		if(ch == '(' || ch == '[')
			depth++;
		else if(ch == ')' || ch == ']')
			depth--;
		else if(ch == ',' && depth == 0) {
			auto param = paramStr[start .. i].strip();
			if(param.length > 0)
				result ~= extractParamType(param);
			start = i + 1;
		}
	}
	// Last parameter
	auto last = paramStr[start .. $].strip();
	if(last.length > 0)
		result ~= extractParamType(last);

	return result;
}

/**
 * Extract just the type portion from a "type name" parameter string.
 * e.g. "string s" -> "string", "const(char)[] buf" -> "const(char)[]"
 *
 * Params:
 *     param = A single parameter declaration string.
 *
 * Returns:
 *     The type portion of the parameter.
 */
string extractParamType(string param)
{
	// Find last space that isn't inside parens/brackets - that separates type from name
	int depth = 0;
	ptrdiff_t lastSpace = -1;
	for(size_t i = 0; i < param.length; i++) {
		auto ch = param[i];
		if(ch == '(' || ch == '[')
			depth++;
		else if(ch == ')' || ch == ']')
			depth--;
		else if(ch == ' ' && depth == 0)
			lastSpace = cast(ptrdiff_t)i;
	}
	if(lastSpace > 0)
		return param[0 .. lastSpace].strip();
	return param; // Couldn't split, return as-is
}

// =====================================================================
// JSON parsing into module structures
// =====================================================================

/**
 * Parse DMD `-X` JSON output into structured module information.
 *
 * Params:
 *     json = The parsed JSON array from DMD's `-X` output.
 *
 * Returns:
 *     Array of `ParsedModule` with functions, types, and unittests extracted.
 */
ParsedModule[] parseModules(JSONValue json)
{
	ParsedModule[] modules;

	if(json.type != JSONType.array)
		return modules;

	foreach(item; json.array) {
		if("kind" !in item || item["kind"].str != "module")
			continue;

		ParsedModule mod;
		mod.name = ("name" in item) ? item["name"].str : "";
		mod.docComment = extractComment(item);

		if("members" in item && item["members"].type == JSONType.array) {
			foreach(member; item["members"].array) {
				if("kind" !in member)
					continue;

				auto kind = member["kind"].str;
				auto memberName = ("name" in member) ? member["name"].str : "";

				switch(kind) {
				case "function":
					// Check if this is a unittest block
					if(memberName.startsWith("__unittest")) {
						int utLine = 0;
						if("line" in member && member["line"].type == JSONType.integer)
							utLine = cast(int)member["line"].integer;
						if(utLine > 0)
							mod.unittests ~= UnittestEntry(utLine, extractComment(member));
					} else {
						mod.functions ~= parseFunction(member);
					}
					break;
				case "class":
				case "struct":
				case "interface":
				case "enum":
					mod.types ~= parseType(member);
					break;
				default:
					break;
				}
			}
		}

		// Associate unittests with nearest preceding declaration
		associateUnittests(mod);

		if(mod.name.length > 0)
			modules ~= mod;
	}

	return modules;
}

/**
 * Associate unittest entries with the nearest preceding function or type by line number.
 *
 * Params:
 *     mod = The module whose unittests should be associated.
 */
void associateUnittests(ref ParsedModule mod)
{
	foreach(ref ut; mod.unittests) {
		int bestDist = int.max;
		FuncInfo* bestFunc = null;
		ParsedType* bestType = null;

		foreach(ref f; mod.functions) {
			if(f.line > 0 && f.line < ut.line) {
				int dist = ut.line - f.line;
				if(dist < bestDist) {
					bestDist = dist;
					bestFunc = &f;
					bestType = null;
				}
			}
		}
		foreach(ref t; mod.types) {
			if(t.line > 0 && t.line < ut.line) {
				int dist = ut.line - t.line;
				if(dist < bestDist) {
					bestDist = dist;
					bestType = &t;
					bestFunc = null;
				}
			}
		}

		if(bestFunc !is null) {
			bestFunc.hasUnittest = true;
			bestFunc.unittestLine = ut.line;
		}
		if(bestType !is null) {
			bestType.hasUnittest = true;
			bestType.unittestLine = ut.line;
		}
	}
}

/**
 * Parse a function member from DMD JSON into a `FuncInfo`.
 *
 * Params:
 *     json = The JSON object for a function member.
 *
 * Returns:
 *     A populated `FuncInfo`.
 */
FuncInfo parseFunction(JSONValue json)
{
	FuncInfo func;
	func.name = ("name" in json) ? json["name"].str : "";
	func.docComment = extractComment(json);
	func.isTemplate = ("templateParameters" in json.object) !is null;

	// Source location
	if("line" in json && json["line"].type == JSONType.integer)
		func.line = cast(int)json["line"].integer;
	if("file" in json && json["file"].type == JSONType.string)
		func.file = json["file"].str;

	// Return type
	if("returnType" in json)
		func.returnType = json["returnType"].str;
	else if("type" in json) {
		auto parts = splitWords(json["type"].str);
		func.returnType = parts.length > 0 ? parts[0] : "";
	}

	// Parameters
	if("parameters" in json && json["parameters"].type == JSONType.array) {
		foreach(param; json["parameters"].array) {
			string p;
			if("storageClass" in param && param["storageClass"].type == JSONType.array) {
				auto sc = param["storageClass"].array.map!(j => j.str).join(" ");
				if(sc.length > 0)
					p ~= sc ~ " ";
			}
			if("type" in param)
				p ~= param["type"].str;
			if("name" in param)
				p ~= " " ~ param["name"].str;
			func.parameters ~= p.strip();
		}
	}

	// Enrich parameters from originalType if they lack type info
	enrichFromOriginalType(func, json);

	// Attributes
	if("attributes" in json && json["attributes"].type == JSONType.array) {
		foreach(attr; json["attributes"].array) {
			string attrStr = attr.str;
			func.attributes ~= attrStr;

			auto lower = attrStr.toLower.strip;
			if(lower == "@nogc" || lower == "nogc")
				func.isNogc = true;
			else if(lower == "@nothrow" || lower == "nothrow")
				func.isNothrow = true;
			else if(lower == "pure")
				func.isPure = true;
			else if(lower == "@safe" || lower == "safe")
				func.isSafe = true;
		}
	}

	// Fallback: extract attributes from deco mangling if not found in attributes array
	if(!func.isSafe && !func.isNogc && !func.isNothrow && !func.isPure) {
		if("deco" in json && json["deco"].type == JSONType.string) {
			auto deco = json["deco"].str;
			extractAttributesFromDeco(func, deco);
		}
	}

	// Build signature
	func.signature = buildFuncSignature(func);

	// Infer time complexity from doc comment
	func.timeComplexity = inferComplexity(func.docComment);

	// Parse ddoc sections
	func.ddocSections = parseDdocSections(func.docComment);

	return func;
}

/**
 * Enrich function parameters and return type from the originalType field
 * or from deco type mangling when the parameters array lacks type info.
 *
 * Params:
 *     func = The function to enrich (modified in place).
 *     json = The JSON object for the function.
 */
void enrichFromOriginalType(ref FuncInfo func, JSONValue json)
{
	// Check if parameters lack types (just names with no spaces)
	bool paramsLackTypes = false;
	if(func.parameters.length > 0) {
		foreach(ref p; func.parameters) {
			if(p.indexOf(' ') < 0) {
				paramsLackTypes = true;
				break;
			}
		}
	}

	// Strategy 1: Try originalType if available
	if("originalType" in json && json["originalType"].type == JSONType.string) {
		auto parsed = parseOriginalType(json["originalType"].str);

		// Fill in return type if missing
		if(func.returnType.length == 0 && parsed.returnType.length > 0)
			func.returnType = parsed.returnType;

		if(paramsLackTypes && parsed.paramTypes.length == func.parameters.length) {
			for(size_t i = 0; i < func.parameters.length; i++) {
				if(func.parameters[i].indexOf(' ') < 0)
					func.parameters[i] = parsed.paramTypes[i] ~ " " ~ func.parameters[i];
			}
			return; // Success
		}
	}

	// Strategy 2: Decode deco on individual parameters
	if(paramsLackTypes && "parameters" in json && json["parameters"].type == JSONType.array) {
		auto params = json["parameters"].array;
		if(params.length == func.parameters.length) {
			for(size_t i = 0; i < func.parameters.length; i++) {
				if(func.parameters[i].indexOf(' ') < 0 && "deco" in params[i]
						&& params[i]["deco"].type == JSONType.string) {
					auto decoded = decodeDeco(params[i]["deco"].str);
					if(decoded.length > 0)
						func.parameters[i] = decoded ~ " " ~ func.parameters[i];
				}
			}
		}
	}

	// Also try to decode the function's return type from deco if still missing
	if(func.returnType.length == 0 && "deco" in json && json["deco"].type == JSONType.string) {
		auto funcDeco = json["deco"].str;
		auto retType = decodeFuncReturnType(funcDeco);
		if(retType.length > 0)
			func.returnType = retType;
	}
}

// =====================================================================
// Deco (type mangling) decoder
// =====================================================================

/**
 * Extract function attributes (pure, nothrow, @nogc, @safe, @trusted)
 * from a DMD deco (type mangling) string.
 *
 * In the deco format, function types start with 'F' and attributes are
 * encoded as two-character 'N' sequences:
 *   Na = pure, Nb = nothrow, Nc = ref, Nd = @system,
 *   Ne = @trusted, Nf = @safe, Ni = @nogc
 *
 * Params:
 *     func = The FuncInfo to update (modified in place).
 *     deco = The function's deco string.
 */
void extractAttributesFromDeco(ref FuncInfo func, string deco)
{
	for(size_t i = 0; i < deco.length; i++) {
		if(deco[i] == 'N' && i + 1 < deco.length) {
			switch(deco[i + 1]) {
			case 'a':
				func.isPure = true;
				if(!func.attributes.canFind("pure"))
					func.attributes ~= "pure";
				i++;
				break;
			case 'b':
				func.isNothrow = true;
				if(!func.attributes.canFind("nothrow"))
					func.attributes ~= "nothrow";
				i++;
				break;
			case 'i':
				func.isNogc = true;
				if(!func.attributes.canFind("@nogc"))
					func.attributes ~= "@nogc";
				i++;
				break;
			case 'f':
				func.isSafe = true;
				if(!func.attributes.canFind("@safe"))
					func.attributes ~= "@safe";
				i++;
				break;
			case 'e':
				if(!func.attributes.canFind("@trusted"))
					func.attributes ~= "@trusted";
				i++;
				break;
			default:
				break;
			}
		}
		// Stop scanning after 'Z' (return type separator) to avoid
		// misinterpreting return type mangling as attributes.
		if(deco[i] == 'Z')
			break;
	}
}

/**
 * Decode a DMD type deco (mangled type) string into a human-readable type.
 * Handles common primitive types and simple composite types.
 *
 * Params:
 *     deco = The mangled type string.
 *
 * Returns:
 *     A human-readable type string, or empty on failure.
 */
string decodeDeco(string deco)
{
	if(deco.length == 0)
		return "";

	size_t pos = 0;
	auto raw = decodeType(deco, pos);
	return normalizeTypeAliases(raw);
}

/**
 * Normalize common D type aliases for readability.
 * e.g. "immutable(char)[]" -> "string"
 *
 * Params:
 *     t = The type string to normalize.
 *
 * Returns:
 *     The normalized type string.
 */
string normalizeTypeAliases(string t)
{
	if(t.length == 0)
		return t;

	t = t.replace("immutable(dchar)[]", "dstring");
	t = t.replace("immutable(wchar)[]", "wstring");
	t = t.replace("immutable(char)[]", "string");

	return t;
}

/** Decode a single type from the deco string starting at pos. */
string decodeType(string deco, ref size_t pos)
{
	if(pos >= deco.length)
		return "";

	char c = deco[pos];
	pos++;

	switch(c) {
		// Basic types
	case 'v':
		return "void";
	case 'g':
		return "byte";
	case 'h':
		return "ubyte";
	case 's':
		return "short";
	case 't':
		return "ushort";
	case 'i':
		return "int";
	case 'k':
		return "uint";
	case 'l':
		return "long";
	case 'm':
		return "ulong";
	case 'f':
		return "float";
	case 'd':
		return "double";
	case 'e':
		return "real";
	case 'b':
		return "bool";
	case 'a':
		return "char";
	case 'u':
		return "wchar";
	case 'w':
		return "dchar";
	case 'n':
		return "typeof(null)";

		// Derived types
	case 'A': // dynamic array
	{
			auto elem = decodeType(deco, pos);
			return elem ~ "[]";
		}
	case 'G': // static array — GnT where n is length
	{
			auto lenStr = appender!string;
			while(pos < deco.length && deco[pos] >= '0' && deco[pos] <= '9') {
				lenStr ~= deco[pos];
				pos++;
			}
			auto elem = decodeType(deco, pos);
			return elem ~ "[" ~ lenStr.data ~ "]";
		}
	case 'H': // associative array — HVK (value, key)
	{
			auto value = decodeType(deco, pos);
			auto key = decodeType(deco, pos);
			return value ~ "[" ~ key ~ "]";
		}
	case 'P': // pointer
	{
			auto pointee = decodeType(deco, pos);
			return pointee ~ "*";
		}
	case 'E': // enum — qualified name follows
	case 'S': // struct
	case 'C': // class
	case 'I': // interface
		return decodeQualifiedName(deco, pos);

	case 'x': // const
	{
			auto inner = decodeType(deco, pos);
			return "const(" ~ inner ~ ")";
		}
	case 'y': // immutable
	{
			auto inner = decodeType(deco, pos);
			return "immutable(" ~ inner ~ ")";
		}
	case 'O': // shared
	{
			auto inner = decodeType(deco, pos);
			return "shared(" ~ inner ~ ")";
		}

	case 'N': // Various N-prefixed types
	{
			if(pos >= deco.length)
				return "";
			char n = deco[pos];
			pos++;
			switch(n) {
			case 'g': // inout
			{
					auto inner = decodeType(deco, pos);
					return "inout(" ~ inner ~ ")";
				}
			default:
				return ""; // Unknown N-prefix
			}
		}

		// Q-backreference (repeated type)
	case 'Q':
		// Skip backreference — too complex for simple decoder
		if(pos < deco.length)
			pos++;
		return "auto";

	default:
		return ""; // Unknown type char
	}
}

/** Decode a LEB128-length-prefixed qualified name from deco. */
string decodeQualifiedName(string deco, ref size_t pos)
{
	auto result = appender!string;
	bool first = true;

	while(pos < deco.length && deco[pos] >= '0' && deco[pos] <= '9') {
		// Read length
		size_t len = 0;
		while(pos < deco.length && deco[pos] >= '0' && deco[pos] <= '9') {
			len = len * 10 + (deco[pos] - '0');
			pos++;
		}

		if(pos + len > deco.length)
			break;

		if(!first)
			result ~= ".";
		result ~= deco[pos .. pos + len];
		pos += len;
		first = false;
	}

	if(result.data.length > 0) {
		// Return just the last component (short name) for readability
		auto full = result.data;
		auto dotIdx = full.lastIndexOf('.');
		if(dotIdx >= 0)
			return full[dotIdx + 1 .. $];
		return full;
	}
	return "";
}

/**
 * Try to extract return type from a function deco string.
 * Function deco format: F[params]Z[returnType]
 *
 * Params:
 *     deco = The function's deco string.
 *
 * Returns:
 *     The decoded return type, or empty on failure.
 */
string decodeFuncReturnType(string deco)
{
	if(deco.length == 0)
		return "";

	size_t pos = 0;

	// Skip attribute prefixes (Na=pure, Nb=nothrow, Nc=ref, Nd=@nogc, Nf=@safe, etc)
	while(pos < deco.length) {
		if(deco[pos] == 'F') {
			pos++; // skip F
			break;
		} else if(deco[pos] == 'N' && pos + 1 < deco.length) {
			pos += 2; // skip N + qualifier char
		} else {
			pos++;
		}
	}

	// Find 'Z' that separates params from return type
	while(pos < deco.length) {
		if(deco[pos] == 'Z') {
			pos++; // skip Z
			return normalizeTypeAliases(decodeType(deco, pos));
		}
		pos++;
	}

	return "";
}

// =====================================================================
// Signature building
// =====================================================================

/**
 * Build a human-readable function signature from parsed FuncInfo.
 *
 * Params:
 *     func = The function information.
 *
 * Returns:
 *     A signature string like "int foo(string s, int n) @safe @nogc".
 */
string buildFuncSignature(ref const FuncInfo func)
{
	auto sig = appender!string;

	if(func.returnType.length > 0)
		sig ~= func.returnType ~ " ";

	sig ~= func.name;
	sig ~= "(";
	sig ~= func.parameters.join(", ");
	sig ~= ")";

	// Append key attributes
	string[] keyAttrs;
	if(func.isSafe)
		keyAttrs ~= "@safe";
	if(func.isNogc)
		keyAttrs ~= "@nogc";
	if(func.isNothrow)
		keyAttrs ~= "nothrow";
	if(func.isPure)
		keyAttrs ~= "pure";

	if(keyAttrs.length > 0)
		sig ~= " " ~ keyAttrs.join(" ");

	return sig.data;
}

// =====================================================================
// Type parsing
// =====================================================================

/**
 * Parse a type member from DMD JSON into a `ParsedType`.
 *
 * Params:
 *     json = The JSON object for a type member.
 *
 * Returns:
 *     A populated `ParsedType`.
 */
ParsedType parseType(JSONValue json)
{
	ParsedType t;
	t.name = ("name" in json) ? json["name"].str : "";
	t.kind = ("kind" in json) ? json["kind"].str : "";
	t.docComment = extractComment(json);

	// Source location
	if("line" in json && json["line"].type == JSONType.integer)
		t.line = cast(int)json["line"].integer;
	if("file" in json && json["file"].type == JSONType.string)
		t.file = json["file"].str;

	if("base" in json)
		t.baseClasses ~= json["base"].str;

	if("interfaces" in json && json["interfaces"].type == JSONType.array) {
		foreach(iface; json["interfaces"].array)
			t.interfaces ~= iface.str;
	}

	// Parse methods
	if("members" in json && json["members"].type == JSONType.array) {
		foreach(member; json["members"].array) {
			if("kind" in member && member["kind"].str == "function")
				t.methods ~= parseFunction(member);
		}
	}

	// Parse ddoc sections
	t.ddocSections = parseDdocSections(t.docComment);

	return t;
}

// =====================================================================
// Utility functions
// =====================================================================

/**
 * Extract the comment field from a DMD JSON element.
 *
 * Params:
 *     json = A JSON object that may contain a "comment" field.
 *
 * Returns:
 *     The stripped comment text, or empty string if absent.
 */
string extractComment(JSONValue json)
{
	if("comment" !in json)
		return "";

	string comment = json["comment"].str;
	return comment.strip();
}

/**
 * Infer time complexity from a documentation comment.
 *
 * Params:
 *     doc = The documentation comment text.
 *
 * Returns:
 *     A Big-O notation string, or empty if no complexity was found.
 */
string inferComplexity(string doc)
{
	if(doc.length == 0)
		return "";

	auto lower = doc.toLower;

	if(lower.canFind("o(n log n)") || lower.canFind("o(nlogn)"))
		return "O(n log n)";
	else if(lower.canFind("o(n²)") || lower.canFind("o(n^2)"))
		return "O(n²)";
	else if(lower.canFind("o(n)") || lower.canFind("linear time"))
		return "O(n)";
	else if(lower.canFind("o(1)") || lower.canFind("constant time"))
		return "O(1)";

	return "";
}

/** Split a string by whitespace into non-empty words. */
string[] splitWords(string s)
{
	string[] result;
	foreach(part; s.splitter(' ')) {
		if(part.length > 0)
			result ~= part;
	}
	return result;
}

// =====================================================================
// Conversion functions: parser structs -> models.types structs
// =====================================================================

/**
 * Convert a `FuncInfo` (parser struct) to a `FunctionDoc` (model struct).
 *
 * Params:
 *     func = The parsed function information.
 *     moduleName = Fully qualified module name for building FQN.
 *     packageName = The package name.
 *
 * Returns:
 *     A populated `FunctionDoc` ready for CRUD storage.
 */
FunctionDoc toFunctionDoc(ref const FuncInfo func, string moduleName, string packageName)
{
	FunctionDoc doc;
	doc.name = func.name;
	doc.fullyQualifiedName = moduleName ~ "." ~ func.name;
	doc.moduleName = moduleName;
	doc.packageName = packageName;
	doc.signature = func.signature;
	doc.returnType = func.returnType;
	doc.parameters = func.parameters.dup;
	doc.docComment = func.docComment;
	doc.isTemplate = func.isTemplate;

	// Extract code examples from doc comment
	doc.examples = extractDocExamples(func.docComment);

	// Performance attributes
	doc.performance.isSafe = func.isSafe;
	doc.performance.isNogc = func.isNogc;
	doc.performance.isNothrow = func.isNothrow;
	doc.performance.isPure = func.isPure;
	doc.performance.timeComplexity = func.timeComplexity;

	return doc;
}

/**
 * Convert a `ParsedType` (parser struct) to a `TypeDoc` (model struct).
 *
 * Params:
 *     type = The parsed type information.
 *     moduleName = Fully qualified module name for building FQN.
 *     packageName = The package name.
 *
 * Returns:
 *     A populated `TypeDoc` ready for CRUD storage.
 */
TypeDoc toTypeDoc(ref const ParsedType type, string moduleName, string packageName)
{
	TypeDoc doc;
	doc.name = type.name;
	doc.fullyQualifiedName = moduleName ~ "." ~ type.name;
	doc.moduleName = moduleName;
	doc.packageName = packageName;
	doc.kind = type.kind;
	doc.docComment = type.docComment;
	doc.baseClasses = type.baseClasses.dup;
	doc.interfaces = type.interfaces.dup;

	// Convert methods recursively
	foreach(ref m; type.methods) {
		auto fqn = moduleName ~ "." ~ type.name;
		doc.methods ~= toFunctionDoc(m, fqn, packageName);
	}

	return doc;
}

/**
 * Convert a `ParsedModule` (parser struct) to a `ModuleDoc` (model struct).
 *
 * Params:
 *     mod = The parsed module information.
 *     packageName = The package name.
 *
 * Returns:
 *     A populated `ModuleDoc` ready for CRUD storage.
 */
ModuleDoc toModuleDoc(ref const ParsedModule mod, string packageName)
{
	ModuleDoc doc;
	doc.name = mod.name;
	doc.packageName = packageName;
	doc.docComment = mod.docComment;

	foreach(ref f; mod.functions)
		doc.functions ~= toFunctionDoc(f, mod.name, packageName);

	foreach(ref t; mod.types)
		doc.types ~= toTypeDoc(t, mod.name, packageName);

	return doc;
}

// =====================================================================
// Source-level unittest block extraction (from enhanced_parser.d)
// =====================================================================

/**
 * Extract unittest blocks from a D source file as runnable code examples.
 *
 * Uses regex to locate `unittest { ... }` blocks in the raw source text,
 * then extracts their bodies with balanced-brace matching.
 *
 * Params:
 *     sourceFile = Path to the D source file.
 *     packageName = The package name (for metadata on the returned examples).
 *
 * Returns:
 *     An array of `CodeExample` records, one per unittest block found.
 */
CodeExample[] extractUnittestBlocks(string sourceFile, string packageName)
{
	if(!exists(sourceFile) || !isFile(sourceFile))
		return [];

	string content;
	try
		content = readText(sourceFile);
	catch(Exception)
		return [];

	return parseUnittestsFromSource(content, packageName);
}

/**
 * Parse unittest blocks from D source text.
 *
 * Params:
 *     source = The full source text of a D file.
 *     packageName = The package name for metadata.
 *
 * Returns:
 *     An array of `CodeExample` records.
 */
CodeExample[] parseUnittestsFromSource(string source, string packageName)
{
	CodeExample[] examples;

	auto re = regex(r"unittest\s*\{", "g");
	auto matches = matchAll(source, re);

	foreach(match; matches) {
		auto startPos = match.pre.length + match.hit.length;
		auto code = extractBalancedBraces(source[startPos .. $]);

		if(code.length > 0) {
			CodeExample ex;
			ex.code = code;
			ex.description = "Unit test";
			ex.isUnittest = true;
			ex.isRunnable = true;
			ex.requiredImports = extractImportsFromCode(code);
			ex.packageId = 0;
			examples ~= ex;
		}
	}

	return examples;
}

/**
 * Extract content inside balanced braces (assumes opening brace already consumed).
 *
 * Params:
 *     source = Source text starting just after the opening brace.
 *
 * Returns:
 *     The text between the (already-consumed) opening brace and its matching
 *     closing brace, stripped of leading/trailing whitespace.
 */
string extractBalancedBraces(string source)
{
	int braceCount = 1;
	size_t pos = 0;

	while(pos < source.length && braceCount > 0) {
		if(source[pos] == '{')
			braceCount++;
		else if(source[pos] == '}')
			braceCount--;
		pos++;
	}

	if(braceCount == 0 && pos > 0)
		return source[0 .. pos - 1].strip();

	return "";
}

/**
 * Extract import module names from a code snippet.
 *
 * Params:
 *     code = D source code snippet.
 *
 * Returns:
 *     Array of module name strings found in import statements.
 */
string[] extractImportsFromCode(string code)
{
	string[] imports;
	auto re = regex(r"import\s+([\w.]+)(?:\s*:\s*([\w,\s]+))?;", "g");

	foreach(match; matchAll(code, re))
		imports ~= match.captures[1];

	return imports;
}

/**
 * Analyze a D source file and return its import dependencies.
 *
 * Params:
 *     sourceFile = Path to the D source file.
 *
 * Returns:
 *     Array of module name strings that the source file imports.
 */
string[] analyzeImportRequirements(string sourceFile)
{
	if(!exists(sourceFile))
		return [];

	try {
		auto content = readText(sourceFile);
		return extractImportsFromCode(content);
	} catch(Exception)
		return [];
}

// =====================================================================
// Doc comment example extraction (from ddoc_parser.d)
// =====================================================================

/**
 * Extract code examples from a DDoc comment.
 *
 * Looks for `Example:` / `Examples:` sections and `---` delimited code blocks.
 *
 * Params:
 *     docComment = The raw documentation comment text.
 *
 * Returns:
 *     Array of code example strings.
 */
string[] extractDocExamples(string docComment)
{
	string[] examples;
	if(docComment.length == 0)
		return examples;

	bool inCodeBlock = false;
	auto currentExample = appender!string;

	foreach(line; docComment.splitter("\n")) {
		auto trimmed = line.strip();

		if(trimmed.startsWith("---")) {
			if(inCodeBlock) {
				// Closing delimiter — save the accumulated example
				if(currentExample.data.length > 0) {
					examples ~= currentExample.data.strip();
				}
				currentExample = appender!string;
				inCodeBlock = false;
			} else {
				// Opening delimiter — start capturing
				currentExample = appender!string;
				inCodeBlock = true;
			}
		} else if(inCodeBlock) {
			currentExample ~= line ~ "\n";
		}
	}

	// Handle unterminated code block
	if(inCodeBlock && currentExample.data.length > 0)
		examples ~= currentExample.data.strip();

	return examples;
}
