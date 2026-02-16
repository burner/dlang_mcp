module tests.unit.test_embeddings;

import embeddings.tfidf_embedder;
import embeddings.manager;
import std.stdio;
import std.math;
import std.file : exists, remove, tempDir;
import std.path : buildPath;
import std.conv : text;

class EmbeddingTests
{
    private string tempVocabPath;

    void setUp()
    {
        tempVocabPath = buildPath(tempDir(), "test_tfidf_vocab.json");
        if (exists(tempVocabPath))
            remove(tempVocabPath);
    }

    void tearDown()
    {
        if (exists(tempVocabPath))
            remove(tempVocabPath);
    }

    // ---------------------------------------------------------------
    // Basic TF-IDF tests (original)
    // ---------------------------------------------------------------

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

    // ---------------------------------------------------------------
    // Deeper TF-IDF tests (new)
    // ---------------------------------------------------------------

    void testTfIdfEmptyString()
    {
        auto embedder = new TfIdfEmbedder(50);
        auto vec = embedder.embed("");

        assert(vec.length == 50, "Empty string should still produce correct dimension vector");
        assert(isZeroVector(vec), "Empty string should produce zero vector");

        writeln("  PASS: TF-IDF embed empty string");
    }

    void testTfIdfSingleWord()
    {
        auto embedder = new TfIdfEmbedder(100);
        auto vec = embedder.embed("function");

        assert(vec.length == 100);
        assert(!isZeroVector(vec), "Known vocabulary word should produce non-zero vector");

        writeln("  PASS: TF-IDF embed single word");
    }

    void testTfIdfUnknownWords()
    {
        auto embedder = new TfIdfEmbedder(50);
        // Words not in the pre-seeded vocabulary
        auto vec = embedder.embed("xyzzy qwerty asdfgh");

        assert(vec.length == 50);
        // Unknown words should produce zero vector (they're not in vocabulary)
        assert(isZeroVector(vec), "Unknown words should produce zero vector");

        writeln("  PASS: TF-IDF embed unknown words");
    }

    void testTfIdfNormalization()
    {
        auto embedder = new TfIdfEmbedder(100);
        auto vec = embedder.embed("function return string class struct");

        if (!isZeroVector(vec))
        {
            float norm = 0.0f;
            foreach (v; vec)
                norm += v * v;
            norm = sqrt(norm);

            // L2 norm should be approximately 1.0
            assert(abs(norm - 1.0f) < 0.01f,
                "Embedding should be L2-normalized, got norm=" ~ text(norm));
        }

        writeln("  PASS: TF-IDF normalization (unit L2 norm)");
    }

    void testTfIdfDeterministic()
    {
        auto embedder = new TfIdfEmbedder(100);
        auto vec1 = embedder.embed("function return string");
        auto vec2 = embedder.embed("function return string");

        assert(vec1.length == vec2.length);
        foreach (i; 0 .. vec1.length)
        {
            assert(vec1[i] == vec2[i],
                "Same input should produce identical vectors");
        }

        writeln("  PASS: TF-IDF deterministic output");
    }

    void testTfIdfDifferentInputsDifferentVectors()
    {
        auto embedder = new TfIdfEmbedder(100);
        auto vec1 = embedder.embed("function return void");
        auto vec2 = embedder.embed("class struct interface");

        // They share no vocabulary terms, so should be different
        bool allSame = true;
        foreach (i; 0 .. vec1.length)
        {
            if (vec1[i] != vec2[i])
            {
                allSame = false;
                break;
            }
        }
        assert(!allSame, "Different inputs should produce different vectors");

        writeln("  PASS: TF-IDF different inputs produce different vectors");
    }

    void testTfIdfDimensionRespected()
    {
        // Small dimensions
        auto small = new TfIdfEmbedder(10);
        assert(small.dimensions() == 10);
        auto vec1 = small.embed("function return");
        assert(vec1.length == 10);

        // Large dimensions
        auto large = new TfIdfEmbedder(500);
        assert(large.dimensions() == 500);
        auto vec2 = large.embed("function return");
        assert(vec2.length == 500);

        writeln("  PASS: TF-IDF dimension parameter respected");
    }

    void testTfIdfTraining()
    {
        auto embedder = new TfIdfEmbedder(200);

        // Before training: embed a text
        auto vecBefore = embedder.embed("function return string");

        // Train on a corpus
        string[] corpus = [
            "function return string int",
            "class struct interface enum",
            "function void auto range",
            "import module package template",
            "function function function string"
        ];
        embedder.train(corpus);

        // After training: embed the same text
        auto vecAfter = embedder.embed("function return string");

        // Vectors should differ because IDF weights changed
        bool changed = false;
        foreach (i; 0 .. vecBefore.length)
        {
            if (vecBefore[i] != vecAfter[i])
            {
                changed = true;
                break;
            }
        }
        assert(changed, "Training should change IDF weights and produce different vectors");

        writeln("  PASS: TF-IDF training changes IDF weights");
    }

