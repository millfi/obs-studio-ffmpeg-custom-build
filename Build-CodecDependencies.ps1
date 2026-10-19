# libtheora is intentionally absent: the FFmpeg encoder whitelist does not build
# its encoder, so building the library would add an unused DLL and import lib.
param([string[]]$Dependencies = @('opus','libogg','libvorbis','libvpx','svt-av1','aom','lame'))
$ErrorActionPreference = 'Stop'
# MSBuild reports warnings and errors in UTF-8; decode it as such instead of
# with the Japanese console code page (Build-Reproduce.ps1 pins the console).
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch { }
$root = $PSScriptRoot
$script:ProjectRoot = "$root/obs-deps"
$script:WorkRoot = "$root/build/codec-sources"
$script:Target = 'x64'
$script:HostArchitecture = 'x64'
$script:Configuration = 'Release'
$script:SkipDeps = $true
$script:Shared = [switch]$false
$script:ConfigData = @{ OutputPath = "$root/local"; Arch = 'x64'; CmakeArch = 'x64' }
$script:CFlags = '-O2 -Ob2 -DNDEBUG'
$script:CxxFlags = '-O2 -Ob2 -DNDEBUG'
$script:CmakeOptions = @('-G','Visual Studio 18 2026','-A','x64',"-DCMAKE_INSTALL_PREFIX=$root/local", "-DCMAKE_PREFIX_PATH=$root/local", '-DCMAKE_BUILD_TYPE=Release','-DCMAKE_POLICY_VERSION_MINIMUM=3.5')
$script:CMakePostfix = @('--parallel','6')
$env:NUMBER_OF_PROCESSORS = '6'
if (!$env:OBS_REPRO_MSYS) { $env:PATH = "C:\msys64\mingw64\bin;C:\msys64\usr\bin;" + $env:PATH }
$env:MSYS2_PATH_TYPE = 'inherit'
# Do not silently depend on Yasm when it happens to be installed alongside NASM.
if ('libvpx' -in $Dependencies) { $env:AS = 'nasm' }
Get-ChildItem "$root/obs-deps/utils.pwsh/*.ps1" | ForEach-Object { . $_.FullName }
if (Test-Path "$root/repro/UpstreamAdapters.ps1") { . "$root/repro/UpstreamAdapters.ps1" }
function Find-VisualStudio {
    # vswhere writes JSON in the OEM code page when its stdout is redirected.
    # On a Japanese system the localized "description" then contains Shift-JIS
    # trail bytes (0x5C, 0x22) that corrupt the JSON, so ask for UTF-8 output.
    $vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
    $vswhereArgs = @('-latest', '-products', '*', '-version', '[18.0,19.0)', '-format', 'json', '-utf8')
    if ($env:OBS_REPRO_VS) { $vswhereArgs = @('-products', '*', '-format', 'json', '-utf8') }
    $instances = @(& $vswhere @vswhereArgs | ConvertFrom-Json)
    if ($LASTEXITCODE) { throw "vswhere failed ($LASTEXITCODE): $vswhere $($vswhereArgs -join ' ')" }
    if ($env:OBS_REPRO_VS) { $instances = @($instances | Where-Object installationPath -eq $env:OBS_REPRO_VS) }
    if (!$instances.Count) {
        $expected = if ($env:OBS_REPRO_VS) { " (expected '$env:OBS_REPRO_VS')" } else { '' }
        throw "No Visual Studio 18 instance found by vswhere$expected."
    }
    return $instances[0]
}
New-Item -ItemType Directory -Force $WorkRoot | Out-Null
foreach ($dep in $Dependencies) {
    & {
        $scriptFile = Get-Item "$root/obs-deps/deps.ffmpeg/*-$dep.ps1"
        . $scriptFile.FullName
        $Path = [IO.Path]::GetFileNameWithoutExtension($Uri)
        $script:StageName = $Name
        foreach ($stage in @('Setup','Patch','Configure','Build','Install','Fixup')) {
            Set-Location $WorkRoot
            if (Test-Path "function:$stage") {
                Write-Host "=== $dep : $stage ==="
                if ($dep -eq 'aom' -and $stage -eq 'Configure') {
                    Set-Location "$WorkRoot/$Path"
                    $llvm = if ($env:OBS_REPRO_LLVM) { $env:OBS_REPRO_LLVM.Replace('\','/') } else { 'C:/Program Files/LLVM' }
                    $aomConfigure = 'cmake --fresh -S . -B build_x64 -G Ninja -DCMAKE_C_COMPILER="' + $llvm + '/bin/clang-cl.exe" -DCMAKE_CXX_COMPILER="' + $llvm + '/bin/clang-cl.exe" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DENABLE_DOCS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_TESTDATA=OFF -DENABLE_TESTS=OFF -DENABLE_TOOLS=OFF -DENABLE_NASM=ON -DAOM_TARGET_CPU=x86_64 -DCMAKE_INSTALL_PREFIX=' + $ConfigData.OutputPath
                    Invoke-DevShell -BasePath (Get-Location).Path -BuildPath . -BuildCommand $aomConfigure -Target x64
                } else {
                    & $stage
                }
                if ($dep -eq 'libvpx' -and $stage -eq 'Setup') {
                    # A clean tree generates .vcxproj during make, after Configure.
                    # Retarget the generator as well as any already generated projects.
                    $generator = "$WorkRoot/libvpx-$Version/build/make/gen_msvs_vcxproj.sh"
                    [IO.File]::WriteAllText($generator, ([IO.File]::ReadAllText($generator).Replace('PlatformToolset v143','PlatformToolset v145')))
                }
                if ($dep -eq 'libvpx' -and $stage -eq 'Configure') {
                    Get-ChildItem "$WorkRoot/libvpx-$Version/build_x64/*.vcxproj" | ForEach-Object {
                        (Get-Content $_.FullName -Raw).Replace('v143','v145') | Set-Content $_.FullName
                    }
                }
            }
        }
    }
}
