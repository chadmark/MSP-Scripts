# Perlego Download to PDF Workflow

> **Use this workflow only for content you are authorized to access and download.** Respect the service's terms of use, copyright restrictions, and any applicable licensing requirements.

## Overview

This workflow uses the **GladistonXD/perlego-download** Chrome extension to automate saving book content to a local HTML file, then converts that HTML file to a PDF with:

- PDF sidebar bookmarks generated from HTML headings
- Repaired internal Table of Contents links
- Local image and stylesheet resolution through WeasyPrint
- A Python virtual environment so the required packages do not interfere with the system Python installation

### Sources

- Chrome extension: https://github.com/GladistonXD/perlego-download
- Extension README: https://github.com/GladistonXD/perlego-download/blob/main/README.md
- Manual Chrome extension installation guide: https://dev.to/ben/how-to-install-chrome-extensions-manually-from-github-1612
- WeasyPrint: https://weasyprint.org/
- Beautiful Soup: https://www.crummy.com/software/BeautifulSoup/

---

## 1. Download the Chrome Extension from GitHub

Open:

https://github.com/GladistonXD/perlego-download

Download the repository using either of these methods:

### Option A — Download ZIP

1. Click **Code**.
2. Click **Download ZIP**.
3. Extract the ZIP to a permanent folder on the computer.

Example:

```text
C:\Tools\perlego-download
```

Do not delete or move the folder after loading the extension into Chrome unless you plan to load it again from the new location.

### Option B — Clone with Git

```bash
git clone https://github.com/GladistonXD/perlego-download.git
```

Using Git makes future updates easier because you can update the local copy with:

```bash
git pull
```

After updating the extension files, Chrome must still reload the unpacked extension before the changes take effect.

---

## 2. Install the Extension Manually in Chrome

Chrome can load the repository directly as an unpacked extension.

1. Open Chrome.
2. Navigate to:

```text
chrome://extensions/
```

3. Enable **Developer mode** in the upper-right corner.
4. Click **Load unpacked**.
5. Browse to the extracted or cloned `perlego-download` folder.
6. Select the folder containing `manifest.json`.

The extension should now appear on the Chrome Extensions page.

### After Updating the Extension

If you later run `git pull`, replace files, or edit the extension locally:

1. Return to:

```text
chrome://extensions/
```

2. Find the extension.
3. Click its **Reload/Refresh** icon.

Chrome does not automatically reload local extension code after the files change.

---

## 3. Use the Extension

The extension's README states that an **active account is required**.

Open the desired book normally in the Perlego e-reader. The repository gives the reader URL pattern as:

```text
https://ereader.perlego.com/1/book/(ID)
```

Once the book is open, start the extension's automation.

The extension processes the book and ultimately generates an `.html` file.

### Important Behavior While Downloading

The repository includes several operational notes:

- If processing becomes stuck, reload the page and start the extension again. Its continuation feature can resume where it left off.
- A reset option is available if the saved continuation state needs to be cleared.
- Read the format descriptions in the extension before starting a very large book.
- Large generated HTML files may consume significant browser memory.

---

## 4. Verify the Generated HTML Before Conversion

Before converting the downloaded HTML to PDF:

1. Open the `.html` file in a browser.
2. Scroll all the way to the bottom of the document.
3. Confirm that the final pages/content have loaded.

This step matters because very large HTML documents may load progressively. If the browser has not rendered the entire document before conversion, the resulting PDF can be incomplete.

For very large HTML files, the repository suggests trying **Firefox**, which may use less memory for this workload.

If a file is too large for the browser to process reliably, splitting the HTML into smaller parts may be necessary.

---

## 5. Prepare the Python PDF Conversion Environment

The PDF converter uses:

- Python 3
- Beautiful Soup 4
- WeasyPrint

A Python virtual environment is recommended.

### Linux / Ubuntu

From the folder where you want to keep the converter:

```bash
python3 -m venv .venv
source .venv/bin/activate
```

Upgrade `pip`:

```bash
pip install --upgrade pip
```

Install the required Python packages:

```bash
pip install weasyprint beautifulsoup4
```

### Why a Virtual Environment Is Used

Modern Ubuntu releases may enforce **PEP 668** and block direct system-wide `pip` changes with an error similar to:

```text
error: externally-managed-environment
```

Using a virtual environment keeps the Python packages isolated from the operating system's package-managed Python installation.

---

## 6. Install WeasyPrint System Dependencies on Ubuntu

If WeasyPrint reports missing graphics or rendering libraries, install the required OS packages.

```bash
sudo apt-get update && sudo apt-get install -y \
  libpango-1.0-0 \
  libpangocairo-1.0-0 \
  libgdk-pixbuf-2.0-0 \
  libffi-dev \
  shared-mime-info
```

