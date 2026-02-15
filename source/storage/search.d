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

struct SearchOptions
{
    string query;
    string packageName;
    string kind;
    int limit = 20;
    bool useVectors = true;
    float ftsWeight = 0.3f;
    float vectorWeight = 0.7f;
}

struct ScoredResult
{
    long id;
    float ftsScore;
    float vectorScore;
    float combinedScore;
}

class HybridSearch
{
    private DBConnection conn;
    private CRUDOperations crud;
    private EmbeddingManager embedder;
    private bool hasVectorSupport;

    this(DBConnection conn)
    {
        this.conn = conn;
        this.crud = new CRUDOperations(conn);
        this.embedder = EmbeddingManager.getInstance();
        this.hasVectorSupport = conn.hasVectorSupport() && embedder.hasVectorSupport();
    }

    SearchResult[] searchFunctions(string query, int limit = 20, string packageFilter = null)
    {
        SearchOptions opts;
        opts.query = query;
        opts.packageName = packageFilter;
        opts.limit = limit;
        opts.kind = "function";
        return search(opts);
    }

    SearchResult[] searchTypes(string query, int limit = 20, string kindFilter = null, string packageFilter = null)
    {
        SearchOptions opts;
        opts.query = query;
        opts.packageName = packageFilter;
        opts.limit = limit;
        opts.kind = kindFilter;
        return search(opts);
    }

    SearchResult[] searchPackages(string query, int limit = 20)
    {
        SearchOptions opts;
        opts.query = query;
        opts.limit = limit;
        opts.kind = "package";
        return search(opts);
    }

    SearchResult[] searchExamples(string query, int limit = 20, string packageFilter = null)
    {
        SearchOptions opts;
        opts.query = query;
        opts.packageName = packageFilter;
        opts.limit = limit;
        opts.kind = "example";
        return search(opts);
    }

    SearchResult[] search(SearchOptions opts)
    {
        if (opts.query.empty)
        {
            return [];
        }

        SearchResult[] results;

        if (opts.kind == "package" || opts.kind.empty)
        {
            results ~= searchPackagesInternal(opts);
        }

        if (opts.kind == "function" || opts.kind.empty)
        {
            results ~= searchFunctionsInternal(opts);
        }

        if (opts.kind == "type" || opts.kind.empty)
        {
            results ~= searchTypesInternal(opts);
        }

        if (opts.kind == "example" || opts.kind.empty)
        {
            results ~= searchExamplesInternal(opts);
        }

        sort!"a.rank > b.rank"(results);

        if (results.length > opts.limit)
        {
            results = results[0 .. opts.limit];
        }

        return results;
    }

    private SearchResult[] searchPackagesInternal(SearchOptions opts)
    {
        ScoredResult[long] combinedResults;

        auto ftsResults = searchFts("fts_packages", opts.query, opts.limit * 2);
        foreach (ftsr; ftsResults)
        {
            if (ftsr.id <= 0) continue;
            
            ScoredResult sr;
            sr.id = ftsr.id;
            sr.ftsScore = ftsr.ftsScore;
            combinedResults[ftsr.id] = sr;
        }

        if (hasVectorSupport && opts.useVectors)
        {
            auto vecResults = searchVectorWithIds("vec_packages", opts.query, opts.limit * 2);
            foreach (vr; vecResults)
            {
                if (vr.id <= 0) continue;
                
                if (vr.id in combinedResults)
                {
                    combinedResults[vr.id].vectorScore = vr.vectorScore;
                }
                else
                {
                    ScoredResult sr;
                    sr.id = vr.id;
                    sr.vectorScore = vr.vectorScore;
                    combinedResults[vr.id] = sr;
                }
            }
        }

        SearchResult[] results;
        foreach (id, sr; combinedResults)
        {
            SearchResult r;
            r.id = sr.id;
            r.name = getPackageName(sr.id);
            r.fullyQualifiedName = r.name;
            
            float fts = sr.ftsScore > 0 ? sr.ftsScore : 0.0f;
            float vec = sr.vectorScore > 0 ? sr.vectorScore : 0.0f;
            
            if (fts > 0 && vec > 0)
                r.rank = fts * opts.ftsWeight + vec * opts.vectorWeight;
            else if (fts > 0)
                r.rank = fts;
            else if (vec > 0)
                r.rank = vec;
            else
                r.rank = 0.0f;

            results ~= r;
        }

        sort!"a.rank > b.rank"(results);
        if (results.length > opts.limit)
            results = results[0 .. opts.limit];

        return results;
    }

