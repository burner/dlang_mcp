import std.stdio;
import std.file;
import std.conv;
import std.algorithm;
import mcp.server : MCPServer;
import mcp.transport : StdioTransport;
import tools.dscanner : DscannerTool;
import tools.dfmt : DfmtTool;
import tools.ctags : CtagsSearchTool;
import tools.base : Tool;
import tools.package_search : PackageSearchTool;
import tools.function_search : FunctionSearchTool;
import tools.type_search : TypeSearchTool;
import tools.example_search : ExampleSearchTool;
import tools.import_tool : ImportTool;
import storage.connection : DBConnection;
import storage.schema : SchemaManager;
import storage.crud : CRUDOperations;
import storage.search : HybridSearch;
import ingestion.pipeline : IngestionPipeline;
import ingestion.pattern_miner : PatternMiner;
import embeddings.manager : EmbeddingManager;
import d2sqlite3 : SqliteType;

enum DEFAULT_DB_PATH = "data/search.db";

version (TestMode)
{
}
else
{
    void main(string[] args)
    {
        if (args.length > 1)
        {
            if (args[1] == "--init-db" || args[1] == "init-db")
            {
                initializeDatabase();
                return;
            }
            else if (args[1] == "--help" || args[1] == "-h")
            {
                printHelp();
                return;
            }
            else if (args[1] == "--stats")
            {
                printStats();
                return;
            }
            else if (args[1] == "--ingest")
            {
                handleIngest(args);
                return;
            }
            else if (args[1] == "--mine-patterns")
            {
                minePatterns();
                return;
            }
            else if (args[1] == "--test-search")
            {
                testSearch(args);
                return;
            }
            else if (args[1] == "--train-embeddings")
            {
                trainEmbeddings();
                return;
            }
        }

        runMcpServer();
    }
}

void printHelp()
{
    writeln("dlang_mcp - MCP server for D language tools with semantic search");
    writeln();
    writeln("Usage:");
    writeln("  ./bin/dlang_mcp               Run MCP server");
    writeln("  ./bin/dlang_mcp --init-db     Initialize the search database");
    writeln("  ./bin/dlang_mcp --stats       Show database statistics");
    writeln("  ./bin/dlang_mcp --ingest      Ingest all packages from code.dlang.org");
    writeln("  ./bin/dlang_mcp --ingest <pkg> Ingest a single package");
    writeln("  ./bin/dlang_mcp --ingest-status Show ingestion progress");
    writeln("  ./bin/dlang_mcp --train-embeddings Re-train embeddings");
    writeln("  ./bin/dlang_mcp --mine-patterns Mine usage patterns from indexed data");
    writeln("  ./bin/dlang_mcp --test-search <q> Test search with a query");
    writeln("  ./bin/dlang_mcp --help        Show this help");
    writeln();
    writeln("MCP Tools:");
    writeln("  dscanner       - Analyze D source code");
    writeln("  dfmt           - Format D source code");
    writeln("  ctags_search   - Search for symbol definitions");
    writeln("  search_packages - Search for D packages");
    writeln("  search_functions - Search for D functions");
    writeln("  search_types   - Search for D types (classes, structs, etc.)");
    writeln("  search_examples - Search for code examples");
    writeln("  get_imports    - Get import statements for symbols");
}

void initializeDatabase()
{
    writeln("Initializing search database...");

    auto conn = new DBConnection(DEFAULT_DB_PATH);
    auto schema = new SchemaManager(conn);

    schema.initializeSchema();

    auto crud = new CRUDOperations(conn);
    auto stats = crud.getStats();

    writeln();
    writeln("Database initialized at: ", DEFAULT_DB_PATH);
    writeln("  Packages: ", stats.packageCount);
    writeln("  Modules:  ", stats.moduleCount);
    writeln("  Functions:", stats.functionCount);
    writeln("  Types:    ", stats.typeCount);
    writeln("  Examples: ", stats.exampleCount);

    conn.close();
}

void printStats()
{
    if (!exists(DEFAULT_DB_PATH))
    {
        writeln("Database not found. Run --init-db first.");
        return;
    }

    auto conn = new DBConnection(DEFAULT_DB_PATH);
    auto crud = new CRUDOperations(conn);

    auto stats = crud.getStats();

    writeln("Database Statistics:");
    writeln("  Packages: ", stats.packageCount);
    writeln("  Modules:  ", stats.moduleCount);
    writeln("  Functions:", stats.functionCount);
    writeln("  Types:    ", stats.typeCount);
    writeln("  Examples: ", stats.exampleCount);

    conn.close();
}

void handleIngest(string[] args)
{
    if (args.length > 2 && args[2] == "--status")
    {
        printIngestStatus();
        return;
    }

    if (!exists(DEFAULT_DB_PATH))
    {
        writeln("Database not found. Initializing...");
        initializeDatabase();
    }

    auto pipeline = new IngestionPipeline(DEFAULT_DB_PATH);
    scope(exit) pipeline.close();

    if (args.length > 2 && args[2] != "--fresh" && args[2] != "--limit")
    {
        string packageName = args[2];
        pipeline.ingestPackage(packageName);
        return;
    }

    bool fresh = false;
    int limit = 0;

    for (int i = 2; i < args.length; i++)
    {
        if (args[i] == "--fresh")
        {
            fresh = true;
        }
        else if (args[i] == "--limit" && i + 1 < args.length)
        {
            limit = args[i + 1].to!int;
            i++;
        }
    }

    pipeline.ingestAll(limit, fresh);
}

