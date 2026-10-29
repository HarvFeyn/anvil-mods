# Builds one zip per mod (each folder with Scripts\main.lua) in dist\,
# ready to attach to a GitHub Release. Each zip holds the mod's folder,
# so players extract it straight into ue4ss\Mods\.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$Dist = Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Force $Dist | Out-Null

$Mods = Get-ChildItem -Directory $PSScriptRoot | Where-Object { Test-Path (Join-Path $_.FullName 'Scripts\main.lua') }

foreach ($Mod in $Mods) {
    if (-not (Test-Path (Join-Path $Mod.FullName 'enabled.txt'))) {
        throw "$($Mod.Name) has no enabled.txt: players would get a mod that never starts"
    }

    $ZipPath = Join-Path $Dist "$($Mod.Name).zip"
    if (Test-Path $ZipPath) { Remove-Item -Force $ZipPath }

    # Entries use forward slashes: Compress-Archive in Windows PowerShell 5.1
    # writes backslashes, which some unzip tools reject.
    $Zip = [System.IO.Compression.ZipFile]::Open($ZipPath, 'Create')
    try {
        foreach ($File in Get-ChildItem -Recurse -File $Mod.FullName) {
            $Relative = $File.FullName.Substring($Mod.Parent.FullName.Length + 1) -replace '\\', '/'
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Zip, $File.FullName, $Relative) | Out-Null
        }
    } finally {
        $Zip.Dispose()
    }
    Write-Output "Built $ZipPath"
}
