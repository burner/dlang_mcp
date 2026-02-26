/**
 * TF-IDF embedding backend using term frequency-inverse document frequency vectors.
 */
module embeddings.tfidf_embedder;

import embeddings.embedder;
import std.algorithm;
import std.array;
import std.conv;
import std.math;
import std.regex;
import std.string;
import std.ascii;

/**
 * Generates sparse-to-dense TF-IDF vector embeddings from text using a trainable vocabulary.
 *
 * The embedder maintains a vocabulary of terms mapped to vector indices and
 * computes TF-IDF weights to produce fixed-length embedding vectors. The
 * vocabulary can be trained on a corpus of documents or loaded from disk.
 */
class TfIdfEmbedder : Embedder {
	private int _dimensions;
	private string[string] vocabulary;
	private double[] idf;
	private bool _available = true;

	/**
	 * Construct a new TF-IDF embedder with a pre-seeded vocabulary.
	 *
	 * Params:
	 *     dimensions = The size of the output embedding vectors (default 1000).
	 */
	this(int dimensions = 1000)
	{
		_dimensions = dimensions;
		initializeVocabulary();
	}

	private void initializeVocabulary()
	{
		string[] commonTerms = [
			"function", "return", "string", "int", "void", "bool", "class",
			"struct", "import", "module", "package", "public", "private", "static",
			"const", "template", "auto", "array", "range", "foreach", "if", "else",
			"while", "for", "switch", "case", "break", "continue", "return",
			"throw", "try", "catch", "finally", "assert", "unittest", "version",
			"debug", "pragma", "mixin", "pragma", "typeof", "typeid", "is", "in",
			"out", "ref", "lazy", "pure", "nothrow", "@safe", "@trusted",
			"@system", "@nogc", "@property", "delegate", "function", "lambda",
			"alias", "enum", "union", "interface", "abstract", "final", "override",
			"synchronized", "volatile", "shared", "immutable", "const", "inout",
			"scope", "new", "delete", "null", "true", "false", "this", "super",
			"sizeof", "alignof", "mangleof", "stringof", "init", "sizeof",
			"alignof", "mangleof", "stringof", "tupleof", "length", "ptr",
			"funcptr", "dup", "idup", "reverse", "sort", "keys", "values",
			"rehash", "clear", "remove", "opApply", "opDispatch", "opCast",
			"opCall", "opIndex", "opIndexAssign", "opSlice", "opSliceAssign",
			"opBinary", "opBinaryRight", "opUnary", "opAssign", "opOpAssign",
			"opEquals", "opCmp", "opHash", "toHash", "toString", "fromString",
			"parse", "encode", "decode", "serialize", "deserialize", "read",
			"write", "open", "close", "flush", "seek", "tell", "eof", "error",
			"clear", "buffer", "input", "output", "stdin", "stdout", "stderr",
			"file", "dir", "path", "name", "base", "extension", "root", "drive",
			"split", "join", "build", "expand", "relative", "absolute",
			"canonical", "exists", "isfile", "isdir", "isabs", "copy", "move",
			"remove", "mkdir", "rmdir", "rename", "size", "time", "access",
			"modified", "created", "attributes", "permissions", "owner",
			"group", "executable", "readable", "writable",
			"hidden", "system", "link", "symlink", "hardlink", "readlink",
			"canonical", "resolve", "normalize", "process", "spawn", "pipe",
			"exec", "wait", "kill", "terminate", "pid", "exit", "status", "signal",
			"interrupt", "hangup", "quit", "abort", "floating", "exception",
			"segmentation", "bus", "trap", "user", "alarm", "child", "continue",
			"stop", "tstp", "ttin", "ttou", "urg", "xcpu", "xfsz", "vtalrm",
			"prof", "winch", "io", "pwr", "sys", "emt", "info", "key", "value",
			"data", "result", "error", "warning", "info", "debug", "trace",
			"fatal", "critical", "alert", "emergency", "notice", "config",
			"format", "parse", "validate", "transform", "convert", "encode",
			"decode", "compress", "decompress", "encrypt", "decrypt", "hash",
			"sign", "verify", "generate", "create", "destroy", "build", "compile",
			"run", "execute", "start", "stop", "pause", "resume", "reset",
			"initialize", "finalize", "alloc", "free", "realloc", "calloc",
			"malloc", "memory", "buffer", "stream", "reader", "writer",
			"encoder", "decoder", "parser", "printer", "formatter",
			"validator", "serializer", "deserializer", "generator", "builder",
			"factory", "singleton", "prototype", "adapter", "proxy",
			"decorator", "facade", "composite", "observer", "strategy",
			"command", "iterator", "visitor", "mediator", "memento", "state",
			"template method", "chain", "responsibility", "flyweight",
			"interpreter", "builder", "clone"
		];

		foreach(i, term; commonTerms) {
			if(i >= _dimensions)
				break;
			vocabulary[term] = i.text;
		}

		idf = new double[_dimensions];
		idf[] = 1.0;
	}

