module models.types;

import std.json;
import std.algorithm;
import std.array;
import std.conv;

struct PackageMetadata {
	string name;
	string version_;
	string description;
	string repository;
	string homepage;
	string license;
	string[] authors;
	string[] tags;

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

struct ModuleDoc {
	string name;
	string packageName;
	string docComment;
	FunctionDoc[] functions;
	TypeDoc[] types;
}

struct FunctionDoc {
	string name;
	string fullyQualifiedName;
	string moduleName;
	string packageName;
	string signature;
	string returnType;
	string[] parameters;
	string docComment;
	string[] examples;
	bool isTemplate;
	TemplateConstraint[] constraints;
	PerformanceInfo performance;
}

struct TypeDoc {
	string name;
	string fullyQualifiedName;
	string moduleName;
	string packageName;
	string kind;
	string docComment;
	FunctionDoc[] methods;
	string[] baseClasses;
	string[] interfaces;
}

struct CodeExample {
	string code;
	string description;
	string[] requiredImports;
	bool isRunnable;
	bool isUnittest;
	long functionId;
	long typeId;
	long packageId;
}

struct TemplateConstraint {
	string parameterName;
	string constraintText;
	string[] requiredTraits;
}

struct PerformanceInfo {
	string timeComplexity;
	string spaceComplexity;
	bool allocatesMemory;
	bool isNogc;
	bool isNothrow;
	bool isPure;
	bool isSafe;
}

struct FunctionRelationship {
	long fromFunctionId;
	long toFunctionId;
	string relationshipType;
	float weight;
}

struct UsagePattern {
	string name;
	string description;
	string[] functionIds;
	string codeTemplate;
	string useCase;
}

struct SearchResult {
	long id;
	string name;
	string fullyQualifiedName;
	string signature;
	string docComment;
	string packageName;
	string moduleName;
	float rank;
}
