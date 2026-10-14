$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$appDir = Join-Path $repoRoot "ui\modules\apps\SmoothDrivingCoach"
$pngPath = Join-Path $appDir "app.png"
$jsonPath = Join-Path $appDir "app.json"

# 1. Validate app.json
$jsonObj = Get-Content -Raw $jsonPath | ConvertFrom-Json
if ($jsonObj.directive -ne "smoothDrivingCoach") {
    throw "Invalid directive in app.json"
}
Write-Host "[OK] Validated app.json ($($jsonObj.name))"

# 2. Generate crisp 320x160 preview icon (app.png) using System.Drawing
Add-Type -AssemblyName System.Drawing
$bmp = New-Object System.Drawing.Bitmap(320, 160)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

$bgBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(220, 18, 18, 20))
$g.FillRectangle($bgBrush, 0, 0, 320, 160)

# Radar circle on left
$radarCenter = New-Object System.Drawing.PointF(62, 68)
$outerPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(180, 90, 90, 95), 2)
$innerPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(140, 168, 221, 115), 1.5)
$axisPen  = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(110, 80, 80, 85), 1)
$horizonPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(130, 255, 165, 63), 1.5)

$g.DrawEllipse($outerPen, 16, 22, 92, 92)
$g.DrawEllipse($innerPen, 39, 45, 46, 46)
$g.DrawLine($axisPen, 16, 68, 108, 68)
$g.DrawLine($axisPen, 62, 22, 62, 114)
$g.DrawLine($horizonPen, 26, 62, 98, 74)

# Green G-ball in comfort zone
$ballBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 168, 221, 115))
$g.FillEllipse($ballBrush, 58, 60, 12, 12)

# Right side header text & graph preview
$fontTitle = New-Object System.Drawing.Font("Consolas", 11, [System.Drawing.FontStyle]::Bold)
$fontSmall = New-Object System.Drawing.Font("Consolas", 8, [System.Drawing.FontStyle]::Regular)
$whiteBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
$greenBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 168, 221, 115))
$orangeBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 255, 102, 0))

$deg = [char]0x00B0
$g.DrawString("SUAVIDADE 98%", $fontTitle, $greenBrush, 122, 14)
$g.DrawString("G 0.12g  J 0.3g/s", $fontSmall, $whiteBrush, 124, 34)
$g.DrawString("P +3.5$deg  R -0.4$deg", $fontSmall, $whiteBrush, 18, 118)

# Graph box
$graphRect = New-Object System.Drawing.Rectangle(122, 52, 184, 62)
$graphBg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(140, 0, 0, 0))
$g.FillRectangle($graphBg, $graphRect)
$g.DrawRectangle($axisPen, $graphRect)

$gLinePen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 168, 221, 115), 2)
$jLinePen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 255, 102, 0), 2)

$ptsG = @(
    (New-Object System.Drawing.PointF(124, 98)),
    (New-Object System.Drawing.PointF(155, 92)),
    (New-Object System.Drawing.PointF(185, 84)),
    (New-Object System.Drawing.PointF(215, 88)),
    (New-Object System.Drawing.PointF(245, 78)),
    (New-Object System.Drawing.PointF(275, 90)),
    (New-Object System.Drawing.PointF(304, 94))
)
$ptsJ = @(
    (New-Object System.Drawing.PointF(124, 106)),
    (New-Object System.Drawing.PointF(155, 102)),
    (New-Object System.Drawing.PointF(185, 70)),
    (New-Object System.Drawing.PointF(215, 100)),
    (New-Object System.Drawing.PointF(245, 66)),
    (New-Object System.Drawing.PointF(275, 101)),
    (New-Object System.Drawing.PointF(304, 105))
)
$g.DrawLines($gLinePen, $ptsG)
$g.DrawLines($jLinePen, $ptsJ)

# Bottom diagnosis bar
$diagBg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(180, 28, 35, 28))
$g.FillRectangle($diagBg, 12, 134, 296, 18)
$g.FillRectangle($greenBrush, 12, 134, 3, 18)
$g.DrawString("[OK] Conducao suave - Sem trancos", $fontSmall, $whiteBrush, 20, 137)

$bmp.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose()
$bmp.Dispose()
Write-Host "[OK] Generated $pngPath"

# 3. Install to BeamNG unpacked mods folder
$modTarget = Join-Path $env:LOCALAPPDATA "BeamNG\BeamNG.drive\current\mods\unpacked\smooth_driving_coach"
New-Item -ItemType Directory -Force -Path $modTarget | Out-Null
Copy-Item -Path (Join-Path $repoRoot "lua") -Destination $modTarget -Recurse -Force
Copy-Item -Path (Join-Path $repoRoot "ui") -Destination $modTarget -Recurse -Force
Copy-Item -Path (Join-Path $repoRoot "tests") -Destination $modTarget -Recurse -Force
Write-Host "[OK] Installed mod to $modTarget"

# 4. Run Lua unit tests inside BeamNG LuaJIT VM (console.x64.exe)
$beamngConsole = "C:\Program Files (x86)\Steam\steamapps\common\BeamNG.drive\Bin64\console.x64.exe"
if (Test-Path $beamngConsole) {
    Write-Host "[INFO] Running unit tests in BeamNG console.x64.exe..."
    $testOutput = & $beamngConsole file "mods/unpacked/smooth_driving_coach/tests/test_smooth_driving_coach.lua" 2>&1
    $testOutput | ForEach-Object { Write-Host $_ }
    Remove-Item -Path (Join-Path $modTarget "tests") -Recurse -Force -ErrorAction SilentlyContinue
    if (($testOutput -join "`n") -notmatch "ALL 8 TEST SUITES PASSED SUCCESSFULLY!") {
        throw "BeamNG Lua unit tests failed!"
    }
}

# 5. Run UI Directive unit tests in Node.js
if (Get-Command node -ErrorAction SilentlyContinue) {
    & node (Join-Path $repoRoot "tests\test_ui_app.js")
}


