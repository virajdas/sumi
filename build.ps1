# Builds Sumi and packs it into a single installer: dist\SumiSetup.exe
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

if (-not (Test-Path "$root\assets\sumi.ico")) { & "$root\tools\make-icon.ps1" }

dotnet build "$root\src\Sumi\Sumi.csproj" -c Release -nologo -v q
if ($LASTEXITCODE) { throw "Sumi build failed" }

dotnet build "$root\src\Setup\Setup.csproj" -c Release -nologo -v q
if ($LASTEXITCODE) { throw "Setup build failed" }

New-Item -ItemType Directory -Force "$root\dist" | Out-Null
Copy-Item "$root\src\Setup\bin\Release\net48\SumiSetup.exe" "$root\dist\SumiSetup.exe" -Force
$size = [Math]::Round((Get-Item "$root\dist\SumiSetup.exe").Length / 1MB, 2)
Write-Host "dist\SumiSetup.exe  ($size MB)"
