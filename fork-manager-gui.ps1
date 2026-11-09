# nx-fork-manager GUI: a window for everything the menu does. All the work stays in fork-manager.ps1:
# this script loads it, calls its functions, and runs downloads and updates in a background runspace
# so the window stays responsive. Uses only WPF, which ships with Windows. Start it with ForkManager-GUI.cmd.

$ErrorActionPreference = 'Stop'

# WPF needs a single-threaded apartment. Windows PowerShell started with -Sta (the .cmd does) already is.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-Sta', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") -WindowStyle Hidden
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$script:FmPath = Join-Path $PSScriptRoot 'fork-manager.ps1'
try {
    . $script:FmPath
}
catch {
    [Windows.MessageBox]::Show("fork-manager.ps1 could not be loaded:`n`n$($_.Exception.Message)", 'NX Fork Manager', 'OK', 'Error') | Out-Null
    return
}
$ErrorActionPreference = 'Stop'
$script:GuiPath = $PSCommandPath

# ---------------------------------------------------------------------------------------------------------------
# App updates: keeps this tool itself on the newest commit of its GitHub repository (the project publishes no
# releases, only commits). Loaded into the window and into every background job, so both can use it.
#   config.json: app_repo (default Schroederr/nx-fork-manager), app_branch (main), app_backup (true),
#                check_app_updates_on_start (true), check_forks_on_start (true)

$script:AppUpdateCode = @'
$script:AppVersionFile = Join-Path $script:DataDir 'app-version.json'
$script:AppBackupDir = Join-Path $script:DataDir 'app-backups'
$script:AppKeep = 3
$script:Latin1 = [Text.Encoding]::GetEncoding(28591)   # bytes <-> text one to one, for line ending changes

function Get-ConfigFlag([string]$Name, [bool]$Default) {
    $p = $script:Config.PSObject.Properties[$Name]
    if (-not $p -or $null -eq $p.Value) { return $Default }
    return [bool]$p.Value
}

function Get-AppSource {
    $repo = [string]$script:Config.app_repo
    $branch = [string]$script:Config.app_branch
    return [pscustomobject]@{
        Repo   = if ($repo) { $repo } else { 'Schroederr/nx-fork-manager' }
        Branch = if ($branch) { $branch } else { 'main' }
    }
}

# Your settings, forks and data are never part of an update.
function Test-AppProtected([string]$Path) {
    return $Path -match '^(config\.json|my-forks\.json|GAMES\.md|data/|forks/|\.git/)'
}

function ConvertTo-Lf([byte[]]$Bytes) {
    if ($Bytes -contains [byte]0) { return $Bytes }   # binary: as is
    return $script:Latin1.GetBytes($script:Latin1.GetString($Bytes).Replace("`r`n", "`n"))
}

# The SHA-1 git gives a file (a "blob"). The repository stores text with LF endings, so CRLF on disk is
# hashed as LF: a file checked out on Windows matches its blob.
function Get-GitBlobSha([string]$File) {
    $b = ConvertTo-Lf ([IO.File]::ReadAllBytes($File))
    $head = [Text.Encoding]::ASCII.GetBytes("blob $($b.Length)`0")
    $all = New-Object byte[] ($head.Length + $b.Length)
    [Array]::Copy($head, $all, $head.Length)
    [Array]::Copy($b, 0, $all, $head.Length, $b.Length)
    $sha = [Security.Cryptography.SHA1]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($all)) -replace '-').ToLower() }
    finally { $sha.Dispose() }
}

