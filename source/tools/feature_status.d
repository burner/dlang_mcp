/**
 * MCP tool and helpers for detecting runtime feature availability.
 *
 * Probes the environment to determine which features are operational,
 * including database connectivity, ONNX embeddings, sqlite-vec vector
 * search, and external tools (dmd, ldc2, dub, dscanner, dfmt).
 */
module tools.feature_status;

import std.json : JSONValue, parseJSON, JSONType;
import std.file : exists;
import std.string : strip;
import std.algorithm : splitter;
import std.process : execute;
import tools.base : BaseTool;
import mcp.types : ToolResult;

/**
 * Shared feature detection logic used by both the MCP tool and the
 * initialize response. Returns a structured JSONValue describing
 * which runtime features are available.
 */
JSONValue detectFeatures()
{
	JSONValue status;

	// --- Database ---
	enum DB_PATH = "data/search.db";
	bool dbAvailable = exists(DB_PATH);
	{
		JSONValue db;
		db["available"] = JSONValue(dbAvailable);
		db["path"] = JSONValue(DB_PATH);
		status["database"] = db;
	}

	// --- sqlite-vec extension ---
	bool vecLoaded = false;
	if(dbAvailable) {
		try {
			import storage.connection : DBConnection;

			auto conn = new DBConnection(DB_PATH);
			scope(exit)
				conn.close();
			vecLoaded = conn.hasVectorSupport();
		} catch(Exception) {
		}
	}
	{
		JSONValue ext;
		JSONValue vec;
		vec["available"] = JSONValue(vecLoaded);
		vec["detail"] = JSONValue(vecLoaded ? "loaded" : (dbAvailable
				? "not loaded" : "database not available to test"));
		ext["sqlite_vec"] = vec;
		status["extensions"] = ext;
	}

	// --- Embeddings ---
	enum ONNX_MODEL_PATH = "data/models/model.onnx";
	enum VOCAB_PATH = "data/models/vocab.txt";
	enum TFIDF_VOCAB_PATH = "data/models/tfidf_vocab.json";

	bool onnxModelExists = exists(ONNX_MODEL_PATH);
	bool vocabExists = exists(VOCAB_PATH);
	bool tfidfVocabExists = exists(TFIDF_VOCAB_PATH);

	bool onnxRuntimeAvailable = false;
	if(onnxModelExists) {
		try {
			import bindbc.onnxruntime;

			auto support = loadONNXRuntime();
			onnxRuntimeAvailable = (support != ONNXRuntimeSupport.noLibrary
					&& support != ONNXRuntimeSupport.badLibrary);
		} catch(Exception) {
		}
	}

	string activeEngine;
	if(onnxRuntimeAvailable && onnxModelExists)
		activeEngine = "ONNX (all-MiniLM-L6-v2)";
	else if(tfidfVocabExists)
		activeEngine = "TF-IDF";
	else
		activeEngine = "TF-IDF (untrained)";

	{
		JSONValue emb;

		JSONValue onnxModel;
		onnxModel["available"] = JSONValue(onnxModelExists);
		onnxModel["path"] = JSONValue(ONNX_MODEL_PATH);
		emb["onnx_model"] = onnxModel;

		JSONValue onnxRt;
		onnxRt["available"] = JSONValue(onnxRuntimeAvailable);
		emb["onnx_runtime"] = onnxRt;

		JSONValue onnxVocab;
		onnxVocab["available"] = JSONValue(vocabExists);
		onnxVocab["path"] = JSONValue(VOCAB_PATH);
		emb["onnx_vocabulary"] = onnxVocab;

		JSONValue tfidfVocab;
		tfidfVocab["available"] = JSONValue(tfidfVocabExists);
		tfidfVocab["path"] = JSONValue(TFIDF_VOCAB_PATH);
		emb["tfidf_vocabulary"] = tfidfVocab;

		emb["active_engine"] = JSONValue(activeEngine);
		status["embeddings"] = emb;
	}

	// --- External tools ---
	{
		JSONValue ext;
		ext["dscanner"] = probeExternalTool(["dscanner", "--version"]);
		ext["dfmt"] = probeExternalTool(["dfmt", "--version"]);
		status["external_tools"] = ext;
	}

	// --- Search mode ---
	{
		string mode;
		if(!dbAvailable)
			mode = "unavailable";
		else if(vecLoaded)
			mode = "hybrid";
		else
			mode = "text_only";
		status["search_mode"] = JSONValue(mode);
	}

	return status;
}

