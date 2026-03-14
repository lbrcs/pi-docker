import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";
import { execSync, spawn } from "child_process";
import { existsSync, mkdirSync, readFileSync, unlinkSync } from "fs";
import { join } from "path";

export default function (pi: ExtensionAPI) {
  const workspace = process.env.PI_WORKSPACE ?? "/workspace";
  const worktreesDir = join(workspace, ".worktrees");
  const timeoutMinutes = parseInt(
    process.env.PI_SUBAGENT_TIMEOUT_MINUTES ?? "30",
    10
  );

  // ── Helper: remove a worktree safely ────────────────────────────────────
  function removeWorktree(worktreePath: string): string | null {
    try {
      execSync(`git worktree remove "${worktreePath}" --force`, {
        cwd: workspace,
        stdio: "pipe",
      });
      return null;
    } catch (e: any) {
      return e.message;
    }
  }

  // ── spawn_subagent tool ─────────────────────────────────────────────────
  pi.registerTool({
    name: "spawn_subagent",
    label: "Spawn Subagent",
    description:
      "Creates a git worktree from the current feature branch and spawns " +
      "a pi subagent in it to complete a task autonomously. The subagent " +
      "commits its work and opens a PR against the feature branch when done. " +
      "Returns the PR URL.",
    parameters: Type.Object({
      task_name: Type.String({
        description:
          "Short kebab-case slug for the task — used as the worktree " +
          "directory name and git branch name. E.g. 'add-auth-tests'.",
      }),
      instructions: Type.String({
        description:
          "Complete instructions for the subagent. Be specific: include " +
          "what to build, any constraints, and acceptance criteria. The " +
          "subagent has no other context.",
      }),
    }),

    async execute(toolCallId, { task_name, instructions }, signal, onUpdate) {
      const worktreePath = join(worktreesDir, task_name);
      const branchName = `subagent/${task_name}`;
      const prUrlFile = join(worktreesDir, ".pr-url-" + task_name);

      // 1. Create .worktrees/ directory if needed
      if (!existsSync(worktreesDir)) {
        mkdirSync(worktreesDir, { recursive: true });
      }

      // 2. Bail if worktree already exists
      if (existsSync(worktreePath)) {
        return {
          content: [
            {
              type: "text",
              text:
                `Worktree already exists at ${worktreePath}. ` +
                `Use a different task_name or remove it first with: ` +
                `/cleanup-worktree ${task_name}`,
            },
          ],
          details: {},
        };
      }

      // 3. Create the worktree
      onUpdate(`Creating worktree: ${worktreePath} (branch: ${branchName})`);
      try {
        execSync(`git worktree add "${worktreePath}" -b "${branchName}"`, {
          cwd: workspace,
          stdio: "pipe",
        });
      } catch (e: any) {
        return {
          content: [
            { type: "text", text: `Failed to create worktree: ${e.message}` },
          ],
          details: {},
        };
      }

      // 4. Get the current feature branch name (PR base)
      const featureBranch = execSync("git rev-parse --abbrev-ref HEAD", {
        cwd: workspace,
        encoding: "utf8",
      }).trim();

      // 5. Build the full prompt
      const fullPrompt = `${instructions}

---
When you have completed the task:
1. Run \`git status\` and confirm you are only staging files you modified.
2. Stage files individually: \`git add <specific-file>\`
3. Commit with a descriptive message.
4. Push your branch: \`git push -u origin ${branchName}\`
5. Open a PR against '${featureBranch}' (NOT main):
   Write your PR body to a temp file, then run:
   \`\`\`
   gh pr create --base ${featureBranch} --title "<concise title>" --body-file /tmp/pr-body.md
   \`\`\`
6. Write the PR URL to the file: \`echo "<PR_URL>" > ${prUrlFile}\`
7. Also output the PR URL as the very last line of your response (starting with https://).`;

      // 6. Spawn with timeout
      onUpdate(
        `Spawning subagent for '${task_name}' (timeout: ${timeoutMinutes}m)...`
      );

      const timeoutMs = timeoutMinutes * 60 * 1000;
      const timeoutController = new AbortController();
      const timer = setTimeout(() => timeoutController.abort(), timeoutMs);

      if (signal) {
        signal.addEventListener("abort", () => timeoutController.abort(), {
          once: true,
        });
      }

      return new Promise((resolve) => {
        const child = spawn("pi", ["-p", fullPrompt, "--no-session"], {
          cwd: worktreePath,
          env: { ...process.env },
          stdio: ["ignore", "pipe", "pipe"],
          signal: timeoutController.signal,
        });

        let output = "";
        let lastUpdate = "";

        child.stdout.on("data", (chunk: Buffer) => {
          const text = chunk.toString();
          output += text;
          const trimmed = text.trim();
          if (trimmed && trimmed !== lastUpdate) {
            onUpdate(`[${task_name}] ${trimmed.slice(0, 200)}`);
            lastUpdate = trimmed;
          }
        });

        child.stderr.on("data", (chunk: Buffer) => {
          output += chunk.toString();
        });

        child.on("close", (code) => {
          clearTimeout(timer);

          // Read PR URL from known file first, fall back to stdout scan
          let prUrl: string | undefined;
          try {
            prUrl = readFileSync(prUrlFile, "utf8").trim();
            unlinkSync(prUrlFile);
          } catch {
            prUrl = output
              .split("\n")
              .map((l) => l.trim())
              .reverse()
              .find((l) => l.startsWith("https://github.com"));
          }

          const timedOut = timeoutController.signal.aborted && code !== 0;

          if (timedOut) {
            const cleanupErr = removeWorktree(worktreePath);
            resolve({
              content: [
                {
                  type: "text",
                  text:
                    `Subagent '${task_name}' timed out after ${timeoutMinutes} minutes.\n` +
                    (prUrl
                      ? `Partial PR: ${prUrl}\n`
                      : "No PR was created.\n") +
                    (cleanupErr
                      ? `Worktree cleanup failed: ${cleanupErr}\n`
                      : "Worktree cleaned up.\n") +
                    `Last output:\n${output.slice(-2000)}`,
                },
              ],
              details: { worktreePath, branchName, timedOut: true },
            });
          } else if (code === 0 && prUrl) {
            resolve({
              content: [
                {
                  type: "text",
                  text: `Subagent '${task_name}' completed successfully.\nPR: ${prUrl}`,
                },
              ],
              details: { worktreePath, branchName, featureBranch, prUrl },
            });
          } else {
            const cleanupErr = removeWorktree(worktreePath);
            resolve({
              content: [
                {
                  type: "text",
                  text:
                    `Subagent '${task_name}' exited with code ${code}.\n` +
                    (prUrl
                      ? `PR (may be partial): ${prUrl}\n`
                      : "No PR URL found.\n") +
                    (cleanupErr
                      ? `Worktree left in place (cleanup failed: ${cleanupErr}).\n`
                      : "Worktree cleaned up automatically.\n") +
                    `Last output:\n${output.slice(-3000)}`,
                },
              ],
              details: { worktreePath, branchName, exitCode: code },
            });
          }
        });
      });
    },
  });

  // ── /worktrees — list active worktrees ──────────────────────────────────
  pi.registerCommand("worktrees", {
    description: "List all active subagent worktrees",
    handler: async (_args, ctx) => {
      try {
        const result = execSync("git worktree list --porcelain", {
          cwd: workspace,
          encoding: "utf8",
        });
        ctx.ui.notify(result || "No worktrees found.", "info");
      } catch (e: any) {
        ctx.ui.notify(`Failed to list worktrees: ${e.message}`, "error");
      }
    },
  });

  // ── /cleanup-worktree — remove one ──────────────────────────────────────
  pi.registerCommand("cleanup-worktree", {
    description:
      "Remove a subagent worktree: /cleanup-worktree <task-name>",
    handler: async (args, ctx) => {
      const taskName = args.trim();
      if (!taskName) {
        ctx.ui.notify("Usage: /cleanup-worktree <task-name>", "error");
        return;
      }
      const err = removeWorktree(join(worktreesDir, taskName));
      if (err) {
        ctx.ui.notify(`Failed: ${err}`, "error");
      } else {
        ctx.ui.notify(`Removed worktree for '${taskName}'`, "success");
      }
    },
  });

  // ── /cleanup-all — remove all ─────────────────────────────────────────
  pi.registerCommand("cleanup-all", {
    description: "Remove all subagent worktrees under .worktrees/",
    handler: async (_args, ctx) => {
      if (!existsSync(worktreesDir)) {
        ctx.ui.notify("No .worktrees/ directory found.", "info");
        return;
      }
      try {
        const list = execSync("git worktree list --porcelain", {
          cwd: workspace,
          encoding: "utf8",
        });
        const worktreeLines = list
          .split("\n")
          .filter((l) => l.startsWith("worktree "))
          .map((l) => l.replace("worktree ", ""));

        let removed = 0;
        let failed = 0;
        for (const wt of worktreeLines) {
          if (wt.startsWith(worktreesDir)) {
            const err = removeWorktree(wt);
            if (err) {
              failed++;
            } else {
              removed++;
            }
          }
        }
        ctx.ui.notify(
          `Done: ${removed} removed, ${failed} failed.`,
          removed > 0 ? "success" : "info"
        );
      } catch (e: any) {
        ctx.ui.notify(`Cleanup failed: ${e.message}`, "error");
      }
    },
  });
}
