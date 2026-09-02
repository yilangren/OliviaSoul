param(
    [string]$OutputDirectory = "",
    [string]$DotNet = "",
    [string]$Iscc = ""
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$project = Split-Path $PSScriptRoot -Parent
$repository = Split-Path $project -Parent
$utf8NoBom = New-Object Text.UTF8Encoding $false

$version = "2008.2.7"
$packagePath = Join-Path $project "package.json"
$packageText = [IO.File]::ReadAllText($packagePath, $utf8NoBom)
$package = $packageText | ConvertFrom-Json
if ([string]$package.version -ne $version) { throw "package.json 版本必须固定为林离生日 $version" }

$lockPath = Join-Path $project "package-lock.json"
$lockText = [IO.File]::ReadAllText($lockPath, $utf8NoBom)
$lockVersionCount = ([regex]::Matches($lockText, [regex]::Escape('"version": "' + $version + '"'))).Count
if ($lockVersionCount -ne 2) { throw "package-lock.json 必须有两处固定生日版本 $version" }

$nativeProjectPath = Join-Path $project "native-host\OliviaSoul.csproj"
$nativeProjectText = [IO.File]::ReadAllText($nativeProjectPath, $utf8NoBom)
foreach ($token in @(
    "<Version>$version</Version>",
    "<AssemblyVersion>$version.0</AssemblyVersion>",
    "<FileVersion>$version.0</FileVersion>"
)) {
    if (-not $nativeProjectText.Contains($token)) { throw "原生程序版本必须固定为林离生日 $version" }
}
Write-Output "Olivia Soul version: $version (fixed)"
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $repository "build" }
$stage = Join-Path $project "dist-native\stage"
$downloadCache = Join-Path $env:LOCALAPPDATA "OliviaSoulBuildTools\downloads"
$nodeVersion = "22.22.0"
$nodeArchiveName = "node-v$nodeVersion-win-x64.zip"
$nodeArchive = Join-Path $downloadCache $nodeArchiveName
$nodeUrl = "https://nodejs.org/dist/v$nodeVersion/$nodeArchiveName"
$nodeChecksums = Join-Path $downloadCache "node-v$nodeVersion-SHASUMS256.txt"
$webViewBootstrapper = Join-Path $downloadCache "MicrosoftEdgeWebview2Setup.exe"
$webViewUrl = "https://go.microsoft.com/fwlink/p/?LinkId=2124703"
$whisperVersion = "v1.9.2"
$whisperArchiveName = "whisper-bin-x64.zip"
$whisperArchive = Join-Path $downloadCache "$whisperVersion-$whisperArchiveName"
$whisperUrl = "https://github.com/ggml-org/whisper.cpp/releases/download/$whisperVersion/$whisperArchiveName"
$whisperSha256 = "49dcc16de826f20bd53d44f947a1ae49dfa81f86cad67a64d80820cb192d674a"
$whisperModel = Join-Path $downloadCache "ggml-small.bin"
$whisperModelUrls = @(
    "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-small.bin",
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
)
$whisperModelSha256 = "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"
$ffmpegRelease = "autobuild-2026-08-25-13-06"
$ffmpegArchiveName = "ffmpeg-n9.0.1-6-g9d4ca21220-win64-lgpl-9.0.zip"
$ffmpegArchive = Join-Path $downloadCache $ffmpegArchiveName
$ffmpegUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/download/$ffmpegRelease/$ffmpegArchiveName"
$ffmpegSha256 = "2a78472df18a88405bfd2cbbce729ff0179bae4b0a13afc43f26d409eb822496"

function Ensure-Directory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path | Out-Null }
}

function Copy-PublicFile([string]$Source, [string]$Destination) {
    $parent = Split-Path $Destination -Parent
    Ensure-Directory $parent
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Copy-Item -LiteralPath $Source -Destination $Destination -Force
            return
        }
        catch {
            if ($attempt -eq 5) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Download-PinnedFile([string]$Url, [string]$Path) {
    $urls = @($Url, "https://ghfast.top/$Url", "https://gh-proxy.com/$Url")
    foreach ($candidate in $urls) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $candidate -OutFile $Path
            return
        } catch {
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        }
    }
    throw "固定依赖下载失败：$Url"
}

Ensure-Directory $downloadCache

if ([string]::IsNullOrWhiteSpace($DotNet)) {
    $localDotNet = Join-Path $env:LOCALAPPDATA "OliviaSoulBuildTools\dotnet\dotnet.exe"
    if (Test-Path -LiteralPath $localDotNet) { $DotNet = $localDotNet }
    else { $DotNet = (Get-Command dotnet.exe -ErrorAction Stop).Source }
}

