// MCP server (stdio, no dependencies) for Claude Desktop, Claude Code and other MCP clients.
// Talks to the pi-companion mod over RCON. stdout carries only JSON-RPC; logs go to stderr.
import * as path from "node:path";
import * as readline from "node:readline";
import { fileURLToPath } from "node:url";
import { readRconConfig } from "../pi-extension/config.ts";
import { Companion } from "./companion.ts";
import { TOOLS } from "./tools.ts";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const ENV_FILE = process.env.FACTORIO_ENV_FILE || path.join(REPO_ROOT, "server", ".env");
const POLL_MS = Number(process.env.FACTORIO_POLL_MS || 3000);
const NOTIFY_IN_GAME = process.env.FACTORIO_NOTIFY_IN_GAME !== "off";
const MAX_RESULT_CHARS = 30000;
const INBOX_URI = "factorio://inbox";
const SUPPORTED = ["2025-06-18", "2025-03-26", "2024-11-05"];

const INSTRUCTIONS =
	"You are a co-player in a running Factorio game (planner and advisor, focus rail networks). " +
	"At the start of each conversation call factorio_inbox to see open @pi chat messages and answer them in game with factorio_say. " +
	"Note: this client cannot be woken up by the game; players' messages wait until the user talks to you. " +
	"Never change the world without confirmation in game chat; suggest ghosts or blueprints instead.";

interface InboxMessage {
	seq: number;
	tick: number;
	player?: string;
	text: string;
}

const companion = new Companion(() => readRconConfig(ENV_FILE));
const log = (msg: string) => process.stderr.write(`[factorio-mcp] ${msg}\n`);

function send(msg: unknown) {
	process.stdout.write(`${JSON.stringify(msg)}\n`);
}
const notify = (method: string, params: unknown) => send({ jsonrpc: "2.0", method, params });

function text(value: unknown): string {
	let t = typeof value === "string" ? value : JSON.stringify(value);
	if (t.length > MAX_RESULT_CHARS) t = `${t.slice(0, MAX_RESULT_CHARS)}\n…[truncated, ${t.length} chars total; narrow the query]`;
	return t;
}

async function readInbox(): Promise<InboxMessage[]> {
	const data = (await companion.call("inbox")) as { messages?: InboxMessage[] | Record<string, never> };
	return Array.isArray(data.messages) ? data.messages : [];
}

async function callTool(name: string, args: Record<string, unknown>): Promise<string> {
	if (name === "factorio_inbox") {
		const messages = await readInbox();
		if (messages.length === 0) return "No open chat messages.";
		if (!args.peek) await companion.call("ack", { upto: messages[messages.length - 1].seq, notify: false });
		return text(messages.map((m) => ({ player: m.player ?? "?", text: m.text, tick: m.tick })));
	}
	if (name === "factorio_call") {
		return text(await companion.call(String(args.op), (args.args ?? {}) as Record<string, unknown>));
	}
	const tool = TOOLS.find((t) => t.name === name);
	if (!tool?.op) throw new Error(`Unknown tool: ${name}`);
	const data = await companion.call(tool.op, args);
	return name === "factorio_say" ? "sent" : text(data);
}

// --- Inbox watcher (variant B: resource update notifications; variant A: in-game hint) ---
let lastSeenSeq = 0;
let subscribed = false;
let pollTimer: NodeJS.Timeout | undefined;
let polling = false;
let lastError = "";

async function poll() {
	if (polling) return;
	polling = true;
	try {
		const messages = await readInbox();
		lastError = "";
		const fresh = messages.filter((m) => m.seq > lastSeenSeq);
		if (fresh.length === 0) return;
		lastSeenSeq = fresh[fresh.length - 1].seq;
		const lines = fresh.map((m) => `${m.player ?? "?"}: ${m.text}`).join("\n");
		if (subscribed) notify("notifications/resources/updated", { uri: INBOX_URI });
		notify("notifications/message", { level: "notice", logger: "factorio", data: `New @pi chat message(s):\n${lines}` });
		if (NOTIFY_IN_GAME) {
			await companion.call("say", {
				text: "Nachricht gesehen. Ich antworte, sobald jemand in Claude Desktop mit mir spricht.",
			});
		}
	} catch (err) {
		const msg = (err as Error).message;
		if (msg !== lastError) log(`inbox poll failed: ${msg}`);
		lastError = msg;
	} finally {
		polling = false;
	}
}

function startPolling() {
	if (pollTimer || POLL_MS <= 0) return;
	// Messages already waiting at start-up count as seen: factorio_inbox picks them up.
	readInbox()
		.then((m) => {
			lastSeenSeq = m.length ? m[m.length - 1].seq : 0;
		})
		.catch((err) => log(`initial inbox read failed: ${(err as Error).message}`));
	pollTimer = setInterval(() => void poll(), POLL_MS);
	pollTimer.unref();
}

// --- JSON-RPC dispatch ---
async function handle(method: string, params: Record<string, any>): Promise<unknown> {
	switch (method) {
		case "initialize":
			return {
				protocolVersion: SUPPORTED.includes(params.protocolVersion) ? params.protocolVersion : SUPPORTED[0],
				capabilities: { tools: {}, resources: { subscribe: true }, logging: {} },
				serverInfo: { name: "factorio-pi", version: "0.1.0" },
				instructions: INSTRUCTIONS,
			};
		case "ping":
			return {};
		case "tools/list":
			return { tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })) };
		case "tools/call":
			try {
				return { content: [{ type: "text", text: await callTool(params.name, params.arguments ?? {}) }] };
			} catch (err) {
				return { content: [{ type: "text", text: `Error: ${(err as Error).message}` }], isError: true };
			}
		case "resources/list":
			return {
				resources: [
					{ uri: INBOX_URI, name: "Factorio chat inbox", description: "Unanswered @pi messages", mimeType: "application/json" },
				],
			};
		case "resources/read":
			if (params.uri !== INBOX_URI) throw Object.assign(new Error("Unknown resource"), { code: -32002 });
			return { contents: [{ uri: INBOX_URI, mimeType: "application/json", text: JSON.stringify(await readInbox()) }] };
		case "resources/subscribe":
			subscribed = params.uri === INBOX_URI || subscribed;
			return {};
		case "resources/unsubscribe":
			if (params.uri === INBOX_URI) subscribed = false;
			return {};
		case "logging/setLevel":
			return {};
		default:
			throw Object.assign(new Error(`Method not found: ${method}`), { code: -32601 });
	}
}

const rl = readline.createInterface({ input: process.stdin });
rl.on("line", async (line) => {
	if (!line.trim()) return;
	let msg: { id?: number | string; method?: string; params?: Record<string, unknown> };
	try {
		msg = JSON.parse(line);
	} catch {
		send({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } });
		return;
	}
	if (!msg.method) return; // responses to our (non-existent) requests
	if (msg.id === undefined) {
		if (msg.method === "notifications/initialized") startPolling();
		return;
	}
	try {
		send({ jsonrpc: "2.0", id: msg.id, result: await handle(msg.method, msg.params ?? {}) });
	} catch (err) {
		const e = err as Error & { code?: number };
		send({ jsonrpc: "2.0", id: msg.id, error: { code: e.code ?? -32603, message: e.message } });
	}
});
rl.on("close", () => {
	companion.close();
	process.exit(0);
});
log(`started, config ${process.env.FACTORIO_RCON_PASSWORD ? "from environment" : ENV_FILE}`);
