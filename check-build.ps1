# Checks a new game build against the last one the mods were checked with.
#
#   .\check-build.ps1           compare the game's class dump with the last
#                               checked one, list what changed and which
#                               mods it may touch
#   .\check-build.ps1 -Accept   once the mods are checked on this build,
#                               keep its dump as the new reference
#
# Before: start the game, go in game, press Ctrl+H (UE4SS dumps the class
# headers to ue4ss\CXXHeaderDump). The steps after this script are in
# docs\new-game-build.md. References live in Documents\ANVIL\dumps.

param([switch]$Accept)

$ErrorActionPreference = 'Stop'

$Game = 'C:\Program Files (x86)\Steam\steamapps\common\Anvil Playtest'
$Exe = Join-Path $Game 'Anvil\Binaries\Win64\Anvil-Win64-Shipping.exe'
$Dump = Join-Path $Game 'Anvil\Binaries\Win64\ue4ss\CXXHeaderDump'
$Manifest = 'C:\Program Files (x86)\Steam\steamapps\appmanifest_2383950.acf'
$Store = Join-Path (Split-Path $PSScriptRoot -Parent) 'dumps'
$Deps = Join-Path $PSScriptRoot 'docs\game-dependencies.md'

# The game's own modules first; the engine ones only matter for the types
# the mods use.
$GameFiles = 'Anvil.hpp', 'Anvil_enums.hpp', 'R2.hpp', 'R2_enums.hpp'
$EngineFiles = 'UMG.hpp', 'Engine.hpp'
$Files = $GameFiles + $EngineFiles

$Build = '?'
if (Test-Path $Manifest) {
    $Line = Select-String -Path $Manifest -Pattern '"buildid"\s+"(\d+)"' | Select-Object -First 1
    if ($Line) { $Build = $Line.Matches[0].Groups[1].Value }
}

foreach ($File in $Files) {
    if (-not (Test-Path (Join-Path $Dump $File))) { throw "No $File in $Dump : dump the headers in game first (Ctrl+H)" }
}
$DumpTime = (Get-Item (Join-Path $Dump 'Anvil.hpp')).LastWriteTime
$ExeTime = (Get-Item $Exe).LastWriteTime
if ($DumpTime -lt $ExeTime) {
    throw "The dump ($DumpTime) is older than the game ($ExeTime): start the game, go in game and press Ctrl+H first"
}
Write-Output "Game build $Build, exe of $ExeTime, dump of $DumpTime"

# Types of one header: name -> @{ Kind; Base; Size; Members = name -> line }.
function Read-Header($Path) {
    $Types = @{}
    $Current = $null
    foreach ($Raw in [System.IO.File]::ReadAllLines($Path)) {
        if ($null -eq $Current) {
            if ($Raw -match '^(class|struct)\s+(\w+)(?:\s*:\s*public\s+(\w+))?\s*$') {
                $Current = @{ Kind = $Matches[1]; Base = $Matches[3]; Size = ''; Members = [ordered]@{} }
                $Types[$Matches[2]] = $Current
            } elseif ($Raw -match '^enum class (\w+)') {
                $Current = @{ Kind = 'enum'; Base = ''; Size = ''; Members = [ordered]@{} }
                $Types[$Matches[1]] = $Current
            }
            continue
        }
        if ($Raw -match '^\};\s*(?://\s*Size:\s*(\S+))?') {
            $Current.Size = $Matches[1]
            $Current = $null
            continue
        }
        $Text = ($Raw.Trim() -replace '\s+', ' ')
        if ($Text -eq '' -or $Text -eq '{') { continue }
        $Name = $null
        if ($Text -match '^(\w+)\s*=\s*-?\d+,?$') { $Name = $Matches[1] }              # enum value
        elseif ($Text -match '\s(\w+)\(') { $Name = $Matches[1] + '()' }                # function
        elseif ($Text -match '(\w+)(?:\[\w+\])?;') { $Name = $Matches[1] }              # property
        if ($Name) { $Current.Members[$Name] = $Text }
    }
    return $Types
}

if (-not (Test-Path $Store)) { New-Item -ItemType Directory $Store | Out-Null }
$Reference = Get-ChildItem -Directory $Store | Sort-Object Name | Select-Object -Last 1

function Save-Reference {
    $Target = Join-Path $Store ("{0}_build{1}" -f (Get-Date -Format 'yyyy-MM-dd'), $Build)
    if (-not (Test-Path $Target)) { New-Item -ItemType Directory $Target | Out-Null }
    foreach ($File in $Files) { Copy-Item (Join-Path $Dump $File) $Target -Force }
    Write-Output "Kept this dump as the reference: $Target"
}

if (-not $Reference) {
    if ($Accept) { Save-Reference } else { Write-Output 'No reference dump yet: check the mods on this build, then run .\check-build.ps1 -Accept' }
    return
}
Write-Output "Reference: $($Reference.Name)"
if ($Accept) { Save-Reference; return }

