$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot.Replace('\','/')
$env:ForceImportBeforeCppTargets = "$root/tools/LocalATL.props"
# Do not let MSYS2's unrelated codec packages influence OBS dependency discovery.
$env:PKG_CONFIG_LIBDIR = "$root/obs-studio/.deps/obs-deps-2026-08-26-x64/lib/pkgconfig"
$env:PKG_CONFIG_PATH = ''
Push-Location "$root/obs-studio"
try {
    cmake --fresh --preset windows-x64 -DENABLE_LIBFDK=ON "-DLibfdk_LIBRARY=$root/local/lib/fdk-aac.lib" "-DLibfdk_INCLUDE_DIR=$root/local/include"
    if ($LASTEXITCODE) { throw 'OBS configure failed' }
    cmake --build --preset windows-x64 --parallel 6
    if ($LASTEXITCODE) { throw 'OBS build failed' }
} finally { Pop-Location }
