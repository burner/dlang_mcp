module embeddings.embedder;

interface Embedder
{
    float[] embed(string text);
    float[][] embedBatch(string[] texts);
    int dimensions();
    bool isAvailable();
    string name();
}