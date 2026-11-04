# Copies every mod of this repository (each folder with Scripts\main.lua)
# into the game's UE4SS Mods folder, the same way players install them.
# Run again after each change, then restart the game.
#
# Mods are enabled by the empty enabled.txt inside their folder, so
# mods.txt and mods.json are not needed: any old AvatarSort line there is
# removed so the mod is not listed twice.

$ErrorActionPreference = 'Stop'

$ModsDir = 'C:\Program Files (x86)\Steam\steamapps\common\Anvil Playtest\Anvil\Binaries\Win64\ue4ss\Mods'
if (-not (Test-Path $ModsDir)) { throw "UE4SS Mods folder not found: $ModsDir" }

# Turns on the mods' developer keys (probes, test bench) on this machine
# only: released zips and the pack never contain this file.
$DevMarker = Join-Path $ModsDir 'AnvilModsDev.txt'
if (-not (Test-Path $DevMarker)) {
    Set-Content -Path $DevMarker -Value 'Developer keys of the Anvil mods are on. Delete this file to turn them off.' -Encoding ascii
    Write-Output "Created $DevMarker"
}

$Mods = Get-ChildItem -Directory $PSScriptRoot | Where-Object { Test-Path (Join-Path $_.FullName 'Scripts\main.lua') }

foreach ($Mod in $Mods) {
    $Target = Join-Path $ModsDir $Mod.Name
    # The player's choices (NameColors, for example) live in the installed
    # folder only: keep them across installs.
    $SettingsPath = Join-Path $Target 'settings.txt'
    $Settings = if (Test-Path $SettingsPath) { [System.IO.File]::ReadAllBytes($SettingsPath) } else { $null }
    if (Test-Path $Target) { Remove-Item -Recurse -Force $Target }
    Copy-Item -Recurse $Mod.FullName $Target
    if ($Settings) { [System.IO.File]::WriteAllBytes($SettingsPath, $Settings) }
    Write-Output "Installed $($Mod.Name)$(if ($Settings) { ' (settings kept)' })"

    $ModsTxt = Join-Path $ModsDir 'mods.txt'
    $Lines = Get-Content $ModsTxt
    $Kept = $Lines | Where-Object { $_ -notmatch "^\s*$([regex]::Escape($Mod.Name))\s*:" }
    if ($Kept.Count -ne $Lines.Count) {
        Set-Content -Path $ModsTxt -Value $Kept -Encoding ascii
        Write-Output "  removed its line from mods.txt"
    }

    $ModsJson = Join-Path $ModsDir 'mods.json'
    if (Test-Path $ModsJson) {
        # ForEach-Object unrolls the array: Windows PowerShell 5.1 would
        # otherwise see the whole JSON array as a single entry.
        $Entries = @((Get-Content -Raw $ModsJson | ConvertFrom-Json) | ForEach-Object { $_ })
        $KeptEntries = @($Entries | Where-Object { $_.mod_name -ne $Mod.Name })
        if ($KeptEntries.Count -ne $Entries.Count) {
            # UTF-8 without BOM, as UE4SS wrote it.
            $Json = ConvertTo-Json -InputObject $KeptEntries -Depth 3
            [System.IO.File]::WriteAllText($ModsJson, $Json, (New-Object System.Text.UTF8Encoding $false))
            Write-Output "  removed its entry from mods.json"
        }
    }
}
