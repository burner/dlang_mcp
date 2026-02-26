/**
 * Base class for database-backed search tools.
 *
 * Provides shared infrastructure for tools that query the search database,
 * including database connection management and parameter extraction helpers.
 */
module tools.search_base;

import std.json : JSONValue, parseJSON, JSONType;
import std.file : exists;
import tools.base : BaseTool;
import storage.connection : DBConnection;
import storage.search : HybridSearch;
import mcp.types : ToolResult;

/** Exception thrown when the search database is not available. */
class SearchDBNotFoundException : Exception {
	this(string msg) pure nothrow @safe
	{
		super(msg);
	}
}

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
			if(!exists("data/search.db")) {
				throw new SearchDBNotFoundException("Search database not available. "
						~ "Run the server with --init-db to create it, then --ingest to populate it.");
			}
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

version(unittest) {
	/// Concrete subclass of SearchTool for testing protected/abstract members.
	private class TestableSearchTool : SearchTool {
		@property string name()
		{
			return "test_search";
		}

		@property string description()
		{
			return "A testable search tool";
		}

		@property JSONValue inputSchema()
		{
			return parseJSON(`{"type":"object","properties":{}}`);
		}

		ToolResult execute(JSONValue arguments)
		{
			return createTextResult("ok");
		}

		// Expose protected methods for testing
		int testGetIntParam(JSONValue args, string key, int defaultVal)
		{
			return getIntParam(args, key, defaultVal);
		}

		string testGetStringParam(JSONValue args, string key, string defaultVal = "")
		{
			return getStringParam(args, key, defaultVal);
		}
	}
}

/// getIntParam returns integer value when key exists and is integer type
unittest {
	import std.format : format;

	auto tool = new TestableSearchTool();
	auto args = parseJSON(`{"limit": 42, "offset": 0}`);

	int result = tool.testGetIntParam(args, "limit", 10);
	assert(result == 42, format("Expected 42, got %d", result));

	int result2 = tool.testGetIntParam(args, "offset", 5);
	assert(result2 == 0, format("Expected 0, got %d", result2));
}

/// getIntParam returns default when key is missing
unittest {
	import std.format : format;

	auto tool = new TestableSearchTool();
	auto args = parseJSON(`{"other": 1}`);

	int result = tool.testGetIntParam(args, "limit", 20);
	assert(result == 20, format("Expected default 20, got %d", result));
}

/// getIntParam returns default when key exists but is not integer type
unittest {
	import std.format : format;

	auto tool = new TestableSearchTool();
	auto args = parseJSON(`{"limit": "not_a_number"}`);

	int result = tool.testGetIntParam(args, "limit", 15);
	assert(result == 15, format("Expected default 15 for string value, got %d", result));
}

/// getIntParam returns default when key is a float/boolean/null/array/object
unittest {
	import std.format : format;

	auto tool = new TestableSearchTool();

	// float value
	auto args1 = parseJSON(`{"limit": 3.14}`);
	int r1 = tool.testGetIntParam(args1, "limit", 99);
	assert(r1 == 99, format("Expected default 99 for float value, got %d", r1));

	// boolean value
	auto args2 = parseJSON(`{"limit": true}`);
	int r2 = tool.testGetIntParam(args2, "limit", 99);
	assert(r2 == 99, format("Expected default 99 for bool value, got %d", r2));

	// null value
	auto args3 = parseJSON(`{"limit": null}`);
	int r3 = tool.testGetIntParam(args3, "limit", 99);
	assert(r3 == 99, format("Expected default 99 for null value, got %d", r3));

	// array value
	auto args4 = parseJSON(`{"limit": [1, 2]}`);
	int r4 = tool.testGetIntParam(args4, "limit", 99);
	assert(r4 == 99, format("Expected default 99 for array value, got %d", r4));

	// object value
	auto args5 = parseJSON(`{"limit": {"a": 1}}`);
	int r5 = tool.testGetIntParam(args5, "limit", 99);
	assert(r5 == 99, format("Expected default 99 for object value, got %d", r5));
}

/// getIntParam works with empty args object
unittest {
	import std.format : format;

	auto tool = new TestableSearchTool();
	auto args = parseJSON(`{}`);

	int result = tool.testGetIntParam(args, "anything", 7);
	assert(result == 7, format("Expected default 7 for empty args, got %d", result));
}

/// getIntParam handles negative integers
unittest {
	import std.format : format;

	auto tool = new TestableSearchTool();
	auto args = parseJSON(`{"offset": -5}`);

	int result = tool.testGetIntParam(args, "offset", 0);
	assert(result == -5, format("Expected -5, got %d", result));
}

