/**
 * MCP tool for analyzing DDoc documentation coverage in D projects.
 *
 * Delegates all parsing to the consolidated `ingestion.ddoc_project_parser`
 * module and formats the results as structured, LLM-friendly markdown.
 */
module tools.ddoc_analyze;

import std.json : JSONValue, parseJSON, JSONType;
import std.path : absolutePath, baseName;
import std.string : strip, join, format;
import std.array : appender;
import std.conv : text;
import std.algorithm.iteration : map, sum;
import std.algorithm.sorting : sort;
import tools.base : BaseTool;
import mcp.types : ToolResult;
import ingestion.ddoc_project_parser;

/**
 * Tool that analyzes DDoc documentation coverage across a D project.
 *
 * Accepts a project path and optional verbosity/filter settings. Produces
 * a report showing per-module and overall documentation coverage, with
 * detailed information about each symbol's documentation status, type
 * signatures, DDoc sections, and unittest associations.
 */
class DdocAnalyzeTool : BaseTool
{
    @property string name()
    {
        return "ddoc_analyze";
    }

    @property string description()
    {
        return "Analyze a D project's documentation and attributes using DMD's JSON output. "
            ~ "Returns per-module function/type summaries, documentation coverage, "
            ~ "performance attribute statistics (@safe, @nogc, nothrow, pure), and template usage.";
    }

    @property JSONValue inputSchema()
    {
        return parseJSON(`{
            "type": "object",
            "properties": {
                "project_path": {
                    "type": "string",
                    "default": ".",
                    "description": "Project root directory (must contain dub.json or dub.sdl)"
                },
                "verbose": {
                    "type": "boolean",
                    "default": false,
                    "description": "Include per-module function/type details in output"
                }
            }
        }`);
    }

    ToolResult execute(JSONValue arguments)
    {
        try
        {
            string projectPath = ".";
            if ("project_path" in arguments && arguments["project_path"].type == JSONType.string)
                projectPath = arguments["project_path"].str;

            projectPath = absolutePath(projectPath);

            bool verbose = false;
            if ("verbose" in arguments && arguments["verbose"].type == JSONType.true_)
                verbose = true;

            // Use the consolidated parser
            auto result = parseProject(projectPath);

            if (result.error.length > 0)
                return createErrorResult(result.error);

            return createTextResult(formatOutput(result.projectName, result.modules, verbose));
        }
        catch (Exception e)
        {
            return createErrorResult("Error analyzing project documentation: " ~ e.msg);
        }
    }

private:

    // --- Output formatting ---

