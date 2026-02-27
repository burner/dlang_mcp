/**
 * MCP tool for searching D functions in the documentation database.
 *
 * Queries the hybrid search engine (FTS + vector) to find functions
 * matching a query by name, signature, documentation, or functionality.
 */
module tools.function_search;

import std.json : JSONValue, parseJSON, JSONType;
import std.string : format;
import tools.search_base;
import mcp.types : ToolResult;
import storage.crud;
import storage.search;

/**
 * Tool that searches for D functions by name, signature, or documentation content.
 *
 * Returns matching functions with their signatures, documentation comments,
 * module and package context, and relevance scores.
 */
class FunctionSearchTool : SearchTool {
	@property string name()
	{
		return "search_functions";
	}

	@property string description()
	{
		return "Search for D function definitions by name, signature, or description across indexed packages. Use when asked 'how do I sort in D?', 'find a function that parses JSON', or 'what does writeln do?'. Returns signatures, documentation, and package origin. For types use search_types; for code examples use search_examples; for import statements use get_imports.";
	}

	@property JSONValue inputSchema()
	{
		return parseJSON(`{
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Function name, signature fragment, or description (e.g., 'sort', 'parse JSON', 'writeln', 'map filter')."
                },
                "package": {
                    "type": "string",
                    "description": "Restrict search to a specific package (e.g., 'std', 'vibe-d'). Omit to search all indexed packages."
                },
                "limit": {
                    "type": "integer",
                    "default": 20,
                    "description": "Maximum results to return (default: 20)."
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

			int limit = getIntParam(arguments, "limit", 20);
			string packageFilter = getStringParam(arguments, "package");

			auto results = search.searchFunctions(query, limit,
					packageFilter.length > 0 ? packageFilter : null);

			if(results.length == 0) {
				return createTextResult("No functions found matching: " ~ query);
			}

			string output = format("Found %d functions:\n\n", results.length);

			foreach(r; results) {
				output ~= format("### %s\n", r.fullyQualifiedName);
				if(r.signature.length > 0) {
					output ~= format("```\n%s\n```\n", r.signature);
				}
				if(r.docComment.length > 0) {
					output ~= format("%s\n", r.docComment);
				}
				output ~= format("Module: %s | Package: %s\n", r.moduleName, r.packageName);
				output ~= "\n---\n\n";
			}

			return createTextResult(output);
		} catch(Exception e) {
			return createErrorResult("Search error: " ~ e.msg);
		}
	}
}
