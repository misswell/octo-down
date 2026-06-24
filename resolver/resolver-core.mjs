import { spawn } from "node:child_process";
import { createReadStream } from "node:fs";
import { mkdir, readdir, rm, stat } from "node:fs/promises";
import { basename, join } from "node:path";
import { randomUUID } from "node:crypto";

export const modeFormats = new Map([
  ["audio", "bestaudio[ext=m4a]/bestaudio/best"],
  ["video", "best[ext=mp4]/best"],
  ["playlist", "best[ext=mp4]/best"],
  ["custom", "best[ext=mp4]/best"]
]);

export function createResolver(options) {
  const {
    ytDlpBinary = "yt-dlp",
    maxPlaylistItems = 20,
    resolverMode = "direct",
    cookiesFile = "",
    externalDownloader = "",
    externalDownloaderArgs = "",
    downloadDirectory,
    publicBaseURL
  } = options;

  async function resolveWithYtDlp(input) {
    const sourceURL = stringValue(input.url);
    const customArguments = stringValue(input.arguments);
    const mode = resolveMode(input);

    if (!sourceURL || !isHTTPURL(sourceURL)) {
      throw httpError(400, "Expected a valid http(s) url");
    }

    if (shouldResolvePlaylist(input, mode)) {
      const entries = await resolvePlaylist(sourceURL, mediaModeForPlaylist(mode), customArguments);
      return { entries };
    }

    return await resolveSingle(sourceURL, mode, customArguments, shouldHostFile(input));
  }

  async function inspectWithYtDlp(input) {
    const sourceURL = stringValue(input.url);
    const customArguments = stringValue(input.arguments);
    const mode = resolveMode(input);

    if (!sourceURL || !isHTTPURL(sourceURL)) {
      throw httpError(400, "Expected a valid http(s) url");
    }

    const args = [
      "--dump-single-json",
      "--no-warnings",
      ...cookiesArguments(cookiesFile)
    ];

    if (shouldResolvePlaylist(input, mode)) {
      args.push("--flat-playlist");
    } else {
      args.push("--no-playlist");
    }

    args.push(...resolverArguments(customArguments), sourceURL);

    const output = await run(ytDlpBinary, args);
    return infoResponseFromYtDlpInfo(parseLastJSONObject(output.stdout));
  }

  async function resolvePlaylist(sourceURL, mode, customArguments) {
    const playlistOutput = await run(ytDlpBinary, [
      "--dump-single-json",
      "--flat-playlist",
      ...playlistArguments(customArguments, maxPlaylistItems),
      ...cookiesArguments(cookiesFile),
      sourceURL
    ]);
    const playlist = parseLastJSONObject(playlistOutput.stdout);
    const entries = Array.isArray(playlist.entries) ? playlist.entries : [];

    if (entries.length === 0) {
      throw httpError(502, "yt-dlp returned an empty playlist");
    }

    const resolvedEntries = [];
    for (const entry of entries.slice(0, maxPlaylistItems)) {
      const entryURL = firstString(entry.webpage_url, entry.url);
      if (!entryURL) {
        continue;
      }

      const absoluteURL = isHTTPURL(entryURL) ? entryURL : new URL(entryURL, sourceURL).toString();
      try {
        resolvedEntries.push(await resolveSingle(absoluteURL, mode, customArguments, false));
      } catch (error) {
        console.error(`playlist item skipped: ${error.message}`);
      }
    }

    if (resolvedEntries.length === 0) {
      throw httpError(502, "No playlist entries could be resolved");
    }

    return resolvedEntries;
  }

  async function resolveSingle(sourceURL, mode, customArguments, hosted) {
    if (hosted) {
      return await downloadAndHost(sourceURL, mode, customArguments);
    }

    const format = modeFormats.get(mode) ?? modeFormats.get("custom");
    const args = [
      "--dump-json",
      "--no-warnings",
      "--no-playlist",
      "-f",
      format,
      "-o",
      "%(title).200B.%(ext)s",
      ...cookiesArguments(cookiesFile),
      ...resolverArguments(customArguments),
      sourceURL
    ];

    const output = await run(ytDlpBinary, args);
    const info = parseLastJSONObject(output.stdout);
    const mediaURL = firstString(
      info.url,
      info.requested_downloads?.[0]?.url,
      info.requested_formats?.[0]?.url
    );

    if (!mediaURL || !isHTTPURL(mediaURL)) {
      throw httpError(502, "yt-dlp did not return a direct media URL");
    }

    return {
      url: mediaURL,
      title: firstString(info.title, info.fulltitle, info.id),
      filename: firstString(info._filename, filenameFromInfo(info))
    };
  }

  async function downloadAndHost(sourceURL, mode, customArguments) {
    const format = modeFormats.get(mode) ?? modeFormats.get("custom");
    const jobID = randomUUID();
    const jobDirectory = join(downloadDirectory, jobID);
    await mkdir(jobDirectory, { recursive: true });

    await run(ytDlpBinary, [
      "--no-warnings",
      "--no-playlist",
      "-f",
      format,
      "-o",
      join(jobDirectory, "%(title).200B.%(ext)s"),
      ...cookiesArguments(cookiesFile),
      ...downloaderArguments(externalDownloader, externalDownloaderArgs),
      ...resolverArguments(customArguments),
      sourceURL
    ]);

    const file = await firstFile(jobDirectory);
    if (!file) {
      throw httpError(502, "yt-dlp completed without producing a file");
    }

    const fileName = basename(file);
    return {
      url: `${publicBaseURL}/files/${jobID}/${encodeURIComponent(fileName)}`,
      title: fileName.replace(/\.[^.]+$/, ""),
      filename: fileName
    };
  }

  function shouldHostFile(input) {
    const delivery = stringValue(input.delivery).toLowerCase();
    return resolverMode === "hosted" || delivery === "hosted";
  }

  return {
    inspectWithYtDlp,
    resolveWithYtDlp,
    resolvePlaylist,
    resolveSingle
  };
}

