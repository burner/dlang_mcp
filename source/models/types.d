/**
 * Domain model types for the D language documentation and search system.
 *
 * Defines the data structures used to represent packages, modules, functions,
 * types, code examples, and search results throughout the ingestion pipeline,
 * storage layer, and search tools.
 */
module models.types;

import std.json;
import std.algorithm;
import std.array;
import std.conv;

/** Metadata for a D package from the DUB registry. */
struct PackageMetadata {
	string name; /// The package name (e.g. "vibe-d").
	string version_; /// The latest or specified version string.
	string description; /// Brief description of the package.
	string repository; /// URL of the source repository.
	string homepage; /// URL of the project homepage.
	string license; /// License identifier (e.g. "MIT", "BSL-1.0").
	string[] authors; /// List of package authors.
	string[] tags; /// Categorization tags.

	/**
	 * Serializes this package metadata to a JSON object.
	 *
	 * Only includes non-empty fields in the output.
	 *
	 * Returns: A `JSONValue` containing the package metadata.
	 */
	JSONValue toJSON() const
	{
		JSONValue[string] obj;
		obj["name"] = JSONValue(name);
		obj["version"] = JSONValue(version_);
		if(description.length > 0)
			obj["description"] = JSONValue(description);
		if(repository.length > 0)
			obj["repository"] = JSONValue(repository);
		if(homepage.length > 0)
			obj["homepage"] = JSONValue(homepage);
		if(license.length > 0)
			obj["license"] = JSONValue(license);
		if(authors.length > 0) {
			JSONValue[] arr;
			foreach(a; authors)
				arr ~= JSONValue(a);
			obj["authors"] = JSONValue(arr);
		}
		if(tags.length > 0) {
			JSONValue[] arr;
			foreach(t; tags)
				arr ~= JSONValue(t);
			obj["tags"] = JSONValue(arr);
		}
		return JSONValue(obj);
	}

	/**
	 * Deserializes package metadata from a DUB registry JSON response.
	 *
	 * Handles both flat JSON objects and nested `info` objects as returned
	 * by different DUB API endpoints.
	 *
	 * Params:
	 *     json = The JSON object to parse.
	 *
	 * Returns: A populated `PackageMetadata` struct.
	 */
	static PackageMetadata fromJSON(JSONValue json)
	{
		PackageMetadata pkg;

		JSONValue info;
		if("info" in json.object && json["info"].type == JSONType.object) {
			info = json["info"];
		} else {
			info = json;
		}

		if("name" in info.object && info["name"].type == JSONType.string)
			pkg.name = info["name"].str;
		if("version" in json.object && json["version"].type == JSONType.string)
			pkg.version_ = json["version"].str;
		else if("version" in info.object && info["version"].type == JSONType.string)
			pkg.version_ = info["version"].str;
		else if("version" in info.object && info["version"].type == JSONType.integer)
			pkg.version_ = text(info["version"].integer);
		if("description" in info.object && info["description"].type == JSONType.string)
			pkg.description = info["description"].str;
		if("repository" in info.object && info["repository"].type == JSONType.string)
			pkg.repository = info["repository"].str;
		if("homepage" in info.object && info["homepage"].type == JSONType.string)
			pkg.homepage = info["homepage"].str;
		if("license" in info.object && info["license"].type == JSONType.string)
			pkg.license = info["license"].str;
		if("authors" in info.object && info["authors"].type == JSONType.array)
			pkg.authors = info["authors"].array.map!(j => j.str).array;
		if("tags" in info.object && info["tags"].type == JSONType.array)
			pkg.tags = info["tags"].array.map!(j => j.str).array;
		return pkg;
	}
}

/** Documentation for a D module, including its contained functions and types. */
struct ModuleDoc {
	string name; /// Fully qualified module name (e.g. "std.algorithm.searching").
	string packageName; /// The package this module belongs to.
	string docComment; /// The module-level documentation comment.
	FunctionDoc[] functions; /// Documented functions in this module.
	TypeDoc[] types; /// Documented types (classes, structs, etc.) in this module.
}

