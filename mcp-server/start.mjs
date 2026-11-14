// Entry point for MCP clients. Plain JavaScript so that it runs on any Node version and can
// explain what to do if Node is too old (Claude Desktop shows stderr in its MCP log).
const [major, minor] = process.versions.node.split(".").map(Number);
if (major < 22 || (major === 22 && minor < 18)) {
	process.stderr.write(
		`[factorio-mcp] Node.js ${process.versions.node} is too old; Node.js 22.18 or newer is required.\n` +
			"Windows: run  winget install OpenJS.NodeJS.LTS  in a terminal (or download the LTS installer from https://nodejs.org),\n" +
			"then restart Claude Desktop completely (also quit it in the system tray).\n",
	);
	process.exit(1);
}
process.removeAllListeners("warning"); // keep the type-stripping notice out of the log
await import("./server.ts");
