import std.stdio;
import mcp.server : MCPServer;
import mcp.transport : StdioTransport;
import tools.dscanner : DscannerTool;
import tools.dfmt : DfmtTool;
import tools.ctags : CtagsSearchTool;
import tools.base : Tool;

void main()
{
    auto server = new MCPServer();

    server.registerTool(new DscannerTool());
    server.registerTool(new DfmtTool());
    server.registerTool(new CtagsSearchTool());

    auto transport = new StdioTransport();

    server.start(transport);
}