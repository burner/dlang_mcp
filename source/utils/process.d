/**
 * Process execution utilities for running external commands and capturing output.
 *
 * All subprocess executions use a configurable timeout (default: 30 seconds)
 * to prevent hung processes from blocking the server indefinitely.
 */
module utils.process;

import std.process : pipeProcess, Redirect, wait, Pid, tryWait, kill, Config, execute;
import std.stdio : File;
import std.array : appender;
import std.string : strip;
import core.time : Duration, dur, MonoTime;

/**
 * Captures the exit status and output streams of a completed process.
 */
struct ProcessResult {
	/** Exit status code returned by the process. Zero typically indicates success. */
	int status;
	/** Captured standard output from the process, with leading/trailing whitespace stripped. */
	string output;
	/** Captured standard error output from the process, with leading/trailing whitespace stripped. */
	string stderrOutput;
}

/**
 * Exception thrown when a subprocess exceeds its allowed execution time.
 */
class ProcessTimeoutException : Exception {
	this(string msg, string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, file, line);
	}
}

// ---------------------------------------------------------------------------
// Global timeout configuration
// ---------------------------------------------------------------------------

/// Default timeout for subprocess execution.
private __gshared Duration _processTimeout = dur!"seconds"(30);

/**
 * Set the global process timeout. Called once at startup.
 *
 * Params:
 *     timeout = Maximum duration to wait for any subprocess.
 */
void setProcessTimeout(Duration timeout) @trusted nothrow
{
	_processTimeout = timeout;
}

// ---------------------------------------------------------------------------
// Timeout-aware wait
// ---------------------------------------------------------------------------

/**
 * Wait for a process with a timeout. Kills the process if it exceeds
 * the deadline and throws ProcessTimeoutException.
 *
 * Params:
 *     pid     = The process to wait for.
 *     timeout = Maximum duration to wait.
 *
 * Returns:
 *     The process exit status code.
 *
 * Throws:
 *     ProcessTimeoutException if the process exceeds the timeout.
 */
private int waitWithTimeout(Pid pid, Duration timeout)
{
	import core.thread : Thread;
	import std.conv : to;

	auto deadline = MonoTime.currTime + timeout;
	while(MonoTime.currTime < deadline) {
		auto result = tryWait(pid);
		if(result.terminated)
			return result.status;
		Thread.sleep(dur!"msecs"(50));
	}
	// Timeout exceeded — kill the process
	try {
		kill(pid, 9); // SIGKILL
	} catch(Exception) {
	}
	// Reap the zombie
	try {
		wait(pid);
	} catch(Exception) {
	}
	throw new ProcessTimeoutException("Process timed out after " ~ timeout.total!"seconds"
			.to!string ~ " seconds");
}

// ---------------------------------------------------------------------------
// Helpers for concurrent pipe reading
// ---------------------------------------------------------------------------

/// Read all lines from a File into a string. Used by stderr reader thread.
private string readAllLines(File f)
{
	auto app = appender!string;
	foreach(line; f.byLine)
		app ~= line ~ "\n";
	return app.data;
}

/**
 * Execute a command and capture its combined output with timeout.
 *
 * Runs the given command and returns the exit status along with the
 * captured standard output. Standard error is captured separately.
 *
 * Params:
 *     command = Array of strings representing the command and its arguments.
 *
 * Returns:
 *     A $(D ProcessResult) containing the exit status and stripped output.
 *
 * Throws:
 *     ProcessTimeoutException if the process exceeds the global timeout.
 */
ProcessResult executeCommand(string[] command)
{
	import core.thread : Thread;

	auto pipes = pipeProcess(command, Redirect.stdout | Redirect.stderr);

	// Read both stdout and stderr on separate threads to avoid pipe deadlocks
	// and allow the main thread to enforce the timeout.
	string stdoutData;
	auto stdoutThread = new Thread({ stdoutData = readAllLines(pipes.stdout); });
	stdoutThread.start();

	string stderrData;
	auto stderrThread = new Thread({ stderrData = readAllLines(pipes.stderr); });
	stderrThread.start();

	// Ensure reader threads are joined even if waitWithTimeout throws
	scope(exit) {
		import std.exception : collectException;

		collectException(stdoutThread.join());
		collectException(stderrThread.join());
	}

	int status = waitWithTimeout(pipes.pid, _processTimeout);

	return ProcessResult(status, stdoutData.strip(), stderrData.strip());
}

/**
 * Execute a command capturing both stdout and stderr separately,
 * with optional working directory and timeout.
 *
 * Reads stderr on a separate thread to prevent pipe deadlocks when
 * both stdout and stderr produce large output.
 *
 * Params:
 *     command = Array of strings representing the command and its arguments.
 *     workDir = Optional working directory for the subprocess.
 *
 * Returns:
 *     A $(D ProcessResult) containing the exit status, stripped stdout,
 *     and stripped stderr.
 *
 * Throws:
 *     ProcessTimeoutException if the process exceeds the global timeout.
 */
ProcessResult executeCommandInDir(string[] command, string workDir = null)
{
	import core.thread : Thread;

	auto pipes = pipeProcess(command, Redirect.stdout | Redirect.stderr,
			cast(const string[string])null, Config.none, workDir);

	// Read both stdout and stderr on separate threads to avoid blocking
	// the main thread, which handles timeout enforcement.
	string stdoutData;
	auto stdoutThread = new Thread({ stdoutData = readAllLines(pipes.stdout); });
	stdoutThread.start();

	string stderrData;
	auto stderrThread = new Thread({ stderrData = readAllLines(pipes.stderr); });
	stderrThread.start();

	scope(exit) {
		import std.exception : collectException;

		collectException(stdoutThread.join());
		collectException(stderrThread.join());
	}

	int status = waitWithTimeout(pipes.pid, _processTimeout);

	return ProcessResult(status, stdoutData.strip(), stderrData.strip());
}

/**
 * Execute a command with data piped to its standard input, with timeout.
 *
 * Spawns the command, writes the provided input string to its stdin,
 * then closes stdin and collects both stdout and stderr output.
 * Stderr is read on a separate thread to prevent pipe deadlocks.
 *
 * Params:
 *     command = Array of strings representing the command and its arguments.
 *     input   = String data to write to the process's standard input.
 *
 * Returns:
 *     A $(D ProcessResult) containing the exit status, stripped stdout,
 *     and stripped stderr.
 *
 * Throws:
 *     ProcessTimeoutException if the process exceeds the global timeout.
 */
ProcessResult executeCommandWithInput(string[] command, string input)
{
	import core.thread : Thread;

	auto pipes = pipeProcess(command, Redirect.stdin | Redirect.stdout | Redirect.stderr);

	pipes.stdin.writeln(input);
	pipes.stdin.flush();
	pipes.stdin.close();

	// Read both stdout and stderr on separate threads to avoid blocking
	// the main thread, which handles timeout enforcement.
	string stdoutData;
	auto stdoutThread = new Thread({ stdoutData = readAllLines(pipes.stdout); });
	stdoutThread.start();

	string stderrData;
	auto stderrThread = new Thread({ stderrData = readAllLines(pipes.stderr); });
	stderrThread.start();

	scope(exit) {
		import std.exception : collectException;

		collectException(stdoutThread.join());
		collectException(stderrThread.join());
	}

	int status = waitWithTimeout(pipes.pid, _processTimeout);

	return ProcessResult(status, stdoutData.strip(), stderrData.strip());
}