function Format-AppDate($Value) {
    try { return ([DateTime]$Value).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { return [string]$Value }
}

# A commit's one-line title; a merged pull request shows as "PR #6: its title".
function Get-CommitTitle([string]$Message) {
    $lines = @($Message -split "`r?`n" | Where-Object { $_.Trim() })
    if ($lines.Count -gt 1 -and $lines[0] -match '^Merge pull request (#\d+)') { return "PR $($Matches[1]): $($lines[1].Trim())" }
    return $lines[0]
}

# Compares the tool's files with the newest commit. Two API requests (commit and file list), three with a
# known previous version (the list of commits in between).
function Get-AppUpdateInfo {
    $src = Get-AppSource
    $commit = Get-JsonUrl "https://api.github.com/repos/$($src.Repo)/commits/$($src.Branch)"
    $tree = Get-JsonUrl "https://api.github.com/repos/$($src.Repo)/git/trees/$($commit.sha)?recursive=1"
    $changed = New-Object Collections.ArrayList
    foreach ($t in $tree.tree) {
        if ($t.type -ne 'blob' -or (Test-AppProtected $t.path)) { continue }
        $local = Join-Path $script:Here ($t.path -replace '/', '\')
        if (-not (Test-Path -LiteralPath $local)) { [void]$changed.Add("$($t.path) (new)"); continue }
        if ((Get-GitBlobSha $local) -ne $t.sha) { [void]$changed.Add($t.path) }
    }
    $known = Read-JsonFile $script:AppVersionFile
    $date = Format-AppDate $commit.commit.committer.date
    if (-not $changed.Count -and -not ($known -and $known.sha -eq $commit.sha)) {
        # The files are the newest version (for example after git pull): remember which one that is.
        Write-JsonFile $script:AppVersionFile ([pscustomobject]@{ sha = $commit.sha; date = $date; updated = (Get-Date).ToString('yyyy-MM-dd HH:mm') })
    }
    $commits = @()
    if ($changed.Count -and $known -and $known.sha -and $known.sha -ne $commit.sha) {
        try {
            $cmp = Get-JsonUrl "https://api.github.com/repos/$($src.Repo)/compare/$($known.sha)...$($commit.sha)"
            $all = @($cmp.commits | ForEach-Object {
                    [pscustomobject]@{ sha = $_.sha.Substring(0, 7); date = (Format-AppDate $_.commit.committer.date); title = (Get-CommitTitle $_.commit.message) }
                })
            # A merged pull request also brings its own commits: list the PR once, by its title.
            $prTitles = @($all | Where-Object { $_.title -match '^PR #\d+: ' } | ForEach-Object { $_.title -replace '^PR #\d+: ', '' })
            $commits = @($all | Where-Object { $_.title -match '^PR #\d+: ' -or $prTitles -notcontains $_.title })
            [array]::Reverse($commits)
        }
        catch { $commits = @() }
    }
    if (-not $commits.Count) { $commits = @([pscustomobject]@{ sha = $commit.sha.Substring(0, 7); date = $date; title = (Get-CommitTitle $commit.commit.message) }) }
    $state = if ($changed.Count) { "update available: $($changed.Count) file(s) differ" } else { 'up to date' }
    Write-Host "App: $($src.Repo) $($src.Branch) is at $($commit.sha.Substring(0, 7)) ($date); $state."
    return [pscustomobject]@{
        Kind = 'app'; Repo = $src.Repo; Branch = $src.Branch; Sha = $commit.sha; Date = $date
        Changed = @($changed); Commits = $commits; UpToDate = ($changed.Count -eq 0)
    }
}

function Get-EolRules([string]$Root) {
    $rules = @{}
    $ga = Join-Path $Root '.gitattributes'
    if (Test-Path -LiteralPath $ga) {
        foreach ($l in [IO.File]::ReadAllLines($ga)) {
            if ($l -match '^\*(\.[\w-]+)\s.*\beol=(crlf|lf)\b') { $rules[$Matches[1].ToLower()] = $Matches[2] }
        }
    }
    return $rules
}

# Writes through a temporary file, so a crash never leaves half a file.
function Write-AppFile([string]$Path, [byte[]]$Bytes) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    [IO.File]::WriteAllBytes("$Path.new", $Bytes)
    Move-Item -LiteralPath "$Path.new" -Destination $Path -Force
}

function Get-AppBackups {
    if (-not (Test-Path -LiteralPath $script:AppBackupDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $script:AppBackupDir -Directory | Sort-Object Name -Descending | ForEach-Object {
            $m = Read-JsonFile (Join-Path $_.FullName 'backup.json')
            if ($m) { [pscustomobject]@{ Name = $_.Name; Dir = $_.FullName; Sha = [string]$m.sha; Date = [string]$m.date; Created = [string]$m.created; Files = @($m.files) } }
        })
}

# Copies the current version of these files (paths with /) to data\app-backups and keeps the newest $AppKeep.
function Save-AppBackup([string[]]$RelPaths, [string]$Reason) {
    $known = Read-JsonFile $script:AppVersionFile
    $sha = if ($known -and $known.sha) { [string]$known.sha } else { '' }
    $name = (Get-Date -Format 'yyyy-MM-dd_HHmmss') + '_' + $(if ($sha) { $sha.Substring(0, 7) } else { 'unknown' })
    $dir = Join-Path $script:AppBackupDir $name
    $saved = New-Object Collections.ArrayList
    foreach ($rel in $RelPaths) {
        $from = Join-Path $script:Here ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $from -PathType Leaf)) { continue }
        $to = Join-Path $dir ($rel -replace '/', '\')
        New-Item -ItemType Directory -Force -Path (Split-Path $to -Parent) | Out-Null
        Copy-Item -LiteralPath $from -Destination $to -Force
        [void]$saved.Add($rel)
    }
    Write-JsonFile (Join-Path $dir 'backup.json') ([pscustomobject]@{
            sha = $sha; date = $(if ($known) { [string]$known.date } else { '' }); created = (Get-Date).ToString('yyyy-MM-dd HH:mm'); reason = $Reason; files = @($saved)
        })
    Write-Host "  Backup of the current version: $($saved.Count) files in data\app-backups\$name"
    $root = [IO.Path]::GetFullPath($script:AppBackupDir).TrimEnd('\') + '\'
    foreach ($old in @(Get-ChildItem -LiteralPath $script:AppBackupDir -Directory | Sort-Object Name -Descending | Select-Object -Skip $script:AppKeep)) {
        if ($old.FullName.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $old.FullName -Recurse -Force }
    }
}

# Downloads the commit as a zip and replaces the tool's files with it.
function Install-AppUpdate([string]$Sha, [bool]$Backup) {
    $src = Get-AppSource
    New-Item -ItemType Directory -Force -Path $script:TmpDir | Out-Null
    $work = Join-Path $script:TmpDir 'app-update'
    $zip = "$work.zip"
    Remove-Managed $work
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    try {
        Write-Host "  Downloading $($src.Repo) at $($Sha.Substring(0, 7))..."
        Invoke-Download "https://api.github.com/repos/$($src.Repo)/zipball/$Sha" $zip ([bool]$env:GITHUB_TOKEN)
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $work)
        $root = @(Get-ChildItem -LiteralPath $work -Directory)[0].FullName
        $prefix = $root.TrimEnd('\').Length + 1
        $files = @(Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { $_.FullName.Substring($prefix) -replace '\\', '/' } |
                Where-Object { -not (Test-AppProtected $_) })
        if ($files -notcontains 'fork-manager.ps1') { throw 'The download does not look like nx-fork-manager (no fork-manager.ps1). Nothing was changed.' }
        if ($Backup) { Save-AppBackup $files "before updating to $($Sha.Substring(0, 7))" }
        $rules = Get-EolRules $root
        foreach ($rel in $files) {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $root ($rel -replace '/', '\')))
            $dest = Join-Path $script:Here ($rel -replace '/', '\')
            $eol = $rules[[IO.Path]::GetExtension($rel).ToLower()]
            if (-not $eol -and (Test-Path -LiteralPath $dest)) {
                # No rule for this file: keep the line endings it has now (what git chose for this folder).
                $now = [IO.File]::ReadAllBytes($dest)
                if ($now -notcontains [byte]0) { $eol = if ($script:Latin1.GetString($now).Contains("`r`n")) { 'crlf' } else { 'lf' } }
            }
            if ($eol) {
                $bytes = ConvertTo-Lf $bytes
                if ($eol -eq 'crlf' -and $bytes -notcontains [byte]0) { $bytes = $script:Latin1.GetBytes($script:Latin1.GetString($bytes).Replace("`n", "`r`n")) }
            }
            Write-AppFile $dest $bytes
        }
        $commit = Get-JsonUrl "https://api.github.com/repos/$($src.Repo)/commits/$Sha"
        Write-JsonFile $script:AppVersionFile ([pscustomobject]@{ sha = $Sha; date = (Format-AppDate $commit.commit.committer.date); updated = (Get-Date).ToString('yyyy-MM-dd HH:mm') })
        Write-Host "  OK: NX Fork Manager updated to $($Sha.Substring(0, 7)) ($($files.Count) files). Restart it to use the new version."
    }
    finally {
        Remove-Managed $work
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    }
}

# Puts a backup's files back. The current files are backed up first (when backups are on), so this can be undone.
function Restore-AppBackup([string]$Name, [bool]$Backup) {
    $b = @(Get-AppBackups | Where-Object { $_.Name -eq $Name })[0]
    if (-not $b) { throw "Backup $Name not found." }
    # Read everything first: the new backup below may remove the oldest one.
    $content = @{}
    foreach ($rel in $b.Files) { $content[$rel] = [IO.File]::ReadAllBytes((Join-Path $b.Dir ($rel -replace '/', '\'))) }
    if ($Backup) { Save-AppBackup @($b.Files) "before restoring $Name" }
    foreach ($rel in $content.Keys) { Write-AppFile (Join-Path $script:Here ($rel -replace '/', '\')) $content[$rel] }
    Write-JsonFile $script:AppVersionFile ([pscustomobject]@{ sha = $b.Sha; date = $b.Date; updated = (Get-Date).ToString('yyyy-MM-dd HH:mm') })
    $label = if ($b.Sha) { $b.Sha.Substring(0, 7) } else { 'an unknown version' }
    Write-Host "  OK: restored $label from the backup of $($b.Created) ($($content.Count) files). Restart to use it."
}
'@
. ([scriptblock]::Create($script:AppUpdateCode))

# The window needs a fork-manager.ps1 of its own version. An older one (a hand-copied file, or a restored backup
# from before the window existed) lacks functions it calls: offer to update instead of failing later.
$needed = 'Get-BuildTypeLabel', 'Get-HiddenInstalled', 'Get-VariantLabel', 'Get-Nx2Switches', 'Add-Nx2Lines', 'Update-Nx2All',
'Complete-Nx2Notes', 'Set-Nx2Note', 'Set-BuildType', 'Remove-Build', 'Get-ZipBackupLimit', 'Set-ZipBackups', 'Get-ZipBackupLabel'
$missing = @($needed | Where-Object { -not (Get-Command $_ -CommandType Function -ErrorAction SilentlyContinue) })
if ($missing.Count) {
    $q = [Windows.MessageBox]::Show("fork-manager.ps1 is older than this window (missing: $($missing -join ', ')).`n`nUpdate NX Fork Manager to the newest version from GitHub now? A backup of the current files is made first.`n`nOr choose No and use ForkManager.cmd.", 'NX Fork Manager', 'YesNo', 'Warning')
    if ($q -ne 'Yes') { return }
    try {
        $info = Get-AppUpdateInfo
        Install-AppUpdate $info.Sha $true 6>$null
        [Windows.MessageBox]::Show("Updated to $($info.Sha.Substring(0, 7)). The window opens again now.", 'NX Fork Manager', 'OK', 'Information') | Out-Null
        Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-Sta', '-ExecutionPolicy', 'Bypass', '-File', "`"$script:GuiPath`"") -WindowStyle Hidden
    }
    catch { [Windows.MessageBox]::Show("The update failed:`n`n$($_.Exception.Message)", 'NX Fork Manager', 'OK', 'Error') | Out-Null }
    return
}

# ---------------------------------------------------------------------------------------------------------------
# Theme

$script:Styles = @'
<SolidColorBrush x:Key="Bg" Color="#1B1C20"/>
<SolidColorBrush x:Key="Side" Color="#141518"/>
<SolidColorBrush x:Key="Card" Color="#24262B"/>
<SolidColorBrush x:Key="Card2" Color="#2E3137"/>
<SolidColorBrush x:Key="Line" Color="#363940"/>
<SolidColorBrush x:Key="Fg" Color="#E8E9EC"/>
<SolidColorBrush x:Key="Sub" Color="#9CA3AF"/>
<SolidColorBrush x:Key="Accent" Color="#4F8CFF"/>
<SolidColorBrush x:Key="Danger" Color="#F2555A"/>

<Style x:Key="Btn" TargetType="Button">
  <Setter Property="Foreground" Value="#E8E9EC"/>
  <Setter Property="Background" Value="#2E3137"/>
  <Setter Property="BorderBrush" Value="#3B3F47"/>
  <Setter Property="Padding" Value="14,7"/>
  <Setter Property="Margin" Value="0,0,8,8"/>
  <Setter Property="VerticalAlignment" Value="Center"/>
  <Setter Property="FontSize" Value="13"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Grid>
          <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="7"/>
          <Border x:Name="hover" Background="White" Opacity="0" CornerRadius="7"/>
          <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Grid>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="hover" Property="Opacity" Value="0.07"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="hover" Property="Opacity" Value="0.14"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="Button" BasedOn="{StaticResource Btn}"/>
<Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Btn}">
  <Setter Property="Background" Value="#4F8CFF"/>
  <Setter Property="BorderBrush" Value="#4F8CFF"/>
  <Setter Property="Foreground" Value="White"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
</Style>
<Style x:Key="DangerBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
  <Setter Property="Foreground" Value="#FF8A8E"/>
  <Setter Property="BorderBrush" Value="#5A2F33"/>
</Style>
<Style x:Key="DangerPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
  <Setter Property="Background" Value="#D9434A"/>
  <Setter Property="BorderBrush" Value="#D9434A"/>
  <Setter Property="Foreground" Value="White"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
</Style>
<Style x:Key="Link" TargetType="Button">
  <Setter Property="Foreground" Value="#7FAAFF"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Margin" Value="0,0,14,6"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <TextBlock x:Name="t" Text="{Binding Content, RelativeSource={RelativeSource TemplatedParent}}"/>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="t" Property="TextDecorations" Value="Underline"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>

<Style x:Key="Nav" TargetType="RadioButton">
  <Setter Property="Foreground" Value="#9CA3AF"/>
  <Setter Property="FontSize" Value="14"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="RadioButton">
        <Border x:Name="b" Background="Transparent" CornerRadius="7" Padding="14,10" Margin="10,2">
          <ContentPresenter/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#1E2025"/></Trigger>
          <Trigger Property="IsChecked" Value="True">
            <Setter TargetName="b" Property="Background" Value="#262B36"/>
            <Setter Property="Foreground" Value="#E8E9EC"/>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>

<Style x:Key="Seg" TargetType="RadioButton">
  <Setter Property="VerticalAlignment" Value="Center"/>
  <Setter Property="Foreground" Value="#C9CDD3"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Margin" Value="0,0,6,6"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="RadioButton">
        <Border x:Name="b" Background="#2E3137" BorderBrush="#3B3F47" BorderThickness="1" CornerRadius="7" Padding="14,7">
          <ContentPresenter HorizontalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#5A6070"/></Trigger>
          <Trigger Property="IsChecked" Value="True">
            <Setter TargetName="b" Property="Background" Value="#4F8CFF"/>
            <Setter TargetName="b" Property="BorderBrush" Value="#4F8CFF"/>
            <Setter Property="Foreground" Value="White"/>
          </Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>

<Style TargetType="TextBox">
  <Setter Property="Background" Value="#1E2024"/>
  <Setter Property="Foreground" Value="#E8E9EC"/>
  <Setter Property="CaretBrush" Value="#E8E9EC"/>
  <Setter Property="SelectionBrush" Value="#4F8CFF"/>
  <Setter Property="BorderBrush" Value="#3B3F47"/>
  <Setter Property="Padding" Value="8,6"/>
  <Setter Property="FontSize" Value="13"/>
  <Setter Property="VerticalContentAlignment" Value="Center"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="TextBox">
        <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="7">
          <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#4F8CFF"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>

<Style TargetType="CheckBox">
  <Setter Property="Foreground" Value="#E8E9EC"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="CheckBox">
        <StackPanel Orientation="Horizontal" Background="Transparent">
          <Border x:Name="box" Width="18" Height="18" CornerRadius="5" BorderThickness="1" BorderBrush="#5A5F69" Background="#1E2024" VerticalAlignment="Center">
            <Path x:Name="tick" Data="M3.5,9 L7.5,13 L14.5,5" Stroke="White" StrokeThickness="2" Visibility="Collapsed"/>
          </Border>
          <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <ControlTemplate.Triggers>
          <Trigger Property="IsChecked" Value="True">
            <Setter TargetName="box" Property="Background" Value="#4F8CFF"/>
            <Setter TargetName="box" Property="BorderBrush" Value="#4F8CFF"/>
            <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>

<Style TargetType="ProgressBar">
  <Setter Property="Height" Value="6"/>
  <Setter Property="Foreground" Value="#4F8CFF"/>
  <Setter Property="Background" Value="#2E3137"/>
  <Setter Property="BorderThickness" Value="0"/>
</Style>

<Style x:Key="ThumbStyle" TargetType="Thumb">
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Thumb"><Border Background="#4A4E57" CornerRadius="4"/></ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="ScrollBar">
  <Setter Property="Background" Value="Transparent"/>
  <Setter Property="Width" Value="10"/>
  <Setter Property="MinWidth" Value="10"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ScrollBar">
        <Track x:Name="PART_Track" IsDirectionReversed="True" Margin="2">
          <Track.Thumb><Thumb Style="{StaticResource ThumbStyle}"/></Track.Thumb>
        </Track>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
  <Style.Triggers>
    <Trigger Property="Orientation" Value="Horizontal">
      <Setter Property="Width" Value="Auto"/>
      <Setter Property="MinWidth" Value="0"/>
      <Setter Property="Height" Value="10"/>
      <Setter Property="MinHeight" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" Margin="2">
              <Track.Thumb><Thumb Style="{StaticResource ThumbStyle}"/></Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Trigger>
  </Style.Triggers>
</Style>

<Style TargetType="ListView">
  <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
  <Setter Property="Background" Value="Transparent"/>
  <Setter Property="BorderThickness" Value="0"/>
  <Setter Property="Foreground" Value="#E8E9EC"/>
</Style>
<Style TargetType="ListViewItem">
  <Setter Property="Foreground" Value="#E8E9EC"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ListViewItem">
        <Border x:Name="b" Background="Transparent" CornerRadius="7" Padding="2,8" Margin="0,1">
          <GridViewRowPresenter Columns="{TemplateBinding GridView.ColumnCollection}" Content="{TemplateBinding Content}" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#2A2D33"/></Trigger>
          <Trigger Property="IsSelected" Value="True"><Setter TargetName="b" Property="Background" Value="#2C3A57"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="GridViewColumnHeader">
  <Setter Property="Foreground" Value="#9CA3AF"/>
  <Setter Property="HorizontalContentAlignment" Value="Left"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="GridViewColumnHeader">
        <Border Background="Transparent" Padding="8,4,8,8" BorderBrush="#363940" BorderThickness="0,0,0,1">
          <ContentPresenter/>
        </Border>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>

<Style TargetType="ComboBox">
  <Setter Property="Foreground" Value="#E8E9EC"/>
  <Setter Property="FontSize" Value="13"/>
  <Setter Property="MaxDropDownHeight" Value="300"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ComboBox">
        <Grid>
          <ToggleButton Focusable="False" ClickMode="Press"
                        IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
            <ToggleButton.Template>
              <ControlTemplate TargetType="ToggleButton">
                <Border x:Name="b" Background="#1E2024" BorderBrush="#3B3F47" BorderThickness="1" CornerRadius="7">
                  <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,13,0" Data="M0,0 L5,5 L10,0" Stroke="#9CA3AF" StrokeThickness="1.6"/>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#5A6070"/></Trigger>
                  <Trigger Property="IsChecked" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#4F8CFF"/></Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </ToggleButton.Template>
          </ToggleButton>
          <ContentPresenter IsHitTestVisible="False" Margin="10,8,34,8" VerticalAlignment="Center"
                            Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
          <Popup x:Name="PART_Popup" IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
            <Border Background="#24262B" BorderBrush="#3B3F47" BorderThickness="1" CornerRadius="7" Margin="0,4,0,0" Padding="4"
                    TextElement.Foreground="#E8E9EC"
                    MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}"
                    MaxHeight="{TemplateBinding MaxDropDownHeight}">
              <ScrollViewer><ItemsPresenter/></ScrollViewer>
            </Border>
          </Popup>
        </Grid>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="ComboBoxItem">
  <Setter Property="Foreground" Value="#E8E9EC"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ComboBoxItem">
        <Border x:Name="b" Background="Transparent" CornerRadius="6" Padding="10,7">
          <ContentPresenter/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="b" Property="Background" Value="#2A2D33"/></Trigger>
          <Trigger Property="IsSelected" Value="True"><Setter TargetName="b" Property="Background" Value="#2C3A57"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>

<Style TargetType="ListBox">
  <Setter Property="Background" Value="#1E2024"/>
  <Setter Property="BorderBrush" Value="#3B3F47"/>
  <Setter Property="Foreground" Value="#E8E9EC"/>
  <Setter Property="Padding" Value="4"/>
</Style>
<Style TargetType="ListBoxItem">
  <Setter Property="Foreground" Value="#E8E9EC"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ListBoxItem">
        <Border x:Name="b" Background="Transparent" CornerRadius="6" Padding="10,6">
          <ContentPresenter/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#2A2D33"/></Trigger>
          <Trigger Property="IsSelected" Value="True"><Setter TargetName="b" Property="Background" Value="#2C3A57"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>

<Style x:Key="CardBorder" TargetType="Border">
  <Setter Property="Background" Value="#24262B"/>
  <Setter Property="CornerRadius" Value="12"/>
  <Setter Property="Padding" Value="18"/>
</Style>
<Style x:Key="H1" TargetType="TextBlock">
  <Setter Property="FontSize" Value="24"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
  <Setter Property="Foreground" Value="#E8E9EC"/>
</Style>
<Style x:Key="H2" TargetType="TextBlock">
  <Setter Property="FontSize" Value="15"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
  <Setter Property="Foreground" Value="#E8E9EC"/>
  <Setter Property="Margin" Value="0,0,0,6"/>
</Style>
<Style x:Key="Muted" TargetType="TextBlock">
  <Setter Property="Foreground" Value="#9CA3AF"/>
  <Setter Property="TextWrapping" Value="Wrap"/>
</Style>
'@

function ConvertFrom-Xaml([string]$Xaml) {
    $Xaml = $Xaml.Replace('%STYLES%', $script:Styles)
    return [Windows.Markup.XamlReader]::Parse($Xaml)
}

# ---------------------------------------------------------------------------------------------------------------
# Main window

$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="NX Fork Manager" Width="1220" Height="780" MinWidth="1000" MinHeight="620"
        Background="#1B1C20" Foreground="#E8E9EC" FontFamily="Segoe UI" FontSize="13"
        WindowStartupLocation="CenterScreen" UseLayoutRounding="True">
  <Window.Resources>
%STYLES%
  </Window.Resources>
  <Grid Background="#1B1C20">
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="220"/>
      <ColumnDefinition/>
    </Grid.ColumnDefinitions>

    <!-- sidebar -->
    <Border Background="#141518">
      <DockPanel>
        <StackPanel DockPanel.Dock="Top" Margin="24,24,20,22">
          <TextBlock Text="NX Fork Manager" FontSize="19" FontWeight="SemiBold"/>
          <TextBlock x:Name="SideSub" Style="{StaticResource Muted}" FontSize="12" Margin="0,4,0,0"/>
        </StackPanel>
        <StackPanel DockPanel.Dock="Bottom" Margin="24,0,20,20">
          <TextBlock x:Name="TokenInfo" Style="{StaticResource Muted}" FontSize="12"/>
          <Button x:Name="BtnToken" Style="{StaticResource Link}" Content="About GitHub tokens" Margin="0,4,0,0" FontSize="12"/>
        </StackPanel>
        <StackPanel>
          <RadioButton x:Name="NavForks" Style="{StaticResource Nav}" GroupName="nav" IsChecked="True" Content="Forks"/>
          <RadioButton x:Name="NavGames" Style="{StaticResource Nav}" GroupName="nav" Content="Games"/>
          <RadioButton x:Name="NavSwitches" Style="{StaticResource Nav}" GroupName="nav" Content="NX2 switches"/>
          <RadioButton x:Name="NavSettings" Style="{StaticResource Nav}" GroupName="nav" Content="Settings"/>
          <RadioButton x:Name="NavLog" Style="{StaticResource Nav}" GroupName="nav" Content="Activity log"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <Grid Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Grid Margin="28,22,28,14">

        <!-- ================= Forks ================= -->
        <Grid x:Name="PageForks">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition/>
          </Grid.RowDefinitions>
          <DockPanel Margin="0,0,0,12">
            <StackPanel>
              <TextBlock Text="Forks" Style="{StaticResource H1}"/>
              <TextBlock x:Name="ForksSub" Style="{StaticResource Muted}" Margin="0,2,0,0"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
              <Button x:Name="BtnAddFork" Content="+  Add fork from link"/>
              <Button x:Name="BtnCheck" Content="Check for updates"/>
              <Button x:Name="BtnUpdateAll" Style="{StaticResource Primary}" Content="Update all"/>
            </StackPanel>
          </DockPanel>
          <StackPanel Grid.Row="1">
            <Border x:Name="AppBanner" Background="#1C2740" BorderBrush="#33507F" BorderThickness="1" CornerRadius="8" Padding="12,6" Margin="0,0,0,10" Visibility="Collapsed">
              <DockPanel>
                <Button x:Name="BtnAppBanner" DockPanel.Dock="Right" Style="{StaticResource Primary}" Content="See what is new" Margin="12,0,0,0" Padding="12,5"/>
                <TextBlock x:Name="AppBannerText" TextWrapping="Wrap" Foreground="#B9CCF2" VerticalAlignment="Center"/>
              </DockPanel>
            </Border>
            <Border x:Name="Banner" Background="#2B2F1E" BorderBrush="#5C5A2A" BorderThickness="1" CornerRadius="8" Padding="12,8" Margin="0,0,0,12" Visibility="Collapsed">
              <TextBlock x:Name="BannerText" TextWrapping="Wrap" Foreground="#E8D98A"/>
            </Border>
          </StackPanel>
          <Grid Grid.Row="2">
            <Grid.ColumnDefinitions>
              <ColumnDefinition/>
              <ColumnDefinition Width="330"/>
            </Grid.ColumnDefinitions>
            <Border Style="{StaticResource CardBorder}" Padding="10" Margin="0,0,16,0">
              <ListView x:Name="ForkList">
                <ListView.GroupStyle>
                  <GroupStyle>
                    <GroupStyle.HeaderTemplate>
                      <DataTemplate>
                        <TextBlock Text="{Binding Name}" Foreground="#9CA3AF" FontWeight="SemiBold" Margin="8,14,0,4"/>
                      </DataTemplate>
                    </GroupStyle.HeaderTemplate>
                  </GroupStyle>
                </ListView.GroupStyle>
                <ListView.View>
                  <GridView>
                    <GridViewColumn Header="Fork" Width="265">
                      <GridViewColumn.CellTemplate>
                        <DataTemplate>
                          <StackPanel Orientation="Horizontal" Margin="6,0,0,0">
                            <TextBlock Text="{Binding Name}" FontWeight="SemiBold"/>
                            <Border Background="{Binding BadgeBg}" CornerRadius="4" Padding="6,1" Margin="8,0,0,0" Visibility="{Binding BadgeVis}">
                              <TextBlock Text="{Binding Badge}" FontSize="11" Foreground="White"/>
                            </Border>
                          </StackPanel>
                        </DataTemplate>
                      </GridViewColumn.CellTemplate>
                    </GridViewColumn>
                    <GridViewColumn Header="Installed" Width="165">
                      <GridViewColumn.CellTemplate>
                        <DataTemplate><TextBlock Text="{Binding Installed}" Foreground="{Binding InstalledBrush}" TextTrimming="CharacterEllipsis"/></DataTemplate>
                      </GridViewColumn.CellTemplate>
                    </GridViewColumn>
                    <GridViewColumn Header="Status" Width="160">
                      <GridViewColumn.CellTemplate>
                        <DataTemplate><TextBlock Text="{Binding Status}" Foreground="{Binding StatusBrush}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/></DataTemplate>
                      </GridViewColumn.CellTemplate>
                    </GridViewColumn>
                  </GridView>
                </ListView.View>
              </ListView>
            </Border>
            <Border Grid.Column="1" Style="{StaticResource CardBorder}">
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel>
                  <TextBlock x:Name="DName" FontSize="18" FontWeight="SemiBold" TextWrapping="Wrap" Text="Select a fork"/>
                  <TextBlock x:Name="DRepo" Style="{StaticResource Muted}" Margin="0,3,0,14"/>
                  <Grid x:Name="DInfo" Margin="0,0,0,14"/>
                  <WrapPanel x:Name="DActions"/>
                  <TextBlock x:Name="DLinksTitle" Text="Links" Style="{StaticResource H2}" Margin="0,10,0,6"/>
                  <WrapPanel x:Name="DLinks"/>
                </StackPanel>
              </ScrollViewer>
            </Border>
          </Grid>
        </Grid>

        <!-- ================= Games ================= -->
        <Grid x:Name="PageGames" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition/>
          </Grid.RowDefinitions>
          <DockPanel Margin="0,0,0,14">
            <StackPanel>
              <TextBlock Text="Games" Style="{StaticResource H1}"/>
              <TextBlock x:Name="GamesSub" Style="{StaticResource Muted}" Margin="0,2,0,0"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
              <Button x:Name="BtnSync" Content="Sync the guide"/>
              <Button x:Name="BtnGamesMd" Content="Open GAMES.md"/>
            </StackPanel>
          </DockPanel>
          <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
              <ColumnDefinition/>
              <ColumnDefinition Width="330"/>
            </Grid.ColumnDefinitions>
            <Border Style="{StaticResource CardBorder}" Padding="10" Margin="0,0,16,0">
              <ListView x:Name="GameList">
                <ListView.View>
                  <GridView>
                    <GridViewColumn Header="Game" Width="255">
                      <GridViewColumn.CellTemplate>
                        <DataTemplate><TextBlock Text="{Binding Game}" FontWeight="SemiBold" Margin="6,0,0,0" TextTrimming="CharacterEllipsis"/></DataTemplate>
                      </GridViewColumn.CellTemplate>
                    </GridViewColumn>
                    <GridViewColumn Header="Recommended" Width="330">
                      <GridViewColumn.CellTemplate>
                        <DataTemplate><TextBlock Text="{Binding Pick}" TextTrimming="CharacterEllipsis"/></DataTemplate>
                      </GridViewColumn.CellTemplate>
                    </GridViewColumn>
                  </GridView>
                </ListView.View>
              </ListView>
            </Border>
            <Border Grid.Column="1" Style="{StaticResource CardBorder}">
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel>
                  <TextBlock x:Name="GName" FontSize="18" FontWeight="SemiBold" TextWrapping="Wrap" Text="Select a game"/>
                  <TextBlock x:Name="GPick" Style="{StaticResource Muted}" Margin="0,3,0,12"/>
                  <WrapPanel x:Name="GActions"/>
                  <TextBlock x:Name="GAltTitle" Text="Alternatives" Style="{StaticResource H2}" Margin="0,8,0,4"/>
                  <TextBlock x:Name="GAlt" TextWrapping="Wrap" Foreground="#C9CDD3"/>
                  <TextBlock x:Name="GEvTitle" Text="Guide evidence" Style="{StaticResource H2}" Margin="0,14,0,4"/>
                  <TextBlock x:Name="GEv" TextWrapping="Wrap" Foreground="#C9CDD3"/>
                  <TextBlock x:Name="GNotesTitle" Text="My notes" Style="{StaticResource H2}" Margin="0,14,0,4"/>
                  <TextBlock x:Name="GNotes" TextWrapping="Wrap" Foreground="#C9CDD3"/>
                </StackPanel>
              </ScrollViewer>
            </Border>
          </Grid>
        </Grid>

        <!-- ================= NX2 switches ================= -->
        <Grid x:Name="PageSwitches" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition/>
          </Grid.RowDefinitions>
          <DockPanel Margin="0,0,0,14">
            <StackPanel>
              <TextBlock Text="NX2 switches" Style="{StaticResource H1}"/>
              <TextBlock Style="{StaticResource Muted}" Margin="0,2,0,0" Text="Written into the nx2_switches.txt of every installed fork, again after every update. The fork's own file is kept as nx2_switches.original.txt."/>
            </StackPanel>
          </DockPanel>
          <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
              <ColumnDefinition/>
              <ColumnDefinition Width="330"/>
            </Grid.ColumnDefinitions>
            <Grid Margin="0,0,16,0">
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition/>
              </Grid.RowDefinitions>
              <WrapPanel Margin="0,0,0,6">
                <Button x:Name="BtnSwAdd" Style="{StaticResource Primary}" Content="+  Add switch"/>
                <Button x:Name="BtnSwPaste" Content="Paste several"/>
                <Button x:Name="BtnSwClip" Content="Add from clipboard"/>
                <Button x:Name="BtnSwApply" Content="Re-apply to all forks"/>
              </WrapPanel>
              <Border Grid.Row="1" Style="{StaticResource CardBorder}" Padding="10">
                <ListView x:Name="SwitchList">
                  <ListView.View>
                    <GridView>
                      <GridViewColumn Header="On" Width="56">
                        <GridViewColumn.CellTemplate>
                          <DataTemplate><CheckBox IsChecked="{Binding Enabled, Mode=OneWay}" Tag="{Binding Name}" Margin="8,0,0,0"/></DataTemplate>
                        </GridViewColumn.CellTemplate>
                      </GridViewColumn>
                      <GridViewColumn Header="Switch" Width="300">
                        <GridViewColumn.CellTemplate>
                          <DataTemplate><TextBlock Text="{Binding Line}" FontFamily="Consolas" TextTrimming="CharacterEllipsis"/></DataTemplate>
                        </GridViewColumn.CellTemplate>
                      </GridViewColumn>
                      <GridViewColumn Header="Description" Width="230">
                        <GridViewColumn.CellTemplate>
                          <DataTemplate><TextBlock Text="{Binding Note}" Foreground="#9CA3AF" TextTrimming="CharacterEllipsis"/></DataTemplate>
                        </GridViewColumn.CellTemplate>
                      </GridViewColumn>
                    </GridView>
                  </ListView.View>
                </ListView>
              </Border>
            </Grid>
            <Border Grid.Column="1" Style="{StaticResource CardBorder}">
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel>
                  <TextBlock x:Name="SName" FontSize="16" FontWeight="SemiBold" TextWrapping="Wrap" FontFamily="Consolas" Text="Select a switch"/>
                  <TextBlock x:Name="SState" Style="{StaticResource Muted}" Margin="0,3,0,12"/>
                  <TextBlock x:Name="SNote" TextWrapping="Wrap" Foreground="#C9CDD3" Margin="0,0,0,14"/>
                  <WrapPanel x:Name="SActions">
                    <Button x:Name="BtnSwToggle" Content="Turn off"/>
                    <Button x:Name="BtnSwValue" Content="Change value"/>
                    <Button x:Name="BtnSwNote" Content="Edit description"/>
                    <Button x:Name="BtnSwDelete" Style="{StaticResource DangerBtn}" Content="Delete"/>
                  </WrapPanel>
                  <TextBlock Style="{StaticResource Muted}" FontSize="12" Margin="0,14,0,0" Text="The forks also read %APPDATA%\eden\nx2_switches.txt, and a value there wins over the fork's file. If a switch has no effect, check that file."/>
                </StackPanel>
              </ScrollViewer>
            </Border>
          </Grid>
        </Grid>

        <!-- ================= Settings ================= -->
        <ScrollViewer x:Name="PageSettings" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
          <StackPanel MaxWidth="820" HorizontalAlignment="Left">
            <TextBlock Text="Settings" Style="{StaticResource H1}" Margin="0,0,0,4"/>
            <TextBlock Style="{StaticResource Muted}" Margin="0,0,0,16" Text="Saved in config.json next to the tool."/>

            <Border Style="{StaticResource CardBorder}" Margin="0,0,0,14">
              <StackPanel>
                <TextBlock Text="When the window opens" Style="{StaticResource H2}"/>
                <CheckBox x:Name="ChkForksOnStart" Content="Check the installed forks for updates, and install them" Margin="0,4,0,8"/>
                <CheckBox x:Name="ChkAppOnStart" Content="Check for a new version of NX Fork Manager (only shows a notice, never installs by itself)" Margin="0,0,0,4"/>
                <TextBlock Style="{StaticResource Muted}" FontSize="12" Margin="26,4,0,0" Text="The guide is synced either way. With fork checks off, use Check for updates or Update all on the Forks page."/>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource CardBorder}" Margin="0,0,0,14">
              <StackPanel>
                <TextBlock Text="App updates" Style="{StaticResource H2}"/>
                <TextBlock Style="{StaticResource Muted}" Margin="0,0,0,10" Text="NX Fork Manager has no releases: it follows the newest commit of its GitHub repository. Updating replaces the tool's files. Your settings, forks, notes and switches are not touched."/>
                <Grid Margin="0,0,0,10">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition/>
                  </Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition/>
                    <RowDefinition/>
                    <RowDefinition/>
                  </Grid.RowDefinitions>
                  <TextBlock Text="This version" Foreground="#9CA3AF" Margin="0,0,14,6"/>
                  <TextBlock x:Name="AppVersionText" Grid.Column="1" TextWrapping="Wrap" Margin="0,0,0,6"/>
                  <TextBlock Grid.Row="1" Text="Source" Foreground="#9CA3AF" Margin="0,0,14,6"/>
                  <WrapPanel Grid.Row="1" Grid.Column="1" Margin="0,0,0,6">
                    <TextBlock x:Name="AppSourceText" TextWrapping="Wrap" VerticalAlignment="Center"/>
                    <Button x:Name="BtnAppSourceEdit" Style="{StaticResource Link}" Content="Edit" Margin="12,0,0,0" VerticalAlignment="Center"/>
                  </WrapPanel>
                  <TextBlock Grid.Row="2" Text="Status" Foreground="#9CA3AF" Margin="0,0,14,6"/>
                  <TextBlock x:Name="AppStatusText" Grid.Row="2" Grid.Column="1" TextWrapping="Wrap" Margin="0,0,0,6"/>
                </Grid>
                <Border x:Name="AppSourcePanel" Background="#1F2126" CornerRadius="8" Padding="12,10" Margin="0,0,0,12" Visibility="Collapsed">
                  <StackPanel>
                    <TextBlock Text="Update source" FontWeight="SemiBold" Margin="0,0,0,6"/>
                    <WrapPanel>
                      <StackPanel Margin="0,0,10,0">
                        <TextBlock Text="Repository" Foreground="#9CA3AF" FontSize="12" Margin="0,0,0,3"/>
                        <TextBox x:Name="AppRepoBox" Width="330" Height="34" Padding="8,0"/>
                      </StackPanel>
                      <StackPanel Margin="0,0,10,0">
                        <TextBlock Text="Branch (empty: the default branch)" Foreground="#9CA3AF" FontSize="12" Margin="0,0,0,3"/>
                        <TextBox x:Name="AppBranchBox" Width="200" Height="34" Padding="8,0"/>
                      </StackPanel>
                      <StackPanel Orientation="Horizontal" VerticalAlignment="Bottom" Margin="0,8,0,0">
                        <Button x:Name="BtnAppSourceSave" Style="{StaticResource Primary}" Content="Save" Margin="0,0,8,0"/>
                        <Button x:Name="BtnAppSourceDefault" Content="Use default" Margin="0,0,8,0"/>
                        <Button x:Name="BtnAppSourceCancel" Content="Cancel" Margin="0"/>
                      </StackPanel>
                    </WrapPanel>
                    <TextBlock Style="{StaticResource Muted}" FontSize="12" Margin="0,6,0,0" Text="owner/repository or a github.com link (a link to a branch, .../tree/name, also sets the branch). For example your own fork, to test changes before they are merged. Only GitHub repositories of nx-fork-manager work: Save checks that."/>
                  </StackPanel>
                </Border>
                <WrapPanel>
                  <Button x:Name="BtnAppCheck" Content="Check now"/>
                  <Button x:Name="BtnAppUpdate" Style="{StaticResource Primary}" Content="Update now"/>
                  <Button x:Name="BtnAppRestore" Content="Restore a previous version..."/>
                  <Button x:Name="BtnAppHistory" Style="{StaticResource Link}" Content="Commit history" Margin="8,0,0,8"/>
                </WrapPanel>
                <CheckBox x:Name="ChkAppBackup" Content="Back up the current version before updating (the last 3 are kept in data\app-backups)" Margin="0,6,0,0"/>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource CardBorder}" Margin="0,0,0,14">
              <StackPanel>
                <TextBlock Text="Build type" Style="{StaticResource H2}"/>
                <TextBlock Style="{StaticResource Muted}" Margin="0,0,0,10" Text="Several forks publish a PGO build (optimized with a recorded profile, often faster) next to the standard MSVC build. PGO builds install to their own folder and never replace the MSVC build. Forks without a PGO build always show their MSVC build."/>
                <WrapPanel>
                  <RadioButton x:Name="BtMsvc" Style="{StaticResource Seg}" GroupName="bt" Content="MSVC"/>
                  <RadioButton x:Name="BtPgo" Style="{StaticResource Seg}" GroupName="bt" Content="PGO"/>
                  <RadioButton x:Name="BtBoth" Style="{StaticResource Seg}" GroupName="bt" Content="Both"/>
                </WrapPanel>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource CardBorder}" Margin="0,0,0,14">
              <StackPanel>
                <TextBlock Text="Zip backups" Style="{StaticResource H2}"/>
                <TextBlock Style="{StaticResource Muted}" Margin="0,0,0,10" Text="Keep the downloaded zips of each build in &lt;install folder&gt;\_zips. A lower number deletes the oldest extra zips right away."/>
                <WrapPanel>
                  <RadioButton x:Name="ZipNone" Style="{StaticResource Seg}" GroupName="zip" Content="None"/>
                  <RadioButton x:Name="ZipCount" Style="{StaticResource Seg}" GroupName="zip" Content="Keep the newest"/>
                  <TextBox x:Name="ZipN" Width="56" Height="34" Padding="8,0" Margin="0,0,6,6" VerticalAlignment="Center"/>
                  <RadioButton x:Name="ZipAll" Style="{StaticResource Seg}" GroupName="zip" Content="All"/>
                  <Button x:Name="BtnZipSave" Content="Save" Margin="8,0,8,6"/>
                </WrapPanel>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource CardBorder}" Margin="0,0,0,14">
              <StackPanel>
                <TextBlock Text="GPU filter" Style="{StaticResource H2}"/>
                <TextBlock Style="{StaticResource Muted}" Margin="0,0,0,10" Text="Hides guide recommendations for forks that the guide marks as not working on your GPU."/>
                <WrapPanel>
                  <RadioButton x:Name="GpuNvidia" Style="{StaticResource Seg}" GroupName="gpu" Content="NVIDIA"/>
                  <RadioButton x:Name="GpuAmd" Style="{StaticResource Seg}" GroupName="gpu" Content="AMD"/>
                  <RadioButton x:Name="GpuIntel" Style="{StaticResource Seg}" GroupName="gpu" Content="Intel"/>
                  <RadioButton x:Name="GpuOff" Style="{StaticResource Seg}" GroupName="gpu" Content="Off"/>
                </WrapPanel>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource CardBorder}" Margin="0,0,0,14">
              <StackPanel>
                <TextBlock Text="Update check" Style="{StaticResource H2}"/>
                <TextBlock Style="{StaticResource Muted}" Margin="0,0,0,10" Text="When the window opens, installed builds are checked at most once per this many minutes. Without a GitHub token, GitHub allows 60 requests per hour. Update all ignores it."/>
                <WrapPanel>
                  <TextBox x:Name="IntervalBox" Width="80" Height="34" Padding="8,0" Margin="0,0,8,6" VerticalAlignment="Center"/>
                  <TextBlock Text="minutes" VerticalAlignment="Center" Margin="0,0,12,6" Foreground="#9CA3AF"/>
                  <Button x:Name="BtnIntervalSave" Content="Save" Margin="0,0,8,6"/>
                </WrapPanel>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource CardBorder}" Margin="0,0,0,14">
              <StackPanel>
                <TextBlock Text="Install folder" Style="{StaticResource H2}"/>
                <TextBlock x:Name="InstallDirText" TextWrapping="Wrap" FontFamily="Consolas" Margin="0,0,0,6"/>
                <TextBlock Style="{StaticResource Muted}" Margin="0,0,0,10" Text="To change it, edit install_dir in config.json while the tool is closed. Installed forks are not moved."/>
                <WrapPanel>
                  <Button x:Name="BtnOpenForks" Content="Open folder"/>
                  <Button x:Name="BtnOpenConfig" Content="Open config.json"/>
                  <Button x:Name="BtnOpenReadme" Content="Open README"/>
                </WrapPanel>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- ================= Log ================= -->
        <Grid x:Name="PageLog" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition/>
          </Grid.RowDefinitions>
          <DockPanel Margin="0,0,0,14">
            <StackPanel>
              <TextBlock Text="Activity log" Style="{StaticResource H1}"/>
              <TextBlock Style="{StaticResource Muted}" Margin="0,2,0,0" Text="Everything the tool reports, since this window opened."/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
              <Button x:Name="BtnLogCopy" Content="Copy"/>
              <Button x:Name="BtnLogClear" Content="Clear"/>
            </StackPanel>
          </DockPanel>
          <Border Grid.Row="1" Style="{StaticResource CardBorder}" Padding="4">
            <TextBox x:Name="LogBox" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                     FontFamily="Consolas" FontSize="12" Background="Transparent" BorderThickness="0"/>
          </Border>
        </Grid>
      </Grid>

      <!-- status bar -->
      <Border Grid.Row="1" Background="#141518" Padding="28,10">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition/>
            <ColumnDefinition Width="360"/>
          </Grid.ColumnDefinitions>
          <StackPanel VerticalAlignment="Center" Margin="0,0,20,0">
            <TextBlock x:Name="StatusTitle" Text="Ready" FontWeight="SemiBold"/>
            <TextBlock x:Name="StatusLine" Foreground="#9CA3AF" TextTrimming="CharacterEllipsis" FontSize="12"/>
          </StackPanel>
          <StackPanel Grid.Column="1" VerticalAlignment="Center">
            <ProgressBar x:Name="Progress" Visibility="Hidden" Maximum="100"/>
            <TextBlock x:Name="ProgressText" Foreground="#9CA3AF" FontSize="12" HorizontalAlignment="Right" Margin="0,4,0,0"/>
          </StackPanel>
        </Grid>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

$script:Win = ConvertFrom-Xaml $mainXaml
$script:UI = @{}
foreach ($n in @('SideSub', 'TokenInfo', 'BtnToken', 'NavForks', 'NavGames', 'NavSwitches', 'NavSettings', 'NavLog',
        'PageForks', 'PageGames', 'PageSwitches', 'PageSettings', 'PageLog',
        'ForksSub', 'BtnAddFork', 'BtnCheck', 'BtnUpdateAll', 'Banner', 'BannerText', 'ForkList',
        'DName', 'DRepo', 'DInfo', 'DActions', 'DLinksTitle', 'DLinks',
        'GamesSub', 'BtnSync', 'BtnGamesMd', 'GameList', 'GName', 'GPick', 'GActions', 'GAlt', 'GEv', 'GNotes', 'GAltTitle', 'GEvTitle', 'GNotesTitle',
        'BtnSwAdd', 'BtnSwPaste', 'BtnSwClip', 'BtnSwApply', 'SwitchList', 'SName', 'SState', 'SNote', 'SActions',
        'BtnSwToggle', 'BtnSwValue', 'BtnSwNote', 'BtnSwDelete',
        'BtMsvc', 'BtPgo', 'BtBoth', 'ZipNone', 'ZipCount', 'ZipN', 'ZipAll', 'BtnZipSave',
        'GpuNvidia', 'GpuAmd', 'GpuIntel', 'GpuOff', 'IntervalBox', 'BtnIntervalSave',
        'InstallDirText', 'BtnOpenForks', 'BtnOpenConfig', 'BtnOpenReadme',
        'AppBanner', 'AppBannerText', 'BtnAppBanner', 'ChkForksOnStart', 'ChkAppOnStart', 'ChkAppBackup',
        'AppVersionText', 'AppSourceText', 'AppStatusText', 'BtnAppCheck', 'BtnAppUpdate', 'BtnAppRestore', 'BtnAppHistory',
        'AppRepoBox', 'AppBranchBox', 'BtnAppSourceSave', 'BtnAppSourceDefault', 'BtnAppSourceEdit', 'BtnAppSourceCancel', 'AppSourcePanel',
        'BtnLogCopy', 'BtnLogClear', 'LogBox', 'StatusTitle', 'StatusLine', 'Progress', 'ProgressText')) {
    $script:UI[$n] = $script:Win.FindName($n)
}
$UI = $script:UI

# Dark title bar on Windows 10 20H1+ and 11 (ignored elsewhere).
try {
    Add-Type -Namespace NxGui -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int value, int size);'
    $script:Win.add_SourceInitialized({
            $h = (New-Object Windows.Interop.WindowInteropHelper $script:Win).Handle
            $on = 1
            [void][NxGui.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$on, 4)
            $caption = 0x00181514   # #141518 as 0x00BBGGRR
            [void][NxGui.Dwm]::DwmSetWindowAttribute($h, 35, [ref]$caption, 4)
        })
}
catch { }

# ---------------------------------------------------------------------------------------------------------------
# Small helpers

function Brush([string]$Hex) { return (New-Object Windows.Media.BrushConverter).ConvertFromString($Hex) }

function Add-Log([string]$Text, [string]$Kind = 'info') {
    if ($null -eq $Text) { return }
    $prefix = switch ($Kind) { 'warn' { '!  ' } 'error' { 'x  ' } 'step' { '>> ' } default { '   ' } }
    $Text = $Text.Replace('Press u to force.', 'Click Update all to check them now.')
    foreach ($line in ($Text -split "`r?`n")) {
        if (-not $line.Trim()) { continue }
        $UI.LogBox.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $prefix$line`r`n")
        $UI.StatusLine.Text = $line.Trim()
    }
    $UI.LogBox.ScrollToEnd()
}

function Open-Url([string]$Url) {
    if ($Url) { Start-Process $Url | Out-Null }
}

function Get-ForkUrl($F) {
    switch ($F.source) {
        'forgejo' { return "https://$($F.host)/$($F.repo)" }
        'actions' { return "https://github.com/$($F.repo)/actions/workflows/$($F.workflow)" }
        default { return "https://github.com/$($F.repo)" }
    }
}

function Get-SourceLabel($F) {
    switch ($F.source) {
        'forgejo' { return "Forgejo releases: $($F.host)/$($F.repo)" }
        'actions' { return "GitHub Actions build: $($F.repo) ($($F.workflow))" }
        default { return "GitHub releases: $($F.repo)" }
    }
}

# Runs a quick call on the window thread and puts what it prints in the log. Errors become a dialog.
function Invoke-Quick([scriptblock]$Code) {
    try {
        $out = & $Code 6>&1 3>&1
        foreach ($o in @($out)) {
            if ($o -is [Management.Automation.WarningRecord]) { Add-Log $o.Message 'warn' }
            elseif ($o -is [Management.Automation.InformationRecord]) { Add-Log ([string]$o.MessageData) }
            elseif ($null -ne $o -and $o -isnot [bool]) { Add-Log ([string]$o) }
        }
        return $true
    }
    catch {
        Add-Log $_.Exception.Message 'error'
        Show-Dialog -Title 'Something went wrong' -Message $_.Exception.Message | Out-Null
        return $false
    }
}

# Reloads config.json and the catalog, as a new start of the tool would.
function Reset-Data {
    $script:Config = Get-Config
    $script:Catalog = Import-Catalog
    $script:Checks = $null
}

function Get-MissingBuildsGui($State) {
    return @(Get-InstalledForks $State | Where-Object { -not (Test-Installed $State $_) })
}

# ---------------------------------------------------------------------------------------------------------------
# Dialogs

$dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        SizeToContent="Height" Width="520" WindowStartupLocation="CenterOwner" ShowInTaskbar="False"
        FontFamily="Segoe UI" FontSize="13" Foreground="#E8E9EC">
  <Window.Resources>
%STYLES%
  </Window.Resources>
  <Border Margin="16" Background="#24262B" CornerRadius="12" BorderBrush="#3B3F47" BorderThickness="1" Padding="24,22">
    <Border.Effect><DropShadowEffect BlurRadius="24" ShadowDepth="4" Opacity="0.5"/></Border.Effect>
    <StackPanel>
      <TextBlock x:Name="T" FontSize="17" FontWeight="SemiBold" TextWrapping="Wrap"/>
      <TextBlock x:Name="M" Foreground="#C9CDD3" TextWrapping="Wrap" Margin="0,10,0,0"/>
      <ComboBox x:Name="CB" Visibility="Collapsed" Margin="0,14,0,0"/>
      <ListBox x:Name="L" Visibility="Collapsed" MaxHeight="220" Margin="0,14,0,0"/>
      <TextBox x:Name="I" Visibility="Collapsed" Margin="0,14,0,0"/>
      <TextBlock x:Name="H" Foreground="#9CA3AF" FontSize="12" TextWrapping="Wrap" Margin="0,6,0,0" Visibility="Collapsed"/>
      <CheckBox x:Name="C" Visibility="Collapsed" Margin="0,14,0,0"/>
      <StackPanel x:Name="B" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,-8"/>
    </StackPanel>
  </Border>
</Window>
'@

# Returns { Button; Text; Index; Checked; Choice; IsCustom }. Button is $null when closed with Esc.
# -Choices fills a dropdown (Choice = the selected index). With -Custom, a last entry of that name shows the text
# box while it is selected (IsCustom = $true, Text = what was typed).
function Show-Dialog {
    param(
        [string]$Title, [string]$Message = '', [string[]]$Buttons = @('OK'), [string]$Primary,
        [switch]$Ask, [switch]$Multiline, [string]$Default = '', [string]$Hint = '',
        [object[]]$Items, [int]$Selected = -1, [string]$Check, [bool]$Checked = $false, [switch]$Danger,
        [object[]]$Choices, [int]$ChoiceIndex = 0, [string]$Custom
    )
    $d = ConvertFrom-Xaml $dialogXaml
    if ($script:Win.IsLoaded) { $d.Owner = $script:Win } else { $d.WindowStartupLocation = 'CenterScreen' }
    $t = $d.FindName('T'); $m = $d.FindName('M'); $l = $d.FindName('L'); $i = $d.FindName('I')
    $h = $d.FindName('H'); $c = $d.FindName('C'); $b = $d.FindName('B'); $cb = $d.FindName('CB')
    $t.Text = $Title
    if ($Message) { $m.Text = $Message } else { $m.Visibility = 'Collapsed' }
    $customIndex = -1
    if ($Choices -or $Custom) {
        $cb.Visibility = 'Visible'
        foreach ($ch in @($Choices)) { if ($null -ne $ch) { [void]$cb.Items.Add([string]$ch) } }
        if ($Custom) { $customIndex = $cb.Items.Add($Custom) }
        $cb.SelectedIndex = [Math]::Min([Math]::Max(0, $ChoiceIndex), $cb.Items.Count - 1)
        if ($Custom) {
            # The text box belongs to the Custom entry: shown only while it is selected.
            $i.Visibility = if ($cb.SelectedIndex -eq $customIndex) { 'Visible' } else { 'Collapsed' }
            $i.Text = $Default
            $cb.add_SelectionChanged({
                    $show = $cb.SelectedIndex -eq $customIndex
                    $i.Visibility = if ($show) { 'Visible' } else { 'Collapsed' }
                    if ($show) { $i.Focus() | Out-Null; $i.SelectAll() }
                }.GetNewClosure())
        }
    }
    if ($Items) {
        $l.Visibility = 'Visible'
        foreach ($it in $Items) { [void]$l.Items.Add([string]$it) }
        if ($Selected -ge 0) { $l.SelectedIndex = $Selected }
    }
    if ($Ask) {
        $i.Visibility = 'Visible'
        $i.Text = $Default
        if ($Multiline) {
            $i.AcceptsReturn = $true; $i.Height = 240; $i.VerticalContentAlignment = 'Top'; $i.TextWrapping = 'NoWrap'
            $i.VerticalScrollBarVisibility = 'Auto'; $i.HorizontalScrollBarVisibility = 'Auto'; $i.FontFamily = 'Consolas'
        }
    }
    if ($Hint) { $h.Visibility = 'Visible'; $h.Text = $Hint }
    if ($Check) { $c.Visibility = 'Visible'; $c.Content = $Check; $c.IsChecked = $Checked }
    if (-not $Primary) { $Primary = $Buttons[0] }
    $d.Tag = $null
    foreach ($label in $Buttons) {
        $btn = New-Object Windows.Controls.Button
        $btn.Content = $label
        $btn.Margin = '8,0,0,8'
        $btn.MinWidth = 90
        $style = if ($label -eq $Primary) { if ($Danger) { 'DangerPrimary' } else { 'Primary' } } else { 'Btn' }
        $btn.Style = $d.FindResource($style)
        if ($label -eq $Primary -and -not ($Ask -and $Multiline)) { $btn.IsDefault = $true }
        if ($label -eq $Buttons[-1] -and $Buttons.Count -gt 1) { $btn.IsCancel = $true }
        $btn.Tag = $label
        $btn.add_Click({ param($s, $e) $d.Tag = $s.Tag; $d.Close() }.GetNewClosure())
        [void]$b.Children.Add($btn)
    }
    $d.add_MouseLeftButtonDown({ try { $d.DragMove() } catch { } }.GetNewClosure())
    $d.add_ContentRendered({ if ($Ask) { $i.Focus(); $i.SelectAll() } elseif ($Items) { $l.Focus() } elseif ($cb.Visibility -eq 'Visible') { $cb.Focus() } }.GetNewClosure())
    [void]$d.ShowDialog()
    return [pscustomobject]@{
        Button   = $d.Tag
        Text     = $i.Text
        Index    = $l.SelectedIndex
        Checked  = [bool]$c.IsChecked
        Choice   = $cb.SelectedIndex
        IsCustom = ($customIndex -ge 0 -and $cb.SelectedIndex -eq $customIndex)
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Background work: one job at a time, in its own runspace that loads fork-manager.ps1 itself. A timer on the
# window thread moves what it prints to the log, and turns the download messages into a real progress bar.

$script:Job = $null
$script:DlTotal = 0
$script:DlName = ''

function Set-Busy([bool]$Busy) {
    foreach ($n in 'BtnAddFork', 'BtnCheck', 'BtnUpdateAll', 'BtnSync', 'DActions', 'GActions', 'BtMsvc', 'BtPgo', 'BtBoth',
        'BtnAppCheck', 'BtnAppUpdate', 'BtnAppRestore', 'BtnAppBanner', 'BtnAppSourceSave', 'BtnAppSourceDefault') {
        $UI[$n].IsEnabled = -not $Busy
    }
    $UI.Progress.Visibility = if ($Busy) { 'Visible' } else { 'Hidden' }
    if ($Busy) { $UI.Progress.IsIndeterminate = $true }
}

function Start-Work {
    param([string]$Title, [scriptblock]$Work, $Arg = $null, [scriptblock]$Done = $null)
    if ($script:Job) {
        Show-Dialog -Title 'Please wait' -Message "Still working on: $($script:Job.Title)." | Out-Null
        return
    }
    $rs = [RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    $code = "param(`$FM, `$A)`n`$ErrorActionPreference = 'Stop'`n. `$FM`n`$ErrorActionPreference = 'Stop'`n" + $script:AppUpdateCode + "`n" + $Work.ToString()
    [void]$ps.AddScript($code).AddArgument($script:FmPath).AddArgument($Arg)
    $script:DlTotal = 0
    $script:Job = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); Title = $Title; Done = $Done; Info = 0; Warn = 0; Err = 0 }
    $UI.StatusTitle.Text = $Title
    $UI.StatusLine.Text = ''
    $UI.ProgressText.Text = ''
    Add-Log $Title 'step'
    Set-Busy $true
}

function Read-JobStreams {
    $j = $script:Job
    $s = $j.PS.Streams
    while ($j.Info -lt $s.Information.Count) {
        $text = [string]$s.Information[$j.Info].MessageData
        $j.Info++
        Add-Log $text
        if ($text -match '^\s*Downloading (.+) \(([\d.,]+) MB\)') {
            $script:DlName = $Matches[1]
            $mb = 0.0
            if ([double]::TryParse($Matches[2], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::CurrentCulture, [ref]$mb) -or
                [double]::TryParse($Matches[2], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$mb)) {
                $script:DlTotal = $mb * 1MB
            }
        }
        elseif ($text -match '^\s*Integrity:') {
            $script:DlTotal = 0
            $UI.Progress.IsIndeterminate = $true
            $UI.ProgressText.Text = 'Extracting and installing...'
        }
        elseif ($text -match '^\s*OK: ') {
            $UI.ProgressText.Text = 'Installed'
        }
    }
    while ($j.Warn -lt $s.Warning.Count) { Add-Log $s.Warning[$j.Warn].Message 'warn'; $j.Warn++ }
    while ($j.Err -lt $s.Error.Count) {
        $rec = $s.Error[$j.Err]
        $j.Err++
        # A native program's stderr line arrives as an error record holding the line in TargetObject.
        # The first one wraps an empty line and prints as "System.Management.Automation.RemoteException".
        $text = if ($rec.FullyQualifiedErrorId -like 'NativeCommandError*') { [string]$rec.TargetObject } else { [string]$rec }
        # curl writes its progress bar to stderr; it is noise here, the bar below shows the same.
        if ($text -match '^[#=\-\s\d.,%O]*$') { continue }
        Add-Log $text 'error'
    }
}

function Update-DownloadBar {
    if ($script:DlTotal -le 0) { return }
    $zip = Get-ChildItem -LiteralPath $script:TmpDir -Filter *.zip -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $zip) { return }
    # A folder listing shows 0 bytes for a file that is still being written: its open handle knows the real size.
    $size = 0
    try {
        $fs = [IO.File]::Open($zip.FullName, 'Open', 'Read', 'ReadWrite, Delete')
        $size = $fs.Length
        $fs.Close()
    }
    catch { return }
    $pct = [Math]::Min(100, 100 * $size / $script:DlTotal)
    $UI.Progress.IsIndeterminate = $false
    $UI.Progress.Value = $pct
    $UI.ProgressText.Text = '{0}: {1:N0} of {2:N0} MB ({3:N0}%)' -f $script:DlName, ($size / 1MB), ($script:DlTotal / 1MB), $pct
}

$script:Timer = New-Object Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(150)
$script:Timer.add_Tick({
        $j = $script:Job
        if (-not $j) { return }
        try { Read-JobStreams; Update-DownloadBar } catch { }
        if (-not $j.Handle.IsCompleted) { return }
        $result = $null
        $failed = $null
        try { $result = $j.PS.EndInvoke($j.Handle) }
        catch {
            $e = $_.Exception
            while ($e.InnerException -and $e -is [Management.Automation.MethodInvocationException]) { $e = $e.InnerException }
            $failed = $e.Message
        }
        try { Read-JobStreams } catch { }
        $j.PS.Dispose()
        $j.RS.Dispose()
        $script:Job = $null
        Set-Busy $false
        $UI.ProgressText.Text = ''
        Reset-Data
        if ($failed) {
            $UI.StatusTitle.Text = 'Stopped with an error'
            Add-Log $failed 'error'
        }
        else {
            $UI.StatusTitle.Text = 'Ready'
            Add-Log "$($j.Title): done."
        }
        if ($j.Done) {
            try { & $j.Done @($result) $failed } catch { Add-Log $_.Exception.Message 'error' }
        }
        Update-All
        if ($failed) { Show-Dialog -Title "$($j.Title) stopped" -Message $failed | Out-Null }
    })
$script:Timer.Start()

# ---------------------------------------------------------------------------------------------------------------
# Forks page

$script:Latest = @{}       # fork id -> result of the last check
$script:SelectedFork = $null

function New-ForkRow($F, $State, [string]$Section, [bool]$Hidden, [bool]$Missing) {
    $e = Get-Entry $State $F.id
    $inst = Test-Installed $State $F
    $l = $script:Latest[$F.id]
    $installed = 'Not installed'
    $installedBrush = '#6B7280'
    if ($inst) {
        $installed = $e.tag
        if ($e.pinned) { $installed += '   (pinned)' }
        $installedBrush = '#E8E9EC'
    }
    $latest = ''
    if ($l) { $latest = if ($l.error) { 'check failed' } else { $l.tag } }
    $status = ''; $brush = '#9CA3AF'
    if ($Hidden) { $status = 'Other build type'; $brush = '#9CA3AF' }
    elseif (-not $inst -and $Missing) { $status = 'Not downloaded'; $brush = '#E3B341' }
    elseif (-not $inst) { $status = '' }
    elseif ($l -and $l.error) { $status = 'Check failed'; $brush = '#F2555A' }
    elseif ($l -and $l.tag -ne $e.tag) {
        if ($e.pinned) { $status = 'Pinned, update out'; $brush = '#E3B341' } else { $status = "Update to $($l.tag)"; $brush = '#4F8CFF' }
    }
    elseif ($l) { $status = 'Up to date'; $brush = '#3FB950' }
    else { $status = 'Installed'; $brush = '#C9CDD3' }
    $badges = @()
    if ($F.variant -eq 'pgo') { $badges += 'PGO' }
    if ($script:CustomIds -contains $F.base_id) { $badges += 'added by you' }
    return [pscustomobject]@{
        Id             = $F.id
        Name           = if ($F.variant -eq 'pgo') { $F.name -replace '\s*\(PGO\)$', '' } else { $F.name }
        Badge          = $badges -join ' · '
        BadgeVis       = if ($badges.Count) { 'Visible' } else { 'Collapsed' }
        BadgeBg        = if ($F.variant -eq 'pgo') { '#6D4AFF' } else { '#3B4252' }
        Installed      = $installed
        InstalledBrush = $installedBrush
        Latest         = $latest
        Status         = $status
        StatusBrush    = $brush
        Section        = $Section
    }
}

function Update-ForksPage {
    $state = Get-State
    $missing = @(Get-MissingBuildsGui $state | ForEach-Object { $_.id })
    $rows = New-Object Collections.ArrayList
    $label = Get-BuildTypeLabel
    foreach ($f in $script:Catalog.forks) {
        [void]$rows.Add((New-ForkRow $f $state "Builds: $label" $false ($missing -contains $f.id)))
    }
    $hidden = @(Get-HiddenInstalled $state)
    if ($hidden.Count) {
        $types = @($hidden | ForEach-Object { Get-VariantLabel $_ } | Select-Object -Unique) -join ' and '
        foreach ($f in $hidden) { [void]$rows.Add((New-ForkRow $f $state "$types builds installed outside your build type (no updates)" $true $false)) }
    }
    $keep = $script:SelectedFork
    $view = [Windows.Data.CollectionViewSource]::GetDefaultView($rows)
    $view.GroupDescriptions.Add((New-Object Windows.Data.PropertyGroupDescription 'Section'))
    $UI.ForkList.ItemsSource = $view
    $count = @($script:AllForks | Where-Object { Test-Installed $state $_ }).Count
    $UI.ForksSub.Text = "$count installed. Select a fork for its actions and links."
    if ($missing.Count) {
        $names = @($script:Catalog.forks | Where-Object { $missing -contains $_.id } | ForEach-Object name) -join ', '
        $UI.BannerText.Text = "Not downloaded yet for your build type ($label): $names. Click Update all to download them."
        $UI.Banner.Visibility = 'Visible'
    }
    else { $UI.Banner.Visibility = 'Collapsed' }
    if ($keep) {
        $row = @($rows | Where-Object { $_.Id -eq $keep }) | Select-Object -First 1
        if ($row) { $UI.ForkList.SelectedItem = $row } else { $script:SelectedFork = $null }
    }
    Show-ForkDetail
}

function Add-InfoRow([string]$Label, [string]$Value) {
    $g = $UI.DInfo
    $r = $g.RowDefinitions.Count
    $g.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
    $a = New-Object Windows.Controls.TextBlock
    $a.Text = $Label; $a.Foreground = Brush '#9CA3AF'; $a.Margin = '0,0,12,6'
    $b = New-Object Windows.Controls.TextBlock
    $b.Text = $Value; $b.TextWrapping = 'Wrap'; $b.Margin = '0,0,0,6'
    [Windows.Controls.Grid]::SetRow($a, $r); [Windows.Controls.Grid]::SetRow($b, $r); [Windows.Controls.Grid]::SetColumn($b, 1)
    [void]$g.Children.Add($a); [void]$g.Children.Add($b)
}

function New-ActionButton([string]$Text, [scriptblock]$Click, [string]$Style = 'Btn', [string]$Tip = '') {
    $b = New-Object Windows.Controls.Button
    $b.Content = $Text
    $b.Style = $script:Win.FindResource($Style)
    if ($Tip) { $b.ToolTip = $Tip }
    $b.add_Click($Click)
    return $b
}

function New-LinkButton([string]$Text, [string]$Url) {
    $b = New-Object Windows.Controls.Button
    $b.Content = $Text
    $b.Style = $script:Win.FindResource('Link')
    $b.ToolTip = $Url
    $b.Tag = $Url
    $b.add_Click({ param($s, $e) Open-Url $s.Tag })
    return $b
}

function Show-ForkDetail {
    $UI.DInfo.Children.Clear(); $UI.DInfo.RowDefinitions.Clear(); $UI.DInfo.ColumnDefinitions.Clear()
    $UI.DActions.Children.Clear(); $UI.DLinks.Children.Clear()
    if (-not $script:SelectedFork) {
        $UI.DName.Text = 'Select a fork'
        $UI.DRepo.Text = 'Its version, actions and links show here.'
        $UI.DLinksTitle.Visibility = 'Collapsed'
        return
    }
    $f = $null
    try { $f = Get-ForkById $script:SelectedFork } catch { $script:SelectedFork = $null; Show-ForkDetail; return }
    $state = Get-State
    $e = Get-Entry $state $f.id
    $inst = Test-Installed $state $f
    $visible = @($script:Catalog.forks | Where-Object { $_.id -eq $f.id }).Count -gt 0
    $UI.DName.Text = $f.name
    $UI.DRepo.Text = Get-SourceLabel $f
    $UI.DLinksTitle.Visibility = 'Visible'

    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = 'Auto'
    [void]$UI.DInfo.ColumnDefinitions.Add($c1)
    [void]$UI.DInfo.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))
    if ($inst) {
        Add-InfoRow 'Installed' $e.tag
        if ($e.published) { Add-InfoRow 'Published' $e.published }
        if ($e.installed) { Add-InfoRow 'Installed on' $e.installed }
        Add-InfoRow 'Pinned' $(if ($e.pinned) { 'Yes: gets no updates' } else { 'No' })
        Add-InfoRow 'Previous' $(if ($e.previous) { "$($e.previous.tag) (kept for roll back)" } else { 'none kept' })
    }
    else { Add-InfoRow 'Installed' 'Not installed' }
    $l = $script:Latest[$f.id]
    if ($l) {
        if ($l.error) { Add-InfoRow 'Latest' "Check failed: $($l.error)" }
        else { Add-InfoRow 'Latest' ("{0}`n{1} ({2:N1} MB, {3})" -f $l.tag, $l.asset, ($l.size / 1MB), $(if ($l.hash) { 'SHA-256 published' } else { 'no hash published' })) }
    }
    else { Add-InfoRow 'Latest' 'Not checked yet' }
    if (-not $visible) { Add-InfoRow 'Build type' "Outside your build type ($(Get-BuildTypeLabel)): gets no updates." }

    $id = $f.id
    $openText = if ($inst) { 'Open' } else { 'Install and open' }
    [void]$UI.DActions.Children.Add((New-ActionButton $openText { Invoke-OpenFork $script:SelectedFork } 'Primary'))
    if ($inst) {
        [void]$UI.DActions.Children.Add((New-ActionButton 'Update' { Invoke-UpdateOne $script:SelectedFork } 'Btn' 'Install the newest build now, unless it is pinned.'))
    }
    [void]$UI.DActions.Children.Add((New-ActionButton 'Check' { Invoke-Check @($script:SelectedFork) } 'Btn' 'Look up the newest build without installing.'))
    [void]$UI.DActions.Children.Add((New-ActionButton 'Install version...' { Invoke-InstallVersion $script:SelectedFork } 'Btn' 'Install a specific release tag or build.'))
    if ($inst) {
        if ($e.previous) { [void]$UI.DActions.Children.Add((New-ActionButton 'Roll back' { Invoke-Rollback $script:SelectedFork } 'Btn' "Go back to $($e.previous.tag) and pin it.")) }
        $pinText = if ($e.pinned) { 'Unpin' } else { 'Pin' }
        [void]$UI.DActions.Children.Add((New-ActionButton $pinText { Invoke-Pin $script:SelectedFork } 'Btn' 'A pinned fork gets no updates.'))
        [void]$UI.DActions.Children.Add((New-ActionButton 'Delete build' { Invoke-DeleteBuild $script:SelectedFork } 'DangerBtn' 'Delete the installed files. The fork stays in the list.'))
    }
    if ($script:CustomIds -contains $f.base_id) {
        [void]$UI.DActions.Children.Add((New-ActionButton 'Remove fork' { Invoke-RemoveFork $script:SelectedFork } 'DangerBtn' 'Remove this fork you added, with its installed files.'))
    }

    [void]$UI.DLinks.Children.Add((New-LinkButton 'Project page' (Get-ForkUrl $f)))
    if ($f.source -ne 'actions') {
        $rel = if ($f.source -eq 'forgejo') { "https://$($f.host)/$($f.repo)/releases" } else { "https://github.com/$($f.repo)/releases" }
        [void]$UI.DLinks.Children.Add((New-LinkButton 'All releases' $rel))
    }
    if ($inst -and $e.url) { [void]$UI.DLinks.Children.Add((New-LinkButton 'Installed release' $e.url)) }
    if ($l -and -not $l.error -and $l.url -and -not ($inst -and $l.url -eq $e.url)) { [void]$UI.DLinks.Children.Add((New-LinkButton 'Latest release' $l.url)) }
    if ($inst) {
        $b = New-Object Windows.Controls.Button
        $b.Content = 'Open install folder'; $b.Style = $script:Win.FindResource('Link'); $b.Tag = (Get-ForkDir $id)
        $b.add_Click({ param($s, $e) Start-Process explorer.exe $s.Tag | Out-Null })
        [void]$UI.DLinks.Children.Add($b)
    }
}

