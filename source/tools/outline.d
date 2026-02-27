/**
 * MCP tool for generating structured outlines of D source files.
 *
 * Uses D-Scanner's ctags and AST capabilities to extract hierarchical symbol
 * information including names, kinds, visibility, attributes, return types,
 * parameters, template parameters, and documentation comments.
 */
module tools.outline;

import std.json : JSONValue, parseJSON, JSONType;
import std.file : exists, readText;
import std.path : absolutePath;
import std.string : strip, indexOf, startsWith, endsWith, replace;
import std.array : appender, array;
import std.conv : text, to;
import std.algorithm.iteration : map, filter, splitter;
import std.algorithm.searching : canFind;
import tools.base : BaseTool;
import mcp.types : ToolResult;
import utils.process : executeCommandWithInput;

/**
 * Tool that generates a structured outline of all symbols in a D source file.
 *
 * Returns hierarchical symbol information including name, kind
 * (class/struct/function/variable/enum/interface/constructor/template),
 * line number, visibility, attributes, return type, parameters, template
 * parameters, and documentation comments. Supports both file paths and
 * inline code input.
 */
class ModuleOutlineTool : BaseTool {
	@property string name()
	{
		return "get_module_outline";
	}

	@property string description()
	{
		return "Retrieve a hierarchical outline of all symbols in a single D source file or code snippet. "
			~ "Use when asked 'what's in this file?', 'show me the structure', or 'list functions in "
			~ "this module'. Returns nested JSON with each symbol's name, kind, line number, visibility, "
			~ "attributes (@safe, @nogc, nothrow, pure), return type, parameters, and ddoc comments. "
			~ "Provide either a file path or inline code. For project-wide symbol search use "
			~ "ctags_search; for all modules use list_project_modules.";
	}

	@property JSONValue inputSchema()
	{
		return parseJSON(`{
			"type": "object",
			"description": "Provide either 'file_path' (path to .d file) or 'code' (inline source). At least one is required.",
			"properties": {
				"file_path": {
					"type": "string",
					"description": "Path to a .d source file to outline. Use for files on disk."
				},
				"code": {
					"type": "string",
					"description": "D source code to outline (alternative to file_path). Use for inline snippets."
				},
				"include_private": {
					"type": "boolean",
					"default": true,
					"description": "Include private and protected symbols (default: true). Set false to see only the public API."
				}
			}
		}`);
	}

	ToolResult execute(JSONValue arguments)
	{
		try {
			string code;

			if("file_path" in arguments && arguments["file_path"].type == JSONType.string) {
				import std.path : absolutePath;

				string filePath = absolutePath(arguments["file_path"].str);
				if(!exists(filePath)) {
					return createErrorResult("File not found: " ~ filePath);
				}
				code = readText(filePath);
			} else if("code" in arguments && arguments["code"].type == JSONType.string) {
				code = arguments["code"].str;
			} else {
				return createErrorResult("Either 'file_path' or 'code' parameter is required");
			}

			bool includePrivate = true;
			if("include_private" in arguments && arguments["include_private"].type
					== JSONType.false_) {
				includePrivate = false;
			}

			// Run dscanner --ast
			auto result = executeCommandWithInput(["dscanner", "--ast"], code);
			if(result.status != 0) {
				string err = "dscanner AST generation failed";
				if(result.stderrOutput.length > 0)
					err ~= ": " ~ result.stderrOutput;
				return createErrorResult(err);
			}

			if(result.output.length == 0) {
				return createErrorResult("dscanner produced no AST output");
			}

			// Parse the XML AST
			auto symbols = parseAstXml(result.output, includePrivate);

			// Format as JSON
			auto jsonResult = formatSymbolsAsJson(symbols);
			return createTextResult(jsonResult);
		} catch(Exception e) {
			return createErrorResult("Error generating module outline: " ~ e.msg);
		}
	}

private:

	/** Parse an integer from a string, returning 0 on failure. */
	static int tryParseInt(string s) nothrow
	{
		try
			return to!int(s);
		catch(Exception)
			return 0;
	}