    private SearchResult[] searchFunctionsInternal(SearchOptions opts)
    {
        string sql = "
            SELECT f.id, f.name, f.fully_qualified_name, f.signature, f.doc_comment,
                   m.full_path as module_name, p.name as package_name
            FROM functions f
            JOIN modules m ON m.id = f.module_id
            JOIN packages p ON p.id = m.package_id
            WHERE f.id IN (
                SELECT rowid FROM fts_functions WHERE fts_functions MATCH ?
                ORDER BY bm25(fts_functions) DESC LIMIT ?
            )
        ";

        if (!opts.packageName.empty)
        {
            sql = "
                SELECT f.id, f.name, f.fully_qualified_name, f.signature, f.doc_comment,
                       m.full_path as module_name, p.name as package_name
                FROM functions f
                JOIN modules m ON m.id = f.module_id
                JOIN packages p ON p.id = m.package_id
                WHERE p.name = ? AND f.id IN (
                    SELECT rowid FROM fts_functions WHERE fts_functions MATCH ?
                    ORDER BY bm25(fts_functions) DESC LIMIT ?
                )
            ";
        }

        SearchResult[] results;

        try
        {
            auto stmt = conn.prepare(sql);
            int paramIdx = 1;

            if (!opts.packageName.empty)
            {
                stmt.bind(paramIdx++, opts.packageName);
            }

            stmt.bind(paramIdx++, opts.query);
            stmt.bind(paramIdx++, opts.limit * 2);

            auto queryEmbedding = embedder.embed(opts.query);

            foreach (row; stmt.execute())
            {
                SearchResult sr;
                sr.id = row["id"].as!long;
                sr.name = row["name"].as!string;
                sr.fullyQualifiedName = row["fully_qualified_name"].as!string;
                sr.signature = row["signature"].as!string;
                sr.docComment = row["doc_comment"].as!string;
                sr.moduleName = row["module_name"].as!string;
                sr.packageName = row["package_name"].as!string;

                sr.rank = 0.5f;

                results ~= sr;
            }
        }
        catch (Exception e)
        {
        }

        return results;
    }

    private SearchResult[] searchTypesInternal(SearchOptions opts)
    {
        string sql = "
            SELECT t.id, t.name, t.fully_qualified_name, t.kind, t.doc_comment,
                   m.full_path as module_name, p.name as package_name
            FROM types t
            JOIN modules m ON m.id = t.module_id
            JOIN packages p ON p.id = m.package_id
            WHERE t.id IN (
                SELECT rowid FROM fts_types WHERE fts_types MATCH ?
                ORDER BY bm25(fts_types) DESC LIMIT ?
            )
        ";

        if (!opts.kind.empty && opts.kind != "type")
        {
            sql = "
                SELECT t.id, t.name, t.fully_qualified_name, t.kind, t.doc_comment,
                       m.full_path as module_name, p.name as package_name
                FROM types t
                JOIN modules m ON m.id = t.module_id
                JOIN packages p ON p.id = m.package_id
                WHERE t.kind = ? AND t.id IN (
                    SELECT rowid FROM fts_types WHERE fts_types MATCH ?
                    ORDER BY bm25(fts_types) DESC LIMIT ?
                )
            ";
        }

        SearchResult[] results;

        try
        {
            auto stmt = conn.prepare(sql);
            int paramIdx = 1;

            if (!opts.kind.empty && opts.kind != "type")
            {
                stmt.bind(paramIdx++, opts.kind);
            }

            stmt.bind(paramIdx++, opts.query);
            stmt.bind(paramIdx++, opts.limit * 2);

            foreach (row; stmt.execute())
            {
                SearchResult sr;
                sr.id = row["id"].as!long;
                sr.name = row["name"].as!string;
                sr.fullyQualifiedName = row["fully_qualified_name"].as!string;
                sr.docComment = row["doc_comment"].as!string;
                sr.moduleName = row["module_name"].as!string;
                sr.packageName = row["package_name"].as!string;

                sr.rank = 0.5f;

                results ~= sr;
            }
        }
        catch (Exception e)
        {
        }

        return results;
    }

