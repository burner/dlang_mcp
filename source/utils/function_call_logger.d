/**
 * Singleton logger for recording MCP function calls to a file.
 *
 * Logs timestamp, method name, and arguments for each MCP method invocation.
 * Failures are silently ignored to avoid disrupting server operation.
 */
module utils.function_call_logger;

import std.stdio : File;
import std.datetime.systime : Clock, SysTime;
import std.conv : to;
import std.json : JSONValue, JSONType;

/**
 * Singleton logger that writes MCP function call records to a file.
 *
 * Usage:
 *   auto logger = FunctionCallLogger.getInstance();
 *   logger.setLogFile("calls.log");
 *   logger.log("tools/call", toolName, arguments);
 */
class FunctionCallLogger {
	private static FunctionCallLogger instance;
	private File logFile;
	private bool active = false;

	private this()
	{
	}

	/**
	 * Returns the singleton logger instance.
	 */
	static FunctionCallLogger getInstance()
	{
		if(instance is null)
			instance = new FunctionCallLogger();
		return instance;
	}

	/**
	 * Sets the log file path and activates logging.
	 *
	 * If the file cannot be opened, logging remains inactive and
	 * the error is silently ignored.
	 *
	 * Params:
	 *     path = Filesystem path for the log file.
	 */
	void setLogFile(string path)
	{
		try {
			logFile = File(path, "a");
			active = true;
		} catch(Exception) {
			active = false;
		}
	}

	/**
	 * Logs an MCP method call with timestamp, method name, and optional details.
	 *
	 * If logging is inactive or the write fails, the call is silently ignored.
	 *
	 * Params:
	 *     method = The MCP method name (e.g., "tools/call", "initialize").
	 *     detail = Optional detail string (e.g., tool name for tools/call).
	 *     arguments = Optional JSON arguments object.
	 */
	void log(string method, string detail = "", JSONValue arguments = JSONValue.init)
	{
		if(!active)
			return;

		try {
			SysTime now = Clock.currTime();
			string timestamp = to!string(now);

			string line = timestamp ~ " | " ~ method;

			if(detail.length > 0)
				line ~= " | " ~ detail;

			if(arguments.type != JSONType.null_) {
				import std.json : toJSON;

				line ~= " | " ~ arguments.toJSON();
			}

			logFile.writeln(line);
			logFile.flush();
		} catch(Exception) {
		}
	}

	/**
	 * Closes the log file and deactivates logging.
	 */
	void close()
	{
		if(active) {
			try {
				logFile.close();
			} catch(Exception) {
			}
			active = false;
		}
	}

	~this()
	{
		close();
	}
}