	struct SymbolInfo {
		string name;
		string kind; // class, struct, function, variable, enum, interface, constructor, template, enum_member, alias_, union_
		int line;
		string visibility; // public, private, protected, package
		string[] attributes; // @safe, @nogc, nothrow, pure, @trusted, const, immutable, shared, static, override, final, abstract
		string returnType;
		ParamInfo[] parameters;
		string[] templateParams;
		string ddoc;
		SymbolInfo[] children;
	}

	struct ParamInfo {
		string name;
		string type;
	}

	// Simple XML tag parser state
	struct XmlTag {
		string name;
		string[string] attrs;
		bool isClosing;
		bool isSelfClosing;
		string textContent; // content between open and close on the same line
	}

	SymbolInfo[] parseAstXml(string xml, bool includePrivate)
	{
		SymbolInfo[] topLevel;

		// Preprocess: split XML into individual tokens (tags and text)
		// dscanner often puts multiple tags on one line like:
		//   <name>Tool</name><structBody>
		string[] lines = splitXmlTokens(xml);

		size_t pos = 0;
		string currentVisibility = "public"; // D default

		// Skip XML declaration and <module> tag
		while(pos < lines.length) {
			auto tag = parseTag(lines[pos]);
			if(tag.name == "module" && !tag.isClosing) {
				pos++;
				break;
			}
			pos++;
		}

		// Parse module content
		parseDeclarations(lines, pos, topLevel, currentVisibility, includePrivate);

		return topLevel;
	}

	/**
	 * Split raw XML into individual tag/text tokens, one per line.
	 * Handles cases like: <name>Foo</name><structBody>
	 * becomes: ["<name>Foo</name>", "<structBody>"]
	 */
	string[] splitXmlTokens(string xml)
	{
		string[] tokens;

		foreach(rawLine; xml.splitter('\n')) {
			auto line = rawLine.strip();
			if(line.length == 0)
				continue;

			// Process the line character by character to split tags
			size_t i = 0;
			while(i < line.length) {
				if(line[i] == '<') {
					// Find the end of this tag
					size_t tagEnd = i + 1;
					while(tagEnd < line.length && line[tagEnd] != '>')
						tagEnd++;

					if(tagEnd < line.length)
						tagEnd++; // include the >

					string tag = line[i .. tagEnd];

					// Check if this is a self-contained element: <tag>text</tag>
					// Look ahead for text content followed by a closing tag
					if(tagEnd < line.length && line[tagEnd] != '<') {
						// There's text content after the opening tag
						size_t textEnd = tagEnd;
						while(textEnd < line.length && line[textEnd] != '<')
							textEnd++;

						if(textEnd < line.length && line[textEnd] == '<'
								&& textEnd + 1 < line.length && line[textEnd + 1] == '/') {
							// Found closing tag after text - keep as one token
							size_t closeEnd = textEnd + 1;
							while(closeEnd < line.length && line[closeEnd] != '>')
								closeEnd++;
							if(closeEnd < line.length)
								closeEnd++;

							tokens ~= line[i .. closeEnd];
							i = closeEnd;
							continue;
						} else {
							// Text followed by another opening tag or end of line
							tokens ~= tag;
							// Add the text as its own token
							string textContent = line[tagEnd .. textEnd].strip();
							if(textContent.length > 0)
								tokens ~= textContent;
							i = textEnd;
							continue;
						}
					} else {
						tokens ~= tag;
						i = tagEnd;
					}
				} else {
					// Text content not starting with <
					size_t textEnd = i;
					while(textEnd < line.length && line[textEnd] != '<')
						textEnd++;

					string textContent = line[i .. textEnd].strip();
					if(textContent.length > 0)
						tokens ~= textContent;
					i = textEnd;
				}
			}
		}

		return tokens;
	}

	void parseDeclarations(string[] lines, ref size_t pos, ref SymbolInfo[] symbols,
			string currentVisibility, bool includePrivate)
	{
		while(pos < lines.length) {
			auto tag = parseTag(lines[pos]);

			if(tag.isClosing && (tag.name == "module" || tag.name == "structBody")) {
				pos++;
				return;
			}

			if(tag.name == "declaration" && !tag.isClosing) {
				pos++;
				parseDeclaration(lines, pos, symbols, currentVisibility, includePrivate);
				continue;
			}

			// Skip moduleDeclaration
			if(tag.name == "moduleDeclaration" && !tag.isClosing) {
				skipToClosingTag(lines, pos, "moduleDeclaration");
				continue;
			}

			pos++;
		}
	}

