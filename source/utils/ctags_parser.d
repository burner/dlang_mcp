/**
 * Parser for Universal Ctags output, extracting symbol definitions from tag files.
 */
module utils.ctags_parser;

import std.stdio : File;
import std.string : split, strip, indexOf;
import std.regex : regex, match;
import std.file : exists;
import std.algorithm.searching : startsWith;

/**
 * A single symbol entry parsed from a ctags output line.
 */
struct CtagsEntry {
	/** Name of the symbol (function, class, variable, etc.). */
	string symbol;
	/** Source file path where the symbol is defined. */
	string file;
	/** Line number in the source file where the symbol is defined. */
	int line;
	/** Single-character kind code (e.g. "f" for function, "c" for class). */
	string kind;
	/** Enclosing scope name (class, struct, enum, or interface that contains this symbol). */
	string scopeName;
	/** Access level of the symbol (e.g. "public", "private", "protected"). */
	string access;
	/** Function or method signature, if available. */
	string signature;
}

/**
 * Parse a single line of ctags output into a $(D CtagsEntry).
 *
 * Handles the standard ctags tab-separated format, extracting the symbol name,
 * file path, line number, and optional extended fields (kind, scope, access,
 * signature). Comment lines (starting with '!') and empty lines are skipped.
 *
 * Params:
 *     line = A single line from a ctags output file.
 *
 * Returns:
 *     A populated $(D CtagsEntry), or $(D CtagsEntry.init) if the line is
 *     empty, a comment, or malformed.
 */
CtagsEntry parseCtagsLine(string line)
{
	if(line.length == 0 || line[0] == '!')
		return CtagsEntry.init;

	auto parts = line.split('\t');
	if(parts.length < 3)
		return CtagsEntry.init;

	CtagsEntry entry;
	entry.symbol = parts[0];
	entry.file = parts[1];

	string lineField = parts[2];
	auto semiIdx = lineField.indexOf(";\t\"");
	if(semiIdx >= 0) {
		lineField = lineField[0 .. semiIdx];
	}
	entry.line = parseLineField(lineField);

	for(size_t i = 3; i < parts.length; i++) {
		auto field = parts[i];
		if(field.length == 1) {
			entry.kind = field;
		} else if(field.startsWith("line:")) {
			entry.line = parseLineField(field[5 .. $]);
		} else if(field.startsWith("class:") || field.startsWith("struct:")
				|| field.startsWith("enum:") || field.startsWith("interface:")) {
			auto colonIdx = field.indexOf(':');
			if(colonIdx >= 0) {
				entry.scopeName = field[colonIdx + 1 .. $];
			}
		} else if(field.startsWith("access:")) {
			entry.access = field[7 .. $];
		} else if(field.startsWith("signature:")) {
			entry.signature = field[10 .. $];
		}
	}

	return entry;
}

/**
 * Parse a line-number field from ctags output into an integer.
 *
 * Strips whitespace and converts the field to an int. Returns 0 if the
 * field cannot be parsed.
 *
 * Params:
 *     field = The raw line-number string from a ctags entry.
 *
 * Returns:
 *     The parsed line number, or 0 on failure.
 */
int parseLineField(string field)
{
	import std.conv : to;

	try {
		return to!int(field.strip());
	} catch(Exception) {
		return 0;
	}
}

/**
 * Parse an entire ctags file and return all valid entries.
 *
 * Reads the file line by line, parses each with $(D parseCtagsLine), and
 * collects entries that have a non-empty symbol name.
 *
 * Params:
 *     tagsPath = Filesystem path to the ctags output file.
 *
 * Returns:
 *     An array of $(D CtagsEntry) for every valid symbol found in the file.
 *     Returns an empty array if the file does not exist.
 */
CtagsEntry[] parseCtagsFile(string tagsPath)
{
	CtagsEntry[] entries;

	if(!exists(tagsPath))
		return entries;

	auto file = File(tagsPath, "r");
	foreach(string line; file.byLineCopy) {
		auto entry = parseCtagsLine(line.strip());
		if(entry.symbol.length > 0) {
			entries ~= entry;
		}
	}

	return entries;
}

/**
 * Search ctags entries by symbol name with configurable match strategy and kind filter.
 *
 * Params:
 *     entries    = Array of $(D CtagsEntry) to search through.
 *     query      = The search string or regex pattern to match against symbol names.
 *     matchType  = Match strategy: "exact" for equality, "prefix" for starts-with,
 *                  "regex" for regular expression matching. Defaults to exact on
 *                  unrecognized values.
 *     kindFilter = If non-empty, only entries whose kind matches this value are included.
 *
 * Returns:
 *     An array of matching $(D CtagsEntry) values.
 */
CtagsEntry[] searchEntries(CtagsEntry[] entries, string query, string matchType, string kindFilter)
{
	CtagsEntry[] results;

	foreach(entry; entries) {
		if(kindFilter.length > 0 && entry.kind != kindFilter)
			continue;

		bool matches = false;
		switch(matchType) {
		case "exact":
			matches = (entry.symbol == query);
			break;
		case "prefix":
			matches = entry.symbol.startsWith(query);
			break;
		case "regex":
			try {
				auto pattern = regex(query);
				matches = !match(entry.symbol, pattern).empty;
			} catch(Exception) {
				matches = (entry.symbol == query);
			}
			break;
		default:
			matches = (entry.symbol == query);
		}

		if(matches)
			results ~= entry;
	}

	return results;
}

/**
 * Format a $(D CtagsEntry) into a human-readable summary string.
 *
 * Produces a tab-separated representation including the symbol name,
 * file location with line number, kind, signature, scope, and access level
 * where available.
 *
 * Params:
 *     entry = The ctags entry to format.
 *
 * Returns:
 *     A formatted string summarizing the entry.
 */
string formatEntry(ref const CtagsEntry entry)
{
	import std.conv : text;

	string result = entry.symbol ~ "\t" ~ entry.file ~ ":" ~ text(entry.line);
	if(entry.kind.length > 0)
		result ~= "\t" ~ kindToString(entry.kind);
	if(entry.signature.length > 0)
		result ~= " " ~ entry.signature;
	if(entry.scopeName.length > 0)
		result ~= " [" ~ entry.scopeName ~ "]";
	if(entry.access.length > 0)
		result ~= " (" ~ entry.access ~ ")";
	return result;
}

/**
 * Convert a single-character ctags kind code to a human-readable string.
 *
 * Params:
 *     kind = The single-character kind code (e.g. "f", "c", "s").
 *
 * Returns:
 *     A descriptive string such as "function", "class", or "struct".
 *     Returns the original kind string unchanged if it is not recognized.
 */
string kindToString(string kind)
{
	switch(kind) {
	case "f":
		return "function";
	case "c":
		return "class";
	case "s":
		return "struct";
	case "g":
		return "enum";
	case "i":
		return "interface";
	case "v":
		return "variable";
	case "e":
		return "enum_member";
	case "m":
		return "member";
	case "p":
		return "property";
	default:
		return kind;
	}
}
