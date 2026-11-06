# nx-fork-manager: keeps emulator forks on their latest ready-made release and
# recommends a fork per game from the riyadhHDA/wichforks community guide.
# Normal use: run ForkManager.cmd. Direct actions:
#   -Action Check|Update|Install|Rollback|Pin|Unpin|Open|Sync|Status [-Fork <id>] [-Tag <tag>]
#   -Action Add -Url <repository link>   /   -Action Remove -Fork <id>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Check', 'Update', 'Install', 'Rollback', 'Pin', 'Unpin', 'Open', 'Sync', 'Status', 'Add', 'Remove')]
    [string]$Action = 'Menu',
    [string]$Fork,
    [string]$Tag,
    [string]$Url
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:Here = $PSScriptRoot
$script:Utf8 = New-Object Text.UTF8Encoding $false
$script:DataDir = Join-Path $script:Here 'data'
$script:TmpDir = Join-Path $script:DataDir '_tmp'
$script:CacheDir = Join-Path $script:DataDir 'wichforks'
$script:StateFile = Join-Path $script:DataDir 'state.json'
$script:ChecksFile = Join-Path $script:DataDir 'checks.json'
$script:NotesFile = Join-Path $script:DataDir 'my-notes.json'
$script:ConfigFile = Join-Path $script:Here 'config.json'
$script:MyForksFile = Join-Path $script:Here 'my-forks.json'
$script:GamesFile = Join-Path $script:Here 'GAMES.md'

# --- helpers -------------------------------------------------------------------------------------

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return [IO.File]::ReadAllText($Path) | ConvertFrom-Json
}

# Write to a temp file first, so a crash never leaves half a JSON file.
function Write-JsonFile([string]$Path, $Value) {
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, ($Value | ConvertTo-Json -Depth 8), $script:Utf8)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Set-Prop($Object, [string]$Name, $Value) {
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

# --- configuration -------------------------------------------------------------------------------

function Get-DetectedGpu {
    $names = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name })
    # Prefer a dedicated GPU over integrated graphics.
    foreach ($vendor in @(@('NVIDIA', 'NVIDIA|GeForce'), @('AMD', 'AMD|Radeon'), @('Intel', 'Intel|Arc'))) {
        foreach ($n in $names) { if ($n -match $vendor[1]) { return $vendor[0] } }
    }
    return ''
}

function Get-Config {
    $cfg = Read-JsonFile $script:ConfigFile
    if ($null -eq $cfg) {
        $cfg = [pscustomobject]@{
            gpu                    = Get-DetectedGpu
            install_dir            = 'forks'
            check_interval_minutes = 60
            zip_backups            = 0
        }
        Write-JsonFile $script:ConfigFile $cfg
        $shown = if ($cfg.gpu) { $cfg.gpu } else { 'not detected (no GPU filter)' }
        Write-Host "Created config.json. GPU: $shown. Edit config.json to change it."
    }
    return $cfg
}

# forks.json ships with the tool. my-forks.json holds the forks you add, so updating the tool never touches them.
function Import-Catalog {
    $catalog = [IO.File]::ReadAllText((Join-Path $script:Here 'forks.json')) | ConvertFrom-Json
    $mine = Read-JsonFile $script:MyForksFile
    $script:CustomIds = @()
    if ($mine -and $mine.forks) {
        $catalog.forks = @($catalog.forks) + @($mine.forks)
        $script:CustomIds = @($mine.forks | ForEach-Object { $_.id })
    }
    return $catalog
}

New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
$script:Catalog = Import-Catalog
$script:Config = Get-Config
$script:ForksDir = if ([IO.Path]::IsPathRooted([string]$script:Config.install_dir)) { [string]$script:Config.install_dir }
else { Join-Path $script:Here ([string]$script:Config.install_dir) }
$script:ForksDir = [IO.Path]::GetFullPath($script:ForksDir)
$script:PrevDir = Join-Path $script:ForksDir '_previous'
$script:ZipDir = Join-Path $script:ForksDir '_zips'

# Deletes only inside folders this tool owns.
function Remove-Managed([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $full = [IO.Path]::GetFullPath($Path)
    $allowed = @($script:ForksDir, $script:TmpDir, $script:CacheDir) | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') + '\' }
    $ok = $false
    foreach ($prefix in $allowed) { if ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $ok = $true } }
    if (-not $ok) { throw "Refused to delete outside the managed folders: $full" }
    Remove-Item -LiteralPath $full -Recurse -Force
}

# Antivirus often holds a freshly extracted folder for a few seconds.
function Move-Dir([string]$From, [string]$To) {
    for ($i = 1; ; $i++) {
        try { [IO.Directory]::Move($From, $To); return }
        catch {
            if ($i -ge 6) { throw }
            Start-Sleep -Seconds 2
        }
    }
}