/** Documentation for a D function or method. */
struct FunctionDoc {
	string name; /// The unqualified function name.
	string fullyQualifiedName; /// Full path including module (e.g. "std.algorithm.find").
	string moduleName; /// The module containing this function.
	string packageName; /// The package containing this function.
	string signature; /// The full function signature string.
	string returnType; /// The return type as a string.
	string[] parameters; /// List of parameter names or declarations.
	string docComment; /// The DDoc documentation comment.
	string[] examples; /// Code examples extracted from documentation or unittests.
	bool isTemplate; /// Whether this is a template function.
	TemplateConstraint[] constraints; /// Template constraints, if any.
	PerformanceInfo performance; /// Performance characteristics and attributes.
}

/** Documentation for a D type (class, struct, interface, or enum). */
struct TypeDoc {
	string name; /// The unqualified type name.
	string fullyQualifiedName; /// Full path including module.
	string moduleName; /// The module containing this type.
	string packageName; /// The package containing this type.
	string kind; /// The type kind: "class", "struct", "interface", or "enum".
	string docComment; /// The DDoc documentation comment.
	FunctionDoc[] methods; /// Documented methods belonging to this type.
	string[] baseClasses; /// Base classes this type inherits from.
	string[] interfaces; /// Interfaces this type implements.
}

/** A code example associated with a function, type, or package. */
struct CodeExample {
	string code; /// The example source code.
	string description; /// A brief description of what the example demonstrates.
	string[] requiredImports; /// Import statements needed to run this example.
	bool isRunnable; /// Whether this example can be compiled and run standalone.
	bool isUnittest; /// Whether this example was extracted from a unittest block.
	long functionId; /// Database ID of the associated function, or 0 if none.
	long typeId; /// Database ID of the associated type, or 0 if none.
	long packageId; /// Database ID of the associated package, or 0 if none.
}

/** A template parameter constraint extracted from a template declaration. */
struct TemplateConstraint {
	string parameterName; /// The template parameter this constraint applies to.
	string constraintText; /// The textual representation of the constraint.
	string[] requiredTraits; /// Traits required by this constraint (e.g. "isInputRange").
}

/** Performance characteristics and compile-time attributes of a function. */
struct PerformanceInfo {
	string timeComplexity; /// Big-O time complexity (e.g. "O(n log n)").
	string spaceComplexity; /// Big-O space complexity.
	bool allocatesMemory; /// Whether the function allocates GC or heap memory.
	bool isNogc; /// Whether the function is marked `@nogc`.
	bool isNothrow; /// Whether the function is marked `nothrow`.
	bool isPure; /// Whether the function is marked `pure`.
	bool isSafe; /// Whether the function is marked `@safe`.
}

/** A directed relationship between two functions (e.g. "calls", "overrides"). */
struct FunctionRelationship {
	long fromFunctionId; /// Database ID of the source function.
	long toFunctionId; /// Database ID of the target function.
	string relationshipType; /// The type of relationship (e.g. "calls", "similar_to").
	float weight; /// Strength of the relationship, from 0.0 to 1.0.
}

/** A common usage pattern mined from code analysis. */
struct UsagePattern {
	string name; /// Short name for this pattern.
	string description; /// Human-readable description of the pattern.
	string[] functionIds; /// IDs of functions involved in this pattern.
	string codeTemplate; /// A template showing how the pattern is typically used.
	string useCase; /// The problem this pattern solves.
}

/** A single search result returned by the hybrid search engine. */
struct SearchResult {
	long id; /// Database ID of the matched entity.
	string name; /// The unqualified name of the matched entity.
	string fullyQualifiedName; /// Full path including module and package.
	string signature; /// Function signature or type declaration.
	string docComment; /// The documentation comment of the matched entity.
	string packageName; /// The package containing the matched entity.
	string moduleName; /// The module containing the matched entity.
	float rank; /// The relevance score, higher is better.
}

// -- Unit Tests --

