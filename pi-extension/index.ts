// factorio: Pi as a co-player. Talks to the pi-companion mod over RCON and bridges the in-game chat.
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { Type } from "@earendil-works/pi-ai";
import { defineTool, type ExtensionAPI, type ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Rcon } from "./rcon.ts";
import { readRconConfig } from "./config.ts";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const POLL_MS = 2000;
const MAX_RESULT_CHARS = 30000;

interface InboxMessage {
	seq: number;
	tick: number;
	player?: string;
	text: string;
}

export default function (pi: ExtensionAPI) {
	let rcon: Rcon | undefined;
	let pollTimer: NodeJS.Timeout | undefined;
	let bridgeOn = process.env.FACTORIO_PI_BRIDGE !== "off";
	let polling = false;
	let lastError: string | undefined;

	let target = "nicht konfiguriert";
	function client(): Rcon {
		if (!rcon) {
			const config = readRconConfig(path.join(REPO_ROOT, "server", ".env"));
			target = `${config.host.includes(":") ? `[${config.host}]` : config.host}:${config.port}`;
			rcon = new Rcon(config);
		}
		return rcon;
	}

	/** Call an op of the pi-companion mod; returns its `data` or throws its error. */
	async function call(op: string, args: Record<string, unknown> = {}): Promise<unknown> {
		const raw = await client().command(`/pi ${JSON.stringify({ ...args, op })}`);
		let parsed: { ok: boolean; data?: unknown; error?: string };
		try {
			parsed = JSON.parse(raw);
		} catch {
			throw new Error(`Unexpected reply from Factorio: ${raw.slice(0, 500)}`);
		}
		if (!parsed.ok) throw new Error(parsed.error ?? "unknown error");
		return parsed.data;
	}

	function setStatus(ctx: ExtensionContext, text: string | undefined) {
		if (ctx.hasUI) ctx.ui.setStatus("factorio", text);
	}

	async function poll(ctx: ExtensionContext) {
		if (polling || !bridgeOn) return;
		polling = true;
		try {
			const data = (await call("inbox")) as { messages?: InboxMessage[] | Record<string, never> };
			const messages = Array.isArray(data.messages) ? data.messages : [];
			if (lastError) {
				lastError = undefined;
			}
			setStatus(ctx, `Factorio: verbunden (${target})`);
			if (messages.length === 0) return;
			const lines = messages.map((m) => `${m.player ?? "?"}: ${m.text}`).join("\n");
			pi.sendMessage(
				{
					customType: "factorio-chat",
					content:
						`[Factorio-Chat] Nachricht(en) an dich aus dem laufenden Spiel:\n${lines}\n\n` +
						"Antworte den Spielern im Spiel mit factorio_say (kurz, Chat-tauglich). " +
						"Nutze bei Bedarf factorio_call, um den Spielzustand zu prüfen.",
					display: true,
					details: { messages },
				},
				{ triggerTurn: true, deliverAs: ctx.isIdle() ? undefined : "followUp" },
			);
			await call("ack", { upto: messages[messages.length - 1].seq, notify: true });
		} catch (err) {
			const msg = (err as Error).message;
			if (msg !== lastError) {
				lastError = msg;
				setStatus(ctx, `Factorio: getrennt (${target})`);
			}
			rcon?.close();
			rcon = undefined;
		} finally {
			polling = false;
		}
	}

	function startPolling(ctx: ExtensionContext) {
		stopPolling();
		pollTimer = setInterval(() => void poll(ctx), POLL_MS);
		void poll(ctx);
	}

	function stopPolling() {
		if (pollTimer) clearInterval(pollTimer);
		pollTimer = undefined;
	}

	pi.on("session_start", async (_event, ctx) => {
		if (bridgeOn) startPolling(ctx);
	});

	pi.on("session_shutdown", async () => {
		stopPolling();
		rcon?.close();
		rcon = undefined;
	});

	pi.registerTool(
		defineTool({
			name: "factorio_call",
			label: "Factorio",
			description:
				"Call an op of the pi-companion mod on the running Factorio server (via RCON) and return its JSON result. " +
				"Ops: ping, summary (tick, players, surfaces, research, mods), inbox (unacknowledged @pi chat messages), " +
				"rails {surface?, limit?} (rail network: problems incl. DEADLOCK cycles, lines/schedules, stations, trains with waits_for), " +
				"map {x,y,r | x1,y1,x2,y2, scale?, surface?} (ASCII map of rails, signals, stops, trains), " +
				"entities {x1,y1,x2,y2, type?|name?, limit?} (entities in an area: name, x, y, direction, state). " +
				"blockcheck {x1?,y1?,x2?,y2?, train_length?, limit?, detail?} (signal blocks where a waiting train blocks foreign traffic; fits = tiles until conflict block, grouped by junction). " +
				"Shared to-do list (players see it in the GUI and via /todo): todos {all?}, todo_add {text, assignee?}, " +
				"todo_update {id, done?, text?, assignee? ('' clears)}, todo_remove {id}, todo_clear_done. Every change is announced in chat. " +
				"Use factorio_say for chat output.",
			parameters: Type.Object({
				op: Type.String({ description: "Mod op name, e.g. 'summary'" }),
				args: Type.Optional(Type.Record(Type.String(), Type.Unknown(), { description: "Op arguments" })),
			}),
			async execute(_id, params) {
				const data = await call(params.op, (params.args ?? {}) as Record<string, unknown>);
				let text = JSON.stringify(data);
				if (text.length > MAX_RESULT_CHARS) {
					text = `${text.slice(0, MAX_RESULT_CHARS)}\n…[truncated, ${text.length} chars total; narrow the query]`;
				}
				return { content: [{ type: "text", text }], details: undefined };
			},
		}),
	);

	pi.registerTool(
		defineTool({
			name: "factorio_say",
			label: "Factorio chat",
			description:
				"Write a chat message in the running Factorio game as [Pi]. Keep it short; plain text, Factorio rich text tags allowed.",
			parameters: Type.Object({ text: Type.String({ description: "Message text" }) }),
			async execute(_id, params) {
				await call("say", { text: params.text });
				return { content: [{ type: "text", text: "sent" }], details: undefined };
			},
		}),
	);

	pi.registerCommand("factorio", {
		description: "Factorio-Chatbrücke: /factorio on | off | status",
		getArgumentCompletions: (prefix) =>
			["on", "off", "status"].filter((s) => s.startsWith(prefix)).map((s) => ({ value: s, label: s })),
		handler: async (args, ctx) => {
			const arg = args.trim() || "status";
			if (arg === "on") {
				bridgeOn = true;
				startPolling(ctx);
				ctx.ui.notify("Factorio-Chatbrücke an", "info");
			} else if (arg === "off") {
				bridgeOn = false;
				stopPolling();
				setStatus(ctx, "Factorio: aus");
				ctx.ui.notify("Factorio-Chatbrücke aus", "info");
			} else {
				try {
					const s = (await call("summary")) as { tick: number; players: unknown };
					const players = Array.isArray(s.players) ? s.players.length : 0;
					ctx.ui.notify(`Factorio verbunden (${target}), Tick ${s.tick}, ${players} Spieler, Brücke ${bridgeOn ? "an" : "aus"}`, "info");
				} catch (err) {
					ctx.ui.notify(`Factorio nicht erreichbar (${target}): ${(err as Error).message}`, "warning");
				}
			}
		},
	});
}
