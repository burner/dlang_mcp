module ingestion.ddoc_parser;

import models;
import std.json;
import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.regex;
import std.exception;

class DdocParser {
	JSONValue generateDdocJson(string sourceDir, string packageName)
	{
		writeln("  Generating documentation JSON...");

		auto dFiles = findDFiles(sourceDir);

		if(dFiles.empty) {
			writeln("  Warning: No D files found in ", sourceDir);
			return JSONValue(null);
		}

		auto outputFile = buildPath(sourceDir, "docs.json");

		try {
			return generateWithDMD(dFiles, outputFile);
		} catch(Exception e) {
			writeln("  DMD generation failed: ", e.msg);
		}

		try {
			return generateWithDub(sourceDir);
		} catch(Exception e) {
			writeln("  Dub describe failed: ", e.msg);
		}

		return JSONValue(null);
	}

	private JSONValue generateWithDMD(string[] dFiles, string outputFile)
	{
		auto filesStr = dFiles.map!(f => `"` ~ f ~ `"`).join(" ");
		auto cmd = format(`dmd -X -Xf="%s" -o- %s 2>&1`, outputFile, filesStr);

		auto result = executeShell(cmd);

		if(exists(outputFile)) {
			auto content = readText(outputFile);
			return parseJSON(content);
		}

		throw new Exception("DMD did not generate JSON output");
	}

	private JSONValue generateWithDub(string sourceDir)
	{
		auto oldDir = getcwd();
		scope(exit)
			chdir(oldDir);

		chdir(sourceDir);

		auto result = executeShell("dub describe --data=json 2>&1");

		if(result.status != 0) {
			throw new Exception("dub describe failed: " ~ result.output);
		}

		return parseJSON(result.output);
	}

	ModuleDoc[] parseJsonDocs(JSONValue json, string packageName)
	{
		if(json.isNull || json.type != JSONType.array) {
			writeln("  Warning: Invalid JSON format");
			return [];
		}

		ModuleDoc[] modules;

		foreach(item; json.array) {
			if("kind" !in item || item["kind"].str != "module") {
				continue;
			}

			ModuleDoc mod = parseModule(item, packageName);
			if(mod.name.length > 0) {
				modules ~= mod;
			}
		}

		return modules;
	}

	private ModuleDoc parseModule(JSONValue json, string packageName)
	{
		ModuleDoc mod;
		mod.name = json["name"].str;
		mod.packageName = packageName;
		mod.docComment = extractComment(json);

		if("members" in json && json["members"].type == JSONType.array) {
			foreach(member; json["members"].array) {
				auto kind = member["kind"].str;

				switch(kind) {
				case "function":
					mod.functions ~= parseFunction(member, mod.name, packageName);
					break;
				case "class":
				case "struct":
				case "interface":
					mod.types ~= parseType(member, mod.name, packageName);
					break;
				default:
					break;
				}
			}
		}

		return mod;
	}

	private FunctionDoc parseFunction(JSONValue json, string moduleName, string packageName)
	{
		FunctionDoc func;
		func.name = json["name"].str;
		func.fullyQualifiedName = moduleName ~ "." ~ func.name;
		func.moduleName = moduleName;
		func.packageName = packageName;
		func.docComment = extractComment(json);

		func.isTemplate = ("templateParameters" in json.object) !is null;

		func.signature = buildSignature(json);

		if("returnType" in json) {
			func.returnType = json["returnType"].str;
		} else if("type" in json) {
			func.returnType = extractReturnType(json["type"].str);
		}

		if("parameters" in json && json["parameters"].type == JSONType.array) {
			foreach(param; json["parameters"].array) {
				func.parameters ~= parseParameter(param);
			}
		}

		if(func.isTemplate && "constraint" in json) {
			func.constraints = parseConstraints(json);
		}

		func.performance = parsePerformanceAttributes(json);

		func.examples = extractExamples(func.docComment);

		return func;
	}

	private TypeDoc parseType(JSONValue json, string moduleName, string packageName)
	{
		TypeDoc type;
		type.name = json["name"].str;
		type.fullyQualifiedName = moduleName ~ "." ~ type.name;
		type.moduleName = moduleName;
		type.packageName = packageName;
		type.kind = json["kind"].str;
		type.docComment = extractComment(json);

		if("base" in json) {
			type.baseClasses ~= json["base"].str;
		}

		if("interfaces" in json && json["interfaces"].type == JSONType.array) {
			foreach(iface; json["interfaces"].array) {
				type.interfaces ~= iface.str;
			}
		}

		if("members" in json && json["members"].type == JSONType.array) {
			foreach(member; json["members"].array) {
				if(member["kind"].str == "function") {
					type.methods ~= parseFunction(member, type.fullyQualifiedName, packageName);
				}
			}
		}

		return type;
	}

