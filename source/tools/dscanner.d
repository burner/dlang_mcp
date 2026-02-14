module tools.dscanner;

import std.json : JSONValue, parseJSON, JSONType;
import std.file : tempDir, write, remove, exists;
import std.path : baseName, buildPath;
import std.string : strip, replace, format;
import std.regex : regex, replaceAll;
import std.conv : text;
import tools.base : BaseTool;
import mcp.types : ToolResult;
import utils.process : executeCommand, executeCommandWithInput;

enum DscannerMode
{
    lint,
    syntaxCheck,
    sloc,
    tokenCount,
    imports,
    recursiveImports,
    ctags,
    ast,
    declaration,
    highlight,
    report
}

enum CheckPreset
{
    default_,
    strict,
    minimal,
    custom
}

class DscannerTool : BaseTool
{
    @property string name()
    {
        return "dscanner";
    }

    @property string description()
    {
        return "Analyze D source code with dscanner. Supports multiple analysis modes: lint (static analysis), syntax check, line counting, import listing, AST generation, and more.";
    }

    @property JSONValue inputSchema()
    {
        return parseJSON(`{
            "type": "object",
            "properties": {
                "code": {
                    "type": "string",
                    "description": "D source code to analyze"
                },
                "file_path": {
                    "type": "string",
                    "description": "Optional file path (for context in error messages)"
                },
                "mode": {
                    "type": "string",
                    "enum": ["lint", "syntax", "sloc", "tokenCount", "imports", "recursiveImports", "ctags", "ast", "declaration", "highlight", "report"],
                    "default": "lint",
                    "description": "Analysis mode"
                },
                "preset": {
                    "type": "string",
                    "enum": ["default", "strict", "minimal", "custom"],
                    "default": "default",
                    "description": "Check preset for lint/syntax modes"
                },
                "symbol": {
                    "type": "string",
                    "description": "Symbol name to find declaration (only for declaration mode)"
                },
                "errorFormat": {
                    "type": "string",
                    "enum": ["github", "pretty", "plain"],
                    "default": "plain",
                    "description": "Output format for errors"
                },
                "config": {
                    "type": "string",
                    "description": "Path to custom dscanner.ini config file"
                },
                "skipTests": {
                    "type": "boolean",
                    "default": false,
                    "description": "Skip analyzing code in unittests"
                },
                "importPaths": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Directories to search for imports"
                }
            },
            "required": ["code"]
        }`);
    }

    ToolResult execute(JSONValue arguments)
    {
        try
        {
            if (arguments.type != JSONType.object || !("code" in arguments))
            {
                return createErrorResult("Missing required 'code' parameter");
            }

            string code = arguments["code"].str;
            string filePath = "source.d";
            if ("file_path" in arguments && arguments["file_path"].type == JSONType.string)
            {
                filePath = arguments["file_path"].str;
            }

            string modeStr = "lint";
            if ("mode" in arguments && arguments["mode"].type == JSONType.string)
            {
                modeStr = arguments["mode"].str;
            }

            string[] command;
            string tempPath;
            string configPath;
            bool usesTempFile = true;

            switch (modeStr)
            {
            case "lint":
                command = buildLintCommand(arguments, filePath);
                tempPath = buildTempPath(filePath);
                configPath = maybeCreatePresetConfig(arguments);
                break;
            case "syntax":
                command = buildSyntaxCommand(arguments, filePath);
                tempPath = buildTempPath(filePath);
                configPath = maybeCreatePresetConfig(arguments);
                break;
            case "sloc":
                command = ["dscanner", "--sloc"];
                usesTempFile = false;
                break;
            case "tokenCount":
                command = ["dscanner", "--tokenCount"];
                usesTempFile = false;
                break;
            case "imports":
                command = buildImportsCommand(arguments, false);
                usesTempFile = false;
                break;
            case "recursiveImports":
                command = buildImportsCommand(arguments, true);
                usesTempFile = false;
                break;
            case "ctags":
                command = ["dscanner", "--ctags"];
                tempPath = buildTempPath(filePath);
                break;
            case "ast":
                command = ["dscanner", "--ast"];
                usesTempFile = false;
                break;
            case "declaration":
                command = buildDeclarationCommand(arguments, filePath);
                tempPath = buildTempPath(filePath);
                break;
            case "highlight":
                command = ["dscanner", "--highlight"];
                usesTempFile = false;
                break;
            case "report":
                command = buildReportCommand(arguments, filePath);
                tempPath = buildTempPath(filePath);
                configPath = maybeCreatePresetConfig(arguments);
                break;
            default:
                return createErrorResult("Unknown mode: " ~ modeStr);
            }

            if (configPath.length > 0)
            {
                command ~= ["--config", configPath];
            }

            ProcessResult result;
            if (usesTempFile && tempPath.length > 0)
            {
                write(tempPath, code);
                command ~= tempPath;
                result = executeCommand(command);
                if (exists(tempPath))
                    remove(tempPath);
            }
            else
            {
                result = executeCommandWithInput(command, code);
            }

            if (configPath.length > 0 && exists(configPath))
            {
                remove(configPath);
            }

            return formatResult(result, modeStr, filePath);
        }
        catch (Exception e)
        {
            return createErrorResult("Error executing dscanner: " ~ e.msg);
        }
    }

private:
    import utils.process : ProcessResult;

