module tests.runner;

import tests.unit.test_storage;
import tests.unit.test_parser;
import tests.unit.test_embeddings;
import tests.unit.test_protocol;
import tests.unit.test_mcp_types;
import tests.unit.test_ctags_parser;
import tests.unit.test_server;
import tests.integration.test_e2e_pipeline;
import std.stdio;

void main()
{
    writeln("D Package Search - Test Suite");
    writeln("==============================");

    bool allPassed = true;

    // --- Unit Tests ---

    try
    {
        writeln("\n--- Protocol Tests ---");
        auto protocolTests = new ProtocolTests();
        protocolTests.runAll();
    }
    catch (Exception e)
    {
        writeln("Protocol tests failed: ", e.msg);
        allPassed = false;
    }

    try
    {
        writeln("\n--- MCP Types Tests ---");
        auto mcpTypesTests = new McpTypesTests();
        mcpTypesTests.runAll();
    }
    catch (Exception e)
    {
        writeln("MCP Types tests failed: ", e.msg);
        allPassed = false;
    }

    try
    {
        writeln("\n--- Ctags Parser Tests ---");
        auto ctagsTests = new CtagsParserTests();
        ctagsTests.runAll();
    }
    catch (Exception e)
    {
        writeln("Ctags Parser tests failed: ", e.msg);
        allPassed = false;
    }

    try
    {
        writeln("\n--- Server Tests ---");
        auto serverTests = new ServerTests();
        serverTests.runAll();
    }
    catch (Exception e)
    {
        writeln("Server tests failed: ", e.msg);
        allPassed = false;
    }

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

    // --- Integration Tests ---

    try
    {
        writeln("\n--- E2E Pipeline Tests ---");
        auto e2eTests = new E2EPipelineTests();
        e2eTests.runAll();
    }
    catch (Exception e)
    {
        writeln("E2E Pipeline tests failed: ", e.msg);
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
