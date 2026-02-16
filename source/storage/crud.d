/**
 * CRUD operations for the D package documentation database.
 *
 * Provides insert, query, and full-text-search index operations for packages,
 * modules, functions, types, code examples, and their vector embeddings.
 */
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

/**
 * Database access layer for all entity CRUD operations.
 *
 * Wraps a `DBConnection` and provides typed insert/query methods for every
 * entity in the schema: packages, modules, functions, types, code examples,
 * embeddings, and full-text-search indexes.
 */
class CRUDOperations {
	private DBConnection conn;

	/**
	 * Constructs the CRUD operations layer.
	 *
	 * Params:
	 *     conn = The database connection to execute queries on.
	 */
	this(DBConnection conn)
	{
		this.conn = conn;
	}

	/**
	 * Inserts or replaces a package record in the database.
	 *
	 * Params:
	 *     pkg = The package metadata to store.
	 *
	 * Returns: The row ID of the inserted or replaced package.
	 */
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

	/**
	 * Retrieves a package by name.
	 *
	 * Params:
	 *     name = The unique package name.
	 *
	 * Returns: The deserialized `PackageMetadata`.
	 *
	 * Throws: `Exception` if the package is not found.
	 */
	PackageMetadata getPackage(string name)
	{
		auto stmt = conn.prepare("SELECT * FROM packages WHERE name = ?");
		stmt.bind(1, name);
		auto result = stmt.execute();

		if(result.empty) {
			throw new Exception("Package not found: " ~ name);
		}

		return parsePackageRow(result.front);
	}

	/**
	 * Deserializes a database row into a `PackageMetadata` struct.
	 *
	 * Params:
	 *     row = A database row from the packages table.
	 *
	 * Returns: A populated `PackageMetadata`.
	 */
	PackageMetadata parsePackageRow(Row row)
	{
		PackageMetadata pkg;
		pkg.name = row["name"].as!string;
		pkg.version_ = row["version"].as!string;
		if(isNotNull(row["description"]))
			pkg.description = row["description"].as!string;
		if(isNotNull(row["repository"]))
			pkg.repository = row["repository"].as!string;
		if(isNotNull(row["homepage"]))
			pkg.homepage = row["homepage"].as!string;
		if(isNotNull(row["license"]))
			pkg.license = row["license"].as!string;
		if(isNotNull(row["authors"])) {
			auto authorsStr = row["authors"].as!string;
			if(authorsStr.length > 0)
				pkg.authors = authorsStr.split(",");
		}
		if(isNotNull(row["tags"])) {
			auto tagsStr = row["tags"].as!string;
			if(tagsStr.length > 0)
				pkg.tags = tagsStr.split(",");
		}
		return pkg;
	}

	/**
	 * Looks up a package ID by name.
	 *
	 * Params:
	 *     name = The package name.
	 *
	 * Returns: The package row ID, or -1 if not found.
	 */
	long getPackageId(string name)
	{
		auto stmt = conn.prepare("SELECT id FROM packages WHERE name = ?");
		stmt.bind(1, name);
		auto result = stmt.execute();

		if(result.empty) {
			return -1;
		}

		return result.front["id"].as!long;
	}

	/** Returns an alphabetically sorted list of all package names in the database. */
	string[] getAllPackageNames()
	{
		auto stmt = conn.prepare("SELECT name FROM packages ORDER BY name");
		auto result = stmt.execute();

		string[] names;
		foreach(row; result) {
			names ~= row["name"].as!string;
		}
		return names;
	}

