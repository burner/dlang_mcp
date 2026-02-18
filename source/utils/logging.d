/**
 * Simple stderr-based logging utilities with severity levels.
 *
 * All logging output goes to stderr to avoid contaminating stdout,
 * which is reserved for JSON-RPC protocol messages in stdio mode.
 * Verbose logging (INFO, DEBUG) is disabled by default and can be
 * enabled via the `--verbose` CLI flag.
 */
module utils.logging;

import std.stdio : stderr;

/** Controls the minimum severity level that produces output. */
enum LogLevel {
	debug_,
	info,
	error,
	silent
}

private __gshared LogLevel _minLevel = LogLevel.error;

/**
 * Sets the minimum log level. Messages below this level are suppressed.
 *
 * Params:
 *     level = The minimum severity to emit.
 */
void setLogLevel(LogLevel level) @trusted nothrow
{
	_minLevel = level;
}

/**
 * Enables verbose logging (INFO and above).
 *
 * Call this when the `--verbose` CLI flag is present.
 */
void enableVerboseLogging() @trusted nothrow
{
	_minLevel = LogLevel.info;
}

/**
 * Returns the current minimum log level.
 */
LogLevel getLogLevel() @trusted nothrow
{
	return _minLevel;
}

/**
 * Log an error-level message to standard error.
 *
 * Error messages are always emitted regardless of verbosity setting.
 *
 * Params:
 *     message = The error message to log.
 */
void logError(string message)
{
	if(_minLevel <= LogLevel.error) {
		import std.format : format;

		stderr.writeln(format("[ERROR] %s", message));
	}
}

/**
 * Log an informational message to standard error.
 *
 * Only produces output when verbose logging is enabled.
 *
 * Params:
 *     message = The informational message to log.
 */
void logInfo(string message)
{
	if(_minLevel <= LogLevel.info) {
		import std.format : format;

		stderr.writeln(format("[INFO] %s", message));
	}
}

/**
 * Log a debug-level message to standard error.
 *
 * Only produces output when verbose logging is enabled and
 * compiled in debug mode.
 *
 * Params:
 *     message = The debug message to log.
 */
void logDebug(string message)
{
	debug {
		if(_minLevel <= LogLevel.debug_) {
			import std.format : format;

			stderr.writeln(format("[DEBUG] %s", message));
		}
	}
}
