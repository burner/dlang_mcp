/** Rate-limited HTTP client with retry logic for DUB registry API access. */
module ingestion.http_client;

import std.net.curl;
import std.stdio;
import std.datetime;
import std.exception;
import std.conv;
import core.thread;

/**
 * HTTP client with configurable rate limiting and automatic retry on failure.
 *
 * Ensures polite crawling of remote APIs by enforcing a minimum delay between
 * consecutive requests and retrying transient failures with exponential backoff.
 */
class HTTPClient {
	private Duration rateLimitDelay;
	private int maxRetries;
	private SysTime lastRequestTime;

	/**
	 * Constructs a new HTTP client.
	 *
	 * Params:
	 *     rateLimitDelay = Minimum delay between consecutive HTTP requests.
	 *     maxRetries = Maximum number of retry attempts for a failed request.
	 */
	this(Duration rateLimitDelay = dur!"msecs"(100), int maxRetries = 3)
	{
		this.rateLimitDelay = rateLimitDelay;
		this.maxRetries = maxRetries;
		this.lastRequestTime = Clock.currTime() - rateLimitDelay;
	}

	/**
	 * Performs an HTTP GET request and returns the response body as a string.
	 *
	 * Respects the configured rate limit and retries on transient failures.
	 *
	 * Params:
	 *     url = The URL to fetch.
	 *
	 * Returns:
	 *     The response body as a string.
	 *
	 * Throws:
	 *     Exception if all retry attempts are exhausted.
	 */
	string get(string url)
	{
		auto now = Clock.currTime();
		auto elapsed = now - lastRequestTime;
		if(elapsed < rateLimitDelay) {
			auto sleepTime = rateLimitDelay - elapsed;
			Thread.sleep(sleepTime);
		}

		int attempt = 0;
		Exception lastException;

		while(attempt < maxRetries) {
			try {
				auto content = std.net.curl.get(url);
				lastRequestTime = Clock.currTime();
				return cast(string)content;
			} catch(Exception e) {
				lastException = e;
				attempt++;

				if(attempt < maxRetries) {
					stderr.writefln("Request failed (attempt %d/%d): %s",
							attempt, maxRetries, e.msg);
					Thread.sleep(dur!"seconds"(attempt));
				}
			}
		}

		throw new Exception("HTTP GET failed after " ~ text(
				maxRetries) ~ " attempts: " ~ lastException.msg);
	}

	/**
	 * Downloads a file from a URL and saves it to the specified path.
	 *
	 * Retries on transient failures up to the configured maximum retry count.
	 *
	 * Params:
	 *     url = The URL of the file to download.
	 *     outputPath = The local filesystem path to write the downloaded file to.
	 *
	 * Throws:
	 *     Exception if all retry attempts are exhausted.
	 */
	void download(string url, string outputPath)
	{
		int attempt = 0;
		Exception lastException;

		while(attempt < maxRetries) {
			try {
				std.net.curl.download(url, outputPath);
				return;
			} catch(Exception e) {
				lastException = e;
				attempt++;

				if(attempt < maxRetries) {
					stderr.writefln("Download failed (attempt %d/%d): %s",
							attempt, maxRetries, e.msg);
					Thread.sleep(dur!"seconds"(attempt));
				}
			}
		}

		throw new Exception("Download failed after " ~ text(
				maxRetries) ~ " attempts: " ~ lastException.msg);
	}
}