function Get-RunningUnder([string]$Dir) {
    $prefix = [IO.Path]::GetFullPath($Dir).TrimEnd('\') + '\'
    return @(Get-CimInstance Win32_Process | Where-Object {
            $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
        })
}

# --- API rate limit ------------------------------------------------------------------------------
# Without a token GitHub allows 60 requests per hour, and 304 (ETag) answers count too.
# So the menu checks each item at most once per interval.

$script:Checks = $null
$script:BlockedUntil = $null

function Get-Checks {
    if ($null -eq $script:Checks) {
        $script:Checks = Read-JsonFile $script:ChecksFile
        if ($null -eq $script:Checks) { $script:Checks = [pscustomobject]@{} }
    }
    return $script:Checks
}

function Get-LimitMessage {
    $at = $script:BlockedUntil.ToString('HH:mm')
    return "GitHub API limit reached (60 requests per hour without a token). Resets at $at. Set GITHUB_TOKEN for a limit of 5000."
}

function Get-JsonUrl([string]$Url) {
    $isGitHub = $Url.StartsWith('https://api.github.com/')
    if ($isGitHub -and $script:BlockedUntil) { throw (Get-LimitMessage) }
    $headers = @{ 'User-Agent' = 'nx-fork-manager'; 'Accept' = 'application/json' }
    # Optional token: raises the API limit and lets Actions artifacts download straight from GitHub.
    if ($env:GITHUB_TOKEN -and $isGitHub) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    try {
        return Invoke-RestMethod -Uri $Url -Headers $headers -TimeoutSec 30
    }
    catch [System.Net.WebException] {
        $r = $_.Exception.Response
        if ($r) {
            $code = [int]$r.StatusCode
            if ($isGitHub -and ($code -eq 403 -or $code -eq 429) -and $r.Headers['X-RateLimit-Remaining'] -eq '0') {
                $script:BlockedUntil = [DateTimeOffset]::FromUnixTimeSeconds([long]$r.Headers['X-RateLimit-Reset']).LocalDateTime
                throw (Get-LimitMessage)
            }
            if ($isGitHub -and $code -eq 401 -and $env:GITHUB_TOKEN) {
                throw 'GitHub rejected GITHUB_TOKEN (401 Bad credentials). The token expired or was deleted. Create a new one, or remove the variable to use the 60-per-hour limit.'
            }
            if ($isGitHub -and ($code -eq 403 -or $code -eq 429)) {
                throw "GitHub refused the request ($code). This is usually the short-term abuse limit: wait a few minutes. With a token, check that it can read public repositories."
            }
        }
        throw
    }
}

function Test-CheckedRecently([string]$Key) {
    $minutes = if ($script:Config.check_interval_minutes) { [int]$script:Config.check_interval_minutes } else { 60 }
    $p = (Get-Checks).PSObject.Properties["checked:$Key"]
    if (-not $p) { return $false }
    return ((Get-Date) - [datetime]::Parse($p.Value, [Globalization.CultureInfo]::InvariantCulture)).TotalMinutes -lt $minutes
}

function Set-Checked([string]$Key) {
    $checks = Get-Checks
    Set-Prop $checks "checked:$Key" (Get-Date).ToString('s')
    Write-JsonFile $script:ChecksFile $checks
}

# --- state ---------------------------------------------------------------------------------------

function Get-State {
    $s = Read-JsonFile $script:StateFile
    if ($null -eq $s) { $s = [pscustomobject]@{} }
    return $s
}

function Get-Entry($State, [string]$Id) {
    $p = $State.PSObject.Properties[$Id]
    if ($p) { return $p.Value }
    return $null
}

function Get-ForkDir([string]$Id) { return Join-Path $script:ForksDir $Id }
function Get-PrevForkDir([string]$Id) { return Join-Path $script:PrevDir $Id }
function Get-ZipForkDir([string]$Id) { return Join-Path $script:ZipDir $Id }

# --- zip backups ---------------------------------------------------------------------------------
# config.json "zip_backups": 0 = keep no zips (default), a number = keep that many per fork, "all" = keep every zip.

# Returns -1 for "all", otherwise the number of zips to keep per fork.
function Get-ZipBackupLimit {
    $value = $script:Config.PSObject.Properties['zip_backups']
    if (-not $value -or $null -eq $value.Value) { return 0 }
    $text = ([string]$value.Value).Trim()
    if ($text -ieq 'all') { return -1 }
    $n = 0
    if ([int]::TryParse($text, [ref]$n) -and $n -ge 0) { return $n }
    Write-Warning "config.json: zip_backups must be 0, a number or ""all"" (found ""$text""). No zips are kept."
    return 0
}

function Get-ZipBackupLabel {
    $limit = Get-ZipBackupLimit
    if ($limit -lt 0) { return 'all' }
    if ($limit -eq 0) { return 'none' }
    return "$limit per fork"
}

# Deletes the oldest zips of a fork beyond the limit. With "all" nothing is deleted.
function Limit-ZipBackups([string]$Id) {
    $limit = Get-ZipBackupLimit
    if ($limit -lt 0) { return }
    $dir = Get-ZipForkDir $Id
    if (-not (Test-Path -LiteralPath $dir)) { return }
    $zips = @(Get-ChildItem -LiteralPath $dir -File -Filter *.zip | Sort-Object LastWriteTime -Descending)
    foreach ($old in ($zips | Select-Object -Skip $limit)) { Remove-Managed $old.FullName }
    if (-not (Get-ChildItem -LiteralPath $dir -Force)) { Remove-Managed $dir }
}

# Keeps the downloaded zip, named after its tag so builds with the same file name do not overwrite each other.
function Save-ZipBackup($F, [string]$Zip, $Info) {
    if ((Get-ZipBackupLimit) -eq 0) { return }
    $dir = Get-ZipForkDir $F.id
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $tag = ($Info.release.tag -replace '[^\w.-]+', '-').Trim('-')
    $name = [string]$Info.asset.name
    if ($name -notmatch '(?i)\.zip$') { $name += '.zip' }
    $target = Join-Path $dir "$tag`_$name"
    Move-Item -LiteralPath $Zip -Destination $target -Force
    (Get-Item -LiteralPath $target).LastWriteTime = Get-Date
    Limit-ZipBackups $F.id
    Write-Host "  Zip kept: $target"
}

function Set-ZipBackups([string]$Value) {
    $text = $Value.Trim().ToLower()
    $n = 0
    if ($text -eq 'all') { $stored = 'all' }
    elseif ([int]::TryParse($text, [ref]$n) -and $n -ge 0) { $stored = $n }
    else { throw 'Type 0 (no backups), a number, or "all".' }
    Set-Prop $script:Config 'zip_backups' $stored
    Write-JsonFile $script:ConfigFile $script:Config
    # Apply a lower limit right away.
    if (Test-Path -LiteralPath $script:ZipDir) {
        foreach ($d in @(Get-ChildItem -LiteralPath $script:ZipDir -Directory)) { Limit-ZipBackups $d.Name }
        if (-not (Get-ChildItem -LiteralPath $script:ZipDir -Force)) { Remove-Managed $script:ZipDir }
    }
    Write-Host "Zip backups: $(Get-ZipBackupLabel)."
}

function Test-Installed($State, $F) {
    return ($null -ne (Get-Entry $State $F.id)) -and (Test-Path -LiteralPath (Get-ForkDir $F.id))
}

function Get-ForkById([string]$Id) {
    $f = $script:Catalog.forks | Where-Object { $_.id -eq $Id }
    if (-not $f) { throw "Unknown fork: $Id. Known: $(($script:Catalog.forks | ForEach-Object id) -join ', ')" }
    return $f
}

function Get-ForkByNumber([string]$Number) {
    $i = [int]$Number
    if ($i -lt 1 -or $i -gt @($script:Catalog.forks).Count) { throw "No fork number $Number." }
    return @($script:Catalog.forks)[$i - 1]
}

# Updates touch installed forks only. A fork is installed the first time you open it.
function Get-InstalledForks($State) {
    return @($script:Catalog.forks | Where-Object { Test-Installed $State $_ })
}

# --- releases ------------------------------------------------------------------------------------

function Get-Releases($F) {
    if ($F.source -eq 'forgejo') {
        $raw = Get-JsonUrl "https://$($F.host)/api/v1/repos/$($F.repo)/releases?limit=15"
    }
    else {
        $raw = Get-JsonUrl "https://api.github.com/repos/$($F.repo)/releases?per_page=15"
    }
    $list = foreach ($r in $raw) {
        if ($r.draft) { continue }
        $assets = foreach ($a in $r.assets) {
            [pscustomobject]@{
                name   = [string]$a.name
                size   = [long]$a.size
                url    = [string]$a.browser_download_url
                digest = [string]$a.digest
            }
        }
        [pscustomobject]@{
            tag    = [string]$r.tag_name
            name   = [string]$r.name
            url    = [string]$r.html_url
            date   = [DateTimeOffset]::Parse([string]$r.published_at, [Globalization.CultureInfo]::InvariantCulture)
            assets = @($assets)
        }
    }
    # The API does not promise publish-date order.
    return @($list | Sort-Object date -Descending)
}

function Find-Asset($F, $Release) {
    foreach ($a in $Release.assets) {
        if ($a.name -match $F.include -and -not ($F.exclude -and $a.name -match $F.exclude)) { return $a }
    }
    return $null
}

# GitHub Actions build: newest successful run of the workflow, from any branch (or only $F.branch).
# Artifacts need a GitHub login. Without GITHUB_TOKEN the zip comes through nightly.link,
# and the SHA-256 digest from the GitHub API still verifies it.
function Get-ActionsInfo($F, [string]$Wanted) {
    $url = "https://api.github.com/repos/$($F.repo)/actions/workflows/$($F.workflow)/runs?status=success&per_page=15"
    if ($F.branch) { $url += "&branch=$($F.branch)" }
    foreach ($run in (Get-JsonUrl $url).workflow_runs) {
        $tag = "build-$($run.run_number) ($($run.head_branch) $($run.head_sha.Substring(0, 7)))"
        if ($Wanted -and $tag -ne $Wanted -and -not $tag.StartsWith("$Wanted ")) { continue }
        $artifacts = (Get-JsonUrl "https://api.github.com/repos/$($F.repo)/actions/runs/$($run.id)/artifacts?per_page=50").artifacts
        foreach ($a in $artifacts) {
            if ($a.expired) { continue }
            if ($a.name -notmatch $F.include -or ($F.exclude -and $a.name -match $F.exclude)) { continue }
            $download = if ($env:GITHUB_TOKEN) { "https://api.github.com/repos/$($F.repo)/actions/artifacts/$($a.id)/zip" }
            else { "https://nightly.link/$($F.repo)/actions/artifacts/$($a.id).zip" }
            $release = [pscustomobject]@{
                tag    = $tag
                url    = [string]$run.html_url
                date   = [DateTimeOffset]::Parse([string]$run.updated_at, [Globalization.CultureInfo]::InvariantCulture)
                assets = @()
            }
            $asset = [pscustomobject]@{
                name   = "$($a.name).zip"
                size   = [long]$a.size_in_bytes
                url    = $download
                digest = [string]$a.digest
                auth   = [bool]$env:GITHUB_TOKEN
            }
            return [pscustomobject]@{ release = $release; asset = $asset }
        }
    }
    if ($Wanted) { throw "Build $Wanted has no valid Windows artifact (artifacts expire after 7 days)." }
    throw "No recent build with a valid Windows artifact in $($F.repo)."
}

function Get-LatestInfo($F, [string]$Wanted) {
    if ($F.source -eq 'actions') { return Get-ActionsInfo $F $Wanted }
    foreach ($r in (Get-Releases $F)) {
        if ($Wanted -and $r.tag -ne $Wanted) { continue }
        # Main channel: skip test-branch, experimental and "don't use" releases.
        if (-not $Wanted -and $F.tags -and $r.tag -notmatch $F.tags) { continue }
        if (-not $Wanted -and $F.release_exclude -and $r.name -match $F.release_exclude) { continue }
        $a = Find-Asset $F $r
        if ($a) { return [pscustomobject]@{ release = $r; asset = $a } }
    }
    if ($Wanted) { throw "Release $Wanted has no matching Windows zip in $($F.repo)." }
    throw "No recent release with a matching Windows zip in $($F.repo)."
}

function Test-IsNew($State, $F, $Info) {
    if (-not (Test-Installed $State $F)) { return $true }
    $e = Get-Entry $State $F.id
    if ($e.tag -ne $Info.release.tag) { return $true }
    return [bool]($Info.asset.digest -and $e.digest -ne $Info.asset.digest)
}

# --- install -------------------------------------------------------------------------------------

function Invoke-Download([string]$Url, [string]$OutFile, [bool]$Auth = $false) {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    $progress = if ([Console]::IsErrorRedirected) { '-sS' } else { '--progress-bar' }
    # curl does not forward Authorization when a redirect goes to another host.
    $extra = @()
    if ($Auth) { $extra = @('-H', "Authorization: Bearer $env:GITHUB_TOKEN") }
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $curl -L --fail --retry 3 --retry-delay 2 --connect-timeout 20 -A 'nx-fork-manager' $progress @extra -o $OutFile $Url
    $code = $LASTEXITCODE
    $ErrorActionPreference = $saved
    if ($code -ne 0) { throw "Download failed (curl $code): $Url" }
}

# Checks the transfer: size always, SHA-256 when the source publishes it. This proves integrity, not trust.
function Assert-Download([string]$Zip, $Asset) {
    $actual = (Get-Item -LiteralPath $Zip).Length
    if ($Asset.size -gt 0 -and $actual -ne $Asset.size) {
        throw "Wrong size for $($Asset.name): expected $($Asset.size), got $actual."
    }
    if ($Asset.digest -match '^sha256:(.+)$') {
        $expected = $Matches[1]
        $hash = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash
        if ($hash -ine $expected) { throw "SHA-256 mismatch for $($Asset.name): expected $expected, got $hash." }
        return 'SHA-256 ok'
    }
    return 'size only (source publishes no hash)'
}

function Find-MainExe([string]$Dir, $F) {
    if ($F.exe -and (Test-Path -LiteralPath (Join-Path $Dir $F.exe))) { return [string]$F.exe }
    $exe = Get-ChildItem -LiteralPath $Dir -File -Filter *.exe |
        Where-Object { $_.Name -notmatch '(?i)^(eden-cli|eden-room|tests)\.exe$|cli\.exe$|room\.exe$|crash|redist|updater' } |
        Select-Object -First 1
    if ($exe) { return [string]$exe.Name }
    return $null
}

function Find-ReleaseRoot([string]$Dir, $F) {
    $current = $Dir
    for ($depth = 0; $depth -lt 3; $depth++) {
        if (Find-MainExe $current $F) { return $current }
        $subs = @(Get-ChildItem -LiteralPath $current -Directory)
        # An Actions artifact can be a zip inside a zip.
        $zips = @(Get-ChildItem -LiteralPath $current -File -Filter *.zip)
        if ($subs.Count -eq 0 -and $zips.Count -eq 1) {
            $inner = Join-Path $current 'inner'
            [IO.Compression.ZipFile]::ExtractToDirectory($zips[0].FullName, $inner)
            $current = $inner
            continue
        }
        if ($subs.Count -ne 1) { break }
        $current = $subs[0].FullName
    }
    throw "The $($F.name) zip has no recognizable executable."
}

function Install-Release($F, $Info) {
    $dest = Get-ForkDir $F.id
    $prev = Get-PrevForkDir $F.id
    $running = @(Get-RunningUnder $dest)
    if ($running.Count) { throw "$($F.name) is running ($($running[0].Name)). Close it and try again." }

    $work = Join-Path $script:TmpDir $F.id
    $zip = "$work.zip"
    $extract = Join-Path $work 'x'
    Remove-Managed $work
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    New-Item -ItemType Directory -Force -Path $extract | Out-Null
    New-Item -ItemType Directory -Force -Path $script:PrevDir | Out-Null

    try {
        $mb = [math]::Round($Info.asset.size / 1MB, 1)
        Write-Host "  Downloading $($Info.asset.name) ($mb MB)..."
        Invoke-Download $Info.asset.url $zip ([bool]$Info.asset.auth)
        $check = Assert-Download $zip $Info.asset
        Write-Host "  Integrity: $check. Extracting..."
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $extract)
        $source = Find-ReleaseRoot $extract $F
        $exe = Find-MainExe $source $F

        $state = Get-State
        $old = Get-Entry $state $F.id
        $hadCurrent = Test-Path -LiteralPath $dest
        if ($hadCurrent) {
            Remove-Managed $prev
            Move-Dir $dest $prev
        }
        try { Move-Dir $source $dest }
        catch {
            if ($hadCurrent) { Move-Dir $prev $dest }
            throw
        }
        # A "user" folder holds portable-mode data, if someone created one.
        $oldUser = Join-Path $prev 'user'
        if ($hadCurrent -and (Test-Path -LiteralPath $oldUser)) { Move-Dir $oldUser (Join-Path $dest 'user') }

        $previous = $null
        if ($hadCurrent -and $old) { $previous = $old | Select-Object -Property * -ExcludeProperty previous }
        $pinned = [bool]($old -and $old.pinned)
        Set-Prop $state $F.id ([pscustomobject]@{
                tag       = $Info.release.tag
                published = $Info.release.date.ToString('yyyy-MM-dd HH:mm')
                asset     = $Info.asset.name
                digest    = $Info.asset.digest
                exe       = $exe
                url       = $Info.release.url
                installed = (Get-Date).ToString('yyyy-MM-dd HH:mm')
                pinned    = $pinned
                previous  = $previous
            })
        Write-JsonFile $script:StateFile $state
        Write-Host "  OK: $($F.name) is now on $($Info.release.tag)."
        # The install already succeeded: a backup problem is only a warning.
        try { Save-ZipBackup $F $zip $Info }
        catch { Write-Warning "Could not keep the zip of $($F.name): $($_.Exception.Message)" }
    }
    finally {
        Remove-Managed $work
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    }
}