	void parseDeclaration(string[] lines, ref size_t pos, ref SymbolInfo[] symbols,
			string currentVisibility, bool includePrivate)
	{
		// A declaration can contain:
		// - attribute tags (visibility, @safe, etc.) followed by the actual declaration
		// - the actual declaration (classDeclaration, structDeclaration, etc.)
		string visibility = currentVisibility;
		string[] attributes;

		while(pos < lines.length) {
			auto tag = parseTag(lines[pos]);

			if(tag.isClosing && tag.name == "declaration") {
				pos++;
				return;
			}

			// Visibility/attribute tag
			if(tag.name == "attribute" && !tag.isClosing) {
				if("attribute" in tag.attrs) {
					string attr = tag.attrs["attribute"];
					if(attr == "public" || attr == "private"
							|| attr == "protected" || attr == "package") {
						visibility = attr;
					} else {
						attributes ~= attr;
					}
				}
				pos++;
				// Only parse inner content if not self-closing
				if(!tag.isSelfClosing)
					parseAttributeContent(lines, pos, attributes);
				continue;
			}

			// Class declaration
			if(tag.name == "classDeclaration" && !tag.isClosing) {
				auto sym = parseClassOrStruct(lines, pos, "class", tag,
						visibility, attributes, includePrivate);
				if(includePrivate || visibility != "private")
					symbols ~= sym;
				continue;
			}

			// Struct declaration
			if(tag.name == "structDeclaration" && !tag.isClosing) {
				auto sym = parseClassOrStruct(lines, pos, "struct", tag,
						visibility, attributes, includePrivate);
				if(includePrivate || visibility != "private")
					symbols ~= sym;
				continue;
			}

			// Interface declaration
			if(tag.name == "interfaceDeclaration" && !tag.isClosing) {
				auto sym = parseClassOrStruct(lines, pos, "interface", tag,
						visibility, attributes, includePrivate);
				if(includePrivate || visibility != "private")
					symbols ~= sym;
				continue;
			}

			// Union declaration
			if(tag.name == "unionDeclaration" && !tag.isClosing) {
				auto sym = parseClassOrStruct(lines, pos, "union_", tag,
						visibility, attributes, includePrivate);
				if(includePrivate || visibility != "private")
					symbols ~= sym;
				continue;
			}

			// Function declaration
			if(tag.name == "functionDeclaration" && !tag.isClosing) {
				auto sym = parseFunctionDeclaration(lines, pos, tag, visibility, attributes);
				if(includePrivate || visibility != "private")
					symbols ~= sym;
				continue;
			}

			// Constructor
			if(tag.name == "constructor" && !tag.isClosing) {
				auto sym = parseConstructor(lines, pos, visibility, attributes);
				if(includePrivate || visibility != "private")
					symbols ~= sym;
				continue;
			}

			// Destructor
			if(tag.name == "destructor" && !tag.isClosing) {
				auto sym = SymbolInfo();
				sym.name = "~this";
				sym.kind = "function";
				sym.visibility = visibility;
				sym.attributes = attributes;
				skipToClosingTag(lines, pos, "destructor");
				if(includePrivate || visibility != "private")
					symbols ~= sym;
				continue;
			}

			// Variable declaration
			if(tag.name == "variableDeclaration" && !tag.isClosing) {
				auto syms = parseVariableDeclaration(lines, pos, visibility, attributes);
				foreach(sym; syms) {
					if(includePrivate || visibility != "private")
						symbols ~= sym;
				}
				continue;
			}

			// Enum declaration
			if(tag.name == "enumDeclaration" && !tag.isClosing) {
				auto sym = parseEnumDeclaration(lines, pos, tag, visibility, attributes);
				if(includePrivate || visibility != "private")
					symbols ~= sym;
				continue;
			}

			// Alias declaration
			if(tag.name == "aliasDeclaration" && !tag.isClosing) {
				auto sym = parseAliasDeclaration(lines, pos, visibility, attributes);
				if(sym.name.length > 0 && (includePrivate || visibility != "private"))
					symbols ~= sym;
				continue;
			}

			// Import declaration - skip
			if(tag.name == "importDeclaration" && !tag.isClosing) {
				skipToClosingTag(lines, pos, "importDeclaration");
				continue;
			}

			// Template declaration
			if(tag.name == "templateDeclaration" && !tag.isClosing) {
				auto sym = parseTemplateDeclaration(lines, pos, tag,
						visibility, attributes, includePrivate);
				if(includePrivate || visibility != "private")
					symbols ~= sym;
				continue;
			}

			// Static constructor/destructor, unittest, etc. - skip
			if(!tag.isClosing && (tag.name == "staticConstructor" || tag.name == "staticDestructor"
					|| tag.name == "sharedStaticConstructor"
					|| tag.name == "sharedStaticDestructor" || tag.name == "unittest_")) {
				skipToClosingTag(lines, pos, tag.name);
				continue;
			}

			// Storage class (auto, etc.)
			if(tag.name == "storageClass" && !tag.isClosing) {
				skipToClosingTag(lines, pos, "storageClass");
				continue;
			}

			pos++;
		}
	}

