# markitdown-web

**GitHub:** `https://github.com/chadmark/MSP-Scripts/tree/main/docker/Microsoft_MarkItDown_DockerUI`

A self-hosted web front end for [microsoft/markitdown](https://github.com/microsoft/markitdown) — upload documents of various types, convert them to Markdown, and download the result. Single file returns a `.md`; multiple files return a `.zip`.

Built with Flask + SSE for real-time processing feedback. Dark-themed UI.

---

## Supported File Types

PDF, DOCX, DOC, PPTX, PPT, XLSX, XLS, HTML, CSV, JSON, XML, TXT, MD, EPUB, ZIP, JPG, PNG, GIF, BMP, WEBP, WAV, MP3

---

## Project Structure

```
markitdown-web/
├── app.py                  # Flask app (upload, SSE stream, download)
├── Dockerfile
├── docker-compose.yml
├── requirements.txt
├── README.md
└── templates/
    └── index.html          # Dark-themed upload UI
```

---

## Deploy

### Requirements
- Docker
- Docker Compose

### Build and start

```bash
docker compose up -d --build
```

Access at: `http://<host>:5000`

### Reload after changes

```bash
docker compose up -d --build
```

### Full rebuild (clear cache)

```bash
docker compose down && docker compose up -d --build --no-cache
```

### Stop

```bash
docker compose down
```

---

## How It Works

1. Files are uploaded via drag-and-drop or file picker (100MB max total)
2. Flask saves uploads to a temp directory and begins converting via the MarkItDown Python API
3. Progress is streamed to the browser in real time via Server-Sent Events — one log line per file as it completes
4. On completion, a UUID token is issued; the browser immediately hits `/download/<token>` to retrieve the output
5. Output files are cleaned up from disk 5 seconds after download
6. Nothing persists between sessions

---

## Notes

- Max upload size is set to 100MB in `app.py` (`MAX_CONTENT_LENGTH`). Adjust as needed.
- The `markitdown[all]` extra installs all optional dependencies (PDF, DOCX, PPTX, XLSX, audio transcription, etc.). See `requirements.txt`.
- No authentication. Deploy behind a reverse proxy (Nginx, Traefik) with access controls if exposing beyond localhost.
- Port can be changed in `docker-compose.yml` (default: `5000`).
