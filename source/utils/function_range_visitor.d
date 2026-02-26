/**
 * Extracts function boundaries from D source code using libdparse.
 *
 * Parses D source and returns the start/end line of each function,
 * constructor, destructor, and unittest block, along with the
 * enclosing class/struct/interface name (if any).
 */
module utils.function_range_visitor;

import dparse.ast;
import dparse.lexer : Token, tok, getTokensForParser, LexerConfig, StringCache;
import dparse.parser : parseModule;
import dparse.rollback_allocator : RollbackAllocator;

/// Describes the source range of a single function-like declaration.
struct FunctionRange {
	/// Function name (e.g. "execute"). Empty for unittest blocks.
	string name;
	/// Enclosing class/struct/interface name, empty for free functions.
	string parentName;
	/// 1-based line of the function declaration.
	size_t startLine;
	/// 1-based line of the closing brace (or last token).
	size_t endLine;
	/// One of "function", "constructor", "destructor", "unittest".
	string kind;
}

/**
 * Lex and parse D source code, then walk the AST to extract function ranges.
 *
 * Params:
 *   source = D source code as a string
 *   fileName = optional file name for error messages
 * Returns:
 *   array of `FunctionRange` structs
 */
FunctionRange[] extractFunctionRanges(string source, string fileName = "<input>")
{
	LexerConfig config;
	config.fileName = fileName;
	auto cache = StringCache(StringCache.defaultBucketCount);
	auto tokens = getTokensForParser(source, config, &cache);

	RollbackAllocator rba;
	auto mod = parseModule(tokens, fileName, &rba);

	auto visitor = new FunctionRangeVisitor(tokens);
	visitor.visit(mod);
	return visitor.ranges;
}

private class FunctionRangeVisitor : ASTVisitor {
	// Bring in all base-class visit overloads so we don't hide them.
	alias visit = ASTVisitor.visit;

	FunctionRange[] ranges;

	private string[] parentStack;
	private const(Token)[] allTokens;

	this(const(Token)[] tokens)
	{
		allTokens = tokens;
	}

	private string currentParent() const
	{
		return parentStack.length > 0 ? parentStack[$ - 1] : "";
	}

	// --- Aggregate type tracking (push/pop parent name) ---

	override void visit(const ClassDeclaration decl)
	{
		parentStack ~= decl.name.text.idup;
		decl.accept(this);
		parentStack = parentStack[0 .. $ - 1];
	}

	override void visit(const StructDeclaration decl)
	{
		parentStack ~= decl.name.text.idup;
		decl.accept(this);
		parentStack = parentStack[0 .. $ - 1];
	}

	override void visit(const InterfaceDeclaration decl)
	{
		parentStack ~= decl.name.text.idup;
		decl.accept(this);
		parentStack = parentStack[0 .. $ - 1];
	}

	// --- Function-like declarations ---

	override void visit(const FunctionDeclaration decl)
	{
		auto endLine = getEndLine(decl);
		if(endLine > 0) {
			ranges ~= FunctionRange(decl.name.text.idup, currentParent(),
					decl.name.line, endLine, "function");
		}
		decl.accept(this);
	}

	override void visit(const Constructor decl)
	{
		auto endLine = getEndLine(decl);
		if(endLine > 0) {
			ranges ~= FunctionRange("this", currentParent(), decl.line, endLine, "constructor");
		}
		decl.accept(this);
	}

	override void visit(const Destructor decl)
	{
		auto endLine = getEndLine(decl);
		if(endLine > 0) {
			ranges ~= FunctionRange("~this", currentParent(), decl.line, endLine, "destructor");
		}
		decl.accept(this);
	}

	override void visit(const Unittest decl)
	{
		auto endLine = getEndLine(decl);
		if(endLine > 0) {
			ranges ~= FunctionRange("", currentParent(), decl.line, endLine, "unittest");
		}
		decl.accept(this);
	}

	// --- End-line helpers ---