# Every word in the mods' Lua code, to see which mod names a changed member.
$ModWords = @{}
foreach ($Lua in Get-ChildItem -Path $PSScriptRoot -Recurse -Filter '*.lua' | Where-Object { $_.FullName -match '\\Scripts\\' }) {
    $Mod = ($Lua.FullName.Substring($PSScriptRoot.Length + 1) -split '\\')[0]
    foreach ($Match in [regex]::Matches([System.IO.File]::ReadAllText($Lua.FullName), '[A-Za-z_][A-Za-z0-9_]*')) {
        $Word = $Match.Value
        if (-not $ModWords.ContainsKey($Word)) { $ModWords[$Word] = New-Object System.Collections.Generic.HashSet[string] }
        [void]$ModWords[$Word].Add($Mod)
    }
}
function Get-Users($Word) {
    $Word = $Word -replace '\(\)$', ''
    if ($ModWords.ContainsKey($Word)) { return (@($ModWords[$Word]) | Sort-Object) -join ', ' }
    return ''
}
# A class is named in Lua without its U/A/F/E prefix (FindAllOf("BountyWidget")).
function Get-TypeUsers($Type) {
    $Users = @(Get-Users $Type) + @(Get-Users ($Type -replace '^[UAFE](?=[A-Z])', '')) | Where-Object { $_ }
    return (($Users -join ', ') -split ', ' | Where-Object { $_ } | Sort-Object -Unique) -join ', '
}

# The dependency table: Class -> list of "Mod: what it relies on".
$Rows = @{}
if (Test-Path $Deps) {
    foreach ($Line in [System.IO.File]::ReadAllLines($Deps)) {
        if ($Line -match '^\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*(.+?)\s*\|\s*$' -and $Matches[1] -ne 'Mod' -and $Matches[1] -notmatch '^-+$') {
            $Class = $Matches[2]
            if (-not $Rows.ContainsKey($Class)) { $Rows[$Class] = @() }
            $Rows[$Class] += "$($Matches[1]): $($Matches[3])"
        }
    }
}

$Changed = @()   # types that changed or went away
$Report = @()
foreach ($File in $Files) {
    $Old = Read-Header (Join-Path $Reference.FullName $File)
    $New = Read-Header (Join-Path $Dump $File)
    $IsGame = $GameFiles -contains $File
    foreach ($Name in ($Old.Keys + $New.Keys | Sort-Object -Unique)) {
        $Users = Get-TypeUsers $Name
        # Engine types: only those the mods use or the table lists.
        if (-not $IsGame -and -not $Users -and -not $Rows.ContainsKey($Name)) { continue }
        $A = $Old[$Name]
        $B = $New[$Name]
        if (-not $B) { $Changed += $Name; $Report += "  REMOVED $Name$(if ($Users) { "   (named by $Users)" })"; continue }
        if (-not $A) { if ($IsGame) { $Report += "  new $Name" }; continue }
        $Lines = @()
        if ($A.Base -ne $B.Base) { $Lines += "    base: $($A.Base) -> $($B.Base)" }
        if ($A.Size -ne $B.Size) { $Lines += "    size: $($A.Size) -> $($B.Size)" }
        foreach ($Member in ($A.Members.Keys + $B.Members.Keys | Sort-Object -Unique)) {
            $X = $A.Members[$Member]
            $Y = $B.Members[$Member]
            if ($X -eq $Y) { continue }
            $MemberUsers = Get-Users $Member
            $Note = if ($MemberUsers) { "   << named by $MemberUsers" } else { '' }
            if (-not $Y) { $Lines += "    - $X$Note" }
            elseif (-not $X) { $Lines += "    + $Y" }
            else { $Lines += "    ~ $X  ->  $Y$Note" }
        }
        if ($Lines.Count -gt 0) {
            $Changed += $Name
            $Report += "  changed $Name ($File)$(if ($Users) { "   (named by $Users)" })"
            $Report += $Lines
        }
    }
}

Write-Output ''
if ($Report.Count -eq 0) {
    Write-Output 'No change in the game classes, enums or the engine types the mods use.'
} else {
    Write-Output 'Changes in the class dump:'
    $Report | ForEach-Object { Write-Output $_ }
}

Write-Output ''
$Hits = @($Changed | Where-Object { $Rows.ContainsKey($_) } | Sort-Object -Unique)
if ($Hits.Count -eq 0) {
    Write-Output 'No changed class is in docs\game-dependencies.md.'
} else {
    Write-Output 'CHECK these dependencies (docs\game-dependencies.md), the classes they rely on changed:'
    foreach ($Class in $Hits) {
        foreach ($Row in $Rows[$Class]) { Write-Output "  [$Class] $Row" }
    }
}
Write-Output ''
Write-Output 'Rows with no class (files, engine behaviour) are not checked here: see docs\new-game-build.md.'
Write-Output 'Then run the quick tests of docs\new-game-build.md and, when all is fine: .\check-build.ps1 -Accept'
