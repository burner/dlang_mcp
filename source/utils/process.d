/**
 * Process execution utilities for running external commands and capturing output.
 */
module utils.process;

import std.process : execute, pipeProcess, Redirect, wait, Pid;
import std.stdio : File;
import std.array : appender;
import std.string : strip;

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
 * Execute a command and capture its combined output.
 *
 * Runs the given command using the system shell and returns the exit status
 * along with the captured standard output. Standard error is not captured
 * separately and will be empty in the result.
 *
 * Params:
 *     command = Array of strings representing the command and its arguments.
 *
 * Returns:
 *     A $(D ProcessResult) containing the exit status and stripped stdout output.
 */
ProcessResult executeCommand(string[] command)
{
	auto result = execute(command);
	return ProcessResult(result.status, result.output.strip(), "");
}

/** Execute a command capturing both stdout and stderr separately, with optional working directory */
ProcessResult executeCommandInDir(string[] command, string workDir = null)
{
	import std.process : Config;

	auto pipes = pipeProcess(command, Redirect.stdout | Redirect.stderr,
			cast(const string[string]) null, Config.none, workDir);

	auto stdoutApp = appender!string;
	foreach (line; pipes.stdout.byLine)
	{
		stdoutApp ~= line ~ "\n";
	}

	auto stderrApp = appender!string;
	foreach (line; pipes.stderr.byLine)
	{
		stderrApp ~= line ~ "\n";
	}

	int status = wait(pipes.pid);

	return ProcessResult(status, stdoutApp.data.strip(), stderrApp.data.strip());
}

/**
 * Execute a command with data piped to its standard input.
 *
 * Spawns the command, writes the provided input string to its stdin,
 * then closes stdin and collects both stdout and stderr output.
 *
 * Params:
 *     command = Array of strings representing the command and its arguments.
 *     input   = String data to write to the process's standard input.
 *
 * Returns:
 *     A $(D ProcessResult) containing the exit status, stripped stdout, and stripped stderr.
 */
ProcessResult executeCommandWithInput(string[] command, string input)
{
	auto pipes = pipeProcess(command, Redirect.stdin | Redirect.stdout | Redirect.stderr);

	pipes.stdin.writeln(input);
	pipes.stdin.flush();
	pipes.stdin.close();

	auto stdoutApp = appender!string;
	foreach(line; pipes.stdout.byLine) {
		stdoutApp ~= line ~ "\n";
	}

	auto stderrApp = appender!string;
	foreach(line; pipes.stderr.byLine) {
		stderrApp ~= line ~ "\n";
	}

	int status = wait(pipes.pid);

	return ProcessResult(status, stdoutApp.data.strip(), stderrApp.data.strip());
}
