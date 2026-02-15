module tests.unit.test_parser;

import ingestion.ddoc_parser;
import ingestion.enhanced_parser;
import std.stdio;
import std.file;
import std.path;
import std.json;
import std.algorithm;

class ParserTests
{
    private string testDataDir = "./test_data";

    void setUp()
    {
        if (exists(testDataDir))
        {
            rmdirRecurse(testDataDir);
        }
        mkdirRecurse(testDataDir);
        createTestFiles();
    }

    void tearDown()
    {
        if (exists(testDataDir))
        {
            rmdirRecurse(testDataDir);
        }
    }

    void createTestFiles()
    {
        auto testSource = buildPath(testDataDir, "test.d");
        std.file.write(testSource, q{
/// Test module
module test;

/// A simple function
/// Example:
/// ---
/// auto result = add(1, 2);
/// assert(result == 3);
/// ---
int add(int a, int b) @nogc @safe pure {
    return a + b;
}

unittest {
    assert(add(1, 2) == 3);
    assert(add(-1, 1) == 0);
}

/// A template function
T max(T)(T a, T b) if (is(T : int)) {
    return a > b ? a : b;
}

/// Test class
class TestClass {
    /// Method
    void doSomething() @safe {
    }
}
        });

        auto testJson = buildPath(testDataDir, "docs.json");
        auto jsonContent = `[
            {
                "kind": "module",
                "name": "test",
                "comment": "Test module",
                "members": [
                    {
                        "kind": "function",
                        "name": "add",
                        "comment": "A simple function",
                        "type": "int(int, int)",
                        "parameters": [
                            {"name": "a", "type": "int"},
                            {"name": "b", "type": "int"}
                        ],
                        "attributes": ["@nogc", "@safe", "pure"]
                    },
                    {
                        "kind": "class",
                        "name": "TestClass",
                        "comment": "Test class",
                        "members": [
                            {
                                "kind": "function",
                                "name": "doSomething",
                                "attributes": ["@safe"]
                            }
                        ]
                    }
                ]
            }
        ]`;
        std.file.write(testJson, jsonContent);
    }

    void testParseJson()
    {
        auto parser = new DdocParser();
        auto jsonPath = buildPath(testDataDir, "docs.json");
        auto json = parseJSON(readText(jsonPath));

        auto modules = parser.parseJsonDocs(json, "test-package");

        assert(modules.length == 1);
        assert(modules[0].name == "test");
        assert(modules[0].functions.length >= 1);
        assert(modules[0].functions[0].name == "add");
        assert(modules[0].functions[0].performance.isNogc);
        assert(modules[0].functions[0].performance.isPure);
        assert(modules[0].functions[0].performance.isSafe);

        writeln("  PASS: Parse DMD JSON");
    }

    void testExtractUnittests()
    {
        auto parser = new EnhancedDdocParser();
        auto sourcePath = buildPath(testDataDir, "test.d");

        auto examples = parser.extractUnittestBlocks(sourcePath, "test-package");

        assert(examples.length >= 1);
        assert(examples[0].isUnittest);
        assert(examples[0].isRunnable);
        assert(examples[0].code.canFind("assert"));

        writeln("  PASS: Extract unittests");
    }

    void testExtractImports()
    {
        auto testFile = buildPath(testDataDir, "imports.d");
        std.file.write(testFile, q{
import std.stdio;
import std.algorithm : map, filter;
import std.range;

void main() {
    writeln("test");
}
        });

        auto parser = new EnhancedDdocParser();
        auto imports = parser.analyzeImportRequirements(testFile);

        assert(imports.canFind("std.stdio"));
        assert(imports.canFind("std.algorithm"));
        assert(imports.canFind("std.range"));

        writeln("  PASS: Extract imports");
    }

    void testPackageMetadataFromJSON()
    {
        import models;

        string jsonStr = `{
            "name": "test-pkg",
            "version": "1.2.3",
            "description": "A test package",
            "authors": ["Author1", "Author2"],
            "tags": ["test", "demo"],
            "license": "MIT"
        }`;

        auto json = parseJSON(jsonStr);
        auto pkg = PackageMetadata.fromJSON(json);

        assert(pkg.name == "test-pkg");
        assert(pkg.version_ == "1.2.3");
        assert(pkg.description == "A test package");
        assert(pkg.authors.length == 2);
        assert(pkg.tags.length == 2);
        assert(pkg.license == "MIT");

        writeln("  PASS: Package metadata from JSON");
    }

    void runAll()
    {
        writeln("\n=== Running Parser Tests ===");

        setUp();
        scope(exit) tearDown();

        testParseJson();
        testExtractUnittests();
        testExtractImports();
        testPackageMetadataFromJSON();

        writeln("=== Parser Tests Complete ===");
    }
}