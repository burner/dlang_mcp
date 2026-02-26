/**
 * MCP tool for compile-checking D source code without linking.
 *
 * Runs DMD or LDC2 with the `-c` flag to detect type errors, syntax errors,
 * undefined identifiers, and other compile-time issues. Supports both inline
 * code snippets and file paths, with optional dub project integration for
 * automatic import path resolution.
 */
module tools.compile_check;

import std.json : JSONValue, parseJSON, JSONType;
import std.file : exists, write, remove, tempDir;
import std.path : buildPath, absolutePath;
import tools.base : BaseTool;
import mcp.types : ToolResult;
import utils.process : executeCommandInDir, executeCommand, ProcessResult;
import utils.diagnostic : mergeOutput, collectDiagnostics;

/**
 * Tool that compile-checks D source code and returns structured diagnostics.
 *
 * Accepts either inline source code or a file path. When a dub project path
 * is provided, automatically resolves import paths and version identifiers
 * from the project configuration.
 */
class CompileCheckTool : BaseTool {
	@property string name()
	{
		return "compile_check";
	}

	@property string description()
	{
		return "Compile-check D source code without linking. Runs dmd or ldc2 with -c flag to "
			~ "detect type errors, syntax errors, undefined identifiers, and other compile-time "
			~ "issues. Returns structured error/warning list with file, line, column, and message. "
			~ "Accepts either inline code or a file path. Either 'code' or 'file_path' must be provided.";
	}

	@property JSONValue inputSchema()
	{
		return parseJSON(`{
            "type": "object",
            "description": "Provide either 'code' (inline source) or 'file_path' (path to .d file). At least one is required.",
            "properties": {
                "code": {
                    "type": "string",
                    "description": "D source code to compile-check"
                },
                "file_path": {
                    "type": "string",
                    "description": "Path to a D source file to compile-check (alternative to code)"
                },
                "compiler": {
                    "type": "string",
                    "enum": ["dmd", "ldc2", "gdc"],
                    "default": "dmd",
                    "description": "Which D compiler to use"
                },
                "import_paths": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Additional import paths (-I flags)"
                },
                "string_imports": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "String import paths (-J flags)"
                },
                "versions": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Version identifiers to define (-version=X)"
                },
                "dub_project": {
                    "type": "string",
                    "description": "Path to a dub project. If provided, import paths and versions are auto-detected from dub describe"
                }
            }
        }`);
	}

	ToolResult execute(JSONValue arguments)
	{
		try {
			import std.path : absolutePath;
			import utils.security : validateCompiler;

			string code;
			string filePath;
			bool hasCode = "code" in arguments && arguments["code"].type == JSONType.string;
			bool hasFile = "file_path" in arguments && arguments["file_path"].type
				== JSONType.string;

			if(!hasCode && !hasFile) {
				return createErrorResult("Either 'code' or 'file_path' parameter is required");
			}

			string compiler = "dmd";
			if("compiler" in arguments && arguments["compiler"].type == JSONType.string) {
				compiler = validateCompiler(arguments["compiler"].str);
			}

			// Build command
			string[] cmd = [compiler, "-c", "-o-"]; // compile-only, no output file

			// Auto-detect from dub project
			if("dub_project" in arguments && arguments["dub_project"].type == JSONType.string) {
				addDubImportPaths(cmd, absolutePath(arguments["dub_project"].str));
			}

			// Manual import paths
			if("import_paths" in arguments && arguments["import_paths"].type == JSONType.array) {
				foreach(p; arguments["import_paths"].array) {
					if(p.type == JSONType.string)
						cmd ~= ["-I" ~ p.str];
				}
			}

			// String import paths
			if("string_imports" in arguments && arguments["string_imports"].type == JSONType.array) {
				foreach(p; arguments["string_imports"].array) {
					if(p.type == JSONType.string)
						cmd ~= ["-J" ~ p.str];
				}
			}

			// Version identifiers
			if("versions" in arguments && arguments["versions"].type == JSONType.array) {
				foreach(v; arguments["versions"].array) {
					if(v.type == JSONType.string)
						cmd ~= ["-version=" ~ v.str];
				}
			}

			string tempPath;

			if(hasFile) {
				filePath = absolutePath(arguments["file_path"].str);
				if(!exists(filePath))
					return createErrorResult("File not found: " ~ arguments["file_path"].str);
				cmd ~= filePath;
			} else {
				code = arguments["code"].str;
				// Write to temp file with a valid D module name
				import std.uuid : randomUUID;

				string uuid = randomUUID().toString();
				// Remove hyphens from UUID so the filename is a valid D identifier
				string cleanId;
				foreach(c; uuid) {
					if(c != '-')
						cleanId ~= c;
				}
				tempPath = buildPath(tempDir, "dcheck_" ~ cleanId ~ ".d");
				write(tempPath, code);
				scope(exit) {
					import std.exception : collectException;

					if(tempPath.length > 0)
						collectException(remove(tempPath));
				}
				cmd ~= tempPath;
			}

			auto result = executeCommand(cmd);

			return formatResult(result, tempPath, hasFile ? filePath : null);
		} catch(Exception e) {
			return createErrorResult("Error running compile check: " ~ e.msg);
		}
	}

private:
	void addDubImportPaths(ref string[] cmd, string projectPath)
	{
		import utils.process : executeCommand = executeCommandInDir;

		auto result = executeCommand(["dub", "describe", "--root=" ~ projectPath]);
		if(result.status != 0 || result.output.length == 0)
			return;

		try {
			auto desc = parseJSON(result.output);
			if("packages" !in desc)
				return;

			string rootPkg;
			if("rootPackage" in desc)
				rootPkg = desc["rootPackage"].str;

			foreach(pkg; desc["packages"].array) {
				// Add import paths from all packages
				if("importPaths" in pkg && pkg["importPaths"].type == JSONType.array) {
					foreach(p; pkg["importPaths"].array) {
						if(p.type == JSONType.string)
							cmd ~= ["-I" ~ p.str];
					}
				}

				// Add versions from root package
				if(rootPkg.length > 0 && pkg["name"].str == rootPkg) {
					if("versions" in pkg && pkg["versions"].type == JSONType.array) {
						foreach(v; pkg["versions"].array) {
							if(v.type == JSONType.string)
								cmd ~= ["-version=" ~ v.str];
						}
					}
					if("stringImportPaths" in pkg && pkg["stringImportPaths"].type == JSONType
							.array) {
						foreach(p; pkg["stringImportPaths"].array) {
							if(p.type == JSONType.string)
								cmd ~= ["-J" ~ p.str];
						}
					}
				}
			}
		} catch(Exception) {
			// Ignore parse errors, proceed without dub info
		}
	}

