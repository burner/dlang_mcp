/**
 * Storage layer for the D package documentation database.
 *
 * Re-exports the connection, schema, CRUD, and search modules that together
 * provide persistent storage, full-text search, and vector similarity search
 * for D package documentation.
 */
module storage;

public import storage.connection;
public import storage.schema;
public import storage.crud;
public import storage.search;
