/**
 * SQLite database connection management with optional sqlite-vec extension support.
 *
 * Provides a wrapper around d2sqlite3's `Database` with connection configuration
 * (WAL mode, foreign keys, cache tuning), automatic sqlite-vec extension detection
 * and loading, and a RAII `Transaction` helper for safe transaction management.
 */
module storage.connection;

import d2sqlite3;
import std.stdio : stderr;
import std.exception;
import std.file;
import std.path;
import std.process : environment;
import std.logger : info, error, LogLevel, globalLogLevel;

/**
 * Manages a SQLite database connection with optimized pragmas and optional vector extension.
 *
 * On construction, creates the database directory if needed, opens the database,
 * configures performance-oriented pragmas (WAL, cache size, etc.), and attempts
 * to load the sqlite-vec extension for vector similarity search support.
 */
class DBConnection {
	private Database db;
	private string dbPath;
	private string vecExtensionPath;
	private bool vectorSupport = false;

	/**
	 * Opens a database connection at the given path.
	 *
	 * Params:
	 *     dbPath = Path to the SQLite database file. Parent directories are created if needed.
	 *     vecExtensionPath = Optional explicit path to the sqlite-vec shared library.
	 *                        If null, auto-detection is attempted.
	 */
	this(string dbPath, string vecExtensionPath = null)
	{
		this.dbPath = dbPath;

		if(vecExtensionPath is null) {
			vecExtensionPath = detectVecExtension();
		}
		this.vecExtensionPath = vecExtensionPath;

		auto dir = dirName(dbPath);
		if(dir.length > 0 && !exists(dir)) {
			mkdirRecurse(dir);
		}

		this.db = Database(dbPath);

		db.execute("PRAGMA foreign_keys = ON");
		db.execute("PRAGMA journal_mode = WAL");
		db.execute("PRAGMA synchronous = NORMAL");
		db.execute("PRAGMA cache_size = -64000");
		db.execute("PRAGMA temp_store = MEMORY");

		if(vecExtensionPath !is null && vecExtensionPath.length > 0 && exists(vecExtensionPath)) {
			loadVectorExtension();
		}
	}

	private string detectVecExtension()
	{
		auto envPath = environment.get("SQLITE_VEC_PATH");
		if(envPath.length > 0) {
			return envPath;
		}

		version(linux) {
			string[] candidates = [
				"data/models/vec0.so", "/usr/local/lib/vec0.so",
				"/usr/lib/vec0.so", "/usr/lib/x86_64-linux-gnu/vec0.so"
			];
		} else version(OSX) {
			string[] candidates = [
				"data/models/vec0.dylib", "/usr/local/lib/vec0.dylib",
				"/usr/lib/vec0.dylib"
			];
		} else version(Windows) {
			string[] candidates = [
				"data/models/vec0.dll", "C:\\Windows\\System32\\vec0.dll"
			];
		} else {
			return null;
		}

		foreach(candidate; candidates) {
			if(exists(candidate)) {
				return candidate;
			}
		}

		return null;
	}

	private void loadVectorExtension()
	{
		try {
			db.enableLoadExtensions(true);
			db.loadExtension(vecExtensionPath, "sqlite3_vec_init");
			vectorSupport = true;
			info("Loaded sqlite-vec extension: " ~ vecExtensionPath);
		} catch(Exception e) {
			error("Failed to load sqlite-vec: " ~ e.msg);
			error("  Extension path: " ~ vecExtensionPath);
			error("  Vector search will be disabled");
		}
	}

	/** Returns whether the sqlite-vec extension was loaded successfully. */
	bool hasVectorSupport()
	{
		return vectorSupport;
	}

	/** Returns the underlying d2sqlite3 `Database` handle for direct access. */
	@property Database database()
	{
		return db;
	}

	/**
	 * Executes a SQL statement that does not return results.
	 *
	 * Params:
	 *     sql = The SQL statement to execute.
	 *
	 * Throws: `SqliteException` if the SQL is invalid or execution fails.
	 */
	void execute(string sql)
	{
		try {
			db.execute(sql);
		} catch(SqliteException e) {
			error("SQL Error in: " ~ sql);
			throw e;
		}
	}

	/**
	 * Prepares a SQL statement for parameterized execution.
	 *
	 * Params:
	 *     sql = The SQL statement with `?` parameter placeholders.
	 *
	 * Returns: A prepared `Statement` that can be bound and executed.
	 *
	 * Throws: `SqliteException` if the SQL is invalid.
	 */
	Statement prepare(string sql)
	{
		try {
			return db.prepare(sql);
		} catch(SqliteException e) {
			error("SQL Error preparing: " ~ sql);
			throw e;
		}
	}