	/**
	 * Embed a single text string into a TF-IDF vector.
	 *
	 * Params:
	 *     text = The input text to embed.
	 *
	 * Returns: A normalized float array of length `dimensions()` representing the TF-IDF embedding.
	 */
	float[] embed(string text)
	{
		auto terms = tokenize(text);
		float[] vec = new float[_dimensions];
		vec[] = 0.0f;

		int[string] termCounts;
		foreach(term; terms) {
			if(term in termCounts)
				termCounts[term]++;
			else
				termCounts[term] = 1;
		}

		foreach(term, count; termCounts) {
			if(term in vocabulary) {
				int idx = vocabulary[term].to!int;
				double tf = cast(double)count / terms.length;
				vec[idx] = cast(float)(tf * idf[idx]);
			}
		}

		normalize(vec);

		return vec;
	}

	/**
	 * Embed multiple text strings in one call.
	 *
	 * Params:
	 *     texts = An array of input texts to embed.
	 *
	 * Returns: An array of float arrays, one TF-IDF embedding per input text.
	 */
	float[][] embedBatch(string[] texts)
	{
		float[][] results = new float[][](texts.length);
		foreach(i, text; texts) {
			results[i] = embed(text);
		}
		return results;
	}

	/**
	 * Returns: The dimensionality of the embedding vectors produced by this backend.
	 */
	int dimensions()
	{
		return _dimensions;
	}

	/**
	 * Returns: `true` if this TF-IDF backend is ready to produce vectors.
	 */
	bool isAvailable()
	{
		return _available;
	}

	/**
	 * Returns: The string `"TF-IDF"`.
	 */
	string name()
	{
		return "TF-IDF";
	}

	/**
	 * Train the TF-IDF model on a corpus of documents.
	 *
	 * Computes inverse document frequency weights and expands the vocabulary
	 * with new terms found in the corpus, up to the configured dimensionality.
	 *
	 * Params:
	 *     documents = An array of document strings to train on.
	 */
	void train(string[] documents)
	{
		int[string] termDocFreq;
		int[string] termIdx;
		int nextIdx = cast(int)vocabulary.length;

		foreach(doc; documents) {
			auto terms = tokenize(doc);
			bool[string] seenInDoc;

			foreach(term; terms) {
				if(term in vocabulary) {
					if(term !in seenInDoc) {
						int idx = vocabulary[term].to!int;
						termIdx[term] = idx;
						if(term in termDocFreq)
							termDocFreq[term]++;
						else
							termDocFreq[term] = 1;
						seenInDoc[term] = true;
					}
				} else if(nextIdx < _dimensions && term !in termIdx) {
					vocabulary[term] = nextIdx.text;
					termIdx[term] = nextIdx;
					termDocFreq[term] = 1;
					seenInDoc[term] = true;
					nextIdx++;
				}
			}
		}

		double n = cast(double)documents.length;
		foreach(term, idx; termIdx) {
			int df = (term in termDocFreq) ? termDocFreq[term] : 1;
			if(df > 0)
				idf[idx] = log(n / cast(double)df) + 1.0;
			else
				idf[idx] = 1.0;
		}
	}