# Swaps the current version with the previous one and pins it, so the next update does not undo it.
function Restore-Previous($F) {
    $dest = Get-ForkDir $F.id
    $prev = Get-PrevForkDir $F.id
    if (-not (Test-Path -LiteralPath $prev)) { throw "$($F.name) has no previous version kept." }
    $running = @(Get-RunningUnder $dest)
    if ($running.Count) { throw "$($F.name) is running ($($running[0].Name)). Close it and try again." }

    $state = Get-State
    $current = Get-Entry $state $F.id
    if (-not $current -or -not $current.previous) { throw "State for $($F.name) records no previous version." }

    New-Item -ItemType Directory -Force -Path $script:TmpDir | Out-Null
    $swap = Join-Path $script:TmpDir "swap-$($F.id)"
    Remove-Managed $swap
    Move-Dir $dest $swap
    try { Move-Dir $prev $dest }
    catch { Move-Dir $swap $dest; throw }
    Move-Dir $swap $prev
    $user = Join-Path $prev 'user'
    if (Test-Path -LiteralPath $user) { Move-Dir $user (Join-Path $dest 'user') }

    $restored = $current.previous | Select-Object -Property * -ExcludeProperty previous, pinned
    Set-Prop $restored 'pinned' $true
    Set-Prop $restored 'previous' ($current | Select-Object -Property * -ExcludeProperty previous)
    Set-Prop $state $F.id $restored
    Write-JsonFile $script:StateFile $state
    Write-Host "OK: $($F.name) is back on $($restored.tag) and pinned. Unpin it to get updates again."
}

