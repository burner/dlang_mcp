module tools.example_search;

import std.json : JSONValue, parseJSON, JSONType;
import std.string : format;
import tools.search_base;
import mcp.types : ToolResult;
import storage.crud;
import storage.search;

class ExampleSearchTool : SearchTool {
	@property string name()
	{
		return "search_examples";
	}

	@property string description()
	{
		return "Search for D code examples by description or code content. Returns runnable code examples with import requirements.";
	}

	@property JSONValue inputSchema()
	{
		return parseJSON(`{
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Search query - example description or code functionality"
                },
                "package": {
                    "type": "string",
                    "description": "Optional package name to filter results"
                },
                "limit": {
                    "type": "integer",
                    "default": 10,
                    "description": "Maximum number of results to return"
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