	void parseAttributeContent(string[] lines, ref size_t pos, ref string[] attributes)
	{
		while(pos < lines.length) {
			auto tag = parseTag(lines[pos]);

			if(tag.isClosing && tag.name == "attribute") {
				pos++;
				return;
			}

			if(tag.name == "atAttribute" && !tag.isClosing) {
				pos++;
				// Next line should be <identifier>safe</identifier> or similar
				while(pos < lines.length) {
					auto innerTag = parseTag(lines[pos]);
					if(innerTag.isClosing && innerTag.name == "atAttribute") {
						pos++;
						break;
					}
					if(innerTag.name == "identifier" && innerTag.textContent.length > 0) {
						attributes ~= "@" ~ innerTag.textContent;
					}
					pos++;
				}
				continue;
			}

			// Some attributes are just text content like "nothrow", "pure"
			if(!tag.name.startsWith("<") && lines[pos].strip().length > 0
					&& !lines[pos].strip().startsWith("<")) {
				// Raw text attribute
				auto stripped = lines[pos].strip();
				if(stripped == "nothrow" || stripped == "pure" || stripped == "const"
						|| stripped == "immutable" || stripped == "shared"
						|| stripped == "static" || stripped == "override"
						|| stripped == "final" || stripped == "abstract" || stripped == "extern") {
					attributes ~= stripped;
				}
			}

			pos++;
		}
	}

	SymbolInfo parseClassOrStruct(string[] lines, ref size_t pos, string kind,
			XmlTag openTag, string visibility, string[] attributes, bool includePrivate)
	{
		SymbolInfo sym;
		sym.kind = kind;
		sym.visibility = visibility;
		sym.attributes = attributes;

		if("line" in openTag.attrs)
			sym.line = tryParseInt(openTag.attrs["line"]);

		string closingTag = openTag.name.endsWith("Declaration") ? openTag.name
			: kind ~ "Declaration";
		pos++;

		while(pos < lines.length) {
			auto tag = parseTag(lines[pos]);

			if(tag.isClosing && tag.name == closingTag) {
				pos++;
				return sym;
			}

			if(tag.name == "name" && tag.textContent.length > 0) {
				sym.name = tag.textContent;
				pos++;
				continue;
			}

			if(tag.name == "ddoc" && tag.textContent.length > 0) {
				sym.ddoc = tag.textContent;
				pos++;
				continue;
			}

			if(tag.name == "templateParameters" && !tag.isClosing) {
				sym.templateParams = parseTemplateParams(lines, pos);
				continue;
			}

			// Parse the body for children
			if(tag.name == "structBody" && !tag.isClosing) {
				pos++;
				parseDeclarations(lines, pos, sym.children, "public", includePrivate);
				continue;
			}

			// Base class list - skip for now
			if(tag.name == "baseClassList" && !tag.isClosing) {
				skipToClosingTag(lines, pos, "baseClassList");
				continue;
			}

			pos++;
		}

		return sym;
	}

