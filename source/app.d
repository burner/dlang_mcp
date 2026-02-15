import std.stdio;
import std.file;
import std.conv;
import std.algorithm;
import std.getopt : getopt, GetOptException;
import mcp.server : MCPServer;
import mcp.transport : StdioTransport;
import mcp.http_server : MCPHTTPServer;
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

struct CliOptions {
	bool initDb;
	bool stats;
	bool help;
	bool minePatterns;
	bool trainEmbeddings;
	bool ingest;
	bool ingestStatus;
	bool fresh;
	bool http;
	int limit = 0;
	ushort port = 3000;
	string host = "127.0.0.1";
	string package_;
	string testSearch;
}

version(TestMode) {
} else {
	void main(string[] args)
	{
		CliOptions opts;
		try {
			getopt(args, "init-db", "Initialize the search database",
					&opts.initDb, "stats", "Show database statistics",
					&opts.stats, "help|h", "Show this help", &opts.help,
					"mine-patterns", "Mine usage patterns", &opts.minePatterns,
					"train-embeddings", "Re-train embeddings", &opts.trainEmbeddings,
					"ingest", "Ingest packages", &opts.ingest, "ingest-status",
					"Show ingestion progress", &opts.ingestStatus,
					"fresh", "Fresh ingestion (with --ingest)", &opts.fresh, "limit",
					"Limit packages (with --ingest)", &opts.limit, "package",
					"Single package to ingest (with --ingest)", &opts.package_,
					"test-search", "Test search with query", &opts.testSearch,
					"http", "Run MCP server with HTTP transport", &opts.http,
					"port", "HTTP port (default: 3000)", &opts.port,
					"host", "HTTP host (default: 127.0.0.1)", &opts.host,);
		} catch(GetOptException e) {
			stderr.writeln("Error: ", e.msg);
			printHelp();
			return;
		}

		if(opts.help) {
			printHelp();
			return;
		}
		if(opts.initDb) {
			initializeDatabase();
			return;
		}
		if(opts.stats) {
			printStats();
			return;
		}
		if(opts.ingestStatus) {
			printIngestStatus();
			return;
		}
		if(opts.minePatterns) {
			minePatterns();
			return;
		}
		if(opts.trainEmbeddings) {
			trainEmbeddings();
			return;
		}
		if(opts.testSearch.length > 0) {
			testSearch(opts.testSearch);
			return;
		}
		if(opts.ingest) {
			handleIngest(opts);
			return;
		}

		if(opts.http)
			runHttpServer(opts.host, opts.port);
		else
			runMcpServer();
	}
}