/// Test PackageMetadata.toJSON with all fields populated
unittest {
	import std.format : format;

	PackageMetadata pkg;
	pkg.name = "test-pkg";
	pkg.version_ = "1.0.0";
	pkg.description = "A test package";
	pkg.repository = "https://github.com/test/pkg";
	pkg.homepage = "https://test-pkg.org";
	pkg.license = "MIT";
	pkg.authors = ["Alice", "Bob"];
	pkg.tags = ["testing", "utils"];

	auto j = pkg.toJSON();

	assert(j["name"].str == "test-pkg", format("expected 'test-pkg', got '%s'", j["name"].str));
	assert(j["version"].str == "1.0.0", format("expected '1.0.0', got '%s'", j["version"].str));
	assert(j["description"].str == "A test package",
			format("expected 'A test package', got '%s'", j["description"].str));
	assert(j["repository"].str == "https://github.com/test/pkg",
			format("expected repository URL, got '%s'", j["repository"].str));
	assert(j["homepage"].str == "https://test-pkg.org",
			format("expected homepage URL, got '%s'", j["homepage"].str));
	assert(j["license"].str == "MIT", format("expected 'MIT', got '%s'", j["license"].str));

	auto authorsArr = j["authors"].array;
	assert(authorsArr.length == 2, format("expected 2 authors, got %d", authorsArr.length));
	assert(authorsArr[0].str == "Alice", format("expected 'Alice', got '%s'", authorsArr[0].str));
	assert(authorsArr[1].str == "Bob", format("expected 'Bob', got '%s'", authorsArr[1].str));

	auto tagsArr = j["tags"].array;
	assert(tagsArr.length == 2, format("expected 2 tags, got %d", tagsArr.length));
	assert(tagsArr[0].str == "testing", format("expected 'testing', got '%s'", tagsArr[0].str));
	assert(tagsArr[1].str == "utils", format("expected 'utils', got '%s'", tagsArr[1].str));
}

/// Test PackageMetadata.toJSON omits empty optional fields
unittest {
	PackageMetadata pkg;
	pkg.name = "minimal";
	pkg.version_ = "0.1.0";

	auto j = pkg.toJSON();

	assert(j["name"].str == "minimal");
	assert(j["version"].str == "0.1.0");
	assert("description" !in j.object, "description should be absent when empty");
	assert("repository" !in j.object, "repository should be absent when empty");
	assert("homepage" !in j.object, "homepage should be absent when empty");
	assert("license" !in j.object, "license should be absent when empty");
	assert("authors" !in j.object, "authors should be absent when empty");
	assert("tags" !in j.object, "tags should be absent when empty");
}

/// Test PackageMetadata round-trip: toJSON -> fromJSON preserves all fields
unittest {
	import std.format : format;

	PackageMetadata original;
	original.name = "round-trip";
	original.version_ = "2.3.4";
	original.description = "Round-trip test";
	original.repository = "https://github.com/test/roundtrip";
	original.homepage = "https://roundtrip.dev";
	original.license = "BSL-1.0";
	original.authors = ["Charlie"];
	original.tags = ["serialization"];

	auto j = original.toJSON();
	auto restored = PackageMetadata.fromJSON(j);

	assert(restored.name == original.name,
			format("name: expected '%s', got '%s'", original.name, restored.name));
	assert(restored.version_ == original.version_,
			format("version: expected '%s', got '%s'", original.version_, restored.version_));
	assert(restored.description == original.description,
			format("description: expected '%s', got '%s'",
				original.description, restored.description));
	assert(restored.repository == original.repository,
			format("repository: expected '%s', got '%s'", original.repository, restored.repository));
	assert(restored.homepage == original.homepage,
			format("homepage: expected '%s', got '%s'", original.homepage, restored.homepage));
	assert(restored.license == original.license,
			format("license: expected '%s', got '%s'", original.license, restored.license));
	assert(restored.authors == original.authors,
			format("authors: expected %s, got %s", original.authors, restored.authors));
	assert(restored.tags == original.tags, format("tags: expected %s, got %s",
			original.tags, restored.tags));
}

/// Test PackageMetadata.fromJSON with nested "info" object (DUB API format)
unittest {
	import std.format : format;

	auto json = parseJSON(`{
		"info": {
			"name": "nested-pkg",
			"version": "3.0.0",
			"description": "Nested info test",
			"repository": "https://github.com/test/nested",
			"homepage": "https://nested.dev",
			"license": "Apache-2.0",
			"authors": ["Dave"],
			"tags": ["nested"]
		}
	}`);

	auto pkg = PackageMetadata.fromJSON(json);

	assert(pkg.name == "nested-pkg", format("expected 'nested-pkg', got '%s'", pkg.name));
	assert(pkg.version_ == "3.0.0", format("expected '3.0.0', got '%s'", pkg.version_));
	assert(pkg.description == "Nested info test",
			format("expected 'Nested info test', got '%s'", pkg.description));
	assert(pkg.repository == "https://github.com/test/nested",
			format("expected repository, got '%s'", pkg.repository));
	assert(pkg.homepage == "https://nested.dev",
			format("expected homepage, got '%s'", pkg.homepage));
	assert(pkg.license == "Apache-2.0", format("expected 'Apache-2.0', got '%s'", pkg.license));
	assert(pkg.authors == ["Dave"], format("expected ['Dave'], got %s", pkg.authors));
	assert(pkg.tags == ["nested"], format("expected ['nested'], got %s", pkg.tags));
}

