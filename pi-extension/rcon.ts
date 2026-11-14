// Minimal Source-RCON client (Factorio). One persistent connection, requests are serialized.
import * as net from "node:net";

const AUTH = 3;
const EXEC = 2;

export interface RconOptions {
	host: string;
	port: number;
	password: string;
	timeoutMs?: number;
	connectTimeoutMs?: number;
}

export class Rcon {
	private socket: net.Socket | undefined;
	private buffer = Buffer.alloc(0);
	private nextId = 1;
	private pending = new Map<number, { resolve: (body: string) => void; reject: (err: Error) => void }>();
	private queue: Promise<unknown> = Promise.resolve();
	private connecting: Promise<void> | undefined;

	private readonly opts: RconOptions;

	constructor(opts: RconOptions) {
		this.opts = opts;
	}

	get connected(): boolean {
		return !!this.socket && !this.socket.destroyed;
	}

	/** Run one console command; requests are queued so only one is in flight. */
	command(cmd: string): Promise<string> {
		const run = async () => {
			await this.ensureConnected();
			return this.request(EXEC, cmd);
		};
		const result = this.queue.then(run, run);
		this.queue = result.catch(() => undefined);
		return result;
	}

	close(): void {
		this.socket?.destroy();
		this.socket = undefined;
		this.connecting = undefined;
	}

	private ensureConnected(): Promise<void> {
		if (this.connected) return Promise.resolve();
		if (this.connecting) return this.connecting;
		this.connecting = new Promise<void>((resolve, reject) => {
			const sock = net.createConnection({ host: this.opts.host, port: this.opts.port });
			sock.setNoDelay(true);
			const fail = (err: Error) => {
				this.failAll(err);
				this.close();
				reject(err);
			};
			sock.once("error", fail);
			const ms = this.opts.connectTimeoutMs ?? 5000;
			sock.setTimeout(ms, () => fail(new Error(`RCON connect to ${this.opts.host}:${this.opts.port} timed out after ${ms} ms`)));
			sock.on("data", (chunk) => this.onData(chunk));
			sock.on("close", () => {
				this.failAll(new Error("RCON connection closed"));
				this.socket = undefined;
				this.connecting = undefined;
			});
			sock.once("connect", async () => {
				this.socket = sock;
				sock.setTimeout(0);
				sock.off("error", fail);
				sock.on("error", () => undefined);
				try {
					await this.request(AUTH, this.opts.password);
					resolve();
				} catch (err) {
					fail(err as Error);
				}
			});
		}).finally(() => {
			this.connecting = undefined;
		});
		return this.connecting;
	}

	private request(kind: number, body: string): Promise<string> {
		const sock = this.socket;
		if (!sock) return Promise.reject(new Error("RCON not connected"));
		const id = this.nextId++;
		const payload = Buffer.from(body, "utf8");
		const packet = Buffer.alloc(4 + 8 + payload.length + 2);
		packet.writeInt32LE(8 + payload.length + 2, 0);
		packet.writeInt32LE(id, 4);
		packet.writeInt32LE(kind, 8);
		payload.copy(packet, 12);
		return new Promise<string>((resolve, reject) => {
			const timer = setTimeout(() => {
				this.pending.delete(id);
				reject(new Error(`RCON timeout after ${this.opts.timeoutMs ?? 15000} ms`));
			}, this.opts.timeoutMs ?? 15000);
			this.pending.set(id, {
				resolve: (b) => {
					clearTimeout(timer);
					resolve(b);
				},
				reject: (e) => {
					clearTimeout(timer);
					reject(e);
				},
			});
			sock.write(packet);
		});
	}

	private onData(chunk: Buffer): void {
		this.buffer = Buffer.concat([this.buffer, chunk]);
		while (this.buffer.length >= 4) {
			const size = this.buffer.readInt32LE(0);
			if (this.buffer.length < 4 + size) return;
			const id = this.buffer.readInt32LE(4);
			const body = this.buffer.subarray(12, 4 + size - 2).toString("utf8");
			this.buffer = this.buffer.subarray(4 + size);
			if (id === -1) {
				// Auth failure is answered with id -1.
				this.failAll(new Error("RCON authentication failed"));
				continue;
			}
			const p = this.pending.get(id);
			if (p) {
				this.pending.delete(id);
				p.resolve(body);
			}
		}
	}

	private failAll(err: Error): void {
		for (const p of this.pending.values()) p.reject(err);
		this.pending.clear();
	}
}
