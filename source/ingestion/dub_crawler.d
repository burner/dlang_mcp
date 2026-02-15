module ingestion.dub_crawler;

import ingestion.http_client;
import models;
import std.json;
import std.stdio;
import std.file;
import std.path;
import std.process;
import std.string;
import std.algorithm;
import std.array;
import std.zip;
import std.exception;

class DubCrawler
{
    private string cacheDir;
    private HTTPClient http;
    private const string API_BASE = "https://code.dlang.org/api";

    this(string cacheDir = "./data/cache")
    {
        this.cacheDir = cacheDir;
        this.http = new HTTPClient();

        mkdirRecurse(cacheDir);
        mkdirRecurse(buildPath(cacheDir, "metadata"));
        mkdirRecurse(buildPath(cacheDir, "sources"));
    }

    string[] fetchAllPackages()
    {
        writeln("Fetching package list from code.dlang.org...");

        try
        {
            auto response = http.get(API_BASE ~ "/packages/dump");
            auto json = parseJSON(response);

            string[] packages;
            foreach (pkg; json.array)
            {
                if (pkg.type == JSONType.string)
                    packages ~= pkg.str;
                else if ("name" in pkg.object)
                    packages ~= pkg["name"].str;
            }

            writefln("Found %d packages", packages.length);
            return packages;
        }
        catch (Exception e)
        {
            stderr.writeln("Error fetching package list: ", e.msg);
            throw e;
        }
    }

    PackageMetadata fetchPackageInfo(string packageName)
    {
        auto cacheFile = buildPath(cacheDir, "metadata", packageName ~ ".json");

        if (exists(cacheFile))
        {
            try
            {
                auto cached = readText(cacheFile);
                return PackageMetadata.fromJSON(parseJSON(cached));
            }
            catch (Exception e)
            {
                stderr.writeln("Cache read failed, fetching fresh: ", e.msg);
            }
        }

        try
        {
            auto url = format("%s/packages/%s/latest/info", API_BASE, packageName);
            auto response = http.get(url);
            auto json = parseJSON(response);

            std.file.write(cacheFile, response);

            return PackageMetadata.fromJSON(json);
        }
        catch (Exception e)
        {
            stderr.writefln("Error fetching metadata for %s: %s", packageName, e.msg);
            throw e;
        }
    }

    string downloadPackageSource(string packageName, string version_)
    {
        auto extractDir = buildPath(cacheDir, "sources", packageName ~ "-" ~ version_);

        if (exists(extractDir) && isDir(extractDir))
        {
            writeln("  Using cached source: ", extractDir);
            return extractDir;
        }

        writeln("  Downloading source...");

        try
        {
            auto zipUrl = format("https://code.dlang.org/packages/%s/%s.zip",
                                packageName, version_);
            auto zipPath = buildPath(cacheDir, "sources",
                                    packageName ~ "-" ~ version_ ~ ".zip");

            http.download(zipUrl, zipPath);

            extractZip(zipPath, extractDir);

            writeln("  Extracted to: ", extractDir);
            return extractDir;

        }
        catch (Exception e)
        {
            stderr.writefln("Error downloading source for %s: %s",
                          packageName, e.msg);
            throw e;
        }
    }

    private void extractZip(string zipPath, string extractTo)
    {
        mkdirRecurse(extractTo);

        try
        {
            auto zipFile = new ZipArchive(read(zipPath));

            foreach (name, member; zipFile.directory)
            {
                auto targetPath = buildPath(extractTo, name);

                if (name.endsWith("/"))
                {
                    mkdirRecurse(targetPath);
                }
                else
                {
                    mkdirRecurse(dirName(targetPath));
                    std.file.write(targetPath, zipFile.expand(member));
                }
            }
        }
        catch (Exception e)
        {
            throw new Exception("Failed to extract ZIP: " ~ e.msg);
        }
    }

    string findSourceDirectory(string packageRoot)
    {
        string[] candidates = [
            buildPath(packageRoot, "source"),
            buildPath(packageRoot, "src"),
        ];

        try
        {
            foreach (entry; dirEntries(packageRoot, SpanMode.shallow))
            {
                if (entry.isDir)
                {
                    candidates ~= buildPath(entry.name, "source");
                    candidates ~= buildPath(entry.name, "src");
                }
            }
        }
        catch (Exception)
        {
        }

        foreach (candidate; candidates)
        {
            if (exists(candidate) && isDir(candidate))
            {
                return candidate;
            }
        }

        return packageRoot;
    }

    string[] findDFiles(string dir)
    {
        string[] files;

        try
        {
            foreach (entry; dirEntries(dir, "*.d", SpanMode.depth))
            {
                if (entry.isFile)
                {
                    files ~= entry.name;
                }
            }
        }
        catch (Exception e)
        {
            stderr.writeln("Error scanning directory: ", e.msg);
        }

        return files;
    }

    struct CacheStats
    {
        ulong metadataCount;
        ulong sourceCount;
        ulong totalSize;
    }

    CacheStats getCacheStats()
    {
        CacheStats stats;

        auto metadataDir = buildPath(cacheDir, "metadata");
        auto sourcesDir = buildPath(cacheDir, "sources");

        if (exists(metadataDir))
        {
            foreach (entry; dirEntries(metadataDir, SpanMode.shallow))
            {
                if (entry.isFile)
                {
                    stats.metadataCount++;
                    stats.totalSize += getSize(entry.name);
                }
            }
        }

        if (exists(sourcesDir))
        {
            foreach (entry; dirEntries(sourcesDir, SpanMode.shallow))
            {
                if (entry.isDir)
                {
                    stats.sourceCount++;
                }
            }
        }

        return stats;
    }

    void clearCache()
    {
        if (exists(cacheDir))
        {
            rmdirRecurse(cacheDir);
            mkdirRecurse(cacheDir);
            mkdirRecurse(buildPath(cacheDir, "metadata"));
            mkdirRecurse(buildPath(cacheDir, "sources"));
        }
    }
}