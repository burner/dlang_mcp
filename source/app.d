/**
 * Main entry point and CLI driver for the dlang_mcp server.
 */
module app;

import std.stdio;
import std.file;
import std.conv;
import std.algorithm;
import std.string : strip;
import std.process : execute;
import std.getopt : getopt, GetOptException;
import std.path : buildPath;
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
import tools.feature_status : FeatureStatusTool;
import tools.analyze_project : AnalyzeProjectTool;
import tools.ddoc_analyze : DdocAnalyzeTool;
import tools.outline : ModuleOutlineTool;
import tools.list_modules : ListProjectModulesTool;
import tools.compile_check : CompileCheckTool;
import tools.build_project : BuildProjectTool;
import tools.run_tests : RunTestsTool;
import tools.run_project : RunProjectTool;
import tools.fetch_package : FetchPackageTool;
import tools.upgrade_deps : UpgradeDependenciesTool;
import tools.coverage_analysis : CoverageAnalysisTool;
import storage.connection : DBConnection;
import storage.schema : SchemaManager;
import storage.crud : CRUDOperations;
import storage.search : HybridSearch;
import ingestion.pipeline : IngestionPipeline;
import ingestion.pattern_miner : PatternMiner;
import embeddings.manager : EmbeddingManager;
import d2sqlite3 : SqliteType;

/** Default filesystem path for the SQLite documentation database. */
enum DEFAULT_DB_PATH = "data/search.db";

/**
 * Command-line options parsed from program arguments.
 */
struct CliOptions {
	/** Initialize the search database. */
	bool initDb;
	/** Display database statistics. */
	bool stats;
	/** Display runtime feature status. */
	bool featureStatus;
	/** Show help text and exit. */
	bool help;
	/** Run the pattern mining pass. */
	bool minePatterns;
	/** Retrain TF-IDF embeddings. */
	bool trainEmbeddings;
	/** Run the package ingestion pipeline. */
	bool ingest;
	/** Show current ingestion progress. */
	bool ingestStatus;
	/** Start a fresh ingestion, clearing previous progress. */
	bool fresh;
	/** Use HTTP transport instead of stdio. */
	bool http;
	/** Maximum number of packages to ingest (0 = unlimited). */
	int limit = 0;
	/** TCP port for the HTTP server. */
	ushort port = 3000;
	/** Bind address for the HTTP server. */
	string host = "127.0.0.1";
	/** Single package name to ingest. */
	string package_;
	/** Query string for the test-search command. */
	string testSearch;
	/** Filesystem path of the project to analyze. */
	string analyzeProject;
	/** Output file path for project analysis results. */
	string analyzeProjectOutput;
	/** Filesystem path of the project for DDoc analysis. */
	string ddocAnalyze;
	/** Output file path for DDoc analysis results. */
	string ddocAnalyzeOutput;
	/** Enable verbose logging to stderr for debugging. */
	bool verbose;
	/** Enable very verbose (trace-level) logging to stderr. */
	bool vverbose;
	/** Process execution timeout in seconds (default: 30). */
	int timeout = 30;
}

