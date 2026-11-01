# Builds dist\AnvilMods-Pack.zip: the official UE4SS loader with every mod of
# this repository and nothing else, ready to extract into the game's Win64
# folder. Only the files listed here come from the UE4SS zip: its cheat,
# console and dump mods (some enabled by default) are left out on purpose.

param(
    [string]$UE4SSZip = (Join-Path $env:USERPROFILE 'Downloads\UE4SS_v3.0.1-1181-g83330635.zip')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$Kept = @(
    'dwmapi.dll'
    'ue4ss/LICENSE'
    'ue4ss/UE4SS.dll'
    'ue4ss/UE4SS-settings.ini'
    'ue4ss/Mods/shared/UEHelpers/UEHelpers.lua'
)

$Dist = Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Force $Dist | Out-Null
$PackPath = Join-Path $Dist 'AnvilMods-Pack.zip'
if (Test-Path $PackPath) { Remove-Item -Force $PackPath }

$Source = [System.IO.Compression.ZipFile]::OpenRead($UE4SSZip)
$Pack = [System.IO.Compression.ZipFile]::Open($PackPath, 'Create')
try {
    foreach ($Name in $Kept) {
        $Entry = $Source.GetEntry($Name)
        if (-not $Entry) { throw "$Name is not in $UE4SSZip" }

        if ($Name -eq 'ue4ss/UE4SS-settings.ini') {
            $Reader = New-Object System.IO.StreamReader $Entry.Open()
            $Settings = $Reader.ReadToEnd()
            $Reader.Dispose()
            if ($Settings -notmatch '(?m)^GuiConsoleEnabled = 0') {
                throw 'This UE4SS opens its debug window by default: fix the settings before packing'
            }
        }

        $In = $Entry.Open()
        $Out = $Pack.CreateEntry($Name).Open()
        $In.CopyTo($Out)
        $Out.Dispose()
        $In.Dispose()
    }

    $Mods = Get-ChildItem -Directory $PSScriptRoot | Where-Object { Test-Path (Join-Path $_.FullName 'Scripts\main.lua') }
    foreach ($Mod in $Mods) {
        if (-not (Test-Path (Join-Path $Mod.FullName 'enabled.txt'))) {
            throw "$($Mod.Name) has no enabled.txt: players would get a mod that never starts"
        }
        foreach ($File in Get-ChildItem -Recurse -File $Mod.FullName) {
            $Relative = $File.FullName.Substring($Mod.Parent.FullName.Length + 1).Replace('\', '/')
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Pack, $File.FullName, "ue4ss/Mods/$Relative") | Out-Null
        }
    }
} finally {
    $Pack.Dispose()
    $Source.Dispose()
}
Write-Output "Built $PackPath"