	/**
	 * Inserts or replaces a module record under a package.
	 *
	 * Params:
	 *     packageId = The parent package row ID.
	 *     mod = The module documentation to store.
	 *
	 * Returns: The row ID of the inserted module.
	 */
	long insertModule(long packageId, ModuleDoc mod)
	{
		auto stmt = conn.prepare("
            INSERT OR REPLACE INTO modules (package_id, name, full_path, doc_comment)
            VALUES (?, ?, ?, ?)
        ");

		stmt.bind(1, packageId);
		auto parts = mod.name.split(".");
		stmt.bind(2, parts.length > 0 ? parts[$ - 1] : mod.name);
		stmt.bind(3, mod.name);
		stmt.bind(4, mod.docComment);
		stmt.execute();

		return conn.lastInsertRowid();
	}

	/**
	 * Looks up a module ID by its fully qualified path.
	 *
	 * Params:
	 *     fullPath = The dot-separated module path (e.g. "std.algorithm").
	 *
	 * Returns: The module row ID, or -1 if not found.
	 */
	long getModuleId(string fullPath)
	{
		auto stmt = conn.prepare("SELECT id FROM modules WHERE full_path = ?");
		stmt.bind(1, fullPath);
		auto result = stmt.execute();

		if(result.empty) {
			return -1;
		}

		return result.front["id"].as!long;
	}

	/**
	 * Inserts or replaces a function record under a module.
	 *
	 * Stores the function's signature, documentation, parameters, examples,
	 * and performance attributes (nogc, nothrow, pure, safe).
	 *
	 * Params:
	 *     moduleId = The parent module row ID.
	 *     func = The function documentation to store.
	 *
	 * Returns: The row ID of the inserted function.
	 */
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

	/**
	 * Looks up a function ID by its fully qualified name.
	 *
	 * Params:
	 *     fqn = The fully qualified function name.
	 *
	 * Returns: The function row ID, or -1 if not found.
	 */
	long getFunctionId(string fqn)
	{
		auto stmt = conn.prepare("SELECT id FROM functions WHERE fully_qualified_name = ?");
		stmt.bind(1, fqn);
		auto result = stmt.execute();

		if(result.empty) {
			return -1;
		}

		return result.front["id"].as!long;
	}

	/**
	 * Retrieves a function by its row ID, including parent module and package names.
	 *
	 * Params:
	 *     id = The function row ID.
	 *
	 * Returns: A populated `FunctionDoc`.
	 *
	 * Throws: `Exception` if the function is not found.
	 */
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

		if(result.empty) {
			throw new Exception("Function not found: " ~ id.text);
		}

		return parseFunctionRow(result.front);
	}

	/**
	 * Deserializes a database row into a `FunctionDoc` struct.
	 *
	 * Params:
	 *     row = A database row from a functions query with joined module/package columns.
	 *
	 * Returns: A populated `FunctionDoc`.
	 */
	FunctionDoc parseFunctionRow(Row row)
	{
		FunctionDoc func;
		func.name = row["name"].as!string;
		func.fullyQualifiedName = row["fully_qualified_name"].as!string;
		func.moduleName = row["module_name"].as!string;
		func.packageName = row["package_name"].as!string;
		if(isNotNull(row["signature"]))
			func.signature = row["signature"].as!string;
		if(isNotNull(row["return_type"]))
			func.returnType = row["return_type"].as!string;
		if(isNotNull(row["doc_comment"]))
			func.docComment = row["doc_comment"].as!string;
		if(isNotNull(row["parameters"])) {
			auto paramsStr = row["parameters"].as!string;
			if(paramsStr.length > 0)
				func.parameters = paramsStr.split(";");
		}
		if(isNotNull(row["examples"])) {
			auto exStr = row["examples"].as!string;
			if(exStr.length > 0)
				func.examples = exStr.split("\n---\n");
		}
		func.isTemplate = row["is_template"].as!int == 1;
		if(isNotNull(row["time_complexity"]))
			func.performance.timeComplexity = row["time_complexity"].as!string;
		if(isNotNull(row["space_complexity"]))
			func.performance.spaceComplexity = row["space_complexity"].as!string;
		func.performance.isNogc = row["is_nogc"].as!int == 1;
		func.performance.isNothrow = row["is_nothrow"].as!int == 1;
		func.performance.isPure = row["is_pure"].as!int == 1;
		func.performance.isSafe = row["is_safe"].as!int == 1;
		return func;
	}

	/**
	 * Inserts or replaces a type record under a module.
	 *
	 * Params:
	 *     moduleId = The parent module row ID.
	 *     type = The type documentation to store.
	 *
	 * Returns: The row ID of the inserted type.
	 */
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