# --- fork actions

function Invoke-OpenFork([string]$Id) {
    $f = Get-ForkById $Id
    $title = if (Test-Installed (Get-State) $f) { "Opening $($f.name)" } else { "Installing $($f.name)" }
    Start-Work $title { $f = Get-ForkById $A; Open-Fork $f } $Id
}

function Invoke-UpdateOne([string]$Id) {
    $f = Get-ForkById $Id
    Start-Work "Updating $($f.name)" { [void](Update-Forks @(Get-ForkById $A) $true); Write-Base } $Id
}

function Invoke-UpdateAll {
    Start-Work 'Updating all forks' {
        try { [void](Sync-Knowledge) } catch { Write-Warning $_.Exception.Message }
        [void](Update-Forks (Get-InstalledForks (Get-State)))
        Write-Base
    }
}

# Looks up the newest build of each fork (nothing is installed) and returns one result per fork.
$script:CheckWork = {
    foreach ($id in $A) {
        $f = Get-ForkById $id
        try {
            $info = Get-LatestInfo $f ''
            $mb = [math]::Round($info.asset.size / 1MB, 1)
            Write-Host "$($f.name): latest $($info.release.tag) ($($info.asset.name), $mb MB)"
            [pscustomobject]@{ id = $id; tag = $info.release.tag; asset = $info.asset.name; size = $info.asset.size; hash = [bool]$info.asset.digest; url = $info.release.url; error = $null }
        }
        catch {
            Write-Warning "$($f.name): $($_.Exception.Message)"
            [pscustomobject]@{ id = $id; error = $_.Exception.Message }
        }
    }
}