$builtHost = Join-Path $project "native-host\bin\Release\net462\OliviaSoul.exe"
$runningHost = Get-Process OliviaSoul -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $builtHost }
if ($runningHost) {
    if (Test-Path -LiteralPath $builtHost) {
        Start-Process -FilePath $builtHost -ArgumentList "--quit" -Wait
        Start-Sleep -Milliseconds 500
    }
}

& $DotNet build (Join-Path $project "native-host\OliviaSoul.csproj") -c Release
if ($LASTEXITCODE -ne 0) { throw "原生宿主编译失败" }

if (-not (Test-Path -LiteralPath $nodeArchive)) {
    Invoke-WebRequest -UseBasicParsing -Uri $nodeUrl -OutFile $nodeArchive
}
if (-not (Test-Path -LiteralPath $nodeChecksums)) {
    Invoke-WebRequest -UseBasicParsing -Uri "https://nodejs.org/dist/v$nodeVersion/SHASUMS256.txt" -OutFile $nodeChecksums
}
$checksumLine = Get-Content -LiteralPath $nodeChecksums | Where-Object { $_ -match [regex]::Escape($nodeArchiveName) + '$' } | Select-Object -First 1
if (-not $checksumLine) { throw "未找到 Node.js 官方校验值" }
$expectedHash = ($checksumLine -split '\s+')[0].ToLowerInvariant()
$actualHash = (Get-FileHash -LiteralPath $nodeArchive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -ne $expectedHash) { throw "Node.js 下载包 SHA-256 校验失败" }

