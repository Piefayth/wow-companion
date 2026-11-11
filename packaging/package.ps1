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
# the streaming engine's libraries (sherpa-onnx, ONNX Runtime): the build puts
# them beside the exe, and the exe cannot start without them. Both builds use
# the same ones.
$dlls = @(Get-ChildItem (Split-Path -Parent $Exe) -Filter *.dll)
if ($dlls.Count -eq 0) { throw "no DLLs beside ${Exe}: the streaming engine's libraries are missing from the build" }
$dlls | Copy-Item -Destination $stage

# What git tracks: what the companion and its agent read beside the exe (home()
# in src/main.rs), and everything CLAUDE.md points at, the source included. Never
# what is generated (untracked) or this repo's own player's: their profile and
# layout (player/), their plan (docs/PLAN.md, the developers' to-do), their
# modules (another player's agent makes its own); nor the repo's own machinery.
$tracked = @(git -C $root ls-files)
if ($LASTEXITCODE -ne 0) { throw "git ls-files failed: run this in a checkout of the repo" }
foreach ($file in $tracked) {
    if ($file -match '^(player|modules|packaging|\.github)/' -or $file -in "docs/PLAN.md", ".gitignore") { continue }
    $to = Join-Path $stage $file
    New-Item -ItemType Directory -Force (Split-Path -Parent $to) | Out-Null
    Copy-Item (Join-Path $root $file) $to
}
foreach ($dir in "player", "modules", "models") {
    New-Item -ItemType Directory -Force (Join-Path $stage $dir) | Out-Null
}
# only the template: unzipping an update over an install must not overwrite the
# profile the agent keeps (the companion makes profile.md from it when missing)
Copy-Item (Join-Path $PSScriptRoot "profile.template.md") (Join-Path $stage "player\profile.template.md")
Copy-Item (Join-Path $PSScriptRoot "README.txt") $stage

$zip = Join-Path $Out "$Name.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip
Get-Item $zip | Select-Object Name, Length
