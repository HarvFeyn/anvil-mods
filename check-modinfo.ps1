# Checks a mod folder before packing: modinfo.txt must exist (ModManager
# only lists mods that have one) and its version must match the Version
# at the top of Scripts\main.lua, which the mod writes to the log.

param([Parameter(Mandatory)][string]$ModPath)

$ErrorActionPreference = 'Stop'
$Name = Split-Path -Leaf $ModPath

$InfoPath = Join-Path $ModPath 'modinfo.txt'
if (-not (Test-Path $InfoPath)) {
    throw "$Name has no modinfo.txt: ModManager would not list it"
}
$Info = Get-Content $InfoPath | Where-Object { $_ -match '^\s*version\s*=' } | Select-Object -First 1
$InfoVersion = if ($Info) { ($Info -split '=', 2)[1].Trim() } else { $null }

$Code = Get-Content -Raw (Join-Path $ModPath 'Scripts\main.lua')
$CodeVersion = if ($Code -match 'local Version = "([^"]+)"') { $Matches[1] } else { $null }

if (-not $InfoVersion -or $InfoVersion -ne $CodeVersion) {
    throw "$Name version mismatch: modinfo.txt says '$InfoVersion', main.lua says '$CodeVersion'"
}