    private SearchResult[] searchExamplesInternal(SearchOptions opts)
    {
        ScoredResult[long] combinedResults;

        try
        {
            auto ftsStmt = conn.prepare("
                SELECT rowid as id, bm25(fts_examples) as score 
                FROM fts_examples 
                WHERE fts_examples MATCH ? 
                ORDER BY score 
                LIMIT ?
            ");
            ftsStmt.bind(1, opts.query);
            ftsStmt.bind(2, opts.limit * 2);

            foreach (row; ftsStmt.execute())
            {
                long id = row["id"].as!long;
                if (id <= 0) continue;
                
                ScoredResult sr;
                sr.id = id;
                sr.ftsScore = -row["score"].as!float;
                combinedResults[id] = sr;
            }
        }
        catch (Exception e)
        {
        }

        if (hasVectorSupport && opts.useVectors)
        {
            auto vecResults = searchVectorWithIds("vec_examples", opts.query, opts.limit * 2);
            foreach (vr; vecResults)
            {
                if (vr.id <= 0) continue;
                
                if (vr.id in combinedResults)
                {
                    combinedResults[vr.id].vectorScore = vr.vectorScore;
                }
                else
                {
                    ScoredResult sr;
                    sr.id = vr.id;
                    sr.vectorScore = vr.vectorScore;
                    combinedResults[vr.id] = sr;
                }
            }
        }

        SearchResult[] results;
        foreach (id, sr; combinedResults)
        {
            float fts = sr.ftsScore > 0 ? sr.ftsScore : 0.0f;
            float vec = sr.vectorScore > 0 ? sr.vectorScore : 0.0f;

            float rank;
            if (fts > 0 && vec > 0)
                rank = fts * opts.ftsWeight + vec * opts.vectorWeight;
            else if (fts > 0)
                rank = fts;
            else if (vec > 0)
                rank = vec;
            else
                continue;

            SearchResult r;
            r.id = id;
            r.rank = rank;
            results ~= r;
        }

        sort!"a.rank > b.rank"(results);
        if (results.length > opts.limit)
            results = results[0 .. opts.limit];

        if (results.length == 0)
            return results;

        long[] ids;
        foreach (r; results)
            ids ~= r.id;

        string sql = format("
            SELECT e.id, e.code, e.description, e.required_imports,
                   f.name as function_name, p.name as package_name
            FROM code_examples e
            LEFT JOIN functions f ON f.id = e.function_id
            LEFT JOIN packages p ON p.id = e.package_id
            WHERE e.id IN (%s)
        ", ids.map!(n => n.text).join(","));

        try
        {
            auto stmt = conn.prepare(sql);
            foreach (row; stmt.execute())
            {
                long id = row["id"].as!long;
                foreach (ref r; results)
                {
                    if (r.id == id)
                    {
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
        }
        catch (Exception e)
        {
        }

        return results;
    }

    private ScoredResult[] searchFts(string table, string query, int limit)
    {
        ScoredResult[] results;

        try
        {
            string sql = format("SELECT rowid as id, bm25(%s) as score FROM %s WHERE %s MATCH ? ORDER BY score LIMIT ?",
                               table, table, table);

            auto stmt = conn.prepare(sql);
            stmt.bind(1, query);
            stmt.bind(2, limit);

            foreach (row; stmt.execute())
            {
                ScoredResult sr;
                sr.id = row["id"].as!long;
                sr.ftsScore = -row["score"].as!float;
                sr.combinedScore = sr.ftsScore;
                results ~= sr;
            }
        }
        catch (Exception e)
        {
        }

        return results;
    }

    ScoredResult[] searchVectorWithIds(string table, string query, int limit)
    {
        ScoredResult[] results;

        if (!hasVectorSupport)
            return results;

        try
        {
            auto embedding = embedder.embed(query);
            
            import std.math;
            
            string blobStr = "X'";
            foreach (f; embedding)
            {
                import std.format;
                uint bits = *cast(uint*)&f;
                ubyte[4] bytes = (cast(ubyte*)&bits)[0 .. 4];
                foreach (b; bytes)
                    blobStr ~= format("%02x", b);
            }
            blobStr ~= "'";

            string idCol = "";
            if (table == "vec_packages")
                idCol = "package_id";
            else if (table == "vec_functions")
                idCol = "function_id";
            else if (table == "vec_types")
                idCol = "type_id";
            else if (table == "vec_examples")
                idCol = "example_id";

            string sql = format("
                SELECT %s as id, distance
                FROM %s
                WHERE embedding MATCH %s
                AND k = ?
            ", idCol, table, blobStr);

            auto stmt = conn.prepare(sql);
            stmt.bind(1, limit);

            foreach (row; stmt.execute())
            {
                ScoredResult sr;
                sr.id = row["id"].as!long;
                float dist = row["distance"].as!float;
                sr.vectorScore = isFinite(dist) ? 1.0f - dist : 0.0f;
                sr.combinedScore = sr.vectorScore;
                results ~= sr;
            }
        }
        catch (Exception e)
        {
        }

        return results;
    }

    private string getPackageName(long id)
    {
        try
        {
            auto stmt = conn.prepare("SELECT name FROM packages WHERE id = ?");
            stmt.bind(1, id);
            auto result = stmt.execute();
            if (!result.empty)
            {
                return result.front["name"].as!string;
            }
        }
        catch (Exception)
        {
        }
        return "";
    }

    string[] getImportsForSymbol(string fullyQualifiedName)
    {
        string[] imports;

        auto parts = fullyQualifiedName.split(".");
        if (parts.length < 2)
        {
            return imports;
        }

        string moduleName = parts[0 .. $-1].join(".");

        try
        {
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

            foreach (row; stmt.execute())
            {
                imports ~= row["module_path"].as!string;
            }

            if (imports.empty)
            {
                imports ~= moduleName;
            }
        }
        catch (Exception)
        {
            imports ~= moduleName;
        }

        return imports;
    }

    string[] getImportsForSymbols(string[] symbols)
    {
        string[string] uniqueImports;

        foreach (symbol; symbols)
        {
            foreach (imp; getImportsForSymbol(symbol))
            {
                uniqueImports[imp] = imp;
            }
        }

        return uniqueImports.byValue.array;
    }
}