	/**
	 * Add a single term to the vocabulary if space remains.
	 *
	 * Params:
	 *     term = The term to add to the vocabulary.
	 */
	void addToVocabulary(string term)
	{
		if(term !in vocabulary && vocabulary.length < _dimensions) {
			vocabulary[term] = vocabulary.length.text;
		}
	}

	/**
	 * Save the vocabulary and IDF weights to a JSON file.
	 *
	 * Params:
	 *     path = File path to write the JSON output to.
	 *
	 * Throws: `Exception` if the file cannot be written.
	 */
	void save(string path)
	{
		import std.file : write;
		import std.json;

		JSONValue obj;
		obj.object = null;

		JSONValue vocabObj;
		vocabObj.object = null;
		foreach(term, idxStr; vocabulary) {
			vocabObj.object[term] = JSONValue(idxStr);
		}
		obj.object["vocabulary"] = vocabObj;

		JSONValue idfArr;
		idfArr.array = null;
		foreach(i, v; idf) {
			JSONValue val;
			val.floating = v;
			idfArr.array ~= val;
		}
		obj.object["idf"] = idfArr;

		write(path, toJSON(obj, false));
	}

	/**
	 * Load vocabulary and IDF weights from a JSON file.
	 *
	 * Params:
	 *     path = File path to read the JSON vocabulary from.
	 *
	 * Throws: `Exception` on JSON parse errors (caught internally; returns `false`).
	 */
	bool load(string path)
	{
		import std.file : exists, readText;
		import std.json;

		if(!exists(path))
			return false;

		try {
			auto json = parseJSON(readText(path));

			vocabulary = null;
			foreach(term, idxVal; json.object["vocabulary"].object) {
				vocabulary[term] = idxVal.str;
			}

			idf = new double[_dimensions];
			idf[] = 1.0;
			foreach(i, vVal; json.object["idf"].array) {
				if(i < _dimensions)
					idf[i] = vVal.floating;
			}

			return true;
		} catch(Exception) {
			return false;
		}
	}

	private string[] tokenize(string text)
	{
		string[] tokens;

		text = text.toLower;

		auto wordRe = regex(r"[a-z][a-z0-9_]*");

		foreach(match; matchAll(text, wordRe)) {
			string token = match.hit;
			if(token.length >= 2 && token.length <= 20) {
				tokens ~= token;
			}
		}

		return tokens;
	}

	private void normalize(float[] vec)
	{
		float norm = 0.0f;
		foreach(v; vec) {
			norm += v * v;
		}
		norm = sqrt(norm);

		if(norm > 1e-10f) {
			foreach(ref v; vec) {
				v /= norm;
			}
		}
	}
}

version(unittest) {
	private bool isZeroVector(float[] vec)
	{
		foreach(v; vec)
			if(v != 0.0f)
				return false;
		return true;
	}

	private float cosineSimilarity(float[] a, float[] b)
	{
		import std.math : sqrt;

		if(a.length != b.length)
			return 0.0f;

		float dot = 0.0f;
		float normA = 0.0f;
		float normB = 0.0f;

		foreach(i; 0 .. a.length) {
			dot += a[i] * b[i];
			normA += a[i] * a[i];
			normB += b[i] * b[i];
		}

		auto denom = sqrt(normA) * sqrt(normB);
		if(denom < 1e-10f)
			return 0.0f;

		return dot / denom;
	}
}

