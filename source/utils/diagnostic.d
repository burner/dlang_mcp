/**
 * Shared diagnostic parsing utilities for D compiler output.
 *
 * Provides functions for parsing dmd/ldc2 diagnostic messages into structured
 * JSON records, merging process output streams, and collecting categorized
 * errors/warnings from compiler output. Used by build, run, test, and
 * compile-check tools.
 */
module utils.diagnostic;

import std.json : JSONValue, JSONType;
import std.string : strip, toLower;
import std.array : appender, split;
import std.conv : to;
import utils.process : ProcessResult;

/**
 * Result of collecting diagnostics from compiler output.
 *
 * Contains categorized arrays of errors, warnings, and supplemental
 * diagnostic messages parsed from compiler output text.
 */
struct DiagnosticResult {
	/// Parsed error diagnostic records (severity == "error")
	JSONValue[] errors;
	/// Parsed warning/deprecation diagnostic records
	JSONValue[] warnings;
	/// Supplemental diagnostic records (no file info, context lines)
	JSONValue[] supplemental;
}

/**
 * Merge stdout and stderr from a ProcessResult into a single string.
 *
 * Concatenates the two output streams with a newline separator when both
 * are non-empty.
 *
 * Params:
 *     result = A ProcessResult containing stdout and stderr output.
 *
 * Returns:
 *     Combined output string.
 */
string mergeOutput(ProcessResult result)
{
	string fullOutput = result.output;
	if(result.stderrOutput.length > 0) {
		if(fullOutput.length > 0)
			fullOutput ~= "\n";
		fullOutput ~= result.stderrOutput;
	}
	return fullOutput;
}

/**
 * Parse a single compiler diagnostic line into a structured JSON record.
 *
 * Handles dmd/ldc2 diagnostic formats:
 * $(UL
 *   $(LI `file(line): Error: message`)
 *   $(LI `file(line,col): Warning: message`)
 *   $(LI `Error: message` (no file info, returned as supplemental))
 * )
 *
 * The optional `tempPath` and `originalFilePath` parameters support
 * compile-check scenarios where temporary files need to be mapped back
 * to meaningful names.
 *
 * Params:
 *     line             = A single line of compiler output to parse.
 *     tempPath         = Optional path to a temporary file to replace in diagnostics.
 *     originalFilePath = Optional original file path to substitute for tempPath.
 *
 * Returns:
 *     A JSONValue object with keys (file, line, column, severity, message),
 *     or JSONValue(null) if the line is not a recognized diagnostic.
 */
JSONValue parseDiagnostic(string line, string tempPath = null, string originalFilePath = null)
{
	import std.regex : regex, matchFirst;

	// Pattern: file(line): severity: message
	// Or:      file(line,col): severity: message
	// Matches both capitalized and lowercase severity keywords
	auto re = regex(
			`^(.+?)\((\d+)(?:,(\d+))?\):\s*(Error|Warning|Deprecation|error|warning|deprecation)\s*:\s*(.+)$`);
	auto m = matchFirst(line, re);

	if(m.empty) {
		// Check for file-less diagnostics: "Error: message"
		auto reNoFile = regex(`^\s*(Error|Warning|Deprecation)\s*:\s*(.+)$`);
		auto m2 = matchFirst(line, reNoFile);
		if(!m2.empty) {
			auto entry = JSONValue(string[string].init);
			entry["severity"] = JSONValue(m2[1].idup.toLower());
			entry["message"] = JSONValue(m2[2].idup);
			return entry;
		}
		return JSONValue(null);
	}

	string file = m[1].idup;
	// Replace temp file path with something meaningful
	if(tempPath !is null && tempPath.length > 0 && file == tempPath)
		file = originalFilePath !is null ? originalFilePath : "<stdin>";

	auto entry = JSONValue(string[string].init);
	entry["file"] = JSONValue(file);
	entry["line"] = JSONValue(m[2].to!int);
	if(m[3].length > 0)
		entry["column"] = JSONValue(m[3].to!int);
	entry["severity"] = JSONValue(m[4].idup.toLower());
	entry["message"] = JSONValue(m[5].idup);

	return entry;
}