	private string buildSignature(JSONValue json)
	{
		string sig;

		if("storageClass" in json && json["storageClass"].type == JSONType.array) {
			auto classes = json["storageClass"].array.map!(j => j.str).join(" ");
			if(classes.length > 0) {
				sig ~= classes ~ " ";
			}
		}

		if("type" in json) {
			sig ~= json["type"].str ~ " ";
		} else if("returnType" in json) {
			sig ~= json["returnType"].str ~ " ";
		}

		sig ~= json["name"].str;

		if("templateParameters" in json && json["templateParameters"].type == JSONType.array) {
			sig ~= "(";
			auto params = json["templateParameters"].array.map!(p => p["name"].str).join(", ");
			sig ~= params ~ ")";
		}

		sig ~= "(";
		if("parameters" in json && json["parameters"].type == JSONType.array) {
			auto params = json["parameters"].array.map!(p => parseParameter(p)).join(", ");
			sig ~= params;
		}
		sig ~= ")";

		if("attributes" in json && json["attributes"].type == JSONType.array) {
			auto attrs = json["attributes"].array.map!(a => a.str).join(" ");
			if(attrs.length > 0) {
				sig ~= " " ~ attrs;
			}
		}

		return sig;
	}

	private string parseParameter(JSONValue json)
	{
		string param;

		if("storageClass" in json && json["storageClass"].type == JSONType.array) {
			auto classes = json["storageClass"].array.map!(j => j.str).join(" ");
			if(classes.length > 0) {
				param ~= classes ~ " ";
			}
		}

		if("type" in json) {
			param ~= json["type"].str ~ " ";
		}

		if("name" in json) {
			param ~= json["name"].str;
		}

		if("defaultValue" in json) {
			param ~= " = " ~ json["defaultValue"].str;
		}

		return param;
	}

	private TemplateConstraint[] parseConstraints(JSONValue json)
	{
		TemplateConstraint[] constraints;

		if("templateParameters" !in json) {
			return constraints;
		}

		foreach(param; json["templateParameters"].array) {
			TemplateConstraint constraint;
			constraint.parameterName = param["name"].str;

			if("constraint" in param) {
				constraint.constraintText = param["constraint"].str;
				constraint.requiredTraits = extractTraits(constraint.constraintText);
			}

			constraints ~= constraint;
		}

		return constraints;
	}

	private string[] extractTraits(string constraintText)
	{
		string[] traits;

		auto re = regex(r"is(\w+)!", "g");
		foreach(match; matchAll(constraintText, re)) {
			traits ~= match.captures[1];
		}

		return traits;
	}

	private PerformanceInfo parsePerformanceAttributes(JSONValue json)
	{
		PerformanceInfo perf;

		if("attributes" in json && json["attributes"].type == JSONType.array) {
			foreach(attr; json["attributes"].array) {
				string attrStr = attr.str.toLower.strip;

				if(attrStr == "@nogc" || attrStr == "nogc") {
					perf.isNogc = true;
				} else if(attrStr == "@nothrow" || attrStr == "nothrow") {
					perf.isNothrow = true;
				} else if(attrStr == "pure") {
					perf.isPure = true;
				} else if(attrStr == "@safe" || attrStr == "safe") {
					perf.isSafe = true;
				}
			}
		}

		auto docComment = extractComment(json);
		perf.timeComplexity = inferComplexity(docComment);

		return perf;
	}

	private string inferComplexity(string doc)
	{
		doc = doc.toLower;

		if(doc.canFind("o(n log n)") || doc.canFind("o(nlogn)")) {
			return "O(n log n)";
		} else if(doc.canFind("o(n²)") || doc.canFind("o(n^2)")) {
			return "O(n²)";
		} else if(doc.canFind("o(n)") || doc.canFind("linear time")) {
			return "O(n)";
		} else if(doc.canFind("o(1)") || doc.canFind("constant time")) {
			return "O(1)";
		}

		return "";
	}

	private string extractReturnType(string signature)
	{
		auto parts = signature.split();
		return parts.length > 0 ? parts[0] : "";
	}

	private string extractComment(JSONValue json)
	{
		if("comment" !in json) {
			return "";
		}

		string comment = json["comment"].str;

		return comment.splitter("\n").map!(line => line.strip)
			.filter!(line => !line.empty)
			.map!(line => line.replace("/**", "").replace("*/", "").replace("///", "").strip)
			.filter!(line => !line.empty)
			.join(" ");
	}

	private string[] extractExamples(string docComment)
	{
		string[] examples;
		bool inExample = false;
		string currentExample;

		foreach(line; docComment.splitter("\n")) {
			auto trimmed = line.strip();

			if(trimmed.startsWith("Example:") || trimmed.startsWith("Examples:")) {
				inExample = true;
				currentExample = "";
			} else if(trimmed.startsWith("---")) {
				if(!currentExample.empty) {
					examples ~= currentExample.strip();
					currentExample = "";
				}
				inExample = !inExample;
			} else if(inExample) {
				currentExample ~= line ~ "\n";
			}
		}

		if(!currentExample.empty) {
			examples ~= currentExample.strip();
		}

		return examples;
	}

	private string[] findDFiles(string dir)
	{
		string[] files;

		try {
			foreach(entry; dirEntries(dir, "*.d", SpanMode.depth)) {
				if(entry.isFile) {
					files ~= entry.name;
				}
			}
		} catch(Exception e) {
			stderr.writeln("Error scanning directory: ", e.msg);
		}

		return files;
	}
}
