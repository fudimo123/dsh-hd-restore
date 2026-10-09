<#
    hd_restore.ps1  -  Batch HD restoration + background compositing.

    PORTABLE BUILD - no machine-specific paths. The engine ships inside this skill
    (engine/), and the scratch directory is discovered at runtime.

    PIPELINE (per image)
      1. measure REAL transparency. Note: an alpha channel is NOT the same as a
         transparent background - plenty of ARGB files are 100% opaque already.
         Only images that actually contain transparent pixels get composited.
      2. transparent -> alpha-composite onto the chosen background colour using
         SourceOver, so semi-transparent edges (hair, fur, anti-aliasing) blend
         correctly instead of showing a hard fringe.
      3. Real-ESRGAN (ncnn-Vulkan) upscale - GPU accelerated, no CUDA required.
      4. write the result into the output folder.

    ORDER MATTERS: composite the background FIRST, then upscale. If you upscale a
    transparent image first, the model has to guess what the transparent region
    means and you get fringing; compositing first gives it definite edge pixels.

    USAGE
      powershell -ExecutionPolicy Bypass -File hd_restore.ps1 -Source "D:\pics"

    IMPORTANT - HOW TO PASS MULTIPLE PATHS
      `powershell -File` binds multi-value parameters poorly. Use ONE
      comma-separated string:
          -Source "D:\a,D:\b,D:\c"        <- recommended, works everywhere
      These also work when calling the script directly (not via -File):
          -Source "D:\a","D:\b"
      This script splits commas itself, and a real path containing a comma is
      detected first and left intact.
#>

