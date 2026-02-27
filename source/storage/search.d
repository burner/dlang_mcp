/**
 * Hybrid search engine combining FTS5 full-text and sqlite-vec vector similarity.
 *
 * Provides ranked search across packages, functions, types, and code examples
 * using configurable weighting between BM25 text scores and cosine-distance
 * vector scores. Falls back to FTS-only when sqlite-vec is unavailable.
 */
module storage.search;

import storage.connection;
import storage.crud;
import embeddings.manager;
import models;
import d2sqlite3;
import std.algorithm;
import std.array;
import std.conv;
import std.math;
import std.string;
import std.logger : error;

/** Configuration for a search query. */
struct SearchOptions {
	string query; /** The search terms. */
	string packageName; /** Optional filter to restrict results to a specific package. */
	string kind; /** Optional entity kind filter: "function", "type", "package", or "example". */
	int limit = 20; /** Maximum number of results to return. */
	bool useVectors = true; /** Whether to include vector similarity scores when available. */
	float ftsWeight = 0.3f; /** Weight applied to the FTS BM25 score in combined ranking. */
	float vectorWeight = 0.7f; /** Weight applied to the vector cosine similarity score. */
}

/** Intermediate scoring container used during result merging. */
struct ScoredResult {
	long id; /** The entity row ID. */
	float ftsScore; /** BM25 full-text relevance score. */
	float vectorScore; /** Cosine similarity score from vector search. */
	float combinedScore; /** Weighted combination of FTS and vector scores. */
}

/**
 * Escape a user query for safe use in FTS5 MATCH expressions.
 *
 * Each whitespace-separated term is wrapped in double quotes so that FTS5
 * metacharacters (dots, asterisks, operators, etc.) are treated as literal
 * text rather than query syntax.  Internal double-quote characters are
 * escaped by doubling them per the FTS5 specification.
 *
 * Examples:
 *     "std.algorithm.filter" → `"std.algorithm.filter"`
 *     `map "hello"` → `"map" "\"hello\""`  (inner quotes escaped)
 */
private string escapeFTS5Query(string query)
{
	auto terms = query.strip().split().filter!(t => t.length > 0)
		.map!(t => `"` ~ t.replace(`"`, `""`) ~ `"`)
		.array;

	return terms.join(" ");
}

/**
 * Hybrid search engine that merges FTS5 and vector similarity results.
 *
 * Queries are executed against both the FTS5 indexes (for keyword relevance)
 * and the sqlite-vec vector tables (for semantic similarity). Results are
 * merged and ranked using a weighted combination of both scores.
 */
class HybridSearch {
	private DBConnection conn;
	private CRUDOperations crud;
	private EmbeddingManager embedder;
	private bool hasVectorSupport;

	/**
	 * Constructs the hybrid search engine.
	 *
	 * Params:
	 *     conn = The database connection. Vector support is auto-detected.
	 */
	this(DBConnection conn)
	{
		this.conn = conn;
		this.crud = new CRUDOperations(conn);
		this.embedder = EmbeddingManager.getInstance();
		this.hasVectorSupport = conn.hasVectorSupport() && embedder.hasVectorSupport();
	}

	/**
	 * Searches for functions matching the query.
	 *
	 * Params:
	 *     query = The search terms.
	 *     limit = Maximum number of results.
	 *     packageFilter = Optional package name to restrict results.
	 *
	 * Returns: Ranked search results.
	 */
	SearchResult[] searchFunctions(string query, int limit = 20, string packageFilter = null)
	{
		SearchOptions opts;
		opts.query = query;
		opts.packageName = packageFilter;
		opts.limit = limit;
		opts.kind = "function";
		return search(opts);
	}

	/**
	 * Searches for types matching the query.
	 *
	 * Params:
	 *     query = The search terms.
	 *     limit = Maximum number of results.
	 *     kindFilter = Optional type kind filter (class, struct, enum, interface).
	 *     packageFilter = Optional package name to restrict results.
	 *
	 * Returns: Ranked search results.
	 */
	SearchResult[] searchTypes(string query, int limit = 20,
			string kindFilter = null, string packageFilter = null)
	{
		SearchOptions opts;
		opts.query = query;
		opts.packageName = packageFilter;
		opts.limit = limit;
		opts.kind = kindFilter;
		return search(opts);
	}