    string cleanTempPath(string output)
    {
        import std.regex : regex, replaceAll;
        auto pattern = regex(tempDir ~ "dscanner_[a-f0-9-]+_");
        string cleaned = replaceAll(output, pattern, "");
        cleaned = cleaned.replace("_source.d", "");
        auto escapedSlash = regex(`\\/`);
        cleaned = replaceAll(cleaned, escapedSlash, "/");
        auto uuidPattern = regex("/tmp/dscanner_[a-f0-9-]+");
        cleaned = replaceAll(cleaned, uuidPattern, "");
        return cleaned;
    }

    string buildTempPath(string originalPath)
    {
        import std.uuid : randomUUID;
        string base = baseName(originalPath);
        return buildPath(tempDir, "dscanner_" ~ randomUUID().toString() ~ "_" ~ base);
    }

    string maybeCreatePresetConfig(JSONValue arguments)
    {
        if ("config" in arguments && arguments["config"].type == JSONType.string)
        {
            return arguments["config"].str;
        }

        string presetStr = "default";
        if ("preset" in arguments && arguments["preset"].type == JSONType.string)
        {
            presetStr = arguments["preset"].str;
        }

        if (presetStr == "default" || presetStr == "custom")
        {
            return null;
        }

        string configContent;
        switch (presetStr)
        {
        case "strict":
            configContent = getStrictConfig();
            break;
        case "minimal":
            configContent = getMinimalConfig();
            break;
        default:
            return null;
        }

        import std.uuid : randomUUID;
        string configPath = buildPath(tempDir, "dscanner_config_" ~ randomUUID().toString() ~ ".ini");
        write(configPath, configContent);
        return configPath;
    }

    string getStrictConfig()
    {
        return `[analysis.config.StaticAnalysisConfig]
style_check="enabled"
enum_array_literal_check="enabled"
exception_check="enabled"
delete_check="enabled"
float_operator_check="enabled"
number_style_check="enabled"
object_const_check="enabled"
backwards_range_check="enabled"
if_else_same_check="enabled"
constructor_check="enabled"
unused_variable_check="enabled"
unused_label_check="enabled"
unused_parameter_check="enabled"
duplicate_attribute="enabled"
opequals_tohash_check="enabled"
length_subtraction_check="enabled"
builtin_property_names_check="enabled"
asm_style_check="enabled"
logical_precedence_check="enabled"
undocumented_declaration_check="enabled"
function_attribute_check="enabled"
comma_expression_check="enabled"
could_be_immutable_check="enabled"
redundant_if_check="enabled"
redundant_parens_check="enabled"
mismatched_args_check="enabled"
label_var_same_name_check="enabled"
long_line_check="enabled"
max_line_length="100"
auto_ref_assignment_check="enabled"
incorrect_infinite_range_check="enabled"
useless_assert_check="enabled"
alias_syntax_check="enabled"
static_if_else_check="enabled"
lambda_return_check="enabled"
auto_function_check="enabled"
imports_sortedness="enabled"
explicitly_annotated_unittests="enabled"
properly_documented_public_functions="enabled"
final_attribute_check="enabled"
vcall_in_ctor="enabled"
redundant_attributes_check="enabled"
has_public_example="enabled"
assert_without_msg="enabled"
trust_too_much="enabled"
redundant_storage_classes="enabled"
unused_result="enabled"
cyclomatic_complexity="enabled"
max_cyclomatic_complexity="15"
body_on_disabled_func_check="enabled"
`;
    }

    string getMinimalConfig()
    {
        return `[analysis.config.StaticAnalysisConfig]
style_check="disabled"
enum_array_literal_check="disabled"
exception_check="enabled"
delete_check="enabled"
float_operator_check="disabled"
number_style_check="disabled"
object_const_check="disabled"
backwards_range_check="disabled"
if_else_same_check="disabled"
constructor_check="disabled"
unused_variable_check="enabled"
unused_label_check="enabled"
unused_parameter_check="disabled"
duplicate_attribute="disabled"
opequals_tohash_check="disabled"
length_subtraction_check="disabled"
builtin_property_names_check="disabled"
asm_style_check="disabled"
logical_precedence_check="enabled"
undocumented_declaration_check="disabled"
function_attribute_check="disabled"
comma_expression_check="enabled"
could_be_immutable_check="disabled"
redundant_if_check="disabled"
redundant_parens_check="disabled"
mismatched_args_check="disabled"
label_var_same_name_check="disabled"
long_line_check="disabled"
auto_ref_assignment_check="disabled"
incorrect_infinite_range_check="enabled"
useless_assert_check="disabled"
alias_syntax_check="disabled"
static_if_else_check="disabled"
lambda_return_check="disabled"
auto_function_check="disabled"
imports_sortedness="disabled"
explicitly_annotated_unittests="disabled"
properly_documented_public_functions="disabled"
final_attribute_check="disabled"
vcall_in_ctor="disabled"
redundant_attributes_check="disabled"
has_public_example="disabled"
assert_without_msg="disabled"
trust_too_much="disabled"
redundant_storage_classes="disabled"
unused_result="disabled"
cyclomatic_complexity="disabled"
body_on_disabled_func_check="disabled"
`;
    }

