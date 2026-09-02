param(
    [Parameter(Mandatory = $true)][string]$Person,
    [Parameter(Mandatory = $true)][string]$Letter,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$RulesFile = "",
    [string]$Root = ""
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = (Get-Location).Path }
if ($Person -match '[<>:"/\\|?*\x00-\x1F]' -or $Person -eq "." -or $Person -eq "..") {
    throw "invalid person"
}

. (Join-Path $PSScriptRoot "memory-lib.ps1")
$letterText = (Read-Utf8 $Letter).Trim()
if ([string]::IsNullOrWhiteSpace($letterText)) { throw "letter is empty" }

$archiveDir = -join @([char]0x4FE1, [char]0x4EF6, [char]0x5F80, [char]0x6765)
$archive = Join-Path $Root ("{0}\{1}.md" -f $archiveDir, $Person)
$raw = ""
$prior = @()
if (Test-Path -LiteralPath $archive) {
    $raw = Read-Utf8 $archive
    $prior = @(Get-ArchiveExchanges -Path $archive)
}
if ([string]::IsNullOrWhiteSpace($raw)) {
    $memoryHeading = "## " + (-join @([char]0x8BB0, [char]0x5FC6))
    $raw = "# local archive - $Person`n`n$memoryHeading`n`n---"
}

$n = 1
if ($prior.Count -gt 0) { $n = [int](($prior | Measure-Object -Property N -Maximum).Maximum) + 1 }
$date = Get-Date -Format "yyyy-MM-dd"
$exchangeHeading = "### " + (-join @([char]0x5F80, [char]0x6765))
$incomingHeading = "#### " + (-join @([char]0x6211, [char]0xFF08, [char]0x4FE1, [char]0x4EF6, [char]0xFF09))
$pending = $raw.TrimEnd() + "`n`n## $date`n`n$exchangeHeading $('{0:D2}' -f $n)`n`n$incomingHeading`n`n$letterText"

$probe = Join-Path $Root "_probe"
if (-not (Test-Path -LiteralPath $probe)) { New-Item -ItemType Directory -Path $probe | Out-Null }
$temporaryArchive = Join-Path $probe ("live_input_{0}.md" -f [Guid]::NewGuid().ToString("N"))
Write-Utf8 $temporaryArchive $pending
try {
    $harness = Join-Path $PSScriptRoot "harness-4step.ps1"
    if ([string]::IsNullOrWhiteSpace($RulesFile)) {
        $rulesName = (-join @([char]0x5199, [char]0x6CD5)) + ".md"
        $RulesFile = Join-Path (Join-Path $Root "harness") $rulesName
    }
    & $harness -Person $Person -N $n -Root $Root -ArchivePath $temporaryArchive -OutFile $OutFile -RulesFile $RulesFile -Tag "live" -PreviousStateTag "live" -AllowStateBootstrap -Quiet
    if (-not (Test-Path -LiteralPath $OutFile)) { throw "harness did not produce a reply" }
    $reply = (Read-Utf8 $OutFile).Trim()
    if ($reply.StartsWith("[BLOCKED]")) { throw "reply was blocked by the safety gate" }
    if ([string]::IsNullOrWhiteSpace($reply)) { throw "harness returned an empty reply" }
}
finally {
    Remove-Item -LiteralPath $temporaryArchive -Force -ErrorAction SilentlyContinue
}
Write-Output "HARNESS LIVE DONE"
