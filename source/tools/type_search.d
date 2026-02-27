/**
 * MCP tool for searching D types in the documentation database.
 *
 * Queries the hybrid search engine to find D types (classes, structs,
 * interfaces, enums) matching a query by name or description.
 */
module tools.type_search;

import std.json : JSONValue, parseJSON, JSONType;
import std.string : format;
import tools.search_base;
import mcp.types : ToolResult;
import storage.crud;
import storage.search;

/**
 * Tool that searches for D types by name or description.
 *
 * Supports optional filtering by type kind (class, struct, interface, enum).
 * Returns matching types with their definitions, documentation, and
 * module/package context.
 */
class TypeSearchTool : SearchTool {
	@property string name()
	{
		return "search_types";
	}

	@property string description()
	{
		return "Search for D type definitions (classes, structs, interfaces, enums) by name or description across indexed packages. Use when asked 'what type represents X?', 'find a struct for Y', or to discover data structures. Returns matching types with definitions and documentation. Filter by kind to narrow results. For functions use search_functions; for usage examples use search_examples.";
	}

	@property JSONValue inputSchema()
	{
		return parseJSON(`{
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Type name or description (e.g., 'JSONValue', 'hash map', 'Duration', 'socket address')."
                },
                "kind": {
                    "type": "string",
                    "enum": ["class", "struct", "interface", "enum"],
                    "description": "Filter by type kind: class, struct, interface, or enum. Omit to search all kinds."
                },
                "package": {
                    "type": "string",
                    "description": "Restrict to a specific package. Omit to search all indexed packages."
                },
                "limit": {
                    "type": "integer",
                    "default": 15,
                    "description": "Maximum results to return (default: 15)."
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

			int limit = getIntParam(arguments, "limit", 15);
			string kindFilter = getStringParam(arguments, "kind");
			string packageFilter = getStringParam(arguments, "package");

			auto results = search.searchTypes(query, limit, kindFilter.length > 0
					? kindFilter : null, packageFilter.length > 0 ? packageFilter : null);

			if(results.length == 0) {
				return createTextResult("No types found matching: " ~ query);
			}

			string output = format("Found %d types:\n\n", results.length);

			foreach(r; results) {
				output ~= format("### %s\n", r.fullyQualifiedName);
				if(r.signature.length > 0 && r.signature != r.fullyQualifiedName) {
					output ~= format("Kind: %s\n", r.signature);
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
