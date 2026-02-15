module storage.schema;

import storage.connection;
import std.stdio;
import std.format;

class SchemaManager {
	private DBConnection conn;
	private int vectorDimensions;

	this(DBConnection conn, int vectorDimensions = 384)
	{
		this.conn = conn;
		this.vectorDimensions = vectorDimensions;
	}

	void initializeSchema()
	{
		writeln("Initializing database schema...");

		createCoreTables();
		createRelationshipTables();
		createIngestionProgressTable();
		createFTSTables();

		if(conn.hasVectorSupport()) {
			createVectorTables();
			writeln("Vector search enabled (sqlite-vec)");
		} else {
			writeln("Vector search disabled (sqlite-vec not loaded)");
		}

		createIndexes();
		writeln("Schema initialized");
	}

	private void createCoreTables()
	{
		conn.execute("
            CREATE TABLE IF NOT EXISTS packages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT UNIQUE NOT NULL,
                version TEXT NOT NULL,
                description TEXT,
                repository TEXT,
                homepage TEXT,
                license TEXT,
                authors TEXT,
                tags TEXT,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
        ");

		conn.execute("
            CREATE TABLE IF NOT EXISTS modules (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                package_id INTEGER NOT NULL,
                name TEXT NOT NULL,
                full_path TEXT NOT NULL,
                doc_comment TEXT,
                FOREIGN KEY (package_id) REFERENCES packages(id) ON DELETE CASCADE,
                UNIQUE(package_id, full_path)
            )
        ");

		conn.execute("
            CREATE TABLE IF NOT EXISTS functions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                module_id INTEGER NOT NULL,
                name TEXT NOT NULL,
                fully_qualified_name TEXT UNIQUE NOT NULL,
                signature TEXT,
                return_type TEXT,
                doc_comment TEXT,
                parameters TEXT,
                examples TEXT,
                is_template INTEGER DEFAULT 0,
                time_complexity TEXT,
                space_complexity TEXT,
                is_nogc INTEGER DEFAULT 0,
                is_nothrow INTEGER DEFAULT 0,
                is_pure INTEGER DEFAULT 0,
                is_safe INTEGER DEFAULT 0,
                FOREIGN KEY (module_id) REFERENCES modules(id) ON DELETE CASCADE
            )
        ");

		conn.execute("
            CREATE TABLE IF NOT EXISTS types (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                module_id INTEGER NOT NULL,
                name TEXT NOT NULL,
                fully_qualified_name TEXT UNIQUE NOT NULL,
                kind TEXT NOT NULL,
                doc_comment TEXT,
                base_classes TEXT,
                interfaces TEXT,
                FOREIGN KEY (module_id) REFERENCES modules(id) ON DELETE CASCADE
            )
        ");

		conn.execute("
            CREATE TABLE IF NOT EXISTS code_examples (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                function_id INTEGER,
                type_id INTEGER,
                package_id INTEGER,
                code TEXT NOT NULL,
                description TEXT,
                is_unittest INTEGER DEFAULT 0,
                is_runnable INTEGER DEFAULT 1,
                required_imports TEXT,
                FOREIGN KEY (function_id) REFERENCES functions(id) ON DELETE CASCADE,
                FOREIGN KEY (type_id) REFERENCES types(id) ON DELETE CASCADE,
                FOREIGN KEY (package_id) REFERENCES packages(id) ON DELETE CASCADE
            )
        ");

		conn.execute("
            CREATE TABLE IF NOT EXISTS template_constraints (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                function_id INTEGER,
                type_id INTEGER,
                parameter_name TEXT NOT NULL,
                constraint_text TEXT,
                required_traits TEXT,
                FOREIGN KEY (function_id) REFERENCES functions(id) ON DELETE CASCADE,
                FOREIGN KEY (type_id) REFERENCES types(id) ON DELETE CASCADE
            )
        ");

		conn.execute("
            CREATE TABLE IF NOT EXISTS import_requirements (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                function_id INTEGER,
                type_id INTEGER,
                module_path TEXT NOT NULL,
                is_selective INTEGER DEFAULT 0,
                symbols TEXT,
                FOREIGN KEY (function_id) REFERENCES functions(id) ON DELETE CASCADE,
                FOREIGN KEY (type_id) REFERENCES types(id) ON DELETE CASCADE
            )
        ");
	}

	private void createRelationshipTables()
	{
		conn.execute("
            CREATE TABLE IF NOT EXISTS function_relationships (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                from_function_id INTEGER NOT NULL,
                to_function_id INTEGER NOT NULL,
                relationship_type TEXT NOT NULL,
                weight REAL DEFAULT 1.0,
                FOREIGN KEY (from_function_id) REFERENCES functions(id) ON DELETE CASCADE,
                FOREIGN KEY (to_function_id) REFERENCES functions(id) ON DELETE CASCADE,
                UNIQUE(from_function_id, to_function_id, relationship_type)
            )
        ");

		conn.execute("
            CREATE TABLE IF NOT EXISTS type_relationships (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                from_type_id INTEGER NOT NULL,
                to_type_id INTEGER NOT NULL,
                relationship_type TEXT NOT NULL,
                FOREIGN KEY (from_type_id) REFERENCES types(id) ON DELETE CASCADE,
                FOREIGN KEY (to_type_id) REFERENCES types(id) ON DELETE CASCADE,
                UNIQUE(from_type_id, to_type_id, relationship_type)
            )
        ");

		conn.execute("
            CREATE TABLE IF NOT EXISTS usage_patterns (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                pattern_name TEXT NOT NULL,
                description TEXT,
                function_ids TEXT NOT NULL,
                code_template TEXT NOT NULL,
                use_case TEXT,
                popularity INTEGER DEFAULT 0
            )
        ");
	}

	private void createIngestionProgressTable()
	{
		conn.execute("
            CREATE TABLE IF NOT EXISTS ingestion_progress (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                last_package TEXT,
                last_updated DATETIME DEFAULT CURRENT_TIMESTAMP,
                packages_processed INTEGER DEFAULT 0,
                total_packages INTEGER DEFAULT 0,
                status TEXT DEFAULT 'idle',
                error_message TEXT
            )
        ");
	}

	private void createFTSTables()
	{
		conn.execute("
            CREATE VIRTUAL TABLE IF NOT EXISTS fts_packages USING fts5(
                package_id UNINDEXED,
                name,
                description,
                authors,
                tags,
                tokenize='porter unicode61'
            )
        ");

		conn.execute("
            CREATE VIRTUAL TABLE IF NOT EXISTS fts_functions USING fts5(
                function_id UNINDEXED,
                name,
                fully_qualified_name,
                signature,
                doc_comment,
                parameters,
                examples,
                package_name,
                tokenize='porter unicode61'
            )
        ");

		conn.execute("
            CREATE VIRTUAL TABLE IF NOT EXISTS fts_types USING fts5(
                type_id UNINDEXED,
                name,
                fully_qualified_name,
                doc_comment,
                kind,
                package_name,
                tokenize='porter unicode61'
            )
        ");

		conn.execute("
            CREATE VIRTUAL TABLE IF NOT EXISTS fts_examples USING fts5(
                example_id UNINDEXED,
                code,
                description,
                function_name,
                package_name,
                tokenize='porter unicode61'
            )
        ");
	}

	private void createVectorTables()
	{
		conn.execute(format("
            CREATE VIRTUAL TABLE IF NOT EXISTS vec_packages 
            USING vec0(
                package_id INTEGER PRIMARY KEY,
                embedding float[%d] distance_metric=cosine
            )
        ", vectorDimensions));

		conn.execute(format("
            CREATE VIRTUAL TABLE IF NOT EXISTS vec_functions 
            USING vec0(
                function_id INTEGER PRIMARY KEY,
                embedding float[%d] distance_metric=cosine
            )
        ", vectorDimensions));

		conn.execute(format("
            CREATE VIRTUAL TABLE IF NOT EXISTS vec_types 
            USING vec0(
                type_id INTEGER PRIMARY KEY,
                embedding float[%d] distance_metric=cosine
            )
        ", vectorDimensions));

		conn.execute(format("
            CREATE VIRTUAL TABLE IF NOT EXISTS vec_examples 
            USING vec0(
                example_id INTEGER PRIMARY KEY,
                embedding float[%d] distance_metric=cosine
            )
        ", vectorDimensions));
	}

	private void createIndexes()
	{
		conn.execute("CREATE INDEX IF NOT EXISTS idx_modules_package ON modules(package_id)");
		conn.execute("CREATE INDEX IF NOT EXISTS idx_functions_module ON functions(module_id)");
		conn.execute("CREATE INDEX IF NOT EXISTS idx_functions_name ON functions(name)");
		conn.execute("CREATE INDEX IF NOT EXISTS idx_types_module ON types(module_id)");
		conn.execute("CREATE INDEX IF NOT EXISTS idx_types_kind ON types(kind)");
		conn.execute(
				"CREATE INDEX IF NOT EXISTS idx_func_rel_from ON function_relationships(from_function_id)");
		conn.execute(
				"CREATE INDEX IF NOT EXISTS idx_func_rel_to ON function_relationships(to_function_id)");
		conn.execute(
				"CREATE INDEX IF NOT EXISTS idx_type_rel_from ON type_relationships(from_type_id)");
		conn.execute(
				"CREATE INDEX IF NOT EXISTS idx_type_rel_to ON type_relationships(to_type_id)");
		conn.execute(
				"CREATE INDEX IF NOT EXISTS idx_examples_function ON code_examples(function_id)");
		conn.execute("CREATE INDEX IF NOT EXISTS idx_examples_type ON code_examples(type_id)");
		conn.execute(
				"CREATE INDEX IF NOT EXISTS idx_examples_package ON code_examples(package_id)");
	}

	int getSchemaVersion()
	{
		try {
			auto stmt = conn.prepare("SELECT version FROM schema_version");
			auto result = stmt.execute();
			if(!result.empty) {
				return cast(int)result.front["version"].as!long;
			}
		} catch(Exception) {
		}
		return 0;
	}

	void setSchemaVersion(int version_)
	{
		conn.execute("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER)");
		conn.execute("DELETE FROM schema_version");
		auto stmt = conn.prepare("INSERT INTO schema_version (version) VALUES (?)");
		stmt.bind(1, version_);
		stmt.execute();
	}
}
