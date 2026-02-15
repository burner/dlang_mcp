module ingestion.pipeline;

import storage.connection;
import storage.crud;
import ingestion.dub_crawler;
import ingestion.ddoc_parser;
import ingestion.enhanced_parser;
import embeddings.manager;
import models;
import d2sqlite3;
import std.stdio;
import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import std.datetime;
import std.conv;

struct IngestionProgress {
	string lastPackage;
	SysTime lastUpdated;
	long packagesProcessed;
	long totalPackages;
	string status;
	string errorMessage;
}

class IngestionPipeline {
	private DBConnection conn;
	private CRUDOperations crud;
	private DubCrawler crawler;
	private DdocParser parser;
	private EnhancedDdocParser enhancedParser;
	private EmbeddingManager embedder;

	this(string dbPath = "data/search.db")
	{
		conn = new DBConnection(dbPath);
		crud = new CRUDOperations(conn);
		crawler = new DubCrawler("data/cache");
		parser = new DdocParser();
		enhancedParser = new EnhancedDdocParser();
		embedder = EmbeddingManager.getInstance();
	}

	void close()
	{
		if(conn !is null) {
			conn.close();
			conn = null;
		}
	}

	void ingestPackage(string packageName)
	{
		writeln("\n=== Ingesting package: ", packageName, " ===");

		auto transaction = Transaction(conn);

		try {
			auto metadata = crawler.fetchPackageInfo(packageName);
			writeln("  Version: ", metadata.version_);
			writeln("  Description: ", metadata.description);

			long pkgId = crud.insertPackage(metadata);
			writeln("  Package ID: ", pkgId);

			auto sourceDir = crawler.downloadPackageSource(packageName, metadata.version_);
			auto srcDir = crawler.findSourceDirectory(sourceDir);
			auto dFiles = crawler.findDFiles(srcDir);

			writeln("  Found ", dFiles.length, " D source files");

			int modulesCount = 0;
			int functionsCount = 0;
			int typesCount = 0;
			int examplesCount = 0;

			foreach(file; dFiles) {
				auto modResult = parseAndStoreModule(file, packageName, pkgId);
				modulesCount += modResult.modules;
				functionsCount += modResult.functions;
				typesCount += modResult.types;
				examplesCount += modResult.examples;
			}

			writeln("  Indexed: ", modulesCount, " modules, ", functionsCount,
					" functions, ", typesCount, " types, ", examplesCount, " examples");

			updateFtsForPackage(pkgId, metadata);

			if(conn.hasVectorSupport()) {
				writeln("  Storing embeddings...");
				string pkgText = metadata.name ~ " " ~ metadata.description ~ " " ~ metadata.tags.join(
						" ");
				auto pkgEmbedding = embedder.embed(pkgText);
				crud.storePackageEmbedding(pkgId, pkgEmbedding);
			}

			transaction.commit();

			writeln("  ✓ Package ingested successfully");
		} catch(Exception e) {
			stderr.writeln("  ✗ Error: ", e.msg);
			updateProgress(packageName, "error", e.msg);
			throw e;
		}
	}

	struct ParseResult {
		int modules;
		int functions;
		int types;
		int examples;
	}

	private ParseResult parseAndStoreModule(string filePath, string packageName, long pkgId)
	{
		ParseResult result;

		try {
			auto unittests = enhancedParser.extractUnittestBlocks(filePath, packageName);

			string moduleName;
			auto parts = filePath.split("/");
			if(parts.length > 0) {
				auto fileName = parts[$ - 1].replace(".d", "");
				moduleName = packageName ~ "." ~ fileName;
			} else {
				moduleName = packageName;
			}

			long modId = crud.insertModule(pkgId, ModuleDoc(moduleName, packageName, "", [
			], []));
			result.modules = 1;

			foreach(ex; unittests) {
				ex.packageId = pkgId;
				long exampleId = crud.insertCodeExample(ex);
				result.examples++;

				if(conn.hasVectorSupport() && exampleId > 0) {
					string exText = ex.code ~ " " ~ ex.description;
					auto exEmbedding = embedder.embed(exText);
					crud.storeExampleEmbedding(exampleId, exEmbedding);
				}

				crud.updateFtsExample(exampleId, ex.code, ex.description, "", packageName);
			}

			result.functions = 0;
			result.types = 0;
		} catch(Exception e) {
			stderr.writeln("    Warning: Failed to parse ", filePath, ": ", e.msg);
		}

		return result;
	}

