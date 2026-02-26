/**
 * Parser for D coverage `.lst` files.
 *
 * Extracts per-line coverage data and reconstructed source code from
 * `.lst` files produced by `dub test --coverage` or `dmd -cov`.
 */
module utils.coverage_parser;

import std.array : appender;
import std.conv : to, ConvException;
import std.string : indexOf, strip, replace;

/**
 * Per-line coverage information extracted from a `.lst` file.
 */
struct LineCoverage {
	/// Line number in the source file (1-based).
	size_t lineNumber;
	/// Whether the line contains executable code.
	bool isExecutable;
	/// Whether the line was executed at least once.
	bool isCovered;
	/// Number of times the line was executed, or -1 if non-executable.
	long executionCount;
	/// Source text for this line (right side of `|`).
	string sourceText;
}

/**
 * Aggregate coverage data for a single source file, parsed from its `.lst` file.
 */
struct FileCoverage {
	/// Path to the original `.lst` file.
	string filePath;
	/// Inferred `.d` source file name (e.g. `source/tools/base.d`).
	string sourceFileName;
	/// Per-line coverage data.
	LineCoverage[] lines;
	/// Full source reconstructed by joining the right-hand sides of `|` lines.
	string reconstructedSource;

	/// Number of executable lines that were never executed.
	size_t uncoveredCount() const
	{
		size_t count;
		foreach(ref line; lines)
			if(line.isExecutable && !line.isCovered)
				count++;
		return count;
	}

	/// Total number of executable lines.
	size_t executableCount() const
	{
		size_t count;
		foreach(ref line; lines)
			if(line.isExecutable)
				count++;
		return count;
	}

	/// Number of executable lines that were executed at least once.
	size_t coveredCount() const
	{
		size_t count;
		foreach(ref line; lines)
			if(line.isExecutable && line.isCovered)
				count++;
		return count;
	}
}

/**
 * Infer the `.d` source file name from a `.lst` file path.
 *
 * Strips directory components and the `.lst` extension, replaces `-` with `/`,
 * and appends `.d`.  For example, `source-tools-base.lst` becomes
 * `source/tools/base.d`.
 *
 * Params:
 *     lstPath = File path to a `.lst` coverage file.
 *
 * Returns:
 *     The inferred `.d` source file name, or an empty string if `lstPath`
 *     is empty.
 */
string inferSourceFileName(string lstPath)
{
	if(lstPath.length == 0)
		return "";

	// Strip directory prefix — take only the base name.
	string base = lstPath;
	auto lastSlash = base.indexOf('/');
	// Find the very last slash.
	while(lastSlash >= 0) {
		base = base[lastSlash + 1 .. $];
		lastSlash = base.indexOf('/');
	}

	// Also handle backslash paths.
	auto lastBack = base.indexOf('\\');
	while(lastBack >= 0) {
		base = base[lastBack + 1 .. $];
		lastBack = base.indexOf('\\');
	}

	// Strip .lst extension.
	if(base.length > 4 && base[$ - 4 .. $] == ".lst")
		base = base[0 .. $ - 4];

	// Replace `-` with `/` and append `.d`.
	return base.replace("-", "/") ~ ".d";
}

/**
 * Parse the textual content of a `.lst` coverage file.
 *
 * Each line containing a `|` character is treated as a coverage line:
 * the left side is the execution count and the right side is source text.
 * Lines without `|` are summary lines and are skipped.
 *
 * Left-side interpretation:
 * $(UL
 *   $(LI All whitespace → non-executable (executionCount = -1))
 *   $(LI `0000000` → executable but uncovered (executionCount = 0))
 *   $(LI A positive number → covered, executed that many times)
 * )
 *
 * Params:
 *     content  = Full text content of a `.lst` file.
 *     filePath = Optional path to the `.lst` file (used for metadata).
 *
 * Returns:
 *     A $(D FileCoverage) containing per-line data and reconstructed source.
 */
