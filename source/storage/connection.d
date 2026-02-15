module storage.connection;

import d2sqlite3;
import std.stdio;
import std.exception;
import std.file;
import std.path;
import std.process : environment;

class DBConnection
{
    private Database db;
    private string dbPath;
    private string vecExtensionPath;
    private bool vectorSupport = false;

    this(string dbPath, string vecExtensionPath = null)
    {
        this.dbPath = dbPath;

        if (vecExtensionPath is null)
        {
            vecExtensionPath = detectVecExtension();
        }
        this.vecExtensionPath = vecExtensionPath;

        auto dir = dirName(dbPath);
        if (dir.length > 0 && !exists(dir))
        {
            mkdirRecurse(dir);
        }

        this.db = Database(dbPath);

        db.execute("PRAGMA foreign_keys = ON");
        db.execute("PRAGMA journal_mode = WAL");
        db.execute("PRAGMA synchronous = NORMAL");
        db.execute("PRAGMA cache_size = -64000");
        db.execute("PRAGMA temp_store = MEMORY");

        if (vecExtensionPath !is null && vecExtensionPath.length > 0 && exists(vecExtensionPath))
        {
            loadVectorExtension();
        }
    }

    private string detectVecExtension()
    {
        auto envPath = environment.get("SQLITE_VEC_PATH");
        if (envPath.length > 0)
        {
            return envPath;
        }

        version (linux)
        {
            string[] candidates = [
                "data/models/vec0.so",
                "/usr/local/lib/vec0.so",
                "/usr/lib/vec0.so",
                "/usr/lib/x86_64-linux-gnu/vec0.so"
            ];
        }
        else version (OSX)
        {
            string[] candidates = [
                "data/models/vec0.dylib",
                "/usr/local/lib/vec0.dylib",
                "/usr/lib/vec0.dylib"
            ];
        }
        else version (Windows)
        {
            string[] candidates = [
                "data/models/vec0.dll",
                "C:\\Windows\\System32\\vec0.dll"
            ];
        }
        else
        {
            return null;
        }

        foreach (candidate; candidates)
        {
            if (exists(candidate))
            {
                return candidate;
            }
        }

        return null;
    }

    private void loadVectorExtension()
    {
        try
        {
            db.enableLoadExtensions(true);
            db.loadExtension(vecExtensionPath, "sqlite3_vec_init");
            vectorSupport = true;
            writeln("Loaded sqlite-vec extension: ", vecExtensionPath);
        }
        catch (Exception e)
        {
            stderr.writeln("Warning: Failed to load sqlite-vec: ", e.msg);
            stderr.writeln("  Extension path: ", vecExtensionPath);
            stderr.writeln("  Vector search will be disabled");
        }
    }

    bool hasVectorSupport()
    {
        return vectorSupport;
    }

    @property Database database()
    {
        return db;
    }

    void execute(string sql)
    {
        try
        {
            db.execute(sql);
        }
        catch (SqliteException e)
        {
            stderr.writefln("SQL Error in: %s", sql);
            throw e;
        }
    }

    Statement prepare(string sql)
    {
        try
        {
            return db.prepare(sql);
        }
        catch (SqliteException e)
        {
            stderr.writefln("SQL Error preparing: %s", sql);
            throw e;
        }
    }

    void beginTransaction()
    {
        execute("BEGIN TRANSACTION");
    }

    void commit()
    {
        execute("COMMIT");
    }

    void rollback()
    {
        execute("ROLLBACK");
    }

    long lastInsertRowid()
    {
        return db.lastInsertRowid;
    }

    int totalChanges()
    {
        return db.totalChanges;
    }

    void close()
    {
        db.close();
    }
}

struct Transaction
{
    private DBConnection conn;
    private bool committed;

    @disable this();
    @disable this(this);

    this(DBConnection conn)
    {
        this.conn = conn;
        this.committed = false;
        conn.beginTransaction();
    }

    void commit()
    {
        conn.commit();
        committed = true;
    }

    ~this()
    {
        if (!committed && conn !is null)
        {
            try
            {
                conn.rollback();
            }
            catch (Exception e)
            {
                stderr.writeln("Error rolling back transaction: ", e.msg);
            }
        }
    }
}