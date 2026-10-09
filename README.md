# hd-restore

Batch **AI image upscaling** for [DeepSeek Harness](https://github.com/deepseek-ai) — plus
automatic **background fill for transparent PNGs**, in any colour you like.

Runs on **Real-ESRGAN (ncnn-Vulkan)**, so it uses your **GPU without CUDA**. Verified on an
Intel Arc **integrated** GPU, so a discrete card is not required.

```
input  ──► detect real transparency ──► composite onto background ──► AI upscale ×2/3/4 ──► output
```

---

## What it does

| | |
|---|---|
| **Batch** | Point it at a folder — it walks subfolders and processes every image |
| **Single** | Point it at one file |
| **Two engines** | `ai` = Real-ESRGAN reconstruction · `faithful` = deterministic resample (nothing invented) |
| **Anime model** | Illustrations, sprites, VTuber art, flat-colour artwork (default) |
| **Photo model** | Real photographs |
| **Background fill** | Transparent PNGs get composited onto **any colour** — white, black, `#RRGGBB`, or `r,g,b` |
| **Keep alpha** | `-BgColor transparent` upscales while preserving the alpha channel |
| **Fill only** | `-NoUpscale` just does the background pass at original size |
| **Verification** | `-Verify` re-checks every output and writes a contact sheet |

---

## ⚠️ When NOT to use the AI engine

The `ai` engine **reconstructs** detail. That is exactly what makes it shine on artwork —
and exactly what makes it the wrong tool in three situations. It was measured, not guessed:
on a portrait with a **woven straw hat**, Real-ESRGAN turned the regular weave into
hallucinated, warped pseudo-texture with visible seams, at *both* available models and
*several* input resolutions. The same file upscaled with `-Method faithful` was pixel-faithful.

Use `-Method faithful` instead of `ai` when the image contains:

| Situation | Why AI fails |
|---|---|
| **Fine regular textures** — woven/knitted fabric, mesh, chain-link, halftone print, brick | The model invents structure instead of enlarging it; output shows warped or tiled pseudo-texture |
| **Text documents, scans, screenshots** | Reconstructed strokes can change glyph shapes; OCR and legibility get worse, not better |
| **ID photos, portraits for official use, evidence, archival copies** | AI may subtly alter facial features. A photo that no longer matches the person is worse than a soft one |

`faithful` is also **dramatically faster**: the straw-hat portrait above took **8 minutes**
with `ai` (and came out broken) versus **1.6 seconds** with `faithful` — and only the latter
was usable.

```powershell
# AI: artwork, illustrations, photos where some reconstruction is welcome
powershell -ExecutionPolicy Bypass -File $SK -Source "D:\art"

# Faithful: documents, ID photos, fine textures
powershell -ExecutionPolicy Bypass -File $SK -Source "D:\docs" -Method faithful

# Faithful + a light crisp-up (still fully deterministic)
powershell -ExecutionPolicy Bypass -File $SK -Source "D:\docs" -Method faithful -Unsharp 0.4
```

> Rule of thumb: **if the image must stay literally true to the original, use `faithful`.**
> If it is art and you want it to look sharper, use `ai`.

---

## Requirements

- **Windows x64** (the bundled engine is a Windows binary)
- **PowerShell 5.1+** (built into Windows 10/11)
- A **Vulkan-capable GPU** — integrated graphics is fine
- ~200 MB free disk space

## Install

Copy the `hd-restore` folder into your skills directory:

```
<your-project>\.dsh\skills\hd-restore\
```

or user-wide:

```
%USERPROFILE%\.dsh\skills\hd-restore\
```

The realesrgan engine and both models ship inside `engine/`, so there is nothing else to
download.

## Usage

```powershell
$SK = "$PWD\.dsh\skills\hd-restore\scripts\hd_restore.ps1"

# whole folder -> creates <folder>\HD_restored\
powershell -ExecutionPolicy Bypass -File $SK -Source "D:\pics"

# one file
powershell -ExecutionPolicy Bypass -File $SK -Source "D:\pics\hero.png"

# several folders at once  (comma-joined in ONE argument - see the note below)
powershell -ExecutionPolicy Bypass -File $SK -Source "D:\pics\a,D:\pics\b" -OutDir "D:\out" -Verify

# transparent PNGs onto black
powershell -ExecutionPolicy Bypass -File $SK -Source "D:\pics" -BgColor black

# onto a custom colour
powershell -ExecutionPolicy Bypass -File $SK -Source "D:\pics" -BgColor "#1E90FF"

# keep transparency (no fill), just upscale
powershell -ExecutionPolicy Bypass -File $SK -Source "D:\pics" -BgColor transparent

# background pass only, no upscaling
powershell -ExecutionPolicy Bypass -File $SK -Source "D:\pics" -NoUpscale

# real photographs, 2x
powershell -ExecutionPolicy Bypass -File $SK -Source "D:\photos" -Model photo -Scale 2
```

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-Source` | *required* | Files, folders (`-Recurse`) or wildcards. Multiple values: comma-joined |
| `-OutDir` | `<first source dir>\<OutDirName>` | Where results go |
| `-OutDirName` | `HD_restored` | Name of the default output subfolder |
| `-Scale` | `4` | Upscale factor: 2, 3 or 4 |
| `-Method` | `ai` | `ai` = Real-ESRGAN reconstruction · `faithful` = deterministic resample |
| `-Unsharp` | `0` | `faithful` only. 0 = pure resample; 0.3–0.6 adds light crispening |
| `-Model` | `anime` | `ai` only. `anime` = illustration/art, `photo` = photographs |
| `-BgColor` | `white` | Fill colour — see below |
| `-NoUpscale` | off | Background pass only |
| `-KeepAlpha` | off | Same as `-BgColor transparent` |
| `-Verify` | off | Per-image check + contact sheet in `OutDir` |
| `-WorkDir` | auto-detected | Scratch folder; must be ASCII and writable by the engine |

### `-BgColor` accepts

| Form | Example |
|---|---|
| Name | `white`, `black`, `red`, `green`, `blue`, `gray`, `lightgray`, `darkgray`, `cyan`, `magenta`, `yellow`, `orange`, `pink`, `purple` |
| Hex | `#1E90FF` |
| RGB triplet | `"12,200,90"` — **quote it**, PowerShell splits bare commas |
| Keep alpha | `transparent` |

### Output names

Each file is named after **what actually happened to it**:

| Input | Output |
|---|---|
| transparent PNG, white fill, 4x, `ai` | `hero_x4_white.png` |
| transparent PNG, `#1E90FF`, 4x, `ai` | `hero_x4_1e90ff.png` |
| already-opaque PNG, 4x, `ai` | `hero_x4.png` — *no misleading colour tag* |
| `-BgColor transparent`, 4x, `ai` | `hero_x4.png` (RGBA preserved) |
| `-NoUpscale`, white fill | `hero_white_bg.png` |
| `-Method faithful`, 2x | `hero_x2_lanczos.png` |
| `-Method faithful` + blue fill, 2x | `hero_x2_lanczos_1e90ff.png` |

The `_lanczos` marker keeps faithful and AI outputs from colliding in the same folder.

Duplicate base names across folders get `_2`, `_3`, …

---

## ⚠️ Passing multiple paths

`powershell -File` binds multi-value parameters poorly. This fails:

```powershell
-File $SK -Source "D:\a" "D:\b"        # ❌ A positional parameter cannot be found
```

Use **one comma-joined string**:

```powershell
-File $SK -Source "D:\a,D:\b"          # ✅
```

`-Source "D:\a","D:\b"` also works when the script is called directly (`& $SK ...`).
The script splits commas itself, and a real path that contains a comma is detected first
and left intact.

---

## Notes & known engine quirks

These are measured behaviours of the Real-ESRGAN ncnn-Vulkan binary, all handled
automatically — listed here so nothing looks like magic.

1. **The engine cannot write to non-ASCII output paths.** It fails with
   `encode image ... failed` *after* all the compute, wasting the whole run. Input paths
   with non-ASCII are fine. This script writes every intermediate to an ASCII scratch
   folder and copies the finished file to the real destination.
2. **Some ASCII scratch locations still fail.** On the machine this was developed on,
   `%LOCALAPPDATA%\Temp` could not be written by the engine while an ordinary drive folder
   could. The script therefore **probes** a shortlist of candidate scratch folders with a
   tiny 8×8 image before processing anything, so a bad location fails instantly instead of
   after a long run. Override with `-WorkDir`.
3. **The engine prints its progress bar to stderr.** With `$ErrorActionPreference='Stop'`,
   merging stderr (`*>`) raises a terminating error that **kills the engine mid-run** and
   reports "no output". The call is deliberately made with the preference relaxed.
4. **`models/` must sit next to the executable** (or be given with `-m models` as a
   *relative* path). Absolute `-m` paths proved unreliable.
5. **Order matters:** composite the background *before* upscaling. Upscaling a transparent
   image first makes the model guess at the transparent region and produces fringing.

### Behaviour worth knowing

- **An alpha channel is not the same as a transparent background.** Many "ARGB" PNGs are
  100% opaque. Only images that genuinely contain transparent pixels get a fill; the rest
  are passed through untouched and stay `24bpp`.
- **Already-opaque images are not "filled" again** — they keep their own background.
- **The output folder is never re-processed.** With the default layout the output folder
  lives inside the source folder, so the scanner explicitly skips it; otherwise a second
  run would upscale the first run's results.

---

## Performance

Measured on an **Intel Arc integrated GPU** (Core Ultra 9 185H), 4x upscale:

| Input | Time | Output |
|---|---|---|
| 250 × 250 | ~2.5 s | 1000 × 1000 |
| 1024 × 1536 | ~23 s | 4096 × 6144 |
| 1254 × 1254 | ~30 s | 5016 × 5016 |
| 3840 × 2160 | ~2.4 min | 15360 × 8640 (132.7 MP) |

Upscaling 4x multiplies pixel count by 16 and file size by roughly 5–6x. A 4K input at 4x
lands at 132 MP — Photoshop needs ~1.6 GB just for that layer, and many viewers will
struggle. Consider `-Scale 2` for large inputs.

---

## Credits & licence

The bundled upscaler is **[Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN)** by
Xintao Wang, redistributed unmodified under the **BSD-3-Clause** licence — the full text is
in [`engine/LICENSE-Real-ESRGAN.txt`](engine/LICENSE-Real-ESRGAN.txt).

The wrapper script is provided as-is, without warranty. You are responsible for respecting
the licences of the images you process.