function Invoke-Check([string[]]$Ids) {
    if (-not $Ids) {
        $state = Get-State
        $Ids = @(@($script:AllForks | Where-Object { Test-Installed $state $_ }) + @(Get-MissingBuildsGui $state) | ForEach-Object { $_.id } | Select-Object -Unique)
        if (-not $Ids) { $Ids = @($script:Catalog.forks | ForEach-Object { $_.id }) }
    }
    $title = if ($Ids.Count -eq 1) { "Checking $((Get-ForkById $Ids[0]).name)" } else { "Checking $($Ids.Count) forks for updates" }
    Start-Work $title $script:CheckWork $Ids {
        param($Result, $Failed)
        foreach ($r in $Result) { if ($r -and $r.id) { $script:Latest[$r.id] = $r } }
        $new = @($Result | Where-Object { $_ -and -not $_.error } | Where-Object {
                $e = Get-Entry (Get-State) $_.id
                $e -and $e.tag -ne $_.tag
            })
        if ($new.Count) { Add-Log "Updates available: $(($new | ForEach-Object { (Get-ForkById $_.id).name }) -join ', '). Click Update all to install them." }
    }
}

# Lists the versions that can be installed: releases with a Windows build that matches this fork's rules
# (the API returns the 15 newest), or for an Actions fork its recent successful builds. One API request.
$script:VersionsWork = {
    $f = Get-ForkById $A
    if ($f.source -eq 'actions') {
        $url = "https://api.github.com/repos/$($f.repo)/actions/workflows/$($f.workflow)/runs?status=success&per_page=15"
        if ($f.branch) { $url += "&branch=$($f.branch)" }
        $runs = @((Get-JsonUrl $url).workflow_runs)
        foreach ($run in $runs) {
            $date = [DateTimeOffset]::Parse([string]$run.updated_at, [Globalization.CultureInfo]::InvariantCulture)
            [pscustomobject]@{
                tag     = "build-$($run.run_number) ($($run.head_branch) $($run.head_sha.Substring(0, 7)))"
                date    = $date.ToString('yyyy-MM-dd')
                name    = [string]$run.display_title
                expired = ([DateTimeOffset]::Now - $date).TotalDays -gt 7
            }
        }
        Write-Host "$($f.name): found $($runs.Count) recent builds."
    }
    else {
        $count = 0
        foreach ($r in (Get-Releases $f)) {
            if (-not (Find-Asset $f $r)) { continue }
            $count++
            [pscustomobject]@{ tag = $r.tag; date = $r.date.ToString('yyyy-MM-dd'); name = $r.name; expired = $false }
        }
        Write-Host "$($f.name): $count recent releases have a matching Windows build."
    }
}

