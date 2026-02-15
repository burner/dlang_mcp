module embeddings.manager;

import embeddings.embedder;
import embeddings.tfidf_embedder;
import embeddings.onnx_embedder;
import std.stdio;
import std.file;

class EmbeddingManager
{
    private Embedder primary;
    private Embedder fallback;
    private static EmbeddingManager instance;
    private TfIdfEmbedder tfidf;
    private const string VOCAB_PATH = "data/models/tfidf_vocab.json";

    static EmbeddingManager getInstance()
    {
        if (instance is null)
        {
            instance = new EmbeddingManager();
        }
        return instance;
    }

    private this()
    {
        tfidf = new TfIdfEmbedder(384);
        fallback = tfidf;
        primary = new OnnxEmbedder("data/models");

        if (!primary.isAvailable())
        {
            if (tfidf.load(VOCAB_PATH))
            {
                writeln("Loaded TF-IDF vocabulary from ", VOCAB_PATH);
            }
            primary = fallback;
        }

        writeln("Embedding manager initialized: using ", primary.name());
    }

    float[] embed(string text)
    {
        return primary.embed(text);
    }

    float[][] embedBatch(string[] texts)
    {
        return primary.embedBatch(texts);
    }

    int dimensions()
    {
        return primary.dimensions();
    }

    bool hasVectorSupport()
    {
        return primary.isAvailable();
    }

    string embedderName()
    {
        return primary.name();
    }

    Embedder getPrimary()
    {
        return primary;
    }

    void trainTfIdf(string[] documents)
    {
        tfidf.train(documents);
        tfidf.save(VOCAB_PATH);
        writeln("TF-IDF vocabulary trained on ", documents.length, " documents and saved to ", VOCAB_PATH);
    }

    static void reset()
    {
        instance = null;
    }
}