void printIngestStatus()
{
    if (!exists(DEFAULT_DB_PATH))
    {
        writeln("Database not found. Run --init-db first.");
        return;
    }

    auto pipeline = new IngestionPipeline(DEFAULT_DB_PATH);
    scope(exit) pipeline.close();
    auto progress = pipeline.getProgress();

    writeln("Ingestion Progress:");
    if (progress.lastPackage.length > 0)
    {
        writeln("  Last package: ", progress.lastPackage);
        writeln("  Packages processed: ", progress.packagesProcessed);
        writeln("  Total packages: ", progress.totalPackages);
        writeln("  Status: ", progress.status);
        if (progress.errorMessage.length > 0)
        {
            writeln("  Error: ", progress.errorMessage);
        }
    }
    else
    {
        writeln("  No ingestion has been run yet.");
    }
}

void ingestSinglePackage(string packageName)
{
    if (!exists(DEFAULT_DB_PATH))
    {
        writeln("Database not found. Initializing...");
        initializeDatabase();
    }

    auto pipeline = new IngestionPipeline(DEFAULT_DB_PATH);
    scope(exit) pipeline.close();
    pipeline.ingestPackage(packageName);
}

void ingestAllPackages(bool fresh)
{
    if (!exists(DEFAULT_DB_PATH))
    {
        writeln("Database not found. Initializing...");
        initializeDatabase();
    }

    auto pipeline = new IngestionPipeline(DEFAULT_DB_PATH);
    scope(exit) pipeline.close();
    pipeline.ingestAll(0, fresh);
}

void minePatterns()
{
    if (!exists(DEFAULT_DB_PATH))
    {
        writeln("Database not found. Run --init-db first.");
        return;
    }

    auto conn = new DBConnection(DEFAULT_DB_PATH);
    scope(exit) conn.close();

    auto miner = new PatternMiner(conn);
    miner.mineAllPatterns();
}

void runMcpServer()
{
    auto server = new MCPServer();

    server.registerTool(new DscannerTool());
    server.registerTool(new DfmtTool());
    server.registerTool(new CtagsSearchTool());

    if (exists(DEFAULT_DB_PATH))
    {
        server.registerTool(new PackageSearchTool());
        server.registerTool(new FunctionSearchTool());
        server.registerTool(new TypeSearchTool());
        server.registerTool(new ExampleSearchTool());
        server.registerTool(new ImportTool());
    }

    auto transport = new StdioTransport();

    server.start(transport);
}

void testSearch(string[] args)
{
    if (!exists(DEFAULT_DB_PATH))
    {
        writeln("Database not found. Run --init-db first.");
        return;
    }

    string query = "array";
    if (args.length > 2)
        query = args[2];

    writeln("Testing search with query: ", query);

    auto conn = new DBConnection(DEFAULT_DB_PATH);
    scope(exit) conn.close();

    auto search = new HybridSearch(conn);

    writeln("\n=== Package Search ===");
    auto packages = search.searchPackages(query, 5);
    foreach (i, pkg; packages)
    {
        writeln(i + 1, ". ", pkg.name, " (rank: ", pkg.rank, ")");
    }

    writeln("\n=== Example Search (Vector) ===");
    auto examples = search.searchExamples(query, 5);
    foreach (i, ex; examples)
    {
        writeln(i + 1, ". ", ex.packageName);
        writeln("   Score: ", ex.rank);
        writeln("   Code: ", ex.signature[0 .. min(100, ex.signature.length)], "...");
        writeln();
    }
}

void trainEmbeddings()
{
    if (!exists(DEFAULT_DB_PATH))
    {
        writeln("Database not found. Run --init-db and --ingest first.");
        return;
    }

    writeln("Training TF-IDF embeddings...");

    auto conn = new DBConnection(DEFAULT_DB_PATH);
    scope(exit) conn.close();

    auto crud = new CRUDOperations(conn);
    auto texts = crud.getAllDocumentTexts();

    writeln("Found ", texts.length, " documents for training");

    auto manager = EmbeddingManager.getInstance();
    manager.trainTfIdf(texts);

    writeln("Training complete. Re-ingesting with new embeddings...");

    auto search = new HybridSearch(conn);
    
    auto pkgStmt = conn.prepare("SELECT id, name, description FROM packages");
    foreach (row; pkgStmt.execute())
    {
        long id = row["id"].as!long;
        string text = row["name"].as!string;
        if (row["description"].type != SqliteType.NULL)
            text ~= " " ~ row["description"].as!string;
        
        auto embedding = manager.embed(text);
        crud.storePackageEmbedding(id, embedding);
    }

    auto exStmt = conn.prepare("SELECT id, code, description FROM code_examples");
    int count = 0;
    foreach (row; exStmt.execute())
    {
        long id = row["id"].as!long;
        string text = row["code"].as!string;
        if (row["description"].type != SqliteType.NULL)
            text ~= " " ~ row["description"].as!string;
        
        auto embedding = manager.embed(text);
        crud.storeExampleEmbedding(id, embedding);
        count++;
        
        if (count % 1000 == 0)
            writeln("  Processed ", count, " examples...");
    }

    writeln("Re-ingested ", count, " example embeddings");
    writeln("Done!");
}