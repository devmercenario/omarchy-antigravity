#!/usr/bin/env node
// =============================================================================
// Local runner for the Omarchy plugin marketplace's Automated Security Baseline.
//
// Runs the exact same deterministic scanner the marketplace uses, but against
// the LOCAL git commit — no push and no network required. It emulates the
// GitHub API + raw.githubusercontent.com endpoints the scanner reads by
// injecting a fetch implementation that serves the local git tree.
//
// Usage:
//   node tools/marketplace-baseline-local.mjs [<repo-url>] [<commit-sha>]
//
// Defaults: repo URL from `git remote.origin.url`, commit = HEAD.
//
// Exit code: 0 when the outcome is `passed` or `review-required`; 1 on
// `needs-fixes` or a scan error (so it can gate a pre-push hook).
// =============================================================================

import { execFileSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { runSecurityBaseline } from "./marketplace-baseline/security-baseline-scanner.mjs";
import { buildSecurityBaselineReport } from "./marketplace-baseline/security-baseline-report.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, "..");

function git(args, opts = {}) {
  return execFileSync("git", ["-C", repoRoot, ...args], {
    encoding: opts.encoding === null ? null : "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
}

function gitRaw(args) {
  return execFileSync("git", ["-C", repoRoot, ...args], {
    encoding: null,
    maxBuffer: 64 * 1024 * 1024,
  });
}

function detectRepoUrl() {
  let url = "";
  try {
    url = git(["config", "--get", "remote.origin.url"]).trim();
  } catch {
    // fall through
  }
  let match = url.match(/^git@github\.com:([^/]+)\/(.+?)(?:\.git)?$/);
  if (match) return `https://github.com/${match[1]}/${match[2]}`;
  match = url.match(/^https?:\/\/github\.com\/([^/]+)\/(.+?)(?:\.git)?$/);
  if (match) return `https://github.com/${match[1]}/${match[2]}`;
  throw new Error(
    "Could not determine repository URL from git remote.origin.url; pass <repo-url> explicitly.",
  );
}

// Parse `git ls-tree -r -l -z --full-tree <commit>` into GitHub-tree-shaped
// entries. With -z, records are NUL-terminated and paths are verbatim.
function parseTree(commit) {
  const out = gitRaw(["ls-tree", "-r", "-l", "-z", "--full-tree", commit]);
  const tree = [];
  let i = 0;
  while (i < out.length) {
    const nul = out.indexOf(0, i);
    if (nul === -1) break;
    const record = out.subarray(i, nul).toString("utf8");
    i = nul + 1;
    const tab = record.indexOf("\t");
    if (tab === -1) continue;
    const meta = record.slice(0, tab).trim().split(/\s+/);
    const path = record.slice(tab + 1);
    if (meta.length < 4 || meta[1] !== "blob") continue;
    const size = /^\d+$/.test(meta[3]) ? Number(meta[3]) : 0;
    tree.push({ path, mode: meta[0], type: "blob", size, sha: meta[2] });
  }
  return tree;
}

function buildLocalFetch({ repoUrl, commit }) {
  const match = repoUrl.match(/^https:\/\/github\.com\/([^/]+)\/([^/]+)\/?$/);
  if (!match) throw new Error(`Unsupported repo URL: ${repoUrl}`);
  const [, owner, repo] = match;
  const treeSha = git(["rev-parse", `${commit}^{tree}`]).trim();
  const apiBase = "https://api.github.com";
  const rawBase = `https://raw.githubusercontent.com/${owner}/${repo}/${commit}/`;
  let treeCache = null;
  const getTree = () => (treeCache ??= parseTree(commit));

  return async function fetchImpl(input, init = {}) {
    const url = String(input);
    const headers = init.headers || {};

    if (url.startsWith(apiBase)) {
      const path = url.slice(apiBase.length);
      let payload;
      if (/^\/repos\/[^/]+\/[^/]+\/?$/.test(path)) {
        payload = { private: false, disabled: false, archived: false, default_branch: "main" };
      } else if (/^\/repos\/[^/]+\/[^/]+\/commits\/[0-9a-f]{40}$/.test(path)) {
        payload = { sha: commit, commit: { tree: { sha: treeSha } } };
      } else if (/^\/repos\/[^/]+\/[^/]+\/git\/trees\/[0-9a-f]{40}\?recursive=1$/.test(path)) {
        payload = { truncated: false, tree: getTree() };
      } else {
        throw new Error(`Unexpected GitHub API path: ${path}`);
      }
      return new Response(JSON.stringify(payload), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }

    if (url.startsWith(rawBase)) {
      const filePath = decodeURIComponent(url.slice(rawBase.length));
      let raw;
      try {
        raw = gitRaw(["cat-file", "-p", `${commit}:${filePath}`]);
      } catch {
        return new Response("", { status: 404 });
      }
      const range = headers.Range || headers.range;
      if (range) {
        const rangeMatch = String(range).match(/^bytes=0-(\d+)$/);
        if (!rangeMatch) throw new Error(`Unexpected Range header: ${range}`);
        const total = raw.length;
        const end = Math.min(total, Number(rangeMatch[1]) + 1);
        const slice = raw.subarray(0, end);
        return new Response(slice, {
          status: 206,
          headers: { "content-range": `bytes 0-${slice.length - 1}/${total}` },
        });
      }
      return new Response(raw, { status: 200 });
    }

    throw new Error(`Unhandled fetch URL: ${url}`);
  };
}

async function main() {
  const args = process.argv.slice(2);
  const repoUrl = args[0] || detectRepoUrl();
  const commit = (args[1] || git(["rev-parse", "HEAD"]).trim()).toLowerCase();
  if (!/^[0-9a-f]{40}$/.test(commit)) {
    throw new Error("commit must be a full 40-character SHA");
  }

  const fetchImpl = buildLocalFetch({ repoUrl, commit });
  const result = await runSecurityBaseline(repoUrl, commit, { fetchImpl });

  // The submission metadata carries the resolved plugin id(s); the report
  // marker serialization requires them. Resolve from the root manifest so the
  // local report matches what the marketplace workflow produces.
  try {
    const manifestRaw = gitRaw(["cat-file", "-p", `${commit}:manifest.json`]).toString("utf8");
    const manifest = JSON.parse(manifestRaw);
    if (typeof manifest?.id === "string" && manifest.id) {
      result.pluginIds = Object.freeze([manifest.id]);
    }
  } catch {
    // No root manifest: leave pluginIds unset; the details still render.
  }

  process.stdout.write(buildSecurityBaselineReport(result, { context: "submission" }));
  process.stdout.write("\n");

  if (result.outcome === "needs-fixes") {
    console.error(`\nBaseline outcome: ${result.outcome} (blocks approval).`);
    process.exitCode = 1;
  } else {
    console.error(`\nBaseline outcome: ${result.outcome} (does not block approval).`);
    process.exitCode = 0;
  }
}

main().catch((error) => {
  console.error(`Automated security baseline failed: ${error.message}`);
  process.exitCode = 1;
});
