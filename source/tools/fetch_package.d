/**
 * MCP tool for fetching D packages from the dub registry.
 *
 * Executes `dub fetch` to download a specific package and returns structured
 * results including success/failure status, the package name, and any output
 * or error messages from dub.
 */
module tools.fetch_package;

import std.json : JSONValue, parseJSON, JSONType;
import std.string : strip, indexOf;
import std.array : split;
import tools.base : BaseTool;
import mcp.types : ToolResult;
import utils.process : executeCommandInDir, ProcessResult;
import utils.diagnostic : mergeOutput;

/**
 * Tool that fetches a D package from the dub registry.
 *
 * Downloads a package (optionally at a specific version) from the dub
 * package registry. Returns structured results indicating whether the
 * fetch succeeded and any output messages.
 */
class FetchPackageTool : BaseTool
{
    @property string name()
    {
        return "fetch_package";
    }

    @property string description()
    {
        return "Fetch a D package from the dub registry. Runs 'dub fetch' to download a specific "
            ~ "package by name, optionally at a specific version. Returns success/failure status "
            ~ "and any output or error messages.";
    }

    @property JSONValue inputSchema()
    {
        return parseJSON(`{
            "type": "object",
            "required": ["package_name"],
            "properties": {
                "package_name": {
                    "type": "string",
                    "description": "Name of the dub package to fetch (e.g. 'vibe-d', 'mir-algorithm')"
                },
                "version_": {
                    "type": "string",
                    "description": "Specific version to fetch (e.g. '1.0.0', '~>2.0'). If omitted, fetches the latest version."
                }
            }
        }`);
    }

    ToolResult execute(JSONValue arguments)
    {
        try
        {
            // Package name is required
            if ("package_name" !in arguments || arguments["package_name"].type != JSONType.string
                || arguments["package_name"].str.strip().length == 0)
            {
                return createErrorResult("Missing required parameter: package_name");
            }

            string packageName = arguments["package_name"].str.strip();

            string[] cmd = ["dub", "fetch", packageName];

            if ("version_" in arguments && arguments["version_"].type == JSONType.string)
            {
                string ver = arguments["version_"].str.strip();
                if (ver.length > 0)
                    cmd ~= "--version=" ~ ver;
            }

            auto result = executeCommandInDir(cmd);

            return formatFetchResult(result, packageName);
        }
        catch (Exception e)
        {
            return createErrorResult("Error running dub fetch: " ~ e.msg);
        }
    }

private:
    ToolResult formatFetchResult(ProcessResult result, string packageName)
    {
        string fullOutput = mergeOutput(result);
        bool success = result.status == 0;

        // Try to extract version information from the output
        string fetchedVersion = "";
        foreach (line; fullOutput.split("\n"))
        {
            // dub fetch outputs lines like "Fetching vibe-d 0.10.3"
            // or "Package vibe-d@0.10.3 was already present"
            auto atIdx = line.indexOf("@");
            if (atIdx >= 0 && line.indexOf(packageName) >= 0)
            {
                // Extract version after @
                auto rest = line[atIdx + 1 .. $];
                auto spaceIdx = rest.indexOf(" ");
                if (spaceIdx > 0)
                    fetchedVersion = rest[0 .. spaceIdx];
                else if (rest.length > 0)
                    fetchedVersion = rest;
            }
        }

        auto resp = JSONValue([
            "success": JSONValue(success),
            "package_name": JSONValue(packageName),
            "version_fetched": JSONValue(fetchedVersion),
            "output": JSONValue(fullOutput),
        ]);

        return createTextResult(resp.toString());
    }
}