    void testTfIdfAddToVocabulary()
    {
        auto embedder = new TfIdfEmbedder(200);

        // Before adding: unknown word produces zero contribution
        auto vecBefore = embedder.embed("customterm");
        assert(isZeroVector(vecBefore), "Unknown term should produce zero vector");

        // Add the term
        embedder.addToVocabulary("customterm");

        // After adding: should now produce non-zero vector
        auto vecAfter = embedder.embed("customterm");
        assert(!isZeroVector(vecAfter), "Added term should now produce non-zero vector");

        writeln("  PASS: TF-IDF addToVocabulary");
    }

    void testTfIdfSaveAndLoad()
    {
        setUp();

        auto embedder = new TfIdfEmbedder(100);
        embedder.addToVocabulary("testsaveterm");

        // Train to get non-default IDF weights
        embedder.train(["testsaveterm function return", "class struct"]);

        auto vecOriginal = embedder.embed("function testsaveterm");

        // Save
        embedder.save(tempVocabPath);
        assert(exists(tempVocabPath), "Save should create the vocabulary file");

        // Load into a new embedder
        auto embedder2 = new TfIdfEmbedder(100);
        bool loaded = embedder2.load(tempVocabPath);
        assert(loaded, "Load should succeed");

        auto vecLoaded = embedder2.embed("function testsaveterm");

        // Vectors should be identical after save/load
        assert(vecOriginal.length == vecLoaded.length);
        foreach (i; 0 .. vecOriginal.length)
        {
            assert(abs(vecOriginal[i] - vecLoaded[i]) < 1e-6f,
                "Loaded embedder should produce same vectors");
        }

        tearDown();

        writeln("  PASS: TF-IDF save and load roundtrip");
    }

    void testTfIdfLoadNonExistent()
    {
        auto embedder = new TfIdfEmbedder(50);
        bool loaded = embedder.load("/tmp/definitely_does_not_exist_abc123.json");
        assert(!loaded, "Loading non-existent file should return false");

        writeln("  PASS: TF-IDF load non-existent file");
    }

    void testTfIdfBatchConsistency()
    {
        auto embedder = new TfIdfEmbedder(100);

        string[] texts = [
            "function return void",
            "class struct",
            "import module"
        ];

        // Batch embed
        auto batchVecs = embedder.embedBatch(texts);

        // Individual embed
        foreach (i, t; texts)
        {
            auto singleVec = embedder.embed(t);
            assert(singleVec.length == batchVecs[i].length);
            foreach (j; 0 .. singleVec.length)
            {
                assert(singleVec[j] == batchVecs[i][j],
                    "Batch embed should produce same results as individual embed");
            }
        }

        writeln("  PASS: TF-IDF batch consistency with individual embed");
    }

    void testTfIdfVocabularyCapacity()
    {
        // With very small dimensions, vocabulary should be limited
        auto embedder = new TfIdfEmbedder(5);
        // The pre-seeded vocabulary has ~200 terms, but dimension is 5
        // so only the first 5 should be used
        assert(embedder.dimensions() == 5);

        // Adding beyond capacity should be a no-op
        embedder.addToVocabulary("overflow_term_1");
        embedder.addToVocabulary("overflow_term_2");

        // Embed should still work with correct dimensions
        auto vec = embedder.embed("function");
        assert(vec.length == 5);

        writeln("  PASS: TF-IDF vocabulary capacity respected");
    }

    void testTfIdfCaseInsensitive()
    {
        auto embedder = new TfIdfEmbedder(100);

        // The tokenizer lowercases input, so these should produce the same vector
        auto vec1 = embedder.embed("Function Return String");
        auto vec2 = embedder.embed("function return string");

        foreach (i; 0 .. vec1.length)
        {
            assert(vec1[i] == vec2[i],
                "Tokenizer should be case-insensitive");
        }

        writeln("  PASS: TF-IDF case insensitive");
    }

    void testTfIdfEmbedBatchEmpty()
    {
        auto embedder = new TfIdfEmbedder(50);
        string[] empty;
        auto vecs = embedder.embedBatch(empty);

        assert(vecs.length == 0, "Empty batch should return empty result");

        writeln("  PASS: TF-IDF embed batch empty");
    }

    // ---------------------------------------------------------------
    // Runner
    // ---------------------------------------------------------------

    void runAll()
    {
        writeln("\n=== Running Embedding Tests ===");

        // Original tests
        testTfIdfEmbedding();
        testTfIdfBatchEmbedding();
        testEmbeddingManager();
        testCosineSimilarity();

        // New deeper tests
        testTfIdfEmptyString();
        testTfIdfSingleWord();
        testTfIdfUnknownWords();
        testTfIdfNormalization();
        testTfIdfDeterministic();
        testTfIdfDifferentInputsDifferentVectors();
        testTfIdfDimensionRespected();
        testTfIdfTraining();
        testTfIdfAddToVocabulary();
        testTfIdfSaveAndLoad();
        testTfIdfLoadNonExistent();
        testTfIdfBatchConsistency();
        testTfIdfVocabularyCapacity();
        testTfIdfCaseInsensitive();
        testTfIdfEmbedBatchEmpty();

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