	/** Begins an explicit database transaction. */
	void beginTransaction()
	{
		execute("BEGIN TRANSACTION");
	}

	/** Commits the current transaction. */
	void commit()
	{
		execute("COMMIT");
	}

	/** Rolls back the current transaction, undoing all uncommitted changes. */
	void rollback()
	{
		execute("ROLLBACK");
	}

	/** Returns the row ID of the most recently inserted row. */
	long lastInsertRowid()
	{
		return db.lastInsertRowid;
	}

	/** Returns the total number of rows modified by all SQL statements since the connection opened. */
	int totalChanges()
	{
		return db.totalChanges;
	}

	/** Closes the database connection, releasing all resources. */
	void close()
	{
		db.close();
	}
}

/**
 * RAII wrapper for SQLite transactions.
 *
 * Automatically rolls back the transaction on scope exit if `commit`
 * has not been called, ensuring no partial changes persist after errors.
 */
struct Transaction {
	private DBConnection conn;
	private bool committed;

	@disable this();
	@disable this(this);

	/**
	 * Creates a transaction and immediately begins it.
	 *
	 * Params:
	 *     conn = The database connection to manage the transaction on.
	 */
	this(DBConnection conn)
	{
		this.conn = conn;
		this.committed = false;
		conn.beginTransaction();
	}

	/** Commits the transaction, preventing automatic rollback on destruction. */
	void commit()
	{
		conn.commit();
		committed = true;
	}

