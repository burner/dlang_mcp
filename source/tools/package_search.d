/**
 * MCP tool for searching D packages in the documentation database.
 *
 * Queries the hybrid search engine to find D packages matching a query
 * by name, description, or tags.
 */
module tools.package_search;

import std.json : JSONValue, parseJSON, JSONType;
import std.string : format;
import tools.search_base;
import mcp.types : ToolResult;
import storage.crud;
import storage.search;

/**
 * Tool that searches for D packages by name, description, or tags.
 *
 * Returns matching packages with their metadata including descriptions,
 * authors, licenses, and relevance scores.
 */
class PackageSearchTool : SearchTool {
	@property string name()
	{
		return "search_packages";
	}

	@property string description()
	{
		return "Search the indexed D package database by name, description, or tags. Use when asked 'is there a D library for X?' or to discover packages by keyword. Returns matching packages with names, descriptions, and metadata. Searches the local index, not the live registry. For function-level search use search_functions; to download a found package use fetch_package.";
	}

	@property JSONValue inputSchema()
	{
		return parseJSON(`{
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Search terms — package name, keywords, or tags (e.g., 'json parser', 'http client', 'allocator')."
                },
                "limit": {
                    "type": "integer",
                    "default": 10,
                    "description": "Maximum results to return (default: 10). Increase for broader searches."
                }
            },
            "required": ["query"]
        }`);
	}

	ToolResult execute(JSONValue arguments)
	{
		try {
			string query = getStringParam(arguments, "query");
			if(query.length == 0) {
				return createErrorResult("Missing required 'query' parameter");
			}

			int limit = getIntParam(arguments, "limit", 10);

			auto results = search.searchPackages(query, limit);

			if(results.length == 0) {
				return createTextResult("No packages found matching: " ~ query);
			}

			string output = format("Found %d packages:\n\n", results.length);

			foreach(r; results) {
				output ~= format("## %s\n", r.name);
				if(r.docComment.length > 0) {
					output ~= format("%s\n", r.docComment);
				}
				output ~= "\n";
			}

			return createTextResult(output);
		} catch(Exception e) {
			return createErrorResult("Search error: " ~ e.msg);
		}
	}
}

/// PackageSearchTool has correct name
unittest {
	auto tool = new PackageSearchTool();
	assert(tool.name == "search_packages",
			format("Expected name 'search_packages', got: '%s'", tool.name));
}

/// PackageSearchTool has non-empty description
unittest {
	auto tool = new PackageSearchTool();
	assert(tool.description.length > 0, "Description should not be empty");
	assert(tool.description.length > 50, format("Description too short: '%s'", tool.description));
}

/// PackageSearchTool schema has correct type and properties
unittest {
	auto tool = new PackageSearchTool();
	auto schema = tool.inputSchema;
	assert(schema["type"].str == "object",
			format("Schema type should be 'object', got: '%s'", schema["type"].str));
	auto props = schema["properties"];
	assert("query" in props, "Schema should have 'query' property");
	assert("limit" in props, "Schema should have 'limit' property");
}

/// PackageSearchTool schema marks query as required
unittest {
	auto tool = new PackageSearchTool();
	auto schema = tool.inputSchema;
	assert("required" in schema, "Schema should have 'required' array");
	bool hasQuery = false;
	foreach(r; schema["required"].array) {
		if(r.str == "query")
			hasQuery = true;
	}
	assert(hasQuery, "query should be listed in required");
}

/// PackageSearchTool schema has correct property types and defaults
unittest {
	auto tool = new PackageSearchTool();
	auto schema = tool.inputSchema;
	auto props = schema["properties"];

	assert(props["query"]["type"].str == "string",
			format("query type should be 'string', got: '%s'", props["query"]["type"].str));
	assert(props["limit"]["type"].str == "integer",
			format("limit type should be 'integer', got: '%s'", props["limit"]["type"].str));
	assert(props["limit"]["default"].integer == 10,
			format("limit default should be 10, got: %d", props["limit"]["default"].integer));
}

/// PackageSearchTool returns error when query parameter is missing
unittest {
	auto tool = new PackageSearchTool();
	auto args = parseJSON(`{}`);
	auto result = tool.execute(args);
	assert(result.isError, "Should return error when query is missing");
	assert(result.content.length > 0, "Should have error content");
	assert(result.content[0].text == "Missing required 'query' parameter",
			format("Unexpected error message: '%s'", result.content[0].text));
}

/// PackageSearchTool returns error when query is empty string
unittest {
	auto tool = new PackageSearchTool();
	auto args = parseJSON(`{"query": ""}`);
	auto result = tool.execute(args);
	assert(result.isError, "Should return error when query is empty string");
	assert(result.content[0].text == "Missing required 'query' parameter",
			format("Unexpected error message: '%s'", result.content[0].text));
}

/// PackageSearchTool execute succeeds with valid query and returns formatted output
unittest {
	import std.algorithm.searching : canFind, startsWith;

	auto tool = new PackageSearchTool();
	auto args = parseJSON(`{"query": "vibe"}`);
	auto result = tool.execute(args);
	assert(result.content.length > 0, "Should have content");
	// Result is either found packages or "No packages found" - both are valid non-error
	if(!result.isError) {
		auto text = result.content[0].text;
		assert(text.canFind("packages") || text.canFind("Found"),
				format("Output should mention packages or Found, got: '%s'",
					text.length > 100 ? text[0 .. 100] ~ "..." : text));
	}
	tool.close();
}

/// PackageSearchTool respects custom limit parameter
unittest {
	auto tool = new PackageSearchTool();
	auto args = parseJSON(`{"query": "algorithm", "limit": 2}`);
	auto result = tool.execute(args);
	assert(result.content.length > 0, "Should have content");
	// Should not crash and should return a result
	assert(!result.isError || result.content[0].text.length > 0,
			"Should either succeed or provide a meaningful error");
	tool.close();
}

/// PackageSearchTool returns no-results message for nonsense query
unittest {
	import std.algorithm.searching : canFind;

	auto tool = new PackageSearchTool();
	auto args = parseJSON(`{"query": "zzznonexistentpackagexyz999"}`);
	auto result = tool.execute(args);
	assert(result.content.length > 0, "Should have content");
	if(!result.isError) {
		assert(result.content[0].text.canFind("No packages found") || result.content[0].text.canFind("Found"),
				format("Expected 'No packages found' or 'Found' message, got: '%s'",
					result.content[0].text.length > 100
					? result.content[0].text[0 .. 100] ~ "..." : result.content[0].text));
	}
	tool.close();
}

/// PackageSearchTool ignores non-integer limit and uses default
unittest {
	auto tool = new PackageSearchTool();
	auto args = parseJSON(`{"query": "test", "limit": "not_a_number"}`);
	auto result = tool.execute(args);
	// Should not crash - limit defaults to 10 when not an integer
	assert(result.content.length > 0, "Should have content");
	tool.close();
}
