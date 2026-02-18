/**
 * Unit tests for the shared diagnostic parsing utilities.
 *
 * Tests mergeOutput, parseDiagnostic, and collectDiagnostics from
 * utils.diagnostic with various compiler output formats and edge cases.
 */
module tests.unit.test_diagnostic;

import std.stdio;
import std.json;
import utils.diagnostic;
import utils.process : ProcessResult;

class DiagnosticTests
{
    void runAll()
    {
        // mergeOutput tests
        testMergeOutputBothStreams();
        testMergeOutputStdoutOnly();
        testMergeOutputStderrOnly();
        testMergeOutputBothEmpty();

        // parseDiagnostic tests
        testParseErrorWithFileLineCol();
        testParseErrorWithFileLine();
        testParseWarning();
        testParseDeprecation();
        testParseLowercaseSeverity();
        testParseFilelessError();
        testParseNonDiagnosticLine();
        testParseEmptyLine();
        testParseTempPathRewriting();
        testParseTempPathWithOriginal();

        // collectDiagnostics tests
        testCollectMixedDiagnostics();
        testCollectEmptyOutput();
        testCollectSupplementalOnly();
        testCollectWithTempPathRewriting();

        writeln("  All diagnostic tests passed.");
    }

    // --- mergeOutput ---

    void testMergeOutputBothStreams()
    {
        ProcessResult r;
        r.output = "stdout line";
        r.stderrOutput = "stderr line";
        r.status = 0;
        string merged = mergeOutput(r);
        assert(merged == "stdout line\nstderr line",
            "Expected merged output, got: " ~ merged);
        writeln("    [PASS] mergeOutput both streams");
    }

    void testMergeOutputStdoutOnly()
    {
        ProcessResult r;
        r.output = "stdout only";
        r.stderrOutput = "";
        r.status = 0;
        string merged = mergeOutput(r);
        assert(merged == "stdout only",
            "Expected stdout only, got: " ~ merged);
        writeln("    [PASS] mergeOutput stdout only");
    }

    void testMergeOutputStderrOnly()
    {
        ProcessResult r;
        r.output = "";
        r.stderrOutput = "stderr only";
        r.status = 0;
        string merged = mergeOutput(r);
        assert(merged == "stderr only",
            "Expected stderr only, got: " ~ merged);
        writeln("    [PASS] mergeOutput stderr only");
    }

    void testMergeOutputBothEmpty()
    {
        ProcessResult r;
        r.output = "";
        r.stderrOutput = "";
        r.status = 0;
        string merged = mergeOutput(r);
        assert(merged == "",
            "Expected empty, got: " ~ merged);
        writeln("    [PASS] mergeOutput both empty");
    }

    // --- parseDiagnostic ---

    void testParseErrorWithFileLineCol()
    {
        auto diag = parseDiagnostic("source/app.d(42,10): Error: undefined identifier 'foo'");
        assert(diag.type != JSONType.null_, "Should parse as diagnostic");
        assert(diag["file"].str == "source/app.d");
        assert(diag["line"].integer == 42);
        assert(diag["column"].integer == 10);
        assert(diag["severity"].str == "error");
        assert(diag["message"].str == "undefined identifier 'foo'");
        writeln("    [PASS] parseDiagnostic error with file, line, col");
    }

    void testParseErrorWithFileLine()
    {
        auto diag = parseDiagnostic("source/app.d(42): Error: something went wrong");
        assert(diag.type != JSONType.null_, "Should parse as diagnostic");
        assert(diag["file"].str == "source/app.d");
        assert(diag["line"].integer == 42);
        assert("column" !in diag, "Should not have column");
        assert(diag["severity"].str == "error");
        assert(diag["message"].str == "something went wrong");
        writeln("    [PASS] parseDiagnostic error with file, line only");
    }

    void testParseWarning()
    {
        auto diag = parseDiagnostic("source/foo.d(10,5): Warning: implicit conversion");
        assert(diag.type != JSONType.null_, "Should parse as diagnostic");
        assert(diag["severity"].str == "warning");
        assert(diag["file"].str == "source/foo.d");
        writeln("    [PASS] parseDiagnostic warning");
    }

    void testParseDeprecation()
    {
        auto diag = parseDiagnostic("source/bar.d(7): Deprecation: use of old syntax");
        assert(diag.type != JSONType.null_, "Should parse as diagnostic");
        assert(diag["severity"].str == "deprecation");
        assert(diag["line"].integer == 7);
        writeln("    [PASS] parseDiagnostic deprecation");
    }