	ToolResult formatResult(ProcessResult result, string tempPath, string originalFilePath)
	{
		string compilerOutput = mergeOutput(result);

		if(result.status == 0 && compilerOutput.length == 0) {
			// Build a JSON response for success
			auto resp = JSONValue([
				"success": JSONValue(true),
				"errors": JSONValue((JSONValue[]).init),
				"warnings": JSONValue((JSONValue[]).init),
				"error_count": JSONValue(0),
				"warning_count": JSONValue(0)
			]);
			return createTextResult(resp.toString());
		}

		auto diags = collectDiagnostics(compilerOutput, tempPath, originalFilePath);

		auto resp = JSONValue([
			"success": JSONValue(result.status == 0),
			"errors": JSONValue(diags.errors),
			"warnings": JSONValue(diags.warnings),
			"error_count": JSONValue(diags.errors.length),
			"warning_count": JSONValue(diags.warnings.length),
		]);

		if(diags.supplemental.length > 0)
			resp["supplemental"] = JSONValue(diags.supplemental);

		return createTextResult(resp.toString());
	}
}

// -- Unit Tests --

version(unittest) {
	import std.format : format;
	import std.json : parseJSON, JSONType;
	import utils.process : ProcessResult;
}

/// CompileCheckTool has correct name
unittest {
	auto tool = new CompileCheckTool();
	assert(tool.name == "compile_check",
			format("Expected name 'compile_check', got '%s'", tool.name));
}

/// CompileCheckTool has non-empty description
unittest {
	auto tool = new CompileCheckTool();
	assert(tool.description.length > 0, "Description should not be empty");
	import std.algorithm.searching : canFind;

	assert(tool.description.canFind("Compile-check"), "Description should mention 'Compile-check'");
}

/// CompileCheckTool schema is a valid object with expected properties
unittest {
	auto tool = new CompileCheckTool();
	auto schema = tool.inputSchema;
	assert(schema["type"].str == "object",
			format("Schema type should be 'object', got '%s'", schema["type"].str));
	auto props = schema["properties"];
	assert("code" in props, "Schema should have 'code' property");
	assert("file_path" in props, "Schema should have 'file_path' property");
	assert("compiler" in props, "Schema should have 'compiler' property");
	assert("import_paths" in props, "Schema should have 'import_paths' property");
	assert("string_imports" in props, "Schema should have 'string_imports' property");
	assert("versions" in props, "Schema should have 'versions' property");
	assert("dub_project" in props, "Schema should have 'dub_project' property");
}