if (-not (Test-Path -LiteralPath $webViewBootstrapper)) {
    Invoke-WebRequest -UseBasicParsing -Uri $webViewUrl -OutFile $webViewBootstrapper
}
if (-not (Test-Path -LiteralPath $whisperArchive)) {
    Download-PinnedFile $whisperUrl $whisperArchive
}
if ((Get-FileHash -LiteralPath $whisperArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $whisperSha256) {
    throw "whisper.cpp 下载包 SHA-256 校验失败"
}
if (-not (Test-Path -LiteralPath $whisperModel)) {
    $installedModel = Join-Path $env:APPDATA "OliviaSoul\models\whisper\ggml-small.bin"
    if ((Test-Path -LiteralPath $installedModel) -and
        (Get-FileHash -LiteralPath $installedModel -Algorithm SHA256).Hash.ToLowerInvariant() -eq $whisperModelSha256) {
        Copy-Item -LiteralPath $installedModel -Destination $whisperModel
    }
    else {
        foreach ($url in $whisperModelUrls) {
            try {
                Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $whisperModel
                break
            }
            catch {
                Remove-Item -LiteralPath $whisperModel -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
if (-not (Test-Path -LiteralPath $whisperModel) -or
    (Get-FileHash -LiteralPath $whisperModel -Algorithm SHA256).Hash.ToLowerInvariant() -ne $whisperModelSha256) {
    throw "Whisper 模型 SHA-256 校验失败"
}
if (-not (Test-Path -LiteralPath $ffmpegArchive)) {
    Download-PinnedFile $ffmpegUrl $ffmpegArchive
}
$ffmpegActualHash = (Get-FileHash -LiteralPath $ffmpegArchive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ffmpegActualHash -ne $ffmpegSha256) { throw "FFmpeg 下载包 SHA-256 校验失败" }

Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
Ensure-Directory $stage

$nativeOutput = Join-Path $project "native-host\bin\Release\net462"
Get-ChildItem -LiteralPath $nativeOutput -File | Where-Object {
    $_.Extension -in @(".exe", ".dll", ".config")
} | Copy-Item -Destination $stage -Force
Copy-Item -LiteralPath (Join-Path $nativeOutput "runtimes") -Destination (Join-Path $stage "runtimes") -Recurse -Force
Copy-PublicFile (Join-Path $PSScriptRoot "app.ico") (Join-Path $stage "app.ico")
Copy-PublicFile (Join-Path $PSScriptRoot "app.ico") (Join-Path $stage "app-v9.ico")
Copy-PublicFile $webViewBootstrapper (Join-Path $stage "redist\MicrosoftEdgeWebview2Setup.exe")

$nodeExtract = Join-Path $project "dist-native\node"
Remove-Item -LiteralPath $nodeExtract -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -LiteralPath $nodeArchive -DestinationPath $nodeExtract -Force
$nodeRoot = Join-Path $nodeExtract "node-v$nodeVersion-win-x64"
Copy-PublicFile (Join-Path $nodeRoot "node.exe") (Join-Path $stage "runtime\node.exe")
Copy-PublicFile (Join-Path $nodeRoot "LICENSE") (Join-Path $stage "runtime\NODE-LICENSE.txt")

$whisperExtract = Join-Path $project "dist-native\whisper"
Remove-Item -LiteralPath $whisperExtract -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -LiteralPath $whisperArchive -DestinationPath $whisperExtract -Force
$whisperCli = Get-ChildItem -LiteralPath $whisperExtract -Filter "whisper-cli.exe" -File -Recurse | Select-Object -First 1
if (-not $whisperCli) { throw "whisper.cpp 下载包结构不正确" }
$whisperRuntime = Split-Path $whisperCli.FullName -Parent
Ensure-Directory (Join-Path $stage "runtime\whisper")
Copy-Item -Path (Join-Path $whisperRuntime "*") -Destination (Join-Path $stage "runtime\whisper") -Recurse -Force
Copy-PublicFile (Join-Path $project "packaging\WHISPER-CPP-LICENSE.txt") (Join-Path $stage "runtime\whisper\LICENSE.txt")
Copy-PublicFile $whisperModel (Join-Path $stage "runtime\whisper\ggml-small.bin")

$ffmpegExtract = Join-Path $project "dist-native\ffmpeg"
Remove-Item -LiteralPath $ffmpegExtract -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -LiteralPath $ffmpegArchive -DestinationPath $ffmpegExtract -Force
$ffmpegRoot = Get-ChildItem -LiteralPath $ffmpegExtract -Directory | Select-Object -First 1
if (-not $ffmpegRoot) { throw "FFmpeg 下载包结构不正确" }
Copy-PublicFile (Join-Path $ffmpegRoot.FullName "bin\ffmpeg.exe") (Join-Path $stage "runtime\ffmpeg\bin\ffmpeg.exe")
Copy-PublicFile (Join-Path $ffmpegRoot.FullName "LICENSE.txt") (Join-Path $stage "runtime\ffmpeg\LICENSE.txt")

foreach ($name in @("server.js", "transcription.js", "remote-memory.js", "soul-bundle.js")) {
    Copy-PublicFile (Join-Path $project $name) (Join-Path $stage "app\$name")
}
Copy-PublicFile (Join-Path $project "package.json") (Join-Path $stage "app\package.json")
Copy-Item -LiteralPath (Join-Path $project "node_modules") -Destination (Join-Path $stage "app\node_modules") -Recurse -Force
Copy-Item -LiteralPath (Join-Path $project "public") -Destination (Join-Path $stage "app\public") -Recurse -Force
foreach ($name in @("controller.js", "node-host.js", "startup-task.ps1")) {
    Copy-PublicFile (Join-Path $project "desktop\$name") (Join-Path $stage "app\desktop\$name")
}

$scriptTarget = Join-Path $stage "resources\workspace-template\.cursor\skills\fit-letters\scripts"
foreach ($name in @("deepseek-reply.ps1", "harness-live.ps1", "harness-4step.ps1", "refresh-live-memory.ps1", "memory-lib.ps1", "ds-call.ps1", "score-temp.ps1", "sqlite-memory-load.cjs")) {
    Copy-PublicFile (Join-Path $repository ".cursor\skills\fit-letters\scripts\$name") (Join-Path $scriptTarget $name)
}
Copy-PublicFile (Join-Path $repository "林离人设.md") (Join-Path $stage "resources\workspace-template\林离人设.md")
foreach ($name in @("VERSION", "00-栏目.md", "01-预检.md", "01-初始化账本.md", "03-中段生成.md", "04-尾端检查.md", "05-反馈重写.md", "开信.md", "写法.md")) {
    Copy-PublicFile (Join-Path $repository "harness\$name") (Join-Path $stage "resources\workspace-template\harness\$name")
}
foreach ($name in @("patch-feapp-local.ps1", "restore-feapp-original.ps1", "get-feapp-status.ps1")) {
    Copy-PublicFile (Join-Path $repository "tools\$name") (Join-Path $stage "resources\workspace-template\tools\$name")
}

Remove-Item -LiteralPath $OutputDirectory -Recurse -Force -ErrorAction SilentlyContinue
Ensure-Directory $OutputDirectory
$portable = Join-Path $OutputDirectory "OliviaSoul-$version-Portable.zip"
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $portable -CompressionLevel Optimal
Copy-PublicFile (Join-Path $PSScriptRoot "使用说明.txt") (Join-Path $OutputDirectory "使用说明.txt")

if ([string]::IsNullOrWhiteSpace($Iscc)) {
    $candidates = @(@(
        $env:ISCC_PATH,
        (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) })
    if ($candidates.Count -lt 1) { throw "缺少 Inno Setup 6。安装后重新运行 npm run build:win。" }
    $Iscc = $candidates[0]
}

$env:OLIVIA_SOUL_VERSION = $version
$env:OLIVIA_SOUL_STAGE = $stage
$env:OLIVIA_SOUL_OUTPUT = $OutputDirectory
& $Iscc (Join-Path $PSScriptRoot "OliviaSoul.iss")
if ($LASTEXITCODE -ne 0) { throw "Inno Setup 打包失败" }

Write-Output "Olivia Soul release: $OutputDirectory"
