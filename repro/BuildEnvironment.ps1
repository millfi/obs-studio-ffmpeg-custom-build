function Get-BuildEnvironment {
    param([string]$MsysRoot, [string]$LLVMRoot, [string]$VSInstallPath)
    $missing = [Collections.Generic.List[string]]::new()
    if ($PSVersionTable.PSVersion -lt [version]'7.2') { $missing.Add('PowerShell 7.2 or newer (run with pwsh.exe).') }
    if (!$IsWindows -or ![Environment]::Is64BitProcess) { $missing.Add('64-bit Windows and 64-bit PowerShell are required.') }
    $commands = @{}
    # 7z extracts the source cache; its Zstandard support is checked by
    # Get-SevenZip in repro/SourceCache.ps1.
    foreach ($name in @('cmake','git','ninja','pwsh','robocopy','7z')) {
        $found = Get-Command "$name.exe" -ErrorAction SilentlyContinue
        if ($found) { $commands[$name] = $found.Source } else { $missing.Add("$name.exe must be on PATH.") }
    }
    if ($commands.cmake) {
        $versionText = & $commands.cmake --version | Select-Object -First 1
        if ($versionText -notmatch '(\d+\.\d+\.\d+)' -or [version]$Matches[1] -lt [version]'4.2.0') {
            $missing.Add('CMake 4.2+ is required for the Visual Studio 18 2026 generator; original build used 4.4.2.')
        }
    }
    if (!$MsysRoot) {
        $bash = Get-Command bash.exe -ErrorAction SilentlyContinue
        $candidates = @($env:MSYS2_ROOT, 'C:/msys64', 'D:/msys64')
        if ($bash -and $bash.Source -match '[/\\]usr[/\\]bin[/\\]bash.exe$') { $candidates = @((Split-Path (Split-Path (Split-Path $bash.Source)))) + $candidates }
        $MsysRoot = $candidates | Where-Object { $_ -and (Test-Path "$_/usr/bin/msys-2.0.dll") -and (Test-Path "$_/etc/pacman.conf") } | Select-Object -First 1
    }
    $msysBin = "$MsysRoot/usr/bin"
    foreach ($name in @('bash','sh','make','sed','grep','awk','diff','perl','tar','gzip','find','sort','head','tail','tr','cut','cmp','rm','cp','mv','mkdir','cat','wc','dirname','basename','od','printf','touch','uname','readlink','xargs','install','which','expr','mktemp','tee','ls','test')) {
        if (!(Test-Path "$msysBin/$name.exe")) { $missing.Add("MSYS2 tool $name.exe missing; install the corresponding MSYS2 base/devel package, or specify -MsysRoot.") }
    }
    $extraDirs = @("$MsysRoot/mingw64/bin", "$MsysRoot/ucrt64/bin", "$MsysRoot/clang64/bin", $msysBin)
    foreach ($name in @('nasm','pkgconf')) {
        $candidate = $extraDirs | ForEach-Object { "$_/$name.exe" } | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (!$candidate) { $candidate = (Get-Command "$name.exe" -ErrorAction SilentlyContinue).Source }
        if ($candidate) { $commands[$name] = $candidate } else { $missing.Add("Install NASM/pkgconf in MSYS2: missing $name.exe.") }
    }
    if (!$LLVMRoot) {
        $clang = Get-Command clang-cl.exe -ErrorAction SilentlyContinue
        $LLVMRoot = if ($clang) { Split-Path (Split-Path $clang.Source) } else { 'C:/Program Files/LLVM' }
    }
    foreach ($name in @('clang-cl','llvm-ar')) {
        if (!(Test-Path "$LLVMRoot/bin/$name.exe")) { $missing.Add("LLVM $name.exe missing; install LLVM or specify -LLVMRoot.") }
    }
    $vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
    $vs = $null
    if (Test-Path $vswhere) {
        # -utf8: vswhere otherwise emits the OEM code page when redirected and
        # the localized "description" breaks JSON parsing on Japanese Windows.
        $instances = @(& $vswhere -products '*' -version '[18.0,19.0)' -format json -utf8 | ConvertFrom-Json)
        if ($VSInstallPath) { $instances = @($instances | Where-Object installationPath -eq $VSInstallPath) }
        $vs = $instances | Select-Object -First 1
    }
    if (!$vs) { $missing.Add('Visual Studio Build Tools 2026 with MSVC x64/x86 tools is required; MSBuild alone is insufficient.') }
    $msvc = $null
    if ($vs) {
        $msvc = Get-ChildItem "$($vs.installationPath)/VC/Tools/MSVC" -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        foreach ($relative in @('bin/Hostx64/x64/cl.exe','bin/Hostx64/x64/link.exe','bin/Hostx64/x64/lib.exe','bin/Hostx64/x64/dumpbin.exe','bin/Hostx64/x64/nmake.exe','bin/Hostx64/x86/cl.exe')) {
            if (!$msvc -or !(Test-Path "$($msvc.FullName)/$relative")) { $missing.Add("MSVC component missing: $relative") }
        }
        if (!(Test-Path "$($vs.installationPath)/Common7/Tools/Microsoft.VisualStudio.DevShell.dll")) { $missing.Add('Visual Studio Developer PowerShell component is missing.') }
    }
    $sdkRoot = (Get-ItemProperty 'HKLM:/SOFTWARE/Microsoft/Windows Kits/Installed Roots' -ErrorAction SilentlyContinue).KitsRoot10
    $sdkRoot = @($sdkRoot, "${env:ProgramFiles(x86)}/Windows Kits/10", "$env:ProgramFiles/Windows Kits/10") | Where-Object { $_ -and (Test-Path "$_/Include/10.0.26100.0/um/Windows.h") } | Select-Object -First 1
    foreach ($relative in @('Include/10.0.26100.0/um/Windows.h','Lib/10.0.26100.0/um/x64/kernel32.lib','Lib/10.0.26100.0/um/x86/kernel32.lib','bin/10.0.26100.0/x64/rc.exe')) {
        if (!$sdkRoot -or !(Test-Path "$sdkRoot/$relative")) { $missing.Add("Windows SDK 10.0.26100.0 missing: $relative") }
    }
    $gitRoot = if ($commands.git) { Split-Path (Split-Path $commands.git) } else { '' }
    if (!(Test-Path "$gitRoot/usr/bin/patch.exe")) { $missing.Add('Git for Windows must include usr/bin/patch.exe.') }
    if ($missing.Count) { throw ("Required build tools are missing. No tools have been installed.`n - " + ($missing -join "`n - ")) }
    [pscustomobject]@{ Commands=$commands; MsysRoot=$MsysRoot; MsysBin=$msysBin; LLVMRoot=$LLVMRoot; VS=$vs; MSVC=$msvc.FullName; GitRoot=$gitRoot; SDKRoot=$sdkRoot }
}
function Enable-BuildEnvironment($Tools) {
    $env:PATH = ((@((Split-Path $Tools.Commands.git),(Split-Path $Tools.Commands.cmake),(Split-Path $Tools.Commands.ninja),(Split-Path $Tools.Commands.pwsh),(Split-Path $Tools.Commands.nasm),(Split-Path $Tools.Commands.pkgconf),$Tools.MsysBin,"$($Tools.LLVMRoot)/bin") | Select-Object -Unique) -join ';') + ';' + $env:PATH
    $env:MSYS2_PATH_TYPE = 'inherit'
    $env:OBS_REPRO_MSYS = $Tools.MsysRoot
    $env:OBS_REPRO_LLVM = $Tools.LLVMRoot
    $env:OBS_REPRO_VS = $Tools.VS.installationPath
    $env:OBS_REPRO_VS_ID = $Tools.VS.instanceId
}