	private void updateFtsForPackage(long pkgId, PackageMetadata metadata)
	{
		auto stmt = conn.prepare("
            INSERT INTO fts_packages (package_id, name, description, authors, tags)
            VALUES (?, ?, ?, ?, ?)
        ");
		stmt.bind(1, pkgId);
		stmt.bind(2, metadata.name);
		stmt.bind(3, metadata.description);
		stmt.bind(4, metadata.authors.join(" "));
		stmt.bind(5, metadata.tags.join(" "));
		stmt.execute();
	}

	void ingestAll(int limit = 0, bool fresh = false)
	{
		writeln("\n=== Starting Batch Ingestion ===");

		auto progress = getProgress();

		string[] packages;
		try {
			packages = crawler.fetchAllPackages();
		} catch(Exception e) {
			stderr.writeln("Failed to fetch package list: ", e.msg);
			return;
		}

		if(limit > 0 && packages.length > limit) {
			packages = packages[0 .. limit];
		}

		if(!fresh && progress.status == "running" && progress.lastPackage.length > 0) {
			writeln("Resuming from: ", progress.lastPackage);
			auto idx = packages.countUntil(progress.lastPackage);
			if(idx >= 0 && idx < packages.length - 1) {
				packages = packages[idx + 1 .. $];
			}
		}

		initProgress(packages.length);

		writeln("Total packages to process: ", packages.length);

		int processed = 0;
		int succeeded = 0;
		int failed = 0;

		foreach(pkgName; packages) {
			processed++;

			try {
				ingestPackage(pkgName);
				succeeded++;
				updateProgress(pkgName, "running", null, processed);
			} catch(Exception e) {
				failed++;
				stderr.writeln("Skipping ", pkgName, ": ", e.msg);
			}

			if(processed % 10 == 0) {
				auto stats = crud.getStats();
				writeln("\n--- Progress: ", processed, "/", packages.length,
						" (", succeeded, " succeeded, ", failed, " failed) ---");
				writeln("Database: ", stats.packageCount, " packages, ",
						stats.functionCount, " functions, ", stats.exampleCount, " examples\n");
			}
		}

		updateProgress("", "completed", null, processed);
		writeln("\n=== Ingestion Complete ===");
		writeln("Processed: ", processed);
		writeln("Succeeded: ", succeeded);
		writeln("Failed: ", failed);

		auto finalStats = crud.getStats();
		writeln("\nFinal database statistics:");
		writeln("  Packages: ", finalStats.packageCount);
		writeln("  Modules:  ", finalStats.moduleCount);
		writeln("  Functions:", finalStats.functionCount);
		writeln("  Types:    ", finalStats.typeCount);
		writeln("  Examples: ", finalStats.exampleCount);
	}

	IngestionProgress getProgress()
	{
		IngestionProgress progress;

		try {
			auto stmt = conn.prepare("SELECT * FROM ingestion_progress ORDER BY id DESC LIMIT 1");
			auto result = stmt.execute();

			if(!result.empty) {
				auto row = result.front;
				progress.lastPackage = row["last_package"].as!string;
				progress.packagesProcessed = row["packages_processed"].as!long;
				progress.totalPackages = row["total_packages"].as!long;
				progress.status = row["status"].as!string;
				if(row["error_message"].type != SqliteType.NULL)
					progress.errorMessage = row["error_message"].as!string;
			}
		} catch(Exception) {
		}

		return progress;
	}

	private void initProgress(long total)
	{
		conn.execute("DELETE FROM ingestion_progress WHERE status = 'idle'");

		auto stmt = conn.prepare("
            INSERT INTO ingestion_progress (last_package, packages_processed, total_packages, status)
            VALUES ('', 0, ?, 'running')
        ");
		stmt.bind(1, total);
		stmt.execute();
	}

	private void updateProgress(string lastPackage, string status,
			string errorMessage = null, long processed = -1)
	{
		auto stmt = conn.prepare("
            UPDATE ingestion_progress 
            SET last_package = ?, last_updated = CURRENT_TIMESTAMP, 
                status = ?, packages_processed = ?, error_message = ?
            WHERE id = (SELECT MAX(id) FROM ingestion_progress)
        ");
		stmt.bind(1, lastPackage);
		stmt.bind(2, status);
		if(processed >= 0)
			stmt.bind(3, processed);
		else
			stmt.bind(3, null);
		stmt.bind(4, errorMessage);
		stmt.execute();
	}
}