	/// Get end line from any BaseNode by looking at its tokens slice.
	private size_t getEndLine(const BaseNode node)
	{
		if(node.tokens.length > 0)
			return node.tokens[$ - 1].line;
		return 0;
	}
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

unittest {
	// Free function range detection
	enum src = q{
void foo()
{
    int x = 1;
}

int bar(int a)
{
    return a + 1;
}
};
	auto ranges = extractFunctionRanges(src);
	assert(ranges.length == 2, "Expected 2 functions");

	// foo
	assert(ranges[0].name == "foo", "Expected 'foo', got: " ~ ranges[0].name);
	assert(ranges[0].kind == "function");
	assert(ranges[0].parentName == "");
	assert(ranges[0].startLine >= 2);
	assert(ranges[0].endLine >= ranges[0].startLine);

	// bar
	assert(ranges[1].name == "bar", "Expected 'bar', got: " ~ ranges[1].name);
	assert(ranges[1].kind == "function");
	assert(ranges[1].parentName == "");
	assert(ranges[1].startLine > ranges[0].endLine);
	assert(ranges[1].endLine >= ranges[1].startLine);
}

unittest {
	// Methods in a class
	enum src = q{
class MyClass
{
    void method1()
    {
        int a = 0;
    }

    int method2(int x)
    {
        return x * 2;
    }
}
};
	auto ranges = extractFunctionRanges(src);
	assert(ranges.length == 2, "Expected 2 methods");

	assert(ranges[0].name == "method1");
	assert(ranges[0].parentName == "MyClass");
	assert(ranges[0].kind == "function");

	assert(ranges[1].name == "method2");
	assert(ranges[1].parentName == "MyClass");
	assert(ranges[1].kind == "function");
}

unittest {
	// Nested struct methods
	enum src = q{
class Outer
{
    void outerMethod()
    {
    }

    struct Inner
    {
        void innerMethod()
        {
        }
    }
}
};
	auto ranges = extractFunctionRanges(src);
	assert(ranges.length == 2, "Expected 2 methods");

	// outerMethod belongs to Outer
	assert(ranges[0].name == "outerMethod");
	assert(ranges[0].parentName == "Outer");

	// innerMethod belongs to Inner
	assert(ranges[1].name == "innerMethod");
	assert(ranges[1].parentName == "Inner");
}

unittest {
	// Constructor, destructor and unittest detection
	enum src = q{
class Foo
{
    this()
    {
    }

    ~this()
    {
    }
}

unittest
{
    int x = 1;
}
};
	auto ranges = extractFunctionRanges(src);
	assert(ranges.length == 3, "Expected 3 ranges");

	assert(ranges[0].kind == "constructor");
	assert(ranges[0].name == "this");
	assert(ranges[0].parentName == "Foo");

	assert(ranges[1].kind == "destructor");
	assert(ranges[1].name == "~this");
	assert(ranges[1].parentName == "Foo");

	assert(ranges[2].kind == "unittest");
	assert(ranges[2].name == "");
	assert(ranges[2].parentName == "");
}

unittest {
	// Interface with default method implementations
	enum src = q{
interface Serializable
{
    void serialize()
    {
        // default implementation
    }

    int priority()
    {
        return 0;
    }
}
};
	auto ranges = extractFunctionRanges(src);
	assert(ranges.length == 2, "Expected 2 methods in interface");

	assert(ranges[0].name == "serialize");
	assert(ranges[0].parentName == "Serializable");
	assert(ranges[0].kind == "function");
	assert(ranges[0].endLine >= ranges[0].startLine);

	assert(ranges[1].name == "priority");
	assert(ranges[1].parentName == "Serializable");
	assert(ranges[1].kind == "function");
	assert(ranges[1].endLine >= ranges[1].startLine);
}

unittest {
	// Empty source produces no ranges (exercises getEndLine returning 0 path)
	enum src = q{};
	auto ranges = extractFunctionRanges(src);
	assert(ranges.length == 0, "Expected 0 ranges for empty source");
}
