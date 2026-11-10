# Screenshot of the primary screen, halved, for the agent to look at with Read.
# Purely on the PC: nothing in the game is touched, read or automated.
# Usage: powershell -NoProfile -File tools/shot.ps1   -> prints the PNG path
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# Without this, Windows hands us 150%-scaled bounds (2560x1440) and the shot is
# only the top-left two thirds of the 3840x2160 screen: the right side was missing
Add-Type -Name Dpi -Namespace Win -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[Win.Dpi]::SetProcessDPIAware() | Out-Null
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
