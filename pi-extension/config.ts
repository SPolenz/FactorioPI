import * as fs from "node:fs";
import type { RconOptions } from "./rcon.ts";

/** Environment overrides the optional, git-ignored server/.env file. No shell evaluation. */
export function readRconConfig(envFile: string, env: NodeJS.ProcessEnv = process.env): RconOptions {
	let text = "";
	try {
		text = fs.readFileSync(envFile, "utf8");
	} catch (err) {
		if ((err as NodeJS.ErrnoException).code !== "ENOENT") throw err;
	}
	const local: Record<string, string> = {};
	for (const line of text.split(/\r?\n/)) {
		const match = /^\s*(RCON_HOST|RCON_PORT|RCON_PASSWORD)=(.*)$/.exec(line);
		if (match) local[match[1]] = match[2].trim();
	}
	const host = (env.FACTORIO_RCON_HOST ?? local.RCON_HOST ?? "127.0.0.1").trim();
	const portText = env.FACTORIO_RCON_PORT ?? local.RCON_PORT ?? "27015";
	const port = Number(portText);
	const password = env.FACTORIO_RCON_PASSWORD || local.RCON_PASSWORD;
	if (!host || /\s/.test(host)) throw new Error("RCON host must be a hostname or IP address without whitespace");
	if (!/^\d+$/.test(portText) || !Number.isInteger(port) || port < 1 || port > 65535) {
		throw new Error("RCON port must be an integer between 1 and 65535");
	}
	if (!password) throw new Error("Set FACTORIO_RCON_PASSWORD or RCON_PASSWORD in server/.env");
	return { host, port, password };
}
