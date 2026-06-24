#!/usr/bin/env node
import { createServer } from "node:http";
import { resolve } from "node:path";
import {
  cleanupHostedFiles,
  createResolver,
  isAuthorized,
  readJSON,
  sendJSON,
  serveDownloadedFile,
  setCorsHeaders
} from "./resolver-core.mjs";

const port = Number.parseInt(process.env.PORT ?? "8787", 10);
const host = process.env.HOST ?? "127.0.0.1";
const ytDlpBinary = process.env.YT_DLP ?? "yt-dlp";
const maxPlaylistItems = Number.parseInt(process.env.MAX_PLAYLIST_ITEMS ?? "20", 10);
const resolverMode = process.env.RESOLVER_MODE ?? "direct";
const downloadDirectory = resolve(process.env.DOWNLOAD_DIR ?? "downloads");
const publicBaseURL = (process.env.PUBLIC_BASE_URL ?? `http://${host}:${port}`).replace(/\/$/, "");
const resolverToken = process.env.RESOLVER_TOKEN ?? "";
const cookiesFile = process.env.YT_DLP_COOKIES_FILE ?? "";
const externalDownloader = process.env.YT_DLP_DOWNLOADER ?? "";
const externalDownloaderArgs = process.env.YT_DLP_DOWNLOADER_ARGS ?? "";
const hostedFileTTLHours = Number.parseFloat(process.env.HOSTED_FILE_TTL_HOURS ?? "72");
const cleanupIntervalMinutes = Number.parseFloat(process.env.CLEANUP_INTERVAL_MINUTES ?? "60");
const hostedFileTTLMilliseconds = Number.isFinite(hostedFileTTLHours) && hostedFileTTLHours > 0
  ? hostedFileTTLHours * 60 * 60 * 1000
  : 0;
const cleanupIntervalMilliseconds = Number.isFinite(cleanupIntervalMinutes) && cleanupIntervalMinutes > 0
  ? cleanupIntervalMinutes * 60 * 1000
  : 60 * 60 * 1000;

const resolver = createResolver({
  ytDlpBinary,
  maxPlaylistItems,
  resolverMode,
  cookiesFile,
  externalDownloader,
  externalDownloaderArgs,
  downloadDirectory,
  publicBaseURL
});

const server = createServer(async (request, response) => {
  setCorsHeaders(response);

  if (request.method === "OPTIONS") {
    response.writeHead(204);
    response.end();
    return;
  }

  if (!isAuthorized(request.headers, resolverToken)) {
    sendJSON(response, 401, { error: "Unauthorized" });
    return;
  }

  if (request.method === "GET" && request.url === "/health") {
    sendJSON(response, 200, { ok: true });
    return;
  }

  if (request.method === "GET" && request.url?.startsWith("/files/")) {
    await serveDownloadedFile(request, response, { publicBaseURL, downloadDirectory });
    return;
  }

  if (request.method === "POST" && request.url === "/info") {
    try {
      const input = await readJSON(request);
      const info = await resolver.inspectWithYtDlp(input);
      sendJSON(response, 200, info);
    } catch (error) {
      sendJSON(response, error.statusCode ?? 500, {
        error: error.message ?? "Resolver failed"
      });
    }
    return;
  }

  if (request.method !== "POST" || request.url !== "/resolve") {
    sendJSON(response, 404, { error: "Not found" });
    return;
  }

  try {
    const input = await readJSON(request);
    const resolved = await resolver.resolveWithYtDlp(input);
    sendJSON(response, 200, resolved);
  } catch (error) {
    sendJSON(response, error.statusCode ?? 500, {
      error: error.message ?? "Resolver failed"
    });
  }
});

server.on("error", error => {
  console.error(`resolver failed to listen on ${host}:${port}: ${error.message}`);
  process.exitCode = 1;
});

server.listen(port, host, () => {
  console.log(`coto down resolver listening on http://${host}:${port}/resolve`);
});

if (hostedFileTTLMilliseconds > 0) {
  const runCleanup = async () => {
    try {
      const { removed } = await cleanupHostedFiles(downloadDirectory, hostedFileTTLMilliseconds);
      if (removed > 0) {
        console.log(`cleaned ${removed} expired hosted download job(s)`);
      }
    } catch (error) {
      console.error(`hosted download cleanup failed: ${error.message}`);
    }
  };

  runCleanup();
  setInterval(runCleanup, cleanupIntervalMilliseconds).unref();
}