### Package Name Note

On newer Ubuntu versions, use:

```text
libgdk-pixbuf-2.0-0
```

rather than the older:

```text
libgdk-pixbuf2.0-0
```

If the older name is used, `apt` may report:

```text
Package 'libgdk-pixbuf2.0-0' has no installation candidate
```

---

## 7. Save the HTML-to-PDF Script

Create:

```text
html_to_pdf_bookmarks.py
```

with the following contents:

```python
#!/usr/bin/env python3
"""
.SYNOPSIS
    Converts a single HTML file to PDF with PDF bookmarks and repaired
    interactive Table of Contents links.

.DESCRIPTION
    Reads a locally saved HTML document, parses its heading structure, repairs
    internal Table of Contents links, injects WeasyPrint bookmark CSS, and
    renders the result to PDF.

    Features:
      - Automatically detects HTML heading levels h1 through h6
      - Creates PDF sidebar bookmarks from document headings
      - Generates clean, unique IDs for heading destinations
      - Repairs Table of Contents hyperlinks by matching link text to headings
      - Attempts to repair legacy fragment links that reference old class/name IDs
      - Resolves local images, stylesheets, and other assets relative to the
        source HTML file by default
      - Supports limiting bookmark generation to selected heading levels
      - Supports overriding the base URL/path used for relative assets

.PARAMETER input_html
    Path to the source HTML file to convert.

.PARAMETER output_pdf
    Path and filename for the generated PDF.

.PARAMETER --levels
    Optional comma-separated list of heading levels to include as PDF bookmarks.

    Example:
      --levels h1,h2,h3

    If omitted, the script automatically includes heading levels that are
    present in the source HTML.

.PARAMETER --base-url
    Optional base URL or filesystem path used by WeasyPrint to resolve relative
    images, stylesheets, fonts, and other document assets.

    If omitted, the parent directory of input_html is used.

.EXAMPLE
    # Convert an HTML file using automatic bookmark-level detection:
    python html_to_pdf_bookmarks.py "book.html" "book.pdf"

.EXAMPLE
    # Include only H1, H2, and H3 headings in the PDF bookmark tree:
    python html_to_pdf_bookmarks.py "book.html" "book.pdf" --levels h1,h2,h3

.EXAMPLE
    # Specify a custom base path for relative document assets:
    python html_to_pdf_bookmarks.py "book.html" "book.pdf" --base-url "/path/to/assets"

.NOTES
    Author        : Chad Mark
    Last Edit     : 08-17-2026
    GitHub        : https://github.com/chadmark/MSP-Scripts/blob/main/General/html_to_pdf_bookmarks.py
    Environment   : Linux / Ubuntu with Python 3
    Requires      : Python 3.10+, WeasyPrint, BeautifulSoup4
    Version       : 1.0

    Python Environment:
      Recommended installation uses a dedicated virtual environment:

        python3 -m venv .venv
        source .venv/bin/activate
        pip install --upgrade pip
        pip install weasyprint beautifulsoup4

    Ubuntu / WeasyPrint Dependencies:
      Depending on the Ubuntu release, WeasyPrint may require:

        libpango-1.0-0
        libpangocairo-1.0-0
        libgdk-pixbuf-2.0-0
        libffi-dev
        shared-mime-info

    Table of Contents Handling:
      The script rebuilds heading IDs and rewrites matching internal anchor
      targets before WeasyPrint renders the PDF. This provides both PDF sidebar
      bookmarks and functional clickable links in the visible Table of Contents.

.LINK
    https://github.com/chadmark/MSP-Scripts
"""
import argparse
import sys
import re
from pathlib import Path
from bs4 import BeautifulSoup
from weasyprint import HTML

def build_bookmark_css(soup: BeautifulSoup, requested_levels: list[str] | None) -> str:
    all_levels = ["h1", "h2", "h3", "h4", "h5", "h6"]
    if requested_levels:
        levels = [lvl for lvl in requested_levels if lvl in all_levels]
    else:
        levels = [tag for tag in all_levels if soup.find(tag)]
    if not levels:
        return ""
    rules = []
    for i, tag in enumerate(levels, start=1):
        rules.append(
            f"{tag} {{ bookmark-level: {i}; bookmark-label: content(); bookmark-state: open; }}"
        )
    return "\n".join(rules)

def slugify(text: str) -> str:
    """Creates clean, uniform string IDs for anchoring."""
    text = text.lower().strip()
    text = re.sub(r'[^a-z0-9\s-]', '', text)
    return re.sub(r'[\s-]+', '-', text)

def fix_toc_and_heading_links(soup: BeautifulSoup):
    """
    Finds all elements acting as content headings, standardizes their IDs,
    and maps any matching text anchors inside the Table of Contents.
    """
    headings = soup.find_all(["h1", "h2", "h3", "h4", "h5", "h6"])
    heading_map = {}

    # Step 1: Enforce clean target IDs on headings based on text content
    for idx, heading in enumerate(headings):
        raw_text = heading.get_text().strip()
        if not raw_text:
            continue

        # Build a safe unique ID
        clean_id = f"section-{idx}-{slugify(raw_text[:30])}"
        heading["id"] = clean_id
        heading_map[raw_text.lower()] = clean_id

    # Step 2: Fix the broken clickable anchor elements inside the document/TOC
    fixed_links = 0
    for a_tag in soup.find_all("a"):
        link_text = a_tag.get_text().strip().lower()
        href = a_tag.get("href", "")

        # If the link text matches one of our heading sections, bind them together
        if link_text in heading_map:
            a_tag["href"] = f"#{heading_map[link_text]}"
            fixed_links += 1
        elif href.startswith("#"):
            # Check if it was trying to point to an old ID fragment that we just standardized
            old_frag = href[1:]
            for heading in headings:
                if heading.get("class") == old_frag or heading.get("name") == old_frag:
                    a_tag["href"] = f"#{heading['id']}"
                    fixed_links += 1
                    break

    print(f"Successfully repaired {fixed_links} internal Table of Contents hyperlinks.")

def convert(input_path: str, output_path: str, levels: list[str] | None, base_url: str | None):
    html_text = Path(input_path).read_text(encoding="utf-8", errors="replace")
    soup = BeautifulSoup(html_text, "html.parser")

    # Run the comprehensive link mapping correction pass
    fix_toc_and_heading_links(soup)

    bookmark_css = build_bookmark_css(soup, levels)
    if bookmark_css:
        style_tag = soup.new_tag("style")
        style_tag.string = bookmark_css
        if soup.head:
            soup.head.append(style_tag)
        else:
            head = soup.new_tag("head")
            head.append(style_tag)
            if soup.html:
                soup.html.insert(0, head)
            else:
                soup.insert(0, head)

    final_html = str(soup)
    resolved_base = base_url or str(Path(input_path).resolve().parent)
    print("Rendering final PDF document layout...")
    HTML(string=final_html, base_url=resolved_base).write_pdf(output_path)
    print(f"Done: {output_path}")

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("input_html", help="Path to the source HTML file")
    parser.add_argument("output_pdf", help="Path to write the output PDF")
    parser.add_argument("--levels", default=None)
    parser.add_argument("--base-url", default=None)
    args = parser.parse_args()
    levels = [lvl.strip().lower() for lvl in args.levels.split(",")] if args.levels else None
    convert(args.input_html, args.output_pdf, levels, args.base_url)

if __name__ == "__main__":
    main()
```

