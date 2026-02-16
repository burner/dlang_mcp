/**
 * MCP tool for compile-checking D source code without linking.
 *
 * Runs DMD or LDC2 with the `-c` flag to detect type errors, syntax errors,
 * undefined identifiers, and other compile-time issues. Supports both inline
 * code snippets and file paths, with optional dub project integration for
 * automatic import path resolution.
 */
module tools.compile_check;

import std.json : JSONValue, parseJSON, JSONType;
import std.file : exists, write, remove, tempDir, readText;
import std.path : buildPath, absolutePath, baseName;
import std.string : strip, indexOf, startsWith, endsWith, format, toLower;
import std.array : appender, array, split;
import std.conv : text, to;
import std.algorithm.iteration : map, filter;
import std.algorithm.searching : canFind;
import tools.base : BaseTool;
import mcp.types : ToolResult;
import utils.process : executeCommandInDir, executeCommand, ProcessResult;

/**
 * Tool that compile-checks D source code and returns structured diagnostics.
 *
 * Accepts either inline source code or a file path. When a dub project path
 * is provided, automatically resolves import paths and version identifiers
 * from the project configuration.
 */
class CompileCheckTool : BaseTool
{
    @property string name()
    {
        return "compile_check";
    }

    @property string description()
    {
        return "Compile-check D source code without linking. Runs dmd or ldc2 with -c flag to "
            ~ "detect type errors, syntax errors, undefined identifiers, and other compile-time "
            ~ "issues. Returns structured error/warning list with file, line, column, and message. "
            ~ "Accepts either inline code or a file path.";
    }

    @property JSONValue inputSchema()
    {
        return parseJSON(`{
            "type": "object",
            "properties": {
                "code": {
                    "type": "string",
                    "description": "D source code to compile-check"
                },
                "file_path": {
                    "type": "string",
                    "description": "Path to a D source file to compile-check (alternative to code)"
                },
                "compiler": {
                    "type": "string",
                    "enum": ["dmd", "ldc2"],
                    "default": "dmd",
                    "description": "Which D compiler to use"
                },
                "import_paths": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Additional import paths (-I flags)"
                },
                "string_imports": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "String import paths (-J flags)"
                },
                "versions": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Version identifiers to define (-version=X)"
                },
                "dub_project": {
                    "type": "string",
                    "description": "Path to a dub project. If provided, import paths and versions are auto-detected from dub describe"
                }
            }
        }`);
    }

    ToolResult execute(JSONValue arguments)
    {
        try
        {
            string code;
            string filePath;
            bool hasCode = "code" in arguments && arguments["code"].type == JSONType.string;
            bool hasFile = "file_path" in arguments && arguments["file_path"].type == JSONType.string;

            if (!hasCode && !hasFile)
            {
                return createErrorResult("Either 'code' or 'file_path' parameter is required");
            }

            string compiler = "dmd";
            if ("compiler" in arguments && arguments["compiler"].type == JSONType.string)
            {
                compiler = arguments["compiler"].str;
                if (compiler != "dmd" && compiler != "ldc2")
                    return createErrorResult("Compiler must be 'dmd' or 'ldc2'");
            }

            // Build command
            string[] cmd = [compiler, "-c", "-o-"]; // compile-only, no output file

            // Auto-detect from dub project
            if ("dub_project" in arguments && arguments["dub_project"].type == JSONType.string)
            {
                addDubImportPaths(cmd, arguments["dub_project"].str);
            }

            // Manual import paths
            if ("import_paths" in arguments && arguments["import_paths"].type == JSONType.array)
            {
                foreach (p; arguments["import_paths"].array)
                {
                    if (p.type == JSONType.string)
                        cmd ~= ["-I" ~ p.str];
                }
            }

            // String import paths
            if ("string_imports" in arguments && arguments["string_imports"].type == JSONType.array)
            {
                foreach (p; arguments["string_imports"].array)
                {
                    if (p.type == JSONType.string)
                        cmd ~= ["-J" ~ p.str];
                }
            }

            // Version identifiers
            if ("versions" in arguments && arguments["versions"].type == JSONType.array)
            {
                foreach (v; arguments["versions"].array)
                {
                    if (v.type == JSONType.string)
                        cmd ~= ["-version=" ~ v.str];
                }
            }

            string tempPath;

            if (hasFile)
            {
                filePath = arguments["file_path"].str;
                if (!exists(filePath))
                {
                    filePath = absolutePath(filePath);
                    if (!exists(filePath))
                        return createErrorResult("File not found: " ~ arguments["file_path"].str);
                }
                cmd ~= filePath;
            }
            else
            {
                code = arguments["code"].str;
                // Write to temp file with a valid D module name
                import std.uuid : randomUUID;
                import std.algorithm.iteration : filter;
                import std.conv : text;
                string uuid = randomUUID().toString();
                // Remove hyphens from UUID so the filename is a valid D identifier
                string cleanId;
                foreach (c; uuid)
                {
                    if (c != '-')
                        cleanId ~= c;
                }
                tempPath = buildPath(tempDir, "dcheck_" ~ cleanId ~ ".d");
                write(tempPath, code);
                cmd ~= tempPath;
            }

            auto result = executeCommand(cmd);

            // Cleanup temp file
            if (tempPath.length > 0 && exists(tempPath))
                remove(tempPath);

            return formatResult(result, tempPath, hasFile ? filePath : null);
        }
        catch (Exception e)
        {
            return createErrorResult("Error running compile check: " ~ e.msg);
        }
    }

private:
    void addDubImportPaths(ref string[] cmd, string projectPath)
    {
        import utils.process : executeCommand = executeCommandInDir;

        auto result = executeCommand(["dub", "describe", "--root=" ~ absolutePath(projectPath)]);
        if (result.status != 0 || result.output.length == 0)
            return;

        try
        {
            auto desc = parseJSON(result.output);
            if ("packages" !in desc)
                return;

            string rootPkg;
            if ("rootPackage" in desc)
                rootPkg = desc["rootPackage"].str;

            foreach (pkg; desc["packages"].array)
            {
                // Add import paths from all packages
                if ("importPaths" in pkg && pkg["importPaths"].type == JSONType.array)
                {
                    foreach (p; pkg["importPaths"].array)
                    {
                        if (p.type == JSONType.string)
                            cmd ~= ["-I" ~ p.str];
                    }
                }

                // Add versions from root package
                if (rootPkg.length > 0 && pkg["name"].str == rootPkg)
                {
                    if ("versions" in pkg && pkg["versions"].type == JSONType.array)
                    {
                        foreach (v; pkg["versions"].array)
                        {
                            if (v.type == JSONType.string)
                                cmd ~= ["-version=" ~ v.str];
                        }
                    }
                    if ("stringImportPaths" in pkg && pkg["stringImportPaths"].type == JSONType.array)
                    {
                        foreach (p; pkg["stringImportPaths"].array)
                        {
                            if (p.type == JSONType.string)
                                cmd ~= ["-J" ~ p.str];
                        }
                    }
                }
            }
        }
        catch (Exception)
        {
            // Ignore parse errors, proceed without dub info
        }
    }