/**
 * Collect and categorize all diagnostics from compiler output text.
 *
 * Splits the output into lines, parses each with `parseDiagnostic`,
 * and sorts results into errors, warnings, and supplemental categories.
 *
 * Params:
 *     output           = Full compiler output text (may contain multiple lines).
 *     tempPath         = Optional temp file path for compile-check rewriting.
 *     originalFilePath = Optional original file path to substitute for tempPath.
 *
 * Returns:
 *     A `DiagnosticResult` containing categorized arrays of parsed diagnostics.
 */
DiagnosticResult collectDiagnostics(string output, string tempPath = null,
		string originalFilePath = null)
{
	auto errors = appender!(JSONValue[]);
	auto warnings = appender!(JSONValue[]);
	auto supplemental = appender!(JSONValue[]);

	foreach(line; output.split("\n")) {
		if(line.length == 0)
			continue;

		auto parsed = parseDiagnostic(line, tempPath, originalFilePath);
		if(parsed.type == JSONType.null_)
			continue;

		// Supplemental entries have no "file" key (file-less diagnostics)
		if("file" !in parsed) {
			supplemental ~= parsed;
			continue;
		}

		string severity = parsed["severity"].str;
		if(severity == "error")
			errors ~= parsed;
		else
			warnings ~= parsed;
	}

	DiagnosticResult result;
	result.errors = errors.data;
	result.warnings = warnings.data;
	result.supplemental = supplemental.data;
	return result;
}

// -- Unit Tests --

/// mergeOutput with both stdout and stderr
unittest {
	ProcessResult r;
	r.output = "stdout line";
	r.stderrOutput = "stderr line";
	r.status = 0;
	string merged = mergeOutput(r);
	assert(merged == "stdout line\nstderr line", "Expected merged output, got: " ~ merged);
}

/// mergeOutput with stdout only
unittest {
	ProcessResult r;
	r.output = "stdout only";
	r.stderrOutput = "";
	r.status = 0;
	string merged = mergeOutput(r);
	assert(merged == "stdout only", "Expected stdout only, got: " ~ merged);
}

/// mergeOutput with stderr only
unittest {
	ProcessResult r;
	r.output = "";
	r.stderrOutput = "stderr only";
	r.status = 0;
	string merged = mergeOutput(r);
	assert(merged == "stderr only", "Expected stderr only, got: " ~ merged);
}

/// mergeOutput with both streams empty
unittest {
	ProcessResult r;
	r.output = "";
	r.stderrOutput = "";
	r.status = 0;
	string merged = mergeOutput(r);
	assert(merged == "", "Expected empty, got: " ~ merged);
}

/// parseDiagnostic error with file, line, and column
unittest {
	auto diag = parseDiagnostic("source/app.d(42,10): Error: undefined identifier 'foo'");
	assert(diag.type != JSONType.null_, "Should parse as diagnostic");
	assert(diag["file"].str == "source/app.d");
	assert(diag["line"].integer == 42);
	assert(diag["column"].integer == 10);
	assert(diag["severity"].str == "error");
	assert(diag["message"].str == "undefined identifier 'foo'");
}

/// parseDiagnostic error with file and line only (no column)
unittest {
	auto diag = parseDiagnostic("source/app.d(42): Error: something went wrong");
	assert(diag.type != JSONType.null_, "Should parse as diagnostic");
	assert(diag["file"].str == "source/app.d");
	assert(diag["line"].integer == 42);
	assert("column" !in diag, "Should not have column");
	assert(diag["severity"].str == "error");
	assert(diag["message"].str == "something went wrong");
}

/// parseDiagnostic warning
unittest {
	auto diag = parseDiagnostic("source/foo.d(10,5): Warning: implicit conversion");
	assert(diag.type != JSONType.null_, "Should parse as diagnostic");
	assert(diag["severity"].str == "warning");
	assert(diag["file"].str == "source/foo.d");
}

/// parseDiagnostic deprecation
unittest {
	auto diag = parseDiagnostic("source/bar.d(7): Deprecation: use of old syntax");
	assert(diag.type != JSONType.null_, "Should parse as diagnostic");
	assert(diag["severity"].str == "deprecation");
	assert(diag["line"].integer == 7);
}