function Invoke-InstallVersion([string]$Id) {
    $f = Get-ForkById $Id
    $script:PickerId = $Id
    Start-Work "Looking up the versions of $($f.name)" $script:VersionsWork $Id {
        param($Result, $Failed)
        Show-VersionPicker $script:PickerId @($Result | Where-Object { $_ -and $_.tag }) $Failed
    }
}

function Show-VersionPicker([string]$Id, [object[]]$Versions, [string]$Failed) {
    $f = Get-ForkById $Id
    $e = Get-Entry (Get-State) $Id
    $labels = foreach ($v in $Versions) {
        $marks = @()
        if ($e -and $e.tag -eq $v.tag) { $marks += 'installed' }
        elseif ($e -and $e.previous -and $e.previous.tag -eq $v.tag) { $marks += 'previous' }
        if ($v.expired) { $marks += 'artifact likely expired' }
        $label = "$($v.tag)    $($v.date)"
        # The release title, unless it only repeats the tag (v0.9.2 / 0.9.2).
        if ($v.name -and $f.source -ne 'actions' -and ($v.name -replace '^v', '') -ne ($v.tag -replace '^v', '')) { $label += "    $($v.name)" }
        if ($marks) { $label += "    ($($marks -join ', '))" }
        $label
    }
    $message = 'The installed version moves to the previous slot, so you can roll back.'
    if ($Failed) { $message += "`n`nThe version list could not be loaded ($Failed). Type the tag under Custom." }
    elseif (-not $Versions.Count) { $message += "`n`nNo recent version with a matching Windows build was found. Type the tag under Custom." }
    $hint = if ($f.source -eq 'actions') { 'Custom: an Actions build name, for example build-80. Artifacts expire after 7 days.' } else { 'Custom: a release tag exactly as on the releases page, also an older one not listed here.' }
    $r = Show-Dialog -Title "Install a version of $($f.name)" -Message $message -Choices @($labels) -Custom 'Custom...' -Hint $hint -Buttons @('Install', 'Cancel')
    if ($r.Button -ne 'Install') { return }
    $tag = if ($r.IsCustom) { $r.Text.Trim() } else { $Versions[$r.Choice].tag }
    if (-not $tag) { return }
    Start-Work "Installing $($f.name) $tag" {
        $f = Get-ForkById $A.id
        Install-Release $f (Get-LatestInfo $f $A.tag)
        Write-Base
    } @{ id = $Id; tag = $tag }
}

