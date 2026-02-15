module tools.import_tool;

import std.json : JSONValue, parseJSON, JSONType;
import std.string : format;
import tools.search_base;
import mcp.types : ToolResult;
import storage.crud;
import storage.search;

class ImportTool : SearchTool {
	@property string name()
	{
		return "get_imports";
	}

	@property string description()
	{
		return "Get the required import statements for D symbols (functions, types, modules). Returns import statements needed to use the specified symbols.";
	}

	@property JSONValue inputSchema()
	{
		return parseJSON(`{
            "type": "object",
            "properties": {
                "symbols": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "List of fully qualified symbol names (e.g., std.stdio.writeln, std.algorithm.map)"
                },
                "symbol": {
                    "type": "string",
                    "description": "Single symbol name (alternative to symbols array)"
                }
            },
            "required": []
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
