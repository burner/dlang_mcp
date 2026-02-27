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
class FetchPackageTool : BaseTool {
	@property string name()
	{
		return "fetch_package";
	}

	@property string description()
	{
		return "Download a D package from the dub registry to the local package cache. Use when asked to "
			~ "install, download, or fetch a dub package. Returns success/failure status and output "
			~ "messages. Downloads only — does not add the package to a project's dub.json. To "
			~ "discover packages by keyword or functionality first, use search_packages.";
	}

	@property JSONValue inputSchema()
	{
		return parseJSON(`{
            "type": "object",
            "required": ["package_name"],
            "properties": {
                "package_name": {
                    "type": "string",
                    "description": "Dub package name to download (e.g., 'vibe-d', 'taggedalgebraic'). Required."
                },
                "version_": {
                    "type": "string",
                    "description": "Specific version to fetch (e.g., '1.0.0', '~>2.0'). Omit to fetch the latest version."
                }
            }
        }`);
	}

	ToolResult execute(JSONValue arguments)
	{
		try {
			// Package name is required
			if("package_name" !in arguments || arguments["package_name"].type != JSONType.string
					|| arguments["package_name"].str.strip().length == 0) {
				return createErrorResult("Missing required parameter: package_name");
			}

			string packageName = arguments["package_name"].str.strip();

			string[] cmd = ["dub", "fetch", packageName];

			if("version_" in arguments && arguments["version_"].type == JSONType.string) {
				string ver = arguments["version_"].str.strip();
				if(ver.length > 0)
					cmd ~= "--version=" ~ ver;
			}

			auto result = executeCommandInDir(cmd);

			return formatFetchResult(result, packageName);
		} catch(Exception e) {
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
		foreach(line; fullOutput.split("\n")) {
			// dub fetch outputs lines like "Fetching vibe-d 0.10.3"
			// or "Package vibe-d@0.10.3 was already present"
			auto atIdx = line.indexOf("@");
			if(atIdx >= 0 && line.indexOf(packageName) >= 0) {
				// Extract version after @
				auto rest = line[atIdx + 1 .. $];
				auto spaceIdx = rest.indexOf(" ");
				if(spaceIdx > 0)
					fetchedVersion = rest[0 .. spaceIdx];
				else if(rest.length > 0)
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

// -- Unit Tests --

/// FetchPackageTool has correct name
unittest {
	auto tool = new FetchPackageTool();
	assert(tool.name == "fetch_package", "Expected name 'fetch_package', got: " ~ tool.name);
}

/// FetchPackageTool has non-empty description
unittest {
	auto tool = new FetchPackageTool();
	assert(tool.description.length > 0, "Description should not be empty");
}

/// FetchPackageTool description mentions dub fetch
unittest {
	import std.algorithm.searching : canFind;

	auto tool = new FetchPackageTool();
	assert(tool.description.canFind("dub") && tool.description.canFind("Download"),
			"Description should mention downloading from dub registry");
}

/// FetchPackageTool inputSchema has correct type
unittest {
	import std.format : format;

	auto tool = new FetchPackageTool();
	auto schema = tool.inputSchema;
	assert(schema["type"].str == "object",
			format!"Schema type should be 'object', got '%s'"(schema["type"].str));
}

/// FetchPackageTool inputSchema has package_name property
unittest {
	auto tool = new FetchPackageTool();
	auto schema = tool.inputSchema;
	auto props = schema["properties"];
	assert("package_name" in props, "Schema should have package_name");
}

/// FetchPackageTool inputSchema has version_ property
unittest {
	auto tool = new FetchPackageTool();
	auto schema = tool.inputSchema;
	auto props = schema["properties"];
	assert("version_" in props, "Schema should have version_");
}

/// FetchPackageTool inputSchema package_name is required
unittest {
	import std.format : format;

	auto tool = new FetchPackageTool();
	auto schema = tool.inputSchema;
	assert("required" in schema, "Schema should have required array");
	bool hasRequired = false;
	foreach(r; schema["required"].array) {
		if(r.str == "package_name")
			hasRequired = true;
	}
	assert(hasRequired, "package_name should be in required array");
}

/// FetchPackageTool inputSchema package_name has string type
unittest {
	import std.format : format;

	auto tool = new FetchPackageTool();
	auto schema = tool.inputSchema;
	auto pkgProp = schema["properties"]["package_name"];
	assert(pkgProp["type"].str == "string",
			format!"package_name type should be 'string', got '%s'"(pkgProp["type"].str));
}

/// FetchPackageTool inputSchema version_ has string type
unittest {
	import std.format : format;

	auto tool = new FetchPackageTool();
	auto schema = tool.inputSchema;
	auto verProp = schema["properties"]["version_"];
	assert(verProp["type"].str == "string",
			format!"version_ type should be 'string', got '%s'"(verProp["type"].str));
}

/// FetchPackageTool execute returns error when package_name is missing
unittest {
	import std.algorithm.searching : canFind;

	auto tool = new FetchPackageTool();
	auto args = parseJSON(`{}`);
	auto result = tool.execute(args);
	assert(result.isError, "Should return error when package_name is missing");
	assert(result.content.length > 0, "Should have error content");
	assert(result.content[0].text.canFind("package_name"), "Error should mention package_name");
}

/// FetchPackageTool execute returns error when package_name is whitespace-only
unittest {
	auto tool = new FetchPackageTool();
	auto args = parseJSON(`{"package_name": "   "}`);
	auto result = tool.execute(args);
	assert(result.isError, "Should return error when package_name is whitespace-only");
}

/// FetchPackageTool execute returns error when package_name is empty string
unittest {
	auto tool = new FetchPackageTool();
	auto args = parseJSON(`{"package_name": ""}`);
	auto result = tool.execute(args);
	assert(result.isError, "Should return error when package_name is empty string");
}

/// FetchPackageTool execute returns error when package_name is wrong type
unittest {
	auto tool = new FetchPackageTool();
	auto args = parseJSON(`{"package_name": 42}`);
	auto result = tool.execute(args);
	assert(result.isError, "Should return error when package_name is not a string");
}

/// formatFetchResult with successful fetch including version in @ format
unittest {
	import std.format : format;

	auto tool = new FetchPackageTool();
	auto pr = ProcessResult(0, "Fetching vibe-d@0.10.3...", "");
	auto result = tool.formatFetchResult(pr, "vibe-d");
	assert(!result.isError, "Successful fetch should not be an error result");
	assert(result.content.length > 0, "Should have content");

	auto resp = parseJSON(result.content[0].text);
	assert(resp["success"].type == JSONType.true_, "success should be true for status 0");
	assert(resp["package_name"].str == "vibe-d",
			format!"package_name should be 'vibe-d', got '%s'"(resp["package_name"].str));
	assert(resp["version_fetched"].str == "0.10.3...",
			format!"version_fetched should be '0.10.3...', got '%s'"(resp["version_fetched"].str));
}

/// formatFetchResult with already-present package (@ with space after version)
unittest {
	import std.format : format;

	auto tool = new FetchPackageTool();
	auto pr = ProcessResult(0, "Package mir-algorithm@3.2.1 was already present", "");
	auto result = tool.formatFetchResult(pr, "mir-algorithm");
	assert(!result.isError, "Already-present should not be error");

	auto resp = parseJSON(result.content[0].text);
	assert(resp["success"].type == JSONType.true_, "success should be true for status 0");
	assert(resp["package_name"].str == "mir-algorithm",
			format!"package_name should be 'mir-algorithm', got '%s'"(resp["package_name"].str));
	assert(resp["version_fetched"].str == "3.2.1",
			format!"version_fetched should be '3.2.1', got '%s'"(resp["version_fetched"].str));
}

/// formatFetchResult with failed fetch (status 1)
unittest {
	import std.format : format;

	auto tool = new FetchPackageTool();
	auto pr = ProcessResult(1, "", "Package not found: nonexistent-pkg");
	auto result = tool.formatFetchResult(pr, "nonexistent-pkg");
	assert(!result.isError, "formatFetchResult returns text result, not error result");

	auto resp = parseJSON(result.content[0].text);
	assert(resp["success"].type == JSONType.false_, "success should be false for status 1");
	assert(resp["package_name"].str == "nonexistent-pkg",
			format!"package_name should be 'nonexistent-pkg', got '%s'"(resp["package_name"].str));
	assert(resp["output"].str.length > 0, "output should contain the error message");
}

/// formatFetchResult with no version info in output
unittest {
	import std.format : format;

	auto tool = new FetchPackageTool();
	auto pr = ProcessResult(0, "Some output without version info", "");
	auto result = tool.formatFetchResult(pr, "mypackage");

	auto resp = parseJSON(result.content[0].text);
	assert(resp["success"].type == JSONType.true_, "success should be true for status 0");
	assert(resp["version_fetched"].str == "",
			format!"version_fetched should be empty when no version in output, got '%s'"(
				resp["version_fetched"].str));
}

/// formatFetchResult with empty output
unittest {
	import std.format : format;

	auto tool = new FetchPackageTool();
	auto pr = ProcessResult(0, "", "");
	auto result = tool.formatFetchResult(pr, "somepackage");

	auto resp = parseJSON(result.content[0].text);
	assert(resp["success"].type == JSONType.true_, "success should be true for status 0");
	assert(resp["version_fetched"].str == "", "version_fetched should be empty for empty output");
	assert(resp["output"].str == "", "output should be empty");
}

/// formatFetchResult with stderr-only output
unittest {
	import std.format : format;

	auto tool = new FetchPackageTool();
	auto pr = ProcessResult(1, "", "Error: unable to resolve package");
	auto result = tool.formatFetchResult(pr, "bad-pkg");

	auto resp = parseJSON(result.content[0].text);
	assert(resp["success"].type == JSONType.false_, "success should be false for status 1");
	assert(resp["output"].str.length > 0, "output should contain stderr content");
}

/// formatFetchResult with multiline output finds version
unittest {
	import std.format : format;

	auto tool = new FetchPackageTool();
	auto pr = ProcessResult(0,
			"Resolving dependencies...\nPackage taggedalgebra@0.7.2 was already present\nDone.", "");
	auto result = tool.formatFetchResult(pr, "taggedalgebra");

	auto resp = parseJSON(result.content[0].text);
	assert(resp["version_fetched"].str == "0.7.2",
			format!"version_fetched should be '0.7.2', got '%s'"(resp["version_fetched"].str));
}

/// formatFetchResult with @ but wrong package name does not extract version
unittest {
	import std.format : format;

	auto tool = new FetchPackageTool();
	auto pr = ProcessResult(0, "Package other-pkg@1.0.0 was fetched", "");
	auto result = tool.formatFetchResult(pr, "my-pkg");

	auto resp = parseJSON(result.content[0].text);
	assert(resp["version_fetched"].str == "",
			format!"version_fetched should be empty when @ is for a different package, got '%s'"(
				resp["version_fetched"].str));
}

/// formatFetchResult with version at end of line (no space after)
unittest {
	import std.format : format;

	auto tool = new FetchPackageTool();
	auto pr = ProcessResult(0, "Fetched mylib@2.0.0", "");
	auto result = tool.formatFetchResult(pr, "mylib");

	auto resp = parseJSON(result.content[0].text);
	assert(resp["version_fetched"].str == "2.0.0",
			format!"version_fetched should be '2.0.0', got '%s'"(resp["version_fetched"].str));
}

/// formatFetchResult with both stdout and stderr
unittest {
	import std.format : format;
	import std.algorithm.searching : canFind;

	auto tool = new FetchPackageTool();
	auto pr = ProcessResult(0, "Fetching pkg@1.0.0", "Warning: something");
	auto result = tool.formatFetchResult(pr, "pkg");

	auto resp = parseJSON(result.content[0].text);
	assert(resp["success"].type == JSONType.true_, "success should be true for status 0");
	assert(resp["output"].str.canFind("Fetching"), "output should contain stdout content");
	assert(resp["output"].str.canFind("Warning"), "output should contain stderr content");
}

/// formatFetchResult preserves package_name exactly as passed
unittest {
	import std.format : format;

	auto tool = new FetchPackageTool();
	auto pr = ProcessResult(0, "", "");
	auto result = tool.formatFetchResult(pr, "My-Special_Package.123");

	auto resp = parseJSON(result.content[0].text);
	assert(resp["package_name"].str == "My-Special_Package.123",
			format!"package_name should be preserved exactly, got '%s'"(resp["package_name"].str));
}