    string formatOutput(string projectName, ParsedModule[] modules, bool verbose)
    {
        auto output = appender!string;

        // Gather aggregate stats
        int totalFunctions = 0;
        int totalTemplates = 0;
        int totalTypes = 0;
        int totalClasses = 0;
        int totalStructs = 0;
        int totalInterfaces = 0;
        int totalEnums = 0;
        int documentedFunctions = 0;
        int documentedTypes = 0;
        int safeCount = 0;
        int nogcCount = 0;
        int nothrowCount = 0;
        int pureCount = 0;
        int totalMethods = 0;
        int funcWithTests = 0;
        int typeWithTests = 0;
        int totalUnittests = 0;

        foreach (ref mod; modules)
        {
            totalUnittests += cast(int) mod.unittests.length;

            foreach (ref func; mod.functions)
            {
                totalFunctions++;
                if (func.isTemplate)
                    totalTemplates++;
                if (func.docComment.length > 0)
                    documentedFunctions++;
                if (func.isSafe)
                    safeCount++;
                if (func.isNogc)
                    nogcCount++;
                if (func.isNothrow)
                    nothrowCount++;
                if (func.isPure)
                    pureCount++;
                if (func.hasUnittest)
                    funcWithTests++;
            }

            foreach (ref t; mod.types)
            {
                totalTypes++;
                if (t.docComment.length > 0)
                    documentedTypes++;
                if (t.hasUnittest)
                    typeWithTests++;

                switch (t.kind)
                {
                case "class":
                    totalClasses++;
                    break;
                case "struct":
                    totalStructs++;
                    break;
                case "interface":
                    totalInterfaces++;
                    break;
                case "enum":
                    totalEnums++;
                    break;
                default:
                    break;
                }

                foreach (ref m; t.methods)
                {
                    totalMethods++;
                    if (m.isSafe)
                        safeCount++;
                    if (m.isNogc)
                        nogcCount++;
                    if (m.isNothrow)
                        nothrowCount++;
                    if (m.isPure)
                        pureCount++;
                }
            }
        }

        int allFunctions = totalFunctions + totalMethods;

        // --- Header ---
        output ~= "# DDoc Analysis: " ~ projectName ~ "\n\n";

        // --- Summary ---
        output ~= "## Summary\n\n";
        output ~= format("- **Modules:** %d\n", modules.length);
        output ~= format("- **Functions:** %d", totalFunctions);
        if (totalTemplates > 0)
            output ~= format(" (%d templates)", totalTemplates);
        output ~= "\n";
        if (totalMethods > 0)
            output ~= format("- **Methods:** %d (in types)\n", totalMethods);

        output ~= format("- **Types:** %d", totalTypes);
        if (totalTypes > 0)
        {
            string[] typeParts;
            if (totalClasses > 0)
                typeParts ~= format("%d classes", totalClasses);
            if (totalStructs > 0)
                typeParts ~= format("%d structs", totalStructs);
            if (totalInterfaces > 0)
                typeParts ~= format("%d interfaces", totalInterfaces);
            if (totalEnums > 0)
                typeParts ~= format("%d enums", totalEnums);
            if (typeParts.length > 0)
                output ~= " (" ~ typeParts.join(", ") ~ ")";
        }
        output ~= "\n";
        if (totalUnittests > 0)
            output ~= format("- **Unittests:** %d\n", totalUnittests);

        // Documentation coverage
        output ~= "\n### Documentation Coverage\n\n";
        if (totalFunctions > 0)
        {
            int pct = cast(int)(100.0 * documentedFunctions / totalFunctions);
            output ~= format("- Functions: %d/%d documented (%d%%)\n", documentedFunctions,
                totalFunctions, pct);
        }
        else
            output ~= "- Functions: 0 (none found)\n";

        if (totalTypes > 0)
        {
            int pct = cast(int)(100.0 * documentedTypes / totalTypes);
            output ~= format("- Types: %d/%d documented (%d%%)\n", documentedTypes, totalTypes, pct);
        }
        else
            output ~= "- Types: 0 (none found)\n";

        // Unittest coverage
        if (totalFunctions > 0 && totalUnittests > 0)
        {
            int pct = cast(int)(100.0 * funcWithTests / totalFunctions);
            output ~= format("- Functions with unittests: %d/%d (%d%%)\n", funcWithTests,
                totalFunctions, pct);
        }
        if (totalTypes > 0 && typeWithTests > 0)
        {
            int pct = cast(int)(100.0 * typeWithTests / totalTypes);
            output ~= format("- Types with unittests: %d/%d (%d%%)\n", typeWithTests,
                totalTypes, pct);
        }

        // --- Performance Attributes ---
        output ~= "\n## Performance Attributes\n\n";
        if (allFunctions > 0)
        {
            output ~= "| Attribute | Count | % of Functions |\n";
            output ~= "|-----------|-------|----------------|\n";
            output ~= formatAttrRow("@safe", safeCount, allFunctions);
            output ~= formatAttrRow("@nogc", nogcCount, allFunctions);
            output ~= formatAttrRow("nothrow", nothrowCount, allFunctions);
            output ~= formatAttrRow("pure", pureCount, allFunctions);
        }
        else
            output ~= "No functions found to analyze.\n";

        // --- Per-module breakdown ---
        output ~= "\n## Modules\n\n";

        auto sortedModules = modules.dup;
        sortedModules.sort!((a, b) => a.name < b.name);

        foreach (ref mod; sortedModules)
        {
            int funcCount = cast(int) mod.functions.length;
            int typeCount = cast(int) mod.types.length;
            int methodCount = 0;
            foreach (ref t; mod.types)
                methodCount += cast(int) t.methods.length;

            output ~= format("### %s", mod.name);

            string[] counts;
            if (funcCount > 0)
                counts ~= format("%d functions", funcCount);
            if (typeCount > 0)
                counts ~= format("%d types", typeCount);
            if (methodCount > 0)
                counts ~= format("%d methods", methodCount);
            if (mod.unittests.length > 0)
                counts ~= format("%d unittests", mod.unittests.length);
            if (counts.length > 0)
                output ~= " (" ~ counts.join(", ") ~ ")";
            output ~= "\n\n";

            if (mod.docComment.length > 0)
                output ~= mod.docComment.strip() ~ "\n\n";

            // Always show function details (structured for LLM consumption)
            if (mod.functions.length > 0)
            {
                output ~= "**Functions:**\n\n";
                foreach (ref func; mod.functions)
                {
                    output ~= formatFunctionDetail(func, verbose);
                }
            }

            // Always show type details
            if (mod.types.length > 0)
            {
                output ~= "**Types:**\n\n";
                foreach (ref t; mod.types)
                {
                    output ~= formatTypeDetail(t, verbose);
                }
            }
        }

        return output.data;
    }

