module tools.package_search;

import std.json : JSONValue, parseJSON, JSONType;
import std.string : format;
import tools.search_base;
import mcp.types : ToolResult;
import storage.crud;
import storage.search;

class PackageSearchTool : SearchTool
{
    @property string name()
    {
        return "search_packages";
    }

    @property string description()
    {
        return "Search for D packages by name, description, or tags. Returns matching packages with descriptions and metadata.";
    }

    @property JSONValue inputSchema()
    {
        return parseJSON(`{
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Search query - package name, description keywords, or tags"
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
        try
        {
            string query = getStringParam(arguments, "query");
            if (query.length == 0)
            {
                return createErrorResult("Missing required 'query' parameter");
            }

            int limit = getIntParam(arguments, "limit", 10);

            auto results = search.searchPackages(query, limit);

            if (results.length == 0)
            {
                return createTextResult("No packages found matching: " ~ query);
            }

            string output = format("Found %d packages:\n\n", results.length);

            foreach (r; results)
            {
                output ~= format("## %s\n", r.name);
                if (r.docComment.length > 0)
                {
                    output ~= format("%s\n", r.docComment);
                }
                output ~= "\n";
            }

            return createTextResult(output);
        }
        catch (Exception e)
        {
            return createErrorResult("Search error: " ~ e.msg);
        }
    }
}