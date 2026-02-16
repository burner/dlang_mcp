/** DUB registry crawler for fetching and caching D package metadata and source archives. */
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

/**
 * Fetches package metadata and source code from the DUB registry API.
 *
 * Maintains a local filesystem cache of downloaded metadata and source archives
 * to avoid redundant network requests across ingestion runs.
 */
class DubCrawler {
	private string cacheDir;
	private HTTPClient http;
	private const string API_BASE = "https://code.dlang.org/api";

	/**
	 * Constructs a new DUB crawler with the specified cache directory.
	 *
	 * Creates the cache directory structure if it does not already exist.
	 *
	 * Params:
	 *     cacheDir = Local directory path for storing cached metadata and sources.
	 */
	this(string cacheDir = "./data/cache")
	{
		this.cacheDir = cacheDir;
		this.http = new HTTPClient();

		mkdirRecurse(cacheDir);
		mkdirRecurse(buildPath(cacheDir, "metadata"));
		mkdirRecurse(buildPath(cacheDir, "sources"));
	}

	/**
	 * Fetches the complete list of package names from the DUB registry.
	 *
	 * Returns:
	 *     An array of package name strings.
	 */
	string[] fetchAllPackages()
	{
		writeln("Fetching package list from code.dlang.org...");

		try {
			auto response = http.get(API_BASE ~ "/packages/dump");
			auto json = parseJSON(response);

			string[] packages;
			foreach(pkg; json.array) {
				if(pkg.type == JSONType.string)
					packages ~= pkg.str;
				else if("name" in pkg.object)
					packages ~= pkg["name"].str;
			}

			writefln("Found %d packages", packages.length);
			return packages;
		} catch(Exception e) {
			stderr.writeln("Error fetching package list: ", e.msg);
			throw e;
		}
	}

	/**
	 * Fetches metadata for a specific package, using the cache when available.
	 *
	 * Params:
	 *     packageName = Name of the DUB package to look up.
	 *
	 * Returns:
	 *     A `PackageMetadata` record containing version, description, and other info.
	 */
	PackageMetadata fetchPackageInfo(string packageName)
	{
		auto cacheFile = buildPath(cacheDir, "metadata", packageName ~ ".json");

		if(exists(cacheFile)) {
			try {
				auto cached = readText(cacheFile);
				return PackageMetadata.fromJSON(parseJSON(cached));
			} catch(Exception e) {
				stderr.writeln("Cache read failed, fetching fresh: ", e.msg);
			}
		}

		try {
			auto url = format("%s/packages/%s/latest/info", API_BASE, packageName);
			auto response = http.get(url);
			auto json = parseJSON(response);

			std.file.write(cacheFile, response);

			return PackageMetadata.fromJSON(json);
		} catch(Exception e) {
			stderr.writefln("Error fetching metadata for %s: %s", packageName, e.msg);
			throw e;
		}
	}

	/**
	 * Downloads and extracts the source archive for a package version.
	 *
	 * Returns the cached extraction directory if the source has already been
	 * downloaded; otherwise downloads and extracts the ZIP archive.
	 *
	 * Params:
	 *     packageName = Name of the DUB package.
	 *     version_ = Version string of the package to download.
	 *
	 * Returns:
	 *     Path to the directory containing the extracted source files.
	 */
	string downloadPackageSource(string packageName, string version_)
	{
		auto extractDir = buildPath(cacheDir, "sources", packageName ~ "-" ~ version_);

		if(exists(extractDir) && isDir(extractDir)) {
			writeln("  Using cached source: ", extractDir);
			return extractDir;
		}

		writeln("  Downloading source...");

		try {
			auto zipUrl = format("https://code.dlang.org/packages/%s/%s.zip", packageName, version_);
			auto zipPath = buildPath(cacheDir, "sources", packageName ~ "-" ~ version_ ~ ".zip");

			http.download(zipUrl, zipPath);

			extractZip(zipPath, extractDir);

			writeln("  Extracted to: ", extractDir);
			return extractDir;

		} catch(Exception e) {
			stderr.writefln("Error downloading source for %s: %s", packageName, e.msg);
			throw e;
		}
	}

	private void extractZip(string zipPath, string extractTo)
	{
		mkdirRecurse(extractTo);

		try {
			auto zipFile = new ZipArchive(read(zipPath));

			foreach(name, member; zipFile.directory) {
				auto targetPath = buildPath(extractTo, name);

				if(name.endsWith("/")) {
					mkdirRecurse(targetPath);
				} else {
					mkdirRecurse(dirName(targetPath));
					std.file.write(targetPath, zipFile.expand(member));
				}
			}
		} catch(Exception e) {
			throw new Exception("Failed to extract ZIP: " ~ e.msg);
		}
	}

	/**
	 * Locates the D source directory within an extracted package root.
	 *
	 * Checks for conventional `source/` and `src/` directories, including
	 * those nested one level deep. Falls back to the package root itself.
	 *
	 * Params:
	 *     packageRoot = Root directory of the extracted package.
	 *
	 * Returns:
	 *     Path to the directory most likely containing D source files.
	 */
	string findSourceDirectory(string packageRoot)
	{
		string[] candidates = [
			buildPath(packageRoot, "source"), buildPath(packageRoot, "src"),
		];

		try {
			foreach(entry; dirEntries(packageRoot, SpanMode.shallow)) {
				if(entry.isDir) {
					candidates ~= buildPath(entry.name, "source");
					candidates ~= buildPath(entry.name, "src");
				}
			}
		} catch(Exception e) {
			stderr.writeln("Warning: Failed to scan directory entries in ", packageRoot, ": ", e.msg);
		}

		foreach(candidate; candidates) {
			if(exists(candidate) && isDir(candidate)) {
				return candidate;
			}
		}

		return packageRoot;
	}

	/**
	 * Recursively finds all `.d` source files in a directory.
	 *
	 * Params:
	 *     dir = Directory to search recursively.
	 *
	 * Returns:
	 *     An array of absolute file paths to `.d` files.
	 */
	string[] findDFiles(string dir)
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

	/** Summary statistics about the local package cache. */
	struct CacheStats {
		/** Number of cached package metadata JSON files. */
		ulong metadataCount;
		/** Number of cached extracted source directories. */
		ulong sourceCount;
		/** Total size in bytes of all cached metadata files. */
		ulong totalSize;
	}

	/**
	 * Computes summary statistics for the local cache.
	 *
	 * Returns:
	 *     A `CacheStats` struct with counts and total size.
	 */
	CacheStats getCacheStats()
	{
		CacheStats stats;

		auto metadataDir = buildPath(cacheDir, "metadata");
		auto sourcesDir = buildPath(cacheDir, "sources");

		if(exists(metadataDir)) {
			foreach(entry; dirEntries(metadataDir, SpanMode.shallow)) {
				if(entry.isFile) {
					stats.metadataCount++;
					stats.totalSize += getSize(entry.name);
				}
			}
		}

		if(exists(sourcesDir)) {
			foreach(entry; dirEntries(sourcesDir, SpanMode.shallow)) {
				if(entry.isDir) {
					stats.sourceCount++;
				}
			}
		}

		return stats;
	}

	/**
	 * Removes all cached metadata and source files, then recreates
	 * the empty cache directory structure.
	 */
	void clearCache()
	{
		if(exists(cacheDir)) {
			rmdirRecurse(cacheDir);
			mkdirRecurse(cacheDir);
			mkdirRecurse(buildPath(cacheDir, "metadata"));
			mkdirRecurse(buildPath(cacheDir, "sources"));
		}
	}
}
