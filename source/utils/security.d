/**
 * Security utilities for input validation.
 *
 * Provides compiler validation used across MCP tools to prevent
 * arbitrary code execution via untrusted compiler paths.
 */
module utils.security;

/**
 * Security-specific exception thrown when a security check fails.
 *
 * Caught by tool-level exception handlers and returned as a tool error
 * result to the client.
 */
class SecurityException : Exception {
	this(string msg, string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, file, line);
	}
}

// ---------------------------------------------------------------------------
// Compiler Validation
// ---------------------------------------------------------------------------

/// Allowed D compiler names.
private immutable string[] _validCompilers = ["dmd", "ldc2", "gdc"];

/**
 * Validate a compiler name against the allowlist.
 *
 * Params:
 *     compiler = The compiler name to validate.
 *
 * Returns:
 *     The compiler name if valid.
 *
 * Throws:
 *     SecurityException if the compiler is not in the allowlist.
 */
string validateCompiler(string compiler)
{
	foreach(valid; _validCompilers) {
		if(compiler == valid)
			return compiler;
	}
	throw new SecurityException("Compiler must be 'dmd', 'ldc2', or 'gdc'");
}