---

## 8. Convert the Downloaded HTML to PDF

Activate the virtual environment first if it is not already active:

```bash
source .venv/bin/activate
```

Then run:

```bash
python html_to_pdf_bookmarks.py "book.html" "book.pdf"
```

Example:

```bash
python html_to_pdf_bookmarks.py \
  "/home/user/Downloads/MyBook.html" \
  "/home/user/Downloads/MyBook.pdf"
```

### Limit Bookmark Levels

By default, the script detects available heading levels automatically.

To limit PDF bookmarks to specific HTML heading levels:

```bash
python html_to_pdf_bookmarks.py \
  "book.html" \
  "book.pdf" \
  --levels h1,h2,h3
```

### Specify a Base URL Manually

Normally the script uses the HTML file's parent folder as the base path for resolving local resources.

If needed:

```bash
python html_to_pdf_bookmarks.py \
  "book.html" \
  "book.pdf" \
  --base-url "/path/to/book/assets"
```

---

## 9. What the Conversion Script Fixes

The script does more than simply render HTML.

### PDF Sidebar Bookmarks

It scans for:

```text
<h1> through <h6>
```

and injects CSS `bookmark-level` rules so WeasyPrint can build a navigable PDF outline.

### Table of Contents Hyperlinks

The original HTML may contain internal TOC links that do not correctly point to the final PDF destinations.

The script:

1. Finds all HTML heading elements.
2. Generates a clean, unique ID for each heading.
3. Builds a text-to-heading lookup map.
4. Finds anchor tags whose text matches a heading.
5. Rewrites the anchor's `href` to the new heading ID.
6. Attempts to repair older fragment references where possible.

During conversion it reports the number of repaired internal links:

```text
Successfully repaired 123 internal Table of Contents hyperlinks.
```

