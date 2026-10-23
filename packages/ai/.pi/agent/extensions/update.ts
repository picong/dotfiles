import { spawn } from "node:child_process";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type UpdateMode = "all" | "self" | "extensions";

function parseUpdateArgs(args: string): string[] {
	const trimmed = args.trim();
	if (!trimmed) {
		return [];
	}

	const tokens = trimmed.split(/\s+/);
	const [first, ...rest] = tokens;

	if (first === "self" || first === "pi") {
		return ["--self", ...rest];
	}

	if (first === "extensions" || first === "extension" || first === "packages") {
		return ["--extensions", ...rest];
	}

	return tokens;
}

function detectMode(args: string[]): UpdateMode {
	if (args.includes("--self") || args.includes("self") || args.includes("pi")) {
		return "self";
	}

	if (args.includes("--extensions") || args.includes("--extension")) {
		return "extensions";
	}

	return "all";
}

function getModeLabel(mode: UpdateMode): string {
	if (mode === "self") {
		return "pi";
	}

	if (mode === "extensions") {
		return "pi extensions";
	}

	return "pi and extensions";
}

function runCommand(command: string, args: string[], cwd: string): Promise<number | null> {
	return new Promise((resolve, reject) => {
		const child = spawn(command, args, {
			cwd,
			env: process.env,
			stdio: "inherit",
		});

		child.on("error", reject);
		child.on("close", (code) => resolve(code));
	});
}

async function runPiUpdate(args: string[], cwd: string): Promise<number | null> {
	return await runCommand("pi", ["update", ...args], cwd);
}

export default function updateExtension(pi: ExtensionAPI) {
	pi.registerCommand("update", {
		description: "Update pi and/or pi extensions, then reload runtime",
		getArgumentCompletions: (prefix) => {
			const items = ["self", "pi", "extensions", "--self", "--extensions", "--force"];
			const filtered = items.filter((item) => item.startsWith(prefix));
			return filtered.length > 0 ? filtered.map((item) => ({ value: item, label: item })) : null;
		},
		handler: async (args, ctx) => {
			const updateArgs = parseUpdateArgs(args);
			const mode = detectMode(updateArgs);
			const label = getModeLabel(mode);

			if (!ctx.hasUI) {
				ctx.ui.notify("Update command requires interactive TUI mode", "error");
				return;
			}

			ctx.ui.notify(`Starting ${label} update...`, "info");

			const exitCode = await ctx.ui.custom<number | null>((tui, _theme, _keybindings, done) => {
				// Stop TUI so pi update can own the terminal(停止 TUI，让 pi update 接管终端)
				tui.stop();
				process.stdout.write("\x1b[2J\x1b[H");
				process.stdout.write(`Running: pi update ${updateArgs.join(" ")}\n\n`);

				runPiUpdate(updateArgs, ctx.cwd)
					.then((code) => {
						process.stdout.write(`\npi update exited with code ${code ?? "null"}.\n`);
						tui.start();
						tui.requestRender(true);
						done(code);
					})
					.catch((error: unknown) => {
						const message = error instanceof Error ? error.message : String(error);
						process.stderr.write(`\npi update failed: ${message}\n`);
						tui.start();
						tui.requestRender(true);
						done(1);
					});

				return { render: () => [], invalidate: () => {} };
			});

			if (exitCode !== 0) {
				ctx.ui.notify(`Update failed with exit code ${exitCode ?? "unknown"}; reload skipped.`, "error");
				return;
			}

			ctx.ui.notify("Update completed. Reloading pi runtime...", "info");
			await ctx.reload();
			return;
		},
	});
}
