# Screenshot of the primary screen, halved, for the agent to look at with Read.
# Purely on the PC: nothing in the game is touched, read or automated.
# Usage: powershell -NoProfile -File tools/shot.ps1   -> prints the PNG path
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
$dir = Join-Path $env:LOCALAPPDATA "wow-companion\shots"
New-Item -ItemType Directory -Force $dir | Out-Null
$small = New-Object System.Drawing.Bitmap $bmp, ([int]($b.Width / 2)), ([int]($b.Height / 2))
$path = Join-Path $dir "now.png"
$small.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
$path
