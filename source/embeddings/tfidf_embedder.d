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