/// parseDiagnostic with lowercase severity
unittest {
	auto diag = parseDiagnostic("source/app.d(1): error: lowercase error msg");
	assert(diag.type != JSONType.null_, "Should parse lowercase severity");
	assert(diag["severity"].str == "error");
	assert(diag["message"].str == "lowercase error msg");
}

/// parseDiagnostic file-less error
unittest {
	auto diag = parseDiagnostic("Error: cannot find source file");
	assert(diag.type != JSONType.null_, "Should parse file-less error");
	assert("file" !in diag, "Should not have file key");
	assert(diag["severity"].str == "error");
	assert(diag["message"].str == "cannot find source file");
}

/// parseDiagnostic non-diagnostic line returns null
unittest {
	auto diag = parseDiagnostic("Building dlang_mcp ~master: building configuration [default]");
	assert(diag.type == JSONType.null_, "Should return null for non-diagnostic line");
}

/// parseDiagnostic empty line returns null
unittest {
	auto diag = parseDiagnostic("");
	assert(diag.type == JSONType.null_, "Should return null for empty line");
}

/// parseDiagnostic temp path rewriting to stdin
unittest {
	// When tempPath is provided but no originalFilePath, should use <stdin>
	auto diag = parseDiagnostic("/tmp/dcheck_abc123.d(5): Error: type mismatch",
			"/tmp/dcheck_abc123.d");
	assert(diag.type != JSONType.null_, "Should parse with temp path");
	assert(diag["file"].str == "<stdin>",
			"Should rewrite temp path to <stdin>, got: " ~ diag["file"].str);
}

/// parseDiagnostic temp path rewriting to original file path
unittest {
	// When both tempPath and originalFilePath are provided
	auto diag = parseDiagnostic("/tmp/dcheck_abc123.d(5,3): Error: type mismatch",
			"/tmp/dcheck_abc123.d", "source/myfile.d");
	assert(diag.type != JSONType.null_, "Should parse with original path");
	assert(diag["file"].str == "source/myfile.d",
			"Should rewrite to original path, got: " ~ diag["file"].str);
	assert(diag["line"].integer == 5);
	assert(diag["column"].integer == 3);
}

/// collectDiagnostics with mixed errors, warnings, deprecations, and supplemental
unittest {
	string output = "source/a.d(1): Error: bad thing\n" ~ "source/b.d(2,5): Warning: sketchy thing\n"
		~ "source/c.d(3): Deprecation: old thing\n" ~ "Building something...\n"
		~ "Error: linker failed\n";

	auto result = collectDiagnostics(output);
	assert(result.errors.length == 1, "Should have 1 error");
	assert(result.errors[0]["file"].str == "source/a.d");
	// warning + deprecation both go into warnings
	assert(result.warnings.length == 2, "Should have 2 warnings (warning + deprecation)");
	// file-less "Error: linker failed" is supplemental
	assert(result.supplemental.length == 1, "Should have 1 supplemental");
	assert(result.supplemental[0]["message"].str == "linker failed");
}

/// collectDiagnostics with empty output
unittest {
	auto result = collectDiagnostics("");
	assert(result.errors.length == 0);
	assert(result.warnings.length == 0);
	assert(result.supplemental.length == 0);
}

/// collectDiagnostics with supplemental-only (file-less) errors
unittest {
	string output = "Error: cannot open input file\nError: another problem";
	auto result = collectDiagnostics(output);
	assert(result.errors.length == 0, "File-less errors are supplemental, not errors");
	assert(result.supplemental.length == 2, "Should have 2 supplemental entries");
}

/// collectDiagnostics with temp path rewriting
unittest {
	string output = "/tmp/check.d(10): Error: bad type\n"
		~ "/tmp/check.d(20,4): Warning: unused var\n" ~ "other/file.d(5): Error: unrelated error\n";

	auto result = collectDiagnostics(output, "/tmp/check.d", "user_code.d");
	// First error should have rewritten path
	assert(result.errors.length == 2, "Should have 2 errors");
	assert(result.errors[0]["file"].str == "user_code.d",
			"Should rewrite temp path, got: " ~ result.errors[0]["file"].str);
	// Second error has different file, should not be rewritten
	assert(result.errors[1]["file"].str == "other/file.d");
	// Warning should also be rewritten
	assert(result.warnings.length == 1);
	assert(result.warnings[0]["file"].str == "user_code.d");
}
