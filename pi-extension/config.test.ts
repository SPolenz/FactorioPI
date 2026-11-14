import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readRconConfig } from "./config.ts";

function fixture(text: string, run: (file: string) => void) {
	const dir = mkdtempSync(join(tmpdir(), "factorio-config-"));
	try {
		const file = join(dir, ".env");
		writeFileSync(file, text);
		run(file);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
}

test("legacy password file retains localhost defaults", () => {
	fixture("RCON_PASSWORD=test-secret\n", (file) => {
		assert.deepEqual(readRconConfig(file, {}), { host: "127.0.0.1", port: 27015, password: "test-secret" });
	});
});

test("local file configures host and port, preserves password with equals signs", () => {
	fixture("# comment\r\nRCON_HOST=game.example\r\nRCON_PORT=28000\r\nRCON_PASSWORD=a=b\r\n", (file) => {
		assert.deepEqual(readRconConfig(file, {}), { host: "game.example", port: 28000, password: "a=b" });
	});
});

test("environment overrides every local setting", () => {
	fixture("RCON_HOST=local.example\nRCON_PORT=28000\nRCON_PASSWORD=local\n", (file) => {
		assert.deepEqual(readRconConfig(file, {
			FACTORIO_RCON_HOST: "env.example", FACTORIO_RCON_PORT: "29000", FACTORIO_RCON_PASSWORD: "env-secret",
		}), { host: "env.example", port: 29000, password: "env-secret" });
	});
});

test("environment-only setup works without a file", () => {
	fixture("", (file) => {
		rmSync(file);
		assert.equal(readRconConfig(file, { FACTORIO_RCON_PASSWORD: "secret" }).port, 27015);
		assert.throws(() => readRconConfig(file, {}), /Set FACTORIO_RCON_PASSWORD/);
	});
});

test("invalid ports and empty hosts fail without leaking credentials", () => {
	fixture("RCON_PASSWORD=private-secret\n", (file) => {
		for (const port of ["", "0", "65536", "1.5", "NaN", "0x123", "-1"]) {
			assert.throws(() => readRconConfig(file, { FACTORIO_RCON_PORT: port }), /RCON port must be an integer between 1 and 65535/);
		}
		for (const host of ["", "bad host"]) {
			assert.throws(() => readRconConfig(file, { FACTORIO_RCON_HOST: host }), /RCON host must be/);
		}
	});
});

test("config is re-read on reconnect and file errors are not hidden", () => {
	fixture("RCON_PASSWORD=secret\n", (file) => {
		assert.equal(readRconConfig(file, {}).host, "127.0.0.1");
		writeFileSync(file, "RCON_HOST=new.example\nRCON_PASSWORD=secret\n");
		assert.equal(readRconConfig(file, {}).host, "new.example");
		assert.throws(() => readRconConfig(join(file, "invalid"), {}), /ENOTDIR/);
	});
});