    ToolResult formatResult(ProcessResult result, string tempPath, string originalFilePath)
    {
        // executeCommand merges stderr into stdout
        string compilerOutput = result.output;
        if (result.stderrOutput.length > 0)
        {
            if (compilerOutput.length > 0)
                compilerOutput ~= "\n";
            compilerOutput ~= result.stderrOutput;
        }

        if (result.status == 0 && compilerOutput.length == 0)
        {
            // Build a JSON response for success
            auto resp = JSONValue(["success": JSONValue(true),
                    "errors": JSONValue((JSONValue[]).init),
                    "warnings": JSONValue((JSONValue[]).init),
                    "error_count": JSONValue(0),
                    "warning_count": JSONValue(0)]);
            return createTextResult(resp.toString());
        }

        // Parse the compiler output into structured errors
        auto errors = appender!(JSONValue[]);
        auto warnings = appender!(JSONValue[]);
        auto supplemental = appender!(JSONValue[]);

        foreach (line; compilerOutput.split("\n"))
        {
            if (line.length == 0)
                continue;

            auto parsed = parseDiagnosticLine(line, tempPath, originalFilePath);
            if (parsed.type == JSONType.null_)
                continue;

            string severity = parsed["severity"].str;
            if (severity == "error")
                errors ~= parsed;
            else if (severity == "warning")
                warnings ~= parsed;
            else if (severity == "deprecation")
                warnings ~= parsed;
            else
                supplemental ~= parsed;
        }

        auto resp = JSONValue([
            "success": JSONValue(result.status == 0),
            "errors": JSONValue(errors.data),
            "warnings": JSONValue(warnings.data),
            "error_count": JSONValue(errors.data.length),
            "warning_count": JSONValue(warnings.data.length),
        ]);

        if (supplemental.data.length > 0)
            resp["supplemental"] = JSONValue(supplemental.data);

        return createTextResult(resp.toString());
    }

    /**
     * Parse a compiler diagnostic line like:
     * file.d(10): Error: cannot implicitly convert ...
     * file.d(10,5): Error: ...
     */
    JSONValue parseDiagnosticLine(string line, string tempPath, string originalFilePath)
    {
        import std.regex : regex, matchFirst;

        // Pattern: file(line): severity: message
        // Or:      file(line,col): severity: message
        auto re = regex(`^(.+?)\((\d+)(?:,(\d+))?\):\s*(Error|Warning|Deprecation|error|warning|deprecation)\s*:\s*(.+)$`);
        auto m = matchFirst(line, re);

        if (m.empty)
        {
            // Check if it's a supplemental line (e.g. "       ^" or context)
            // Or "Error: ..." without file info
            auto reNoFile = regex(`^\s*(Error|Warning|Deprecation)\s*:\s*(.+)$`);
            auto m2 = matchFirst(line, reNoFile);
            if (!m2.empty)
            {
                auto entry = JSONValue(string[string].init);
                entry["severity"] = JSONValue(m2[1].idup.toLower());
                entry["message"] = JSONValue(m2[2].idup);
                return entry;
            }
            return JSONValue(null);
        }

        string file = m[1].idup;
        // Replace temp file path with something meaningful
        if (tempPath.length > 0 && file == tempPath)
            file = originalFilePath !is null ? originalFilePath : "<stdin>";

        auto entry = JSONValue(string[string].init);
        entry["file"] = JSONValue(file);
        entry["line"] = JSONValue(m[2].to!int);
        if (m[3].length > 0)
            entry["column"] = JSONValue(m[3].to!int);
        entry["severity"] = JSONValue(m[4].idup.toLower());
        entry["message"] = JSONValue(m[5].idup);

        return entry;
    }
}