FileCoverage parseLstContent(string content, string filePath = "")
{
	FileCoverage result;
	result.filePath = filePath;
	result.sourceFileName = inferSourceFileName(filePath);

	if(content.length == 0)
		return result;

	auto sourceBuilder = appender!string();
	size_t lineNum;

	// Split content into lines, preserving empty trailing lines.
	auto rawLines = splitLines(content);

	foreach(rawLine; rawLines) {
		auto pipeIdx = rawLine.indexOf('|');
		if(pipeIdx < 0)
			continue; // Summary line — skip.

		lineNum++;
		string left = rawLine[0 .. pipeIdx];
		string right = pipeIdx + 1 < rawLine.length ? rawLine[pipeIdx + 1 .. $] : "";

		if(lineNum > 1)
			sourceBuilder.put('\n');
		sourceBuilder.put(right);

		LineCoverage lc;
		lc.lineNumber = lineNum;
		lc.sourceText = right;

		string trimmed = left.strip();
		if(trimmed.length == 0) {
			// Non-executable line.
			lc.isExecutable = false;
			lc.isCovered = false;
			lc.executionCount = -1;
		} else {
			lc.isExecutable = true;
			try {
				lc.executionCount = to!long(trimmed);
			} catch(ConvException) {
				lc.executionCount = 0;
			}
			lc.isCovered = lc.executionCount > 0;
		}

		result.lines ~= lc;
	}

	result.reconstructedSource = sourceBuilder[];
	return result;
}

/**
 * Split a string into lines, handling `\n`, `\r\n`, and `\r` line endings.
 *
 * Params:
 *     s = The string to split.
 *
 * Returns:
 *     An array of lines without their terminators.
 */