/**
 * Build a compact boolean summary suitable for the initialize response's
 * serverInfo block. Lighter weight than the full detectFeatures output.
 */
JSONValue buildFeatureStatusSummary(JSONValue fullStatus)
{
	JSONValue summary;

	// database
	if("database" in fullStatus) {
		auto db = fullStatus["database"];
		summary["database"] = db["available"];
	}

	// sqlite_vec
	if("extensions" in fullStatus && "sqlite_vec" in fullStatus["extensions"]) {
		summary["sqlite_vec"] = fullStatus["extensions"]["sqlite_vec"]["available"];
	}

	// embeddings
	if("embeddings" in fullStatus) {
		auto emb = fullStatus["embeddings"];
		if("onnx_runtime" in emb)
			summary["onnx_runtime"] = emb["onnx_runtime"]["available"];
		if("onnx_model" in emb)
			summary["onnx_model"] = emb["onnx_model"]["available"];
		if("tfidf_vocabulary" in emb)
			summary["tfidf_vocabulary"] = emb["tfidf_vocabulary"]["available"];
		if("active_engine" in emb)
			summary["active_embedding_engine"] = emb["active_engine"];
	}

	// search_mode
	if("search_mode" in fullStatus) {
		summary["search_mode"] = fullStatus["search_mode"];
	}

	// external tools
	if("external_tools" in fullStatus) {
		auto ext = fullStatus["external_tools"];
		if("dscanner" in ext)
			summary["dscanner"] = ext["dscanner"]["available"];
		if("dfmt" in ext)
			summary["dfmt"] = ext["dfmt"]["available"];
	}

	return summary;
}

private JSONValue probeExternalTool(string[] command)
{
	JSONValue info;
	try {
		auto result = execute(command);
		if(result.status == 0) {
			auto output = result.output.strip();
			string firstLine = "";
			if(output.length > 0) {
				foreach(line; output.splitter('\n')) {
					firstLine = line;
					break;
				}
			}
			if(firstLine.length > 80)
				firstLine = firstLine[0 .. 80] ~ "...";
			info["available"] = JSONValue(true);
			info["version"] = JSONValue(firstLine);
		} else {
			info["available"] = JSONValue(false);
			info["detail"] = JSONValue("found but returned error");
		}
	} catch(Exception) {
		info["available"] = JSONValue(false);
		info["detail"] = JSONValue("not found in PATH");
	}
	return info;
}

/**
 * Tool that reports which runtime features are currently available.
 *
 * Returns a structured JSON report covering database status, ONNX
 * embeddings, sqlite-vec vector search, external tool availability,
 * and the active search mode.
 */
class FeatureStatusTool : BaseTool {
	@property string name()
	{
		return "get_feature_status";
	}

	@property string description()
	{
		return "Check which optional runtime features are available in this server instance. Use when diagnosing tool failures, asked 'is ONNX available?', or 'what features are enabled?'. Returns JSON with database, ONNX embeddings, sqlite-vec, external tool, and search mode availability. No parameters needed. Call this first when search or analysis tools return unexpected results.";
	}

	@property JSONValue inputSchema()
	{
		return parseJSON(`{
			"type": "object",
			"properties": {},
			"required": []
		}`);
	}

	ToolResult execute(JSONValue arguments)
	{
		try {
			auto status = detectFeatures();
			return createTextResult(status.toPrettyString());
		} catch(Exception e) {
			return createErrorResult("Feature detection failed: " ~ e.msg);
		}
	}
}
