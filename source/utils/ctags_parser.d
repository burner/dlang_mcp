module utils.ctags_parser;

import std.stdio : File;
import std.string : split, strip, indexOf;
import std.regex : regex, match;
import std.file : exists;
import std.algorithm.searching : startsWith;

struct CtagsEntry
{
    string symbol;
    string file;
    int line;
    string kind;
    string scopeName;
    string access;
}

CtagsEntry parseCtagsLine(string line)
{
    if (line.length == 0 || line[0] == '!')
        return CtagsEntry.init;

    auto parts = line.split('\t');
    if (parts.length < 3)
        return CtagsEntry.init;

    CtagsEntry entry;
    entry.symbol = parts[0];
    entry.file = parts[1];

    string lineField = parts[2];
    auto semiIdx = lineField.indexOf(";\t\"");
    if (semiIdx >= 0)
    {
        lineField = lineField[0 .. semiIdx];
    }
    entry.line = parseLineField(lineField);

    for (size_t i = 3; i < parts.length; i++)
    {
        auto field = parts[i];
        if (field.length == 1)
        {
            entry.kind = field;
        }
        else if (field.startsWith("line:"))
        {
            entry.line = parseLineField(field[5 .. $]);
        }
        else if (field.startsWith("class:") || field.startsWith("struct:") || field.startsWith("enum:"))
        {
            auto colonIdx = field.indexOf(':');
            if (colonIdx >= 0)
            {
                entry.scopeName = field[colonIdx + 1 .. $];
            }
        }
        else if (field.startsWith("access:"))
        {
            entry.access = field[7 .. $];
        }
    }

    return entry;
}

int parseLineField(string field)
{
    import std.conv : to;
    try
    {
        return to!int(field.strip());
    }
    catch (Exception)
    {
        return 0;
    }
}

CtagsEntry[] parseCtagsFile(string tagsPath)
{
    CtagsEntry[] entries;

    if (!exists(tagsPath))
        return entries;

    auto file = File(tagsPath, "r");
    foreach (string line; file.byLineCopy)
    {
        auto entry = parseCtagsLine(line.strip());
        if (entry.symbol.length > 0)
        {
            entries ~= entry;
        }
    }

    return entries;
}

CtagsEntry[] searchEntries(CtagsEntry[] entries, string query, string matchType, string kindFilter)
{
    CtagsEntry[] results;

    foreach (entry; entries)
    {
        if (kindFilter.length > 0 && entry.kind != kindFilter)
            continue;

        bool matches = false;
        switch (matchType)
        {
        case "exact":
            matches = (entry.symbol == query);
            break;
        case "prefix":
            matches = entry.symbol.startsWith(query);
            break;
        case "regex":
            try
            {
                auto pattern = regex(query);
                matches = !match(entry.symbol, pattern).empty;
            }
            catch (Exception)
            {
                matches = (entry.symbol == query);
            }
            break;
        default:
            matches = (entry.symbol == query);
        }

        if (matches)
            results ~= entry;
    }

    return results;
}

string formatEntry(ref const CtagsEntry entry)
{
    import std.conv : text;
    string result = entry.symbol ~ "\t" ~ entry.file ~ ":" ~ text(entry.line);
    if (entry.kind.length > 0)
        result ~= "\t" ~ kindToString(entry.kind);
    if (entry.scopeName.length > 0)
        result ~= " [" ~ entry.scopeName ~ "]";
    return result;
}

string kindToString(string kind)
{
    switch (kind)
    {
    case "f":
        return "function";
    case "c":
        return "class";
    case "s":
        return "struct";
    case "g":
        return "enum";
    case "i":
        return "interface";
    case "v":
        return "variable";
    case "e":
        return "enum_member";
    case "m":
        return "member";
    case "p":
        return "property";
    default:
        return kind;
    }
}