export function resolveMode(input) {
  const mode = stringValue(input.mode).toLowerCase();
  if (modeFormats.has(mode)) {
    return mode;
  }

  const template = stringValue(input.template).toLowerCase();
  return modeFormats.has(template) ? template : "custom";
}

export function shouldResolvePlaylist(input, mode = resolveMode(input)) {
  return booleanValue(input.playlist)
    || mode === "playlist"
    || argumentsRequestPlaylist(input.arguments);
}

export function mediaModeForPlaylist(mode) {
  return mode === "playlist" ? "video" : mode;
}

export function infoResponseFromYtDlpInfo(info) {
  const entries = Array.isArray(info.entries) ? info.entries : [];
  return {
    title: firstString(info.title, info.fulltitle, info.id),
    uploader: firstString(info.uploader, info.channel, info.creator),
    webpageURL: firstString(info.webpage_url, info.original_url),
    thumbnail: firstString(info.thumbnail),
    extractor: firstString(info.extractor_key, info.extractor),
    durationSeconds: Number.isFinite(info.duration) ? info.duration : null,
    entryCount: entries.length || null,
    formats: formatSummariesFromYtDlpInfo(info)
  };
}

export function formatSummariesFromYtDlpInfo(info, limit = 24) {
  const formats = Array.isArray(info.formats) ? info.formats : [];
  const seen = new Set();

  return formats
    .map(formatSummary)
    .filter(format => {
      if (!format?.id || seen.has(format.id)) {
        return false;
      }
      seen.add(format.id);
      return format.hasVideo || format.hasAudio;
    })
    .sort(compareFormatSummaries)
    .slice(0, limit);
}

function formatSummary(format) {
  const id = firstString(format.format_id);
  if (!id) {
    return null;
  }

  const videoCodec = codecValue(format.vcodec);
  const audioCodec = codecValue(format.acodec);
  const width = finiteNumber(format.width);
  const height = finiteNumber(format.height);
  const resolution = firstString(
    format.resolution,
    width && height ? `${width}x${height}` : null,
    height ? `${height}p` : null
  );

  return {
    id,
    extension: firstString(format.ext),
    resolution,
    height,
    fps: finiteNumber(format.fps),
    filesizeBytes: finiteNumber(format.filesize) ?? finiteNumber(format.filesize_approx),
    bitrateKbps: finiteNumber(format.tbr) ?? finiteNumber(format.abr) ?? finiteNumber(format.vbr),
    note: firstString(format.format_note),
    videoCodec,
    audioCodec,
    hasVideo: Boolean(videoCodec),
    hasAudio: Boolean(audioCodec)
  };
}

function compareFormatSummaries(left, right) {
  const leftKind = formatKindScore(left);
  const rightKind = formatKindScore(right);
  if (leftKind !== rightKind) {
    return rightKind - leftKind;
  }

  const leftHeight = left.height ?? 0;
  const rightHeight = right.height ?? 0;
  if (leftHeight !== rightHeight) {
    return rightHeight - leftHeight;
  }

  return (right.bitrateKbps ?? 0) - (left.bitrateKbps ?? 0);
}

function formatKindScore(format) {
  if (format.hasVideo && format.hasAudio) {
    return 3;
  }
  if (format.hasVideo) {
    return 2;
  }
  if (format.hasAudio) {
    return 1;
  }
  return 0;
}