function Update-Forks($Forks, [bool]$Force = $true) {
    $failures = 0
    $recent = New-Object Collections.ArrayList
    $blocked = New-Object Collections.ArrayList
    foreach ($f in $Forks) {
        try {
            $state = Get-State
            $entry = Get-Entry $state $f.id
            if (-not $Force -and (Test-CheckedRecently $f.id)) {
                [void]$recent.Add($f.name)
                continue
            }
            if ($f.source -ne 'forgejo' -and $script:BlockedUntil) { throw (Get-LimitMessage) }
            $info = Get-LatestInfo $f ''
            if (-not (Test-IsNew $state $f $info)) {
                Set-Checked $f.id
                Write-Host "$($f.name): up to date ($($entry.tag))."
                continue
            }
            if ($entry -and $entry.pinned) {
                Set-Checked $f.id
                Write-Host "$($f.name): pinned on $($entry.tag). Available: $($info.release.tag)."
                continue
            }
            $from = if ($entry) { $entry.tag } else { 'not installed' }
            Write-Host "$($f.name): $from -> $($info.release.tag)"
            # Mark as checked only after the install: a failure (fork running, network) retries next time.
            Install-Release $f $info
            Set-Checked $f.id
        }
        catch {
            # A new fork with no Windows build yet: wait, and do not count it as an error.
            if (-not (Test-Installed (Get-State) $f) -and $_.Exception.Message -like 'No recent*') {
                Set-Checked $f.id
                Write-Host "$($f.name): no release with a Windows zip yet. Will check again later."
                continue
            }
            $failures++
            if ($script:BlockedUntil -and $_.Exception.Message -eq (Get-LimitMessage)) { [void]$blocked.Add($f.name) }
            else { Write-Warning "$($f.name): $($_.Exception.Message)" }
        }
    }
    if ($recent.Count) { Write-Host "Checked recently, skipped: $($recent -join ', '). Press u to force." }
    if ($blocked.Count) { Write-Warning "Not checked: $($blocked -join ', '). Reason: $(Get-LimitMessage)" }
    return $failures
}

function Show-Check($Forks) {
    $state = Get-State
    $failures = 0
    foreach ($f in $Forks) {
        try {
            $info = Get-LatestInfo $f ''
            $entry = Get-Entry $state $f.id
            $current = if ($entry) { $entry.tag } else { '-' }
            $flag = if (Test-IsNew $state $f $info) { 'NEW' } else { 'up to date' }
            if ($entry -and $entry.pinned) { $flag += ' (pinned)' }
            $mb = [math]::Round($info.asset.size / 1MB, 1)
            $hash = if ($info.asset.digest) { 'sha256' } else { 'no hash' }
            Write-Host ("{0,-24} installed {1,-34} latest {2,-34} {3}  [{4}, {5} MB, {6}]" -f $f.name, $current, $info.release.tag, $flag, $info.asset.name, $mb, $hash)
        }
        catch {
            $failures++
            Write-Warning "$($f.name): $($_.Exception.Message)"
        }
    }
    return $failures
}

