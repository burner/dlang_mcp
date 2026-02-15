module tools.search_base;

import std.json : JSONValue, parseJSON, JSONType;
import tools.base : BaseTool;
import storage.connection : DBConnection;
import storage.search : HybridSearch;
import mcp.types : ToolResult;

abstract class SearchTool : BaseTool {
	protected DBConnection conn;
	protected HybridSearch search;

	this()
	{
		conn = new DBConnection("data/search.db");
		search = new HybridSearch(conn);
	}

	~this()
	{
		if(conn !is null) {
			conn.close();
		}
	}

	protected int getIntParam(JSONValue args, string key, int defaultVal)
	{
		if(key in args && args[key].type == JSONType.integer) {
			return cast(int)args[key].integer;
		}
		return defaultVal;
	}

	protected string getStringParam(JSONValue args, string key, string defaultVal = "")
	{
		if(key in args && args[key].type == JSONType.string) {
			return args[key].str;
		}
		return defaultVal;
	}
}
