/**
 * Base class for database-backed search tools.
 *
 * Provides shared infrastructure for tools that query the search database,
 * including database connection management and parameter extraction helpers.
 */
module tools.search_base;

import std.json : JSONValue, parseJSON, JSONType;
import tools.base : BaseTool;
import storage.connection : DBConnection;
import storage.search : HybridSearch;
import mcp.types : ToolResult;

/**
 * Abstract base class for tools that perform searches against the local database.
 *
 * Uses lazy initialization to open the database connection on first use rather
 * than at construction time. This avoids holding open connections for tools that
 * may never be invoked, and is safer under concurrent HTTP use where construction
 * happens at startup but queries happen much later on different threads.
 *
 * Subclasses access the `search` property which triggers connection setup
 * automatically. The connection is closed on destruction or via explicit `close()`.
 */
abstract class SearchTool : BaseTool {
	private DBConnection _conn; /// Lazily-initialized database connection.
	private HybridSearch _search; /// Lazily-initialized hybrid search engine.

	/**
	 * Returns the hybrid search engine, opening the database connection on first access.
	 *
	 * Returns: The initialized `HybridSearch` instance.
	 */
	protected @property HybridSearch search()
	{
		ensureConnection();
		return _search;
	}

	/**
	 * Opens the database connection and search engine if not already open.
	 */
	private void ensureConnection()
	{
		if(_conn is null) {
			_conn = new DBConnection("data/search.db");
			_search = new HybridSearch(_conn);
		}
	}

	/**
	 * Explicitly closes the database connection and releases resources.
	 */
	void close()
	{
		if(_conn !is null) {
			_conn.close();
			_conn = null;
			_search = null;
		}
	}

	/** Closes the database connection on destruction. */
	~this()
	{
		close();
	}

	/**
	 * Extracts an integer parameter from the tool arguments, with a default fallback.
	 *
	 * Params:
	 *     args = The JSON arguments object from the tool invocation.
	 *     key = The parameter name to look up.
	 *     defaultVal = The value to return if the key is missing or not an integer.
	 *
	 * Returns: The integer value of the parameter, or `defaultVal`.
	 */
	protected int getIntParam(JSONValue args, string key, int defaultVal)
	{
		if(key in args && args[key].type == JSONType.integer) {
			return cast(int)args[key].integer;
		}
		return defaultVal;
	}

	/**
	 * Extracts a string parameter from the tool arguments, with a default fallback.
	 *
	 * Params:
	 *     args = The JSON arguments object from the tool invocation.
	 *     key = The parameter name to look up.
	 *     defaultVal = The value to return if the key is missing or not a string.
	 *
	 * Returns: The string value of the parameter, or `defaultVal`.
	 */
	protected string getStringParam(JSONValue args, string key, string defaultVal = "")
	{
		if(key in args && args[key].type == JSONType.string) {
			return args[key].str;
		}
		return defaultVal;
	}
}
