<!--
    Title       : Unlock a Protected PDF
    Author      : Chad
    Last Edit   : 05-08-2026
    GitHub      : https://github.com/chadmark/MSP-Scripts/blob/main/Guides/unlock-pdf-ghostscript.md
    Environment : Ubuntu, Windows
    Requires    : qpdf (primary), Ghostscript (fallback)
    Version     : 2.0
-->

# Unlock a Protected PDF

Remove copy/paste and editing restrictions from a permissions-locked PDF. This works when the PDF contains real selectable text (not scanned images).

**Use qpdf** as the primary tool — it strips restrictions losslessly without re-rendering the document. Ghostscript is a fallback for edge cases where qpdf doesn't work.

> For scanned/image-based PDFs, use `ocrmypdf` instead.

---

## Method 1 — qpdf (Recommended)

qpdf strips restrictions without re-rendering anything. Faster, lossless, and preserves fonts, formatting, and metadata exactly.

### Ubuntu

#### Install

```bash
sudo apt install qpdf
```

#### Unlock a Single File

```bash
qpdf --decrypt input.pdf input_unrestricted.pdf
```

#### Batch — Process All PDFs in a Directory

```bash
mkdir -p unlocked
for f in *.pdf; do
    qpdf --decrypt "$f" "unlocked/${f%.pdf}_unrestricted.pdf"
done
```

### Windows

#### Install

Download and run the latest qpdf Windows installer:

**https://github.com/qpdf/qpdf/releases**

Grab the `qpdf-*-msvc64.exe` installer. It will add qpdf to your system PATH automatically.

#### Unlock a Single File

```powershell
qpdf --decrypt input.pdf input_unrestricted.pdf
```

#### Batch — Process All PDFs in a Directory

```powershell
New-Item -ItemType Directory -Force -Path "unlocked"
$files = Get-ChildItem -Filter "*.pdf"
foreach ($f in $files) {
    $output = "unlocked\$($f.BaseName)_unrestricted.pdf"
    qpdf --decrypt $f.Name $output
}
```

Output files are saved to an `unlocked\` subfolder alongside the originals.

---

## Method 2 — Ghostscript (Fallback)

Use Ghostscript if qpdf fails. Ghostscript re-renders the entire document which is slower and may subtly alter formatting, but handles malformed or unusual PDFs that qpdf cannot process.

### Ubuntu

#### Install

```bash
sudo apt install ghostscript
```

#### Unlock a Single File

```bash
gs -dNOPAUSE -dBATCH -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 \
   -sOutputFile=input_unrestricted.pdf input.pdf
```

#### Batch — Process All PDFs in a Directory

```bash
mkdir -p unlocked
for f in *.pdf; do
    gs -dNOPAUSE -dBATCH -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 \
       -sOutputFile="unlocked/${f%.pdf}_unrestricted.pdf" "$f"
done
```

### Windows

#### Install

Download and run the latest Ghostscript Windows installer:

**https://github.com/ArtifexSoftware/ghostpdl-downloads/releases**

Grab the `gswin64.exe` installer. It will add Ghostscript to your system PATH automatically.

#### Unlock a Single File

Open PowerShell in the directory containing your PDF and run:

```powershell
gswin64c --% -dNOPAUSE -dBATCH -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 -sOutputFile=input_unrestricted.pdf input.pdf
```

> **Note:** The `--%` stop-parsing token tells PowerShell to pass all remaining arguments to Ghostscript exactly as typed, without interpreting them first.

#### Batch — Process All PDFs in a Directory

```powershell
New-Item -ItemType Directory -Force -Path "unlocked"
$files = Get-ChildItem -Filter "*.pdf"
foreach ($f in $files) {
    $output = "unlocked\$($f.BaseName)_unrestricted.pdf"
    $input = $f.Name
    gswin64c --% -dNOPAUSE -dBATCH -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 -sOutputFile=$output $input
}
```

Output files are saved to an `unlocked\` subfolder alongside the originals.

---

## Notes

- Warnings like `Invalid /Length supplied in Encryption dictionary` from Ghostscript are harmless — it repairs them on the fly.
- Neither tool can unlock PDFs protected with a password you don't know.
- For scanned/image-based PDFs where text cannot be selected, use `ocrmypdf` instead.

---

*Maintained by Markley Technologies — [MSP-Scripts](https://github.com/chadmark/MSP-Scripts)*