	SymbolInfo parseFunctionDeclaration(string[] lines, ref size_t pos,
			XmlTag openTag, string visibility, string[] attributes)
	{
		SymbolInfo sym;
		sym.kind = "function";
		sym.visibility = visibility;
		sym.attributes = attributes.dup;

		if("line" in openTag.attrs)
			sym.line = tryParseInt(openTag.attrs["line"]);

		pos++;

		while(pos < lines.length) {
			auto tag = parseTag(lines[pos]);

			if(tag.isClosing && tag.name == "functionDeclaration") {
				pos++;
				return sym;
			}

			if(tag.name == "name" && tag.textContent.length > 0) {
				sym.name = tag.textContent;
				pos++;
				continue;
			}

			if(tag.name == "ddoc" && tag.textContent.length > 0) {
				sym.ddoc = tag.textContent;
				pos++;
				continue;
			}

			if(tag.name == "type" && !tag.isClosing) {
				if("pretty" in tag.attrs)
					sym.returnType = tag.attrs["pretty"];
				skipToClosingTag(lines, pos, "type");
				continue;
			}

			if(tag.name == "parameters" && !tag.isClosing) {
				sym.parameters = parseParameters(lines, pos);
				continue;
			}

			if(tag.name == "templateParameters" && !tag.isClosing) {
				sym.templateParams = parseTemplateParams(lines, pos);
				continue;
			}

			if(tag.name == "memberFunctionAttribute" && !tag.isClosing) {
				parseMemberFunctionAttribute(lines, pos, sym.attributes);
				continue;
			}

			// Skip function body
			if(tag.name == "functionBody" && !tag.isClosing) {
				skipToClosingTag(lines, pos, "functionBody");
				continue;
			}

			// Storage class (auto, ref, etc.)
			if(tag.name == "storageClass" && !tag.isClosing) {
				skipToClosingTag(lines, pos, "storageClass");
				continue;
			}

			pos++;
		}

		return sym;
	}

	SymbolInfo parseConstructor(string[] lines, ref size_t pos,
			string visibility, string[] attributes)
	{
		SymbolInfo sym;
		sym.name = "this";
		sym.kind = "constructor";
		sym.visibility = visibility;
		sym.attributes = attributes.dup;

		pos++;

		while(pos < lines.length) {
			auto tag = parseTag(lines[pos]);

			if(tag.isClosing && tag.name == "constructor") {
				pos++;
				return sym;
			}

			if(tag.name == "parameters" && !tag.isClosing) {
				sym.parameters = parseParameters(lines, pos);
				continue;
			}

			if(tag.name == "templateParameters" && !tag.isClosing) {
				sym.templateParams = parseTemplateParams(lines, pos);
				continue;
			}

			if(tag.name == "memberFunctionAttribute" && !tag.isClosing) {
				parseMemberFunctionAttribute(lines, pos, sym.attributes);
				continue;
			}

			if(tag.name == "functionBody" && !tag.isClosing) {
				skipToClosingTag(lines, pos, "functionBody");
				continue;
			}

			pos++;
		}

		return sym;
	}

	SymbolInfo[] parseVariableDeclaration(string[] lines, ref size_t pos,
			string visibility, string[] attributes)
	{
		SymbolInfo[] results;
		string typeName;

		pos++;

		while(pos < lines.length) {
			auto tag = parseTag(lines[pos]);

			if(tag.isClosing && tag.name == "variableDeclaration") {
				pos++;
				return results;
			}

			if(tag.name == "type" && !tag.isClosing) {
				if("pretty" in tag.attrs)
					typeName = tag.attrs["pretty"];
				skipToClosingTag(lines, pos, "type");
				continue;
			}

			if(tag.name == "declarator" && !tag.isClosing) {
				SymbolInfo sym;
				sym.kind = "variable";
				sym.visibility = visibility;
				sym.attributes = attributes;
				sym.returnType = typeName;

				if("line" in tag.attrs)
					sym.line = tryParseInt(tag.attrs["line"]);

				pos++;
				while(pos < lines.length) {
					auto innerTag = parseTag(lines[pos]);
					if(innerTag.isClosing && innerTag.name == "declarator") {
						pos++;
						break;
					}
					if(innerTag.name == "name" && innerTag.textContent.length > 0) {
						sym.name = innerTag.textContent;
					}
					pos++;
				}

				if(sym.name.length > 0)
					results ~= sym;
				continue;
			}

			pos++;
		}

		return results;
	}

