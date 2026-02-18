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
struct DiagnosticResult
{
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
    if (result.stderrOutput.length > 0)
    {
        if (fullOutput.length > 0)
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
    auto re = regex(`^(.+?)\((\d+)(?:,(\d+))?\):\s*(Error|Warning|Deprecation|error|warning|deprecation)\s*:\s*(.+)$`);
    auto m = matchFirst(line, re);

    if (m.empty)
    {
        // Check for file-less diagnostics: "Error: message"
        auto reNoFile = regex(`^\s*(Error|Warning|Deprecation)\s*:\s*(.+)$`);
        auto m2 = matchFirst(line, reNoFile);
        if (!m2.empty)
        {
            auto entry = JSONValue(string[string].init);
            entry["severity"] = JSONValue(m2[1].idup.toLower());
            entry["message"] = JSONValue(m2[2].idup);
            return entry;
        }
        return JSONValue(null);
    }

    string file = m[1].idup;
    // Replace temp file path with something meaningful
    if (tempPath !is null && tempPath.length > 0 && file == tempPath)
        file = originalFilePath !is null ? originalFilePath : "<stdin>";

    auto entry = JSONValue(string[string].init);
    entry["file"] = JSONValue(file);
    entry["line"] = JSONValue(m[2].to!int);
    if (m[3].length > 0)
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
DiagnosticResult collectDiagnostics(string output, string tempPath = null, string originalFilePath = null)
{
    auto errors = appender!(JSONValue[]);
    auto warnings = appender!(JSONValue[]);
    auto supplemental = appender!(JSONValue[]);

    foreach (line; output.split("\n"))
    {
        if (line.length == 0)
            continue;

        auto parsed = parseDiagnostic(line, tempPath, originalFilePath);
        if (parsed.type == JSONType.null_)
            continue;

        // Supplemental entries have no "file" key (file-less diagnostics)
        if ("file" !in parsed)
        {
            supplemental ~= parsed;
            continue;
        }

        string severity = parsed["severity"].str;
        if (severity == "error")
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
