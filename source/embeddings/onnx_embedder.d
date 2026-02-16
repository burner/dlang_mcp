/**
 * ONNX Runtime embedding backend for neural text embedding models.
 */
module embeddings.onnx_embedder;

import embeddings.embedder;
import embeddings.tfidf_embedder;
import std.file;
import std.path;
import std.stdio;
import std.string;
import std.conv;
import std.math;
import std.regex;
import std.algorithm;
import std.array;
import std.json;

import bindbc.onnxruntime;
import core.stdc.stdlib;
import core.stdc.string;

version(Windows) {
	import std.utf;

	private wchar_t* toORTCharZ(string s)
	{
		auto dstr = s.toUTF32;
		auto result = cast(wchar_t*)malloc((dstr.length + 1) * wchar_t.sizeof);
		if(result is null)
			return null;
		foreach(i, c; dstr) {
			result[i] = cast(wchar_t)c;
		}
		result[dstr.length] = 0;
		return result;
	}

	private void freeORTCharPath(wchar_t* p)
	{
		free(p);
	}
} else {
	private alias ORTCHAR_T = char;

	private ORTCHAR_T* toORTCharZ(string s)
	{
		auto result = cast(ORTCHAR_T*)malloc(s.length + 1);
		if(result is null)
			return null;
		foreach(i, c; s) {
			result[i] = cast(ORTCHAR_T)c;
		}
		result[s.length] = 0;
		return result;
	}

	private void freeORTCharPath(ORTCHAR_T* p)
	{
		free(p);
	}
}

/**
 * Generates dense vector embeddings using an ONNX transformer model via the ONNX Runtime C API.
 *
 * If the ONNX model or runtime is unavailable, the embedder transparently
 * falls back to a TF-IDF backend so callers always receive valid vectors.
 */
class OnnxEmbedder : Embedder {
	private string modelPath;
	private string vocabPath;
	private int _dimensions = 384;
	private bool _available = false;
	private TfIdfEmbedder fallback;

	private OrtEnv* env;
	private OrtSession* session;
	private OrtSessionOptions* sessionOptions;
	private OrtAllocator* allocator;
	private const(OrtApi)* ort;

	private string[string] vocab;
	private string[] idToToken;
	private int maxSeqLength = 128;
	private int[128][2] specialTokens;
	private int clsTokenId = 101;
	private int sepTokenId = 102;
	private int padTokenId = 0;
	private int unkTokenId = 100;

	/**
	 * Construct an ONNX embedder, loading the model from the given directory.
	 *
	 * Params:
	 *     modelDir = Directory containing `model.onnx` and `vocab.txt` (or `tokenizer.json`).
	 */
	this(string modelDir = "data/models")
	{
		this.modelPath = buildPath(modelDir, "model.onnx");
		this.vocabPath = buildPath(modelDir, "vocab.txt");

		fallback = new TfIdfEmbedder(384);

		if(!exists(modelPath)) {
			stderr.writeln("ONNX model not found at ", modelPath, ", using TF-IDF fallback");
			return;
		}

		if(tryLoadModel()) {
			_available = true;
			writeln("ONNX embedder loaded successfully");
		} else {
			stderr.writeln("Failed to initialize ONNX Runtime, using TF-IDF fallback");
		}
	}

	/** Release the ONNX Runtime session and associated resources. */
	~this()
	{
		releaseSession();
	}