	/**
	 * Searches for packages matching the query.
	 *
	 * Params:
	 *     query = The search terms.
	 *     limit = Maximum number of results.
	 *
	 * Returns: Ranked search results.
	 */
	SearchResult[] searchPackages(string query, int limit = 20)
	{
		SearchOptions opts;
		opts.query = query;
		opts.limit = limit;
		opts.kind = "package";
		return search(opts);
	}

	/**
	 * Searches for code examples matching the query.
	 *
	 * Params:
	 *     query = The search terms.
	 *     limit = Maximum number of results.
	 *     packageFilter = Optional package name to restrict results.
	 *
	 * Returns: Ranked search results.
	 */
	SearchResult[] searchExamples(string query, int limit = 20, string packageFilter = null)
	{
		SearchOptions opts;
		opts.query = query;
		opts.packageName = packageFilter;
		opts.limit = limit;
		opts.kind = "example";
		return search(opts);
	}

	/**
	 * Executes a search with full options, dispatching to the appropriate
	 * entity-specific search methods based on the `kind` filter.
	 *
	 * Params:
	 *     opts = The search configuration including query, filters, and weights.
	 *
	 * Returns: Combined and ranked search results across all matching entity types.
	 */
	SearchResult[] search(SearchOptions opts)
	{
		if(opts.query.empty) {
			return [];
		}

		SearchResult[] results;

		if(opts.kind == "package" || opts.kind.empty) {
			results ~= searchPackagesInternal(opts);
		}

		if(opts.kind == "function" || opts.kind.empty) {
			results ~= searchFunctionsInternal(opts);
		}

		if(opts.kind == "type" || opts.kind.empty) {
			results ~= searchTypesInternal(opts);
		}

		if(opts.kind == "example" || opts.kind.empty) {
			results ~= searchExamplesInternal(opts);
		}

		sort!"a.rank > b.rank"(results);

		if(results.length > opts.limit) {
			results = results[0 .. opts.limit];
		}

		return results;
	}

	/** Combine FTS and vector scores into a single rank using configured weights. */
	private static float combineScores(float ftsScore, float vecScore,
			float ftsWeight, float vecWeight)
	{
		float fts = ftsScore > 0 ? ftsScore : 0.0f;
		float vec = vecScore > 0 ? vecScore : 0.0f;

		if(fts > 0 && vec > 0)
			return fts * ftsWeight + vec * vecWeight;
		else if(fts > 0)
			return fts;
		else if(vec > 0)
			return vec;
		else
			return 0.0f;
	}

	/** Merge vector search results into existing combined results map. */
	private static void mergeVectorResults(ref ScoredResult[long] combinedResults,
			ScoredResult[] vecResults)
	{
		foreach(vr; vecResults) {
			if(vr.id <= 0)
				continue;

			if(vr.id in combinedResults) {
				combinedResults[vr.id].vectorScore = vr.vectorScore;
			} else {
				ScoredResult sr;
				sr.id = vr.id;
				sr.vectorScore = vr.vectorScore;
				combinedResults[vr.id] = sr;
			}
		}
	}

