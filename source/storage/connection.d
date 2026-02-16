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
import utils.logging : logInfo, logError;

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
			logInfo("Loaded sqlite-vec extension: " ~ vecExtensionPath);
		} catch(Exception e) {
			logError("Failed to load sqlite-vec: " ~ e.msg);
			logError("  Extension path: " ~ vecExtensionPath);
			logError("  Vector search will be disabled");
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
			logError("SQL Error in: " ~ sql);
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
			logError("SQL Error preparing: " ~ sql);
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
				logError("Error rolling back transaction: " ~ e.msg);
			}
		}
	}
}
