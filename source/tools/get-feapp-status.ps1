param(
    [Parameter(Mandatory = $true)][string]$FeappPath
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (-not (Test-Path -LiteralPath $FeappPath)) {
    [ordered]@{ clientFound = $false; mounted = $false; port = $null } | ConvertTo-Json -Compress
    exit 0
}

$stream = [IO.File]::OpenRead($FeappPath)
$archive = New-Object -TypeName IO.Compression.ZipArchive -ArgumentList @(
    $stream,
    [IO.Compression.ZipArchiveMode]::Read,
    $false
)
try {
    $entries = @($archive.Entries | Where-Object { $_.FullName -match '^assets/main-[^/]+\.js$' })
    if ($entries.Count -ne 1) { throw "expected one main-*.js, got $($entries.Count)" }
    $reader = New-Object IO.StreamReader($entries[0].Open(), (New-Object System.Text.UTF8Encoding $false))
    try { $text = $reader.ReadToEnd() }
    finally { $reader.Dispose() }
}
finally {
    $archive.Dispose()
    $stream.Dispose()
}

$endpoints = @(
    "/signIn",
    "/getUserInfo",
    "/letter/send",
    "/letter/list",
    "/letter/detail",
    "/letter/unread_count",
    "/letter/share",
    "/letter/resend",
    "/addToPlaylist",
    "/delFromPlaylist",
    "/searchPlaylist"
)
$ports = New-Object System.Collections.Generic.List[int]
$complete = $true
foreach ($endpoint in $endpoints) {
    $pattern = 'http://127\.0\.0\.1:(\d+)/toy' + [regex]::Escape($endpoint)
    $matches = @([regex]::Matches($text, $pattern))
    if ($matches.Count -ne 1) {
        $complete = $false
        continue
    }
    $ports.Add([int]$matches[0].Groups[1].Value)
}
$uniquePorts = @($ports | Select-Object -Unique)
$patchMarkers = @(
    '/*OliviaSoulPatch:mail-music-v19*/'
)
$mounted = $complete -and $uniquePorts.Count -eq 1 -and @($patchMarkers | Where-Object { $text.StartsWith($_) }).Count -eq 1
$port = $null
if ($mounted) { $port = $uniquePorts[0] }
[ordered]@{ clientFound = $true; mounted = $mounted; port = $port } | ConvertTo-Json -Compress
