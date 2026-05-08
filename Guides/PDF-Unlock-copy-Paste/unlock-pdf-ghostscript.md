<!--
    Title       : Unlock a Protected PDF with Ghostscript
    Author      : Chad
    Last Edit   : 05-08-2026
    GitHub      : https://github.com/chadmark/MSP-Scripts/blob/main/Guides/unlock-pdf-ghostscript.md
    Environment : Ubuntu, Windows
    Requires    : Ghostscript
    Version     : 1.0
-->

# Unlock a Protected PDF with Ghostscript

Use Ghostscript to "reprint" a PDF that has copy/paste and editing restrictions. This works when the PDF contains real selectable text (not scanned images). The output is a brand-new, unrestricted PDF.

---

## Ubuntu

### Install

```bash
sudo apt install ghostscript
```

### Unlock a Single File

```bash
gs -dNOPAUSE -dBATCH -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 \
   -sOutputFile=output_unlocked.pdf input.pdf
```

### Batch — Process All PDFs in a Directory

```bash
mkdir -p unlocked
for f in *.pdf; do
    gs -dNOPAUSE -dBATCH -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 \
       -sOutputFile="unlocked/${f%.pdf}_unlocked.pdf" "$f"
done
```

Output files are saved to an `unlocked/` subfolder alongside the originals.

---

## Windows

### Install

Download and run the latest Ghostscript Windows installer:

**https://github.com/ArtifexSoftware/ghostpdl-downloads/releases**

Grab the `gswin64.exe` installer. It will add Ghostscript to your system PATH automatically.

### Unlock a Single File

Open PowerShell in the directory containing your PDF and run:

```powershell
gswin64c -dNOPAUSE -dBATCH -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 `
   -sOutputFile=output_unlocked.pdf input.pdf
```

### Batch — Process All PDFs in a Directory

```powershell
New-Item -ItemType Directory -Force -Path "unlocked"
$files = Get-ChildItem -Filter "*.pdf"
foreach ($f in $files) {
    $output = "unlocked\$($f.BaseName)_unlocked.pdf"
    gswin64c -dNOPAUSE -dBATCH -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 -sOutputFile=$output $f.Name
}
```

Output files are saved to an `unlocked\` subfolder alongside the originals.

---

## Notes

- This method works on PDFs with **real text** that are permissions-locked. For scanned/image-based PDFs, use `ocrmypdf` instead.
- Warnings like `Invalid /Length supplied in Encryption dictionary` are harmless — Ghostscript repairs them on the fly.
- The output PDF is a freshly generated file with no restrictions.

---

*Maintained by Markley Technologies — [MSP-Scripts](https://github.com/chadmark/MSP-Scripts)*