[CmdletBinding()]
param(
    # One or more files / folders / wildcard patterns. Comma-separated is safest.
    [Parameter(Mandatory = $true, Position = 0)]
    [string[]] $Source,

    # Output folder. Default: "<first source folder>\<OutDirName>"
    [string] $OutDir,

    # Name of the default output subfolder created next to the first source folder.
    # ASCII by default so it works on any console/locale; pass your own if you
    # prefer e.g. "HD修复".
    [string] $OutDirName = 'HD_restored',

    # Upscale factor: 2, 3 or 4
    [ValidateRange(2, 4)]
    [int] $Scale = 4,

    # anime = illustration / flat-colour art (default); photo = real photographs
    [ValidateSet('anime', 'photo')]
    [string] $Model = 'anime',

    # Background colour used to fill transparent areas.
    #   named : white, black, red, green, blue, gray/grey, transparent
    #   hex   : #RRGGBB   e.g. #FFFFFF
    #   RGB   : 255,255,255   (quote it - otherwise PowerShell splits on commas)
    # 'transparent' keeps the alpha channel (no compositing) and outputs RGBA.
    [string] $BgColor = 'white',

    # Skip the AI upscale; only do the background pass.
    [switch] $NoUpscale,

    # Do not touch transparent images at all (keep RGBA, no fill).
    [switch] $KeepAlpha,

    # Print per-image verification and write a contact sheet into OutDir.
    [switch] $Verify,

    # Scratch folder for intermediate files. Auto-detected when empty.
    # It MUST be writable by the engine and pure ASCII - see Resolve-WorkDir.
    [string] $WorkDir = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$ModelName = if ($Model -eq 'photo') { 'realesrgan-x4plus' } else { 'realesrgan-x4plus-anime' }

# ------------------------------------------------------------------ engine

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot = Split-Path -Parent $scriptDir

$engineCandidates = @(
    (Join-Path $skillRoot 'engine\realesrgan-ncnn-vulkan.exe'),
    (Join-Path $scriptDir 'realesrgan-ncnn-vulkan.exe')
)
$Engine = $null
foreach ($c in $engineCandidates) { if (Test-Path -LiteralPath $c) { $Engine = $c; break } }
if (-not $Engine) {
    throw ("Real-ESRGAN engine not found. Expected it next to this script:`n  " +
           ($engineCandidates -join "`n  ") +
           "`nDownload the release that includes engine/ and models/.")
}
$EngineDir = Split-Path -Parent $Engine
if (-not (Test-Path -LiteralPath (Join-Path $EngineDir 'models'))) {
    throw "Engine found at $Engine but its 'models' folder is missing."
}

# ------------------------------------------------------------------ colour

function Parse-BgColor {
    param([string] $Spec)

    $named = @{
        white = @(255, 255, 255); black = @(0, 0, 0)
        red = @(255, 0, 0); green = @(0, 255, 0); blue = @(0, 0, 255)
        gray = @(128, 128, 128); grey = @(128, 128, 128)
        lightgray = @(211, 211, 211); lightgrey = @(211, 211, 211)
        darkgray = @(64, 64, 64); darkgrey = @(64, 64, 64)
        cyan = @(0, 255, 255); magenta = @(255, 0, 255); yellow = @(255, 255, 0)
        orange = @(255, 165, 0); pink = @(255, 192, 203); purple = @(128, 0, 128)
    }
    $key = $Spec.Trim().ToLowerInvariant()

    if ($key -eq 'transparent' -or $key -eq 'none' -or $key -eq 'alpha') {
        return [pscustomobject]@{ Transparent = $true; Color = $null; Label = 'transparent' }
    }
    if ($named.ContainsKey($key)) {
        $v = $named[$key]
        return [pscustomobject]@{
            Transparent = $false
            Color = [System.Drawing.Color]::FromArgb($v[0], $v[1], $v[2])
            Label = $key
        }
    }
    if ($key -match '^#?([0-9a-f]{6})$') {
        $h = $Matches[1]
        $r = [Convert]::ToInt32($h.Substring(0, 2), 16)
        $g = [Convert]::ToInt32($h.Substring(2, 2), 16)
        $b = [Convert]::ToInt32($h.Substring(4, 2), 16)
        return [pscustomobject]@{
            Transparent = $false
            Color = [System.Drawing.Color]::FromArgb($r, $g, $b)
            Label = "#$h"
        }
    }
    if ($key -match '^(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})$') {
        $r = [int]$Matches[1]; $g = [int]$Matches[2]; $b = [int]$Matches[3]
        if ($r -gt 255 -or $g -gt 255 -or $b -gt 255) {
            throw "BgColor RGB values must be 0-255: $Spec"
        }
        return [pscustomobject]@{
            Transparent = $false
            Color = [System.Drawing.Color]::FromArgb($r, $g, $b)
            Label = "$r,$g,$b"
        }
    }
    throw ("Unrecognised -BgColor '$Spec'. Use a name (white/black/red/...), " +
           "#RRGGBB, 'r,g,b', or 'transparent'.")
}

$Bg = Parse-BgColor -Spec $BgColor
if ($KeepAlpha) { $Bg = [pscustomobject]@{ Transparent = $true; Color = $null; Label = 'transparent' } }

# ------------------------------------------------------------------ inputs

# Split one -Source value into possibly several items. If the whole value is a
# real path, keep it (so folders whose names contain commas still work).
function Expand-SourceItem {
    param([string] $Item)
    if ([string]::IsNullOrWhiteSpace($Item)) { return @() }
    if ($Item.Contains(',')) {
        if (Test-Path -LiteralPath $Item) { return @($Item) }
        return @($Item -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    return @($Item)
}

function Resolve-InputFile {
    param([string] $Item, [string] $SkipDir)
    $ext = '(?i)\.(png|jpg|jpeg|webp|bmp|tif|tiff)$'
    if (Test-Path -LiteralPath $Item -PathType Container) {
        $found = @(Get-ChildItem -LiteralPath $Item -Recurse -File | Where-Object { $_.Extension -match $ext })
    } elseif (Test-Path -LiteralPath $Item -PathType Leaf) {
        return @(Get-Item -LiteralPath $Item)
    } else {
        $found = @(Get-ChildItem -Path $Item -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.Extension -match $ext })
    }
    # Never re-process our own output. The default output folder lives INSIDE the
    # source folder, so without this a second run would pick up the previous run's
    # results and upscale them again.
    if ($SkipDir) {
        $sep = [System.IO.Path]::DirectorySeparatorChar
        $found = @($found | Where-Object {
            -not $_.FullName.StartsWith($SkipDir + $sep, [System.StringComparison]::OrdinalIgnoreCase)
        })
    }
    return $found
}

# Default output location: a subfolder of the folder holding the FIRST matched
# image. Resolved before the full scan so the scanner can exclude it.
if (-not $OutDir) {
    $seed = $null
    foreach ($item in $Source) {
        foreach ($piece in (Expand-SourceItem -Item $item)) {
            $hit = @(Resolve-InputFile -Item $piece -SkipDir '')
            if ($hit.Count -gt 0) { $seed = $hit[0]; break }
        }
        if ($seed) { break }
    }
    if (-not $seed) { throw "No image files matched: $($Source -join ', ')" }
    if ($seed.PSIsContainer) {
        $OutDir = Join-Path $seed.FullName $OutDirName
    } else {
        $OutDir = Join-Path (Split-Path -Parent $seed.FullName) $OutDirName
    }
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDirFull = (Resolve-Path -LiteralPath $OutDir).Path

$files = New-Object System.Collections.Generic.List[object]
foreach ($item in $Source) {
    foreach ($piece in (Expand-SourceItem -Item $item)) {
        foreach ($f in (Resolve-InputFile -Item $piece -SkipDir $OutDirFull)) { $files.Add($f) }
    }
}
$files = @($files | Sort-Object FullName -Unique)
if ($files.Count -eq 0) { throw "No image files matched: $($Source -join ', ')" }

# ------------------------------------------------------------------ work dir
# Engine path limitations (measured, not guessed):
#   - INPUT path  : non-ASCII is fine.
#   - OUTPUT path : non-ASCII FAILS with "encode image ... failed" (after all the
#                   compute is done, so it wastes the whole run).
#   - OUTPUT path : some locations simply fail to open for writing even when ASCII
#                   (observed: C:\Users\<u>\AppData\Local\Temp on one machine),
#                   while a normal drive folder works.
# So: probe candidates with a tiny image and use the first that really works.

function Test-EngineWritable {
    param([string] $Dir)
    try {
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        $probeIn = Join-Path $Dir '_probe_in.png'
        $probeOut = Join-Path $Dir '_probe_out.png'
        $probeLog = Join-Path $Dir '_probe.log'
        if (Test-Path -LiteralPath $probeOut) { Remove-Item -LiteralPath $probeOut -Force -ErrorAction SilentlyContinue }

        $b = New-Object System.Drawing.Bitmap(8, 8, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        try {
            $gg = [System.Drawing.Graphics]::FromImage($b)
            try { $gg.Clear([System.Drawing.Color]::White) } finally { $gg.Dispose() }
            $b.Save($probeIn, [System.Drawing.Imaging.ImageFormat]::Png)
        } finally { $b.Dispose() }

        Push-Location $EngineDir
        $prev = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $Engine -i $probeIn -o $probeOut -n $ModelName -s 2 -f png -m models *> $probeLog
        } finally {
            $ErrorActionPreference = $prev
            Pop-Location
        }
        $ok = Test-Path -LiteralPath $probeOut
        Remove-Item $probeIn, $probeOut, $probeLog -Force -ErrorAction SilentlyContinue
        return $ok
    } catch { return $false }
}

function Resolve-WorkDir {
    param([string] $Requested)

    if ($Requested) {
        if ($Requested -notmatch '^[\x20-\x7E]+$') {
            throw "WorkDir must be ASCII-only (engine limitation): $Requested"
        }
        if (-not (Test-EngineWritable -Dir $Requested)) {
            throw ("The engine cannot write into: $Requested`n" +
                   "Pick another -WorkDir (an ordinary drive folder works on the " +
                   "machines tested; some TEMP locations do not).")
        }
        return $Requested
    }

    $cands = New-Object System.Collections.Generic.List[string]
    if ($env:TEMP) { $cands.Add((Join-Path $env:TEMP 'hd_restore_work')) }
    if ($env:TMP  -and $env:TMP -ne $env:TEMP) { $cands.Add((Join-Path $env:TMP 'hd_restore_work')) }
    try {
        $cands.Add((Join-Path ([System.IO.Path]::GetTempPath()) 'hd_restore_work'))
    } catch { }
    if ($scriptDir -match '^[\x20-\x7E]+$') { $cands.Add((Join-Path $scriptDir '.hd_restore_work')) }

    foreach ($c in ($cands | Select-Object -Unique)) {
        Write-Host "probing work dir: $c"
        if (Test-EngineWritable -Dir $c) { return $c }
    }
    throw ("No usable scratch directory found. The engine must be able to write its " +
           "output somewhere ASCII. Pass -WorkDir with a normal drive folder.")
}

$WorkDir = Resolve-WorkDir -Requested $WorkDir
if (Test-Path -LiteralPath $WorkDir) {
    Get-ChildItem -LiteralPath $WorkDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
} else {
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
}

# ------------------------------------------------------------------ helpers

function Test-HasTransparency {
    param([string] $Path)
    $img = [System.Drawing.Image]::FromFile($Path)
    try {
        if ($img.PixelFormat.ToString() -notmatch 'Alpha|Argb') { return $false }
        $bmp = New-Object System.Drawing.Bitmap($img)
        try {
            $W = $bmp.Width; $H = $bmp.Height
            $sx = [Math]::Max(1, [int]($W / 60)); $sy = [Math]::Max(1, [int]($H / 60))
            for ($y = 0; $y -lt $H; $y += $sy) {
                for ($x = 0; $x -lt $W; $x += $sx) {
                    if ($bmp.GetPixel($x, $y).A -lt 250) { return $true }
                }
            }
            return $false
        } finally { $bmp.Dispose() }
    } finally { $img.Dispose() }
}

# Composite onto the background colour (SourceOver). Emits 24bpp RGB, or 32bpp
# ARGB when the background is 'transparent'.
function Save-Composited {
    param([string] $InPath, [string] $OutPath, [object] $Bg)
    $sim = [System.Drawing.Image]::FromFile($InPath)
    try {
        $W = [int]$sim.Width; $H = [int]$sim.Height
        $fmt = if ($Bg.Transparent) {
            [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
        } else {
            [System.Drawing.Imaging.PixelFormat]::Format24bppRgb
        }
        $cv = New-Object System.Drawing.Bitmap($W, $H, $fmt)
        try {
            $g = [System.Drawing.Graphics]::FromImage($cv)
            try {
                if ($Bg.Transparent) {
                    $g.Clear([System.Drawing.Color]::Transparent)
                } else {
                    $g.Clear($Bg.Color)
                }
                $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
                $g.CompositingQuality = 'HighQuality'
                $g.InterpolationMode = 'NearestNeighbor'
                $g.PixelOffsetMode = 'Half'
                $g.DrawImage($sim, 0, 0, $W, $H)
            } finally { $g.Dispose() }
            $cv.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
        } finally { $cv.Dispose() }
    } finally { $sim.Dispose() }
}

# Re-encode an image as an ordinary opaque 24bpp PNG. Used when nothing needed
# compositing, so a source that had no real transparency does not get silently
# promoted to 32bpp ARGB (which inflates the file and surprises people).
function Save-OpaqueCopy {
    param([string] $InPath, [string] $OutPath)
    $sim = [System.Drawing.Image]::FromFile($InPath)
    try {
        $W = [int]$sim.Width; $H = [int]$sim.Height
        $cv = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        try {
            $g = [System.Drawing.Graphics]::FromImage($cv)
            try {
                $g.Clear([System.Drawing.Color]::White)
                $g.InterpolationMode = 'NearestNeighbor'
                $g.PixelOffsetMode = 'Half'
                $g.DrawImage($sim, 0, 0, $W, $H)
            } finally { $g.Dispose() }
            $cv.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
        } finally { $cv.Dispose() }
    } finally { $sim.Dispose() }
}

function Get-ImageInfo {
    param([string] $Path)
    $i = [System.Drawing.Image]::FromFile($Path)
    try { return [pscustomobject]@{ W = $i.Width; H = $i.Height; Text = "$($i.Width)x$($i.Height)" } }
    finally { $i.Dispose() }
}

# ------------------------------------------------------------------ run

Write-Host "== hd-restore =="
Write-Host "engine : $Engine"
Write-Host "model  : $ModelName"
Write-Host "scale  : $(if ($NoUpscale) { 'none (background pass only)' } else { "x$Scale" })"
Write-Host "bg     : $($Bg.Label)"
Write-Host "out    : $OutDirFull"
Write-Host "input  : $($files.Count) image(s)"
Write-Host ""

$results = New-Object System.Collections.Generic.List[object]
$usedNames = @{}
$ok = 0; $fail = 0; $idx = 0

foreach ($f in $files) {
    $idx++
    $base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)

    $t0 = Get-Date
    $stage = 'detect'
    try {
        $needsFill = (-not $Bg.Transparent) -and (Test-HasTransparency -Path $f.FullName)
        $srcInfo = Get-ImageInfo -Path $f.FullName

        # Name each file by what actually happened to it: the background tag is only
        # appended when a background was really composited. Files that were already
        # opaque keep a clean <name>_x{scale}.png so the name never claims a fill
        # that did not occur.
        $suffix = if ($NoUpscale) {
            if ($needsFill) { "_$($Bg.Label -replace '[^0-9A-Za-z]', '')_bg" } else { '_bg' }
        } else {
            "_x$Scale" + $(if ($needsFill) { '_' + ($Bg.Label -replace '[^0-9A-Za-z]', '') } else { '' })
        }
        $outName = $base + $suffix + '.png'
        if ($usedNames.ContainsKey($outName)) {
            $n = $usedNames[$outName] + 1
            $usedNames[$outName] = $n
            $outName = "${base}_$n" + $suffix + '.png'
        } else {
            $usedNames[$outName] = 1
        }
        $final = Join-Path $OutDirFull $outName

        $inputForEngine = $f.FullName
        if ($needsFill -and -not $NoUpscale) {
            $stage = 'composite'
            $flat = Join-Path $WorkDir "flat$idx.png"
            Save-Composited -InPath $f.FullName -OutPath $flat -Bg $Bg
            $inputForEngine = $flat
        }

        if ($NoUpscale) {
            $stage = 'write'
            if ($needsFill) {
                Save-Composited -InPath $f.FullName -OutPath $final -Bg $Bg
            } elseif ($Bg.Transparent) {
                # -BgColor transparent: alpha was explicitly requested, keep it
                Save-Composited -InPath $f.FullName -OutPath $final -Bg $Bg
            } else {
                # already opaque -> normalise to plain 24bpp RGB
                Save-OpaqueCopy -InPath $f.FullName -OutPath $final
            }
        } else {
            $stage = 'upscale'
            $big = Join-Path $WorkDir "big$idx.png"
            $log = Join-Path $WorkDir "log$idx.txt"

            # The engine writes its progress bar to stderr. With
            # $ErrorActionPreference='Stop' a native command's stderr (merged via
            # *>) is raised as a TERMINATING error and kills the engine mid-run,
            # producing "engine produced no output". Drop to Continue for the call
            # and rely on the exit code and the output file instead.
            Push-Location $EngineDir
            $prevEap = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                & $Engine -i $inputForEngine -o $big -n $ModelName -s $Scale -f png -m models *> $log
                $engineExit = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $prevEap
                Pop-Location
            }

            if (-not (Test-Path -LiteralPath $big)) {
                $tail = ''
                if (Test-Path $log) { $tail = (Get-Content $log -Tail 6 -ErrorAction SilentlyContinue) -join ' | ' }
                throw "engine produced no output (exit $engineExit). $tail"
            }

            $stage = 'write'
            # Order matters here. When the user asked for -BgColor transparent,
            # $needsFill is FALSE by definition, so a "not needsFill -> flatten"
            # branch placed first would silently destroy the alpha channel they
            # explicitly asked to preserve. Check the transparent case first.
            if ($Bg.Transparent) {
                # keep alpha as the engine produced it
                Copy-Item -LiteralPath $big -Destination $final -Force
            } elseif (Test-HasTransparency -Path $big) {
                # real transparency still present -> composite onto the chosen colour
                Save-Composited -InPath $big -OutPath $final -Bg $Bg
            } elseif (-not $needsFill) {
                # already opaque, nothing composited -> normalise to plain 24bpp RGB
                Save-OpaqueCopy -InPath $big -OutPath $final
            } else {
                Copy-Item -LiteralPath $big -Destination $final -Force
            }
            Remove-Item -LiteralPath $big -Force -ErrorAction SilentlyContinue
        }

        Remove-Item -LiteralPath (Join-Path $WorkDir "flat$idx.png") -Force -ErrorAction SilentlyContinue

        $secs = ((Get-Date) - $t0).TotalSeconds
        $size = (Get-Item -LiteralPath $final).Length
        $outInfo = Get-ImageInfo -Path $final
        $ok++
        $tag = if ($needsFill) { "fill($($Bg.Label))+up" } else { 'opaque' }
        Write-Host ("  [{0,3}/{1}] {2,-46} {3,5} -> {4,-11} {5,7:N2} MB {6,6:N1}s  {7}" -f `
            $idx, $files.Count, $f.Name.Substring(0, [Math]::Min(46, $f.Name.Length)), `
            $srcInfo.Text, $outInfo.Text, ($size / 1MB), $secs, $tag)
        $results.Add([pscustomobject]@{
            Source = $f.FullName; Output = $final; SrcSize = $srcInfo.Text
            OutSize = $outInfo.Text; Bytes = $size; Seconds = [Math]::Round($secs, 1); Filled = $needsFill
        })
    }
    catch {
        $fail++
        Write-Host ("  [{0,3}/{1}] {2,-46} FAILED at '{3}': {4}" -f `
            $idx, $files.Count, $f.Name.Substring(0, [Math]::Min(46, $f.Name.Length)), $stage, $_.Exception.Message) -ForegroundColor Red
        $results.Add([pscustomobject]@{
            Source = $f.FullName; Output = ''; SrcSize = ''; OutSize = ''
            Bytes = 0; Seconds = 0; Filled = $null
        })
    }
}

Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue

# ------------------------------------------------------------------ report

Write-Host ""
Write-Host "== result =="
Write-Host "  succeeded : $ok"
Write-Host "  failed    : $fail"
Write-Host "  output    : $OutDirFull"

if ($Verify -and $ok -gt 0) {
    Write-Host ""
    Write-Host "== verification =="
    $bad = 0
    foreach ($r in ($results | Where-Object { $_.Output })) {
        $bmp = New-Object System.Drawing.Bitmap($r.Output)
        try {
            $W = [int]$bmp.Width; $H = [int]$bmp.Height
            $sx = [Math]::Max(1, [int]($W / 70)); $sy = [Math]::Max(1, [int]($H / 70))
            $trans = 0
            for ($y = 0; $y -lt $H; $y += $sy) {
                for ($x = 0; $x -lt $W; $x += $sx) { if ($bmp.GetPixel($x, $y).A -lt 250) { $trans++ } }
            }
            $corner = $bmp.GetPixel(3, 3)
            $flags = @()
            if (-not $Bg.Transparent -and $trans -gt 0) { $flags += "STILL-TRANSPARENT:$trans" }
            if ($flags.Count) { $bad++ }
            $mark = if ($flags.Count) { $flags -join ',' } else { "ok corner=$($corner.R),$($corner.G),$($corner.B)" }
            Write-Host ("  {0,-52} {1,-11} {2}" -f (Split-Path $r.Output -Leaf), $r.OutSize, $mark)
        } finally { $bmp.Dispose() }
    }
    if ($bad -eq 0) { Write-Host "  all outputs look correct" -ForegroundColor Green }
    else { Write-Host "  $bad output(s) need review" -ForegroundColor Yellow }

    # contact sheet - kept inside OutDir so a run never litters the parent folder
    $sheet = Join-Path $OutDirFull '_hd_restore_sheet.png'
    $imgs = @($results | Where-Object { $_.Output })
    $cw = 170; $ch = 170; $pad = 6; $cols = 6
    $rows = [Math]::Ceiling($imgs.Count / $cols)
    if ($rows -ge 1) {
        $W2 = [int](($cw + $pad) * $cols + $pad); $H2 = [int](($ch + $pad + 16) * $rows + $pad)
        $c2 = New-Object System.Drawing.Bitmap($W2, $H2)
        try {
            $g2 = [System.Drawing.Graphics]::FromImage($c2)
            try {
                $g2.Clear([System.Drawing.Color]::White)
                $g2.InterpolationMode = 'HighQualityBicubic'
                $fnt = New-Object System.Drawing.Font('Arial', 8)
                $i = 0
                foreach ($r in $imgs) {
                    $col = $i % $cols; $row = [Math]::Floor($i / $cols)
                    $px = $pad + $col * ($cw + $pad); $py = $pad + $row * ($ch + $pad + 16)
                    $im = [System.Drawing.Image]::FromFile($r.Output)
                    try { $g2.DrawImage($im, (New-Object System.Drawing.Rectangle([int]$px, [int]$py, $cw, $ch))) }
                    finally { $im.Dispose() }
                    $lbl = Split-Path $r.Output -Leaf
                    if ($lbl.Length -gt 26) { $lbl = $lbl.Substring(0, 26) }
                    $g2.DrawString($lbl, $fnt, [System.Drawing.Brushes]::DimGray, [int]$px, [int]($py + $ch + 1))
                    $i++
                }
            } finally { $g2.Dispose() }
            $c2.Save($sheet, [System.Drawing.Imaging.ImageFormat]::Png)
            Write-Host "  contact sheet: $sheet"
        } finally { $c2.Dispose() }
    }
}

if ($fail -gt 0) { exit 1 }
