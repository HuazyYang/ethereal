<#
.SYNOPSIS
Configures and builds ethereal (donut + ethereal-samples) with CMake and Ninja Multi-Config.

.DESCRIPTION
Sets up the Visual Studio developer environment when cl.exe is not on PATH (a bare shell has no
INCLUDE/LIB, so compilation fails with "cannot open include file"), initialises the submodules if
they are missing, then runs `cmake --preset default` and `cmake --build --preset <config>`.

Output: build\bin (every executable, DLL, compiled shader and runtime asset, for all configurations).

.EXAMPLE
.\build.ps1                                   # Release, all targets
.\build.ps1 -Config Debug -Target VXGISample
.\build.ps1 -Target basic_triangle,asteroids_nvrhi
.\build.ps1 -ConfigureOnly -CMakeArgs '-DETHEREAL_BUILD_BENCHMARKS=OFF'
.\build.ps1 -Test                             # also runs ctest (benchmark self-test, analysis tests)
#>
param(
    [string]$Preset = 'default',
    [ValidateSet('Debug', 'Release', 'RelWithDebInfo')][string]$Config = 'Release',
    [string[]]$Target,
    [string[]]$CMakeArgs,
    [switch]$ConfigureOnly,
    [switch]$Test,
    [switch]$Clean
)
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

# --- sources ---------------------------------------------------------------------------------
foreach ($sub in 'ethereal-donut\CMakeLists.txt', 'ethereal-nvrhi\CMakeLists.txt', 'ethereal-samples\CMakeLists.txt') {
    if (-not (Test-Path $sub)) {
        Write-Host 'Initialising submodules ...'
        git submodule update --init --recursive
        if ($LASTEXITCODE -ne 0) { throw 'git submodule update failed.' }
        break
    }
}

# --- Visual Studio environment ----------------------------------------------------------------
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vsPath = if (Test-Path $vswhere) { & $vswhere -latest -products * -property installationPath } else { $null }
    if (-not $vsPath) { $vsPath = 'C:\Program Files\Microsoft Visual Studio\2022\Community' }
    $vsDevCmd = Join-Path $vsPath 'Common7\Tools\VsDevCmd.bat'
    if (-not (Test-Path $vsDevCmd)) { throw "VsDevCmd.bat not found ($vsDevCmd). Install Visual Studio 2022 with the C++ workload." }
    Write-Host "Using $vsDevCmd"
    # stderr is dropped inside cmd: VsDevCmd prints harmless notices there, which PowerShell 5.1
    # would turn into terminating errors under $ErrorActionPreference = 'Stop'.
    cmd /c "`"$vsDevCmd`" -arch=amd64 -host_arch=amd64 -no_logo 2>nul && set" | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($matches[1])" -Value $matches[2] -ErrorAction SilentlyContinue }
    }
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) { throw 'cl.exe is still not on PATH after VsDevCmd.' }
}

# Ninja files use UTF-8. A localized cl.exe also needs UTF-8 diagnostics for
# /showIncludes dependency paths to match CMake's detected prefix.
$env:VSLANG = '1033'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
& cmd /c "chcp 65001 >nul"

# --- configure --------------------------------------------------------------------------------
if ($Clean -and (Test-Path build)) {
    # A rebuild from scratch is requested explicitly; the old tree is moved aside, not deleted.
    $aside = "build.old-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Move-Item -LiteralPath build -Destination $aside
    Write-Host "Moved the previous build tree to $aside"
}
# PowerShell 5 must not turn a successful compiler/CMake warning on stderr
# into a terminating error. Native exit codes determine build success.
$ErrorActionPreference = 'Continue'
& cmake --preset $Preset @CMakeArgs
$configureExit = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($configureExit -ne 0) { throw 'CMake configuration failed.' }
if ($ConfigureOnly) { return }

# --- build ------------------------------------------------------------------------------------
$buildPreset = if ($Preset -eq 'default') { $Config.ToLower() } else { "$Preset-$($Config.ToLower())" }
$buildArgs = @('--build', '--preset', $buildPreset)
$targets = @($Target | Where-Object { $_ } | ForEach-Object { $_ -split ',' })   # "-Target a,b" arrives as one string via -File
if ($targets) { $buildArgs += '--target'; $buildArgs += $targets }
& cmake @buildArgs
if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }

# Ninja prints only "Running utility command" lines when nothing needed compiling: that is not a build.
Write-Host "Done. Binaries: $(Join-Path $PSScriptRoot 'build\bin')"

if ($Test) {
    & ctest --preset $buildPreset
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed.' }
}
