# Version declarations for the OBS/FFmpeg build (Cargo.toml style).
#
# Edit a rev here, then run Download-Sources.ps1: it resolves the rev to a
# commit, refreshes only the affected source-cache archive and records the
# result in sources.lock. Build-Reproduce.ps1 reads sources.lock only, so a
# declaration edit can never silently change a build before the download step
# ran (the same relationship as Cargo.toml / Cargo.lock).
#
# Each entry is either a rev string (tag, branch or 40-character commit) or a
# table with:
#   rev         (required) tag / branch / 40-character commit
#   url         (optional) override the built-in repository URL
#   submodules  (optional) initialize submodules
#   history     (optional) extra commits to fetch on top of the shallow clone
#   tags        (optional) extra tag refs to fetch so "git describe" reports the
#                          same version string as the original build
#   core_abbrev (optional) "git config core.abbrev" value used by version strings
#
# Examples of a version bump:
#   'fdk-aac' = 'v2.0.3'
#   'ffmpeg'  = 'n8.1.2'
#   'libvpl'  = 'v2.15.0'
#
# The ATL development files and the prebuilt OBS dependencies (Windows deps,
# Qt6, CEF) have no user-selectable version: their pinned hashes come from
# repro/SourceCache.ps1 and obs-studio/CMakePresets.json, so they follow the
# obs-studio pin automatically.
@{
    sources = @{
        'obs-studio' = @{
            rev = 'b5bfb79093e26ce4b0e71d999f59b6b22f961121'
            submodules = $true
            history = 400
            tags = @('32.2.1')
            core_abbrev = 9
        }
        'fdk-aac' = 'c41c3c7516ea8d0d78a53b96b30bed3a29745cc6'
        'ffmpeg' = @{
            rev = '38b88335f99e76ed89ff3c93f877fdefce736c13'
            tags = @('n8.1.2')
        }
        'obs-deps' = 'f80e1d30181b0ff2b048b6d8fe8b8c501f3d221c'
        'libvpl' = '674d015bcb294bc39fa276e99a652ea045423e82'
    }
}
