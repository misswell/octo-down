# coto down resolver

This is a small development resolver for coto down. It accepts the app's
`POST /info` and `POST /resolve` requests, calls `yt-dlp`, and returns either
link metadata, a direct media URL, or a hosted file URL.

## Requirements

- Node.js 20+
- `yt-dlp` available on `PATH`

## Run

```sh
npm start
```

The server listens on `http://127.0.0.1:8787/resolve` by default.

For a device on the same network, bind to all interfaces:

```sh
HOST=0.0.0.0 PORT=8787 npm start
```

Then set the app resolver endpoint to:

```text
http://YOUR_MAC_IP:8787/resolve
```

## Docker

The resolver can run in Docker with `yt-dlp` and `ffmpeg` included:

```sh
docker compose up --build
```

For device testing, set `PUBLIC_BASE_URL` in `docker-compose.yml` to the LAN URL
your iPhone can reach, for example:

```yaml
PUBLIC_BASE_URL: http://192.168.1.20:8787
```

Then set the app resolver endpoint to:

```text
http://192.168.1.20:8787/resolve
```

Use hosted mode when you want `yt-dlp` and `ffmpeg` to finish processing, such
as audio extraction or subtitle embedding, before iOS downloads the final file:

```yaml
RESOLVER_MODE: hosted
HOSTED_FILE_TTL_HOURS: 72
```

Hosted files are kept under `DOWNLOAD_DIR` and cleaned automatically after
`HOSTED_FILE_TTL_HOURS`. Set it to `0` to disable cleanup.

The Docker image also includes `aria2c`. To make hosted downloads use it as the
yt-dlp external downloader, set:

```yaml
RESOLVER_MODE: hosted
YT_DLP_DOWNLOADER: aria2c
YT_DLP_DOWNLOADER_ARGS: "aria2c:-x 8 -s 8"
```

## Request

Preview metadata:

```json
{
  "url": "https://example.com/watch?v=...",
  "template": "Video",
  "mode": "video",
  "arguments": "-f bv*+ba/b",
  "delivery": "direct",
  "playlist": false
}
```

Send this body to `POST /info`.

Start a download:

```json
{
  "url": "https://example.com/watch?v=...",
  "template": "Video",
  "mode": "video",
  "arguments": "-f bv*+ba/b --embed-thumbnail --embed-metadata",
  "delivery": "direct",
  "playlist": false
}
```

Use `delivery: "hosted"` to make the resolver download first and return a URL
under `/files/...`. You can also set hosted mode for every request:
Use `mode` for the requested media type (`video`, `audio`, `playlist`, or
`custom`) and `playlist: true` to expand a playlist into multiple entries.
When `arguments` contains `--playlist-start` or `--playlist-end`, the resolver
uses those values for playlist expansion while still capping the range with
`MAX_PLAYLIST_ITEMS`.

```sh
HOST=0.0.0.0 PUBLIC_BASE_URL=http://YOUR_MAC_IP:8787 RESOLVER_MODE=hosted npm start
```

## Response

Preview metadata:

```json
{
  "title": "Resolved title",
  "uploader": "Channel name",
  "webpageURL": "https://example.com/watch?v=...",
  "thumbnail": "https://example.com/thumb.jpg",
  "extractor": "Example",
  "durationSeconds": 125,
  "entryCount": null,
  "formats": [
    {
      "id": "22",
      "extension": "mp4",
      "resolution": "1280x720",
      "height": 720,
      "fps": 30,
      "filesizeBytes": 42000000,
      "bitrateKbps": 1800,
      "note": "720p",
      "videoCodec": "avc1",
      "audioCodec": "mp4a.40.2",
      "hasVideo": true,
      "hasAudio": true
    }
  ]
}
```

`formats` is populated for single-item previews. Playlist previews stay flat and
usually return `entryCount` without a full format list.

Single item:

```json
{
  "url": "https://cdn.example.com/file.mp4",
  "title": "Resolved title",
  "filename": "resolved-title.mp4"
}
```

Playlist:

```json
{
  "entries": [
    {
      "url": "https://cdn.example.com/one.mp4",
      "title": "Episode 1",
      "filename": "episode-1.mp4"
    }
  ]
}
```

## Environment

- `HOST`: bind address, default `127.0.0.1`
- `PORT`: bind port, default `8787`
- `PUBLIC_BASE_URL`: public URL used for hosted file links
- `RESOLVER_TOKEN`: optional Bearer token required for `/health`, `/info`, `/resolve`, and `/files`
- `YT_DLP`: `yt-dlp` binary path, default `yt-dlp`
- `YT_DLP_COOKIES_FILE`: optional cookies.txt file path passed to `yt-dlp --cookies`
- `YT_DLP_DOWNLOADER`: optional admin-configured yt-dlp external downloader for hosted downloads, for example `aria2c`
- `YT_DLP_DOWNLOADER_ARGS`: optional arguments passed with `yt-dlp --downloader-args`
- `MAX_PLAYLIST_ITEMS`: playlist expansion limit, default `20`
- `RESOLVER_MODE`: `direct` or `hosted`, default `direct`
- `DOWNLOAD_DIR`: hosted-file storage directory, default `downloads`
- `HOSTED_FILE_TTL_HOURS`: hosted-file retention window, default `72`; use `0` to disable cleanup
- `CLEANUP_INTERVAL_MINUTES`: cleanup cadence, default `60`

## Limits

This sample resolver is intended for development. If you expose it outside your
LAN, put it behind authentication, rate limits, and storage cleanup.

Set `RESOLVER_TOKEN` and enter the same token in coto down Settings when the
resolver is reachable by other devices:

```yaml
RESOLVER_TOKEN: change-me
```

For platforms that need login cookies, mount a Netscape-format cookies file and
set `YT_DLP_COOKIES_FILE`:

```yaml
volumes:
  - ./cookies.txt:/run/secrets/cookies.txt:ro
environment:
  YT_DLP_COOKIES_FILE: /run/secrets/cookies.txt
```
