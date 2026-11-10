# Captures the bottom-right corner of the primary screen (where the game's data
# strip draws) as raw pixels: 8-byte header (width, height as int32) then BGRA rows.
param([string]$Out, [int]$Width = 1024, [int]$Height = 256)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# Without this the capture is in scaled (150%) coordinates and resampled, so the
# game's 3840x2160 pixels arrive blurred into 2560x1440 and no colour is exact
Add-Type -Name Dpi -Namespace Win -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[Win.Dpi]::SetProcessDPIAware() | Out-Null
$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap $Width, $Height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.Right - $Width, $b.Bottom - $Height, 0, 0, (New-Object System.Drawing.Size $Width, $Height))
$rect = New-Object System.Drawing.Rectangle 0, 0, $Width, $Height
$data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, $bmp.PixelFormat)
$bytes = New-Object byte[] ($data.Stride * $Height)
[System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
$bmp.UnlockBits($data)
$fs = [System.IO.File]::Create($Out)
$fs.Write([BitConverter]::GetBytes([int]$Width), 0, 4)
$fs.Write([BitConverter]::GetBytes([int]$Height), 0, 4)
$fs.Write($bytes, 0, $bytes.Length)
$fs.Close()
