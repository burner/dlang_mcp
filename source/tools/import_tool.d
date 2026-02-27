/**
 * MCP tool for resolving import statements for D symbols.
 *
 * Looks up symbols in the documentation database and returns the
 * import statements needed to use them.
 */
module tools.import_tool;

import std.json : JSONValue, parseJSON, JSONType;
import std.string : format;
import tools.search_base;
import mcp.types : ToolResult;
import storage.crud;
import storage.search;

/**
 * Tool that resolves the required import statements for D symbols.
 *
 * Accepts a single symbol name or a list of symbol names and returns
 * the corresponding `import` statements needed to use them.
 */
class ImportTool : SearchTool {
	@property string name()
	{
		return "get_imports";
	}

	@property string description()
	{
		return "Look up the required import statements for D symbols. Use when asked 'what do I import "
			~ "for X?', 'how to import writeln', or when you know a symbol name but need its module "
			~ "path. Returns ready-to-paste import lines. Provide a single symbol or a list; fully "
			~ "qualified names yield more precise results. Use after search_functions or search_types.";
	}

	@property JSONValue inputSchema()
	{
		return parseJSON(`{
            "type": "object",
            "description": "Provide either 'symbol' (single name) or 'symbols' (array of names). At least one is required.",
            "properties": {
                "symbols": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Multiple symbol names to look up at once (e.g., ['std.stdio.writeln', 'std.algorithm.map']). Fully qualified names give more precise results."
                },
                "symbol": {
                    "type": "string",
                    "description": "A single symbol name to look up (e.g., 'writeln', 'JSONValue', 'map')."
                }
            }
        }`);
	}

	ToolResult execute(JSONValue arguments)
	{
		try {
			string[] symbols;

			if("symbols" in arguments && arguments["symbols"].type == JSONType.array) {
				foreach(s; arguments["symbols"].array) {
					if(s.type == JSONType.string) {
						symbols ~= s.str;
					}
				}
			} else if("symbol" in arguments && arguments["symbol"].type == JSONType.string) {
				symbols ~= arguments["symbol"].str;
			}

			if(symbols.length == 0) {
				return createErrorResult("Missing required 'symbols' or 'symbol' parameter");
			}

			auto imports = search.getImportsForSymbols(symbols);

			if(imports.length == 0) {
				return createTextResult("No imports found for the specified symbols.");
			}

			string output = "Required imports:\n\n```d\n";
			foreach(imp; imports) {
				output ~= format("import %s;\n", imp);
			}
			output ~= "```\n";

			return createTextResult(output);
		} catch(Exception e) {
			return createErrorResult("Error: " ~ e.msg);
		}
	}
}
