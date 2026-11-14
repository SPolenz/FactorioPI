// Thin client for the pi-companion mod: `/pi <json>` over RCON, reply `{ok, data, error}`.
import { Rcon, type RconOptions } from "../pi-extension/rcon.ts";

export interface Commander {
	command(cmd: string): Promise<string>;
	close(): void;
}

export class Companion {
	private rcon: Commander | undefined;

	private readonly config: () => RconOptions;
	private readonly factory: (opts: RconOptions) => Commander;

	constructor(config: () => RconOptions, factory: (opts: RconOptions) => Commander = (o) => new Rcon(o)) {
		this.config = config;
		this.factory = factory;
	}

	async call(op: string, args: Record<string, unknown> = {}): Promise<unknown> {
		this.rcon ??= this.factory(this.config());
		let raw: string;
		try {
			raw = await this.rcon.command(`/pi ${JSON.stringify({ ...args, op })}`);
		} catch (err) {
			this.close(); // reconnect on the next call
			throw err;
		}
		let parsed: { ok: boolean; data?: unknown; error?: string };
		try {
			parsed = JSON.parse(raw);
		} catch {
			throw new Error(`Unexpected reply from Factorio: ${raw.slice(0, 500)}`);
		}
		if (!parsed.ok) throw new Error(parsed.error ?? "unknown error");
		return parsed.data;
	}

	close(): void {
		this.rcon?.close();
		this.rcon = undefined;
	}
}