/// CompileCheckTool schema compiler property has correct enum values
unittest {
	auto tool = new CompileCheckTool();
	auto schema = tool.inputSchema;
	auto compilerProp = schema["properties"]["compiler"];
	assert("enum" in compilerProp, "Compiler property should have enum constraint");
	auto enumVals = compilerProp["enum"].array;
	assert(enumVals.length == 3, format("Expected 3 compiler enum values, got %d", enumVals.length));

	import std.algorithm.searching : canFind;
	import std.algorithm.iteration : map;
	import std.array : array;

	auto vals = enumVals.map!(v => v.str).array;
	assert(vals.canFind("dmd"), "Compiler enum should include 'dmd'");
	assert(vals.canFind("ldc2"), "Compiler enum should include 'ldc2'");
	assert(vals.canFind("gdc"), "Compiler enum should include 'gdc'");
}

/// formatResult returns success JSON when compilation succeeds with no output
unittest {
	auto tool = new CompileCheckTool();
	ProcessResult pr;
	pr.status = 0;
	pr.output = "";
	pr.stderrOutput = "";

	auto result = tool.formatResult(pr, null, null);
	assert(!result.isError, "Successful compilation should not be an error result");
	assert(result.content.length > 0, "Should have content");

	auto json = parseJSON(result.content[0].text);
	assert(json["success"].type == JSONType.true_, "success should be true");
	assert(json["error_count"].integer == 0,
			format("error_count should be 0, got %d", json["error_count"].integer));
	assert(json["warning_count"].integer == 0,
			format("warning_count should be 0, got %d", json["warning_count"].integer));
}

/// formatResult returns errors when compilation fails with error output
unittest {
	auto tool = new CompileCheckTool();
	ProcessResult pr;
	pr.status = 1;
	pr.output = "";
	pr.stderrOutput = "source/app.d(10,5): Error: undefined identifier 'foo'";

	auto result = tool.formatResult(pr, null, null);
	assert(!result.isError, "formatResult should return a text result, not an error result");
	assert(result.content.length > 0, "Should have content");

	auto json = parseJSON(result.content[0].text);
	assert(json["success"].type == JSONType.false_,
			"success should be false for failed compilation");
	assert(json["error_count"].integer == 1,
			format("error_count should be 1, got %d", json["error_count"].integer));
	assert(json["errors"].array.length == 1,
			format("Should have 1 error entry, got %d", json["errors"].array.length));

	auto err = json["errors"].array[0];
	assert(err["file"].str == "source/app.d",
			format("Error file should be 'source/app.d', got '%s'", err["file"].str));
	assert(err["line"].integer == 10, format("Error line should be 10, got %d",
			err["line"].integer));
	assert(err["column"].integer == 5,
			format("Error column should be 5, got %d", err["column"].integer));
	assert(err["severity"].str == "error",
			format("Severity should be 'error', got '%s'", err["severity"].str));
}

/// formatResult handles warnings in output
unittest {
	auto tool = new CompileCheckTool();
	ProcessResult pr;
	pr.status = 0;
	pr.output = "";
	pr.stderrOutput = "source/foo.d(20): Warning: statement is not reachable";

	auto result = tool.formatResult(pr, null, null);
	auto json = parseJSON(result.content[0].text);
	assert(json["success"].type == JSONType.true_,
			"success should be true when only warnings present");
	assert(json["warning_count"].integer == 1,
			format("warning_count should be 1, got %d", json["warning_count"].integer));
	assert(json["warnings"].array.length == 1,
			format("Should have 1 warning entry, got %d", json["warnings"].array.length));

	auto warn = json["warnings"].array[0];
	assert(warn["severity"].str == "warning",
			format("Severity should be 'warning', got '%s'", warn["severity"].str));
}

/// formatResult handles mixed errors and warnings
unittest {
	auto tool = new CompileCheckTool();
	ProcessResult pr;
	pr.status = 1;
	pr.output = "";
	pr.stderrOutput = "source/a.d(1): Error: bad thing\n"
		~ "source/b.d(2,5): Warning: sketchy thing\n" ~ "source/c.d(3): Deprecation: old syntax";

	auto result = tool.formatResult(pr, null, null);
	auto json = parseJSON(result.content[0].text);
	assert(json["success"].type == JSONType.false_, "success should be false");
	assert(json["error_count"].integer == 1,
			format("error_count should be 1, got %d", json["error_count"].integer));
	// Warning + deprecation both go to warnings
	assert(json["warning_count"].integer == 2,
			format("warning_count should be 2, got %d", json["warning_count"].integer));
}

/// formatResult includes supplemental diagnostics when present
unittest {
	auto tool = new CompileCheckTool();
	ProcessResult pr;
	pr.status = 1;
	pr.output = "";
	pr.stderrOutput = "source/a.d(1): Error: undefined identifier\n" ~ "Error: linker failed";

	auto result = tool.formatResult(pr, null, null);
	auto json = parseJSON(result.content[0].text);
	assert("supplemental" in json, "Should include supplemental field for file-less diagnostics");
	assert(json["supplemental"].array.length == 1,
			format("Should have 1 supplemental entry, got %d", json["supplemental"].array.length));
}

