module utils.process;

import std.process : execute, pipeProcess, Redirect, wait, Pid;
import std.stdio : File;
import std.array : appender;
import std.string : strip;

struct ProcessResult
{
    int status;
    string output;
    string stderrOutput;
}

ProcessResult executeCommand(string[] command)
{
    auto result = execute(command);
    return ProcessResult(result.status, result.output.strip(), "");
}

ProcessResult executeCommandWithInput(string[] command, string input)
{
    auto pipes = pipeProcess(command, Redirect.stdin | Redirect.stdout | Redirect.stderr);

    pipes.stdin.writeln(input);
    pipes.stdin.flush();
    pipes.stdin.close();

    auto stdoutApp = appender!string;
    foreach (line; pipes.stdout.byLine)
    {
        stdoutApp ~= line ~ "\n";
    }

    auto stderrApp = appender!string;
    foreach (line; pipes.stderr.byLine)
    {
        stderrApp ~= line ~ "\n";
    }

    int status = wait(pipes.pid);

    return ProcessResult(status, stdoutApp.data.strip(), stderrApp.data.strip());
}