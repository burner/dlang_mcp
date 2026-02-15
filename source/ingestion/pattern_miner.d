module ingestion.pattern_miner;

import storage.connection;
import storage.crud;
import models;
import d2sqlite3;
import std.stdio;
import std.algorithm;
import std.array;
import std.string;
import std.conv;

struct ImportPattern
{
    string[] imports;
    int count;
    string[] packages;
}

struct FunctionPattern
{
    string name;
    string[] callers;
    int count;
}

class PatternMiner
{
    private DBConnection conn;
    private CRUDOperations crud;

    this(DBConnection conn)
    {
        this.conn = conn;
        this.crud = new CRUDOperations(conn);
    }

    ImportPattern[] mineImportPatterns(int minOccurrences = 2)
    {
        writeln("Mining import patterns...");

        ImportPattern[] patterns;

        try
        {
            auto stmt = conn.prepare("
                SELECT required_imports, COUNT(*) as cnt
                FROM code_examples
                WHERE required_imports IS NOT NULL AND required_imports != ''
                GROUP BY required_imports
                HAVING COUNT(*) >= ?
                ORDER BY cnt DESC
                LIMIT 100
            ");
            stmt.bind(1, minOccurrences);

            foreach (row; stmt.execute())
            {
                ImportPattern pattern;
                auto importsStr = row["required_imports"].as!string;
                pattern.imports = importsStr.split(",");
                pattern.count = row["cnt"].as!int;
                patterns ~= pattern;
            }
        }
        catch (Exception e)
        {
            stderr.writeln("Error mining import patterns: ", e.msg);
        }

        writeln("  Found ", patterns.length, " import patterns");
        return patterns;
    }

    void storeUsagePatterns()
    {
        writeln("Storing usage patterns...");

        auto patterns = mineImportPatterns(3);

        foreach (pattern; patterns)
        {
            if (pattern.imports.length < 2)
                continue;

            try
            {
                auto stmt = conn.prepare("
                    INSERT OR REPLACE INTO usage_patterns 
                    (pattern_name, description, function_ids, code_template, use_case, popularity)
                    VALUES (?, ?, ?, ?, ?, ?)
                ");

                string name = "Import: " ~ pattern.imports.join(" + ");
                string description = format("Common import combination used %d times", pattern.count);
                string functionIds = "[]";
                string codeTemplate = format("import %s;", pattern.imports.join(";\nimport "));
                string useCase = "imports";
                int popularity = pattern.count;

                stmt.bind(1, name);
                stmt.bind(2, description);
                stmt.bind(3, functionIds);
                stmt.bind(4, codeTemplate);
                stmt.bind(5, useCase);
                stmt.bind(6, popularity);
                stmt.execute();
            }
            catch (Exception e)
            {
            }
        }

        writeln("  Stored ", patterns.length, " usage patterns");
    }

    string[] getCommonImportsForPackage(string packageName)
    {
        string[] imports;

        try
        {
            auto stmt = conn.prepare("
                SELECT required_imports, COUNT(*) as cnt
                FROM code_examples ce
                JOIN packages p ON p.id = ce.package_id
                WHERE p.name = ? AND required_imports IS NOT NULL
                GROUP BY required_imports
                ORDER BY cnt DESC
                LIMIT 10
            ");
            stmt.bind(1, packageName);

            foreach (row; stmt.execute())
            {
                auto importStr = row["required_imports"].as!string;
                foreach (imp; importStr.split(","))
                {
                    if (!imports.canFind(imp.strip()))
                    {
                        imports ~= imp.strip();
                    }
                }
            }
        }
        catch (Exception e)
        {
        }

        return imports;
    }

    string[] suggestImports(string[] symbols)
    {
        string[string] suggested;

        foreach (symbol; symbols)
        {
            try
            {
                auto parts = symbol.split(".");
                if (parts.length >= 2)
                {
                    string modulePath = parts[0 .. $-1].join(".");
                    suggested[modulePath] = modulePath;
                }
            }
            catch (Exception)
            {
            }
        }

        return suggested.byValue.array;
    }

    void analyzeFunctionRelationships()
    {
        writeln("Analyzing function relationships...");

        try
        {
            auto stmt = conn.prepare("
                SELECT f1.id as from_id, f2.id as to_id, COUNT(*) as cnt
                FROM functions f1
                JOIN functions f2 ON f1.module_id = f2.module_id
                WHERE f1.id != f2.id
                GROUP BY f1.id, f2.id
                HAVING COUNT(*) > 0
                LIMIT 1000
            ");

            foreach (row; stmt.execute())
            {
                auto insertStmt = conn.prepare("
                    INSERT OR IGNORE INTO function_relationships
                    (from_function_id, to_function_id, relationship_type, weight)
                    VALUES (?, ?, 'related', ?)
                ");
                insertStmt.bind(1, row["from_id"].as!long);
                insertStmt.bind(2, row["to_id"].as!long);
                insertStmt.bind(3, row["cnt"].as!int);
                insertStmt.execute();
            }
        }
        catch (Exception e)
        {
            stderr.writeln("Error analyzing relationships: ", e.msg);
        }

        writeln("  Function relationships analyzed");
    }

    void mineAllPatterns()
    {
        writeln("\n=== Mining Patterns ===");
        storeUsagePatterns();
        analyzeFunctionRelationships();
        writeln("=== Pattern Mining Complete ===\n");
    }
}