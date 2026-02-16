/**
 * MCP tool for building D projects using dub.
 *
 * Executes `dub build` with configurable options and returns structured results
 * including success/failure status, parsed compiler errors with file locations,
 * and the full build output.
 */
module tools.build_project;

import std.json : JSONValue, parseJSON, JSONType;
import std.path : absolutePath;
import std.string : strip, toLower, startsWith, indexOf;
import std.array : appender, split;
import std.conv : to;
import tools.base : BaseTool;
import mcp.types : ToolResult;
import utils.process : executeCommandInDir, ProcessResult;

/**
 * Tool that builds a D/dub project and reports structured build results.
 *
 * Supports configuration selection, build type (debug/release), compiler
 * choice (dmd/ldc2), and forced rebuilds. Parses compiler diagnostic
 * output into structured error/warning records.
 */
class BuildProjectTool : BaseTool
{
    @property string name()
    {
        return "build_project";
    }

    @property string description()
    {
        return "Build a D/dub project. Runs 'dub build' and returns structured results including "
            ~ "success/failure status, compiler errors with file/line/message, and build output. "
            ~ "Supports configuration selection, build type, compiler choice, and force rebuild.";
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
                    "enum": ["dmd", "ldc2"],
                    "description": "Which D compiler to use (default: project default)"
                },
                "build_type": {
                    "type": "string",
                    "enum": ["debug", "release", "release-debug", "plain"],
                    "description": "Build type (default: debug)"
                },
                "configuration": {
                    "type": "string",
                    "description": "Build configuration name"
                },
                "force": {
                    "type": "boolean",
                    "default": false,
                    "description": "Force rebuild even if up-to-date"
                }
            }
        }`);
    }

    ToolResult execute(JSONValue arguments)
    {
        try
        {
            string projectPath = ".";
            if ("project_path" in arguments && arguments["project_path"].type == JSONType.string)
                projectPath = arguments["project_path"].str;

            projectPath = absolutePath(projectPath);

            string[] cmd = ["dub", "build", "--root=" ~ projectPath];

            if ("compiler" in arguments && arguments["compiler"].type == JSONType.string)
                cmd ~= ["--compiler=" ~ arguments["compiler"].str];

            if ("build_type" in arguments && arguments["build_type"].type == JSONType.string)
                cmd ~= ["--build=" ~ arguments["build_type"].str];

            if ("configuration" in arguments && arguments["configuration"].type == JSONType.string)
                cmd ~= ["--config=" ~ arguments["configuration"].str];

            if ("force" in arguments && arguments["force"].type == JSONType.true_)
                cmd ~= "--force";

            auto result = executeCommandInDir(cmd);

            return formatBuildResult(result);
        }
        catch (Exception e)
        {
            return createErrorResult("Error running dub build: " ~ e.msg);
        }
    }

private:
    ToolResult formatBuildResult(ProcessResult result)
    {
        // Combine stdout and stderr
        string fullOutput = result.output;
        if (result.stderrOutput.length > 0)
        {
            if (fullOutput.length > 0)
                fullOutput ~= "\n";
            fullOutput ~= result.stderrOutput;
        }

        bool success = result.status == 0;

        // Parse compiler errors from the output
        auto errors = appender!(JSONValue[]);
        auto warnings = appender!(JSONValue[]);

        foreach (line; fullOutput.split("\n"))
        {
            auto diag = parseDiagnostic(line);
            if (diag.type == JSONType.null_)
                continue;

            if (diag["severity"].str == "error")
                errors ~= diag;
            else
                warnings ~= diag;
        }

        auto resp = JSONValue([
            "success": JSONValue(success),
            "errors": JSONValue(errors.data),
            "warnings": JSONValue(warnings.data),
            "error_count": JSONValue(errors.data.length),
            "warning_count": JSONValue(warnings.data.length),
            "output": JSONValue(fullOutput),
        ]);

        return createTextResult(resp.toString());
    }

    /** Parse dmd/ldc2 diagnostic lines from dub output */
    JSONValue parseDiagnostic(string line)
    {
        import std.regex : regex, matchFirst;

        // Pattern: file(line): Error: message
        // Or:      file(line,col): Error: message
        auto re = regex(`^(.+?)\((\d+)(?:,(\d+))?\):\s*(Error|Warning|Deprecation)\s*:\s*(.+)$`);
        auto m = matchFirst(line, re);

        if (m.empty)
            return JSONValue(null);

        auto entry = JSONValue(string[string].init);
        entry["file"] = JSONValue(m[1].idup);
        entry["line"] = JSONValue(m[2].to!int);
        if (m[3].length > 0)
            entry["column"] = JSONValue(m[3].to!int);
        entry["severity"] = JSONValue(m[4].idup.toLower());
        entry["message"] = JSONValue(m[5].idup);

        return entry;
    }
}