private string[] splitLines(string s)
{
	string[] lines;
	size_t start;
	for(size_t i = 0; i < s.length; i++) {
		if(s[i] == '\n') {
			lines ~= s[start .. i];
			start = i + 1;
		} else if(s[i] == '\r') {
			lines ~= s[start .. i];
			if(i + 1 < s.length && s[i + 1] == '\n')
				i++;
			start = i + 1;
		}
	}
	// Remaining content after the last newline.
	if(start <= s.length)
		lines ~= s[start .. $];
	return lines;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

/// Basic parsing of a multi-line .lst with non-executable, covered, and
/// uncovered lines.
unittest {
	string lst = "       |module foo;\n" ~ "       |\n" ~ "      5|void bar() {\n" ~ "0000000|    if (false)\n"
		~ "0000000|        unreachable();\n" ~ "      5|}\n" ~ "source/foo.d is 85% covered\n";

	auto cov = parseLstContent(lst, "source-foo.lst");

	// Should have 6 code lines (the summary line is skipped).
	assert(cov.lines.length == 6, "Expected 6 lines, got " ~ to!string(cov.lines.length));

	// Line 1: non-executable module declaration.
	assert(!cov.lines[0].isExecutable);
	assert(cov.lines[0].executionCount == -1);
	assert(cov.lines[0].sourceText == "module foo;");
	assert(cov.lines[0].lineNumber == 1);

	// Line 2: blank non-executable.
	assert(!cov.lines[1].isExecutable);

	// Line 3: covered, executed 5 times.
	assert(cov.lines[2].isExecutable);
	assert(cov.lines[2].isCovered);
	assert(cov.lines[2].executionCount == 5);

	// Line 4: uncovered executable.
	assert(cov.lines[3].isExecutable);
	assert(!cov.lines[3].isCovered);
	assert(cov.lines[3].executionCount == 0);

	// Line 5: uncovered executable.
	assert(cov.lines[4].isExecutable);
	assert(!cov.lines[4].isCovered);
	assert(cov.lines[4].executionCount == 0);

	// Line 6: covered.
	assert(cov.lines[5].isExecutable);
	assert(cov.lines[5].isCovered);
	assert(cov.lines[5].executionCount == 5);
}

/// Aggregate counts (executableCount, uncoveredCount, coveredCount).
unittest {
	string lst = "       |module foo;\n" ~ "      5|void bar() {\n"
		~ "0000000|    if (false)\n" ~ "0000000|        unreachable();\n" ~ "      5|}\n";

	auto cov = parseLstContent(lst);

	assert(cov.executableCount() == 4,
			"Expected 4 executable, got " ~ to!string(cov.executableCount()));
	assert(cov.coveredCount() == 2, "Expected 2 covered, got " ~ to!string(cov.coveredCount()));
	assert(cov.uncoveredCount() == 2,
			"Expected 2 uncovered, got " ~ to!string(cov.uncoveredCount()));
}

/// Reconstructed source contains expected content.
unittest {
	string lst = "       |module foo;\n" ~ "      5|void bar() {\n" ~ "      5|}\n";

	auto cov = parseLstContent(lst);

	assert(cov.reconstructedSource.length > 0);
	import std.algorithm.searching : canFind;

	assert(cov.reconstructedSource.canFind("module foo;"));
	assert(cov.reconstructedSource.canFind("void bar()"));
	assert(cov.reconstructedSource.canFind("}"));
}

/// Summary lines at end of .lst are skipped (lines without `|`).
unittest {
	string lst = "       |module bar;\n" ~ "      1|int x = 1;\n"
		~ "source/bar.d is 100% covered\n" ~ "source/bar.d has no code\n";

	auto cov = parseLstContent(lst, "source-bar.lst");

	// Only the 2 pipe lines should be parsed.
	assert(cov.lines.length == 2, "Expected 2 lines, got " ~ to!string(cov.lines.length));
}

/// Source file name inference from .lst path.
unittest {
	assert(inferSourceFileName("source-tools-base.lst") == "source/tools/base.d");
	assert(inferSourceFileName("app.lst") == "app.d");
	assert(inferSourceFileName("some/dir/source-foo.lst") == "source/foo.d");
	assert(inferSourceFileName("") == "");
}

/// Empty content produces empty result.
unittest {
	auto cov = parseLstContent("");
	assert(cov.lines.length == 0);
	assert(cov.reconstructedSource == "");
}

/// Large execution counts parse correctly.
unittest {
	string lst = " 123456|    writeln(\"hello\");\n";
	auto cov = parseLstContent(lst);
	assert(cov.lines.length == 1);
	assert(cov.lines[0].executionCount == 123456);
	assert(cov.lines[0].isCovered);
}

/// Backslash path handling in inferSourceFileName.
unittest {
	assert(inferSourceFileName("dir\\subdir\\source-foo.lst") == "source/foo.d");
	assert(inferSourceFileName("dir\\source-tools-base.lst") == "source/tools/base.d");
	assert(inferSourceFileName("C:\\builds\\app.lst") == "app.d");
}

/// ConvException branch: non-numeric left side of `|` yields executionCount 0.
unittest {
	string lst = "garbage|source line\n";
	auto cov = parseLstContent(lst);
	assert(cov.lines.length == 1);
	assert(cov.lines[0].isExecutable);
	assert(!cov.lines[0].isCovered);
	assert(cov.lines[0].executionCount == 0);
	assert(cov.lines[0].sourceText == "source line");
}

/// \r\n and bare \r line endings are handled the same as \n.
unittest {
	string lstLf = "       |module foo;\n      5|void bar() {\n      5|}\n";
	auto covLf = parseLstContent(lstLf);

	// \r\n line endings.
	string lstCrLf = "       |module foo;\r\n      5|void bar() {\r\n      5|}\r\n";
	auto covCrLf = parseLstContent(lstCrLf);

	assert(covCrLf.lines.length == covLf.lines.length,
			"Expected " ~ to!string(covLf.lines.length) ~ " lines, got " ~ to!string(
				covCrLf.lines.length));
	foreach(i; 0 .. covLf.lines.length) {
		assert(covCrLf.lines[i].sourceText == covLf.lines[i].sourceText);
		assert(covCrLf.lines[i].executionCount == covLf.lines[i].executionCount);
		assert(covCrLf.lines[i].isExecutable == covLf.lines[i].isExecutable);
		assert(covCrLf.lines[i].isCovered == covLf.lines[i].isCovered);
	}

	// Bare \r line endings.
	string lstCr = "       |module foo;\r      5|void bar() {\r      5|}\r";
	auto covCr = parseLstContent(lstCr);

	assert(covCr.lines.length == covLf.lines.length,
			"Expected " ~ to!string(
				covLf.lines.length) ~ " lines, got " ~ to!string(covCr.lines.length));
	foreach(i; 0 .. covLf.lines.length) {
		assert(covCr.lines[i].sourceText == covLf.lines[i].sourceText);
		assert(covCr.lines[i].executionCount == covLf.lines[i].executionCount);
		assert(covCr.lines[i].isExecutable == covLf.lines[i].isExecutable);
		assert(covCr.lines[i].isCovered == covLf.lines[i].isCovered);
	}
}