# --- knowledge base ------------------------------------------------------------------------------

function Read-GameRows([string]$ReadmePath) {
    $lines = [IO.File]::ReadAllLines($ReadmePath)
    $inside = $false
    $rows = New-Object Collections.ArrayList
    foreach ($line in $lines) {
        if ($line -match '^##\s+Which fork for which game') { $inside = $true; continue }
        if (-not $inside) { continue }
        if ($line -match '^##\s') { break }
        if ($line -notmatch '^\|') { continue }
        $clean = $line -replace '\[([^\]]+)\]\([^)]+\)', '$1'
        $cells = @($clean.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
        if ($cells.Count -lt 4 -or $cells[0] -eq 'Game' -or $cells[0] -match '^-+$') { continue }
        [void]$rows.Add([pscustomobject]@{ game = $cells[0]; first = $cells[1]; also = $cells[2]; evidence = $cells[3] })
    }
    if ($rows.Count -eq 0) { throw 'The wichforks README format changed: game table not found.' }
    return $rows.ToArray()
}

function Sync-Knowledge([bool]$Force = $true) {
    New-Item -ItemType Directory -Force -Path $script:CacheDir | Out-Null
    $sourceFile = Join-Path $script:CacheDir 'source.json'
    $known = Read-JsonFile $sourceFile
    if (-not $Force -and $known -and (Test-CheckedRecently 'guide')) { return $false }
    $repo = $script:Catalog.knowledge_source
    $commit = Get-JsonUrl "https://api.github.com/repos/$repo/commits/main"
    Set-Checked 'guide'
    if ($known -and $known.sha -eq $commit.sha) { return $false }

    # The guide adds new documents often: list everything in docs/ on each new commit.
    $tree = Get-JsonUrl "https://api.github.com/repos/$repo/git/trees/$($commit.sha)?recursive=1"
    $docs = @($tree.tree | Where-Object { $_.type -eq 'blob' -and $_.path -match '^docs/[^/]+\.md$' } | ForEach-Object { $_.path })
    $files = @('README.md', 'data/forks.json') + $docs
    $incoming = Join-Path $script:CacheDir '_incoming'
    Remove-Managed $incoming
    New-Item -ItemType Directory -Force -Path $incoming | Out-Null
    try {
        foreach ($file in $files) {
            $out = Join-Path $incoming (Split-Path -Leaf $file)
            Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -UserAgent 'nx-fork-manager' -OutFile $out `
                -Uri "https://raw.githubusercontent.com/$repo/$($commit.sha)/$file"
        }
        # Validate before replacing. The content is data only and is never executed.
        [void](Read-GameRows (Join-Path $incoming 'README.md'))
        [void](Read-JsonFile (Join-Path $incoming 'forks.json'))
        foreach ($file in $files) {
            $name = Split-Path -Leaf $file
            Move-Item -LiteralPath (Join-Path $incoming $name) -Destination (Join-Path $script:CacheDir $name) -Force
        }
        Write-JsonFile $sourceFile ([pscustomobject]@{ sha = $commit.sha; date = [string]$commit.commit.author.date })
    }
    finally { Remove-Managed $incoming }
    return $true
}

function Resolve-Candidates([string]$Cell) {
    $found = New-Object Collections.ArrayList
    foreach ($part in ($Cell -split '\s*;\s*|\s*,\s*|\s+or\s+')) {
        $label = $part.Trim()
        if (-not $label -or $label -ieq 'None') { continue }
        $match = $null
        foreach ($f in $script:Catalog.forks) {
            foreach ($alias in $f.aliases) {
                if ($label -match ('(?i)\b' + [regex]::Escape($alias) + '\b')) { $match = $f; break }
            }
            if ($match) { break }
        }
        [void]$found.Add([pscustomobject]@{ label = $label; fork = $match })
    }
    return $found.ToArray()
}

function Test-GpuFit($F, $GuideForks) {
    if (-not $script:Config.gpu) { return $true }
    $data = $GuideForks | Where-Object { $_.id -eq $F.wichforks_id }
    if (-not $data -or -not $data.gpu) { return $true }
    foreach ($g in $data.gpu) { if ($g -match [regex]::Escape($script:Config.gpu)) { return $true } }
    return $false
}

function Get-Games {
    $readme = Join-Path $script:CacheDir 'README.md'
    $guide = Read-JsonFile (Join-Path $script:CacheDir 'forks.json')
    $notes = Read-JsonFile $script:NotesFile
    if ($null -eq $notes) { $notes = [pscustomobject]@{} }
    $rows = if (Test-Path -LiteralPath $readme) { @(Read-GameRows $readme) } else { @() }
    $guideForks = if ($guide) { $guide.forks } else { @() }

    $names = New-Object Collections.ArrayList
    foreach ($r in $rows) { [void]$names.Add($r.game) }
    foreach ($p in $notes.PSObject.Properties) { if (-not $names.Contains($p.Name)) { [void]$names.Add($p.Name) } }

    $games = foreach ($name in $names) {
        $row = $rows | Where-Object { $_.game -eq $name } | Select-Object -First 1
        $candidates = @()
        if ($row) { $candidates = @(Resolve-Candidates $row.first) + @(Resolve-Candidates $row.also) }
        $noteProp = $notes.PSObject.Properties[$name]
        $note = if ($noteProp) { $noteProp.Value } else { $null }

        $pick = $null
        $pickSource = ''
        if ($note -and $note.fork) {
            # A removed fork in an old note falls back to the guide.
            $pick = $script:Catalog.forks | Where-Object { $_.id -eq $note.fork } | Select-Object -First 1
            if ($pick) { $pickSource = 'my choice' }
        }
        $outside = $null
        if (-not $pick) {
            foreach ($c in $candidates) {
                if (-not $c.fork) { $outside = $c.label; break }
                # The guide sometimes names a specific version ("Selevet perf 3/4"): keep its text.
                if (Test-GpuFit $c.fork $guideForks) { $pick = $c.fork; $pickSource = "guide: $($c.label)"; break }
            }
        }
        [pscustomobject]@{
            game       = $name
            fork       = $pick
            source     = $pickSource
            outside    = $outside
            candidates = $candidates
            evidence   = if ($row) { $row.evidence } else { '' }
            note       = $note
        }
    }
    return @($games)
}

function Get-PickLabel($Game) {
    if ($Game.fork) { return "$($Game.fork.name) ($($Game.source))" }
    if ($Game.outside) { return "$($Game.outside) (not managed here)" }
    return '-'
}

function Write-Base {
    $state = Get-State
    $source = Read-JsonFile (Join-Path $script:CacheDir 'source.json')
    $gpu = if ($script:Config.gpu) { $script:Config.gpu } else { 'none' }
    $games = @(Get-Games)
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('# Best fork per game')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('Generated file. Do not edit it: record results from the menu (`ForkManager.cmd`) or in `data/my-notes.json`.')
    [void]$sb.AppendLine()
    if ($source) {
        [void]$sb.AppendLine("Guide: [$($script:Catalog.knowledge_source)](https://github.com/$($script:Catalog.knowledge_source)), commit ``$($source.sha.Substring(0,10))`` from $($source.date). GPU filter: $gpu.")
    }
    else { [void]$sb.AppendLine('Guide not synced yet.') }
    [void]$sb.AppendLine('The guide collects community reports, not controlled benchmarks. Your own notes beat it on your machine.')
    [void]$sb.AppendLine('Details: [reported performance](data/wichforks/PERFORMANCE.md), [project notes](data/wichforks/PROJECT-NOTES.md), [full guide](data/wichforks/README.md).')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| Game | Recommended | Installed | Alternatives | Guide evidence |')
    [void]$sb.AppendLine('|---|---|---|---|---|')
    foreach ($g in $games) {
        $status = '-'
        if ($g.fork) {
            $entry = Get-Entry $state $g.fork.id
            $status = if ($entry -and (Test-Installed $state $g.fork)) { $entry.tag } else { 'not installed' }
        }
        $others = @($g.candidates | Where-Object { -not ($g.fork -and $_.fork -and $_.fork.id -eq $g.fork.id) } | ForEach-Object { $_.label }) -join '; '
        [void]$sb.AppendLine("| $($g.game) | $(Get-PickLabel $g) | $status | $others | $($g.evidence) |")
    }
    $withNotes = @($games | Where-Object { $_.note })
    if ($withNotes.Count) {
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('## My notes')
        foreach ($g in $withNotes) {
            [void]$sb.AppendLine()
            [void]$sb.AppendLine("### $($g.game)")
            foreach ($h in $g.note.history) {
                [void]$sb.AppendLine("- $($h.date), $($h.fork) $($h.tag): $($h.note)")
            }
        }
    }
    [IO.File]::WriteAllText($script:GamesFile, $sb.ToString(), $script:Utf8)
}

function Add-Note([string]$Game, $F, [string]$Text, [bool]$Prefer) {
    $notes = Read-JsonFile $script:NotesFile
    if ($null -eq $notes) { $notes = [pscustomobject]@{} }
    $state = Get-State
    $entry = Get-Entry $state $F.id
    $item = [pscustomobject]@{
        date = (Get-Date).ToString('yyyy-MM-dd')
        fork = $F.id
        tag  = if ($entry) { $entry.tag } else { '?' }
        note = $Text
    }
    $existing = $notes.PSObject.Properties[$Game]
    if ($existing) {
        $existing.Value.history = @($item) + @($existing.Value.history)
        if ($Prefer) { $existing.Value.fork = $F.id }
    }
    else {
        $forkValue = if ($Prefer) { $F.id } else { $null }
        Set-Prop $notes $Game ([pscustomobject]@{ fork = $forkValue; history = @($item) })
    }
    Write-JsonFile $script:NotesFile $notes
    Write-Base
}

# --- add a fork from a link ----------------------------------------------------------------------

# Turns an asset name into a rule that also matches future builds:
# numbers become \d+, commit hashes become [0-9a-f]+, the rest stays literal.
function ConvertTo-NamePattern([string]$Name) {
    $sb = New-Object Text.StringBuilder '^'
    $pos = 0
    foreach ($m in [regex]::Matches($Name, '[0-9A-Fa-f]{7,}|\d+[a-z]?(?![a-zA-Z])|\d+')) {
        [void]$sb.Append([regex]::Escape($Name.Substring($pos, $m.Index - $pos)))
        $v = $m.Value
        $next = $m.Index + $m.Length
        $letterNext = $next -lt $Name.Length -and [char]::IsLetter($Name[$next])
        if ($v -match '^\d+$' -and $letterNext) { [void]$sb.Append('\d+') }
        elseif ($v -match '^\d+[a-z]?$') { [void]$sb.Append('\d+[a-z]?') }
        elseif ($v -match '\d' -and $v -match '[A-Fa-f]') { [void]$sb.Append('[0-9a-fA-F]+') }
        else { [void]$sb.Append([regex]::Escape($v)) }
        $pos = $next
    }
    [void]$sb.Append([regex]::Escape($Name.Substring($pos))).Append('$')
    return $sb.ToString()
}

# Picks the Windows build among release assets or Actions artifacts. Prefers MSVC, avoids PGO and debug files.
function Select-WindowsAsset($Assets, [bool]$Artifact) {
    $best = $null
    $bestScore = -1
    foreach ($a in $Assets) {
        $n = [string]$a.name
        if (-not $Artifact -and $n -notmatch '(?i)\.zip$') { continue }
        if ($n -match '(?i)linux|macos|\bmac\b|osx|darwin|android|\.apk|arm64|aarch64|appimage|source|\bsrc\b|symbols|pdb|debug|exe-only') { continue }
        $score = 0
        if ($n -match '(?i)win|msvc|x86_64|x64|amd64') { $score += 10 }
        if ($n -match '(?i)msvc') { $score += 2 }
        if ($n -match '(?i)pgo') { $score -= 3 }
        if ($Artifact -and $score -lt 7) { continue }
        if ($score -gt $bestScore) { $best = $a; $bestScore = $score }
    }
    return $best
}

function Get-FreeForkId([string[]]$Choices) {
    $taken = @($script:Catalog.forks | ForEach-Object { $_.id })
    foreach ($c in $Choices) { if ($taken -notcontains $c) { return $c } }
    for ($i = 2; ; $i++) { if ($taken -notcontains "$($Choices[-1])-$i") { return "$($Choices[-1])-$i" } }
}

function New-ForkFromUrl([string]$Link) {
    $Link = $Link.Trim().Trim('"')
    if ($Link -notmatch '^https?://([^/]+)/([^/]+)/([^/?#]+)(.*)$') {
        throw "Not a repository link: $Link. Example: https://github.com/owner/repo"
    }
    $hostName = $Matches[1].ToLower() -replace '^www\.', ''
    $owner = $Matches[2]
    $repoName = $Matches[3] -replace '\.git$', ''
    $rest = $Matches[4]
    $repo = "$owner/$repoName"

    $f = [ordered]@{ id = $null; name = $null }
    if ($hostName -eq 'github.com') {
        if ($rest -match '/actions/workflows/([^/?#]+)') {
            $f.source = 'actions'
            $f.repo = $repo
            $f.workflow = $Matches[1]
            $f.branch = $null
        }
        else {
            $f.source = 'github'
            $f.repo = $repo
        }
    }
    else {
        $f.source = 'forgejo'
        $f.host = $hostName
        $f.repo = $repo
    }
    $f = [pscustomobject]$f

    $same = @($script:Catalog.forks | Where-Object {
            $_.repo -ieq $repo -and $_.source -eq $f.source -and ($f.source -ne 'actions' -or $_.workflow -eq $f.workflow)
        })
    if ($same.Count) { throw "This fork is already in the list: $($same[0].name) (id $($same[0].id))." }

    # Find the Windows build and turn its name into a rule for future builds.
    $asset = $null
    if ($f.source -eq 'actions') {
        $runs = (Get-JsonUrl "https://api.github.com/repos/$repo/actions/workflows/$($f.workflow)/runs?status=success&per_page=5").workflow_runs
        foreach ($run in $runs) {
            $arts = @((Get-JsonUrl "https://api.github.com/repos/$repo/actions/runs/$($run.id)/artifacts?per_page=50").artifacts | Where-Object { -not $_.expired })
            $asset = Select-WindowsAsset $arts $true
            if ($asset) { break }
        }
        if (-not $asset) { throw "No recent successful run of $($f.workflow) has a Windows artifact." }
    }
    else {
        try { $releases = Get-Releases $f }
        catch {
            if ($f.source -eq 'forgejo') { throw "Could not read releases from $hostName. Only GitHub and Forgejo/Gitea hosts work. ($($_.Exception.Message))" }
            throw
        }
        foreach ($r in $releases) {
            $asset = Select-WindowsAsset $r.assets $false
            if ($asset) { break }
        }
        if (-not $asset) {
            $hint = if ($f.source -eq 'github') { ' If it only publishes GitHub Actions builds, paste the workflow link instead (https://github.com/owner/repo/actions/workflows/<file>.yml).' } else { '' }
            throw "No release of $repo has a Windows .zip.$hint"
        }
    }
    Set-Prop $f 'include' (ConvertTo-NamePattern ([string]$asset.name))
    Set-Prop $f 'exclude' $null

    # The guide lists many forks: reuse its name and id, so the GPU filter and game table know this fork.
    $guide = Read-JsonFile (Join-Path $script:CacheDir 'forks.json')
    $known = $null
    if ($guide) { $known = $guide.forks | Where-Object { ([string]$_.repo).TrimEnd('/') -ieq "https://$hostName/$repo" } | Select-Object -First 1 }
    $name = if ($known) { [string]$known.name } else { "$repoName ($owner)" }
    if ($f.source -eq 'actions') { $name += ' (git build)' }
    $f.name = $name
    $slugOwner = ($owner.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    $slugRepo = ($repoName.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    $suffix = if ($f.source -eq 'actions') { '-git' } else { '' }
    $f.id = Get-FreeForkId @("$slugOwner$suffix", "$slugOwner-$slugRepo$suffix")
    # Words the guide's game table may use for this fork: owner, first word of the repo and of the guide name.
    $aliases = New-Object Collections.ArrayList
    $words = @($owner, ($repoName -split '[-_ .]')[0])
    if ($known) { $words += ([string]$known.name -split '[ (]')[0] }
    foreach ($w in $words) {
        if ($w -and $w.Length -ge 3 -and $w -notmatch '^(?i)(eglantine|lichii|eden|yuzu|sudachi|citron|nx2?|emu|switch)$' -and -not ($aliases -contains $w)) { [void]$aliases.Add($w) }
    }
    Set-Prop $f 'aliases' @($aliases)
    Set-Prop $f 'wichforks_id' $(if ($known) { [string]$known.id } else { $null })

    # Prove the rule finds the same build before saving it.
    $latest = Get-LatestInfo $f ''
    return [pscustomobject]@{ fork = $f; latest = $latest }
}

function Add-CustomFork([string]$Link) {
    $result = New-ForkFromUrl $Link
    $mine = Read-JsonFile $script:MyForksFile
    if ($null -eq $mine) { $mine = [pscustomobject]@{ forks = @() } }
    $mine.forks = @($mine.forks) + @($result.fork)
    Write-JsonFile $script:MyForksFile $mine
    $script:Catalog = Import-Catalog
    $number = @($script:Catalog.forks).Count
    Write-Host "Added $($result.fork.name) as fork $number (id $($result.fork.id))."
    Write-Host "  Latest build: $($result.latest.release.tag), file $($result.latest.asset.name)."
    Write-Host "  File rule: $($result.fork.include)  (edit my-forks.json to change it)"
    return $result.fork
}

# Removes a fork you added, with its installed files. Forks that ship with the tool stay.
function Remove-CustomFork($F) {
    if ($script:CustomIds -notcontains $F.id) { throw "$($F.name) ships with the tool and cannot be removed here. Just do not open it: forks you never open use no disk space." }
    $dest = Get-ForkDir $F.id
    $running = @(Get-RunningUnder $dest)
    if ($running.Count) { throw "$($F.name) is running ($($running[0].Name)). Close it and try again." }
    Remove-Managed $dest
    Remove-Managed (Get-PrevForkDir $F.id)
    Remove-Managed (Get-ZipForkDir $F.id)
    $state = Get-State
    if ($state.PSObject.Properties[$F.id]) { $state.PSObject.Properties.Remove($F.id); Write-JsonFile $script:StateFile $state }
    $mine = Read-JsonFile $script:MyForksFile
    $mine.forks = @($mine.forks | Where-Object { $_.id -ne $F.id })
    Write-JsonFile $script:MyForksFile $mine
    $script:Catalog = Import-Catalog
    Write-Host "Removed $($F.name) and its installed files."
}

# --- open and menu -------------------------------------------------------------------------------

function Open-Fork($F) {
    $state = Get-State
    if (-not (Test-Installed $state $F)) {
        Write-Host "$($F.name) is not installed. Installing..."
        Install-Release $F (Get-LatestInfo $F '')
        Set-Checked $F.id
        $state = Get-State
        Write-Base
    }
    $entry = Get-Entry $state $F.id
    $dir = Get-ForkDir $F.id
    Write-Host "Opening $($F.name) ($($entry.tag))."
    Start-Process -FilePath (Join-Path $dir $entry.exe) -WorkingDirectory $dir | Out-Null
}

function Set-Pin($F, [bool]$Value) {
    $state = Get-State
    $entry = Get-Entry $state $F.id
    if (-not $entry) { throw "$($F.name) is not installed." }
    Set-Prop $entry 'pinned' $Value
    Write-JsonFile $script:StateFile $state
    if ($Value) { Write-Host "$($F.name) pinned on $($entry.tag)." } else { Write-Host "$($F.name) unpinned: it gets updates again." }
}

function Show-Status {
    $state = Get-State
    Write-Host ''
    Write-Host 'FORKS'
    $i = 0
    foreach ($f in $script:Catalog.forks) {
        $i++
        $entry = Get-Entry $state $f.id
        $label = 'not installed'
        if ($entry -and (Test-Installed $state $f)) {
            $label = $entry.tag
            if ($entry.pinned) { $label += ' [pinned]' }
            if ($entry.previous) { $label += " (previous: $($entry.previous.tag))" }
        }
        $shown = if ($script:CustomIds -contains $f.id) { "$($f.name) *" } else { $f.name }
        Write-Host ('  {0,2}  {1,-24} {2}' -f $i, $shown, $label)
    }
    if ($script:CustomIds.Count) { Write-Host '      * added by you' }
    Write-Host ''
    Write-Host 'GAMES'
    $i = 0
    foreach ($g in (Get-Games)) {
        $i++
        Write-Host ('  g{0,-2} {1,-36} {2}' -f $i, $g.game, (Get-PickLabel $g))
    }
}

function Get-GameByNumber([string]$Number) {
    $games = @(Get-Games)
    $i = [int]$Number
    if ($i -lt 1 -or $i -gt $games.Count) { throw "No game number $Number." }
    return $games[$i - 1]
}

function Invoke-Menu {
    Write-Host 'Checking the guide and installed forks...'
    try { if (Sync-Knowledge $false) { Write-Host 'Guide updated.' } }
    catch { Write-Warning "Guide sync failed, using the local copy: $($_.Exception.Message)" }
    [void](Update-Forks (Get-InstalledForks (Get-State)) $false)
    Write-Base

    while ($true) {
        Show-Status
        Write-Host ''
        Write-Host '  2    open fork 2 (installs it first if needed)   g3  open the recommended fork for game 3'
        Write-Host '  n3   add a note for game 3   r1  roll back fork 1   p1  pin or unpin fork 1'
        Write-Host '  a    add a fork from a link   x5  remove fork 5 (only forks you added)'
        Write-Host "  z    zip backups (now: $(Get-ZipBackupLabel))"
        Write-Host '  u    update now   b  open GAMES.md   q  quit'
        $choice = (Read-Host 'Choice').Trim().ToLower()
        try {
            if ($choice -eq 'q') { return }
            elseif ($choice -eq 'a') {
                $link = Read-Host 'Paste the fork link (GitHub, Forgejo, or a GitHub Actions workflow)'
                if (-not $link.Trim()) { continue }
                $added = Add-CustomFork $link
                if ((Read-Host 'Install and open it now? (y/n)').Trim().ToLower() -eq 'y') {
                    Open-Fork $added
                    return
                }
            }
            elseif ($choice -match '^x(\d+)$') {
                $f = Get-ForkByNumber $Matches[1]
                if ($script:CustomIds -notcontains $f.id) { throw "$($f.name) ships with the tool and cannot be removed here." }
                if ((Read-Host "Remove $($f.name) and delete its installed files? (y/n)").Trim().ToLower() -eq 'y') {
                    Remove-CustomFork $f
                    Write-Base
                }
            }
            elseif ($choice -eq 'u') {
                try { [void](Sync-Knowledge) } catch { Write-Warning $_.Exception.Message }
                [void](Update-Forks (Get-InstalledForks (Get-State)))
                Write-Base
            }
            elseif ($choice -eq 'z') {
                Write-Host "Downloaded zips are kept in $script:ZipDir\<fork>. Now: $(Get-ZipBackupLabel)."
                $value = Read-Host 'Zips to keep per fork: 0 = none, a number, or all (Enter = no change)'
                if ($value.Trim()) { Set-ZipBackups $value }
            }
            elseif ($choice -eq 'b') { Start-Process -FilePath $script:GamesFile | Out-Null }
            elseif ($choice -match '^(\d+)$') {
                Open-Fork (Get-ForkByNumber $Matches[1])
                return
            }
            elseif ($choice -match '^r(\d+)$') { Restore-Previous (Get-ForkByNumber $Matches[1]); Write-Base }
            elseif ($choice -match '^p(\d+)$') {
                $f = Get-ForkByNumber $Matches[1]
                $entry = Get-Entry (Get-State) $f.id
                if (-not $entry) { throw "$($f.name) is not installed." }
                Set-Pin $f (-not $entry.pinned)
            }
            elseif ($choice -match '^g(\d+)$') {
                $g = Get-GameByNumber $Matches[1]
                if (-not $g.fork) { Write-Warning "$($g.game): the recommendation is not managed here ($($g.outside))."; continue }
                Open-Fork $g.fork
                return
            }
            elseif ($choice -match '^n(\d+)$') {
                $g = Get-GameByNumber $Matches[1]
                $f = Get-ForkByNumber (Read-Host "Number of the fork you tested with $($g.game)")
                $text = Read-Host 'Result (fps, bugs, crashes)'
                $prefer = (Read-Host 'Make this fork the default for this game? (y/n)').Trim().ToLower() -eq 'y'
                Add-Note $g.game $f $text $prefer
            }
            else { Write-Warning 'Unknown choice.' }
        }
        catch { Write-Warning $_.Exception.Message }
    }
}

# Lets tests load the functions without running an action.
if ($MyInvocation.InvocationName -eq '.') { return }

# --- entry point ---------------------------------------------------------------------------------

New-Item -ItemType Directory -Force -Path $script:ForksDir | Out-Null
$selected = if ($Fork) { Get-ForkById $Fork } else { $null }
$failed = 0
try {
    switch ($Action) {
        'Menu' { Invoke-Menu }
        'Status' { Show-Status }
        'Sync' {
            $changed = Sync-Knowledge
            Write-Base
            if ($changed) { Write-Host 'Guide updated.' } else { Write-Host 'Guide was already up to date.' }
        }
        'Check' {
            $list = if ($selected) { @($selected) } else { $script:Catalog.forks }
            $failed = Show-Check $list
        }
        'Update' {
            $list = if ($selected) { @($selected) } else { Get-InstalledForks (Get-State) }
            $failed = Update-Forks $list
            Write-Base
        }
        'Install' {
            if (-not $selected) { throw 'Install needs -Fork.' }
            Install-Release $selected (Get-LatestInfo $selected $Tag)
            Write-Base
        }
        'Rollback' {
            if (-not $selected) { throw 'Rollback needs -Fork.' }
            Restore-Previous $selected
            Write-Base
        }
        'Pin' { if (-not $selected) { throw 'Pin needs -Fork.' }; Set-Pin $selected $true; Write-Base }
        'Unpin' { if (-not $selected) { throw 'Unpin needs -Fork.' }; Set-Pin $selected $false; Write-Base }
        'Open' { if (-not $selected) { throw 'Open needs -Fork.' }; Open-Fork $selected }
        'Add' { if (-not $Url) { throw 'Add needs -Url.' }; [void](Add-CustomFork $Url) }
        'Remove' { if (-not $selected) { throw 'Remove needs -Fork.' }; Remove-CustomFork $selected; Write-Base }
    }
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
if ($failed) { exit 1 }