	SymbolInfo parseEnumDeclaration(string[] lines, ref size_t pos, XmlTag openTag,
			string visibility, string[] attributes)
	{
		SymbolInfo sym;
		sym.kind = "enum";
		sym.visibility = visibility;
		sym.attributes = attributes;

		if("line" in openTag.attrs)
			sym.line = tryParseInt(openTag.attrs["line"]);

		pos++;

		while(pos < lines.length) {
			auto tag = parseTag(lines[pos]);

			if(tag.isClosing && tag.name == "enumDeclaration") {
				pos++;
				return sym;
			}

			if(tag.name == "name" && tag.textContent.length > 0) {
				sym.name = tag.textContent;
				pos++;
				continue;
			}

			if(tag.name == "ddoc" && tag.textContent.length > 0) {
				sym.ddoc = tag.textContent;
				pos++;
				continue;
			}

			if(tag.name == "enumBody" && !tag.isClosing) {
				pos++;
				parseEnumMembers(lines, pos, sym.children);
				continue;
			}

			// Base type for the enum
			if(tag.name == "type" && !tag.isClosing) {
				if("pretty" in tag.attrs)
					sym.returnType = tag.attrs["pretty"];
				skipToClosingTag(lines, pos, "type");
				continue;
			}

			pos++;
		}

		return sym;
	}

	void parseEnumMembers(string[] lines, ref size_t pos, ref SymbolInfo[] members)
	{
		while(pos < lines.length) {
			auto tag = parseTag(lines[pos]);

			if(tag.isClosing && tag.name == "enumBody") {
				pos++;
				return;
			}

			if(tag.name == "enumMember" && !tag.isClosing) {
				SymbolInfo member;
				member.kind = "enum_member";
				member.visibility = "public";

				if("line" in tag.attrs)
					member.line = tryParseInt(tag.attrs["line"]);

				pos++;
				while(pos < lines.length) {
					auto innerTag = parseTag(lines[pos]);
					if(innerTag.isClosing && innerTag.name == "enumMember") {
						pos++;
						break;
					}
					if(innerTag.name == "identifier" && innerTag.textContent.length > 0) {
						member.name = innerTag.textContent;
					}
					if(innerTag.name == "ddoc" && innerTag.textContent.length > 0) {
						member.ddoc = innerTag.textContent;
					}
					pos++;
				}

				if(member.name.length > 0)
					members ~= member;
				continue;
			}

			pos++;
		}
	}

	SymbolInfo parseAliasDeclaration(string[] lines, ref size_t pos,
			string visibility, string[] attributes)
	{
		SymbolInfo sym;
		sym.kind = "alias_";
		sym.visibility = visibility;
		sym.attributes = attributes;

		pos++;

		while(pos < lines.length) {
			auto tag = parseTag(lines[pos]);

			if(tag.isClosing && tag.name == "aliasDeclaration") {
				pos++;
				return sym;
			}

			if(tag.name == "name" && tag.textContent.length > 0) {
				sym.name = tag.textContent;
				pos++;
				continue;
			}

			if(tag.name == "identifier" && tag.textContent.length > 0 && sym.name.length == 0) {
				sym.name = tag.textContent;
				pos++;
				continue;
			}

			pos++;
		}

		return sym;
	}