    /**
     * Format a single function as structured markdown.
     * Always shows signature and key metadata; verbose adds full doc sections.
     */
    string formatFunctionDetail(ref const FuncInfo func, bool verbose)
    {
        auto out_ = appender!string;

        // Signature line
        out_ ~= "- `" ~ func.signature ~ "`";
        if (func.line > 0)
            out_ ~= format(" (line %d)", func.line);
        out_ ~= "\n";

        // Attributes as comma-separated tags
        string[] tags;
        if (func.isTemplate)
            tags ~= "template";
        if (func.hasUnittest)
            tags ~= format("unittest:L%d", func.unittestLine);
        if (func.timeComplexity.length > 0)
            tags ~= func.timeComplexity;
        if (tags.length > 0)
            out_ ~= "  **Tags:** " ~ tags.join(", ") ~ "\n";

        // Summary
        if (func.ddocSections.summary.length > 0)
            out_ ~= "  **Summary:** " ~ func.ddocSections.summary ~ "\n";

        if (verbose)
        {
            // Named DDoc sections
            if ("Params" in func.ddocSections.sections)
                out_ ~= "  **Params:** " ~ func.ddocSections.sections["Params"].strip() ~ "\n";
            if ("Returns" in func.ddocSections.sections)
                out_ ~= "  **Returns:** " ~ func.ddocSections.sections["Returns"].strip() ~ "\n";
            if ("Throws" in func.ddocSections.sections)
                out_ ~= "  **Throws:** " ~ func.ddocSections.sections["Throws"].strip() ~ "\n";
            if ("See_Also" in func.ddocSections.sections)
                out_ ~= "  **See Also:** " ~ func.ddocSections.sections["See_Also"].strip() ~ "\n";
        }

        out_ ~= "\n";
        return out_.data;
    }

    /**
     * Format a single type as structured markdown.
     */
    string formatTypeDetail(ref const ParsedType t, bool verbose)
    {
        auto out_ = appender!string;

        out_ ~= "- " ~ t.kind ~ " `" ~ t.name ~ "`";
        if (t.line > 0)
            out_ ~= format(" (line %d)", t.line);

        // Show inheritance
        string[] heritage;
        foreach (bc; t.baseClasses)
            heritage ~= bc;
        foreach (iface; t.interfaces)
            heritage ~= iface;
        if (heritage.length > 0)
            out_ ~= " : " ~ heritage.join(", ");

        out_ ~= "\n";

        // Tags
        string[] tags;
        if (t.methods.length > 0)
            tags ~= format("%d methods", t.methods.length);
        if (t.hasUnittest)
            tags ~= format("unittest:L%d", t.unittestLine);
        if (tags.length > 0)
            out_ ~= "  **Tags:** " ~ tags.join(", ") ~ "\n";

        // Summary
        if (t.ddocSections.summary.length > 0)
            out_ ~= "  **Summary:** " ~ t.ddocSections.summary ~ "\n";

        // Methods
        if (t.methods.length > 0)
        {
            out_ ~= "  **Methods:**\n";
            foreach (ref m; t.methods)
            {
                out_ ~= "  - `" ~ m.signature ~ "`";
                if (m.line > 0)
                    out_ ~= format(" (line %d)", m.line);
                out_ ~= "\n";
                if (verbose && m.ddocSections.summary.length > 0)
                    out_ ~= "    **Summary:** " ~ m.ddocSections.summary ~ "\n";
            }
        }

        out_ ~= "\n";
        return out_.data;
    }

    static string formatAttrRow(string attrName, int count, int total)
    {
        int pct = total > 0 ? cast(int)(100.0 * count / total) : 0;
        return format("| %-9s | %-5d | %-14s |\n", attrName, count, format("%d%%", pct));
    }
}