	private bool tryLoadModel()
	{
		auto support = loadONNXRuntime();
		if(support == ONNXRuntimeSupport.noLibrary || support == ONNXRuntimeSupport.badLibrary) {
			stderr.writeln("ONNX Runtime library not found");
			return false;
		}

		ort = OrtGetApiBase().GetApi(ORT_API_VERSION);
		if(ort is null) {
			stderr.writeln("Failed to get ONNX Runtime API");
			return false;
		}

		OrtStatus* status;

		status = ort.CreateEnv(OrtLoggingLevel.ORT_LOGGING_LEVEL_WARNING, "dlang_mcp", &env);
		if(status !is null) {
			stderr.writeln("Failed to create ONNX env: ", ort.GetErrorMessage(status).to!string());
			ort.ReleaseStatus(status);
			return false;
		}

		status = ort.CreateSessionOptions(&sessionOptions);
		if(status !is null) {
			ort.ReleaseStatus(status);
			ort.ReleaseEnv(env);
			env = null;
			return false;
		}

		ort.SetIntraOpNumThreads(sessionOptions, 1);
		ort.SetSessionGraphOptimizationLevel(sessionOptions,
				GraphOptimizationLevel.ORT_ENABLE_BASIC);

		auto modelPathORT = toORTCharZ(modelPath);
		if(modelPathORT is null) {
			stderr.writeln("Failed to convert model path");
			ort.ReleaseSessionOptions(sessionOptions);
			ort.ReleaseEnv(env);
			env = null;
			sessionOptions = null;
			return false;
		}

		scope(exit)
			freeORTCharPath(modelPathORT);

		status = ort.CreateSession(env, cast(const(wchar_t)*)modelPathORT,
				sessionOptions, &session);
		if(status !is null) {
			stderr.writeln("Failed to create ONNX session: ",
					ort.GetErrorMessage(status).to!string());
			ort.ReleaseStatus(status);
			ort.ReleaseSessionOptions(sessionOptions);
			ort.ReleaseEnv(env);
			env = null;
			sessionOptions = null;
			return false;
		}

		status = ort.GetAllocatorWithDefaultOptions(&allocator);
		if(status !is null) {
			stderr.writeln("Failed to get allocator");
			ort.ReleaseStatus(status);
			releaseSession();
			return false;
		}

		if(!loadVocabulary()) {
			stderr.writeln("Warning: Could not load vocabulary, using fallback tokenization");
		}

		return true;
	}

	private bool loadVocabulary()
	{
		if(!exists(vocabPath)) {
			auto vocabJsonPath = vocabPath.dirName.buildPath("tokenizer.json");
			if(exists(vocabJsonPath))
				return loadVocabularyFromJson(vocabJsonPath);
			return false;
		}

		try {
			auto lines = readText(vocabPath).splitLines();
			idToToken = new string[lines.length];
			foreach(i, line; lines) {
				auto token = line.chomp();
				vocab[token] = i.text;
				idToToken[i] = token;
			}
			writeln("Loaded vocabulary: ", vocab.length, " tokens");
			return true;
		} catch(Exception e) {
			stderr.writeln("Error loading vocabulary: ", e.msg);
			return false;
		}
	}

	private bool loadVocabularyFromJson(string path)
	{
		try {
			auto json = parseJSON(readText(path));

			if("model" !in json.object)
				return false;
			if("vocab" !in json.object["model"].object)
				return false;

			auto vocabObj = json.object["model"].object["vocab"].object;
			idToToken = new string[vocabObj.length];

			foreach(token, idVal; vocabObj) {
				int id = cast(int)idVal.integer;
				vocab[token] = id.text;
				if(id >= 0 && id < idToToken.length)
					idToToken[id] = token;
			}

			writeln("Loaded vocabulary from JSON: ", vocab.length, " tokens");
			return true;
		} catch(Exception e) {
			stderr.writeln("Error loading vocabulary from JSON: ", e.msg);
			return false;
		}
	}

	private void releaseSession()
	{
		if(session !is null) {
			ort.ReleaseSession(session);
			session = null;
		}
		if(sessionOptions !is null) {
			ort.ReleaseSessionOptions(sessionOptions);
			sessionOptions = null;
		}
		if(env !is null) {
			ort.ReleaseEnv(env);
			env = null;
		}
	}

