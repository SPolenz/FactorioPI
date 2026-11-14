// Tool catalogue for the MCP server: typed tools for the known ops, plus a generic fallback.

type Schema = Record<string, unknown>;

export interface ToolDef {
	name: string;
	description: string;
	inputSchema: Schema;
	/** Mod op to call; undefined for tools handled specially by the server. */
	op?: string;
}

const num = (description: string): Schema => ({ type: "number", description });
const str = (description: string): Schema => ({ type: "string", description });
const obj = (properties: Record<string, Schema>, required: string[] = []): Schema => ({
	type: "object",
	properties,
	required,
	additionalProperties: false,
});

const area = {
	x1: num("Left tile x"),
	y1: num("Top tile y"),
	x2: num("Right tile x"),
	y2: num("Bottom tile y"),
};

export const TOOLS: ToolDef[] = [
	{
		name: "factorio_summary",
		op: "summary",
		description: "Overview of the running game: tick, play time, players with positions, surfaces, current research, active mods. Good first call.",
		inputSchema: obj({}),
	},
	{
		name: "factorio_rails",
		op: "rails",
		description:
			"Rail network analysis: problems incl. DEADLOCK cycles, lines/schedules, stations, trains with waits_for. Start here for any train question.",
		inputSchema: obj({ surface: str("Surface name, default nauvis"), limit: num("Max items per list") }),
	},
	{
		name: "factorio_map",
		op: "map",
		description:
			"ASCII map of rails, signals, stops and trains. Either a centre with radius (x, y, r) or a rectangle (x1, y1, x2, y2).",
		inputSchema: obj({
			x: num("Centre tile x"),
			y: num("Centre tile y"),
			r: num("Radius in tiles"),
			...area,
			scale: num("Tiles per character"),
			surface: str("Surface name"),
		}),
	},
	{
		name: "factorio_entities",
		op: "entities",
		description: "Entities in a rectangle: name, x, y, direction, state. Filter by type or name.",
		inputSchema: obj(
			{ ...area, type: str("Entity type, e.g. 'rail-signal'"), name: str("Entity name"), limit: num("Max entities") },
			["x1", "y1", "x2", "y2"],
		),
	},
	{
		name: "factorio_blockcheck",
		op: "blockcheck",
		description:
			"Signal blocks where a waiting train blocks foreign traffic. fits = tiles until the conflict block, grouped by junction. Optional area.",
		inputSchema: obj({
			...area,
			train_length: num("Train length in tiles"),
			limit: num("Max results"),
			detail: { type: "boolean", description: "Include per-block detail" },
		}),
	},
	{
		name: "factorio_todos",
		op: "todos",
		description: "Shared to-do list the players see in the GUI and via /todo.",
		inputSchema: obj({ all: { type: "boolean", description: "Include done items" } }),
	},
	{
		name: "factorio_todo_add",
		op: "todo_add",
		description: "Add an item to the shared to-do list (announced in chat).",
		inputSchema: obj({ text: str("Item text"), assignee: str("Player name") }, ["text"]),
	},
	{
		name: "factorio_todo_update",
		op: "todo_update",
		description: "Update a to-do item (announced in chat). assignee '' clears it.",
		inputSchema: obj(
			{ id: num("Item id"), done: { type: "boolean" }, text: str("New text"), assignee: str("Player name, '' clears") },
			["id"],
		),
	},
	{
		name: "factorio_say",
		op: "say",
		description: "Write a chat message in the game as [Pi]. Keep it short; plain text, Factorio rich text tags allowed.",
		inputSchema: obj({ text: str("Message text") }, ["text"]),
	},
	{
		name: "factorio_inbox",
		description:
			"Fetch @pi chat messages from players that are not answered yet and mark them as read. " +
			"Call this at the start of a conversation and whenever the user mentions the game chat; answer with factorio_say.",
		inputSchema: obj({ peek: { type: "boolean", description: "Only read, do not mark as read" } }),
	},
	{
		name: "factorio_call",
		description:
			"Fallback: call any op of the pi-companion mod directly. Prefer the typed factorio_* tools. " +
			"Ops: ping, summary, inbox, ack {upto, notify?}, say {text}, rails, map, entities, blockcheck, todos, todo_add, todo_update, todo_remove {id}, todo_clear_done.",
		inputSchema: obj({ op: str("Op name"), args: { type: "object", description: "Op arguments" } }, ["op"]),
	},
];
