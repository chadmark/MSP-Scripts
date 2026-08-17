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
    text = re.sub(r"[^a-z0-9\s-]", "", text)
    return re.sub(r"[\s-]+", "-", text)


def fix_toc_and_heading_links(soup: BeautifulSoup):
    """
    Finds all elements acting as content headings, standardizes their IDs,
    and maps matching text anchors inside the Table of Contents.
    """
    headings = soup.find_all(["h1", "h2", "h3", "h4", "h5", "h6"])
    heading_map = {}

    # -----------------------------------------------------------------------
    # Step 1: Generate clean target IDs for all headings
    # -----------------------------------------------------------------------

    for idx, heading in enumerate(headings):
        raw_text = heading.get_text().strip()

        if not raw_text:
            continue

        clean_id = f"section-{idx}-{slugify(raw_text[:30])}"
        heading["id"] = clean_id
        heading_map[raw_text.lower()] = clean_id

    # -----------------------------------------------------------------------
    # Step 2: Repair clickable anchor elements
    # -----------------------------------------------------------------------

    fixed_links = 0

    for a_tag in soup.find_all("a"):
        link_text = a_tag.get_text().strip().lower()
        href = a_tag.get("href", "")

        if link_text in heading_map:
            a_tag["href"] = f"#{heading_map[link_text]}"
            fixed_links += 1

        elif href.startswith("#"):
            old_frag = href[1:]

            for heading in headings:
                if heading.get("class") == old_frag or heading.get("name") == old_frag:
                    a_tag["href"] = f"#{heading['id']}"
                    fixed_links += 1
                    break

    print(
        f"Successfully repaired {fixed_links} internal "
        "Table of Contents hyperlinks."
    )


def convert(
    input_path: str,
    output_path: str,
    levels: list[str] | None,
    base_url: str | None,
):
    html_text = Path(input_path).read_text(
        encoding="utf-8",
        errors="replace",
    )

    soup = BeautifulSoup(html_text, "html.parser")

    # Repair internal document navigation before rendering.
    fix_toc_and_heading_links(soup)

    # Build the WeasyPrint bookmark CSS from the document heading structure.
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

    # Resolve relative images/styles against the source HTML directory unless
    # explicitly overridden by --base-url.
    resolved_base = base_url or str(Path(input_path).resolve().parent)

    print("Rendering final PDF document layout...")

    HTML(
        string=final_html,
        base_url=resolved_base,
    ).write_pdf(output_path)

    print(f"Done: {output_path}")


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    parser.add_argument(
        "input_html",
        help="Path to the source HTML file",
    )

    parser.add_argument(
        "output_pdf",
        help="Path to write the output PDF",
    )

    parser.add_argument(
        "--levels",
        default=None,
        help="Comma-separated bookmark heading levels, e.g. h1,h2,h3",
    )

    parser.add_argument(
        "--base-url",
        default=None,
        help="Optional base URL/path for resolving relative assets",
    )

    args = parser.parse_args()

    levels = (
        [lvl.strip().lower() for lvl in args.levels.split(",")]
        if args.levels
        else None
    )

    convert(
        args.input_html,
        args.output_pdf,
        levels,
        args.base_url,
    )


if __name__ == "__main__":
    main()