    string[] buildLintCommand(JSONValue arguments, string filePath)
    {
        string[] cmd = ["dscanner", "--styleCheck"];
        addErrorFormat(cmd, arguments);
        addSkipTests(cmd, arguments);
        addImportPaths(cmd, arguments);
        return cmd;
    }

    string[] buildSyntaxCommand(JSONValue arguments, string filePath)
    {
        string[] cmd = ["dscanner", "--syntaxCheck"];
        addErrorFormat(cmd, arguments);
        addSkipTests(cmd, arguments);
        return cmd;
    }

    string[] buildImportsCommand(JSONValue arguments, bool recursive)
    {
        string[] cmd;
        if (recursive)
            cmd = ["dscanner", "--recursiveImports"];
        else
            cmd = ["dscanner", "--imports"];
        addImportPaths(cmd, arguments);
        return cmd;
    }

    string[] buildDeclarationCommand(JSONValue arguments, string filePath)
    {
        string[] cmd = ["dscanner", "--declaration"];
        if ("symbol" in arguments && arguments["symbol"].type == JSONType.string)
        {
            cmd ~= arguments["symbol"].str;
        }
        else
        {
            cmd ~= "main";
        }
        addImportPaths(cmd, arguments);
        return cmd;
    }

    string[] buildReportCommand(JSONValue arguments, string filePath)
    {
        string[] cmd = ["dscanner", "--report"];
        addSkipTests(cmd, arguments);
        addImportPaths(cmd, arguments);
        return cmd;
    }

    void addErrorFormat(ref string[] cmd, JSONValue arguments)
    {
        if ("errorFormat" in arguments && arguments["errorFormat"].type == JSONType.string)
        {
            string fmt = arguments["errorFormat"].str;
            if (fmt == "plain")
            {
                cmd ~= ["--errorFormat", "{filepath}({line}:{column})[{type}]: {message}"];
            }
            else
            {
                cmd ~= ["--errorFormat", fmt];
            }
        }
    }

    void addSkipTests(ref string[] cmd, JSONValue arguments)
    {
        if ("skipTests" in arguments)
        {
            auto t = arguments["skipTests"].type;
            if (t == JSONType.true_ || t == JSONType.false_)
            {
                if (arguments["skipTests"].type == JSONType.true_)
                {
                    cmd ~= "--skipTests";
                }
            }
        }
    }

    void addImportPaths(ref string[] cmd, JSONValue arguments)
    {
        if ("importPaths" in arguments && arguments["importPaths"].type == JSONType.array)
        {
            foreach (path; arguments["importPaths"].array)
            {
                if (path.type == JSONType.string)
                {
                    cmd ~= ["-I", path.str];
                }
            }
        }
    }

    ToolResult formatResult(ProcessResult result, string mode, string filePath)
    {
        if (mode == "lint" || mode == "syntax")
        {
            if (result.output.length == 0)
            {
                return createTextResult("No issues found.");
            }
            string cleaned = cleanTempPath(result.output);
            return createTextResult("Dscanner " ~ mode ~ " results:\n\n" ~ cleaned);
        }
        else if (mode == "sloc")
        {
            if (result.output.length > 0)
            {
                return createTextResult("Source Lines of Code:\n" ~ result.output);
            }
            return createTextResult("SLOC: 0");
        }
        else if (mode == "tokenCount")
        {
            if (result.output.length > 0)
            {
                return createTextResult("Token Count:\n" ~ result.output);
            }
            return createTextResult("Tokens: 0");
        }
        else if (mode == "imports" || mode == "recursiveImports")
        {
            if (result.output.length > 0)
            {
                return createTextResult("Imports:\n" ~ result.output);
            }
            return createTextResult("No imports found.");
        }
        else if (mode == "ctags")
        {
            if (result.output.length > 0)
            {
                string cleaned = cleanTempPath(result.output);
                return createTextResult(cleaned);
            }
            return createTextResult("No tags generated.");
        }
        else if (mode == "ast")
        {
            if (result.output.length > 0)
            {
                return createTextResult(result.output);
            }
            return createTextResult("No AST generated.");
        }
        else if (mode == "declaration")
        {
            if (result.output.length > 0)
            {
                string cleaned = cleanTempPath(result.output);
                return createTextResult("Declaration found:\n" ~ cleaned);
            }
            return createTextResult("Declaration not found.");
        }
        else if (mode == "highlight")
        {
            if (result.output.length > 0)
            {
                return createTextResult(result.output);
            }
            return createTextResult("No highlighting generated.");
        }
        else if (mode == "report")
        {
            if (result.output.length > 0)
            {
                string cleaned = cleanTempPath(result.output);
                return createTextResult("Analysis Report:\n" ~ cleaned);
            }
            return createTextResult("No issues found in report.");
        }

        return createTextResult(result.output.length > 0 ? result.output : "Completed.");
    }
}