version(TestMode) {
} else {
	/**
	 * Program entry point. Parses command-line arguments and dispatches
	 * to the appropriate sub-command or starts the MCP server.
	 *
	 * Params:
	 *     args = Command-line arguments passed to the program.
	 */
	void main(string[] args)
	{
		CliOptions opts;
		try {
			getopt(args, "init-db", "Initialize the search database",
					&opts.initDb, "stats", "Show database statistics",
					&opts.stats, "feature-status", "Show runtime feature status",
					&opts.featureStatus, "help|h", "Show this help",
					&opts.help, "mine-patterns", "Mine usage patterns",
					&opts.minePatterns, "train-embeddings", "Re-train embeddings",
					&opts.trainEmbeddings, "ingest", "Ingest packages",
					&opts.ingest, "ingest-status", "Show ingestion progress",
					&opts.ingestStatus, "fresh", "Fresh ingestion (with --ingest)",
					&opts.fresh, "limit", "Limit packages (with --ingest)",
					&opts.limit, "package", "Single package to ingest (with --ingest)",
					&opts.package_, "test-search", "Test search with query",
					&opts.testSearch, "analyze-project",
					"Analyze a D project at given path", &opts.analyzeProject,
					"analyze-project-output",
					"Output file for --analyze-project (default: project_analysis.txt)",
					&opts.analyzeProjectOutput, "ddoc-analyze",
					"Analyze project documentation/attributes via DMD JSON",
					&opts.ddocAnalyze, "ddoc-analyze-output",
					"Output file for --ddoc-analyze (default: ddoc_analysis.txt)",
					&opts.ddocAnalyzeOutput,
					"http", "Run MCP server with HTTP transport", &opts.http,
					"port", "HTTP port (default: 3000)", &opts.port, "host",
					"HTTP host (default: 127.0.0.1)", &opts.host,
					"verbose|v", "Enable verbose logging to stderr", &opts.verbose,
					"vverbose", "Enable trace-level logging to stderr",
					&opts.vverbose, "timeout",
					"Process execution timeout in seconds (default: 30)", &opts.timeout,);
		} catch(GetOptException e) {
			stderr.writeln("Error: ", e.msg);
			printHelp();
			return;
		}

		// Configure logging level. Default sharedLog writes to stderr.
		// Default globalLogLevel is LogLevel.all, so we set it to error
		// to only show errors unless verbose flags are used.
		{
			import std.logger : globalLogLevel, LogLevel;

			if(opts.vverbose)
				globalLogLevel = LogLevel.trace;
			else if(opts.verbose)
				globalLogLevel = LogLevel.info;
			else
				globalLogLevel = LogLevel.error;
		}

		// Set process execution timeout
		{
			import utils.process : setProcessTimeout;
			import core.time : dur;

			setProcessTimeout(dur!"seconds"(opts.timeout));
		}

		if(opts.help) {
			printHelp();
			return;
		}
		if(opts.featureStatus) {
			printFeatureStatus();
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
		if(opts.analyzeProject.length > 0) {
			runAnalyzeProject(opts.analyzeProject, opts.analyzeProjectOutput);
			return;
		}
		if(opts.ddocAnalyze.length > 0) {
			runDdocAnalyze(opts.ddocAnalyze, opts.ddocAnalyzeOutput);
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

/**
 * Print usage information and available commands to stdout.
 */
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
	writeln("  ./bin/dlang_mcp --feature-status       Show runtime feature status");
	writeln("  ./bin/dlang_mcp --ingest               Ingest all packages from code.dlang.org");
	writeln("  ./bin/dlang_mcp --ingest --package=foo Ingest a single package");
	writeln("  ./bin/dlang_mcp --ingest-status        Show ingestion progress");
	writeln("  ./bin/dlang_mcp --train-embeddings     Re-train embeddings");
	writeln("  ./bin/dlang_mcp --mine-patterns        Mine usage patterns from indexed data");
	writeln("  ./bin/dlang_mcp --test-search=QUERY    Test search with a query");
	writeln(
			"  ./bin/dlang_mcp --analyze-project=PATH Analyze a D project and write results to file");
	writeln("  ./bin/dlang_mcp --ddoc-analyze=PATH    Analyze project docs/attributes via DMD JSON");
	writeln("  ./bin/dlang_mcp --help                 Show this help");
	writeln(
			"  ./bin/dlang_mcp --verbose              Enable verbose (info-level) logging to stderr");
	writeln("  ./bin/dlang_mcp --vverbose             Enable trace-level logging to stderr");
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
	writeln("  --timeout=SECS   Process execution timeout (default: 30)");
	writeln();
	writeln("Analyze options:");
	writeln("  --analyze-project=PATH          Project path to analyze");
	writeln("  --analyze-project-output=FILE   Output file (default: project_analysis.txt)");
	writeln("  --ddoc-analyze=PATH             Project path for ddoc analysis");
	writeln("  --ddoc-analyze-output=FILE      Output file (default: ddoc_analysis.txt)");
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
	writeln("  compile_check   - Compile-check D code (syntax/type errors)");
	writeln("  build_project   - Build a D/dub project");
	writeln("  run_tests       - Run dub project tests");
	writeln("  run_project     - Run a D/dub project");
	writeln("  fetch_package   - Fetch a package from the dub registry");
	writeln("  upgrade_dependencies - Upgrade project dependencies");
	writeln("  analyze_project - Analyze D project structure");
	writeln("  ddoc_analyze    - Analyze project docs/attributes via DMD JSON");
	writeln("  module_outline  - Get detailed module symbol outline");
	writeln("  list_modules    - List project modules with symbols");
	writeln("  search_packages - Search for D packages");
	writeln("  search_functions- Search for D functions");
	writeln("  search_types    - Search for D types (classes, structs, etc.)");
	writeln("  search_examples - Search for code examples");
	writeln("  get_imports     - Get import statements for symbols");
}

/**
 * Print a detailed report of runtime feature availability to stdout.
 */
void printFeatureStatus()
{
	enum OK = "[OK]";
	enum NO = "[--]";

	writeln("dlang_mcp - Feature Status");
	writeln("==========================");

	// --- Database ---
	writeln();
	writeln("Database:");
	bool dbAvailable = exists(DEFAULT_DB_PATH);
	writeln("  ", dbAvailable ? OK : NO, " Search database         ", DEFAULT_DB_PATH);

	// --- sqlite-vec extension ---
	writeln();
	writeln("Extensions:");
	bool vecLoaded = false;
	if(dbAvailable) {
		try {
			auto conn = new DBConnection(DEFAULT_DB_PATH);
			scope(exit)
				conn.close();
			vecLoaded = conn.hasVectorSupport();
			writeln("  ", vecLoaded ? OK : NO, " sqlite-vec              ",
					vecLoaded ? "loaded" : "not loaded");
		} catch(Exception e) {
			writeln("  ", NO, " sqlite-vec              error: ", e.msg);
		}
	} else {
		writeln("  ", NO, " sqlite-vec              (database not available to test)");
	}

	// --- ONNX Runtime & model ---
	enum ONNX_MODEL_PATH = "data/models/model.onnx";
	enum VOCAB_PATH = "data/models/vocab.txt";
	enum TFIDF_VOCAB_PATH = "data/models/tfidf_vocab.json";

	writeln();
	writeln("Embeddings:");
	bool onnxModelExists = exists(ONNX_MODEL_PATH);
	writeln("  ", onnxModelExists ? OK : NO, " ONNX model              ", ONNX_MODEL_PATH);

	bool vocabExists = exists(VOCAB_PATH);
	writeln("  ", vocabExists ? OK : NO, " ONNX vocabulary         ", VOCAB_PATH);

	bool tfidfVocabExists = exists(TFIDF_VOCAB_PATH);
	writeln("  ", tfidfVocabExists ? OK : NO, " TF-IDF vocabulary       ", TFIDF_VOCAB_PATH);

	// Check ONNX Runtime library availability
	bool onnxRuntimeAvailable = false;
	string activeEngine = "TF-IDF";
	if(onnxModelExists) {
		try {
			import bindbc.onnxruntime;

			auto support = loadONNXRuntime();
			onnxRuntimeAvailable = (support != ONNXRuntimeSupport.noLibrary
					&& support != ONNXRuntimeSupport.badLibrary);
		} catch(Exception) {
		}
	}
	writeln("  ", onnxRuntimeAvailable ? OK : NO, " ONNX Runtime library    ",
			onnxRuntimeAvailable ? "loaded" : "not available");

	if(onnxRuntimeAvailable && onnxModelExists)
		activeEngine = "ONNX (all-MiniLM-L6-v2)";
	else if(tfidfVocabExists)
		activeEngine = "TF-IDF";
	else
		activeEngine = "TF-IDF (untrained)";

	writeln("  Active engine:         ", activeEngine);

	// --- External Tools ---
	writeln();
	writeln("External Tools:");
	checkExternalTool("dscanner", ["dscanner", "--version"]);
	checkExternalTool("dfmt", ["dfmt", "--version"]);

	// --- MCP Tools ---
	writeln();
	writeln("MCP Tools:");
	writeln("  ", OK, " dscanner               static analysis (always available)");
	writeln("  ", OK, " dfmt                   code formatting (always available)");
	writeln("  ", OK, " ctags_search           symbol search (always available)");
	writeln("  ", OK, " compile_check          compile checking (always available)");
	writeln("  ", OK, " build_project          dub build (always available)");
	writeln("  ", OK, " run_tests              dub test (always available)");
	writeln("  ", OK, " run_project            dub run (always available)");
	writeln("  ", OK, " fetch_package          dub fetch (always available)");
	writeln("  ", OK, " upgrade_dependencies   dub upgrade (always available)");
	writeln("  ", OK, " analyze_project        project analysis (always available)");
	writeln("  ", OK, " module_outline         module outline (always available)");
	writeln("  ", OK, " list_modules           module listing (always available)");
	writeln("  ", dbAvailable ? OK : NO, " search_packages        ", dbAvailable
			? "available" : "requires --init-db");
	writeln("  ", dbAvailable ? OK : NO, " search_functions       ", dbAvailable
			? "available" : "requires --init-db");
	writeln("  ", dbAvailable ? OK : NO, " search_types           ", dbAvailable
			? "available" : "requires --init-db");
	writeln("  ", dbAvailable ? OK : NO, " search_examples        ", dbAvailable
			? "available" : "requires --init-db");
	writeln("  ", dbAvailable ? OK : NO, " get_imports            ", dbAvailable
			? "available" : "requires --init-db");

	// --- Search mode ---
	writeln();
	writeln("Search Mode:");
	if(!dbAvailable) {
		writeln("  ", NO, " Search unavailable (no database)");
	} else if(vecLoaded) {
		writeln("  ", OK, " Hybrid search (FTS5 + vector)");
	} else {
		writeln("  ", OK, " Text search only (FTS5)");
		writeln("       Install sqlite-vec for hybrid vector+text search");
	}
}

private void checkExternalTool(string name, string[] command)
{
	enum OK = "[OK]";
	enum NO = "[--]";

	string padding = name.length < 20 ? "                    "[0 .. 20 - name.length] : " ";

	try {
		auto result = execute(command);
		if(result.status == 0) {
			// Extract first line of version output
			auto output = result.output.strip();
			auto firstLine = output.length > 0 ? output.splitter('\n').front : "";
			// Truncate long version strings
			if(firstLine.length > 50)
				firstLine = firstLine[0 .. 50] ~ "...";
			writeln("  ", OK, " ", name, padding, firstLine);
		} else {
			writeln("  ", NO, " ", name, padding, "found but returned error");
		}
	} catch(Exception) {
		writeln("  ", NO, " ", name, padding, "not found in PATH");
	}
}

/**
 * Create and initialize the SQLite search database with the required schema.
 *
 * Returns:
 *     Prints the schema status and initial record counts to stdout.
 */
void initializeDatabase()
{
	writeln("Initializing search database...");

	auto conn = new DBConnection(DEFAULT_DB_PATH);
	scope(exit)
		conn.close();
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
}

/**
 * Print database record counts to stdout.
 */
void printStats()
{
	if(!exists(DEFAULT_DB_PATH)) {
		writeln("Database not found. Run --init-db first.");
		return;
	}

	auto conn = new DBConnection(DEFAULT_DB_PATH);
	scope(exit)
		conn.close();
	auto crud = new CRUDOperations(conn);

	auto stats = crud.getStats();

	writeln("Database Statistics:");
	writeln("  Packages: ", stats.packageCount);
	writeln("  Modules:  ", stats.moduleCount);
	writeln("  Functions:", stats.functionCount);
	writeln("  Types:    ", stats.typeCount);
	writeln("  Examples: ", stats.exampleCount);
}

/**
 * Run the package ingestion pipeline based on the provided CLI options.
 *
 * Ingests either a single named package or all packages from code.dlang.org,
 * optionally starting fresh or limiting the number of packages processed.
 *
 * Params:
 *     opts = The parsed command-line options controlling ingestion behavior.
 */
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

/**
 * Print current ingestion pipeline progress to stdout.
 */
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

/**
 * Mine usage patterns from the indexed data in the database.
 */
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

private MCPServer createConfiguredServer()
{
	auto server = new MCPServer();

	server.registerTool(new DscannerTool());
	server.registerTool(new DfmtTool());
	server.registerTool(new CtagsSearchTool());
	server.registerTool(new FeatureStatusTool());
	server.registerTool(new AnalyzeProjectTool());
	server.registerTool(new DdocAnalyzeTool());
	server.registerTool(new ModuleOutlineTool());
	server.registerTool(new ListProjectModulesTool());
	server.registerTool(new CompileCheckTool());
	server.registerTool(new BuildProjectTool());
	server.registerTool(new RunTestsTool());
	server.registerTool(new RunProjectTool());
	server.registerTool(new FetchPackageTool());
	server.registerTool(new UpgradeDependenciesTool());
	server.registerTool(new CoverageAnalysisTool());

	// Always register search tools so they appear in tools/list.
	// They return a helpful error at call time if the DB is missing.
	server.registerTool(new PackageSearchTool());
	server.registerTool(new FunctionSearchTool());
	server.registerTool(new TypeSearchTool());
	server.registerTool(new ExampleSearchTool());
	server.registerTool(new ImportTool());

	return server;
}

/**
 * Start the MCP server using stdio transport.
 */
void runMcpServer()
{
	auto server = createConfiguredServer();
	auto transport = new StdioTransport();
	server.start(transport);
}

/**
 * Start the MCP server using HTTP transport.
 *
 * Params:
 *     host       = The network address to bind the HTTP server to.
 *     port       = The TCP port to listen on.
 */
void runHttpServer(string host, ushort port)
{
	auto server = createConfiguredServer();
	auto httpServer = new MCPHTTPServer(server, host, port);
	httpServer.start();
}

/**
 * Execute a test search against the database and print results to stdout.
 *
 * Params:
 *     query = The search query string to test.
 */
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
		// Show first few lines of code, truncate if too many
		auto codeLines = ex.signature.splitter('\n');
		writeln("   Code: ");
		int lineCount;
		foreach(line; codeLines) {
			if(lineCount >= 6) {
				writeln("         ... (truncated)");
				break;
			}
			writeln("     ", line);
			lineCount++;
		}
		writeln();
	}
}

/**
 * Analyze a D project's structure and write the results to a file.
 *
 * Params:
 *     projectPath = Filesystem path to the D project root directory.
 *     outputPath  = Destination file path for the analysis output.
 *                   Defaults to "project_analysis.txt" if empty.
 */
void runAnalyzeProject(string projectPath, string outputPath)
{
	import std.json : JSONValue, JSONType;

	if(outputPath.length == 0)
		outputPath = "project_analysis.txt";

	writeln("Analyzing project at: ", projectPath);

	auto tool = new AnalyzeProjectTool();
	JSONValue args = JSONValue(string[string].init);
	args["project_path"] = JSONValue(projectPath);

	auto result = tool.execute(args);

	if(result.isError) {
		stderr.writeln("Error: ", result.content.length > 0
				? result.content[0].text : "unknown error");
		return;
	}

	string text;
	foreach(c; result.content) {
		if(c.type == "text")
			text ~= c.text;
	}

	std.file.write(outputPath, text);
	writeln("Project analysis written to: ", outputPath);
}

/**
 * Analyze a D project's documentation and attributes via DMD JSON output
 * and write the results to a file.
 *
 * Params:
 *     projectPath = Filesystem path to the D project root directory.
 *     outputPath  = Destination file path for the DDoc analysis output.
 *                   Defaults to "ddoc_analysis.txt" if empty.
 */
void runDdocAnalyze(string projectPath, string outputPath)
{
	import std.json : JSONValue, JSONType;

	if(outputPath.length == 0)
		outputPath = "ddoc_analysis.txt";

	writeln("Analyzing project documentation at: ", projectPath);

	auto tool = new DdocAnalyzeTool();
	JSONValue args = JSONValue(string[string].init);
	args["project_path"] = JSONValue(projectPath);
	args["verbose"] = JSONValue(true);

	auto result = tool.execute(args);

	if(result.isError) {
		stderr.writeln("Error: ", result.content.length > 0
				? result.content[0].text : "unknown error");
		return;
	}

	string text;
	foreach(c; result.content) {
		if(c.type == "text")
			text ~= c.text;
	}

	std.file.write(outputPath, text);
	writeln("DDoc analysis written to: ", outputPath);
}

/**
 * Train TF-IDF embeddings from all indexed documents and re-embed all
 * packages and code examples in the database.
 */
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
