import assert from "assert";
import { mkdtemp, mkdir, readdir, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  argumentsRequestPlaylist,
  cleanupHostedFiles,
  contentTypeFor,
  cookiesArguments,
  downloaderArguments,
  filenameFromInfo,
  formatSummariesFromYtDlpInfo,
  infoResponseFromYtDlpInfo,
  isAuthorized,
  isHTTPURL,
  mediaModeForPlaylist,
  parseLastJSONObject,
  playlistArguments,
  resolverArguments,
  resolveMode,
  sanitizeFileName,
  shouldResolvePlaylist,
  splitCommandLine
} from "./resolver-core.mjs";

async function test(name, body) {
  try {
    await body();
    console.log(`ok - ${name}`);
  } catch (error) {
    console.error(`not ok - ${name}`);
    throw error;
  }
}

await test("splitCommandLine handles quotes and escapes", () => {
  assert.deepEqual(
    splitCommandLine('-f "bv*+ba/b" --merge-output-format mp4 --cookies-from-browser safari'),
    ["-f", "bv*+ba/b", "--merge-output-format", "mp4", "--cookies-from-browser", "safari"]
  );

  assert.deepEqual(
    splitCommandLine("--metadata-from-title '%(artist)s - %(title)s'"),
    ["--metadata-from-title", "%(artist)s - %(title)s"]
  );
});

await test("resolverArguments filters unsafe filesystem and exec options", () => {
  assert.deepEqual(
    resolverArguments("--exec rm --output bad.mp4 -f best --embed-metadata"),
    ["-f", "best", "--embed-metadata"]
  );

  assert.deepEqual(
    resolverArguments("--paths=/tmp/capture --config-location config.txt --audio-format m4a"),
    ["--audio-format", "m4a"]
  );
});

await test("resolverArguments filters user supplied downloader options", () => {
  assert.deepEqual(
    resolverArguments("--downloader aria2c --downloader-args '-x 8' -f best"),
    ["-f", "best"]
  );
  assert.deepEqual(
    resolverArguments("--external-downloader=aria2c --external-downloader-args=-x=8 --embed-metadata"),
    ["--embed-metadata"]
  );
});

await test("resolverArguments filters playlist control flags", () => {
  assert.deepEqual(
    resolverArguments("--yes-playlist -f best --no-playlist --playlist-start 3 --playlist-end=7 --embed-metadata"),
    ["-f", "best", "--embed-metadata"]
  );
  assert.equal(argumentsRequestPlaylist("--yes-playlist -f best"), true);
  assert.equal(argumentsRequestPlaylist("--playlist-start 3 -f best"), true);
  assert.equal(argumentsRequestPlaylist("--playlist-end=8 -f best"), true);
  assert.equal(argumentsRequestPlaylist("-f best"), false);
});

await test("playlistArguments preserves range within server limit", () => {
  assert.deepEqual(playlistArguments("", 20), ["--playlist-start", "1", "--playlist-end", "20"]);
  assert.deepEqual(
    playlistArguments("--playlist-start 3 --playlist-end 8", 20),
    ["--playlist-start", "3", "--playlist-end", "8"]
  );
  assert.deepEqual(
    playlistArguments("--playlist-start=5 --playlist-end=50", 10),
    ["--playlist-start", "5", "--playlist-end", "14"]
  );
  assert.deepEqual(
    playlistArguments("--playlist-start 9 --playlist-end 4", 20),
    ["--playlist-start", "9", "--playlist-end", "9"]
  );
});

await test("resolverArguments keeps subtitle and metadata options", () => {
  assert.deepEqual(
    resolverArguments("--write-subs --write-auto-subs --sub-langs all,-live_chat --embed-subs --merge-output-format mp4 --embed-thumbnail --embed-metadata"),
    [
      "--write-subs",
      "--write-auto-subs",
      "--sub-langs",
      "all,-live_chat",
      "--embed-subs",
      "--merge-output-format",
      "mp4",
      "--embed-thumbnail",
      "--embed-metadata"
    ]
  );
});