	/**
	 * Embed a single text string using the ONNX model.
	 *
	 * Falls back to TF-IDF if the ONNX session is not available.
	 *
	 * Params:
	 *     text = The input text to embed.
	 *
	 * Returns: A normalized float array representing the embedding vector.
	 */
	float[] embed(string text)
	{
		if(!_available || session is null) {
			return fallback.embed(text);
		}

		OrtStatus* status;

		auto tokens = tokenize(text);
		auto inputIds = convertToIds(tokens);

		int seqLen = inputIds.length > maxSeqLength ? maxSeqLength : cast(int)inputIds.length;

		long[] inputIdsArr = new long[seqLen];
		long[] attentionMaskArr = new long[seqLen];
		long[] tokenTypeIdsArr = new long[seqLen];
		attentionMaskArr[] = 1;
		tokenTypeIdsArr[] = 0;

		foreach(i; 0 .. seqLen) {
			inputIdsArr[i] = inputIds[i];
		}

		long[] shape = [1, seqLen];

		OrtMemoryInfo* memoryInfo;
		status = ort.CreateCpuMemoryInfo(OrtAllocatorType.OrtArenaAllocator,
				OrtMemType.OrtMemTypeDefault, &memoryInfo);
		if(status !is null) {
			ort.ReleaseStatus(status);
			return fallback.embed(text);
		}

		OrtValue* inputIdsTensor;
		status = ort.CreateTensorWithDataAsOrtValue(memoryInfo, inputIdsArr.ptr, seqLen * long.sizeof, shape.ptr, 2,
				ONNXTensorElementDataType.ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &inputIdsTensor);
		if(status !is null) {
			ort.ReleaseMemoryInfo(memoryInfo);
			ort.ReleaseStatus(status);
			return fallback.embed(text);
		}

		OrtValue* attentionMaskTensor;
		status = ort.CreateTensorWithDataAsOrtValue(memoryInfo,
				attentionMaskArr.ptr, seqLen * long.sizeof, shape.ptr, 2,
				ONNXTensorElementDataType.ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64,
				&attentionMaskTensor);
		if(status !is null) {
			ort.ReleaseValue(inputIdsTensor);
			ort.ReleaseMemoryInfo(memoryInfo);
			ort.ReleaseStatus(status);
			return fallback.embed(text);
		}

		OrtValue* tokenTypeIdsTensor;
		status = ort.CreateTensorWithDataAsOrtValue(memoryInfo, tokenTypeIdsArr.ptr, seqLen * long.sizeof, shape.ptr, 2,
				ONNXTensorElementDataType.ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &tokenTypeIdsTensor);
		ort.ReleaseMemoryInfo(memoryInfo);
		if(status !is null) {
			ort.ReleaseValue(inputIdsTensor);
			ort.ReleaseValue(attentionMaskTensor);
			ort.ReleaseStatus(status);
			return fallback.embed(text);
		}

		char* inputName1;
		char* inputName2;
		char* inputName3;
		ort.SessionGetInputName(session, 0, allocator, &inputName1);
		ort.SessionGetInputName(session, 1, allocator, &inputName2);
		ort.SessionGetInputName(session, 2, allocator, &inputName3);

		const(char)*[] inputNames = [inputName1, inputName2, inputName3];
		OrtValue*[] inputTensors = [
			inputIdsTensor, attentionMaskTensor, tokenTypeIdsTensor
		];

		char* outputName;
		ort.SessionGetOutputName(session, 0, allocator, &outputName);
		const(char)*[] outputNames = [outputName];

		OrtValue* outputTensor;
		status = ort.Run(session, null, inputNames.ptr, inputTensors.ptr, 3,
				outputNames.ptr, 1, &outputTensor);

		ort.ReleaseValue(inputIdsTensor);
		ort.ReleaseValue(attentionMaskTensor);
		ort.ReleaseValue(tokenTypeIdsTensor);

		if(status !is null) {
			ort.ReleaseStatus(status);
			return fallback.embed(text);
		}

		float* outputData;
		status = ort.GetTensorMutableData(outputTensor, cast(void**)&outputData);
		if(status !is null) {
			ort.ReleaseValue(outputTensor);
			ort.ReleaseStatus(status);
			return fallback.embed(text);
		}

		OrtTensorTypeAndShapeInfo* outputInfo;
		status = ort.GetTensorTypeAndShape(outputTensor, &outputInfo);
		if(status !is null) {
			ort.ReleaseValue(outputTensor);
			ort.ReleaseStatus(status);
			return fallback.embed(text);
		}

		size_t dimsCount;
		ort.GetDimensionsCount(outputInfo, &dimsCount);

		long[] dims = new long[dimsCount];
		ort.GetDimensions(outputInfo, dims.ptr, dimsCount);
		ort.ReleaseTensorTypeAndShapeInfo(outputInfo);

		float[] embedding;

		if(dimsCount == 3) {
			int hiddenSize = cast(int)dims[2];
			embedding = new float[hiddenSize];
			embedding[] = 0.0f;

			foreach(i; 0 .. seqLen) {
				foreach(j; 0 .. hiddenSize) {
					embedding[j] += outputData[i * hiddenSize + j];
				}
			}

			foreach(ref v; embedding) {
				v /= seqLen;
			}
		} else if(dimsCount == 2) {
			int hiddenSize = cast(int)dims[1];
			embedding = outputData[0 .. hiddenSize].dup;
		} else {
			ort.ReleaseValue(outputTensor);
			return fallback.embed(text);
		}

		ort.ReleaseValue(outputTensor);

		normalize(embedding);

		return embedding;
	}

