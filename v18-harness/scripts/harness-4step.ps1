# Harness: safe -> draft -> check -> rewrite
# Prompts live in harness/. PowerShell 5.x.
#   powershell -NoProfile -File .cursor/skills/fit-letters/scripts/harness-4step.ps1 -Person X -N 33 -Root "..."

param(
    [Parameter(Mandatory = $true)][string]$Person,
    [Parameter(Mandatory = $true)][int]$N,
    [string]$Root = "",
    [string]$RulesFile = "",
    [string]$HarnessDir = "",
    [string]$Tag = "",
    [string]$Model = "",
    [string]$ReuseSafeTag = "",
    [string]$ArchivePath = "",
    [string]$OutFile = "",
    [string]$DraftFile = "",
    [string]$PrecheckFile = "",
    [string]$PreviousStateTag = "",
    [string]$PreviousReplyOverrideFile = "",
    [switch]$NoThink,
    [switch]$InitializeState,
    [switch]$AllowStateBootstrap,
    [switch]$StopAfterSafe,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = (Get-Location).Path }
. (Join-Path $PSScriptRoot "memory-lib.ps1")
Initialize-Ds -Root $Root
if (-not [string]::IsNullOrWhiteSpace($Model)) { Set-DsModel -Model $Model }
if ($NoThink) { Set-DsThinking -On $false }
$sw = [Diagnostics.Stopwatch]::StartNew()
function Say([string]$m) {
    if ($Quiet) { Write-Output $m }
    else { Write-Output $m }
}
function Lap([string]$step) {
    if (-not $Quiet) { Write-Output ("{0} {1}s" -f $step, [int]$sw.Elapsed.TotalSeconds) }
}

$nn = "{0:D2}" -f $N
$probe = Join-Path $Root "_probe"
if (-not (Test-Path -LiteralPath $probe)) { New-Item -ItemType Directory -Path $probe | Out-Null }
$suffix = ""
if (-not [string]::IsNullOrWhiteSpace($Tag)) { $suffix = "_" + $Tag }
function Save-Step([string]$step, [string]$text) {
    $p = Join-Path $probe ("h4_{0}_{1}{2}_{3}.txt" -f $Person, $nn, $suffix, $step)
    Write-Utf8 $p $text
    if ($step -eq "5final" -and -not [string]::IsNullOrWhiteSpace($OutFile)) { Write-Utf8 $OutFile $text }
    if (-not $Quiet) { Write-Output ("wrote " + $p) }
}

if ([string]::IsNullOrWhiteSpace($HarnessDir)) { $HarnessDir = Join-Path $Root "harness" }
if (-not [IO.Path]::IsPathRooted($HarnessDir)) { $HarnessDir = Join-Path $Root $HarnessDir }

function Expand-Harness([string]$text, [hashtable]$map) {
    $out = $text
    foreach ($k in $map.Keys) {
        $out = $out.Replace(("{{" + $k + "}}"), [string]$map[$k])
    }
    return $out
}

function Get-HarnessPrompt([string]$fileName) {
    $path = Join-Path $HarnessDir $fileName
    if (-not (Test-Path -LiteralPath $path)) { throw ("missing harness prompt: " + $path) }
    $raw = Read-Utf8 $path
    $sysMarker = "## System"
    $userMarker = "## User"
    $iSys = $raw.IndexOf($sysMarker)
    $iUser = $raw.IndexOf($userMarker)
    if ($iSys -lt 0 -or $iUser -lt 0 -or $iUser -le $iSys) {
        throw ("harness prompt need ## System and ## User: " + $path)
    }
    $sys = $raw.Substring($iSys + $sysMarker.Length, $iUser - $iSys - $sysMarker.Length).Trim()
    $user = $raw.Substring($iUser + $userMarker.Length).Trim()
    return @{ System = $sys; User = $user }
}

$writeHeading = "# " + (-join @([char]0x5199, [char]0x6CD5))
$personaHeading = "## " + (-join @([char]0x57FA, [char]0x7840))
if ([string]::IsNullOrWhiteSpace($RulesFile)) { $RulesFile = Join-Path $Root ".cursor\rules\linli-letters.mdc" }
if (-not [IO.Path]::IsPathRooted($RulesFile)) { $RulesFile = Join-Path $Root $RulesFile }
$personaPath = Join-Path $Root ((-join @([char]0x6797, [char]0x79BB, [char]0x4EBA, [char]0x8BBE)) + ".md")
$archDir = -join @([char]0x4FE1, [char]0x4EF6, [char]0x5F80, [char]0x6765)
$rules = Take-FromHeading (Strip-Yaml (Read-Utf8 $RulesFile)) $writeHeading
$persona = Take-FromHeading (Read-Utf8 $personaPath) $personaHeading
$fields = (Read-Utf8 (Join-Path $HarnessDir ("00-" + (-join @([char]0x680F, [char]0x76EE)) + ".md"))).Trim()

