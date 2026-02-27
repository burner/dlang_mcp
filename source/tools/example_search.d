/**
 * MCP tool for searching D code examples in the documentation database.
 *
 * Queries the search database for code examples matching a description
 * or code content, returning runnable examples with their import requirements.
 */
module tools.example_search;

import std.json : JSONValue, parseJSON, JSONType;
import std.string : format;
import tools.search_base;
import mcp.types : ToolResult;
import storage.crud;
import storage.search;

/**
 * Tool that searches for D code examples by description or code content.
 *
 * Returns matching examples with source code, descriptions, required imports,
 * and metadata about runnability and associated functions/types.
 */
class ExampleSearchTool : SearchTool {
	@property string name()
	{
		return "search_examples";
	}

	@property string description()
	{
		return "Search for runnable D code examples by description or code pattern. Use when asked 'show me how to X in D', 'example of Y', or when the user needs working sample code. Returns complete, runnable snippets with required import statements. Best used after search_functions or search_types to see practical API usage. For API signatures without examples use search_functions.";
	}

	@property JSONValue inputSchema()
	{
		return parseJSON(`{
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Description of what the example should demonstrate (e.g., 'read a file line by line', 'HTTP GET request', 'regex matching')."
                },
                "package": {
                    "type": "string",
                    "description": "Restrict to examples from a specific package. Omit to search all indexed packages."
                },
                "limit": {
                    "type": "integer",
                    "default": 10,
                    "description": "Maximum results to return (default: 10)."
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
			string packageFilter = getStringParam(arguments, "package");

			auto results = search.searchExamples(query, limit,
					packageFilter.length > 0 ? packageFilter : null);

			if(results.length == 0) {
				return createTextResult("No examples found matching: " ~ query);
			}

			string output = format("Found %d code examples:\n\n", results.length);

			foreach(r; results) {
				output ~= format("### Example: %s\n", r.name.length > 0 ? r.name : "Code");
				if(r.docComment.length > 0) {
					output ~= format("%s\n\n", r.docComment);
				}

				auto imports = search.getImportsForSymbol(r.name);
				if(imports.length > 0) {
					output ~= "Required imports:\n```d\n";
					foreach(imp; imports) {
						output ~= format("import %s;\n", imp);
					}
					output ~= "```\n\n";
				}

				output ~= "Code:\n```d\n";
				output ~= r.signature;
				output ~= "\n```\n";
				output ~= format("Package: %s\n", r.packageName);
				output ~= "\n---\n\n";
			}

			return createTextResult(output);
		} catch(Exception e) {
			return createErrorResult("Search error: " ~ e.msg);
		}
	}
}
