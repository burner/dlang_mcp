module utils.logging;

import std.stdio : stderr;
import std.datetime.systime : Clock;
import std.format : formattedWrite;

void logError(string message)
{
	import std.format : format;

	stderr.writeln(format("[ERROR] %s", message));
}

void logInfo(string message)
{
	import std.format : format;

	stderr.writeln(format("[INFO] %s", message));
}

void logDebug(string message)
{
	debug {
		import std.format : format;

		stderr.writeln(format("[DEBUG] %s", message));
	}
}
