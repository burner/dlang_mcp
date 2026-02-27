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
		return "Upgrade or verify dependencies for a D/dub project. Use when asked to update packages, "
			~ "fix missing dependencies, or check dependency consistency. Returns which packages were "
			~ "updated and to what versions. Requires dub.json or dub.sdl. Use missing_only=true after "
			~ "cloning to fetch without upgrading; verify=true to check without modifying. For "
			~ "downloading individual packages use fetch_package.";
	}

	@property JSONValue inputSchema()
	{
		return parseJSON(`{
            "type": "object",
            "properties": {
                "project_path": {
                    "type": "string",
                    "default": ".",
                    "description": "Path to the project root containing dub.json or dub.sdl (default: current directory)."
                },
                "missing_only": {
                    "type": "boolean",
                    "default": false,
                    "description": "Only download dependencies not yet cached — do not upgrade existing ones (default: false). Use after cloning a fresh repo."
                },
                "verify": {
                    "type": "boolean",
                    "default": false,
                    "description": "Check dependency version consistency without modifying anything (default: false). Use for CI or auditing."
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

// -- Unit Tests --

/// UpgradeDependenciesTool has correct name
unittest {
	auto tool = new UpgradeDependenciesTool();
	assert(tool.name == "upgrade_dependencies",
			"Expected name 'upgrade_dependencies', got: " ~ tool.name);
}

/// UpgradeDependenciesTool has non-empty description
unittest {
	auto tool = new UpgradeDependenciesTool();
	assert(tool.description.length > 0, "Description should not be empty");
}

/// UpgradeDependenciesTool description mentions dub upgrade
unittest {
	import std.algorithm.searching : canFind;

	auto tool = new UpgradeDependenciesTool();
	assert(tool.description.canFind("Upgrade") && tool.description.canFind("dependencies"),
			"Description should mention upgrading dependencies");
}

/// inputSchema has correct type and all expected properties
unittest {
	import std.format : format;

	auto tool = new UpgradeDependenciesTool();
	auto schema = tool.inputSchema;
	assert(schema["type"].str == "object",
			format!"Schema type should be 'object', got '%s'"(schema["type"].str));
	auto props = schema["properties"];
	assert("project_path" in props, "Schema should have project_path");
	assert("missing_only" in props, "Schema should have missing_only");
	assert("verify" in props, "Schema should have verify");
}

/// inputSchema project_path has default value "."
unittest {
	import std.format : format;

	auto tool = new UpgradeDependenciesTool();
	auto schema = tool.inputSchema;
	auto pp = schema["properties"]["project_path"];
	assert(pp["type"].str == "string",
			format!"project_path type should be 'string', got '%s'"(pp["type"].str));
	assert(pp["default"].str == ".",
			format!"project_path default should be '.', got '%s'"(pp["default"].str));
}

/// inputSchema missing_only has boolean type and default false
unittest {
	import std.format : format;

	auto tool = new UpgradeDependenciesTool();
	auto schema = tool.inputSchema;
	auto mo = schema["properties"]["missing_only"];
	assert(mo["type"].str == "boolean",
			format!"missing_only type should be 'boolean', got '%s'"(mo["type"].str));
	assert(mo["default"].type == JSONType.false_, "missing_only default should be false");
}

/// inputSchema verify has boolean type and default false
unittest {
	import std.format : format;

	auto tool = new UpgradeDependenciesTool();
	auto schema = tool.inputSchema;
	auto v = schema["properties"]["verify"];
	assert(v["type"].str == "boolean",
			format!"verify type should be 'boolean', got '%s'"(v["type"].str));
	assert(v["default"].type == JSONType.false_, "verify default should be false");
}

/// parseUpgradeLine matches "Upgrading package old -> new" pattern
unittest {
	import std.format : format;

	auto tool = new UpgradeDependenciesTool();
	auto result = tool.parseUpgradeLine("Upgrading vibe-d 0.9.0 -> 0.10.3");
	assert(result.type != JSONType.null_, "Should match upgrade pattern");
	assert(result["package"].str == "vibe-d",
			format!"package should be 'vibe-d', got '%s'"(result["package"].str));
	assert(result["from_version"].str == "0.9.0",
			format!"from_version should be '0.9.0', got '%s'"(result["from_version"].str));
	assert(result["to_version"].str == "0.10.3",
			format!"to_version should be '0.10.3', got '%s'"(result["to_version"].str));
	assert(result["action"].str == "upgraded",
			format!"action should be 'upgraded', got '%s'"(result["action"].str));
}

/// parseUpgradeLine matches "Upgrading package old to new" pattern
unittest {
	import std.format : format;

	auto tool = new UpgradeDependenciesTool();
	auto result = tool.parseUpgradeLine("Upgrading mir-algorithm 1.0.0 to 1.2.0");
	assert(result.type != JSONType.null_, "Should match 'to' upgrade pattern");
	assert(result["package"].str == "mir-algorithm",
			format!"package should be 'mir-algorithm', got '%s'"(result["package"].str));
	assert(result["from_version"].str == "1.0.0",
			format!"from_version should be '1.0.0', got '%s'"(result["from_version"].str));
	assert(result["to_version"].str == "1.2.0",
			format!"to_version should be '1.2.0', got '%s'"(result["to_version"].str));
	assert(result["action"].str == "upgraded",
			format!"action should be 'upgraded', got '%s'"(result["action"].str));
}

/// parseUpgradeLine matches lowercase "upgrading"
unittest {
	auto tool = new UpgradeDependenciesTool();
	auto result = tool.parseUpgradeLine("upgrading foo 1.0.0 -> 2.0.0");
	assert(result.type != JSONType.null_, "Should match lowercase 'upgrading'");
	assert(result["package"].str == "foo");
	assert(result["action"].str == "upgraded");
}

/// parseUpgradeLine matches "Upgraded" variant
unittest {
	auto tool = new UpgradeDependenciesTool();
	auto result = tool.parseUpgradeLine("Upgraded some-pkg 0.1.0 -> 0.2.0");
	assert(result.type != JSONType.null_, "Should match 'Upgraded' variant");
	assert(result["package"].str == "some-pkg");
	assert(result["from_version"].str == "0.1.0");
	assert(result["to_version"].str == "0.2.0");
}

/// parseUpgradeLine matches "Fetching package version" pattern
unittest {
	import std.format : format;

	auto tool = new UpgradeDependenciesTool();
	auto result = tool.parseUpgradeLine("Fetching vibe-d 0.10.3");
	assert(result.type != JSONType.null_, "Should match fetch pattern");
	assert(result["package"].str == "vibe-d",
			format!"package should be 'vibe-d', got '%s'"(result["package"].str));
	assert(result["to_version"].str == "0.10.3",
			format!"to_version should be '0.10.3', got '%s'"(result["to_version"].str));
	assert(result["action"].str == "fetched",
			format!"action should be 'fetched', got '%s'"(result["action"].str));
}

/// parseUpgradeLine matches lowercase "fetching"
unittest {
	auto tool = new UpgradeDependenciesTool();
	auto result = tool.parseUpgradeLine("fetching bar-lib 3.1.4");
	assert(result.type != JSONType.null_, "Should match lowercase 'fetching'");
	assert(result["package"].str == "bar-lib");
	assert(result["to_version"].str == "3.1.4");
	assert(result["action"].str == "fetched");
}

/// parseUpgradeLine returns null for non-matching lines
unittest {
	auto tool = new UpgradeDependenciesTool();

	auto r1 = tool.parseUpgradeLine("Building project...");
	assert(r1.type == JSONType.null_, "Non-matching line should return null");

	auto r2 = tool.parseUpgradeLine("Compiling source/app.d");
	assert(r2.type == JSONType.null_, "Compiler line should return null");

	auto r3 = tool.parseUpgradeLine("");
	assert(r3.type == JSONType.null_, "Empty line should return null");

	auto r4 = tool.parseUpgradeLine("Linking...");
	assert(r4.type == JSONType.null_, "Linking line should return null");

	auto r5 = tool.parseUpgradeLine("Dependencies are up to date");
	assert(r5.type == JSONType.null_, "Up to date message should return null");
}

/// parseUpgradeLine with version containing tilde constraint
unittest {
	auto tool = new UpgradeDependenciesTool();
	auto result = tool.parseUpgradeLine("Upgrading package-name ~>1.0.0 -> 1.0.1");
	assert(result.type != JSONType.null_, "Should match version with tilde constraint");
	assert(result["package"].str == "package-name");
	assert(result["from_version"].str == "~>1.0.0");
	assert(result["to_version"].str == "1.0.1");
}

/// formatUpgradeResult with successful upgrade and no upgrades
unittest {
	import std.format : format;

	auto tool = new UpgradeDependenciesTool();
	auto pr = ProcessResult(0, "Dependencies are up to date", "");
	auto result = tool.formatUpgradeResult(pr);
	assert(!result.isError, "Successful result should not be error");
	assert(result.content.length > 0, "Should have content");

	auto resp = parseJSON(result.content[0].text);
	assert(resp["success"].type == JSONType.true_, "success should be true for status 0");
	assert(resp["upgrade_count"].integer == 0,
			format!"upgrade_count should be 0, got %d"(resp["upgrade_count"].integer));
	assert(resp["upgrades"].array.length == 0, "upgrades array should be empty");
}

/// formatUpgradeResult with successful upgrade containing upgrade lines
unittest {
	import std.format : format;

	auto tool = new UpgradeDependenciesTool();
	string output = "Upgrading vibe-d 0.9.0 -> 0.10.3\nFetching mir-algorithm 1.2.0\n";
	auto pr = ProcessResult(0, output, "");
	auto result = tool.formatUpgradeResult(pr);

	auto resp = parseJSON(result.content[0].text);
	assert(resp["success"].type == JSONType.true_, "success should be true");
	assert(resp["upgrade_count"].integer == 2,
			format!"upgrade_count should be 2, got %d"(resp["upgrade_count"].integer));
	assert(resp["upgrades"].array.length == 2,
			format!"upgrades array should have 2 entries, got %d"(resp["upgrades"].array.length));

	// Verify first entry (upgrade)
	auto u0 = resp["upgrades"].array[0];
	assert(u0["action"].str == "upgraded",
			format!"First action should be 'upgraded', got '%s'"(u0["action"].str));
	assert(u0["package"].str == "vibe-d",
			format!"First package should be 'vibe-d', got '%s'"(u0["package"].str));

	// Verify second entry (fetch)
	auto u1 = resp["upgrades"].array[1];
	assert(u1["action"].str == "fetched",
			format!"Second action should be 'fetched', got '%s'"(u1["action"].str));
	assert(u1["package"].str == "mir-algorithm",
			format!"Second package should be 'mir-algorithm', got '%s'"(u1["package"].str));
}

/// formatUpgradeResult with failed status
unittest {
	import std.format : format;

	auto tool = new UpgradeDependenciesTool();
	auto pr = ProcessResult(1, "", "Error: could not find dub.json");
	auto result = tool.formatUpgradeResult(pr);

	auto resp = parseJSON(result.content[0].text);
	assert(resp["success"].type == JSONType.false_, "success should be false for status 1");
	assert(resp["upgrade_count"].integer == 0,
			format!"upgrade_count should be 0, got %d"(resp["upgrade_count"].integer));
}

/// formatUpgradeResult with empty output
unittest {
	import std.format : format;

	auto tool = new UpgradeDependenciesTool();
	auto pr = ProcessResult(0, "", "");
	auto result = tool.formatUpgradeResult(pr);

	auto resp = parseJSON(result.content[0].text);
	assert(resp["success"].type == JSONType.true_, "success should be true");
	assert(resp["upgrade_count"].integer == 0,
			format!"upgrade_count should be 0, got %d"(resp["upgrade_count"].integer));
	assert(resp["output"].str == "", "output should be empty string");
}

/// formatUpgradeResult result content is valid JSON with all expected keys
unittest {
	auto tool = new UpgradeDependenciesTool();
	auto pr = ProcessResult(0, "some output", "some stderr");
	auto result = tool.formatUpgradeResult(pr);

	assert(result.content.length == 1, "Should have exactly 1 content block");
	assert(result.content[0].type == "text", "Content type should be 'text'");

	auto resp = parseJSON(result.content[0].text);
	assert("success" in resp, "JSON should have 'success' key");
	assert("upgrades" in resp, "JSON should have 'upgrades' key");
	assert("upgrade_count" in resp, "JSON should have 'upgrade_count' key");
	assert("output" in resp, "JSON should have 'output' key");
}

/// formatUpgradeResult merges stdout and stderr into output
unittest {
	import std.algorithm.searching : canFind;
	import std.format : format;

	auto tool = new UpgradeDependenciesTool();
	auto pr = ProcessResult(0, "stdout text", "stderr text");
	auto result = tool.formatUpgradeResult(pr);

	auto resp = parseJSON(result.content[0].text);
	// mergeOutput combines stdout and stderr
	assert(resp["output"].str.length > 0, "output should contain merged content");
}

/// formatUpgradeResult with mixed matching and non-matching lines
unittest {
	import std.format : format;

	auto tool = new UpgradeDependenciesTool();
	string output = "Performing \"upgrade\" on configuration \"default\"...\n"
		~ "Upgrading foo 1.0.0 -> 2.0.0\n" ~ "Some informational line\n"
		~ "Fetching bar 3.0.0\n" ~ "Build complete.";
	auto pr = ProcessResult(0, output, "");
	auto result = tool.formatUpgradeResult(pr);

	auto resp = parseJSON(result.content[0].text);
	assert(resp["upgrade_count"].integer == 2,
			format!"Only upgrade/fetch lines should be counted, got %d"(
				resp["upgrade_count"].integer));
}
