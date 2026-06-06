import os
import uuid
import zipfile
import tempfile
import threading
from pathlib import Path
from flask import Flask, request, send_file, render_template, jsonify, Response, stream_with_context
from markitdown import MarkItDown
from werkzeug.utils import secure_filename

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 100 * 1024 * 1024  # 100MB max upload

ALLOWED_EXTENSIONS = {
    "pdf", "pptx", "ppt", "docx", "doc", "xlsx", "xls",
    "jpg", "jpeg", "png", "gif", "bmp", "webp",
    "html", "htm", "csv", "json", "xml",
    "txt", "md", "epub", "zip", "wav", "mp3",
}

# In-memory job store: token -> output file path (cleaned up after download)
jobs = {}
jobs_lock = threading.Lock()

def allowed_file(filename):
    return "." in filename and filename.rsplit(".", 1)[1].lower() in ALLOWED_EXTENSIONS

def sse(msg):
    return f"data: {msg}\n\n"

@app.route("/")
def index():
    return render_template("index.html")

@app.route("/convert", methods=["POST"])
def convert():
    if "files" not in request.files:
        return jsonify({"error": "No files provided"}), 400

    files = request.files.getlist("files")
    files = [f for f in files if f and f.filename and allowed_file(f.filename)]

    if not files:
        return jsonify({"error": "No valid files provided"}), 400

    # Save uploads to a persistent temp dir before streaming begins
    # (request context won't be available inside the generator)
    upload_dir = tempfile.mkdtemp()
    saved = []
    for file in files:
        name = secure_filename(file.filename)
        path = os.path.join(upload_dir, name)
        file.save(path)
        saved.append((name, path))

    def generate():
        md = MarkItDown(enable_plugins=False)
        out_dir = tempfile.mkdtemp()
        results = []
        total = len(saved)

        for i, (original_name, input_path) in enumerate(saved, 1):
            yield sse(f"[{i}/{total}] Converting: {original_name}")
            try:
                result = md.convert(input_path)
                stem = Path(original_name).stem
                out_name = f"{stem}.md"
                out_path = os.path.join(out_dir, out_name)
                with open(out_path, "w", encoding="utf-8") as f:
                    f.write(result.text_content)
                results.append(out_name)
                yield sse(f"[{i}/{total}] Done: {out_name}")
            except Exception as e:
                yield sse(f"ERROR: Failed to convert {original_name} — {str(e)}")
                # Clean up and bail
                import shutil
                shutil.rmtree(upload_dir, ignore_errors=True)
                shutil.rmtree(out_dir, ignore_errors=True)
                return

        # Clean up uploads
        import shutil
        shutil.rmtree(upload_dir, ignore_errors=True)

        if not results:
            yield sse("ERROR: No files were converted")
            return

        # Package output
        if len(results) == 1:
            final_path = os.path.join(out_dir, results[0])
            download_name = results[0]
        else:
            zip_path = os.path.join(out_dir, "converted.zip")
            with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
                for name in results:
                    zf.write(os.path.join(out_dir, name), name)
            final_path = zip_path
            download_name = "converted.zip"

        token = str(uuid.uuid4())
        with jobs_lock:
            jobs[token] = (final_path, download_name, out_dir)

        yield sse(f"DONE:{token}:{download_name}")

    return Response(stream_with_context(generate()), mimetype="text/event-stream",
                    headers={"X-Accel-Buffering": "no", "Cache-Control": "no-cache"})

@app.route("/download/<token>")
def download(token):
    with jobs_lock:
        entry = jobs.pop(token, None)

    if not entry:
        return "Not found or already downloaded", 404

    final_path, download_name, out_dir = entry

    import shutil

    def cleanup():
        shutil.rmtree(out_dir, ignore_errors=True)

    mimetype = "text/markdown" if download_name.endswith(".md") else "application/zip"

    response = send_file(final_path, as_attachment=True,
                         download_name=download_name, mimetype=mimetype)

    # Schedule cleanup after response is sent
    threading.Timer(5.0, cleanup).start()
    return response

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False, threaded=True)
