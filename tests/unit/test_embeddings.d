module tests.unit.test_embeddings;

import embeddings.tfidf_embedder;
import embeddings.manager;
import std.stdio;
import std.math;

class EmbeddingTests
{
    void testTfIdfEmbedding()
    {
        auto embedder = new TfIdfEmbedder(100);
        assert(embedder.isAvailable());
        assert(embedder.dimensions() == 100);
        assert(embedder.name() == "TF-IDF");

        auto vec = embedder.embed("function test string int array");

        assert(vec.length == 100);
        assert(!isZeroVector(vec));

        writeln("  PASS: TF-IDF embedding generation");
    }

    void testTfIdfBatchEmbedding()
    {
        auto embedder = new TfIdfEmbedder(50);

        string[] texts = [
            "function return void",
            "class struct interface",
            "import module package"
        ];

        auto vecs = embedder.embedBatch(texts);

        assert(vecs.length == 3);
        foreach (vec; vecs)
        {
            assert(vec.length == 50);
        }

        writeln("  PASS: TF-IDF batch embedding");
    }

    void testEmbeddingManager()
    {
        EmbeddingManager.reset();
        auto manager = EmbeddingManager.getInstance();

        assert(manager !is null);
        assert(manager.dimensions() > 0);

        auto vec = manager.embed("test string");

        assert(vec.length == manager.dimensions());
        assert(!isZeroVector(vec));

        writeln("  PASS: Embedding manager");
    }

    void testCosineSimilarity()
    {
        auto embedder = new TfIdfEmbedder(100);

        auto vec1 = embedder.embed("function string array");
        auto vec2 = embedder.embed("function string list");
        auto vec3 = embedder.embed("class object method");

        auto sim12 = cosineSimilarity(vec1, vec2);
        auto sim13 = cosineSimilarity(vec1, vec3);

        assert(sim12 > sim13, "Similar texts should have higher similarity");

        writeln("  PASS: Cosine similarity");
    }

    void runAll()
    {
        writeln("\n=== Running Embedding Tests ===");

        testTfIdfEmbedding();
        testTfIdfBatchEmbedding();
        testEmbeddingManager();
        testCosineSimilarity();

        writeln("=== Embedding Tests Complete ===");
    }

private:
    bool isZeroVector(float[] vec)
    {
        foreach (v; vec)
        {
            if (v != 0.0f)
                return false;
        }
        return true;
    }

    float cosineSimilarity(float[] a, float[] b)
    {
        if (a.length != b.length)
            return 0.0f;

        float dot = 0.0f;
        float normA = 0.0f;
        float normB = 0.0f;

        foreach (i; 0 .. a.length)
        {
            dot += a[i] * b[i];
            normA += a[i] * a[i];
            normB += b[i] * b[i];
        }

        auto denom = sqrt(normA) * sqrt(normB);
        if (denom < 1e-10f)
            return 0.0f;

        return dot / denom;
    }
}