/// Test basic TF-IDF embedding generation
unittest {
	auto embedder = new TfIdfEmbedder(100);
	assert(embedder.isAvailable());
	assert(embedder.dimensions() == 100);
	assert(embedder.name() == "TF-IDF");

	auto vec = embedder.embed("function test string int array");

	assert(vec.length == 100);
	assert(!isZeroVector(vec));
}

/// Test TF-IDF batch embedding
unittest {
	auto embedder = new TfIdfEmbedder(50);

	string[] texts = [
		"function return void", "class struct interface", "import module package"
	];

	auto vecs = embedder.embedBatch(texts);

	assert(vecs.length == 3);
	foreach(vec; vecs) {
		assert(vec.length == 50);
	}
}

/// Test cosine similarity between embeddings
unittest {
	auto embedder = new TfIdfEmbedder(100);

	auto vec1 = embedder.embed("function string array");
	auto vec2 = embedder.embed("function string list");
	auto vec3 = embedder.embed("class object method");

	auto sim12 = cosineSimilarity(vec1, vec2);
	auto sim13 = cosineSimilarity(vec1, vec3);

	assert(sim12 > sim13, "Similar texts should have higher similarity");
}

/// Test TF-IDF embedding of empty string
unittest {
	auto embedder = new TfIdfEmbedder(50);
	auto vec = embedder.embed("");

	assert(vec.length == 50, "Empty string should still produce correct dimension vector");
	assert(isZeroVector(vec), "Empty string should produce zero vector");
}

/// Test TF-IDF embedding of single known word
unittest {
	auto embedder = new TfIdfEmbedder(100);
	auto vec = embedder.embed("function");

	assert(vec.length == 100);
	assert(!isZeroVector(vec), "Known vocabulary word should produce non-zero vector");
}

/// Test TF-IDF embedding of unknown words
unittest {
	auto embedder = new TfIdfEmbedder(50);
	auto vec = embedder.embed("xyzzy qwerty asdfgh");

	assert(vec.length == 50);
	assert(isZeroVector(vec), "Unknown words should produce zero vector");
}

/// Test TF-IDF vector normalization (unit L2 norm)
unittest {
	import std.math : sqrt, abs;
	import std.conv : text;

	auto embedder = new TfIdfEmbedder(100);
	auto vec = embedder.embed("function return string class struct");

	if(!isZeroVector(vec)) {
		float norm = 0.0f;
		foreach(v; vec)
			norm += v * v;
		norm = sqrt(norm);

		assert(abs(norm - 1.0f) < 0.01f, "Embedding should be L2-normalized, got norm=" ~ text(norm));
	}
}

/// Test TF-IDF deterministic output
unittest {
	auto embedder = new TfIdfEmbedder(100);
	auto vec1 = embedder.embed("function return string");
	auto vec2 = embedder.embed("function return string");

	assert(vec1.length == vec2.length);
	foreach(i; 0 .. vec1.length) {
		assert(vec1[i] == vec2[i], "Same input should produce identical vectors");
	}
}

/// Test TF-IDF different inputs produce different vectors
unittest {
	auto embedder = new TfIdfEmbedder(100);
	auto vec1 = embedder.embed("function return void");
	auto vec2 = embedder.embed("class struct interface");

	bool allSame = true;
	foreach(i; 0 .. vec1.length) {
		if(vec1[i] != vec2[i]) {
			allSame = false;
			break;
		}
	}
	assert(!allSame, "Different inputs should produce different vectors");
}

/// Test TF-IDF dimension parameter is respected
unittest {
	auto small = new TfIdfEmbedder(10);
	assert(small.dimensions() == 10);
	auto vec1 = small.embed("function return");
	assert(vec1.length == 10);

	auto large = new TfIdfEmbedder(500);
	assert(large.dimensions() == 500);
	auto vec2 = large.embed("function return");
	assert(vec2.length == 500);
}

