param(
    [Parameter(Mandatory = $true)][string]$GameRoot,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$OriginalFile
)

$ErrorActionPreference = "Stop"
$relative = "$Version\resources\feapp.dat"
$destination = Join-Path $GameRoot $relative
if (-not (Test-Path -LiteralPath $OriginalFile)) { throw "original feapp.dat not found" }
$gamePrefix = [IO.Path]::GetFullPath($GameRoot).TrimEnd("\") + "\"
Get-CimInstance Win32_Process |
    Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($gamePrefix, [StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep -Milliseconds 250
Copy-Item -LiteralPath $OriginalFile -Destination $destination -Force
$webplayerDestination = Join-Path $GameRoot "$Version\resources\webplayer.dat"
$webplayerBackup = Join-Path ([IO.Path]::GetDirectoryName($OriginalFile)) ("webplayer-" + $Version + ".dat")
if (Test-Path -LiteralPath $webplayerBackup) {
    Copy-Item -LiteralPath $webplayerBackup -Destination $webplayerDestination -Force
}
$nutBasePath = Join-Path $GameRoot "$Version\NutBase.dll"
$nutBackup = Join-Path ([IO.Path]::GetDirectoryName($OriginalFile)) ("NutBase-" + $Version + ".dll")
if (Test-Path -LiteralPath $nutBackup) {
    Copy-Item -LiteralPath $nutBackup -Destination $nutBasePath -Force
}
$studioUiPath = Join-Path $GameRoot "$Version\plugins\Studio\NutStudioUI.dll"
$studioBackup = Join-Path ([IO.Path]::GetDirectoryName($OriginalFile)) ("NutStudioUI-" + $Version + ".dll")
if ((Test-Path -LiteralPath $studioBackup) -and (Test-Path -LiteralPath $studioUiPath)) {
    Copy-Item -LiteralPath $studioBackup -Destination $studioUiPath -Force
}
$containerPluginPath = Join-Path $GameRoot "$Version\plugins\Container\NutContainerPlugin.dll"
$containerPluginBackup = Join-Path ([IO.Path]::GetDirectoryName($OriginalFile)) ("NutContainerPlugin-" + $Version + ".dll")
if ((Test-Path -LiteralPath $containerPluginBackup) -and (Test-Path -LiteralPath $containerPluginPath)) {
    Copy-Item -LiteralPath $containerPluginBackup -Destination $containerPluginPath -Force
}
$userSettingsPath = Join-Path $env:APPDATA "miHoYo\Olivia-steam\store\usersettings.dat"
$settingsBackup = Join-Path ([IO.Path]::GetDirectoryName($OriginalFile)) ("usersettings-" + $Version + ".dat")
if ((Test-Path -LiteralPath $settingsBackup) -and (Test-Path -LiteralPath $userSettingsPath)) {
    Copy-Item -LiteralPath $settingsBackup -Destination $userSettingsPath -Force
}
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash
Write-Output "restored=$destination"
Write-Output "sha256=$hash"
if (Test-Path -LiteralPath $webplayerDestination) {
    Write-Output "webplayer=$webplayerDestination"
    Write-Output "webplayerSha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $webplayerDestination).Hash)"
}
if (Test-Path -LiteralPath $studioUiPath) {
    Write-Output "studioUi=$studioUiPath"
    Write-Output "studioUiSha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $studioUiPath).Hash)"
}
if (Test-Path -LiteralPath $containerPluginPath) {
    Write-Output "containerPlugin=$containerPluginPath"
    Write-Output "containerPluginSha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $containerPluginPath).Hash)"
}