	private SearchResult[] searchPackagesInternal(SearchOptions opts)
	{
		ScoredResult[long] combinedResults;

		// FTS search with proper JOIN to resolve package_id
		try {
			auto ftsStmt = conn.prepare("
                SELECT p.id, fts.rank as score
                FROM fts_packages fts
                JOIN packages p ON p.id = fts.package_id
                WHERE fts_packages MATCH ?
                ORDER BY fts.rank
                LIMIT ?
            ");
			ftsStmt.bind(1, escapeFTS5Query(opts.query));
			ftsStmt.bind(2, opts.limit * 2);

			foreach(row; ftsStmt.execute()) {
				long id = row["id"].as!long;
				if(id <= 0)
					continue;

				ScoredResult sr;
				sr.id = id;
				sr.ftsScore = -row["score"].as!float;
				combinedResults[id] = sr;
			}
		} catch(Exception e) {
			error("searchPackagesInternal FTS failed: " ~ e.msg);
		}

		if(hasVectorSupport && opts.useVectors) {
			auto vecResults = searchVectorWithIds("vec_packages", opts.query, opts.limit * 2);
			mergeVectorResults(combinedResults, vecResults);
		}

		SearchResult[] results;
		foreach(id, sr; combinedResults) {
			SearchResult r;
			r.id = sr.id;
			r.name = getPackageName(sr.id);
			r.fullyQualifiedName = r.name;
			r.rank = combineScores(sr.ftsScore, sr.vectorScore, opts.ftsWeight, opts.vectorWeight);

			results ~= r;
		}

		sort!"a.rank > b.rank"(results);
		if(results.length > opts.limit)
			results = results[0 .. opts.limit];

		return results;
	}

	private SearchResult[] searchFunctionsInternal(SearchOptions opts)
	{
		ScoredResult[long] combinedResults;

		// FTS search
		try {
			string sql = "
                SELECT f.id, f.name, f.fully_qualified_name, f.signature, f.doc_comment,
                       m.full_path as module_name, p.name as package_name,
                       fts.rank as score
                FROM fts_functions fts
                JOIN functions f ON f.id = fts.function_id
                JOIN modules m ON m.id = f.module_id
                JOIN packages p ON p.id = m.package_id
                WHERE fts_functions MATCH ?
                ORDER BY fts.rank
                LIMIT ?
            ";

			if(!opts.packageName.empty) {
				sql = "
                    SELECT f.id, f.name, f.fully_qualified_name, f.signature, f.doc_comment,
                           m.full_path as module_name, p.name as package_name,
                           fts.rank as score
                    FROM fts_functions fts
                    JOIN functions f ON f.id = fts.function_id
                    JOIN modules m ON m.id = f.module_id
                    JOIN packages p ON p.id = m.package_id
                    WHERE p.name = ? AND fts_functions MATCH ?
                    ORDER BY fts.rank
                    LIMIT ?
                ";
			}

			auto stmt = conn.prepare(sql);
			int paramIdx = 1;

			if(!opts.packageName.empty) {
				stmt.bind(paramIdx++, opts.packageName);
			}

			stmt.bind(paramIdx++, escapeFTS5Query(opts.query));
			stmt.bind(paramIdx++, opts.limit * 2);

			foreach(row; stmt.execute()) {
				long id = row["id"].as!long;
				if(id <= 0)
					continue;

				ScoredResult sr;
				sr.id = id;
				sr.ftsScore = -row["score"].as!float;
				combinedResults[id] = sr;
			}
		} catch(Exception e) {
			error("searchFunctionsInternal FTS failed: " ~ e.msg);
		}

		// Vector search
		if(hasVectorSupport && opts.useVectors) {
			auto vecResults = searchVectorWithIds("vec_functions", opts.query, opts.limit * 2);
			mergeVectorResults(combinedResults, vecResults);
		}

		// Build final results
		SearchResult[] results;
		foreach(id, sr; combinedResults) {
			float rank = combineScores(sr.ftsScore, sr.vectorScore,
					opts.ftsWeight, opts.vectorWeight);

			if(rank <= 0.0f)
				continue;

			SearchResult r;
			r.id = id;
			r.rank = rank;
			results ~= r;
		}

		sort!"a.rank > b.rank"(results);
		if(results.length > opts.limit)
			results = results[0 .. opts.limit];

		if(results.length == 0)
			return results;

		// Fetch full details for ranked results
		long[] ids;
		foreach(r; results)
			ids ~= r.id;

		string detailSql = format("
            SELECT f.id, f.name, f.fully_qualified_name, f.signature, f.doc_comment,
                   m.full_path as module_name, p.name as package_name
            FROM functions f
            JOIN modules m ON m.id = f.module_id
            JOIN packages p ON p.id = m.package_id
            WHERE f.id IN (%s)
        ", ids.map!(n => n.text).join(","));

		try {
			auto stmt = conn.prepare(detailSql);
			foreach(row; stmt.execute()) {
				long id = row["id"].as!long;
				foreach(ref r; results) {
					if(r.id == id) {
						r.name = row["name"].as!string;
						r.fullyQualifiedName = row["fully_qualified_name"].as!string;
						if(row["signature"].type != SqliteType.NULL)
							r.signature = row["signature"].as!string;
						if(row["doc_comment"].type != SqliteType.NULL)
							r.docComment = row["doc_comment"].as!string;
						r.moduleName = row["module_name"].as!string;
						r.packageName = row["package_name"].as!string;
						break;
					}
				}
			}
		} catch(Exception e) {
			error("searchFunctionsInternal detail fetch failed: " ~ e.msg);
		}

		return results;
	}

	private SearchResult[] searchTypesInternal(SearchOptions opts)
	{
		ScoredResult[long] combinedResults;

		// FTS search
		try {
			string sql = "
                SELECT t.id, t.name, t.fully_qualified_name, t.kind, t.doc_comment,
                       m.full_path as module_name, p.name as package_name,
                       fts.rank as score
                FROM fts_types fts
                JOIN types t ON t.id = fts.type_id
                JOIN modules m ON m.id = t.module_id
                JOIN packages p ON p.id = m.package_id
                WHERE fts_types MATCH ?
                ORDER BY fts.rank
                LIMIT ?
            ";

			if(!opts.kind.empty && opts.kind != "type") {
				sql = "
                    SELECT t.id, t.name, t.fully_qualified_name, t.kind, t.doc_comment,
                           m.full_path as module_name, p.name as package_name,
                           fts.rank as score
                    FROM fts_types fts
                    JOIN types t ON t.id = fts.type_id
                    JOIN modules m ON m.id = t.module_id
                    JOIN packages p ON p.id = m.package_id
                    WHERE t.kind = ? AND fts_types MATCH ?
                    ORDER BY fts.rank
                    LIMIT ?
                ";
			}

			auto stmt = conn.prepare(sql);
			int paramIdx = 1;

			if(!opts.kind.empty && opts.kind != "type") {
				stmt.bind(paramIdx++, opts.kind);
			}

			stmt.bind(paramIdx++, escapeFTS5Query(opts.query));
			stmt.bind(paramIdx++, opts.limit * 2);

			foreach(row; stmt.execute()) {
				long id = row["id"].as!long;
				if(id <= 0)
					continue;

				ScoredResult sr;
				sr.id = id;
				sr.ftsScore = -row["score"].as!float;
				combinedResults[id] = sr;
			}
		} catch(Exception e) {
			error("searchTypesInternal FTS failed: " ~ e.msg);
		}

		// Vector search
		if(hasVectorSupport && opts.useVectors) {
			auto vecResults = searchVectorWithIds("vec_types", opts.query, opts.limit * 2);
			mergeVectorResults(combinedResults, vecResults);
		}

		// Build final results
		SearchResult[] results;
		foreach(id, sr; combinedResults) {
			float rank = combineScores(sr.ftsScore, sr.vectorScore,
					opts.ftsWeight, opts.vectorWeight);

			if(rank <= 0.0f)
				continue;

			SearchResult r;
			r.id = id;
			r.rank = rank;
			results ~= r;
		}

		sort!"a.rank > b.rank"(results);
		if(results.length > opts.limit)
			results = results[0 .. opts.limit];

		if(results.length == 0)
			return results;

		// Fetch full details for ranked results
		long[] ids;
		foreach(r; results)
			ids ~= r.id;

		string detailSql = format("
            SELECT t.id, t.name, t.fully_qualified_name, t.kind, t.doc_comment,
                   m.full_path as module_name, p.name as package_name
            FROM types t
            JOIN modules m ON m.id = t.module_id
            JOIN packages p ON p.id = m.package_id
            WHERE t.id IN (%s)
        ", ids.map!(n => n.text).join(","));

		try {
			auto stmt = conn.prepare(detailSql);
			foreach(row; stmt.execute()) {
				long id = row["id"].as!long;
				foreach(ref r; results) {
					if(r.id == id) {
						r.name = row["name"].as!string;
						r.fullyQualifiedName = row["fully_qualified_name"].as!string;
						if(row["doc_comment"].type != SqliteType.NULL)
							r.docComment = row["doc_comment"].as!string;
						r.moduleName = row["module_name"].as!string;
						r.packageName = row["package_name"].as!string;
						break;
					}
				}
			}
		} catch(Exception e) {
			error("searchTypesInternal detail fetch failed: " ~ e.msg);
		}

		return results;
	}

	private SearchResult[] searchExamplesInternal(SearchOptions opts)
	{
		ScoredResult[long] combinedResults;

		try {
			string sql = "
                SELECT e.id, fts.rank as score
                FROM fts_examples fts
                JOIN code_examples e ON e.id = fts.example_id
                WHERE fts_examples MATCH ?
                ORDER BY fts.rank
                LIMIT ?
            ";

			if(!opts.packageName.empty) {
				sql = "
                    SELECT e.id, fts.rank as score
                    FROM fts_examples fts
                    JOIN code_examples e ON e.id = fts.example_id
                    LEFT JOIN packages p ON p.id = e.package_id
                    WHERE p.name = ? AND fts_examples MATCH ?
                    ORDER BY fts.rank
                    LIMIT ?
                ";
			}

			auto ftsStmt = conn.prepare(sql);
			int paramIdx = 1;

			if(!opts.packageName.empty) {
				ftsStmt.bind(paramIdx++, opts.packageName);
			}

			ftsStmt.bind(paramIdx++, escapeFTS5Query(opts.query));
			ftsStmt.bind(paramIdx++, opts.limit * 2);

			foreach(row; ftsStmt.execute()) {
				long id = row["id"].as!long;
				if(id <= 0)
					continue;

				ScoredResult sr;
				sr.id = id;
				sr.ftsScore = -row["score"].as!float;
				combinedResults[id] = sr;
			}
		} catch(Exception e) {
			error("searchExamplesInternal FTS failed: " ~ e.msg);
		}

		if(hasVectorSupport && opts.useVectors) {
			auto vecResults = searchVectorWithIds("vec_examples", opts.query, opts.limit * 2);
			mergeVectorResults(combinedResults, vecResults);
		}

		SearchResult[] results;
		foreach(id, sr; combinedResults) {
			float rank = combineScores(sr.ftsScore, sr.vectorScore,
					opts.ftsWeight, opts.vectorWeight);

			if(rank <= 0.0f)
				continue;

			SearchResult r;
			r.id = id;
			r.rank = rank;
			results ~= r;
		}

		sort!"a.rank > b.rank"(results);
		if(results.length > opts.limit)
			results = results[0 .. opts.limit];

		if(results.length == 0)
			return results;

		long[] ids;
		foreach(r; results)
			ids ~= r.id;

		string sql = format("
            SELECT e.id, e.code, e.description, e.required_imports,
                   f.name as function_name, p.name as package_name
            FROM code_examples e
            LEFT JOIN functions f ON f.id = e.function_id
            LEFT JOIN packages p ON p.id = e.package_id
            WHERE e.id IN (%s)
        ", ids.map!(n => n.text).join(","));

		try {
			auto stmt = conn.prepare(sql);
			foreach(row; stmt.execute()) {
				long id = row["id"].as!long;
				foreach(ref r; results) {
					if(r.id == id) {
						r.name = row["function_name"].type != SqliteType.NULL
							? row["function_name"].as!string : "";
						r.docComment = row["description"].type != SqliteType.NULL
							? row["description"].as!string : "";
						r.packageName = row["package_name"].type != SqliteType.NULL
							? row["package_name"].as!string : "";
						r.signature = row["code"].as!string;
						break;
					}
				}
			}
		} catch(Exception e) {
			error("searchExamplesInternal detail fetch failed: " ~ e.msg);
		}

		return results;
	}

	/**
	 * Performs a vector similarity search and returns scored results.
	 *
	 * Params:
	 *     table = The vector table name (e.g. "vec_functions").
	 *     query = The search text to embed and compare against.
	 *     limit = Maximum number of nearest neighbours to return.
	 *
	 * Returns: An array of `ScoredResult` with vector similarity scores.
	 */
	ScoredResult[] searchVectorWithIds(string table, string query, int limit)
	{
		ScoredResult[] results;

		if(!hasVectorSupport)
			return results;

		try {
			auto embedding = embedder.embed(query);

			import std.format;

			string blobStr = "X'";
			foreach(f; embedding) {
				uint bits = *cast(uint*)&f;
				ubyte[4] bytes = (cast(ubyte*)&bits)[0 .. 4];
				foreach(b; bytes)
					blobStr ~= format("%02x", b);
			}
			blobStr ~= "'";

			string idCol = "";
			if(table == "vec_packages")
				idCol = "package_id";
			else if(table == "vec_functions")
				idCol = "function_id";
			else if(table == "vec_types")
				idCol = "type_id";
			else if(table == "vec_examples")
				idCol = "example_id";

			string sql = format("
                SELECT %s as id, distance
                FROM %s
                WHERE embedding MATCH %s
                AND k = ?
            ", idCol, table, blobStr);

			auto stmt = conn.prepare(sql);
			stmt.bind(1, limit);

			foreach(row; stmt.execute()) {
				ScoredResult sr;
				sr.id = row["id"].as!long;
				float dist = row["distance"].as!float;
				sr.vectorScore = isFinite(dist) ? 1.0f - dist : 0.0f;
				sr.combinedScore = sr.vectorScore;
				results ~= sr;
			}
		} catch(Exception e) {
			error("searchVectorWithIds on " ~ table ~ " failed: " ~ e.msg);
		}

		return results;
	}

	private string getPackageName(long id)
	{
		try {
			auto stmt = conn.prepare("SELECT name FROM packages WHERE id = ?");
			stmt.bind(1, id);
			auto result = stmt.execute();
			if(!result.empty) {
				return result.front["name"].as!string;
			}
		} catch(Exception e) {
			error("getPackageName failed for id " ~ id.text ~ ": " ~ e.msg);
		}
		return "";
	}

	/**
	 * Resolves the import paths required for a fully qualified symbol.
	 *
	 * First checks the import_requirements table; if empty, infers the
	 * module path from the symbol's fully qualified name.
	 *
	 * Params:
	 *     fullyQualifiedName = The dot-separated fully qualified symbol name.
	 *
	 * Returns: An array of module paths to import.
	 */
	string[] getImportsForSymbol(string fullyQualifiedName)
	{
		string[] imports;

		auto parts = fullyQualifiedName.split(".");
		if(parts.length < 2) {
			return imports;
		}

		string moduleName = parts[0 .. $ - 1].join(".");

		try {
			auto stmt = conn.prepare("
                SELECT DISTINCT ir.module_path
                FROM import_requirements ir
                JOIN functions f ON f.id = ir.function_id
                WHERE f.fully_qualified_name = ?
                UNION
                SELECT DISTINCT ir.module_path
                FROM import_requirements ir
                JOIN types t ON t.id = ir.type_id
                WHERE t.fully_qualified_name = ?
            ");
			stmt.bind(1, fullyQualifiedName);
			stmt.bind(2, fullyQualifiedName);

			foreach(row; stmt.execute()) {
				imports ~= row["module_path"].as!string;
			}

			if(imports.empty) {
				imports ~= moduleName;
			}
		} catch(Exception e) {
			error("getImportsForSymbol failed for " ~ fullyQualifiedName ~ ": " ~ e.msg);
			imports ~= moduleName;
		}

		return imports;
	}

	/**
	 * Resolves import paths for multiple symbols, deduplicating the results.
	 *
	 * Params:
	 *     symbols = An array of fully qualified symbol names.
	 *
	 * Returns: A deduplicated array of module paths to import.
	 */
	string[] getImportsForSymbols(string[] symbols)
	{
		string[string] uniqueImports;

		foreach(symbol; symbols) {
			foreach(imp; getImportsForSymbol(symbol)) {
				uniqueImports[imp] = imp;
			}
		}

		return uniqueImports.byValue.array;
	}
}