	/**
	 * Embed multiple text strings in one call.
	 *
	 * Falls back to TF-IDF if the ONNX session is not available.
	 *
	 * Params:
	 *     texts = An array of input texts to embed.
	 *
	 * Returns: An array of float arrays, one embedding per input text.
	 */
	float[][] embedBatch(string[] texts)
	{
		if(!_available || session is null) {
			return fallback.embedBatch(texts);
		}

		float[][] results = new float[][](texts.length);
		foreach(i, text; texts) {
			results[i] = embed(text);
		}
		return results;
	}

	/**
	 * Returns: The dimensionality of the embedding vectors (typically 384).
	 */
	int dimensions()
	{
		return _dimensions;
	}

	/**
	 * Returns: `true` if the ONNX model was loaded successfully and is ready for inference.
	 */
	bool isAvailable()
	{
		return _available;
	}

	/**
	 * Returns: `"ONNX"` when the model is available, or `"TF-IDF (fallback)"` otherwise.
	 */
	string name()
	{
		return _available ? "ONNX" : "TF-IDF (fallback)";
	}

	private string[] tokenize(string text)
	{
		if(vocab.length == 0) {
			return simpleTokenize(text);
		}

		text = text.toLower();
		text = text.replace("_", " ");

		auto wordRe = regex(r"[a-z][a-z0-9]*|[0-9]+|[^a-z0-9\s]");
		string[] tokens;

		foreach(match; matchAll(text, wordRe)) {
			string word = match.hit;
			if(word in vocab) {
				tokens ~= word;
			} else {
				auto subTokens = wordpieceTokenize(word);
				tokens ~= subTokens;
			}
		}

		return tokens;
	}

	private string[] simpleTokenize(string text)
	{
		text = text.toLower();
		text = text.replace("_", " ");
		text = text.replace("/", " ");
		text = text.replace(".", " ");

		auto wordRe = regex(r"[a-z][a-z0-9]*");
		string[] tokens;

		foreach(match; matchAll(text, wordRe)) {
			string token = match.hit;
			if(token.length >= 2) {
				tokens ~= token;
			}
		}

		return tokens;
	}

	private string[] wordpieceTokenize(string word)
	{
		string[] tokens;

		if(word in vocab) {
			tokens ~= word;
			return tokens;
		}

		string remaining = word;
		while(remaining.length > 0) {
			bool found = false;
			for(int len = cast(int)remaining.length; len > 0; len--) {
				string candidate = remaining[0 .. len];
				if(tokens.length > 0)
					candidate = "##" ~ candidate;

				if(candidate in vocab) {
					tokens ~= candidate;
					remaining = remaining[len .. $];
					found = true;
					break;
				}
			}

			if(!found) {
				tokens ~= "[UNK]";
				break;
			}
		}

		return tokens;
	}

	private int[] convertToIds(string[] tokens)
	{
		int[] ids = new int[tokens.length + 2];
		ids[0] = clsTokenId;

		foreach(i, token; tokens) {
			if(i >= maxSeqLength - 2)
				break;

			if(token in vocab) {
				ids[i + 1] = vocab[token].to!int;
			} else {
				ids[i + 1] = unkTokenId;
			}
		}

		ids[tokens.length + 1] = sepTokenId;

		return ids[0 .. min(tokens.length + 2, maxSeqLength)];
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