/// getStringParam returns string value when key exists and is string type
unittest {
	import std.format : format;

	auto tool = new TestableSearchTool();
	auto args = parseJSON(`{"query": "hello world", "package": "std"}`);

	string result = tool.testGetStringParam(args, "query");
	assert(result == "hello world", format("Expected 'hello world', got '%s'", result));

	string result2 = tool.testGetStringParam(args, "package");
	assert(result2 == "std", format("Expected 'std', got '%s'", result2));
}

/// getStringParam returns default when key is missing
unittest {
	import std.format : format;

	auto tool = new TestableSearchTool();
	auto args = parseJSON(`{"other": "value"}`);

	string result = tool.testGetStringParam(args, "query", "default_val");
	assert(result == "default_val", format("Expected 'default_val', got '%s'", result));
}

/// getStringParam returns empty string default when key is missing and no default specified
unittest {
	import std.format : format;

	auto tool = new TestableSearchTool();
	auto args = parseJSON(`{}`);

	string result = tool.testGetStringParam(args, "query");
	assert(result == "", format("Expected empty string, got '%s'", result));
}

/// getStringParam returns default when key exists but is not string type
unittest {
	import std.format : format;

	auto tool = new TestableSearchTool();

	// integer value
	auto args1 = parseJSON(`{"query": 42}`);
	string r1 = tool.testGetStringParam(args1, "query", "fallback");
	assert(r1 == "fallback", format("Expected 'fallback' for integer value, got '%s'", r1));

	// boolean value
	auto args2 = parseJSON(`{"query": false}`);
	string r2 = tool.testGetStringParam(args2, "query", "fallback");
	assert(r2 == "fallback", format("Expected 'fallback' for bool value, got '%s'", r2));

	// null value
	auto args3 = parseJSON(`{"query": null}`);
	string r3 = tool.testGetStringParam(args3, "query", "fallback");
	assert(r3 == "fallback", format("Expected 'fallback' for null value, got '%s'", r3));

	// array value
	auto args4 = parseJSON(`{"query": ["a", "b"]}`);
	string r4 = tool.testGetStringParam(args4, "query", "fallback");
	assert(r4 == "fallback", format("Expected 'fallback' for array value, got '%s'", r4));
}

/// getStringParam handles empty string value (not missing, but empty)
unittest {
	import std.format : format;

	auto tool = new TestableSearchTool();
	auto args = parseJSON(`{"query": ""}`);

	string result = tool.testGetStringParam(args, "query", "default");
	assert(result == "", format("Expected empty string (actual value), got '%s'", result));
}

/// getStringParam handles strings with special characters
unittest {
	import std.format : format;

	auto tool = new TestableSearchTool();
	auto args = parseJSON(`{"query": "hello\nworld\ttab"}`);

	string result = tool.testGetStringParam(args, "query");
	assert(result == "hello\nworld\ttab",
			format("Expected string with special chars, got '%s'", result));
}

/// close() is safe to call when no connection has been opened
unittest {
	auto tool = new TestableSearchTool();
	// Should not throw when called without any prior connection
	tool.close();
	// Should be safe to call multiple times
	tool.close();
}

/// SearchDBNotFoundException is throwable and has correct message
unittest {
	import std.format : format;
	import std.algorithm.searching : canFind;

	auto ex = new SearchDBNotFoundException("test error message");
	assert(ex.msg == "test error message",
			format("Expected 'test error message', got '%s'", ex.msg));
	assert(ex.msg.canFind("test error"), "Exception message should contain the provided text");
}

/// SearchDBNotFoundException can be caught as Exception
unittest {
	bool caught = false;
	try {
		throw new SearchDBNotFoundException("db not found");
	} catch(Exception e) {
		caught = true;
		assert(e.msg == "db not found", "Caught exception should have the correct message");
	}
	assert(caught, "SearchDBNotFoundException should be catchable as Exception");
}

/// TestableSearchTool has correct name, description, and schema
unittest {
	import std.format : format;

	auto tool = new TestableSearchTool();
	assert(tool.name == "test_search", format("Expected 'test_search', got '%s'", tool.name));
	assert(tool.description == "A testable search tool",
			format("Expected 'A testable search tool', got '%s'", tool.description));
	auto schema = tool.inputSchema;
	assert(schema["type"].str == "object", "Schema type should be 'object'");
}

/// execute returns non-error result
unittest {
	auto tool = new TestableSearchTool();
	auto args = parseJSON(`{}`);
	auto result = tool.execute(args);
	assert(!result.isError, "execute should return a non-error result");
	assert(result.content.length > 0, "execute should return content");
	assert(result.content[0].text == "ok", "execute should return 'ok'");
}
