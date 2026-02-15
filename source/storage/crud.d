module storage.crud;

import storage.connection;
import models;
import d2sqlite3;
import std.algorithm;
import std.array;
import std.conv;
import std.string;

private bool isNotNull(ColumnData col)
{
    return col.type != SqliteType.NULL;
}

class CRUDOperations
{
    private DBConnection conn;

    this(DBConnection conn)
    {
        this.conn = conn;
    }

    long insertPackage(PackageMetadata pkg)
    {
        auto stmt = conn.prepare("
            INSERT OR REPLACE INTO packages 
            (name, version, description, repository, homepage, license, authors, tags)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ");

        stmt.bind(1, pkg.name);
        stmt.bind(2, pkg.version_);
        stmt.bind(3, pkg.description);
        stmt.bind(4, pkg.repository);
        stmt.bind(5, pkg.homepage);
        stmt.bind(6, pkg.license);
        stmt.bind(7, pkg.authors.join(","));
        stmt.bind(8, pkg.tags.join(","));
        stmt.execute();

        return conn.lastInsertRowid();
    }

    PackageMetadata getPackage(string name)
    {
        auto stmt = conn.prepare("SELECT * FROM packages WHERE name = ?");
        stmt.bind(1, name);
        auto result = stmt.execute();

        if (result.empty)
        {
            throw new Exception("Package not found: " ~ name);
        }

        return parsePackageRow(result.front);
    }

    PackageMetadata parsePackageRow(Row row)
    {
        PackageMetadata pkg;
        pkg.name = row["name"].as!string;
        pkg.version_ = row["version"].as!string;
        if (isNotNull(row["description"]))
            pkg.description = row["description"].as!string;
        if (isNotNull(row["repository"]))
            pkg.repository = row["repository"].as!string;
        if (isNotNull(row["homepage"]))
            pkg.homepage = row["homepage"].as!string;
        if (isNotNull(row["license"]))
            pkg.license = row["license"].as!string;
        if (isNotNull(row["authors"]))
        {
            auto authorsStr = row["authors"].as!string;
            if (authorsStr.length > 0)
                pkg.authors = authorsStr.split(",");
        }
        if (isNotNull(row["tags"]))
        {
            auto tagsStr = row["tags"].as!string;
            if (tagsStr.length > 0)
                pkg.tags = tagsStr.split(",");
        }
        return pkg;
    }

    long getPackageId(string name)
    {
        auto stmt = conn.prepare("SELECT id FROM packages WHERE name = ?");
        stmt.bind(1, name);
        auto result = stmt.execute();

        if (result.empty)
        {
            return -1;
        }

        return result.front["id"].as!long;
    }

    string[] getAllPackageNames()
    {
        auto stmt = conn.prepare("SELECT name FROM packages ORDER BY name");
        auto result = stmt.execute();

        string[] names;
        foreach (row; result)
        {
            names ~= row["name"].as!string;
        }
        return names;
    }

    long insertModule(long packageId, ModuleDoc mod)
    {
        auto stmt = conn.prepare("
            INSERT OR REPLACE INTO modules (package_id, name, full_path, doc_comment)
            VALUES (?, ?, ?, ?)
        ");

        stmt.bind(1, packageId);
        auto parts = mod.name.split(".");
        stmt.bind(2, parts.length > 0 ? parts[$-1] : mod.name);
        stmt.bind(3, mod.name);
        stmt.bind(4, mod.docComment);
        stmt.execute();

        return conn.lastInsertRowid();
    }

    long getModuleId(string fullPath)
    {
        auto stmt = conn.prepare("SELECT id FROM modules WHERE full_path = ?");
        stmt.bind(1, fullPath);
        auto result = stmt.execute();

        if (result.empty)
        {
            return -1;
        }

        return result.front["id"].as!long;
    }

    long insertFunction(long moduleId, FunctionDoc func)
    {
        auto stmt = conn.prepare("
            INSERT OR REPLACE INTO functions
            (module_id, name, fully_qualified_name, signature, return_type,
             doc_comment, parameters, examples, is_template,
             time_complexity, space_complexity, is_nogc, is_nothrow, is_pure, is_safe)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ");

        stmt.bind(1, moduleId);
        stmt.bind(2, func.name);
        stmt.bind(3, func.fullyQualifiedName);
        stmt.bind(4, func.signature);
        stmt.bind(5, func.returnType);
        stmt.bind(6, func.docComment);
        stmt.bind(7, func.parameters.join(";"));
        stmt.bind(8, func.examples.join("\n---\n"));
        stmt.bind(9, func.isTemplate ? 1 : 0);
        stmt.bind(10, func.performance.timeComplexity);
        stmt.bind(11, func.performance.spaceComplexity);
        stmt.bind(12, func.performance.isNogc ? 1 : 0);
        stmt.bind(13, func.performance.isNothrow ? 1 : 0);
        stmt.bind(14, func.performance.isPure ? 1 : 0);
        stmt.bind(15, func.performance.isSafe ? 1 : 0);
        stmt.execute();

        return conn.lastInsertRowid();
    }

    long getFunctionId(string fqn)
    {
        auto stmt = conn.prepare("SELECT id FROM functions WHERE fully_qualified_name = ?");
        stmt.bind(1, fqn);
        auto result = stmt.execute();

        if (result.empty)
        {
            return -1;
        }

        return result.front["id"].as!long;
    }

    FunctionDoc getFunction(long id)
    {
        auto stmt = conn.prepare("
            SELECT f.*, m.full_path as module_name, p.name as package_name
            FROM functions f
            JOIN modules m ON m.id = f.module_id
            JOIN packages p ON p.id = m.package_id
            WHERE f.id = ?
        ");
        stmt.bind(1, id);
        auto result = stmt.execute();

        if (result.empty)
        {
            throw new Exception("Function not found: " ~ id.text);
        }

        return parseFunctionRow(result.front);
    }

    FunctionDoc parseFunctionRow(Row row)
    {
        FunctionDoc func;
        func.name = row["name"].as!string;
        func.fullyQualifiedName = row["fully_qualified_name"].as!string;
        func.moduleName = row["module_name"].as!string;
        func.packageName = row["package_name"].as!string;
        if (isNotNull(row["signature"]))
            func.signature = row["signature"].as!string;
        if (isNotNull(row["return_type"]))
            func.returnType = row["return_type"].as!string;
        if (isNotNull(row["doc_comment"]))
            func.docComment = row["doc_comment"].as!string;
        if (isNotNull(row["parameters"]))
        {
            auto paramsStr = row["parameters"].as!string;
            if (paramsStr.length > 0)
                func.parameters = paramsStr.split(";");
        }
        if (isNotNull(row["examples"]))
        {
            auto exStr = row["examples"].as!string;
            if (exStr.length > 0)
                func.examples = exStr.split("\n---\n");
        }
        func.isTemplate = row["is_template"].as!int == 1;
        if (isNotNull(row["time_complexity"]))
            func.performance.timeComplexity = row["time_complexity"].as!string;
        if (isNotNull(row["space_complexity"]))
            func.performance.spaceComplexity = row["space_complexity"].as!string;
        func.performance.isNogc = row["is_nogc"].as!int == 1;
        func.performance.isNothrow = row["is_nothrow"].as!int == 1;
        func.performance.isPure = row["is_pure"].as!int == 1;
        func.performance.isSafe = row["is_safe"].as!int == 1;
        return func;
    }

    long insertType(long moduleId, TypeDoc type)
    {
        auto stmt = conn.prepare("
            INSERT OR REPLACE INTO types
            (module_id, name, fully_qualified_name, kind, doc_comment, base_classes, interfaces)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        ");

        stmt.bind(1, moduleId);
        stmt.bind(2, type.name);
        stmt.bind(3, type.fullyQualifiedName);
        stmt.bind(4, type.kind);
        stmt.bind(5, type.docComment);
        stmt.bind(6, type.baseClasses.join(","));
        stmt.bind(7, type.interfaces.join(","));
        stmt.execute();

        return conn.lastInsertRowid();
    }

    long getTypeId(string fqn)
    {
        auto stmt = conn.prepare("SELECT id FROM types WHERE fully_qualified_name = ?");
        stmt.bind(1, fqn);
        auto result = stmt.execute();

        if (result.empty)
        {
            return -1;
        }

        return result.front["id"].as!long;
    }

    long insertCodeExample(CodeExample example)
    {
        auto stmt = conn.prepare("
            INSERT INTO code_examples
            (function_id, type_id, package_id, code, description, 
             is_unittest, is_runnable, required_imports)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ");

        if (example.functionId > 0)
            stmt.bind(1, example.functionId);
        else
            stmt.bind(1, null);

        if (example.typeId > 0)
            stmt.bind(2, example.typeId);
        else
            stmt.bind(2, null);

        if (example.packageId > 0)
            stmt.bind(3, example.packageId);
        else
            stmt.bind(3, null);

        stmt.bind(4, example.code);
        stmt.bind(5, example.description);
        stmt.bind(6, example.isUnittest ? 1 : 0);
        stmt.bind(7, example.isRunnable ? 1 : 0);
        stmt.bind(8, example.requiredImports.join(","));
        stmt.execute();

        return conn.lastInsertRowid();
    }

    CodeExample[] getCodeExamplesForFunction(long functionId)
    {
        auto stmt = conn.prepare("
            SELECT * FROM code_examples 
            WHERE function_id = ? AND is_runnable = 1
            ORDER BY is_unittest DESC
        ");
        stmt.bind(1, functionId);
        auto result = stmt.execute();

        CodeExample[] examples;
        foreach (row; result)
        {
            examples ~= parseCodeExampleRow(row);
        }

        return examples;
    }

    CodeExample parseCodeExampleRow(Row row)
    {
        CodeExample ex;
        if (isNotNull(row["function_id"]))
            ex.functionId = row["function_id"].as!long;
        if (isNotNull(row["type_id"]))
            ex.typeId = row["type_id"].as!long;
        if (isNotNull(row["package_id"]))
            ex.packageId = row["package_id"].as!long;
        ex.code = row["code"].as!string;
        if (isNotNull(row["description"]))
            ex.description = row["description"].as!string;
        ex.isUnittest = row["is_unittest"].as!int == 1;
        ex.isRunnable = row["is_runnable"].as!int == 1;
        if (isNotNull(row["required_imports"]))
        {
            auto importsStr = row["required_imports"].as!string;
            if (importsStr.length > 0)
                ex.requiredImports = importsStr.split(",");
        }
        return ex;
    }

    struct DBStats
    {
        long packageCount;
        long moduleCount;
        long functionCount;
        long typeCount;
        long exampleCount;
    }

    DBStats getStats()
    {
        DBStats stats;

        auto stmt = conn.prepare("SELECT COUNT(*) as cnt FROM packages");
        stats.packageCount = stmt.execute().front["cnt"].as!long;

        stmt = conn.prepare("SELECT COUNT(*) as cnt FROM modules");
        stats.moduleCount = stmt.execute().front["cnt"].as!long;

        stmt = conn.prepare("SELECT COUNT(*) as cnt FROM functions");
        stats.functionCount = stmt.execute().front["cnt"].as!long;

        stmt = conn.prepare("SELECT COUNT(*) as cnt FROM types");
        stats.typeCount = stmt.execute().front["cnt"].as!long;

        stmt = conn.prepare("SELECT COUNT(*) as cnt FROM code_examples");
        stats.exampleCount = stmt.execute().front["cnt"].as!long;

        return stats;
    }

    void storePackageEmbedding(long packageId, float[] embedding)
    {
        storeEmbedding("vec_packages", "package_id", packageId, embedding);
    }

    void storeFunctionEmbedding(long functionId, float[] embedding)
    {
        storeEmbedding("vec_functions", "function_id", functionId, embedding);
    }

    void storeTypeEmbedding(long typeId, float[] embedding)
    {
        storeEmbedding("vec_types", "type_id", typeId, embedding);
    }

    void storeExampleEmbedding(long exampleId, float[] embedding)
    {
        storeEmbedding("vec_examples", "example_id", exampleId, embedding);
    }

    private void storeEmbedding(string table, string idColumn, long id, float[] embedding)
    {
        if (!conn.hasVectorSupport() || embedding.length == 0)
            return;

        string blobStr = "X'";
        foreach (i, f; embedding)
        {
            uint bits = *cast(uint*)&f;
            ubyte[4] bytes = (cast(ubyte*)&bits)[0 .. 4];
            foreach (b; bytes)
                blobStr ~= format("%02x", b);
        }
        blobStr ~= "'";

        auto deleteStmt = conn.prepare(format("DELETE FROM %s WHERE %s = ?", table, idColumn));
        deleteStmt.bind(1, id);
        deleteStmt.execute();
        
        string sql = format("INSERT INTO %s (%s, embedding) VALUES (?, %s)",
                           table, idColumn, blobStr);

        auto stmt = conn.prepare(sql);
        stmt.bind(1, id);
        stmt.execute();
    }

    void updateFtsFunction(long functionId, long packageId, string name, string fqn,
                           string signature, string docComment, string[] parameters,
                           string[] examples, string packageName)
    {
        auto stmt = conn.prepare("
            INSERT INTO fts_functions (function_id, name, fully_qualified_name, signature,
                                       doc_comment, parameters, examples, package_name)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ");
        stmt.bind(1, functionId);
        stmt.bind(2, name);
        stmt.bind(3, fqn);
        stmt.bind(4, signature);
        stmt.bind(5, docComment);
        stmt.bind(6, parameters.join(";"));
        stmt.bind(7, examples.join("\n---\n"));
        stmt.bind(8, packageName);
        stmt.execute();
    }

    void updateFtsType(long typeId, long packageId, string name, string fqn,
                       string kind, string docComment, string packageName)
    {
        auto stmt = conn.prepare("
            INSERT INTO fts_types (type_id, name, fully_qualified_name, kind,
                                   doc_comment, package_name)
            VALUES (?, ?, ?, ?, ?, ?)
        ");
        stmt.bind(1, typeId);
        stmt.bind(2, name);
        stmt.bind(3, fqn);
        stmt.bind(4, kind);
        stmt.bind(5, docComment);
        stmt.bind(6, packageName);
        stmt.execute();
    }

    void updateFtsExample(long exampleId, string code, string description,
                          string functionName, string packageName)
    {
        auto stmt = conn.prepare("
            INSERT INTO fts_examples (example_id, code, description,
                                      function_name, package_name)
            VALUES (?, ?, ?, ?, ?)
        ");
        stmt.bind(1, exampleId);
        stmt.bind(2, code);
        stmt.bind(3, description);
        stmt.bind(4, functionName);
        stmt.bind(5, packageName);
        stmt.execute();
    }

    string[] getAllDocumentTexts()
    {
        string[] texts;

        auto pkgStmt = conn.prepare("SELECT name, description, tags FROM packages");
        foreach (row; pkgStmt.execute())
        {
            string text = row["name"].as!string;
            if (isNotNull(row["description"]))
                text ~= " " ~ row["description"].as!string;
            if (isNotNull(row["tags"]))
                text ~= " " ~ row["tags"].as!string;
            texts ~= text;
        }

        auto exStmt = conn.prepare("SELECT code, description FROM code_examples");
        foreach (row; exStmt.execute())
        {
            string text = row["code"].as!string;
            if (isNotNull(row["description"]))
                text ~= " " ~ row["description"].as!string;
            texts ~= text;
        }

        return texts;
    }
}