	/**
	 * Looks up a type ID by its fully qualified name.
	 *
	 * Params:
	 *     fqn = The fully qualified type name.
	 *
	 * Returns: The type row ID, or -1 if not found.
	 */
	long getTypeId(string fqn)
	{
		auto stmt = conn.prepare("SELECT id FROM types WHERE fully_qualified_name = ?");
		stmt.bind(1, fqn);
		auto result = stmt.execute();

		if(result.empty) {
			return -1;
		}

		return result.front["id"].as!long;
	}

	/**
	 * Inserts a code example linked to a function, type, or package.
	 *
	 * Params:
	 *     example = The code example to store; its functionId, typeId, or
	 *               packageId determines the parent entity.
	 *
	 * Returns: The row ID of the inserted example.
	 */
	long insertCodeExample(CodeExample example)
	{
		auto stmt = conn.prepare("
            INSERT INTO code_examples
            (function_id, type_id, package_id, code, description, 
             is_unittest, is_runnable, required_imports)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ");

		if(example.functionId > 0)
			stmt.bind(1, example.functionId);
		else
			stmt.bind(1, null);

		if(example.typeId > 0)
			stmt.bind(2, example.typeId);
		else
			stmt.bind(2, null);

		if(example.packageId > 0)
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

	/**
	 * Retrieves runnable code examples associated with a function.
	 *
	 * Params:
	 *     functionId = The function row ID.
	 *
	 * Returns: An array of `CodeExample` structs, with unittests ordered first.
	 */
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
		foreach(row; result) {
			examples ~= parseCodeExampleRow(row);
		}

		return examples;
	}

	/**
	 * Deserializes a database row into a `CodeExample` struct.
	 *
	 * Params:
	 *     row = A database row from the code_examples table.
	 *
	 * Returns: A populated `CodeExample`.
	 */
	CodeExample parseCodeExampleRow(Row row)
	{
		CodeExample ex;
		if(isNotNull(row["function_id"]))
			ex.functionId = row["function_id"].as!long;
		if(isNotNull(row["type_id"]))
			ex.typeId = row["type_id"].as!long;
		if(isNotNull(row["package_id"]))
			ex.packageId = row["package_id"].as!long;
		ex.code = row["code"].as!string;
		if(isNotNull(row["description"]))
			ex.description = row["description"].as!string;
		ex.isUnittest = row["is_unittest"].as!int == 1;
		ex.isRunnable = row["is_runnable"].as!int == 1;
		if(isNotNull(row["required_imports"])) {
			auto importsStr = row["required_imports"].as!string;
			if(importsStr.length > 0)
				ex.requiredImports = importsStr.split(",");
		}
		return ex;
	}

	/** Aggregate row counts for each entity table in the database. */
	struct DBStats {
		long packageCount; /** Number of stored packages. */
		long moduleCount; /** Number of stored modules. */
		long functionCount; /** Number of stored functions. */
		long typeCount; /** Number of stored types. */
		long exampleCount; /** Number of stored code examples. */
	}

	/** Queries the database and returns row counts for all entity tables. */
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

	/**
	 * Stores a vector embedding for a package.
	 *
	 * Params:
	 *     packageId = The package row ID.
	 *     embedding = The float vector to store.
	 */
	void storePackageEmbedding(long packageId, float[] embedding)
	{
		storeEmbedding("vec_packages", "package_id", packageId, embedding);
	}

	/**
	 * Stores a vector embedding for a function.
	 *
	 * Params:
	 *     functionId = The function row ID.
	 *     embedding = The float vector to store.
	 */
	void storeFunctionEmbedding(long functionId, float[] embedding)
	{
		storeEmbedding("vec_functions", "function_id", functionId, embedding);
	}

	/**
	 * Stores a vector embedding for a type.
	 *
	 * Params:
	 *     typeId = The type row ID.
	 *     embedding = The float vector to store.
	 */
	void storeTypeEmbedding(long typeId, float[] embedding)
	{
		storeEmbedding("vec_types", "type_id", typeId, embedding);
	}

	/**
	 * Stores a vector embedding for a code example.
	 *
	 * Params:
	 *     exampleId = The code example row ID.
	 *     embedding = The float vector to store.
	 */
	void storeExampleEmbedding(long exampleId, float[] embedding)
	{
		storeEmbedding("vec_examples", "example_id", exampleId, embedding);
	}

	private void storeEmbedding(string table, string idColumn, long id, float[] embedding)
	{
		if(!conn.hasVectorSupport() || embedding.length == 0)
			return;

		string blobStr = "X'";
		foreach(i, f; embedding) {
			uint bits = *cast(uint*)&f;
			ubyte[4] bytes = (cast(ubyte*)&bits)[0 .. 4];
			foreach(b; bytes)
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

	/**
	 * Updates the FTS5 full-text index for a function.
	 *
	 * Params:
	 *     functionId = The function row ID.
	 *     packageId = The parent package row ID.
	 *     name = The function name.
	 *     fqn = The fully qualified name.
	 *     signature = The function signature.
	 *     docComment = The documentation comment text.
	 *     parameters = The parameter list.
	 *     examples = Code examples associated with the function.
	 *     packageName = The parent package name.
	 */
	void updateFtsFunction(long functionId, long packageId, string name, string fqn, string signature,
			string docComment, string[] parameters, string[] examples, string packageName)
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

	/**
	 * Updates the FTS5 full-text index for a type.
	 *
	 * Params:
	 *     typeId = The type row ID.
	 *     packageId = The parent package row ID.
	 *     name = The type name.
	 *     fqn = The fully qualified name.
	 *     kind = The type kind (class, struct, enum, interface).
	 *     docComment = The documentation comment text.
	 *     packageName = The parent package name.
	 */
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

	/**
	 * Updates the FTS5 full-text index for a code example.
	 *
	 * Params:
	 *     exampleId = The code example row ID.
	 *     code = The example source code.
	 *     description = Human-readable description of the example.
	 *     functionName = The name of the associated function, if any.
	 *     packageName = The parent package name.
	 */
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

	/**
	 * Retrieves all document texts from the database for embedding training.
	 *
	 * Collects text from packages (name, description, tags) and code examples
	 * (code, description) to build a training corpus for TF-IDF or other
	 * embedding models.
	 *
	 * Returns: An array of concatenated text strings, one per document.
	 */
	string[] getAllDocumentTexts()
	{
		string[] texts;

		auto pkgStmt = conn.prepare("SELECT name, description, tags FROM packages");
		foreach(row; pkgStmt.execute()) {
			string text = row["name"].as!string;
			if(isNotNull(row["description"]))
				text ~= " " ~ row["description"].as!string;
			if(isNotNull(row["tags"]))
				text ~= " " ~ row["tags"].as!string;
			texts ~= text;
		}

		auto funcStmt = conn.prepare("SELECT name, signature, doc_comment FROM functions");
		foreach(row; funcStmt.execute()) {
			string text = row["name"].as!string;
			if(isNotNull(row["signature"]))
				text ~= " " ~ row["signature"].as!string;
			if(isNotNull(row["doc_comment"]))
				text ~= " " ~ row["doc_comment"].as!string;
			texts ~= text;
		}

		auto typeStmt = conn.prepare("SELECT name, kind, doc_comment FROM types");
		foreach(row; typeStmt.execute()) {
			string text = row["name"].as!string;
			if(isNotNull(row["kind"]))
				text ~= " " ~ row["kind"].as!string;
			if(isNotNull(row["doc_comment"]))
				text ~= " " ~ row["doc_comment"].as!string;
			texts ~= text;
		}

		auto exStmt = conn.prepare("SELECT code, description FROM code_examples");
		foreach(row; exStmt.execute()) {
			string text = row["code"].as!string;
			if(isNotNull(row["description"]))
				text ~= " " ~ row["description"].as!string;
			texts ~= text;
		}

		return texts;
	}
}
