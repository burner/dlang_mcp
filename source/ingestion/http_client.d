module ingestion.http_client;

import std.net.curl;
import std.stdio;
import std.datetime;
import std.exception;
import std.conv;
import core.thread;

class HTTPClient
{
    private Duration rateLimitDelay;
    private int maxRetries;
    private SysTime lastRequestTime;

    this(Duration rateLimitDelay = dur!"msecs"(100), int maxRetries = 3)
    {
        this.rateLimitDelay = rateLimitDelay;
        this.maxRetries = maxRetries;
        this.lastRequestTime = Clock.currTime() - rateLimitDelay;
    }

    string get(string url)
    {
        auto now = Clock.currTime();
        auto elapsed = now - lastRequestTime;
        if (elapsed < rateLimitDelay)
        {
            auto sleepTime = rateLimitDelay - elapsed;
            Thread.sleep(sleepTime);
        }

        int attempt = 0;
        Exception lastException;

        while (attempt < maxRetries)
        {
            try
            {
                auto content = std.net.curl.get(url);
                lastRequestTime = Clock.currTime();
                return cast(string)content;
            }
            catch (Exception e)
            {
                lastException = e;
                attempt++;

                if (attempt < maxRetries)
                {
                    stderr.writefln("Request failed (attempt %d/%d): %s",
                                   attempt, maxRetries, e.msg);
                    Thread.sleep(dur!"seconds"(attempt));
                }
            }
        }

        throw new Exception("HTTP GET failed after " ~ text(maxRetries) ~
                          " attempts: " ~ lastException.msg);
    }

    void download(string url, string outputPath)
    {
        int attempt = 0;
        Exception lastException;

        while (attempt < maxRetries)
        {
            try
            {
                std.net.curl.download(url, outputPath);
                return;
            }
            catch (Exception e)
            {
                lastException = e;
                attempt++;

                if (attempt < maxRetries)
                {
                    stderr.writefln("Download failed (attempt %d/%d): %s",
                                   attempt, maxRetries, e.msg);
                    Thread.sleep(dur!"seconds"(attempt));
                }
            }
        }

        throw new Exception("Download failed after " ~ text(maxRetries) ~
                          " attempts: " ~ lastException.msg);
    }
}