void printHelp()
{
	writeln("dlang_mcp - MCP server for D language tools with semantic search");
	writeln();
	writeln("Usage:");
	writeln("  ./bin/dlang_mcp                        Run MCP server (stdio mode)");
	writeln("  ./bin/dlang_mcp --http                 Run MCP server (HTTP mode)");
	writeln("  ./bin/dlang_mcp --http --port=8080     Run HTTP server on port 8080");
	writeln("  ./bin/dlang_mcp --init-db              Initialize the search database");
	writeln("  ./bin/dlang_mcp --stats                Show database statistics");
	writeln("  ./bin/dlang_mcp --ingest               Ingest all packages from code.dlang.org");
	writeln("  ./bin/dlang_mcp --ingest --package=foo Ingest a single package");
	writeln("  ./bin/dlang_mcp --ingest-status        Show ingestion progress");
	writeln("  ./bin/dlang_mcp --train-embeddings     Re-train embeddings");
	writeln("  ./bin/dlang_mcp --mine-patterns        Mine usage patterns from indexed data");
	writeln("  ./bin/dlang_mcp --test-search=QUERY    Test search with a query");
	writeln("  ./bin/dlang_mcp --help                 Show this help");
	writeln();
	writeln("Ingest options:");
	writeln("  --package=NAME  Ingest single package by name");
	writeln("  --fresh          Start fresh (clear progress)");
	writeln("  --limit=N        Limit number of packages");
	writeln();
	writeln("HTTP options:");
	writeln("  --http           Enable HTTP transport instead of stdio");
	writeln("  --port=PORT      HTTP port (default: 3000)");
	writeln("  --host=HOST      HTTP host (default: 127.0.0.1)");
	writeln();
	writeln("HTTP endpoints:");
	writeln("  GET  /sse        SSE endpoint for MCP connections");
	writeln("  POST /messages   Send MCP messages (SSE mode)");
	writeln("  POST /mcp        Streamable HTTP endpoint");
	writeln("  GET  /health     Health check");
	writeln();
	writeln("MCP Tools:");
	writeln("  dscanner        - Analyze D source code");
	writeln("  dfmt            - Format D source code");
	writeln("  ctags_search    - Search for symbol definitions");
	writeln("  search_packages - Search for D packages");
	writeln("  search_functions- Search for D functions");
	writeln("  search_types    - Search for D types (classes, structs, etc.)");
	writeln("  search_examples - Search for code examples");
	writeln("  get_imports     - Get import statements for symbols");
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
	if(!exists(DEFAULT_DB_PATH)) {
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

void handleIngest(ref const CliOptions opts)
{
	if(!exists(DEFAULT_DB_PATH)) {
		writeln("Database not found. Initializing...");
		initializeDatabase();
	}

	auto pipeline = new IngestionPipeline(DEFAULT_DB_PATH);
	scope(exit)
		pipeline.close();

	if(opts.package_.length > 0) {
		pipeline.ingestPackage(opts.package_);
	} else {
		pipeline.ingestAll(opts.limit, opts.fresh);
	}
}

void printIngestStatus()
{
	if(!exists(DEFAULT_DB_PATH)) {
		writeln("Database not found. Run --init-db first.");
		return;
	}

	auto pipeline = new IngestionPipeline(DEFAULT_DB_PATH);
	scope(exit)
		pipeline.close();
	auto progress = pipeline.getProgress();

	writeln("Ingestion Progress:");
	if(progress.lastPackage.length > 0) {
		writeln("  Last package: ", progress.lastPackage);
		writeln("  Packages processed: ", progress.packagesProcessed);
		writeln("  Total packages: ", progress.totalPackages);
		writeln("  Status: ", progress.status);
		if(progress.errorMessage.length > 0) {
			writeln("  Error: ", progress.errorMessage);
		}
	} else {
		writeln("  No ingestion has been run yet.");
	}
}

void minePatterns()
{
	if(!exists(DEFAULT_DB_PATH)) {
		writeln("Database not found. Run --init-db first.");
		return;
	}

	auto conn = new DBConnection(DEFAULT_DB_PATH);
	scope(exit)
		conn.close();

	auto miner = new PatternMiner(conn);
	miner.mineAllPatterns();
}

void runMcpServer()
{
	auto server = new MCPServer();

	server.registerTool(new DscannerTool());
	server.registerTool(new DfmtTool());
	server.registerTool(new CtagsSearchTool());

	if(exists(DEFAULT_DB_PATH)) {
		server.registerTool(new PackageSearchTool());
		server.registerTool(new FunctionSearchTool());
		server.registerTool(new TypeSearchTool());
		server.registerTool(new ExampleSearchTool());
		server.registerTool(new ImportTool());
	}

	auto transport = new StdioTransport();

	server.start(transport);
}

void runHttpServer(string host, ushort port)
{
	auto server = new MCPServer();

	server.registerTool(new DscannerTool());
	server.registerTool(new DfmtTool());
	server.registerTool(new CtagsSearchTool());

	if(exists(DEFAULT_DB_PATH)) {
		server.registerTool(new PackageSearchTool());
		server.registerTool(new FunctionSearchTool());
		server.registerTool(new TypeSearchTool());
		server.registerTool(new ExampleSearchTool());
		server.registerTool(new ImportTool());
	}

	auto httpServer = new MCPHTTPServer(server, host, port);
	httpServer.start();
}

void testSearch(string query)
{
	if(!exists(DEFAULT_DB_PATH)) {
		writeln("Database not found. Run --init-db first.");
		return;
	}

	writeln("Testing search with query: ", query);

	auto conn = new DBConnection(DEFAULT_DB_PATH);
	scope(exit)
		conn.close();

	auto search = new HybridSearch(conn);

	writeln("\n=== Package Search ===");
	auto packages = search.searchPackages(query, 5);
	foreach(i, pkg; packages) {
		writeln(i + 1, ". ", pkg.name, " (rank: ", pkg.rank, ")");
	}

	writeln("\n=== Example Search (Vector) ===");
	auto examples = search.searchExamples(query, 5);
	foreach(i, ex; examples) {
		writeln(i + 1, ". ", ex.packageName);
		writeln("   Score: ", ex.rank);
		writeln("   Code: ", ex.signature[0 .. min(100, ex.signature.length)], "...");
		writeln();
	}
}

void trainEmbeddings()
{
	if(!exists(DEFAULT_DB_PATH)) {
		writeln("Database not found. Run --init-db and --ingest first.");
		return;
	}

	writeln("Training TF-IDF embeddings...");

	auto conn = new DBConnection(DEFAULT_DB_PATH);
	scope(exit)
		conn.close();

	auto crud = new CRUDOperations(conn);
	auto texts = crud.getAllDocumentTexts();

	writeln("Found ", texts.length, " documents for training");

	auto manager = EmbeddingManager.getInstance();
	manager.trainTfIdf(texts);

	writeln("Training complete. Re-ingesting with new embeddings...");

	auto search = new HybridSearch(conn);

	auto pkgStmt = conn.prepare("SELECT id, name, description FROM packages");
	foreach(row; pkgStmt.execute()) {
		long id = row["id"].as!long;
		string text = row["name"].as!string;
		if(row["description"].type != SqliteType.NULL)
			text ~= " " ~ row["description"].as!string;

		auto embedding = manager.embed(text);
		crud.storePackageEmbedding(id, embedding);
	}

	auto exStmt = conn.prepare("SELECT id, code, description FROM code_examples");
	int count = 0;
	foreach(row; exStmt.execute()) {
		long id = row["id"].as!long;
		string text = row["code"].as!string;
		if(row["description"].type != SqliteType.NULL)
			text ~= " " ~ row["description"].as!string;

		auto embedding = manager.embed(text);
		crud.storeExampleEmbedding(id, embedding);
		count++;

		if(count % 1000 == 0)
			writeln("  Processed ", count, " examples...");
	}

	writeln("Re-ingested ", count, " example embeddings");
	writeln("Done!");
}