/// formatResult does not include supplemental key when no supplemental diagnostics
unittest {
	auto tool = new CompileCheckTool();
	ProcessResult pr;
	pr.status = 1;
	pr.output = "";
	pr.stderrOutput = "source/a.d(1): Error: undefined identifier";

	auto result = tool.formatResult(pr, null, null);
	auto json = parseJSON(result.content[0].text);
	assert("supplemental" !in json,
			"Should not include supplemental field when no file-less diagnostics");
}

/// formatResult rewrites temp path to stdin when no original file
unittest {
	auto tool = new CompileCheckTool();
	ProcessResult pr;
	pr.status = 1;
	pr.output = "";
	pr.stderrOutput = "/tmp/dcheck_abc123.d(5): Error: type mismatch";

	auto result = tool.formatResult(pr, "/tmp/dcheck_abc123.d", null);
	auto json = parseJSON(result.content[0].text);
	assert(json["errors"].array.length == 1, "Should have 1 error");
	assert(json["errors"].array[0]["file"].str == "<stdin>",
			format("Should rewrite temp path to '<stdin>', got '%s'",
				json["errors"].array[0]["file"].str));
}

/// formatResult rewrites temp path to original file path
unittest {
	auto tool = new CompileCheckTool();
	ProcessResult pr;
	pr.status = 1;
	pr.output = "";
	pr.stderrOutput = "/tmp/dcheck_abc123.d(5,3): Error: type mismatch";

	auto result = tool.formatResult(pr, "/tmp/dcheck_abc123.d", "source/myfile.d");
	auto json = parseJSON(result.content[0].text);
	assert(json["errors"].array.length == 1, "Should have 1 error");
	assert(json["errors"].array[0]["file"].str == "source/myfile.d",
			format("Should rewrite to original path, got '%s'", json["errors"].array[0]["file"].str));
}

/// formatResult handles output on stdout (not just stderr)
unittest {
	auto tool = new CompileCheckTool();
	ProcessResult pr;
	pr.status = 1;
	pr.output = "source/app.d(7): Error: found on stdout";
	pr.stderrOutput = "";

	auto result = tool.formatResult(pr, null, null);
	auto json = parseJSON(result.content[0].text);
	assert(json["error_count"].integer == 1,
			format("Should detect error from stdout, got error_count=%d",
				json["error_count"].integer));
}

/// formatResult handles output on both stdout and stderr
unittest {
	auto tool = new CompileCheckTool();
	ProcessResult pr;
	pr.status = 1;
	pr.output = "source/a.d(1): Error: from stdout";
	pr.stderrOutput = "source/b.d(2): Warning: from stderr";

	auto result = tool.formatResult(pr, null, null);
	auto json = parseJSON(result.content[0].text);
	assert(json["error_count"].integer == 1,
			format("Should have 1 error, got %d", json["error_count"].integer));
	assert(json["warning_count"].integer == 1,
			format("Should have 1 warning, got %d", json["warning_count"].integer));
}

/// formatResult with zero status but non-empty compiler output (warnings only)
unittest {
	auto tool = new CompileCheckTool();
	ProcessResult pr;
	pr.status = 0;
	pr.output = "";
	pr.stderrOutput = "source/x.d(5,1): Deprecation: use of old syntax";

	auto result = tool.formatResult(pr, null, null);
	auto json = parseJSON(result.content[0].text);
	assert(json["success"].type == JSONType.true_,
			"success should be true when status is 0 even with deprecation warnings");
	assert(json["warning_count"].integer == 1,
			format("warning_count should be 1, got %d", json["warning_count"].integer));
}

/// addDubImportPaths handles failed dub describe gracefully (does not modify cmd)
unittest {
	auto tool = new CompileCheckTool();
	string[] cmd = ["dmd", "-c", "-o-"];
	auto originalLen = cmd.length;

	// Pass a non-existent path - dub describe will fail with status != 0
	tool.addDubImportPaths(cmd, "/nonexistent/path/that/does/not/exist");

	// cmd should not have been modified since dub describe failed
	assert(cmd.length == originalLen,
			format("cmd should not be modified on dub describe failure, length was %d now %d",
				originalLen, cmd.length));
}

/// formatResult handles multiple errors on the same file
unittest {
	auto tool = new CompileCheckTool();
	ProcessResult pr;
	pr.status = 1;
	pr.output = "";
	pr.stderrOutput = "source/app.d(10): Error: first error\n"
		~ "source/app.d(20): Error: second error\n" ~ "source/app.d(30): Error: third error";

	auto result = tool.formatResult(pr, null, null);
	auto json = parseJSON(result.content[0].text);
	assert(json["error_count"].integer == 3,
			format("Should have 3 errors, got %d", json["error_count"].integer));
	assert(json["errors"].array.length == 3,
			format("Should have 3 error entries, got %d", json["errors"].array.length));
}