/// Test TF-IDF training changes IDF weights
unittest {
	auto embedder = new TfIdfEmbedder(200);

	auto vecBefore = embedder.embed("function return string");

	string[] corpus = [
		"function return string int", "class struct interface enum",
		"function void auto range", "import module package template",
		"function function function string"
	];
	embedder.train(corpus);

	auto vecAfter = embedder.embed("function return string");

	bool changed = false;
	foreach(i; 0 .. vecBefore.length) {
		if(vecBefore[i] != vecAfter[i]) {
			changed = true;
			break;
		}
	}
	assert(changed, "Training should change IDF weights and produce different vectors");
}

/// Test TF-IDF addToVocabulary
unittest {
	auto embedder = new TfIdfEmbedder(200);

	auto vecBefore = embedder.embed("customterm");
	assert(isZeroVector(vecBefore), "Unknown term should produce zero vector");

	embedder.addToVocabulary("customterm");

	auto vecAfter = embedder.embed("customterm");
	assert(!isZeroVector(vecAfter), "Added term should now produce non-zero vector");
}

/// Test TF-IDF save and load roundtrip
unittest {
	import std.file : exists, remove, tempDir;
	import std.path : buildPath;
	import std.math : abs;

	auto tempVocabPath = buildPath(tempDir(), "test_tfidf_vocab.json");
	scope(exit)
		if(exists(tempVocabPath))
			remove(tempVocabPath);

	auto embedder = new TfIdfEmbedder(100);
	embedder.addToVocabulary("testsaveterm");

	embedder.train(["testsaveterm function return", "class struct"]);

	auto vecOriginal = embedder.embed("function testsaveterm");

	embedder.save(tempVocabPath);
	assert(exists(tempVocabPath), "Save should create the vocabulary file");

	auto embedder2 = new TfIdfEmbedder(100);
	bool loaded = embedder2.load(tempVocabPath);
	assert(loaded, "Load should succeed");

	auto vecLoaded = embedder2.embed("function testsaveterm");

	assert(vecOriginal.length == vecLoaded.length);
	foreach(i; 0 .. vecOriginal.length) {
		assert(abs(vecOriginal[i] - vecLoaded[i]) < 1e-6f,
				"Loaded embedder should produce same vectors");
	}
}

/// Test TF-IDF load non-existent file returns false
unittest {
	auto embedder = new TfIdfEmbedder(50);
	bool loaded = embedder.load("/tmp/definitely_does_not_exist_abc123.json");
	assert(!loaded, "Loading non-existent file should return false");
}

/// Test TF-IDF batch consistency with individual embed
unittest {
	auto embedder = new TfIdfEmbedder(100);

	string[] texts = ["function return void", "class struct", "import module"];

	auto batchVecs = embedder.embedBatch(texts);

	foreach(i, t; texts) {
		auto singleVec = embedder.embed(t);
		assert(singleVec.length == batchVecs[i].length);
		foreach(j; 0 .. singleVec.length) {
			assert(singleVec[j] == batchVecs[i][j],
					"Batch embed should produce same results as individual embed");
		}
	}
}

/// Test TF-IDF vocabulary capacity is respected
unittest {
	auto embedder = new TfIdfEmbedder(5);
	assert(embedder.dimensions() == 5);

	embedder.addToVocabulary("overflow_term_1");
	embedder.addToVocabulary("overflow_term_2");

	auto vec = embedder.embed("function");
	assert(vec.length == 5);
}

/// Test TF-IDF tokenizer is case insensitive
unittest {
	auto embedder = new TfIdfEmbedder(100);

	auto vec1 = embedder.embed("Function Return String");
	auto vec2 = embedder.embed("function return string");

	foreach(i; 0 .. vec1.length) {
		assert(vec1[i] == vec2[i], "Tokenizer should be case-insensitive");
	}
}

/// Test TF-IDF embed batch with empty input
unittest {
	auto embedder = new TfIdfEmbedder(50);
	string[] empty;
	auto vecs = embedder.embedBatch(empty);

	assert(vecs.length == 0, "Empty batch should return empty result");
}
