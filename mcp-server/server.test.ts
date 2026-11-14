import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { Companion } from "./companion.ts";
import { TOOLS } from "./tools.ts";

test("companion sends /pi json and unwraps data", async () => {
	const sent: string[] = [];
	const c = new Companion(
		() => ({ host: "h", port: 1, password: "p" }),
		() => ({ command: async (cmd) => (sent.push(cmd), '{"ok":true,"data":{"x":1}}'), close() {} }),
	);
	assert.deepEqual(await c.call("rails", { limit: 3 }), { x: 1 });
	assert.equal(sent[0], '/pi {"limit":3,"op":"rails"}');
});

test("companion surfaces mod errors", async () => {
	const c = new Companion(
		() => ({ host: "h", port: 1, password: "p" }),
		() => ({ command: async () => '{"ok":false,"error":"bad op"}', close() {} }),
	);
	await assert.rejects(c.call("nope"), /bad op/);
});

test("tool names are unique and schemas are objects", () => {
	const names = TOOLS.map((t) => t.name);
	assert.equal(new Set(names).size, names.length);
	for (const t of TOOLS) assert.equal(t.inputSchema.type, "object");
});

test("stdio handshake and tools/list", async () => {
	const child = spawn(process.execPath, ["start.mjs"], {
		cwd: import.meta.dirname,
		env: { ...process.env, FACTORIO_POLL_MS: "0", FACTORIO_RCON_PASSWORD: "x", FACTORIO_RCON_PORT: "1" },
	});
	const replies: any[] = [];
	let buf = "";
	child.stdout.on("data", (d) => {
		buf += d;
		let i;
		while ((i = buf.indexOf("\n")) >= 0) {
			replies.push(JSON.parse(buf.slice(0, i)));
			buf = buf.slice(i + 1);
		}
	});
	const w = (m: unknown) => child.stdin.write(`${JSON.stringify(m)}\n`);
	w({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "0" } } });
	w({ jsonrpc: "2.0", method: "notifications/initialized" });
	w({ jsonrpc: "2.0", id: 2, method: "tools/list" });
	w({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "factorio_summary", arguments: {} } });
	while (replies.length < 3) await new Promise((r) => setTimeout(r, 50));
	child.stdin.end();
	assert.equal(replies[0].result.protocolVersion, "2025-06-18");
	assert.ok(replies[1].result.tools.some((t: any) => t.name === "factorio_rails"));
	assert.equal(replies[2].result.isError, true); // no game on port 1
});
