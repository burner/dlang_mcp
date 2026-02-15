module tests.unit.test_storage;

import storage.connection;
import storage.schema;
import storage.crud;
import models;
import std.stdio;
import std.file;
import std.exception;
import std.algorithm;

class StorageTests
{
    private DBConnection conn;
    private SchemaManager schema;
    private CRUDOperations crud;
    private string testDbPath = "test_db.sqlite";

    void setUp()
    {
        if (exists(testDbPath))
        {
            remove(testDbPath);
        }

        conn = new DBConnection(testDbPath);
        schema = new SchemaManager(conn);
        crud = new CRUDOperations(conn);

        schema.initializeSchema();
    }

    void tearDown()
    {
        if (conn !is null)
        {
            conn.close();
        }
        if (exists(testDbPath))
        {
            remove(testDbPath);
        }
    }

    void testDatabaseCreation()
    {
        assert(exists(testDbPath), "Database file should exist");
        writeln("  PASS: Database creation");
    }

    void testSchemaInitialization()
    {
        auto stmt = conn.prepare("
            SELECT name FROM sqlite_master 
            WHERE type='table' 
            ORDER BY name
        ");
        auto result = stmt.execute();

        string[] tables;
        foreach (row; result)
        {
            tables ~= row["name"].as!string;
        }

        assert(tables.canFind("packages"), "packages table should exist");
        assert(tables.canFind("modules"), "modules table should exist");
        assert(tables.canFind("functions"), "functions table should exist");
        assert(tables.canFind("types"), "types table should exist");
        assert(tables.canFind("code_examples"), "code_examples table should exist");

        writeln("  PASS: Schema initialization");
    }

    void testPackageCRUD()
    {
        PackageMetadata pkg;
        pkg.name = "test-package";
        pkg.version_ = "1.0.0";
        pkg.description = "A test package";
        pkg.license = "MIT";
        pkg.authors = ["Test Author"];
        pkg.tags = ["test", "example"];

        long pkgId = crud.insertPackage(pkg);
        assert(pkgId > 0, "Package ID should be positive");

        auto retrieved = crud.getPackage("test-package");
        assert(retrieved.name == pkg.name);
        assert(retrieved.version_ == pkg.version_);
        assert(retrieved.description == pkg.description);

        writeln("  PASS: Package CRUD");
    }

    void testModuleCRUD()
    {
        PackageMetadata pkg;
        pkg.name = "test-pkg";
        pkg.version_ = "1.0.0";
        long pkgId = crud.insertPackage(pkg);

        ModuleDoc mod;
        mod.name = "test.module.example";
        mod.packageName = "test-pkg";
        mod.docComment = "Test module";

        long modId = crud.insertModule(pkgId, mod);
        assert(modId > 0, "Module ID should be positive");

        long retrievedId = crud.getModuleId("test.module.example");
        assert(retrievedId == modId);

        writeln("  PASS: Module CRUD");
    }

    void testFunctionCRUD()
    {
        PackageMetadata pkg;
        pkg.name = "test-pkg";
        pkg.version_ = "1.0.0";
        long pkgId = crud.insertPackage(pkg);

        ModuleDoc mod;
        mod.name = "test.module";
        long modId = crud.insertModule(pkgId, mod);

        FunctionDoc func;
        func.name = "testFunction";
        func.fullyQualifiedName = "test.module.testFunction";
        func.signature = "void testFunction(int x)";
        func.returnType = "void";
        func.docComment = "A test function";
        func.parameters = ["int x"];
        func.isTemplate = false;
        func.performance.isNogc = true;
        func.performance.isPure = true;

        long funcId = crud.insertFunction(modId, func);
        assert(funcId > 0, "Function ID should be positive");

        auto retrieved = crud.getFunction(funcId);
        assert(retrieved.name == func.name);
        assert(retrieved.signature == func.signature);
        assert(retrieved.performance.isNogc);
        assert(retrieved.performance.isPure);

        writeln("  PASS: Function CRUD");
    }

    void testCodeExamples()
    {
        PackageMetadata pkg;
        pkg.name = "test-pkg";
        pkg.version_ = "1.0.0";
        long pkgId = crud.insertPackage(pkg);

        ModuleDoc mod;
        mod.name = "test.module";
        long modId = crud.insertModule(pkgId, mod);

        FunctionDoc func;
        func.name = "testFunc";
        func.fullyQualifiedName = "test.module.testFunc";
        long funcId = crud.insertFunction(modId, func);

        CodeExample example;
        example.functionId = funcId;
        example.code = "testFunc(42);";
        example.description = "Basic usage";
        example.isRunnable = true;
        example.isUnittest = false;
        example.requiredImports = ["test.module"];

        long exId = crud.insertCodeExample(example);
        assert(exId > 0, "Example ID should be positive");

        auto examples = crud.getCodeExamplesForFunction(funcId);
        assert(examples.length == 1);
        assert(examples[0].code == example.code);

        writeln("  PASS: Code examples");
    }

    void testStatistics()
    {
        PackageMetadata pkg;
        pkg.name = "pkg1";
        pkg.version_ = "1.0.0";
        crud.insertPackage(pkg);

        pkg.name = "pkg2";
        crud.insertPackage(pkg);

        auto stats = crud.getStats();
        assert(stats.packageCount == 2);

        writeln("  PASS: Statistics");
    }

    void runAll()
    {
        writeln("\n=== Running Storage Tests ===");

        setUp();
        scope(exit) tearDown();

        testDatabaseCreation();
        testSchemaInitialization();

        tearDown();
        setUp();
        testPackageCRUD();

        tearDown();
        setUp();
        testModuleCRUD();

        tearDown();
        setUp();
        testFunctionCRUD();

        tearDown();
        setUp();
        testCodeExamples();

        tearDown();
        setUp();
        testStatistics();

        writeln("=== Storage Tests Complete ===");
    }
}