Write-Output ("STEP0 memory " + $Person + " " + $nn)
$arch = Join-Path $Root ("{0}\{1}.md" -f $archDir, $Person)
if (-not [string]::IsNullOrWhiteSpace($ArchivePath)) { $arch = $ArchivePath }
$openingPath = Join-Path $HarnessDir ((-join @([char]0x5F00, [char]0x4FE1)) + ".md")
if (-not (Test-Path -LiteralPath $openingPath)) { $openingPath = Join-Path $Root ("harness\" + (-join @([char]0x5F00, [char]0x4FE1)) + ".md") }
$ctx = Build-Memory -Root $Root -Person $Person -N $N -ArchivePath $arch -OpeningPath $openingPath
if (-not [string]::IsNullOrWhiteSpace($PreviousReplyOverrideFile)) {
    if ($N -lt 2) { throw "previous reply override requires N >= 2" }
    if (-not [IO.Path]::IsPathRooted($PreviousReplyOverrideFile)) { $PreviousReplyOverrideFile = Join-Path $Root $PreviousReplyOverrideFile }
    if (-not (Test-Path -LiteralPath $PreviousReplyOverrideFile)) { throw ("previous reply override not found: " + $PreviousReplyOverrideFile) }
    $overrideReply = (Read-Utf8 $PreviousReplyOverrideFile).Trim()
    $linliHeading = "#### " + (-join @([char]0x6797, [char]0x79BB))
    $targetHeading = "## " + (-join @([char]0x8981, [char]0x56DE, [char]0x7684, [char]0x6765, [char]0x4FE1))
    $replyHeadingStart = $ctx.LastIndexOf($linliHeading)
    $targetHeadingStart = $ctx.IndexOf($targetHeading, $replyHeadingStart)
    if ($replyHeadingStart -lt 0 -or $targetHeadingStart -lt 0) { throw "cannot locate previous reply in memory context" }
    $replyHeadingEnd = $ctx.IndexOf("`n", $replyHeadingStart)
    if ($replyHeadingEnd -lt 0 -or $replyHeadingEnd -ge $targetHeadingStart) { throw "cannot locate previous reply heading end" }
    $ctx = $ctx.Substring(0, $replyHeadingEnd + 1) + "`n" + $overrideReply + "`n`n" + $ctx.Substring($targetHeadingStart)
}

$relationshipLabel = -join @([char]0x4F60, [char]0x4EEC, [char]0x7684, [char]0x5173, [char]0x7CFB)
$progressLabel = -join @([char]0x4F60, [char]0x4EEC, [char]0x5173, [char]0x7CFB, [char]0x8FDB, [char]0x5C55, [char]0x7684, [char]0x5173, [char]0x952E, [char]0x70B9)
$relationshipMemoryLines = @(
    ($ctx -split "`r?`n") |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_.StartsWith($relationshipLabel) -or $_.StartsWith($progressLabel) }
)
$relationshipMemory = "无"
if ($relationshipMemoryLines.Count -gt 0) { $relationshipMemory = [string]::Join("`n", $relationshipMemoryLines) }

$stateBootstrapRequired = $InitializeState
$previousState = "无（未启用上一轮状态传递）"
if (-not [string]::IsNullOrWhiteSpace($PreviousStateTag)) {
    if ($N -eq 1) {
        $previousState = "无（首封，无上一轮状态）"
        $stateBootstrapRequired = $true
    }
    else {
        $previousNn = "{0:D2}" -f ($N - 1)
        $previousStatePath = Join-Path $probe ("h4_{0}_{1}_{2}_1safe.txt" -f $Person, $previousNn, $PreviousStateTag)
        if (-not (Test-Path -LiteralPath $previousStatePath)) {
            if (-not $AllowStateBootstrap) { throw ("missing previous state: " + $previousStatePath) }
            $previousState = "无（缺少前置账本；依据全部可见历史初始化）"
            $stateBootstrapRequired = $true
        }
        else {
            $previousSafeLines = @(
                ((Read-Utf8 $previousStatePath) -split "`r?`n") |
                    ForEach-Object { $_.Trim() } |
                    Where-Object { $_.Length -gt 0 }
            )
            $statePrefixes = @("关系　", "关系依据　", "已承认情感　", "既有亲密　", "既有边界　", "亲密上限　")
            $stateLines = @(
                $previousSafeLines |
                    Where-Object {
                        $line = $_
                        @($statePrefixes | Where-Object { $line.StartsWith($_) }).Count -gt 0
                    }
            )
            if ($stateLines.Count -lt 4) { throw ("invalid previous state: " + $previousStatePath) }
            $previousState = [string]::Join("`n", $stateLines)
        }
    }
}

# STEP1: safety gate (was writing card)
$precheckPrompt = "01-" + (-join @([char]0x9884, [char]0x68C0)) + ".md"
if ($stateBootstrapRequired) {
    $precheckPrompt = "01-" + (-join @([char]0x521D, [char]0x59CB, [char]0x5316, [char]0x8D26, [char]0x672C)) + ".md"
}
if (-not [string]::IsNullOrWhiteSpace($PrecheckFile)) { $precheckPrompt = $PrecheckFile }
$p1 = Get-HarnessPrompt $precheckPrompt
if ([string]::IsNullOrWhiteSpace($ReuseSafeTag)) {
    $map1 = @{ ctx = $ctx; rules = $rules; previousState = $previousState; relationshipMemory = $relationshipMemory }
    $sysSafe = Expand-Harness $p1.System $map1
    $userSafe = Expand-Harness $p1.User $map1
    Write-Output ("STEP1 safe " + $Person + " " + $nn)
    $safe = Invoke-Ds -System $sysSafe -User $userSafe
}
else {
    $reuseSafePath = Join-Path $probe ("h4_{0}_{1}_{2}_1safe.txt" -f $Person, $nn, $ReuseSafeTag)
    if (-not (Test-Path -LiteralPath $reuseSafePath)) { throw ("missing reused precheck: " + $reuseSafePath) }
    Write-Output ("STEP1 reuse-safe " + $Person + " " + $nn + " from=" + $ReuseSafeTag)
    $safe = Read-Utf8 $reuseSafePath
}
Save-Step "1safe" $safe
Lap "T1safe"

$expectedSafeLines = 8
if ($p1.System -match "九行") { $expectedSafeLines = 9 }
if ($p1.System -match "十三行") { $expectedSafeLines = 13 }
$safeLines = @(($safe -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
$fullWidthSpace = [string][char]0x3000
$conclusionWord = -join @([char]0x7ED3, [char]0x8BBA)
$allowedRelationships = @()
if ($expectedSafeLines -eq 13) {
    $relationshipWord = -join @([char]0x5173, [char]0x7CFB)
    $relationshipDefinition = @(
        ($p1.System -split "`r?`n") |
            Where-Object { $_.StartsWith($relationshipWord + $fullWidthSpace) }
    )[0]
    $allowedRelationships = @(
        $relationshipDefinition.Substring($relationshipDefinition.IndexOf($fullWidthSpace) + 1) -split ([string][char]0xFF0F)
    )
}
$invalidSafe = $safeLines.Count -ne $expectedSafeLines
if (-not $invalidSafe) {
    $invalidSafe = @($safeLines | Where-Object { $_.IndexOf($fullWidthSpace) -lt 1 }).Count -gt 0
}
if (-not $invalidSafe) { $invalidSafe = -not $safeLines[$expectedSafeLines - 1].StartsWith($conclusionWord) }
if ($safe -match "(?m)^\s*(#|---)") { $invalidSafe = $true }
if (-not $invalidSafe -and $expectedSafeLines -eq 13) {
    $relationshipValue = $safeLines[4].Substring($safeLines[4].IndexOf($fullWidthSpace) + 1).Trim()
    $invalidSafe = -not ($allowedRelationships -contains $relationshipValue)
}
if ($invalidSafe -and [string]::IsNullOrWhiteSpace($ReuseSafeTag)) {
    Write-Output ("STEP1 repair-format " + $Person + " " + $nn)
    $repairSystem = $p1.System + "`n`n上一版输出格式不合格。重新执行原任务，字段不可省略；只输出规定行数与规定字段，不要解释。"
    $repairUser = $userSafe + "`n`n格式不合格的上一版输出：`n" + $safe
    $safe = Invoke-Ds -System $repairSystem -User $repairUser
    Save-Step "1safe" $safe
    $safeLines = @(($safe -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
    $invalidSafe = $safeLines.Count -ne $expectedSafeLines
    if (-not $invalidSafe) {
        $invalidSafe = @($safeLines | Where-Object { $_.IndexOf($fullWidthSpace) -lt 1 }).Count -gt 0
    }
    if (-not $invalidSafe) { $invalidSafe = -not $safeLines[$expectedSafeLines - 1].StartsWith($conclusionWord) }
    if ($safe -match "(?m)^\s*(#|---)") { $invalidSafe = $true }
    if (-not $invalidSafe -and $expectedSafeLines -eq 13) {
        $relationshipValue = $safeLines[4].Substring($safeLines[4].IndexOf($fullWidthSpace) + 1).Trim()
        $invalidSafe = -not ($allowedRelationships -contains $relationshipValue)
    }
}
if ($invalidSafe) { throw "STEP1 precheck format invalid" }

if ($StopAfterSafe) {
    Write-Output ("HARNESS1 DONE {0} {1}{2} total={3}s" -f $Person, $nn, $suffix, [int]$sw.Elapsed.TotalSeconds)
    return
}

$blockWord = -join @([char]0x62E6, [char]0x622A)
if ($safe -match $blockWord) {
    Save-Step "5final" ("[BLOCKED]`n" + $safe)
    Write-Output ("STEP1 blocked " + $Person + " " + $nn)
    Write-Output ("HARNESS5 DONE {0} {1}{2} total={3}s blocked=1" -f $Person, $nn, $suffix, [int]$sw.Elapsed.TotalSeconds)
    return
}

if ([string]::IsNullOrWhiteSpace($DraftFile)) {
    $p3 = Get-HarnessPrompt ("03-" + (-join @([char]0x4E2D, [char]0x6BB5, [char]0x751F, [char]0x6210)) + ".md")
    $map3 = @{ fields = $fields; safe = $safe; rules = $rules; persona = $persona; ctx = $ctx }
    $sysDraft = Expand-Harness $p3.System $map3
    $userDraft = Expand-Harness $p3.User $map3
    Write-Output ("STEP3 draft " + $Person + " " + $nn)
    $draft = Invoke-Ds -System $sysDraft -User $userDraft
}
else {
    if (-not [IO.Path]::IsPathRooted($DraftFile)) { $DraftFile = Join-Path $Root $DraftFile }
    if (-not (Test-Path -LiteralPath $DraftFile)) { throw ("draft file not found: " + $DraftFile) }
    Write-Output ("STEP3 reuse-draft " + $Person + " " + $nn)
    $draft = Read-Utf8 $DraftFile
}
Save-Step "3draft" $draft
Lap "T3draft"

$p4 = Get-HarnessPrompt ("04-" + (-join @([char]0x5C3E, [char]0x7AEF, [char]0x68C0, [char]0x67E5)) + ".md")
$map4 = @{ fields = $fields; safe = $safe; persona = $persona; draft = $draft; ctx = $ctx }
$sysCheck = Expand-Harness $p4.System $map4
$userCheck = Expand-Harness $p4.User $map4
Write-Output ("STEP4 check " + $Person + " " + $nn)
$check = Invoke-Ds -System $sysCheck -User $userCheck
Save-Step "4check" $check
Lap "T4check"

$badWord = -join @([char]0x8FDD, [char]0x89C4)
$fullWidthSpace = [string][char]0x3000
$bad = @(
    foreach ($line in ($check -split "`n")) {
        $parts = @($line.Trim() -split [regex]::Escape($fullWidthSpace))
        if ($parts.Count -ge 2 -and $parts[1].Trim() -eq $badWord) { $line }
    }
)
if ($bad.Count -eq 0) {
    Save-Step "5final" $draft
    Write-Output ("STEP5 clean " + $Person + " " + $nn)
}
else {
    $check = [string]::Join("`n", $bad)
    $p5 = Get-HarnessPrompt ("05-" + (-join @([char]0x53CD, [char]0x9988, [char]0x91CD, [char]0x5199)) + ".md")
    $map5 = @{ fields = $fields; safe = $safe; check = $check; rules = $rules; persona = $persona; draft = $draft; ctx = $ctx }
    $sysFix = Expand-Harness $p5.System $map5
    $userFix = Expand-Harness $p5.User $map5
    Write-Output ("STEP5 rewrite " + $Person + " " + $nn)
    $final = Invoke-Ds -System $sysFix -User $userFix
    Save-Step "5final" $final
}

Write-Output ("HARNESS5 DONE {0} {1}{2} total={3}s" -f $Person, $nn, $suffix, [int]$sw.Elapsed.TotalSeconds)
