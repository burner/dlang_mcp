/**
 * Unit tests for MCP tool instantiation, schema validation,
 * and argument error handling.
 */
module tests.unit.test_tools;

import std.stdio;
import std.json;
import std.algorithm.searching : canFind;
import tools.base : Tool;
import tools.run_project : RunProjectTool;
import tools.fetch_package : FetchPackageTool;
import tools.upgrade_deps : UpgradeDependenciesTool;
import tools.build_project : BuildProjectTool;
import tools.run_tests : RunTestsTool;
import tools.analyze_project : AnalyzeProjectTool;
import mcp.types : ToolResult;

class ToolTests
{
    void runAll()
    {
        testRunProjectToolProperties();
        testRunProjectToolSchema();
        testFetchPackageToolProperties();
        testFetchPackageToolSchema();
        testFetchPackageMissingArg();
        testFetchPackageEmptyName();
        testUpgradeDepsToolProperties();
        testUpgradeDepsToolSchema();
        testBuildProjectToolProperties();
        testRunTestsToolProperties();
        testAnalyzeProjectToolProperties();
        testRunProjectNonexistentPath();
        testUpgradeNonexistentPath();
        writeln("  All tool tests passed.");
    }

    // --- RunProjectTool ---

    void testRunProjectToolProperties()
    {
        auto tool = new RunProjectTool();
        assert(tool.name == "run_project", "Expected name 'run_project', got: " ~ tool.name);
        assert(tool.description.length > 0, "Description should not be empty");
        writeln("    [PASS] RunProjectTool properties");
    }

    void testRunProjectToolSchema()
    {
        auto tool = new RunProjectTool();
        auto schema = tool.inputSchema;
        assert(schema["type"].str == "object", "Schema type should be 'object'");
        auto props = schema["properties"];
        assert("project_path" in props, "Schema should have project_path");
        assert("compiler" in props, "Schema should have compiler");
        assert("build_type" in props, "Schema should have build_type");
        assert("configuration" in props, "Schema should have configuration");
        assert("args" in props, "Schema should have args");
        assert("force" in props, "Schema should have force");
        writeln("    [PASS] RunProjectTool schema");
    }

    void testRunProjectNonexistentPath()
    {
        auto tool = new RunProjectTool();
        auto args = parseJSON(`{"project_path": "/nonexistent/path/that/does/not/exist"}`);
        auto result = tool.execute(args);
        // Should not crash — returns a result (possibly with error output from dub)
        assert(result.content.length > 0, "Should return content");
        writeln("    [PASS] RunProjectTool handles nonexistent path");
    }

    // --- FetchPackageTool ---

    void testFetchPackageToolProperties()
    {
        auto tool = new FetchPackageTool();
        assert(tool.name == "fetch_package", "Expected name 'fetch_package', got: " ~ tool.name);
        assert(tool.description.length > 0, "Description should not be empty");
        writeln("    [PASS] FetchPackageTool properties");
    }

    void testFetchPackageToolSchema()
    {
        auto tool = new FetchPackageTool();
        auto schema = tool.inputSchema;
        assert(schema["type"].str == "object", "Schema type should be 'object'");
        auto props = schema["properties"];
        assert("package_name" in props, "Schema should have package_name");
        assert("version_" in props, "Schema should have version_");
        // Check required
        assert("required" in schema, "Schema should have required array");
        bool hasRequired = false;
        foreach (r; schema["required"].array)
        {
            if (r.str == "package_name")
                hasRequired = true;
        }
        assert(hasRequired, "package_name should be required");
        writeln("    [PASS] FetchPackageTool schema");
    }

    void testFetchPackageMissingArg()
    {
        auto tool = new FetchPackageTool();
        auto args = parseJSON(`{}`);
        auto result = tool.execute(args);
        assert(result.isError, "Should return error when package_name is missing");
        assert(result.content.length > 0, "Should have error content");
        assert(result.content[0].text.canFind("package_name"),
            "Error should mention package_name");
        writeln("    [PASS] FetchPackageTool missing arg error");
    }

    void testFetchPackageEmptyName()
    {
        auto tool = new FetchPackageTool();
        auto args = parseJSON(`{"package_name": "   "}`);
        auto result = tool.execute(args);
        assert(result.isError, "Should return error when package_name is whitespace");
        writeln("    [PASS] FetchPackageTool empty name error");
    }

    // --- UpgradeDependenciesTool ---

    void testUpgradeDepsToolProperties()
    {
        auto tool = new UpgradeDependenciesTool();
        assert(tool.name == "upgrade_dependencies",
            "Expected name 'upgrade_dependencies', got: " ~ tool.name);
        assert(tool.description.length > 0, "Description should not be empty");
        writeln("    [PASS] UpgradeDependenciesTool properties");
    }

    void testUpgradeDepsToolSchema()
    {
        auto tool = new UpgradeDependenciesTool();
        auto schema = tool.inputSchema;
        assert(schema["type"].str == "object", "Schema type should be 'object'");
        auto props = schema["properties"];
        assert("project_path" in props, "Schema should have project_path");
        assert("missing_only" in props, "Schema should have missing_only");
        assert("verify" in props, "Schema should have verify");
        writeln("    [PASS] UpgradeDependenciesTool schema");
    }

    void testUpgradeNonexistentPath()
    {
        auto tool = new UpgradeDependenciesTool();
        auto args = parseJSON(`{"project_path": "/nonexistent/path/that/does/not/exist"}`);
        auto result = tool.execute(args);
        // Should not crash — returns a result (possibly with error output from dub)
        assert(result.content.length > 0, "Should return content");
        writeln("    [PASS] UpgradeDependenciesTool handles nonexistent path");
    }

    // --- Existing tools: basic property checks ---

    void testBuildProjectToolProperties()
    {
        auto tool = new BuildProjectTool();
        assert(tool.name == "build_project", "Expected name 'build_project', got: " ~ tool.name);
        assert(tool.description.length > 0, "Description should not be empty");
        auto schema = tool.inputSchema;
        assert(schema["type"].str == "object");
        writeln("    [PASS] BuildProjectTool properties");
    }

    void testRunTestsToolProperties()
    {
        auto tool = new RunTestsTool();
        assert(tool.name == "run_tests", "Expected name 'run_tests', got: " ~ tool.name);
        assert(tool.description.length > 0, "Description should not be empty");
        auto schema = tool.inputSchema;
        assert(schema["type"].str == "object");
        writeln("    [PASS] RunTestsTool properties");
    }

    void testAnalyzeProjectToolProperties()
    {
        auto tool = new AnalyzeProjectTool();
        assert(tool.name == "analyze_project", "Expected name 'analyze_project', got: " ~ tool.name);
        assert(tool.description.length > 0, "Description should not be empty");
        auto schema = tool.inputSchema;
        assert(schema["type"].str == "object");
        writeln("    [PASS] AnalyzeProjectTool properties");
    }
}
