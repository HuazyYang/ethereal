# Capture the explicitly separate zero-offset NaN diagnostic. Run GPU jobs serially.
param(
    [string]$LegacyBuild = 'build/legacy-reference',
    [string]$Output = 'build/acceptance/mixed-finite-reference',
    [string]$OptixInclude = 'C:/Program Files/NVIDIA GPU Computing Toolkit/OptiX SDK 9.0.0/include',
    [double]$SecondaryBias = 0.01
)
$ErrorActionPreference = 'Stop'
if ([double]::IsNaN($SecondaryBias) -or [double]::IsInfinity($SecondaryBias) -or $SecondaryBias -lt 0) {
    throw 'SecondaryBias must be finite and nonnegative'
}
$repository = Split-Path $PSScriptRoot -Parent
$legacy = [IO.Path]::GetFullPath((Join-Path $repository $LegacyBuild))
$destination = [IO.Path]::GetFullPath((Join-Path $repository $Output))
New-Item -ItemType Directory -Force $destination | Out-Null
$source = Join-Path $repository 'ethereal-samples/src/gvdb_samples/samples/sample-utils/kernels/optix/OptixPrograms.cu'
$originalExpression = 'const float3 fhp = hitW + optixTransformVectorFromObjectToWorldSpace(nObj * frontOfs);'
$content = [IO.File]::ReadAllText($source)
if (($content.Split(@($originalExpression), [StringSplitOptions]::None)).Length -ne 2) {
    throw 'Expected exactly one original level-set offset expression'
}
$patched = Join-Path $destination 'OptixPrograms-finite.cu'
$ptx = Join-Path $destination 'OptixPrograms-finite.ptx'
[IO.File]::WriteAllText($patched, $content.Replace($originalExpression,
    'const float3 fhp = frontOfs == 0.f ? hitW : hitW + optixTransformVectorFromObjectToWorldSpace(nObj * frontOfs);'))
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vsPath = & $vswhere -latest -products * -property installationPath
$vsDevCmd = Join-Path $vsPath 'Common7/Tools/VsDevCmd.bat'
cmd /c "`"$vsDevCmd`" -arch=amd64 -host_arch=amd64 -no_logo 2>nul && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($matches[1])" -Value $matches[2] -ErrorAction SilentlyContinue }
}
$ErrorActionPreference = 'Continue' # nvcc warnings are stderr on Windows PowerShell.
& nvcc -ptx -arch=compute_75 -std=c++17 --use_fast_math -lineinfo -rdc=true -DOPTIX_PATHWAY=1 `
    -I "$repository/ethereal-samples/src/gvdb_samples" -I "$repository/ethereal-samples/src/gvdb_samples/samples" `
    -I $OptixInclude $patched -o $ptx
if ($LASTEXITCODE -ne 0) { throw 'Diagnostic compile failed' }
$ErrorActionPreference = 'Stop'
$reference = Join-Path $legacy 'bin/ptx/OptixPrograms.ptx'
$original = [IO.File]::ReadAllBytes($reference)
# Keep a recovery copy even if this shell is forcibly terminated.
$backup = Join-Path $destination 'OptixPrograms-original.ptx'
if (Test-Path $backup) { throw "Recovery copy already exists; inspect it before retrying: $backup" }
[IO.File]::WriteAllBytes($backup, $original)
try {
    [IO.File]::WriteAllBytes($reference, [IO.File]::ReadAllBytes($ptx))
    $exe = Join-Path $legacy 'bin/interactive-optix.exe'
    $bias = $SecondaryBias.ToString([Globalization.CultureInfo]::InvariantCulture)
    $process = Start-Process -FilePath $exe -ArgumentList @('-dx12', '--secondary-bias', $bias,
        '--shading', 'levelset', '--samples', '8', '--frames', '1000000',
        '--screenshot', 'legacy-finite-levelset.png') -WorkingDirectory $destination -WindowStyle Hidden `
        -PassThru -RedirectStandardOutput (Join-Path $destination 'legacy-finite.log') `
        -RedirectStandardError (Join-Path $destination 'legacy-finite.err')
    $process.Handle | Out-Null
    if (!$process.WaitForExit(60000)) { $process.Kill(); $process.WaitForExit(); throw 'Diagnostic capture timeout' }
    if ($process.ExitCode -ne 0) { throw 'Diagnostic capture failed' }
    @{ secondaryBias = $SecondaryBias; samples = 8; width = 1024; height = 768;
       reference = 'Separate zero-offset NaN diagnostic; retained source is unchanged' } |
        ConvertTo-Json | Set-Content (Join-Path $destination 'diagnostic.json')
} finally {
    [IO.File]::WriteAllBytes($reference, $original)
    Remove-Item -LiteralPath $backup
}