	~this()
	{
		if(!committed && conn !is null) {
			try {
				conn.rollback();
			} catch(Exception e) {
				error("Error rolling back transaction: " ~ e.msg);
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

/// Test basic connection with :memory: database
unittest {
	import std.format : format;

	auto conn = new DBConnection(":memory:", "");
	assert(conn !is null, "Connection should be created for :memory: database");

	// hasVectorSupport should be false since we passed empty extension path
	assert(!conn.hasVectorSupport(),
			"In-memory DB should not have vector support with empty extension path");

	conn.close();
}

/// Test database property accessor
unittest {
	auto conn = new DBConnection(":memory:", "");
	scope(exit)
		conn.close();

	auto db = conn.database;
	// Verify we can use the raw database handle
	db.execute("SELECT 1");
}

/// Test execute with valid SQL
unittest {
	auto conn = new DBConnection(":memory:", "");
	scope(exit)
		conn.close();

	conn.execute("CREATE TABLE test_exec (id INTEGER PRIMARY KEY, name TEXT)");
	conn.execute("INSERT INTO test_exec (name) VALUES ('hello')");

	auto stmt = conn.prepare("SELECT COUNT(*) FROM test_exec");
	auto result = stmt.execute();
	foreach(row; result) {
		assert(row[0].as!int == 1, "Should have inserted 1 row");
	}
}

/// Test execute error handling — invalid SQL triggers SqliteException
unittest {
	import std.format : format;
	import d2sqlite3 : SqliteException;

	auto savedLevel = globalLogLevel;
	globalLogLevel = LogLevel.off;
	scope(exit)
		globalLogLevel = savedLevel;

	auto conn = new DBConnection(":memory:", "");
	scope(exit)
		conn.close();

	bool caughtException = false;
	try {
		conn.execute("INVALID SQL STATEMENT HERE !!!");
	} catch(SqliteException e) {
		caughtException = true;
	}
	assert(caughtException, "execute() should throw SqliteException for invalid SQL");
}

/// Test prepare error handling — invalid SQL triggers SqliteException
unittest {
	import d2sqlite3 : SqliteException;

	auto savedLevel = globalLogLevel;
	globalLogLevel = LogLevel.off;
	scope(exit)
		globalLogLevel = savedLevel;

	auto conn = new DBConnection(":memory:", "");
	scope(exit)
		conn.close();

	bool caughtException = false;
	try {
		conn.prepare("SELECT * FROM nonexistent_table_xyz");
	} catch(SqliteException e) {
		caughtException = true;
	}
	assert(caughtException, "prepare() should throw SqliteException for invalid SQL");
}

/// Test prepare with parameters
unittest {
	import std.format : format;

	auto conn = new DBConnection(":memory:", "");
	scope(exit)
		conn.close();

	conn.execute("CREATE TABLE test_params (id INTEGER PRIMARY KEY, value TEXT)");

	auto insertStmt = conn.prepare("INSERT INTO test_params (value) VALUES (?)");
	insertStmt.bind(1, "test_value");
	insertStmt.execute();

	auto selectStmt = conn.prepare("SELECT value FROM test_params WHERE id = ?");
	selectStmt.bind(1, 1);
	auto result = selectStmt.execute();
	foreach(row; result) {
		assert(row[0].as!string == "test_value",
				format("Expected 'test_value', got '%s'", row[0].as!string));
	}
}

/// Test beginTransaction, commit lifecycle
unittest {
	auto conn = new DBConnection(":memory:", "");
	scope(exit)
		conn.close();

	conn.execute("CREATE TABLE test_txn (id INTEGER PRIMARY KEY, val INTEGER)");

	conn.beginTransaction();
	conn.execute("INSERT INTO test_txn (val) VALUES (42)");
	conn.commit();

	// Verify data persisted after commit
	auto stmt = conn.prepare("SELECT val FROM test_txn");
	auto result = stmt.execute();
	bool found = false;
	foreach(row; result) {
		assert(row[0].as!int == 42, "Committed value should be 42");
		found = true;
	}
	assert(found, "Should find the committed row");
}

/// Test beginTransaction, rollback lifecycle
unittest {
	auto conn = new DBConnection(":memory:", "");
	scope(exit)
		conn.close();

	conn.execute("CREATE TABLE test_rb (id INTEGER PRIMARY KEY, val INTEGER)");

	conn.beginTransaction();
	conn.execute("INSERT INTO test_rb (val) VALUES (99)");
	conn.rollback();

	// Verify data was rolled back
	auto stmt = conn.prepare("SELECT COUNT(*) FROM test_rb");
	auto result = stmt.execute();
	foreach(row; result) {
		assert(row[0].as!int == 0, "Rolled-back insert should leave table empty");
	}
}

/// Test lastInsertRowid
unittest {
	import std.format : format;

	auto conn = new DBConnection(":memory:", "");
	scope(exit)
		conn.close();

	conn.execute("CREATE TABLE test_rowid (id INTEGER PRIMARY KEY, name TEXT)");
	conn.execute("INSERT INTO test_rowid (name) VALUES ('first')");

	auto rowid = conn.lastInsertRowid();
	assert(rowid == 1, format("Expected rowid 1, got %d", rowid));

	conn.execute("INSERT INTO test_rowid (name) VALUES ('second')");
	auto rowid2 = conn.lastInsertRowid();
	assert(rowid2 == 2, format("Expected rowid 2, got %d", rowid2));
}

/// Test totalChanges
unittest {
	import std.format : format;

	auto conn = new DBConnection(":memory:", "");
	scope(exit)
		conn.close();

	conn.execute("CREATE TABLE test_changes (id INTEGER PRIMARY KEY, val INTEGER)");
	conn.execute("INSERT INTO test_changes (val) VALUES (1)");
	conn.execute("INSERT INTO test_changes (val) VALUES (2)");
	conn.execute("INSERT INTO test_changes (val) VALUES (3)");

	auto changes = conn.totalChanges();
	// totalChanges counts all row modifications since connection opened,
	// including the CREATE TABLE (0 rows) + 3 INSERTs = at least 3
	assert(changes >= 3, format("Expected at least 3 total changes, got %d", changes));
}

/// Test Transaction struct — commit path
unittest {
	auto conn = new DBConnection(":memory:", "");
	scope(exit)
		conn.close();

	conn.execute("CREATE TABLE test_txn_struct (id INTEGER PRIMARY KEY, val TEXT)");

	{
		auto txn = Transaction(conn);
		conn.execute("INSERT INTO test_txn_struct (val) VALUES ('committed')");
		txn.commit();
	}

	// Data should persist after committed Transaction goes out of scope
	auto stmt = conn.prepare("SELECT val FROM test_txn_struct");
	auto result = stmt.execute();
	bool found = false;
	foreach(row; result) {
		assert(row[0].as!string == "committed", "Transaction commit should persist data");
		found = true;
	}
	assert(found, "Should find the committed row");
}

/// Test Transaction struct — automatic rollback on scope exit (no commit)
unittest {
	auto conn = new DBConnection(":memory:", "");
	scope(exit)
		conn.close();

	conn.execute("CREATE TABLE test_txn_auto_rb (id INTEGER PRIMARY KEY, val TEXT)");

	{
		auto txn = Transaction(conn);
		conn.execute("INSERT INTO test_txn_auto_rb (val) VALUES ('should_vanish')");
		// txn goes out of scope without commit → auto rollback
	}

	// Data should be rolled back
	auto stmt = conn.prepare("SELECT COUNT(*) FROM test_txn_auto_rb");
	auto result = stmt.execute();
	foreach(row; result) {
		assert(row[0].as!int == 0,
				"Uncommitted Transaction should auto-rollback, leaving table empty");
	}
}
