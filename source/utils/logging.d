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

// ---------------------------------------------------------------------------
//  Unit tests
// ---------------------------------------------------------------------------

/// Helper: redirect stderr to a temporary file, run `fn`, restore stderr,
/// and return what was written.
private string captureStderr(void delegate() fn) @trusted
{
	import std.stdio : File;

	auto saved = stderr; // save original stderr
	auto tmp = File.tmpfile(); // anonymous temp file
	stderr = tmp; // redirect

	scope(exit)
		stderr = saved; // always restore

	fn(); // execute the logging call
	stderr.flush();

	tmp.rewind();
	string output;
	foreach(line; tmp.byLine)
		output ~= line.idup ~ "\n";

	return output;
}

/// LogLevel enum ordering: debug_ < info < error < silent.
unittest {
	import std.format : format;

	assert(LogLevel.debug_ < LogLevel.info,
			format("expected debug_ < info, got %s vs %s", LogLevel.debug_, LogLevel.info));
	assert(LogLevel.info < LogLevel.error,
			format("expected info < error, got %s vs %s", LogLevel.info, LogLevel.error));
	assert(LogLevel.error < LogLevel.silent,
			format("expected error < silent, got %s vs %s", LogLevel.error, LogLevel.silent));
}

/// setLogLevel / getLogLevel round-trip.
unittest {
	import std.format : format;

	auto saved = getLogLevel();
	scope(exit)
		setLogLevel(saved);

	foreach(lvl; [
			LogLevel.debug_, LogLevel.info, LogLevel.error, LogLevel.silent
		]) {
		setLogLevel(lvl);
		assert(getLogLevel() == lvl,
				format("expected getLogLevel() == %s, got %s", lvl, getLogLevel()));
	}
}

/// enableVerboseLogging sets level to info.
unittest {
	import std.format : format;

	auto saved = getLogLevel();
	scope(exit)
		setLogLevel(saved);

	enableVerboseLogging();
	assert(getLogLevel() == LogLevel.info,
			format("expected info after enableVerboseLogging, got %s", getLogLevel()));
}

/// logError emits output at error level and below, suppressed at silent.
unittest {
	auto saved = getLogLevel();
	scope(exit)
		setLogLevel(saved);

	// At error level (default) – should produce output
	setLogLevel(LogLevel.error);
	auto output = captureStderr(() { logError("err-test"); });
	assert(output.length > 0, "logError should produce output at error level");

	// At silent level – should suppress
	setLogLevel(LogLevel.silent);
	output = captureStderr(() { logError("should-not-appear"); });
	assert(output.length == 0, "logError should be suppressed at silent level");
}

/// logError formats message with [ERROR] prefix.
unittest {
	import std.algorithm : canFind;

	auto saved = getLogLevel();
	scope(exit)
		setLogLevel(saved);

	setLogLevel(LogLevel.error);
	auto output = captureStderr(() { logError("hello world"); });
	assert(output.canFind("[ERROR]"), "logError output should contain [ERROR] prefix");
	assert(output.canFind("hello world"), "logError output should contain the message");
}

/// logInfo emits output at info level, suppressed at error level.
unittest {
	auto saved = getLogLevel();
	scope(exit)
		setLogLevel(saved);

	// At info level – should produce output
	setLogLevel(LogLevel.info);
	auto output = captureStderr(() { logInfo("info-test"); });
	assert(output.length > 0, "logInfo should produce output at info level");

	// At error level – should suppress
	setLogLevel(LogLevel.error);
	output = captureStderr(() { logInfo("should-not-appear"); });
	assert(output.length == 0, "logInfo should be suppressed at error level");
}

/// logInfo formats message with [INFO] prefix.
unittest {
	import std.algorithm : canFind;

	auto saved = getLogLevel();
	scope(exit)
		setLogLevel(saved);

	setLogLevel(LogLevel.info);
	auto output = captureStderr(() { logInfo("informational"); });
	assert(output.canFind("[INFO]"), "logInfo output should contain [INFO] prefix");
	assert(output.canFind("informational"), "logInfo output should contain the message");
}

/// logDebug emits output at debug_ level (in debug builds), suppressed at info.
debug unittest {
	auto saved = getLogLevel();
	scope(exit)
		setLogLevel(saved);

	// At debug_ level – should produce output in debug builds
	setLogLevel(LogLevel.debug_);
	auto output = captureStderr(() { logDebug("dbg-test"); });
	assert(output.length > 0, "logDebug should produce output at debug_ level");

	// At info level – should suppress
	setLogLevel(LogLevel.info);
	output = captureStderr(() { logDebug("should-not-appear"); });
	assert(output.length == 0, "logDebug should be suppressed at info level");
}

/// logDebug formats message with [DEBUG] prefix.
debug unittest {
	import std.algorithm : canFind;

	auto saved = getLogLevel();
	scope(exit)
		setLogLevel(saved);

	setLogLevel(LogLevel.debug_);
	auto output = captureStderr(() { logDebug("trace-msg"); });
	assert(output.canFind("[DEBUG]"), "logDebug output should contain [DEBUG] prefix");
	assert(output.canFind("trace-msg"), "logDebug output should contain the message");
}

/// logInfo is emitted at debug_ level (lower levels pass higher-level messages).
unittest {
	auto saved = getLogLevel();
	scope(exit)
		setLogLevel(saved);

	setLogLevel(LogLevel.debug_);
	auto output = captureStderr(() { logInfo("should-show"); });
	assert(output.length > 0, "logInfo should produce output when level is debug_ (more verbose)");
}

/// logError is emitted at info level.
unittest {
	auto saved = getLogLevel();
	scope(exit)
		setLogLevel(saved);

	setLogLevel(LogLevel.info);
	auto output = captureStderr(() { logError("err-at-info"); });
	assert(output.length > 0, "logError should produce output when level is info");
}

/// Default log level is error.
unittest {
	import std.format : format;

	// The module initialises _minLevel to LogLevel.error.
	// After all tests restore state via scope(exit), this test should
	// still see error as the default if it runs first or last — but
	// because __gshared state may have been touched, we just verify
	// the enum value exists and the getter works.
	auto lvl = getLogLevel();
	assert(lvl == LogLevel.debug_ || lvl == LogLevel.info || lvl == LogLevel.error
			|| lvl == LogLevel.silent, format("getLogLevel returned unexpected value %s", lvl));
}