It then renders the final PDF:

```text
Rendering final PDF document layout...
Done: book.pdf
```

---

## 10. Validate the Finished PDF

Open the resulting PDF and verify:

- The first and last pages are present.
- Images are visible.
- Fonts and formatting are acceptable.
- The PDF navigation/sidebar contains bookmarks.
- Clicking a bookmark jumps to the correct section.
- Clicking links in the document's visible Table of Contents jumps to the intended section.

For a large book, spot-check several chapters from the beginning, middle, and end.

---

## Troubleshooting

### `externally-managed-environment`

**Symptom**

```text
error: externally-managed-environment
```

**Fix**

Use a Python virtual environment:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install weasyprint beautifulsoup4
```

---

### Old Pillow Version Fails on Python 3.13

A legacy dependency set may attempt to install:

```text
Pillow==8.4.0
```

and fail with errors such as:

```text
error: subprocess-exited-with-error
Getting requirements to build wheel did not run successfully.
KeyError: '__version__'
```

For this PDF conversion workflow, install current packages directly instead of relying on an obsolete pinned requirements file:

```bash
pip install --upgrade pip
pip install weasyprint beautifulsoup4
```

The supplied `html_to_pdf_bookmarks.py` script does not directly import Pillow.

---

### `libgdk-pixbuf2.0-0` Has No Installation Candidate

**Symptom**

```text
Package libgdk-pixbuf2.0-0 is not available
E: Package 'libgdk-pixbuf2.0-0' has no installation candidate
```

**Fix**

Use the newer package name:

```bash
sudo apt-get install libgdk-pixbuf-2.0-0
```

or install the complete dependency set:

```bash
sudo apt-get update && sudo apt-get install -y \
  libpango-1.0-0 \
  libpangocairo-1.0-0 \
  libgdk-pixbuf-2.0-0 \
  libffi-dev \
  shared-mime-info
```

---

### PDF Sidebar Bookmarks Work but Visible TOC Links Do Not

This was the main reason for the final version of the Python script.

The working script repairs internal links before WeasyPrint renders the document by mapping heading text to generated anchor IDs and rewriting matching `<a href>` targets.

Use the full `html_to_pdf_bookmarks.py` script in this document rather than an earlier bookmark-only version.

---

### Images Are Missing from the PDF

Check the following:

1. Open the source HTML locally and confirm the images display there.
2. Make sure associated local files remain in the same relative folder structure.
3. Run the converter with the HTML file in its original location.
4. If needed, specify `--base-url` so WeasyPrint can resolve relative assets.
5. If the source images are remotely hosted and temporary, convert the HTML to PDF promptly.

The extension README specifically warns that images may have an expiration period, which is another reason to convert the generated HTML to a self-contained PDF soon after downloading it.

---

### Generated PDF Is Missing Later Chapters

1. Open the generated HTML in a browser.
2. Scroll to the very end.
3. Wait for all content to finish rendering/loading.
4. Run the converter again.

For very large documents, try Firefox or split the HTML into smaller parts.

---

### Extension Was Updated but Chrome Still Runs the Old Version

After modifying the local extension or running:

```bash
git pull
```

open:

```text
chrome://extensions/
```

and click the extension's **Reload/Refresh** icon.

---

## Quick Reference

### First-Time Setup

```bash
git clone https://github.com/GladistonXD/perlego-download.git
```

Load the repository into Chrome through:

```text
chrome://extensions/
Developer mode -> Load unpacked
```

Create the PDF environment:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install weasyprint beautifulsoup4
```

Install Ubuntu dependencies if required:

```bash
sudo apt-get update && sudo apt-get install -y \
  libpango-1.0-0 \
  libpangocairo-1.0-0 \
  libgdk-pixbuf-2.0-0 \
  libffi-dev \
  shared-mime-info
```

### Each Book

1. Open the book normally in the Perlego reader.
2. Run the Chrome extension.
3. Allow the process to complete.
4. Open the resulting HTML file.
5. Scroll to the bottom and confirm all content has loaded.
6. Convert:

```bash
python html_to_pdf_bookmarks.py "book.html" "book.pdf"
```

7. Verify PDF bookmarks, TOC links, images, and the final pages.

---

## Maintenance

### Update the Extension

If cloned with Git:

```bash
cd perlego-download
git pull
```

Then reload the extension in:

```text
chrome://extensions/
```

### Update Python Packages

Activate the environment:

```bash
source .venv/bin/activate
```

Then:

```bash
pip install --upgrade pip
pip install --upgrade weasyprint beautifulsoup4
```

Because package updates can alter rendering behavior, test an existing known-good HTML file after major upgrades.