export async function serveDownloadedFile(request, response, options) {
  const { publicBaseURL, downloadDirectory } = options;

  try {
    const requestURL = new URL(request.url, publicBaseURL);
    const parts = requestURL.pathname.split("/").filter(Boolean);
    const jobID = parts[1];
    const fileName = decodeURIComponent(parts.slice(2).join("/"));

    if (!/^[0-9a-f-]{36}$/i.test(jobID) || fileName !== basename(fileName)) {
      sendJSON(response, 400, { error: "Invalid file path" });
      return;
    }

    const filePath = join(downloadDirectory, jobID, fileName);
    const fileStats = await stat(filePath);
    response.writeHead(200, {
      "content-length": fileStats.size,
      "content-type": contentTypeFor(fileName),
      "content-disposition": `attachment; filename*=UTF-8''${encodeRFC5987ValueChars(fileName)}`
    });
    createReadStream(filePath).pipe(response);
  } catch {
    sendJSON(response, 404, { error: "File not found" });
  }
}

export async function firstFile(directory) {
  const names = await readdir(directory);
  for (const name of names) {
    const filePath = join(directory, name);
    const fileStats = await stat(filePath);
    if (fileStats.isFile()) {
      return filePath;
    }
  }

  return null;
}

export async function cleanupHostedFiles(directory, maxAgeMilliseconds, now = Date.now()) {
  if (!Number.isFinite(maxAgeMilliseconds) || maxAgeMilliseconds <= 0) {
    return { removed: 0, skipped: 0 };
  }

  let entries;
  try {
    entries = await readdir(directory, { withFileTypes: true });
  } catch (error) {
    if (error.code === "ENOENT") {
      return { removed: 0, skipped: 0 };
    }
    throw error;
  }

  let removed = 0;
  let skipped = 0;
  for (const entry of entries) {
    if (!entry.isDirectory()) {
      skipped += 1;
      continue;
    }

    const entryPath = join(directory, entry.name);
    const entryStats = await stat(entryPath);
    if (now - entryStats.mtimeMs <= maxAgeMilliseconds) {
      skipped += 1;
      continue;
    }

    await rm(entryPath, { recursive: true, force: true });
    removed += 1;
  }

  return { removed, skipped };
}

export function resolverArguments(value) {
  const parsed = splitCommandLine(value);
  const blockedValueOptions = new Set([
    "--exec",
    "--exec-before-download",
    "--load-info-json",
    "--batch-file",
    "-a",
    "--config-location",
    "--paths",
    "-P",
    "--output",
    "-o",
    "--downloader",
    "--external-downloader",
    "--downloader-args",
    "--external-downloader-args",
    "--playlist-start",
    "--playlist-end",
    "--playlist-items"
  ]);
  const blockedFlagOptions = new Set([
    "--no-playlist",
    "--yes-playlist"
  ]);

  const result = [];
  for (let index = 0; index < parsed.length; index += 1) {
    const arg = parsed[index];
    const optionName = arg.split("=", 1)[0];
    if (blockedFlagOptions.has(optionName)) {
      continue;
    }
    if (blockedValueOptions.has(optionName)) {
      index += optionConsumesValue(arg) ? 1 : 0;
      continue;
    }
    result.push(arg);
  }

  return result;
}

export function argumentsRequestPlaylist(value) {
  const playlistOptions = new Set([
    "--yes-playlist",
    "--playlist-start",
    "--playlist-end",
    "--playlist-items"
  ]);
  return splitCommandLine(value).some(arg => playlistOptions.has(arg.split("=", 1)[0]));
}

export function playlistArguments(value, maxPlaylistItems) {
  const maxItems = positiveInteger(maxPlaylistItems) ?? 20;
  let start = 1;
  let end = null;
  const parsed = splitCommandLine(value);

  for (let index = 0; index < parsed.length; index += 1) {
    const arg = parsed[index];
    const optionName = arg.split("=", 1)[0];
    if (optionName !== "--playlist-start" && optionName !== "--playlist-end") {
      continue;
    }

    const rawValue = arg.includes("=") ? arg.slice(optionName.length + 1) : parsed[index + 1];
    if (!arg.includes("=")) {
      index += 1;
    }

    const parsedValue = positiveInteger(rawValue);
    if (!parsedValue) {
      continue;
    }

    if (optionName === "--playlist-start") {
      start = parsedValue;
    } else {
      end = parsedValue;
    }
  }

  const maximumEnd = start + maxItems - 1;
  end = Math.min(end ?? maximumEnd, maximumEnd);
  if (end < start) {
    end = start;
  }

  return ["--playlist-start", String(start), "--playlist-end", String(end)];
}

export function cookiesArguments(cookiesFile) {
  const trimmed = stringValue(cookiesFile);
  return trimmed ? ["--cookies", trimmed] : [];
}

export function downloaderArguments(externalDownloader, externalDownloaderArgs) {
  const downloader = stringValue(externalDownloader);
  if (!downloader) {
    return [];
  }

  const args = ["--downloader", downloader];
  const downloaderArgs = stringValue(externalDownloaderArgs);
  if (downloaderArgs) {
    args.push("--downloader-args", downloaderArgs);
  }
  return args;
}