function Invoke-Rollback([string]$Id) {
    $f = Get-ForkById $Id
    $e = Get-Entry (Get-State) $Id
    $r = Show-Dialog -Title "Roll back $($f.name)?" -Message "Swaps $($e.tag) with the previous version $($e.previous.tag) and pins it, so the next update does not undo it. Unpin it to get updates again." -Buttons @('Roll back', 'Cancel')
    if ($r.Button -ne 'Roll back') { return }
    Start-Work "Rolling back $($f.name)" { Restore-Previous (Get-ForkById $A); Write-Base } $Id
}

function Invoke-Pin([string]$Id) {
    $f = Get-ForkById $Id
    $e = Get-Entry (Get-State) $Id
    if (Invoke-Quick { Set-Pin $f (-not $e.pinned); Write-Base }) { Update-All }
}

function Invoke-DeleteBuild([string]$Id) {
    $f = Get-ForkById $Id
    $state = Get-State
    $e = Get-Entry $state $Id
    $msg = "Deletes the installed files of $($f.name) ($($e.tag)) and its previous version. The fork stays in the list: opening it installs it again. Zip backups are kept."
    $visible = @($script:Catalog.forks | Where-Object { $_.id -eq $Id }).Count -gt 0
    $sibling = @($script:AllForks | Where-Object { $_.base_id -eq $f.base_id -and $_.id -ne $f.id -and (Test-Installed $state $_) }).Count -gt 0
    if ($visible -and $sibling) { $msg += "`n`nThis build is in your build type ($(Get-BuildTypeLabel)) and another build of this fork is installed, so the next update installs it again. Change the build type in Settings to stop that." }
    $r = Show-Dialog -Title "Delete $($f.name)?" -Message $msg -Buttons @('Delete', 'Cancel') -Danger
    if ($r.Button -ne 'Delete') { return }
    Start-Work "Deleting $($f.name)" { Remove-Build (Get-ForkById $A); Write-Base } $Id
}

function Invoke-RemoveFork([string]$Id) {
    $f = Get-ForkById $Id
    $what = if ($f.pgo) { "$($f.name -replace '\s*\(PGO\)$', '') (MSVC and PGO builds)" } else { $f.name }
    $r = Show-Dialog -Title "Remove $what?" -Message 'Removes the fork you added from the list and deletes its installed files and zip backups.' -Buttons @('Remove', 'Cancel') -Danger
    if ($r.Button -ne 'Remove') { return }
    $script:SelectedFork = $null
    Start-Work "Removing $what" { Remove-CustomFork (Get-ForkById $A); Write-Base } $Id
}

