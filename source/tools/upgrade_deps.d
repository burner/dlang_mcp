/**
 * MCP tool for upgrading D project dependencies using dub.
 *
 * Executes `dub upgrade` with configurable options and returns structured
 * results including success/failure status, which packages were upgraded
 * (with from/to versions when detectable), and the full output.
 */
module tools.upgrade_deps;

import std.json : JSONValue, parseJSON, JSONType;
import std.path : absolutePath;
import std.string : strip;
import std.array : appender, split;
import tools.base : BaseTool;
import mcp.types : ToolResult;
import utils.process : executeCommandInDir, ProcessResult;
import utils.diagnostic : mergeOutput;

/**
 * Tool that upgrades dependencies for a D/dub project.
 *
 * Runs `dub upgrade` to update project dependencies to their latest
 * allowed versions. Supports missing-only mode and verify mode.
 * Parses upgrade output to extract which packages changed versions.
 */
class UpgradeDependenciesTool : BaseTool {
	@property string name()
	{
		return "upgrade_dependencies";
	}

	@property string description()
	{
		return "Upgrade dependencies for a D/dub project. Runs 'dub upgrade' to update project "
			~ "dependencies to their latest allowed versions. Supports missing-only mode (only "
			~ "fetch missing dependencies) and verify mode (check consistency without upgrading). "
			~ "Returns structured results with upgrade details.";
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
                "missing_only": {
                    "type": "boolean",
                    "default": false,
                    "description": "Only fetch dependencies that are missing locally, do not upgrade existing ones"
                },
                "verify": {
                    "type": "boolean",
                    "default": false,
                    "description": "Check dependency consistency without actually upgrading"
                }
            }
        }`);
	}

	ToolResult execute(JSONValue arguments)
	{
		try {
			import std.path : absolutePath;

			string projectPath = ".";
			if("project_path" in arguments && arguments["project_path"].type == JSONType.string)
				projectPath = arguments["project_path"].str;

			projectPath = absolutePath(projectPath);

			string[] cmd = ["dub", "upgrade", "--root=" ~ projectPath];

			if("missing_only" in arguments && arguments["missing_only"].type == JSONType.true_)
				cmd ~= "--missing-only";

			if("verify" in arguments && arguments["verify"].type == JSONType.true_)
				cmd ~= "--verify";

			auto result = executeCommandInDir(cmd);

			return formatUpgradeResult(result);
		} catch(Exception e) {
			return createErrorResult("Error running dub upgrade: " ~ e.msg);
		}
	}

private:
	ToolResult formatUpgradeResult(ProcessResult result)
	{
		string fullOutput = mergeOutput(result);
		bool success = result.status == 0;

		// Parse upgrade details from output
		// dub upgrade output typically contains lines like:
		//   "Upgrading foo 1.0.0 -> 1.1.0"
		//   "Package foo was upgraded to 1.1.0"
		//   "Fetching foo 1.1.0"
		auto upgrades = appender!(JSONValue[]);

		foreach(line; fullOutput.split("\n")) {
			auto stripped = line.strip();
			if(stripped.length == 0)
				continue;

			auto upgrade = parseUpgradeLine(stripped);
			if(upgrade.type != JSONType.null_)
				upgrades ~= upgrade;
		}

		auto resp = JSONValue([
			"success": JSONValue(success),
			"upgrades": JSONValue(upgrades.data),
			"upgrade_count": JSONValue(upgrades.data.length),
			"output": JSONValue(fullOutput),
		]);

		return createTextResult(resp.toString());
	}

	/**
     * Parse a line from dub upgrade output to extract package upgrade info.
     *
     * Handles patterns like:
     *   "Upgrading vibe-d 0.9.0 -> 0.10.3"
     *   "Fetching vibe-d 0.10.3"
     */
	JSONValue parseUpgradeLine(string line)
	{
		import std.regex : regex, matchFirst;

		// Pattern: Upgrading <package> <old_version> -> <new_version>
		{
			auto re = regex(`[Uu]pgrad\w+\s+(\S+)\s+(\S+)\s*(?:->|to)\s*(\S+)`);
			auto m = matchFirst(line, re);
			if(!m.empty) {
				auto entry = JSONValue(string[string].init);
				entry["package"] = JSONValue(m[1].idup);
				entry["from_version"] = JSONValue(m[2].idup);
				entry["to_version"] = JSONValue(m[3].idup);
				entry["action"] = JSONValue("upgraded");
				return entry;
			}
		}

		// Pattern: Fetching <package> <version> (newly fetched dependency)
		{
			auto re = regex(`[Ff]etch\w+\s+(\S+)\s+(\S+)`);
			auto m = matchFirst(line, re);
			if(!m.empty) {
				auto entry = JSONValue(string[string].init);
				entry["package"] = JSONValue(m[1].idup);
				entry["to_version"] = JSONValue(m[2].idup);
				entry["action"] = JSONValue("fetched");
				return entry;
			}
		}

		return JSONValue(null);
	}
}