	SymbolInfo parseTemplateDeclaration(string[] lines, ref size_t pos,
			XmlTag openTag, string visibility, string[] attributes, bool includePrivate)
	{
		SymbolInfo sym;
		sym.kind = "template";
		sym.visibility = visibility;
		sym.attributes = attributes;

		if("line" in openTag.attrs)
			sym.line = tryParseInt(openTag.attrs["line"]);

		pos++;

		while(pos < lines.length) {
			auto tag = parseTag(lines[pos]);

			if(tag.isClosing && tag.name == "templateDeclaration") {
				pos++;
				return sym;
			}

			if(tag.name == "name" && tag.textContent.length > 0) {
				sym.name = tag.textContent;
				pos++;
				continue;
			}

			if(tag.name == "ddoc" && tag.textContent.length > 0) {
				sym.ddoc = tag.textContent;
				pos++;
				continue;
			}

			if(tag.name == "templateParameters" && !tag.isClosing) {
				sym.templateParams = parseTemplateParams(lines, pos);
				continue;
			}

			// Template body contains declarations
			if(tag.name == "declaration" && !tag.isClosing) {
				pos++;
				parseDeclaration(lines, pos, sym.children, "public", includePrivate);
				continue;
			}

			pos++;
		}

		return sym;
	}

	ParamInfo[] parseParameters(string[] lines, ref size_t pos)
	{
		ParamInfo[] params;
		pos++;

		while(pos < lines.length) {
			auto tag = parseTag(lines[pos]);

			if(tag.isClosing && tag.name == "parameters") {
				pos++;
				return params;
			}

			if(tag.name == "parameter" && !tag.isClosing) {
				ParamInfo param;
				pos++;

				while(pos < lines.length) {
					auto innerTag = parseTag(lines[pos]);
					if(innerTag.isClosing && innerTag.name == "parameter") {
						pos++;
						break;
					}

					if(innerTag.name == "name" && innerTag.textContent.length > 0) {
						param.name = innerTag.textContent;
					}
					if(innerTag.name == "type" && !innerTag.isClosing) {
						if("pretty" in innerTag.attrs)
							param.type = innerTag.attrs["pretty"];
						skipToClosingTag(lines, pos, "type");
						continue;
					}
					pos++;
				}

				if(param.name.length > 0 || param.type.length > 0)
					params ~= param;
				continue;
			}

			pos++;
		}

		return params;
	}

	string[] parseTemplateParams(string[] lines, ref size_t pos)
	{
		string[] tparams;
		pos++;

		while(pos < lines.length) {
			auto tag = parseTag(lines[pos]);

			if(tag.isClosing && tag.name == "templateParameters") {
				pos++;
				return tparams;
			}

			if(tag.name == "identifier" && tag.textContent.length > 0) {
				tparams ~= tag.textContent;
			}

			pos++;
		}

		return tparams;
	}

	void parseMemberFunctionAttribute(string[] lines, ref size_t pos, ref string[] attributes)
	{
		pos++;

		while(pos < lines.length) {
			auto tag = parseTag(lines[pos]);

			if(tag.isClosing && tag.name == "memberFunctionAttribute") {
				pos++;
				return;
			}

			if(tag.name == "atAttribute" && !tag.isClosing) {
				pos++;
				while(pos < lines.length) {
					auto innerTag = parseTag(lines[pos]);
					if(innerTag.isClosing && innerTag.name == "atAttribute") {
						pos++;
						break;
					}
					if(innerTag.name == "identifier" && innerTag.textContent.length > 0) {
						attributes ~= "@" ~ innerTag.textContent;
					}
					pos++;
				}
				continue;
			}

			// Plain text attributes like "const", "nothrow"
			string stripped = lines[pos].strip();
			if(stripped.length > 0 && !stripped.startsWith("<") && !stripped.startsWith("/")) {
				if(stripped == "const" || stripped == "nothrow" || stripped == "pure"
						|| stripped == "immutable" || stripped == "shared"
						|| stripped == "inout" || stripped == "return" || stripped == "scope") {
					attributes ~= stripped;
				}
			}

			pos++;
		}
	}

	void skipToClosingTag(string[] lines, ref size_t pos, string tagName)
	{
		int depth = 1;
		pos++;

		while(pos < lines.length && depth > 0) {
			auto tag = parseTag(lines[pos]);
			if(tag.name == tagName) {
				if(tag.isClosing)
					depth--;
				else
					depth++;
			}
			pos++;
		}
	}

