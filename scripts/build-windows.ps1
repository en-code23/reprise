param([string]$Version = "1.6.1", [switch]$TestInstaller)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$publish = Join-Path $root 'build/windows/publish'
$qa = Join-Path $root 'build/windows/qa'
$output = Join-Path $root 'dist/windows'
$tools = Join-Path $root 'build/windows/tools'
$models = Join-Path $root 'windows/Reprise.Windows/tessdata'
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Use a numeric major.minor.patch version.' }
if (-not $IsWindows) { throw 'The Windows installer must be packaged on Windows.' }
if ($TestInstaller -and $env:CI -ne 'true') { throw 'Installer testing is restricted to clean CI runners.' }
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
New-Item -ItemType Directory -Force -Path $models, $publish, $qa, $output, $tools | Out-Null

# OCR stays offline at runtime. Pin the upstream English model and verify its bytes.
$model = Join-Path $models 'eng.traineddata'
Invoke-WebRequest 'https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/87416418657359cb625c412a48b6e1d6d41c29bd/eng.traineddata' -OutFile $model
if ((Get-FileHash $model -Algorithm SHA256).Hash -ne '7D4322BD2A7749724879683FC3912CB542F19906C83BCC1A52132556427170B2') { throw 'OCR language model checksum mismatch.' }

dotnet run --project "$root/windows/Reprise.Core.Tests" -c Release
if ($LASTEXITCODE -ne 0) { throw 'Windows core tests failed.' }
dotnet publish "$root/windows/Reprise.Windows/Reprise.Windows.csproj" -c Release -r win-x64 --self-contained true -p:Version=$Version -o $publish
if ($LASTEXITCODE -ne 0) { throw 'Windows app publish failed.' }

# App-local redistributable CRT files let the bundled Tesseract DLLs run without
# asking users to install a separate Visual C++ runtime.
$crt = Get-ChildItem -Path "$env:ProgramFiles/Microsoft Visual Studio/*/*/VC/Redist/MSVC/*/x64/Microsoft.VC*.CRT" -Directory -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1
if (-not $crt) { throw 'Visual Studio x64 redistributable CRT files were not found.' }
Copy-Item "$($crt.FullName)/*.dll" $publish -Force

$licenses = Join-Path $publish 'licenses'
New-Item -ItemType Directory -Force -Path $licenses | Out-Null
Copy-Item "$root/LICENSE" "$licenses/Reprise-LICENSE.txt"
Invoke-WebRequest 'https://raw.githubusercontent.com/velopack/velopack/1.2.161/LICENSE' -OutFile "$licenses/Velopack-LICENSE.txt"
Invoke-WebRequest 'https://raw.githubusercontent.com/charlesw/tesseract/master/LICENSE.txt' -OutFile "$licenses/Tesseract.NET-LICENSE.txt"
Invoke-WebRequest 'https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/87416418657359cb625c412a48b6e1d6d41c29bd/LICENSE' -OutFile "$licenses/Tesseract-model-LICENSE.txt"
Invoke-WebRequest 'https://raw.githubusercontent.com/DanBloomberg/leptonica/master/leptonica-license.txt' -OutFile "$licenses/Leptonica-LICENSE.txt"
Invoke-WebRequest 'https://visualstudio.microsoft.com/license-terms/vs2022-cruntime/' -OutFile "$licenses/Visual-C-Runtime-LICENSE.html"

$smoke = Start-Process "$publish/Reprise.exe" -ArgumentList @('--smoke-test', "`"$qa`"") -PassThru
if (-not $smoke.WaitForExit(120000)) { $smoke.Kill(); throw 'Windows UI/OCR smoke test timed out.' }
if ($smoke.ExitCode -ne 0 -or -not (Test-Path "$qa/smoke-result.txt")) {
    if (Test-Path "$qa/error.txt") { Get-Content "$qa/error.txt" | Write-Host }
    throw 'Windows UI/OCR smoke test failed.'
}
Get-Content "$qa/smoke-result.txt" | Write-Host

dotnet tool install vpk --version 1.2.161 --tool-path $tools --allow-roll-forward
if ($LASTEXITCODE -ne 0 -and -not (Test-Path "$tools/vpk.exe")) { throw 'Could not install the Windows packaging tool.' }
& "$tools/vpk.exe" pack --packId Reprise --packVersion $Version --packDir $publish --mainExe Reprise.exe --icon "$root/windows/Reprise.Windows/Assets/Reprise.ico" --packTitle Reprise --packAuthors en-code23 --outputDir $output
if ($LASTEXITCODE -ne 0) { throw 'Windows installer packaging failed.' }
if (-not (Get-ChildItem $output -Filter '*Setup.exe')) { throw 'The Windows installer EXE was not generated.' }
if ($TestInstaller) {
    $setup = Get-ChildItem $output -Filter '*Setup.exe' | Select-Object -First 1
    $install = Start-Process $setup.FullName -ArgumentList '--silent' -PassThru
    if (-not $install.WaitForExit(120000)) { $install.Kill(); throw 'Installer test timed out.' }
    if ($install.ExitCode -ne 0) { throw "Installer exited with code $($install.ExitCode)." }
    $installedExe = Join-Path $env:LOCALAPPDATA 'Reprise/current/Reprise.exe'
    if (-not (Test-Path $installedExe)) { throw 'The installer did not create the installed app.' }
    $installedQa = Join-Path $qa 'installed'
    $check = Start-Process $installedExe -ArgumentList @('--smoke-test', "`"$installedQa`"") -PassThru
    if (-not $check.WaitForExit(120000)) { $check.Kill(); throw 'Installed app test timed out.' }
    if ($check.ExitCode -ne 0 -or -not (Test-Path "$installedQa/smoke-result.txt")) {
        if (Test-Path "$installedQa/error.txt") { Get-Content "$installedQa/error.txt" | Write-Host }
        throw 'The installed app failed its UI/OCR test.'
    }
    Get-Process Reprise -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $installedExe } | Stop-Process -Force
    Write-Host 'Installed EXE launched and passed UI/OCR tests.'
}
Write-Host "Windows installer and update packages are ready in $output"
