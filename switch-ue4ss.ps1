# Switches the game between the developer UE4SS (console, GUI, dumps, dev
# keys, test mods) and the player version (dist\AnvilMods-Pack.zip, exactly
# what players get).
#
#   .\switch-ue4ss.ps1 prod   park the dev install, extract the pack
#   .\switch-ue4ss.ps1 dev    remove the pack, bring the dev install back
#
# The parked dev install waits in Documents\ANVIL\ue4ss-dev-parked. Mod
# settings (settings.txt) follow from one install to the other. Run
# build-pack.ps1 first so the pack holds the current mods.

param(
    [Parameter(Mandatory)][ValidateSet('prod', 'dev')][string]$Mode
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$Win64 = 'C:\Program Files (x86)\Steam\steamapps\common\Anvil Playtest\Anvil\Binaries\Win64'
$Parked = Join-Path (Split-Path $PSScriptRoot -Parent) 'ue4ss-dev-parked'
$Pack = Join-Path $PSScriptRoot 'dist\AnvilMods-Pack.zip'
$Live = Join-Path $Win64 'ue4ss'

if (Get-Process -Name 'Anvil-Win64-Shipping' -ErrorAction SilentlyContinue) {
    throw 'The game is running: close it first'
}

function Get-Settings($ModsDir) {
    $Found = @{}
    if (Test-Path $ModsDir) {
        foreach ($Dir in Get-ChildItem -Directory $ModsDir) {
            $File = Join-Path $Dir.FullName 'settings.txt'
            if (Test-Path $File) { $Found[$Dir.Name] = [System.IO.File]::ReadAllBytes($File) }
        }
    }
    return $Found
}

function Set-Settings($ModsDir, $Settings) {
    foreach ($Name in $Settings.Keys) {
        $Dir = Join-Path $ModsDir $Name
        if (Test-Path $Dir) {
            [System.IO.File]::WriteAllBytes((Join-Path $Dir 'settings.txt'), $Settings[$Name])
            Write-Output "  settings of $Name kept"
        }
    }
}

$IsDev = Test-Path (Join-Path $Live 'Mods\AnvilModsDev.txt')

if ($Mode -eq 'prod') {
    if (-not (Test-Path $Pack)) { throw "No pack: run build-pack.ps1 first ($Pack)" }
    if (Test-Path $Live) {
        if (-not $IsDev) { throw 'The installed UE4SS is not the dev one (no AnvilModsDev.txt): already prod?' }
        if (Test-Path $Parked) { throw "$Parked already exists: switch back to dev first, or move it away" }
        $Settings = Get-Settings (Join-Path $Live 'Mods')
        New-Item -ItemType Directory $Parked | Out-Null
        Move-Item $Live (Join-Path $Parked 'ue4ss')
        Move-Item (Join-Path $Win64 'dwmapi.dll') (Join-Path $Parked 'dwmapi.dll')
        Write-Output "Dev UE4SS parked in $Parked"
    } else {
        $Settings = @{}
    }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Pack, $Win64)
    Set-Settings (Join-Path $Live 'Mods') $Settings
    Write-Output 'Player version installed (dev keys off, no console)'
} else {
    if (-not (Test-Path $Parked)) { throw "No parked dev install in $Parked" }
    if ($IsDev) { throw 'The installed UE4SS is already the dev one' }
    $Settings = Get-Settings (Join-Path $Live 'Mods')
    if (Test-Path $Live) { Remove-Item -Recurse -Force $Live }
    $Dll = Join-Path $Win64 'dwmapi.dll'
    if (Test-Path $Dll) { Remove-Item -Force $Dll }
    Move-Item (Join-Path $Parked 'ue4ss') $Live
    Move-Item (Join-Path $Parked 'dwmapi.dll') $Dll
    Remove-Item $Parked
    Set-Settings (Join-Path $Live 'Mods') $Settings
    Write-Output 'Dev UE4SS back in place'
}