	XmlTag parseTag(string line)
	{
		XmlTag result;
		auto stripped = line.strip();

		if(stripped.length == 0 || stripped[0] != '<') {
			// Not a tag - could be text content
			return result;
		}

		// Handle closing tags: </name>
		if(stripped.length > 1 && stripped[1] == '/') {
			result.isClosing = true;
			auto endIdx = stripped.indexOf('>');
			if(endIdx > 2)
				result.name = stripped[2 .. endIdx];
			return result;
		}

		// Handle <?xml ...?> declaration
		if(stripped.length > 1 && stripped[1] == '?') {
			result.name = "?xml";
			return result;
		}

		// Find the tag name
		size_t i = 1;
		while(i < stripped.length && stripped[i] != ' ' && stripped[i] != '>' && stripped[i] != '/')
			i++;

		result.name = stripped[1 .. i];

		// Parse attributes
		while(i < stripped.length && stripped[i] != '>' && stripped[i] != '/') {
			// Skip whitespace
			while(i < stripped.length && stripped[i] == ' ')
				i++;

			if(i >= stripped.length || stripped[i] == '>' || stripped[i] == '/')
				break;

			// Read attribute name
			size_t nameStart = i;
			while(i < stripped.length && stripped[i] != '=' && stripped[i] != '>'
					&& stripped[i] != ' ')
				i++;

			if(i >= stripped.length || stripped[i] != '=')
				break;

			string attrName = stripped[nameStart .. i];
			i++; // skip =

			if(i >= stripped.length || stripped[i] != '"')
				break;

			i++; // skip opening quote
			size_t valStart = i;
			while(i < stripped.length && stripped[i] != '"')
				i++;

			result.attrs[attrName] = stripped[valStart .. i];
			if(i < stripped.length)
				i++; // skip closing quote
		}

		// Check self-closing
		if(stripped.endsWith("/>")) {
			result.isSelfClosing = true;
		}

		// Check for inline text content: <tag>content</tag>
		auto gtIdx = stripped.indexOf('>');
		if(gtIdx >= 0 && gtIdx + 1 < stripped.length) {
			auto afterTag = stripped[gtIdx + 1 .. $];
			auto closeIdx = afterTag.indexOf("</");
			if(closeIdx >= 0) {
				result.textContent = afterTag[0 .. closeIdx];
			}
		}

		return result;
	}

	string formatSymbolsAsJson(SymbolInfo[] symbols)
	{
		auto arr = JSONValue(cast(JSONValue[])[]);
		foreach(ref sym; symbols) {
			arr.array ~= symbolToJson(sym);
		}

		// Pretty-print with 2-space indent
		return arr.toPrettyString();
	}

	JSONValue symbolToJson(ref SymbolInfo sym)
	{
		auto obj = JSONValue(cast(string[string])null);

		obj["name"] = sym.name;
		obj["kind"] = sym.kind;
		if(sym.line > 0)
			obj["line"] = sym.line;
		if(sym.visibility.length > 0)
			obj["visibility"] = sym.visibility;
		if(sym.attributes.length > 0) {
			auto attrArr = JSONValue(cast(JSONValue[])[]);
			foreach(attr; sym.attributes)
				attrArr.array ~= JSONValue(attr);
			obj["attributes"] = attrArr;
		}
		if(sym.returnType.length > 0)
			obj["type"] = sym.returnType;
		if(sym.parameters.length > 0) {
			auto paramArr = JSONValue(cast(JSONValue[])[]);
			foreach(ref p; sym.parameters) {
				auto pObj = JSONValue(cast(string[string])null);
				if(p.name.length > 0)
					pObj["name"] = p.name;
				if(p.type.length > 0)
					pObj["type"] = p.type;
				paramArr.array ~= pObj;
			}
			obj["parameters"] = paramArr;
		}
		if(sym.templateParams.length > 0) {
			auto tpArr = JSONValue(cast(JSONValue[])[]);
			foreach(tp; sym.templateParams)
				tpArr.array ~= JSONValue(tp);
			obj["templateParams"] = tpArr;
		}
		if(sym.ddoc.length > 0)
			obj["doc"] = sym.ddoc;
		if(sym.children.length > 0) {
			auto childArr = JSONValue(cast(JSONValue[])[]);
			foreach(ref child; sym.children)
				childArr.array ~= symbolToJson(child);
			obj["children"] = childArr;
		}

		return obj;
	}
}
