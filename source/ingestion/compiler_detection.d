/** Compiler detection and import path resolution for D compilers. */
module ingestion.compiler_detection;

import std.process;
import std.string;
import std.stdio;
import std.path;
import std.file;
import std.array;
import std.regex;

struct CompilerPaths
{
    string importPath;
    string stdPath;
    string corePath;
    string etcPath;
    string compilerName;

    bool isValid() const
    {
        return importPath.length > 0 && exists(importPath);
    }
}

CompilerPaths detectCompilerPaths()
{
    CompilerPaths result;

    string[] compilers = ["ldc2", "ldc", "dmd"];
    string compiler = null;

    foreach(c; compilers)
    {
        auto p = execute(["which", c], null, Config.none, 5000);
        if(p.status == 0 && p.output.strip().length > 0)
        {
            compiler = c;
            break;
        }
    }

    if(compiler is null)
    {
        stderr.writeln("No D compiler found (tried ldc2, ldc, dmd)");
        return result;
    }

    result.compilerName = compiler;

    auto execResult = execute([compiler, "-v", "-o-", "/dev/null"], null, Config.none, 10000);
    string output = execResult.output ~ execResult.output;

    auto importMatch = matchFirst(output, regex(`import path\[\d+\]\s*=\s*(.+)`));
    if(!importMatch.empty)
    {
        result.importPath = importMatch.captures[1].strip();
    }
    else
    {
        auto pathMatch = matchFirst(output, regex(`-I([^\s]+)`));
        if(!pathMatch.empty)
        {
            result.importPath = pathMatch.captures[1].strip();
        }
    }

    if(result.importPath.length > 0)
    {
        result.stdPath = buildPath(result.importPath, "std");
        result.corePath = buildPath(result.importPath, "core");
        result.etcPath = buildPath(result.importPath, "etc");
    }

    return result;
}

bool isSpecialPackage(string packageName)
{
    return packageName == "phobos" || packageName == "core" || packageName == "etc";
}

string getSpecialPackagePath(string packageName, CompilerPaths paths)
{
    final switch(packageName)
    {
    case "phobos":
        return paths.stdPath;
    case "core":
        return paths.corePath;
    case "etc":
        return paths.etcPath;
    }
}