export function optionConsumesValue(arg) {
  return !arg.includes("=");
}

export function splitCommandLine(value) {
  value = stringValue(value);
  const args = [];
  let current = "";
  let quote = null;
  let escaping = false;

  for (const char of value) {
    if (escaping) {
      current += char;
      escaping = false;
      continue;
    }

    if (char === "\\") {
      escaping = true;
      continue;
    }

    if (quote) {
      if (char === quote) {
        quote = null;
      } else {
        current += char;
      }
      continue;
    }

    if (char === "'" || char === "\"") {
      quote = char;
      continue;
    }

    if (/\s/.test(char)) {
      if (current) {
        args.push(current);
        current = "";
      }
      continue;
    }

    current += char;
  }

  if (current) {
    args.push(current);
  }

  return args;
}

export function run(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      stdio: ["ignore", "pipe", "pipe"]
    });

    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", chunk => {
      stdout += chunk;
    });
    child.stderr.on("data", chunk => {
      stderr += chunk;
    });
    child.on("error", error => {
      reject(httpError(500, `${command} failed to start: ${error.message}`));
    });
    child.on("close", code => {
      if (code === 0) {
        resolve({ stdout, stderr });
      } else {
        reject(httpError(502, stderr.trim() || `${command} exited with ${code}`));
      }
    });
  });
}

export function parseLastJSONObject(output) {
  const lines = output.split(/\r?\n/).map(line => line.trim()).filter(Boolean);
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    try {
      return JSON.parse(lines[index]);
    } catch {
      continue;
    }
  }

  throw httpError(502, "yt-dlp returned no JSON");
}

export function readJSON(request) {
  return new Promise((resolve, reject) => {
    let body = "";
    request.setEncoding("utf8");
    request.on("data", chunk => {
      body += chunk;
      if (body.length > 64 * 1024) {
        reject(httpError(413, "Request body is too large"));
        request.destroy();
      }
    });
    request.on("end", () => {
      try {
        resolve(JSON.parse(body || "{}"));
      } catch {
        reject(httpError(400, "Request body must be JSON"));
      }
    });
    request.on("error", reject);
  });
}

export function sendJSON(response, statusCode, value) {
  response.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8"
  });
  response.end(`${JSON.stringify(value)}\n`);
}

export function setCorsHeaders(response) {
  response.setHeader("access-control-allow-origin", "*");
  response.setHeader("access-control-allow-methods", "GET, POST, OPTIONS");
  response.setHeader("access-control-allow-headers", "content-type, authorization");
}

export function isAuthorized(headers, resolverToken) {
  if (!resolverToken) {
    return true;
  }

  const authorization = headers.authorization ?? headers.Authorization ?? "";
  return authorization === `Bearer ${resolverToken}`;
}

export function stringValue(value) {
  return typeof value === "string" ? value.trim() : "";
}

export function booleanValue(value) {
  if (typeof value === "boolean") {
    return value;
  }
  if (typeof value === "string") {
    return ["1", "true", "yes"].includes(value.trim().toLowerCase());
  }
  return false;
}

export function positiveInteger(value) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
}

export function firstString(...values) {
  return values.find(value => typeof value === "string" && value.trim().length > 0);
}

export function finiteNumber(value) {
  return Number.isFinite(value) ? value : null;
}

export function codecValue(value) {
  const codec = firstString(value);
  return codec && codec !== "none" ? codec : null;
}

export function isHTTPURL(value) {
  try {
    const url = new URL(value);
    return url.protocol === "http:" || url.protocol === "https:";
  } catch {
    return false;
  }
}

export function filenameFromInfo(info) {
  const title = firstString(info.title, info.id, "download");
  const ext = firstString(info.ext, "media");
  return `${sanitizeFileName(title)}.${sanitizeFileName(ext)}`;
}

export function sanitizeFileName(value) {
  return value.replace(/[\/\\?%*|"<>:]/g, "-").trim() || "download";
}

export function contentTypeFor(fileName) {
  const ext = fileName.split(".").pop()?.toLowerCase();
  switch (ext) {
    case "m4a": return "audio/mp4";
    case "mp3": return "audio/mpeg";
    case "mp4":
    case "m4v": return "video/mp4";
    case "mov": return "video/quicktime";
    case "webm": return "video/webm";
    case "srt": return "application/x-subrip";
    case "vtt": return "text/vtt";
    default: return "application/octet-stream";
  }
}

export function encodeRFC5987ValueChars(value) {
  return encodeURIComponent(value)
    .replace(/['()]/g, escape)
    .replace(/\*/g, "%2A");
}

export function httpError(statusCode, message) {
  const error = new Error(message);
  error.statusCode = statusCode;
  return error;
}