    void testParseLowercaseSeverity()
    {
        auto diag = parseDiagnostic("source/app.d(1): error: lowercase error msg");
        assert(diag.type != JSONType.null_, "Should parse lowercase severity");
        assert(diag["severity"].str == "error");
        assert(diag["message"].str == "lowercase error msg");
        writeln("    [PASS] parseDiagnostic lowercase severity");
    }

    void testParseFilelessError()
    {
        auto diag = parseDiagnostic("Error: cannot find source file");
        assert(diag.type != JSONType.null_, "Should parse file-less error");
        assert("file" !in diag, "Should not have file key");
        assert(diag["severity"].str == "error");
        assert(diag["message"].str == "cannot find source file");
        writeln("    [PASS] parseDiagnostic file-less error");
    }

    void testParseNonDiagnosticLine()
    {
        auto diag = parseDiagnostic("Building dlang_mcp ~master: building configuration [default]");
        assert(diag.type == JSONType.null_, "Should return null for non-diagnostic line");
        writeln("    [PASS] parseDiagnostic non-diagnostic line");
    }

    void testParseEmptyLine()
    {
        auto diag = parseDiagnostic("");
        assert(diag.type == JSONType.null_, "Should return null for empty line");
        writeln("    [PASS] parseDiagnostic empty line");
    }

    void testParseTempPathRewriting()
    {
        // When tempPath is provided but no originalFilePath, should use <stdin>
        auto diag = parseDiagnostic(
            "/tmp/dcheck_abc123.d(5): Error: type mismatch",
            "/tmp/dcheck_abc123.d"
        );
        assert(diag.type != JSONType.null_, "Should parse with temp path");
        assert(diag["file"].str == "<stdin>",
            "Should rewrite temp path to <stdin>, got: " ~ diag["file"].str);
        writeln("    [PASS] parseDiagnostic temp path rewriting to <stdin>");
    }

    void testParseTempPathWithOriginal()
    {
        // When both tempPath and originalFilePath are provided
        auto diag = parseDiagnostic(
            "/tmp/dcheck_abc123.d(5,3): Error: type mismatch",
            "/tmp/dcheck_abc123.d",
            "source/myfile.d"
        );
        assert(diag.type != JSONType.null_, "Should parse with original path");
        assert(diag["file"].str == "source/myfile.d",
            "Should rewrite to original path, got: " ~ diag["file"].str);
        assert(diag["line"].integer == 5);
        assert(diag["column"].integer == 3);
        writeln("    [PASS] parseDiagnostic temp path rewriting to original");
    }

    // --- collectDiagnostics ---

    void testCollectMixedDiagnostics()
    {
        string output = "source/a.d(1): Error: bad thing\n"
            ~ "source/b.d(2,5): Warning: sketchy thing\n"
            ~ "source/c.d(3): Deprecation: old thing\n"
            ~ "Building something...\n"
            ~ "Error: linker failed\n";

        auto result = collectDiagnostics(output);
        assert(result.errors.length == 1, "Should have 1 error");
        assert(result.errors[0]["file"].str == "source/a.d");
        // warning + deprecation both go into warnings
        assert(result.warnings.length == 2, "Should have 2 warnings (warning + deprecation)");
        // file-less "Error: linker failed" is supplemental
        assert(result.supplemental.length == 1, "Should have 1 supplemental");
        assert(result.supplemental[0]["message"].str == "linker failed");
        writeln("    [PASS] collectDiagnostics mixed output");
    }

    void testCollectEmptyOutput()
    {
        auto result = collectDiagnostics("");
        assert(result.errors.length == 0);
        assert(result.warnings.length == 0);
        assert(result.supplemental.length == 0);
        writeln("    [PASS] collectDiagnostics empty output");
    }

    void testCollectSupplementalOnly()
    {
        string output = "Error: cannot open input file\nError: another problem";
        auto result = collectDiagnostics(output);
        assert(result.errors.length == 0, "File-less errors are supplemental, not errors");
        assert(result.supplemental.length == 2, "Should have 2 supplemental entries");
        writeln("    [PASS] collectDiagnostics supplemental only");
    }

    void testCollectWithTempPathRewriting()
    {
        string output = "/tmp/check.d(10): Error: bad type\n"
            ~ "/tmp/check.d(20,4): Warning: unused var\n"
            ~ "other/file.d(5): Error: unrelated error\n";

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
        writeln("    [PASS] collectDiagnostics with temp path rewriting");
    }
}
