/**
 * Singleton embedding manager that selects and delegates to the best available backend.
 */
module embeddings.manager;

import embeddings.embedder;
import embeddings.tfidf_embedder;
import embeddings.onnx_embedder;
import std.stdio;
import std.file;

/**
 * Singleton that manages embedding backends, preferring ONNX when available
 * and falling back to TF-IDF.
 *
 * Use `getInstance()` to obtain the shared instance. The manager automatically
 * selects the best available backend during construction.
 */
class EmbeddingManager {
	private Embedder primary;
	private Embedder fallback;
	private static EmbeddingManager instance;
	private TfIdfEmbedder tfidf;
	private const string VOCAB_PATH = "data/models/tfidf_vocab.json";

	/**
	 * Returns: The singleton `EmbeddingManager` instance, creating it on first access.
	 */
	static EmbeddingManager getInstance()
	{
		if(instance is null) {
			instance = new EmbeddingManager();
		}
		return instance;
	}

	private this()
	{
		tfidf = new TfIdfEmbedder(384);
		fallback = tfidf;
		primary = new OnnxEmbedder("data/models");

		if(!primary.isAvailable()) {
			if(tfidf.load(VOCAB_PATH)) {
				writeln("Loaded TF-IDF vocabulary from ", VOCAB_PATH);
			}
			primary = fallback;
		}

		writeln("Embedding manager initialized: using ", primary.name());
	}

	/**
	 * Embed a single text string using the active backend.
	 *
	 * Params:
	 *     text = The input text to embed.
	 *
	 * Returns: A float array representing the embedding vector.
	 */
	float[] embed(string text)
	{
		return primary.embed(text);
	}

	/**
	 * Embed multiple text strings in one call using the active backend.
	 *
	 * Params:
	 *     texts = An array of input texts to embed.
	 *
	 * Returns: An array of float arrays, one embedding per input text.
	 */
	float[][] embedBatch(string[] texts)
	{
		return primary.embedBatch(texts);
	}

	/**
	 * Returns: The dimensionality of the vectors produced by the active backend.
	 */
	int dimensions()
	{
		return primary.dimensions();
	}

	/**
	 * Returns: `true` if the active embedding backend is operational.
	 */
	bool hasVectorSupport()
	{
		return primary.isAvailable();
	}

	/**
	 * Returns: The human-readable name of the active embedding backend.
	 */
	string embedderName()
	{
		return primary.name();
	}

	/**
	 * Returns: The primary `Embedder` backend currently in use.
	 */
	Embedder getPrimary()
	{
		return primary;
	}

	/**
	 * Train the TF-IDF backend on the given documents and persist the vocabulary.
	 *
	 * Params:
	 *     documents = An array of document strings to train the TF-IDF model on.
	 */
	void trainTfIdf(string[] documents)
	{
		tfidf.train(documents);
		tfidf.save(VOCAB_PATH);
		writeln("TF-IDF vocabulary trained on ", documents.length,
				" documents and saved to ", VOCAB_PATH);
	}

	/**
	 * Reset the singleton instance, allowing a fresh manager to be created on next access.
	 */
	static void reset()
	{
		instance = null;
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
}

/// Test EmbeddingManager singleton and basic embedding
unittest {
	EmbeddingManager.reset();
	auto manager = EmbeddingManager.getInstance();

	assert(manager !is null);
	assert(manager.dimensions() > 0);

	auto vec = manager.embed("test string");

	assert(vec.length == manager.dimensions());
	assert(!isZeroVector(vec));
}