function Invoke-AddFork {
    $r = Show-Dialog -Title 'Add a fork from a link' -Message 'The tool finds the Windows zip in the newest releases (or Actions runs), makes a rule that also matches future builds, and checks it.' -Ask -Hint "Works with:`n  GitHub repository, releases page or release`n  Forgejo or Gitea repository`n  GitHub Actions workflow, for forks that publish builds only through Actions" -Buttons @('Add', 'Cancel')
    if ($r.Button -ne 'Add' -or -not $r.Text.Trim()) { return }
    Start-Work 'Adding a fork' { $f = Add-CustomFork $A; $f.id } $r.Text.Trim() {
        param($Result, $Failed)
        if ($Failed) { return }
        $id = @($Result | Where-Object { $_ -is [string] }) | Select-Object -Last 1
        if (-not $id) { return }
        $script:SelectedFork = $id
        $f = Get-ForkById $id
        $q = Show-Dialog -Title "Added $($f.name)" -Message 'Install and open it now?' -Buttons @('Install and open', 'Later')
        if ($q.Button -eq 'Install and open') { Invoke-OpenFork $id }
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Games page

$script:SelectedGame = $null

function Update-GamesPage {
    $state = Get-State
    $games = @(Get-Games)
    $rows = foreach ($g in $games) {
        $inst = '-'
        if ($g.fork) {
            $e = Get-Entry $state $g.fork.id
            $inst = if ($e -and (Test-Installed $state $g.fork)) { $e.tag } else { 'not installed' }
        }
        [pscustomobject]@{ Game = $g.game; Pick = (Get-PickLabel $g); Installed = $inst }
    }
    $UI.GameList.ItemsSource = @($rows)
    $src = Read-JsonFile (Join-Path $script:CacheDir 'source.json')
    $UI.GamesSub.Text = if ($src) { "From the $($script:Catalog.knowledge_source) guide, commit $($src.sha.Substring(0, 10)). Community reports, not benchmarks: your own notes win." } else { 'The guide is not synced yet. Click Sync the guide.' }
    if ($script:SelectedGame) {
        $row = @($rows | Where-Object { $_.Game -eq $script:SelectedGame }) | Select-Object -First 1
        if ($row) { $UI.GameList.SelectedItem = $row } else { $script:SelectedGame = $null }
    }
    Show-GameDetail
}

function Show-GameDetail {
    $UI.GActions.Children.Clear()
    $g = $null
    if ($script:SelectedGame) { $g = @(Get-Games | Where-Object { $_.game -eq $script:SelectedGame }) | Select-Object -First 1 }
    foreach ($n in 'GAltTitle', 'GAlt', 'GEvTitle', 'GEv', 'GNotesTitle', 'GNotes') { $UI[$n].Visibility = if ($g) { 'Visible' } else { 'Collapsed' } }
    if (-not $g) {
        $UI.GName.Text = 'Select a game'
        $UI.GPick.Text = 'Its recommended fork, the guide''s evidence and your notes show here.'
        return
    }
    $UI.GName.Text = $g.game
    $UI.GPick.Text = "Recommended: $(Get-PickLabel $g)"
    if ($g.fork) {
        $b = New-ActionButton "Play with $($g.fork.name)" { $gg = @(Get-Games | Where-Object { $_.game -eq $script:SelectedGame })[0]; Invoke-OpenFork $gg.fork.id } 'Primary'
        [void]$UI.GActions.Children.Add($b)
    }
    [void]$UI.GActions.Children.Add((New-ActionButton 'Add a note...' { Invoke-AddNote $script:SelectedGame }))
    $others = @($g.candidates | Where-Object { -not ($g.fork -and $_.fork -and $_.fork.id -eq $g.fork.id) } | ForEach-Object { $_.label })
    $UI.GAlt.Text = if ($others.Count) { $others -join "`n" } else { 'none' }
    $UI.GEv.Text = if ($g.evidence) { $g.evidence } else { 'none' }
    $UI.GNotes.Text = if ($g.note -and $g.note.history) { (@($g.note.history) | ForEach-Object { "$($_.date), $($_.fork) $($_.tag): $($_.note)" }) -join "`n`n" } else { 'No notes yet. Add one after you test a fork with this game.' }
}

function Invoke-AddNote([string]$Game) {
    $forks = @($script:Catalog.forks)
    $state = Get-State
    $names = $forks | ForEach-Object { $e = Get-Entry $state $_.id; if ($e -and (Test-Installed $state $_)) { "$($_.name)   ($($e.tag))" } else { $_.name } }
    $g = @(Get-Games | Where-Object { $_.game -eq $Game })[0]
    $sel = if ($g.fork) { [array]::IndexOf(@($forks | ForEach-Object id), $g.fork.id) } else { -1 }
    $r = Show-Dialog -Title "Note for $Game" -Message 'Which fork did you test, and how did it run?' -Items $names -Selected $sel -Ask -Hint 'For example: 60 fps in the open world, crash in the first boss fight.' -Check 'Make this fork the default for this game' -Buttons @('Save', 'Cancel')
    if ($r.Button -ne 'Save') { return }
    if ($r.Index -lt 0) { Show-Dialog -Title 'Choose a fork' -Message 'Select the fork you tested in the list.' | Out-Null; return }
    $f = $forks[$r.Index]
    if (Invoke-Quick { Add-Note $Game $f $r.Text $r.Checked }) { Update-All }
}

# ---------------------------------------------------------------------------------------------------------------
# NX2 switches page

$script:SelectedSwitch = $null

function Update-SwitchesPage {
    try { Complete-Nx2Notes } catch { }
    $rows = foreach ($s in @(Get-Nx2Switches)) {
        [pscustomobject]@{ Name = $s.name; Line = "$($s.name)=$($s.value)"; Note = [string]$s.note; Enabled = [bool]$s.enabled }
    }
    $UI.SwitchList.ItemsSource = @($rows)
    if ($script:SelectedSwitch) {
        $row = @($rows | Where-Object { $_.Name -eq $script:SelectedSwitch }) | Select-Object -First 1
        if ($row) { $UI.SwitchList.SelectedItem = $row } else { $script:SelectedSwitch = $null }
    }
    Show-SwitchDetail
}

function Get-SelectedSwitch { return @(Get-Nx2Switches | Where-Object { $_.name -eq $script:SelectedSwitch }) | Select-Object -First 1 }

function Show-SwitchDetail {
    $s = Get-SelectedSwitch
    $UI.SActions.Visibility = if ($s) { 'Visible' } else { 'Collapsed' }
    if (-not $s) {
        $UI.SName.Text = 'Select a switch'
        $UI.SState.Text = if (@(Get-Nx2Switches).Count) { '' } else { 'No switches yet. Add one, paste several, or copy lines from an nx2_switches.txt and add them from the clipboard.' }
        $UI.SNote.Text = ''
        return
    }
    $UI.SName.Text = "$($s.name)=$($s.value)"
    $UI.SState.Text = if ($s.enabled) { 'On: written to every installed fork' } else { 'Off: the forks keep their own value' }
    $UI.SNote.Text = if ($s.note) { $s.note } else { 'No description.' }
    $UI.BtnSwToggle.Content = if ($s.enabled) { 'Turn off' } else { 'Turn on' }
}

function Set-SwitchEnabled([string]$Name, [bool]$On) {
    $list = @(Get-Nx2Switches)
    $s = $list | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $s) { return }
    Set-Prop $s 'enabled' $On
    if (Invoke-Quick { Save-Nx2Switches $list; Write-Host "$Name is now $(if ($On) { 'on' } else { 'off' })."; Update-Nx2All }) { Update-All }
}

function Invoke-AddSwitchLines([string[]]$Lines) {
    if (Invoke-Quick { if (Add-Nx2Lines $Lines) { Update-Nx2All } }) { Update-All }
}

# ---------------------------------------------------------------------------------------------------------------
# Settings page

$script:Rendering = $false

function Update-SettingsPage {
    $script:Rendering = $true
    try {
        switch (Get-BuildType) { 'pgo' { $UI.BtPgo.IsChecked = $true } 'both' { $UI.BtBoth.IsChecked = $true } default { $UI.BtMsvc.IsChecked = $true } }
        $limit = Get-ZipBackupLimit
        if ($limit -lt 0) { $UI.ZipAll.IsChecked = $true; $UI.ZipN.Text = '3' }
        elseif ($limit -eq 0) { $UI.ZipNone.IsChecked = $true; $UI.ZipN.Text = '3' }
        else { $UI.ZipCount.IsChecked = $true; $UI.ZipN.Text = "$limit" }
        switch ([string]$script:Config.gpu) { 'NVIDIA' { $UI.GpuNvidia.IsChecked = $true } 'AMD' { $UI.GpuAmd.IsChecked = $true } 'Intel' { $UI.GpuIntel.IsChecked = $true } default { $UI.GpuOff.IsChecked = $true } }
        $UI.IntervalBox.Text = if ($script:Config.check_interval_minutes) { "$($script:Config.check_interval_minutes)" } else { '60' }
        $UI.InstallDirText.Text = $script:ForksDir
        $UI.ChkForksOnStart.IsChecked = Get-ConfigFlag 'check_forks_on_start' $true
        $UI.ChkAppOnStart.IsChecked = Get-ConfigFlag 'check_app_updates_on_start' $true
        $UI.ChkAppBackup.IsChecked = Get-ConfigFlag 'app_backup' $true
        Update-AppSection
    }
    finally { $script:Rendering = $false }
}

# ---------------------------------------------------------------------------------------------------------------
# App updates (the functions are in $script:AppUpdateCode at the top)

$script:AppInfo = $null   # result of the last check

function Update-AppSection {
    $v = Read-JsonFile $script:AppVersionFile
    $UI.AppVersionText.Text = if ($v -and $v.sha) { "$($v.sha.Substring(0, 7)), committed $($v.date)" + $(if ($v.updated) { "   (installed $($v.updated))" } else { '' }) } else { 'Not known yet: Check now compares your files with the newest commit.' }
    $src = Get-AppSource
    $custom = [bool]([string]$script:Config.app_repo -or [string]$script:Config.app_branch)
    $UI.AppSourceText.Text = "github.com/$($src.Repo), branch $($src.Branch)" + $(if ($custom) { '   (your choice)' } else { '   (default)' })
    # Leave the boxes alone while you type in them.
    if (-not $UI.AppRepoBox.IsKeyboardFocusWithin) { $UI.AppRepoBox.Text = $src.Repo }
    if (-not $UI.AppBranchBox.IsKeyboardFocusWithin) { $UI.AppBranchBox.Text = $src.Branch }
    $UI.BtnAppSourceDefault.IsEnabled = $custom
    $i = $script:AppInfo
    if (-not $i) { $UI.AppStatusText.Text = 'Not checked since the window opened.'; $UI.AppStatusText.Foreground = Brush '#C9CDD3' }
    elseif ($i.UpToDate) { $UI.AppStatusText.Text = "Up to date with $($i.Sha.Substring(0, 7)) ($($i.Date))."; $UI.AppStatusText.Foreground = Brush '#3FB950' }
    else { $UI.AppStatusText.Text = "Newer version $($i.Sha.Substring(0, 7)) ($($i.Date)): $($i.Changed.Count) file(s) change."; $UI.AppStatusText.Foreground = Brush '#7FAAFF' }
    $UI.BtnAppUpdate.Visibility = if ($i -and -not $i.UpToDate) { 'Visible' } else { 'Collapsed' }
    $UI.BtnAppRestore.IsEnabled = (@(Get-AppBackups).Count -gt 0)
    if ($i -and -not $i.UpToDate) {
        $n = @($i.Commits).Count
        $what = if ($n -gt 1) { "$n new commits" } else { "the latest commit: $(@($i.Commits)[0].title)" }
        $UI.AppBannerText.Text = "A new version of NX Fork Manager is available ($what)."
        $UI.AppBanner.Visibility = 'Visible'
    }
    else { $UI.AppBanner.Visibility = 'Collapsed' }
}

function Set-AppInfo($Result) {
    $info = @($Result | Where-Object { $_ -and $_.Kind -eq 'app' }) | Select-Object -Last 1
    if ($info) { $script:AppInfo = $info }
}

function Invoke-AppCheck {
    Start-Work 'Checking for a new version of NX Fork Manager' { Get-AppUpdateInfo } $null {
        param($Result, $Failed)
        if ($Failed) { return }
        Set-AppInfo $Result
        if ($script:AppInfo -and $script:AppInfo.UpToDate) {
            Show-Dialog -Title 'NX Fork Manager is up to date' -Message "Your files match the newest commit $($script:AppInfo.Sha.Substring(0, 7)) ($($script:AppInfo.Date))." | Out-Null
        }
        elseif ($script:AppInfo) { Show-AppUpdateDialog }
    }
}

function Show-AppUpdateDialog {
    $i = $script:AppInfo
    if (-not $i -or $i.UpToDate) { return }
    $list = @($i.Commits | Select-Object -First 12 | ForEach-Object { "   $($_.date)   $($_.title)" })
    $more = @($i.Commits).Count - $list.Count
    $msg = "New since your version:`n" + ($list -join "`n")
    if ($more -gt 0) { $msg += "`n   ... and $more more" }
    $msg += "`n`n$($i.Changed.Count) file(s) change: $(($i.Changed | Select-Object -First 6) -join ', ')$(if ($i.Changed.Count -gt 6) { ', ...' })"
    $hint = 'The window restarts after the update. Your settings, forks, notes and switches are not touched.'
    if (Test-Path -LiteralPath (Join-Path $script:Here '.git')) {
        $hint = "This folder is a git checkout. Updating overwrites the changed files with $($i.Repo) $($i.Branch), also any local changes or another branch you have checked out there (they stay in the backup). With git, 'git pull' is the usual way."
    }
    $r = Show-Dialog -Title "Update NX Fork Manager to $($i.Sha.Substring(0, 7))?" -Message $msg -Hint $hint -Check 'Back up the current version first' -Checked (Get-ConfigFlag 'app_backup' $true) -Buttons @('Update', 'Later')
    if ($r.Button -ne 'Update') { return }
    Start-Work 'Updating NX Fork Manager' { Install-AppUpdate $A.Sha $A.Backup } @{ Sha = $i.Sha; Backup = $r.Checked } {
        param($Result, $Failed)
        if ($Failed) { return }
        $script:AppInfo = $null
        Request-Restart 'NX Fork Manager was updated.'
    }
}

function Invoke-AppRestore {
    $backups = @(Get-AppBackups)
    if (-not $backups.Count) { Show-Dialog -Title 'No backups yet' -Message 'A backup is made before each app update while the option is on.' | Out-Null; return }
    $labels = foreach ($b in $backups) {
        $ver = if ($b.Sha) { $b.Sha.Substring(0, 7) } else { 'unknown version' }
        $from = if ($b.Date) { ", committed $($b.Date)" } else { '' }
        "$($b.Created)    $ver$from    ($(@($b.Files).Count) files)"
    }
    $r = Show-Dialog -Title 'Restore a previous version' -Message 'Puts the files of a backup back in place. Your settings, forks, notes and switches are not touched.' -Choices @($labels) -Check 'Back up the current version first' -Checked $true -Buttons @('Restore', 'Cancel')
    if ($r.Button -ne 'Restore' -or $r.Choice -lt 0) { return }
    Start-Work 'Restoring a previous version' { Restore-AppBackup $A.Name $A.Backup } @{ Name = $backups[$r.Choice].Name; Backup = $r.Checked } {
        param($Result, $Failed)
        if ($Failed) { return }
        $script:AppInfo = $null
        Request-Restart 'The previous version was restored.'
    }
}

# "owner/repo", "https://github.com/owner/repo(.git)" or ".../tree/branch" -> { Repo; Branch } (Branch may be empty).
function ConvertFrom-AppSourceText([string]$Text, [string]$Branch) {
    $t = $Text.Trim().Trim('"').TrimEnd('/')
    $fromLink = ''
    if ($t -match '^(?:https?://)?(?:www\.)?github\.com/([\w.-]+)/([\w.-]+?)(?:\.git)?(?:/tree/([^?#]+))?(?:[?#].*)?$') {
        $repo = "$($Matches[1])/$($Matches[2])"
        $fromLink = [string]$Matches[3]
    }
    elseif ($t -match '^([\w.-]+)/([\w.-]+?)(?:\.git)?$') { $repo = "$($Matches[1])/$($Matches[2])" }
    else { throw 'Type the repository as owner/repository or paste its github.com link, for example Schroederr/nx-fork-manager.' }
    $b = $Branch.Trim()
    if (-not $b) { $b = $fromLink }
    return [pscustomobject]@{ Repo = $repo; Branch = $b }
}

# Checks the source on GitHub before saving it: the repository and branch exist and hold fork-manager.ps1.
function Save-AppSource {
    try { $src = ConvertFrom-AppSourceText $UI.AppRepoBox.Text $UI.AppBranchBox.Text }
    catch { Show-Dialog -Title 'Not a repository' -Message $_.Exception.Message | Out-Null; return }
    Start-Work "Checking github.com/$($src.Repo)" {
        $repo = $A.Repo
        try { $info = Get-JsonUrl "https://api.github.com/repos/$repo" }
        catch { throw "github.com/$repo was not found (or is private). Check the owner and repository name. ($($_.Exception.Message))" }
        $branch = if ($A.Branch) { $A.Branch } else { [string]$info.default_branch }
        try { $b = Get-JsonUrl "https://api.github.com/repos/$repo/branches/$([uri]::EscapeDataString($branch))" }
        catch { throw "github.com/$repo has no branch '$branch'. ($($_.Exception.Message))" }
        try { [void](Get-JsonUrl "https://api.github.com/repos/$repo/contents/fork-manager.ps1?ref=$([uri]::EscapeDataString($branch))") }
        catch { throw "github.com/$repo ($branch) has no fork-manager.ps1, so it is not nx-fork-manager. Nothing was saved." }
        Write-Host "Update source OK: github.com/$($info.full_name), branch $branch, newest commit $($b.commit.sha.Substring(0, 7))."
        [pscustomobject]@{ Kind = 'source'; Repo = [string]$info.full_name; Branch = $branch; Explicit = [bool]$A.Branch; Default = [string]$info.default_branch }
    } $src {
        param($Result, $Failed)
        if ($Failed) { return }
        $ok = @($Result | Where-Object { $_ -and $_.Kind -eq 'source' })[0]
        if (-not $ok) { return }
        $isDefault = $ok.Repo -ieq 'Schroederr/nx-fork-manager' -and $ok.Branch -eq 'main'
        if ($isDefault) { Reset-AppSource -Quiet }
        else {
            # The branch is saved as checked (an empty box meant the repository's default branch).
            Invoke-Quick {
                Save-ConfigValue 'app_repo' $ok.Repo
                Save-ConfigValue 'app_branch' $ok.Branch
                Write-Host "App updates now come from github.com/$($ok.Repo), branch $($ok.Branch)."
            } | Out-Null
        }
        $script:AppInfo = $null
        Set-AppSourceEditor $false
        Update-All
        $q = Show-Dialog -Title 'Update source saved' -Message "App updates now come from github.com/$($ok.Repo), branch $($ok.Branch). Check it now?" -Buttons @('Check now', 'Later')
        if ($q.Button -eq 'Check now') { Invoke-AppCheck }
    }
}

# The Update source box stays hidden until Edit. Closing it puts the saved source back in the boxes.
function Set-AppSourceEditor([bool]$Open) {
    $UI.AppSourcePanel.Visibility = if ($Open) { 'Visible' } else { 'Collapsed' }
    $UI.BtnAppSourceEdit.Content = if ($Open) { 'Close' } else { 'Edit' }
    if ($Open) {
        $src = Get-AppSource
        $UI.AppRepoBox.Text = $src.Repo
        $UI.AppBranchBox.Text = $src.Branch
        $UI.AppRepoBox.Focus() | Out-Null
        $UI.AppRepoBox.SelectAll()
    }
    else { [Windows.Input.Keyboard]::ClearFocus(); Update-AppSection }
}

function Reset-AppSource([switch]$Quiet) {
    foreach ($k in 'app_repo', 'app_branch') { $script:Config.PSObject.Properties.Remove($k) }
    Invoke-Quick { Write-JsonFile $script:ConfigFile $script:Config; Write-Host 'App updates come from the default source again: github.com/Schroederr/nx-fork-manager, branch main.' } | Out-Null
    $script:AppInfo = $null
    Update-All
}

function Request-Restart([string]$What) {
    $r = Show-Dialog -Title $What -Message 'Restart the window now to use it? The menu (ForkManager.cmd) uses the new files the next time it starts.' -Buttons @('Restart now', 'Later')
    if ($r.Button -ne 'Restart now') { return }
    $exe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-Sta', '-ExecutionPolicy', 'Bypass', '-File', "`"$script:GuiPath`"") -WindowStyle Hidden
    $script:Win.Close()
}

function Invoke-BuildTypeChange([string]$Value) {
    if ($script:Rendering -or $Value -eq (Get-BuildType)) { return }
    if (-not (Invoke-Quick { Set-BuildType $Value })) { return }
    Update-All
    $state = Get-State
    $missing = @(Get-MissingBuildsGui $state)
    if ($missing.Count) {
        $r = Show-Dialog -Title "Download the $(Get-BuildTypeLabel) builds?" -Message "Not installed yet for the forks you use:`n$(($missing | ForEach-Object { '   ' + $_.name }) -join "`n")" -Hint 'If you say no, nothing downloads until you click Update all (or open one of them).' -Buttons @('Download now', 'Not now')
        if ($r.Button -eq 'Download now') {
            Start-Work "Downloading $($missing.Count) build(s)" { [void](Update-Forks @($A | ForEach-Object { Get-ForkById $_ }) $true); Write-Base } @($missing | ForEach-Object { $_.id }) {
                param($Result, $Failed)
                Request-RemoveHidden
            }
            return
        }
    }
    Request-RemoveHidden
}

# Offers to remove installed builds outside the new build type. A build is removed only when the fork has a
# build of the selected type installed: a fork with nothing installed would stop getting updates.
function Request-RemoveHidden {
    $state = Get-State
    $hidden = @(Get-HiddenInstalled $state)
    if (-not $hidden.Count) { return }
    $types = @($hidden | ForEach-Object { Get-VariantLabel $_ } | Select-Object -Unique) -join ' and '
    $r = Show-Dialog -Title "Remove the $types builds?" -Message "Still installed, outside your build type:`n$(($hidden | ForEach-Object { '   ' + $_.name }) -join "`n")" -Hint "A build is only removed when the fork has a $(Get-BuildTypeLabel) build installed. If you keep them, they show in their own section and get no updates." -Buttons @('Remove', 'Keep') -Danger
    if ($r.Button -ne 'Remove') { return }
    Start-Work "Removing $types builds" {
        $state = Get-State
        foreach ($id in $A) {
            $h = Get-ForkById $id
            $replacement = @($script:Catalog.forks | Where-Object { $_.base_id -eq $h.base_id -and (Test-Installed $state $_) })
            if (-not $replacement.Count) { Write-Host "Kept $($h.name): its $(Get-BuildTypeLabel) build is not installed yet."; continue }
            try { Remove-Build $h } catch { Write-Warning $_.Exception.Message }
        }
        Write-Base
    } @($hidden | ForEach-Object { $_.id })
}

function Save-ConfigValue([string]$Name, $Value) {
    Set-Prop $script:Config $Name $Value
    Write-JsonFile $script:ConfigFile $script:Config
}

# ---------------------------------------------------------------------------------------------------------------
# Whole-window refresh

function Update-All {
    Update-ForksPage
    Update-GamesPage
    Update-SwitchesPage
    Update-SettingsPage
    $on = @(Get-Nx2Switches | Where-Object { $_.enabled }).Count
    $UI.SideSub.Text = "Builds: $(Get-BuildTypeLabel)`nZip backups: $(Get-ZipBackupLabel)`nNX2 switches on: $on"
    $UI.TokenInfo.Text = if ($env:GITHUB_TOKEN) { 'GitHub token set: 5000 API requests per hour.' } else { 'No GitHub token: 60 API requests per hour, shared with your network.' }
}

# ---------------------------------------------------------------------------------------------------------------
# Events

$script:Pages = $script:Pages = $pages = @{ NavForks = 'PageForks'; NavGames = 'PageGames'; NavSwitches = 'PageSwitches'; NavSettings = 'PageSettings'; NavLog = 'PageLog' }
foreach ($nav in $pages.Keys) {
    $UI[$nav].add_Checked({
            foreach ($k in $script:Pages.Keys) { $UI[$script:Pages[$k]].Visibility = if ($UI[$k].IsChecked) { 'Visible' } else { 'Collapsed' } }
        })
}

$UI.BtnToken.add_Click({
        $r = Show-Dialog -Title 'GitHub tokens' -Message "Without a login, GitHub allows 60 API requests per hour per IP address. A token raises that to 5000, only for you, and lets Actions builds download straight from GitHub.`n`n1. Create a token with 'Public repositories' access and no permissions.`n2. In a Command Prompt run:  setx GITHUB_TOKEN `"your-token`"`n3. Close and reopen this window." -Buttons @('Create a token', 'Close')
        if ($r.Button -eq 'Create a token') { Open-Url 'https://github.com/settings/personal-access-tokens/new' }
    })

# Forks
$UI.ForkList.add_SelectionChanged({
        $row = $UI.ForkList.SelectedItem
        if ($row) { $script:SelectedFork = $row.Id; Show-ForkDetail }
    })
$UI.ForkList.add_MouseDoubleClick({ if ($UI.ForkList.SelectedItem -and -not $script:Job) { Invoke-OpenFork $UI.ForkList.SelectedItem.Id } })
$UI.BtnAddFork.add_Click({ Invoke-AddFork })
$UI.BtnCheck.add_Click({ Invoke-Check $null })
$UI.BtnUpdateAll.add_Click({ Invoke-UpdateAll })

# Games
$UI.GameList.add_SelectionChanged({
        $row = $UI.GameList.SelectedItem
        if ($row) { $script:SelectedGame = $row.Game; Show-GameDetail }
    })
$UI.BtnSync.add_Click({
        Start-Work 'Syncing the guide' {
            $changed = Sync-Knowledge
            Write-Base
            if ($changed) { Write-Host 'Guide updated.' } else { Write-Host 'Guide was already up to date.' }
        }
    })
$UI.BtnGamesMd.add_Click({ if (Test-Path -LiteralPath $script:GamesFile) { Start-Process $script:GamesFile | Out-Null } else { Show-Dialog -Title 'GAMES.md does not exist yet' -Message 'Sync the guide first.' | Out-Null } })

# NX2 switches
$UI.SwitchList.add_SelectionChanged({
        $row = $UI.SwitchList.SelectedItem
        if ($row) { $script:SelectedSwitch = $row.Name; Show-SwitchDetail }
    })
$UI.SwitchList.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler] {
        param($s, $e)
        $cb = $e.OriginalSource
        if ($cb -is [Windows.Controls.CheckBox]) { Set-SwitchEnabled ([string]$cb.Tag) ([bool]$cb.IsChecked) }
    })
