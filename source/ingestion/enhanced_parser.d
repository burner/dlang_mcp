module ingestion.enhanced_parser;

import ingestion.ddoc_parser;
import models;
import std.stdio;
import std.file;
import std.regex;
import std.algorithm;
import std.array;
import std.string;

class EnhancedDdocParser : DdocParser
{
    CodeExample[] extractUnittestBlocks(string sourceFile, string packageName)
    {
        if (!exists(sourceFile) || !isFile(sourceFile))
        {
            return [];
        }

        string content;
        try
        {
            content = readText(sourceFile);
        }
        catch (Exception e)
        {
            stderr.writeln("Error reading file: ", e.msg);
            return [];
        }

        return parseUnittests(content, packageName);
    }

    private CodeExample[] parseUnittests(string source, string packageName)
    {
        CodeExample[] examples;

        auto re = regex(r"unittest\s*\{", "g");
        auto matches = matchAll(source, re);

        foreach (match; matches)
        {
            auto startPos = match.pre.length + match.hit.length;
            auto code = extractBalancedBraces(source[startPos .. $]);

            if (code.length > 0)
            {
                CodeExample ex;
                ex.code = code;
                ex.description = "Unit test";
                ex.isUnittest = true;
                ex.isRunnable = true;
                ex.requiredImports = extractImports(code);
                ex.packageId = 0;

                examples ~= ex;
            }
        }

        return examples;
    }

    private string extractBalancedBraces(string source)
    {
        int braceCount = 1;
        size_t pos = 0;

        while (pos < source.length && braceCount > 0)
        {
            if (source[pos] == '{')
            {
                braceCount++;
            }
            else if (source[pos] == '}')
            {
                braceCount--;
            }
            pos++;
        }

        if (braceCount == 0 && pos > 0)
        {
            return source[0 .. pos - 1].strip();
        }

        return "";
    }

    private string[] extractImports(string code)
    {
        string[] imports;

        auto re = regex(r"import\s+([\w.]+)(?:\s*:\s*([\w,\s]+))?;", "g");

        foreach (match; matchAll(code, re))
        {
            imports ~= match.captures[1];
        }

        return imports;
    }

    string[] analyzeImportRequirements(string sourceFile)
    {
        if (!exists(sourceFile))
        {
            return [];
        }

        try
        {
            auto content = readText(sourceFile);
            return extractImports(content);
        }
        catch (Exception)
        {
            return [];
        }
    }

    FunctionRelationship[] analyzeFunctionCalls(string sourceFile, string functionName)
    {
        if (!exists(sourceFile))
        {
            return [];
        }

        FunctionRelationship[] relationships;

        try
        {
            auto content = readText(sourceFile);

            auto funcBody = extractFunctionBody(content, functionName);

            if (funcBody.empty)
            {
                return [];
            }

            auto callRe = regex(r"(\w+(?:\.\w+)*)\s*\(", "g");

            foreach (match; matchAll(funcBody, callRe))
            {
                string calledFunc = match.captures[1];

                if (["if", "for", "while", "foreach", "assert", "switch", "with", "synchronized"].canFind(calledFunc))
                {
                    continue;
                }

                FunctionRelationship rel;
                rel.fromFunctionId = 0;
                rel.toFunctionId = 0;
                rel.relationshipType = "calls";
                rel.weight = 1.0;

                relationships ~= rel;
            }
        }
        catch (Exception e)
        {
            stderr.writeln("Error analyzing function calls: ", e.msg);
        }

        return relationships;
    }

    private string extractFunctionBody(string source, string functionName)
    {
        auto re = regex(functionName ~ r"\s*\([^)]*\)\s*\{", "g");
        auto match = matchFirst(source, re);

        if (match.empty)
        {
            return "";
        }

        auto startPos = match.pre.length + match.hit.length;
        return extractBalancedBraces(source[startPos .. $]);
    }
}