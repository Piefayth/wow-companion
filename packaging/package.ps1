# Assemble a release folder and zip from built exes.
# Usage: powershell -File packaging/package.ps1 -Exe <wow-companion.exe> -Setup <wow-companion-setup.exe>
#          [-CpuExe <cpu build>] [-Extra <dll>...] -Name <zip name without .zip> [-Out <dir>]
param(
    [Parameter(Mandatory)] [string] $Exe,
    [Parameter(Mandatory)] [string] $Setup,
    [string] $CpuExe,
    [string[]] $Extra = @(),
    [Parameter(Mandatory)] [string] $Name,
    [string] $Out = "dist"
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$stage = Join-Path $Out $Name
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $stage | Out-Null

Copy-Item $Exe (Join-Path $stage "wow-companion.exe")
Copy-Item $Setup (Join-Path $stage "wow-companion-setup.exe")
if ($CpuExe) { Copy-Item $CpuExe (Join-Path $stage "wow-companion-cpu.exe") }
foreach ($file in $Extra) { Copy-Item $file $stage }

# what the companion and its agent read beside the exe (home() in src/main.rs)
foreach ($dir in "addon", "modules", "integrations", "assets", "tools") {
    Copy-Item -Recurse (Join-Path $root $dir) (Join-Path $stage $dir)
}
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $stage "tools\__pycache__")
# the generated module bundle is rebuilt by install
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $stage "addon\WowCompanion\Modules.lua")
New-Item -ItemType Directory -Force (Join-Path $stage "docs") | Out-Null
Get-ChildItem (Join-Path $root "docs") -File | Where-Object { $_.Name -notin "PLAN.md", "history.md" } | Copy-Item -Destination (Join-Path $stage "docs")
Copy-Item (Join-Path $root "CLAUDE.md") $stage
New-Item -ItemType Directory -Force (Join-Path $stage "player") | Out-Null
Copy-Item (Join-Path $PSScriptRoot "profile.template.md") (Join-Path $stage "player\profile.md")
Copy-Item (Join-Path $PSScriptRoot "README.txt") $stage
New-Item -ItemType Directory -Force (Join-Path $stage "models") | Out-Null

$zip = Join-Path $Out "$Name.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip
Get-Item $zip | Select-Object Name, Length