await test("cleanupHostedFiles removes only expired hosted job directories", async () => {
  const root = await mkdtemp(join(tmpdir(), "coto-down-cleanup-"));
  try {
    const oldDirectory = join(root, "old-job");
    const freshDirectory = join(root, "fresh-job");
    const looseFile = join(root, "keep.txt");
    await mkdir(oldDirectory);
    await mkdir(freshDirectory);
    await writeFile(join(oldDirectory, "old.mp4"), "");
    await writeFile(join(freshDirectory, "fresh.mp4"), "");
    await writeFile(looseFile, "");

    const now = Date.now();
    await utimes(oldDirectory, new Date(now - 4_000), new Date(now - 4_000));
    await utimes(freshDirectory, new Date(now - 500), new Date(now - 500));

    assert.deepEqual(await cleanupHostedFiles(root, 1_000, now), { removed: 1, skipped: 2 });
    assert.deepEqual((await readdir(root)).sort(), ["fresh-job", "keep.txt"]);
    assert.deepEqual(await cleanupHostedFiles(root, 0, now), { removed: 0, skipped: 0 });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

await test("cookiesArguments adds optional yt-dlp cookies file", () => {
  assert.deepEqual(cookiesArguments(""), []);
  assert.deepEqual(cookiesArguments(" /data/cookies.txt "), ["--cookies", "/data/cookies.txt"]);
});

await test("downloaderArguments adds admin configured external downloader", () => {
  assert.deepEqual(downloaderArguments("", ""), []);
  assert.deepEqual(downloaderArguments("aria2c", ""), ["--downloader", "aria2c"]);
  assert.deepEqual(
    downloaderArguments("aria2c", "aria2c:-x 8 -s 8"),
    ["--downloader", "aria2c", "--downloader-args", "aria2c:-x 8 -s 8"]
  );
});

await test("parseLastJSONObject reads final JSON object", () => {
  assert.deepEqual(
    parseLastJSONObject("noise\n{\"url\":\"https://example.com/a.mp4\"}\n"),
    { url: "https://example.com/a.mp4" }
  );

  assert.throws(() => parseLastJSONObject("not json"), /yt-dlp returned no JSON/);
});

await test("helpers classify URLs, filenames, and content types", () => {
  assert.equal(isHTTPURL("https://example.com/watch?v=1"), true);
  assert.equal(isHTTPURL("ftp://example.com/file"), false);

  assert.equal(sanitizeFileName("a/b:c?.mp4"), "a-b-c-.mp4");
  assert.equal(filenameFromInfo({ title: "Song/Name", ext: "m4a" }), "Song-Name.m4a");

  assert.equal(contentTypeFor("clip.mp4"), "video/mp4");
  assert.equal(contentTypeFor("audio.mp3"), "audio/mpeg");
  assert.equal(contentTypeFor("subtitle.vtt"), "text/vtt");
  assert.equal(contentTypeFor("archive.bin"), "application/octet-stream");
});

await test("resolveMode prefers explicit mode and keeps template fallback", () => {
  assert.equal(resolveMode({ mode: "audio", template: "Video" }), "audio");
  assert.equal(resolveMode({ mode: "unknown", template: "playlist" }), "playlist");
  assert.equal(resolveMode({ template: "My Custom Template" }), "custom");
});

await test("playlist requests are explicit and preserve item media mode", () => {
  assert.equal(shouldResolvePlaylist({ playlist: true, mode: "audio" }), true);
  assert.equal(shouldResolvePlaylist({ playlist: "yes", mode: "video" }), true);
  assert.equal(shouldResolvePlaylist({ mode: "playlist" }), true);
  assert.equal(shouldResolvePlaylist({ mode: "video", arguments: "--yes-playlist" }), true);
  assert.equal(shouldResolvePlaylist({ mode: "audio" }), false);
  assert.equal(mediaModeForPlaylist("playlist"), "video");
  assert.equal(mediaModeForPlaylist("audio"), "audio");
});

await test("infoResponseFromYtDlpInfo summarizes metadata and playlist count", () => {
  assert.deepEqual(
    infoResponseFromYtDlpInfo({
      title: "Example video",
      uploader: "Creator",
      webpage_url: "https://example.com/watch?v=1",
      thumbnail: "https://example.com/thumb.jpg",
      extractor_key: "Example",
      duration: 125,
      entries: [{ id: "one" }, { id: "two" }],
      formats: [
        {
          format_id: "18",
          ext: "mp4",
          resolution: "640x360",
          width: 640,
          height: 360,
          fps: 30,
          filesize: 12_000_000,
          tbr: 800,
          vcodec: "avc1.42001E",
          acodec: "mp4a.40.2",
          format_note: "360p"
        }
      ]
    }),
    {
      title: "Example video",
      uploader: "Creator",
      webpageURL: "https://example.com/watch?v=1",
      thumbnail: "https://example.com/thumb.jpg",
      extractor: "Example",
      durationSeconds: 125,
      entryCount: 2,
      formats: [
        {
          id: "18",
          extension: "mp4",
          resolution: "640x360",
          height: 360,
          fps: 30,
          filesizeBytes: 12_000_000,
          bitrateKbps: 800,
          note: "360p",
          videoCodec: "avc1.42001E",
          audioCodec: "mp4a.40.2",
          hasVideo: true,
          hasAudio: true
        }
      ]
    }
  );
});

await test("formatSummariesFromYtDlpInfo filters and sorts useful formats", () => {
  assert.deepEqual(
    formatSummariesFromYtDlpInfo({
      formats: [
        { format_id: "storyboard", ext: "mhtml", vcodec: "none", acodec: "none" },
        { format_id: "140", ext: "m4a", abr: 128, vcodec: "none", acodec: "mp4a.40.2" },
        { format_id: "137", ext: "mp4", height: 1080, tbr: 4500, vcodec: "avc1", acodec: "none" },
        { format_id: "22", ext: "mp4", height: 720, tbr: 1800, vcodec: "avc1", acodec: "mp4a.40.2" },
        { format_id: "137", ext: "mp4", height: 1080, tbr: 4500, vcodec: "avc1", acodec: "none" }
      ]
    }).map(format => format.id),
    ["22", "137", "140"]
  );
});

await test("isAuthorized accepts optional bearer token", () => {
  assert.equal(isAuthorized({}, ""), true);
  assert.equal(isAuthorized({ authorization: "Bearer secret" }, "secret"), true);
  assert.equal(isAuthorized({ Authorization: "Bearer secret" }, "secret"), true);
  assert.equal(isAuthorized({ authorization: "Bearer wrong" }, "secret"), false);
  assert.equal(isAuthorized({}, "secret"), false);
});

console.log("resolver-core tests passed");
