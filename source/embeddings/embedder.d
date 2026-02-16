/**
 * Embedding interface for converting text into dense vector representations.
 */
module embeddings.embedder;

/**
 * Contract for text embedding backends that convert strings to float vectors.
 *
 * Implementations produce fixed-length numeric vectors suitable for
 * similarity search, clustering, and other downstream tasks.
 */
interface Embedder {
	/**
	 * Embed a single text string into a float vector.
	 *
	 * Params:
	 *     text = The input text to embed.
	 *
	 * Returns: A float array of length `dimensions()` representing the embedding.
	 */
	float[] embed(string text);

	/**
	 * Embed multiple text strings in one call.
	 *
	 * Params:
	 *     texts = An array of input texts to embed.
	 *
	 * Returns: An array of float arrays, one embedding per input text.
	 */
	float[][] embedBatch(string[] texts);

	/**
	 * Returns: The dimensionality of the embedding vectors produced by this backend.
	 */
	int dimensions();

	/**
	 * Returns: `true` if this embedding backend is initialized and ready to produce vectors.
	 */
	bool isAvailable();

	/**
	 * Returns: A human-readable name identifying this embedding backend.
	 */
	string name();
}