/// Test PackageMetadata.fromJSON with version at top level overrides info version
unittest {
	import std.format : format;

	auto json = parseJSON(`{
		"version": "1.0.0",
		"info": {
			"name": "override-test",
			"version": "2.0.0"
		}
	}`);

	auto pkg = PackageMetadata.fromJSON(json);
	// Top-level version takes precedence
	assert(pkg.version_ == "1.0.0", format("expected '1.0.0', got '%s'", pkg.version_));
}

/// Test PackageMetadata.fromJSON with version as integer in info
unittest {
	import std.format : format;

	auto json = parseJSON(`{
		"name": "int-version",
		"version": 42
	}`);

	auto pkg = PackageMetadata.fromJSON(json);
	assert(pkg.version_ == "42", format("expected '42', got '%s'", pkg.version_));
}

/// Test PackageMetadata.fromJSON with version as string in info (no top-level version)
unittest {
	import std.format : format;

	auto json = parseJSON(`{
		"info": {
			"name": "info-version",
			"version": "5.0.0"
		}
	}`);

	auto pkg = PackageMetadata.fromJSON(json);
	assert(pkg.version_ == "5.0.0", format("expected '5.0.0', got '%s'", pkg.version_));
}

/// Test PackageMetadata.fromJSON with empty JSON object
unittest {
	auto json = parseJSON(`{}`);
	auto pkg = PackageMetadata.fromJSON(json);

	assert(pkg.name == "", "name should be empty for empty JSON");
	assert(pkg.version_ == "", "version should be empty for empty JSON");
	assert(pkg.description == "", "description should be empty for empty JSON");
	assert(pkg.repository == "", "repository should be empty for empty JSON");
	assert(pkg.homepage == "", "homepage should be empty for empty JSON");
	assert(pkg.license == "", "license should be empty for empty JSON");
	assert(pkg.authors.length == 0, "authors should be empty for empty JSON");
	assert(pkg.tags.length == 0, "tags should be empty for empty JSON");
}

/// Test PackageMetadata.fromJSON ignores wrong-typed fields
unittest {
	auto json = parseJSON(`{
		"name": 123,
		"description": false,
		"license": [],
		"authors": "not-an-array",
		"tags": "not-an-array"
	}`);

	auto pkg = PackageMetadata.fromJSON(json);
	// All fields should remain default because types don't match
	assert(pkg.name == "", "name should be empty when JSON type is wrong");
	assert(pkg.description == "", "description should be empty when JSON type is wrong");
	assert(pkg.license == "", "license should be empty when JSON type is wrong");
	assert(pkg.authors.length == 0, "authors should be empty when JSON type is wrong");
	assert(pkg.tags.length == 0, "tags should be empty when JSON type is wrong");
}

/// Test PackageMetadata round-trip with minimal fields (only required)
unittest {
	PackageMetadata original;
	original.name = "minimal-rt";
	original.version_ = "0.0.1";

	auto j = original.toJSON();
	auto restored = PackageMetadata.fromJSON(j);

	assert(restored.name == "minimal-rt");
	assert(restored.version_ == "0.0.1");
	assert(restored.description == "");
	assert(restored.authors.length == 0);
	assert(restored.tags.length == 0);
}

/// Test PackageMetadata.toJSON with partial optional fields
unittest {
	PackageMetadata pkg;
	pkg.name = "partial";
	pkg.version_ = "1.0.0";
	pkg.description = "Has description";
	pkg.license = "MIT";
	// No repository, homepage, authors, or tags

	auto j = pkg.toJSON();

	assert("description" in j.object, "description should be present");
	assert("license" in j.object, "license should be present");
	assert("repository" !in j.object, "repository should be absent");
	assert("homepage" !in j.object, "homepage should be absent");
	assert("authors" !in j.object, "authors should be absent");
	assert("tags" !in j.object, "tags should be absent");
}
