/** Usage pattern mining for discovering common import and function call patterns. */
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

/** A recurring combination of imports observed across code examples. */
struct ImportPattern {
	/** The set of import module names that co-occur. */
	string[] imports;
	/** Number of code examples containing this import combination. */
	int count;
	/** Names of packages in which this pattern was observed. */
	string[] packages;
}

/** A frequently called function and the contexts in which it appears. */
struct FunctionPattern {
	/** Fully qualified name of the function. */
	string name;
	/** Names of functions that call this function. */
	string[] callers;
	/** Number of times this call pattern was observed. */
	int count;
}

/**
 * Analyzes ingested data to discover recurring usage patterns and function
 * relationships.
 *
 * Queries the database for frequently co-occurring imports and function calls,
 * storing the discovered patterns back into the database for later retrieval.
 */
class PatternMiner {
	private DBConnection conn;
	private CRUDOperations crud;

	/**
	 * Constructs a pattern miner backed by the given database connection.
	 *
	 * Params:
	 *     conn = An open database connection to query and store patterns.
	 */
	this(DBConnection conn)
	{
		this.conn = conn;
		this.crud = new CRUDOperations(conn);
	}

	/**
	 * Mines the database for recurring import combinations in code examples.
	 *
	 * Params:
	 *     minOccurrences = Minimum number of times an import combination must
	 *                      appear to be included in the results.
	 *
	 * Returns:
	 *     An array of `ImportPattern` records sorted by frequency descending.
	 */
	ImportPattern[] mineImportPatterns(int minOccurrences = 2)
	{
		writeln("Mining import patterns...");

		ImportPattern[] patterns;

		try {
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

			foreach(row; stmt.execute()) {
				ImportPattern pattern;
				auto importsStr = row["required_imports"].as!string;
				pattern.imports = importsStr.split(",");
				pattern.count = row["cnt"].as!int;
				patterns ~= pattern;
			}
		} catch(Exception e) {
			stderr.writeln("Error mining import patterns: ", e.msg);
		}

		writeln("  Found ", patterns.length, " import patterns");
		return patterns;
	}

	/**
	 * Mines import patterns and stores them in the `usage_patterns` table.
	 *
	 * Only patterns with at least 3 occurrences and 2 or more imports are stored.
	 */
	void storeUsagePatterns()
	{
		writeln("Storing usage patterns...");

		auto patterns = mineImportPatterns(3);

		foreach(pattern; patterns) {
			if(pattern.imports.length < 2)
				continue;

			try {
				auto stmt = conn.prepare("
                    INSERT OR REPLACE INTO usage_patterns 
                    (pattern_name, description, function_ids, code_template, use_case, popularity)
                    VALUES (?, ?, ?, ?, ?, ?)
                ");

				string name = "Import: " ~ pattern.imports.join(" + ");
				string description = format("Common import combination used %d times",
						pattern.count);
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
			} catch(Exception e) {
			}
		}

		writeln("  Stored ", patterns.length, " usage patterns");
	}

	/**
	 * Retrieves the most commonly used imports across code examples for a package.
	 *
	 * Params:
	 *     packageName = Name of the package to query.
	 *
	 * Returns:
	 *     An array of unique import module names, ordered by frequency.
	 */
	string[] getCommonImportsForPackage(string packageName)
	{
		string[] imports;

		try {
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

			foreach(row; stmt.execute()) {
				auto importStr = row["required_imports"].as!string;
				foreach(imp; importStr.split(",")) {
					if(!imports.canFind(imp.strip())) {
						imports ~= imp.strip();
					}
				}
			}
		} catch(Exception e) {
		}

		return imports;
	}

	/**
	 * Suggests import statements for the given fully qualified symbol names.
	 *
	 * Derives module paths by stripping the final symbol component from each
	 * qualified name.
	 *
	 * Params:
	 *     symbols = Array of fully qualified symbol names (e.g., `std.stdio.writeln`).
	 *
	 * Returns:
	 *     An array of unique module paths suitable for import statements.
	 */
	string[] suggestImports(string[] symbols)
	{
		string[string] suggested;

		foreach(symbol; symbols) {
			try {
				auto parts = symbol.split(".");
				if(parts.length >= 2) {
					string modulePath = parts[0 .. $ - 1].join(".");
					suggested[modulePath] = modulePath;
				}
			} catch(Exception) {
			}
		}

		return suggested.byValue.array;
	}

	/**
	 * Discovers and stores function co-occurrence relationships.
	 *
	 * Finds functions that share a module and records their relationship
	 * in the `function_relationships` table.
	 */
	void analyzeFunctionRelationships()
	{
		writeln("Analyzing function relationships...");

		try {
			auto stmt = conn.prepare("
                SELECT f1.id as from_id, f2.id as to_id, COUNT(*) as cnt
                FROM functions f1
                JOIN functions f2 ON f1.module_id = f2.module_id
                WHERE f1.id != f2.id
                GROUP BY f1.id, f2.id
                HAVING COUNT(*) > 0
                LIMIT 1000
            ");

			foreach(row; stmt.execute()) {
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
		} catch(Exception e) {
			stderr.writeln("Error analyzing relationships: ", e.msg);
		}

		writeln("  Function relationships analyzed");
	}

	/**
	 * Runs the full pattern mining pipeline: import patterns, usage patterns,
	 * and function relationship analysis.
	 */
	void mineAllPatterns()
	{
		writeln("\n=== Mining Patterns ===");
		storeUsagePatterns();
		analyzeFunctionRelationships();
		writeln("=== Pattern Mining Complete ===\n");
	}
}
