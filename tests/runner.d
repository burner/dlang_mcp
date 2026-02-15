module tests.runner;

import tests.unit.test_storage;
import tests.unit.test_parser;
import tests.unit.test_embeddings;
import std.stdio;

void main()
{
    writeln("D Package Search - Test Suite");
    writeln("==============================");

    bool allPassed = true;

    try
    {
        writeln("\n--- Storage Tests ---");
        auto storageTests = new StorageTests();
        storageTests.runAll();
    }
    catch (Exception e)
    {
        writeln("Storage tests failed: ", e.msg);
        allPassed = false;
    }

    try
    {
        writeln("\n--- Parser Tests ---");
        auto parserTests = new ParserTests();
        parserTests.runAll();
    }
    catch (Exception e)
    {
        writeln("Parser tests failed: ", e.msg);
        allPassed = false;
    }

    try
    {
        writeln("\n--- Embedding Tests ---");
        auto embeddingTests = new EmbeddingTests();
        embeddingTests.runAll();
    }
    catch (Exception e)
    {
        writeln("Embedding tests failed: ", e.msg);
        allPassed = false;
    }

    writeln("\n==============================");
    if (allPassed)
    {
        writeln("All tests passed!");
    }
    else
    {
        writeln("Some tests failed.");
    }
}