$UI.BtnSwAdd.add_Click({
        $r = Show-Dialog -Title 'Add a switch' -Message 'Type it as NAME=VALUE. A name you already have gets the new value and is turned on.' -Ask -Default 'EDEN_NX2_' -Buttons @('Add', 'Cancel')
        if ($r.Button -eq 'Add' -and $r.Text.Trim()) { if (Invoke-Quick { Add-Nx2Switch $r.Text; Update-Nx2All }) { Update-All } }
    })
$UI.BtnSwPaste.add_Click({
        $r = Show-Dialog -Title 'Paste several switches' -Message 'Paste lines from an nx2_switches.txt. The comment above a switch becomes its description.' -Ask -Multiline -Hint 'Blank lines and comment lines are skipped, also disabled examples such as #EDEN_NX2_SPLIT=1.' -Buttons @('Add', 'Cancel')
        if ($r.Button -eq 'Add' -and $r.Text.Trim()) { Invoke-AddSwitchLines ($r.Text -split "`r?`n") }
    })
$UI.BtnSwClip.add_Click({
        $text = [Windows.Clipboard]::GetText()
        if (-not $text.Trim()) { Show-Dialog -Title 'The clipboard is empty' -Message 'Copy the switch lines first.' | Out-Null; return }
        Invoke-AddSwitchLines ($text -split "`r?`n")
    })
$UI.BtnSwApply.add_Click({ Invoke-Quick { Update-Nx2All } | Out-Null; Update-All })
$UI.BtnSwToggle.add_Click({ $s = Get-SelectedSwitch; if ($s) { Set-SwitchEnabled $s.name (-not $s.enabled) } })
$UI.BtnSwValue.add_Click({
        $s = Get-SelectedSwitch
        if (-not $s) { return }
        $r = Show-Dialog -Title "Change $($s.name)" -Ask -Default "$($s.name)=$($s.value)" -Buttons @('Save', 'Cancel')
        if ($r.Button -eq 'Save' -and $r.Text.Trim()) { if (Invoke-Quick { Add-Nx2Switch $r.Text; Update-Nx2All }) { Update-All } }
    })
$UI.BtnSwNote.add_Click({
        $s = Get-SelectedSwitch
        if (-not $s) { return }
        $r = Show-Dialog -Title "Description of $($s.name)" -Ask -Default ([string]$s.note) -Hint 'Cleared descriptions stay empty: they are not filled in from the forks again.' -Buttons @('Save', 'Clear', 'Cancel')
        if ($r.Button -eq 'Save' -and $r.Text.Trim()) { if (Invoke-Quick { Set-Nx2Note $s $r.Text }) { Update-All } }
        elseif ($r.Button -eq 'Clear' -or ($r.Button -eq 'Save' -and -not $r.Text.Trim())) { if (Invoke-Quick { Set-Nx2Note $s '-' }) { Update-All } }
    })
$UI.BtnSwDelete.add_Click({
        $s = Get-SelectedSwitch
        if (-not $s) { return }
        $r = Show-Dialog -Title "Delete $($s.name)?" -Message 'The forks get their own value back.' -Buttons @('Delete', 'Cancel') -Danger
        if ($r.Button -ne 'Delete') { return }
        $list = @(Get-Nx2Switches | Where-Object { $_.name -ne $s.name })
        $script:SelectedSwitch = $null
        if (Invoke-Quick { Save-Nx2Switches $list; Write-Host "Deleted $($s.name)."; Update-Nx2All }) { Update-All }
    })

# Settings
$UI.BtMsvc.add_Checked({ Invoke-BuildTypeChange 'msvc' })
$UI.BtPgo.add_Checked({ Invoke-BuildTypeChange 'pgo' })
$UI.BtBoth.add_Checked({ Invoke-BuildTypeChange 'both' })
$UI.BtnZipSave.add_Click({
        $v = if ($UI.ZipAll.IsChecked) { 'all' } elseif ($UI.ZipCount.IsChecked) { $UI.ZipN.Text.Trim() } else { '0' }
        if (Invoke-Quick { Set-ZipBackups $v }) { Update-All }
    })
$UI.ZipN.add_GotFocus({ $UI.ZipCount.IsChecked = $true })
# The value rides on the button's Tag: a closure could not see this script's functions.
foreach ($pair in @(@('GpuNvidia', 'NVIDIA'), @('GpuAmd', 'AMD'), @('GpuIntel', 'Intel'), @('GpuOff', ''))) {
    $UI[$pair[0]].Tag = $pair[1]
    $UI[$pair[0]].add_Checked({
            param($s, $e)
            if ($script:Rendering) { return }
            $value = [string]$s.Tag
            if (Invoke-Quick { Save-ConfigValue 'gpu' $value; Write-Host "GPU filter: $(if ($value) { $value } else { 'off' })."; Write-Base }) { Update-All }
        })
}
$UI.BtnIntervalSave.add_Click({
        $n = 0
        if (-not [int]::TryParse($UI.IntervalBox.Text.Trim(), [ref]$n) -or $n -lt 1) { Show-Dialog -Title 'Not a number' -Message 'Type the minutes as a whole number, for example 60.' | Out-Null; return }
        if (Invoke-Quick { Save-ConfigValue 'check_interval_minutes' $n; Write-Host "Update check interval: $n minutes." }) { Update-All }
    })
$UI.BtnOpenForks.add_Click({ New-Item -ItemType Directory -Force -Path $script:ForksDir | Out-Null; Start-Process explorer.exe $script:ForksDir | Out-Null })
$UI.BtnOpenConfig.add_Click({ Start-Process notepad.exe $script:ConfigFile | Out-Null })
$UI.BtnOpenReadme.add_Click({ $p = Join-Path $script:Here 'README.md'; if (Test-Path -LiteralPath $p) { Start-Process notepad.exe $p | Out-Null } })

# Log
$UI.BtnLogCopy.add_Click({ if ($UI.LogBox.Text) { [Windows.Clipboard]::SetText($UI.LogBox.Text) } })
$UI.BtnLogClear.add_Click({ $UI.LogBox.Clear() })

$script:Win.add_Closing({
        param($s, $e)
        if (-not $script:Job) { return }
        $r = Show-Dialog -Title 'Still working' -Message "$($script:Job.Title) is not done. Close anyway? An unfinished install is cleaned up the next time; the installed version stays as it was." -Buttons @('Keep working', 'Close anyway')
        if ($r.Button -ne 'Close anyway') { $e.Cancel = $true; return }
        try { $script:Job.PS.Stop() } catch { }
    })

# App updates and start-up options
$UI.BtnAppCheck.add_Click({ Invoke-AppCheck })
$UI.BtnAppUpdate.add_Click({ Show-AppUpdateDialog })
$UI.BtnAppBanner.add_Click({ Show-AppUpdateDialog })
$UI.BtnAppRestore.add_Click({ Invoke-AppRestore })
$UI.BtnAppHistory.add_Click({ $src = Get-AppSource; Open-Url "https://github.com/$($src.Repo)/commits/$($src.Branch)" })
$UI.BtnAppSourceSave.add_Click({ Save-AppSource })
$UI.BtnAppSourceDefault.add_Click({ Reset-AppSource; Set-AppSourceEditor $false })
$UI.BtnAppSourceEdit.add_Click({ Set-AppSourceEditor ($UI.AppSourcePanel.Visibility -ne 'Visible') })
$UI.BtnAppSourceCancel.add_Click({ Set-AppSourceEditor $false })
foreach ($pair in @(@('ChkForksOnStart', 'check_forks_on_start'), @('ChkAppOnStart', 'check_app_updates_on_start'), @('ChkAppBackup', 'app_backup'))) {
    $UI[$pair[0]].Tag = $pair[1]
    $UI[$pair[0]].add_Click({
            param($s, $e)
            if (Invoke-Quick { Save-ConfigValue ([string]$s.Tag) ([bool]$s.IsChecked); Write-Host "Setting $($s.Tag): $(if ($s.IsChecked) { 'on' } else { 'off' })." }) { Update-All }
        })
}

# When the window opens: sync the guide, update the installed builds (unless turned off) and look for a new
# version of the app (unless turned off; it only shows a notice). Builds of a newly selected type are only listed.
$script:Win.add_ContentRendered({
        $opts = @{ Forks = (Get-ConfigFlag 'check_forks_on_start' $true); App = (Get-ConfigFlag 'check_app_updates_on_start' $true) }
        Start-Work 'Checking the guide and installed forks' {
            try { if (Sync-Knowledge $false) { Write-Host 'Guide updated.' } }
            catch { Write-Warning "Guide sync failed, using the local copy: $($_.Exception.Message)" }
            if ($A.Forks) {
                $state = Get-State
                [void](Update-Forks @(Get-InstalledForks $state | Where-Object { Test-Installed $state $_ }) $false)
            }
            else { Write-Host 'Fork updates when the window opens are off (Settings). Use Check for updates or Update all.' }
            Write-Base
            if ($A.App) {
                try { Get-AppUpdateInfo } catch { Write-Warning "Could not check for a new version of NX Fork Manager: $($_.Exception.Message)" }
            }
        } $opts {
            param($Result, $Failed)
            Set-AppInfo $Result
        }
    })

New-Item -ItemType Directory -Force -Path $script:ForksDir | Out-Null
Add-Log "NX Fork Manager started. Data folder: $script:Here"
Update-All
[void]$script:Win.ShowDialog()
$script:Timer.Stop()
