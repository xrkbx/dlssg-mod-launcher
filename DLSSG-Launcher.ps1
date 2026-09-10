<#
    DLSSG SM86 Mod Launcher
    Selects a game, installs dlssg_for_sm86 next to its render exe, backs up
    everything it touches first, and can roll the whole thing back.

    Requires: Windows PowerShell 5.1+ (built in), NVIDIA RTX 20/30 series.
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------- paths / consts

$Script:Root       = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$Script:ModSrc     = Join-Path $Script:Root 'dlssg_for_sm86-main'
$Script:BackupRoot = Join-Path $Script:Root 'backups'
$Script:StateFile  = Join-Path $Script:Root 'launcher-state.json'
$Script:LogFile    = Join-Path $Script:Root 'launcher.log'
$Script:ModZipUrl  = 'https://codeload.github.com/sdli1995/dlssg_for_sm86/zip/refs/heads/main'

# version.dll lives in the mod root, the rest in altnative\
$Script:ProxyNames = @('version.dll', 'dxgi.dll', 'winmm.dll', 'dinput8.dll', 'winhttp.dll')
$Script:IniName    = 'dlssg_sm86.ini'
$Script:NgxOriginals = @('nvngx_dlssg.dll', 'nvngx_dlss.dll', 'nvngx_dlssd.dll')

# exes that are never the render target
$Script:ExeSkip = 'crash|report|unins|setup|redist|dxsetup|helper|touchup|backup|benchmark|' +
                  'battleye|anticheat|easyanticheat|eac|launcher|activation|prereq|vc_|directx|' +
                  'subprocess|cefsubprocess|eossdk|epiconlineservices|epicgames|crashpad|' +
                  'unitycrashhandler|oalinst|dotnet|dxwebsetup|vcredist|unrealcef'

$Script:Games    = @()
$Script:LogBox   = $null
$Script:GpuName  = 'unknown'
$Script:GpuRoute = 'SM86'

# ---------------------------------------------------------------- helpers

function Write-Log {
    param([string]$Message, [string]$Level = 'info')
    $ts   = (Get-Date).ToString('HH:mm:ss')
    $line = '[{0}] {1}' -f $ts, $Message
    if ($Script:LogBox) {
        $Script:LogBox.AppendText($line + "`r`n")
        $Script:LogBox.SelectionStart = $Script:LogBox.TextLength
        $Script:LogBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
    try { Add-Content -LiteralPath $Script:LogFile -Value ('{0} {1} {2}' -f (Get-Date -Format 's'), $Level.ToUpper(), $Message) -Encoding utf8 } catch { }
}

function Show-Info  { param($m, $t = 'DLSSG Launcher') [void][System.Windows.Forms.MessageBox]::Show($m, $t, 'OK', 'Information') }
function Show-Warn  { param($m, $t = 'DLSSG Launcher') [void][System.Windows.Forms.MessageBox]::Show($m, $t, 'OK', 'Warning') }
function Show-Error { param($m, $t = 'DLSSG Launcher') [void][System.Windows.Forms.MessageBox]::Show($m, $t, 'OK', 'Error') }
function Confirm-Action {
    param($m, $t = 'Confirm')
    return ([System.Windows.Forms.MessageBox]::Show($m, $t, 'YesNo', 'Question') -eq 'Yes')
}

function Get-PathKey {
    param([string]$Name, [string]$Path)
    $md5   = [System.Security.Cryptography.MD5]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Path.ToLower())
    $hash  = ($md5.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    $md5.Dispose()
    $safe = ($Name -replace '[^\w\.\- ]', '_').Trim()
    if (-not $safe) { $safe = 'game' }
    return ('{0}_{1}' -f $safe, $hash.Substring(0, 8))
}

function Test-DirWritable {
    param([string]$Dir)
    try {
        $probe = Join-Path $Dir ('.dlssg_write_test_{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        [System.IO.File]::WriteAllText($probe, 'x')
        Remove-Item -LiteralPath $probe -Force
        return $true
    } catch { return $false }
}

# ---------------------------------------------------------------- admin / defender
#
# The mod trips heuristic AV flags because it proxies a system DLL and uses
# LoadLibrary hooks. The supported, non-destructive fix for a mod you trust on
# your own machine is a Windows Defender *exclusion*: it tells Defender to leave
# a specific folder alone. It is not obfuscation and changes nothing about the
# DLL. Adding or removing exclusions needs an elevated process.

function Test-IsAdmin {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Restart-Elevated {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName   = (Get-Process -Id $PID).Path
    $scriptPath     = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $Script:Root 'DLSSG-Launcher.ps1' }
    $psi.Arguments  = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath
    $psi.Verb       = 'runas'
    try { [void][System.Diagnostics.Process]::Start($psi); return $true }
    catch { return $false }   # user declined the UAC prompt
}

function Test-DefenderAvailable {
    try { return [bool](Get-Command Add-MpPreference -ErrorAction SilentlyContinue) } catch { return $false }
}

function Get-DefenderExclusions {
    try { return @((Get-MpPreference -ErrorAction Stop).ExclusionPath) } catch { return @() }
}

function Test-PathExcluded {
    param([string]$Path)
    if (-not $Path) { return $false }
    foreach ($e in (Get-DefenderExclusions)) {
        if ($e -and ($e.TrimEnd('\') -ieq $Path.TrimEnd('\'))) { return $true }
    }
    return $false
}

function Add-DefenderException {
    # Excludes the game folder (covers the proxy DLL and its runtime log folder).
    param($Game, [string]$Proxy)

    if (-not (Test-DefenderAvailable)) {
        Show-Warn ("Windows Defender cmdlets are not available, so you may be running a third-party antivirus. Add a folder exclusion in that product's settings instead:`n`n{0}" -f $Game.TargetDir)
        return $false
    }
    if (-not (Test-IsAdmin)) {
        if (Confirm-Action "Adding a Defender exclusion needs administrator rights.`n`nReopen this launcher as administrator now? It restarts with a UAC prompt." 'Elevation required') {
            if (Restart-Elevated) { $form.Close() }
        }
        return $false
    }
    try {
        Add-MpPreference -ExclusionPath $Game.TargetDir -ErrorAction Stop
        Write-Log ('  Defender exclusion added for {0}' -f $Game.TargetDir)
        $exFile = Join-Path (Join-Path $Script:BackupRoot $Game.Key) 'defender-exclusion.json'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $exFile) -Force)
        (@{ folder = $Game.TargetDir; addedAt = (Get-Date -Format 's') } | ConvertTo-Json) | Set-Content -LiteralPath $exFile -Encoding utf8
        return $true
    } catch {
        Write-Log ('  Defender exclusion failed: {0}' -f $_.Exception.Message) 'error'
        Show-Error ('Could not add the exclusion:' + "`n" + $_.Exception.Message)
        return $false
    }
}

function Remove-DefenderException {
    param($Game)
    if (-not (Test-DefenderAvailable)) { return $false }
    if (-not (Test-IsAdmin)) {
        if (Confirm-Action "Removing a Defender exclusion needs administrator rights.`n`nReopen this launcher as administrator now?" 'Elevation required') {
            if (Restart-Elevated) { $form.Close() }
        }
        return $false
    }
    try {
        if (Test-PathExcluded -Path $Game.TargetDir) {
            Remove-MpPreference -ExclusionPath $Game.TargetDir -ErrorAction SilentlyContinue
            Write-Log ('  Defender exclusion removed for {0}' -f $Game.TargetDir)
        }
        $exFile = Join-Path (Join-Path $Script:BackupRoot $Game.Key) 'defender-exclusion.json'
        if (Test-Path -LiteralPath $exFile) { Remove-Item -LiteralPath $exFile -Force }
        return $true
    } catch { Write-Log ('  exclusion removal failed: {0}' -f $_.Exception.Message) 'warn'; return $false }
}

# ---------------------------------------------------------------- GPU detection

function Initialize-Gpu {
    try {
        $nv = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1)
    } catch { $nv = @() }

    if (-not $nv -or $nv.Count -eq 0) {
        $Script:GpuName  = 'no NVIDIA GPU detected'
        $Script:GpuRoute = 'SM86'
        return
    }

    $card = $nv[0]
    $Script:GpuName = $card.Name
    $drv = $card.DriverVersion
    if ($drv -match '(\d+)\.(\d+)$') {
        $raw = ($drv -replace '[^\d]', '')
        if ($raw.Length -ge 5) {
            $tail = $raw.Substring($raw.Length - 5)
            $Script:GpuName = '{0}  (driver {1}.{2})' -f $card.Name, $tail.Substring(0, 3), $tail.Substring(3)
        }
    }

    if     ($card.Name -match 'RTX\s*A?3\d{3}')            { $Script:GpuRoute = 'SM86' }
    elseif ($card.Name -match 'RTX\s*A?2\d{3}|TITAN RTX')   { $Script:GpuRoute = 'SM75' }
    elseif ($card.Name -match 'RTX\s*[45]\d{3}')            { $Script:GpuRoute = 'NATIVE' }
    else                                                    { $Script:GpuRoute = 'UNSUPPORTED' }
}

# ---------------------------------------------------------------- state file

function Get-State {
    $default = [ordered]@{ extraRoots = @(); manualGames = @(); lastScan = $null; lastDeep = $false; cachedGames = @(); dllLibrary = ''; nameOverrides = @{}; modDirOverrides = @{} }
    if (Test-Path -LiteralPath $Script:StateFile) {
        try {
            $raw = Get-Content -LiteralPath $Script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @('extraRoots', 'manualGames', 'lastScan', 'lastDeep', 'cachedGames', 'dllLibrary', 'nameOverrides', 'modDirOverrides')) {
                if ($raw.PSObject.Properties.Name -contains $k) { $default[$k] = $raw.$k }
            }
        } catch { Write-Log "state file unreadable, using defaults: $($_.Exception.Message)" 'warn' }
    }
    return $default
}

function Save-State {
    param($State)
    try {
        ($State | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $Script:StateFile -Encoding utf8
    } catch { Write-Log "could not save state: $($_.Exception.Message)" 'warn' }
}

function Save-GameCache {
    param($Games, [bool]$Deep)
    $state = Get-State
    $state.cachedGames = @($Games)
    $state.lastScan    = (Get-Date -Format 's')
    $state.lastDeep    = $Deep
    Save-State -State $state
}

function Get-CachedGames {
    $state = Get-State
    $cached = @($state.cachedGames)
    if ($cached.Count -eq 0) { return @() }
    # drop anything whose folder has since disappeared
    return @($cached | Where-Object { $_ -and $_.TargetDir -and (Test-Path -LiteralPath $_.TargetDir) })
}

function Rename-GameEntry {
    # Renames a game's display name everywhere: persists an override keyed by the
    # game folder, updates a manual entry if applicable, renames the backup folder
    # to match the new name, and fixes paths inside the install manifest.
    param($Game, [string]$NewName)
    $NewName = ($NewName -replace '\s+', ' ').Trim()
    if (-not $NewName -or $NewName -eq $Game.Name) { return $false }

    $oldKey = $Game.Key
    $newKey = Get-PathKey -Name $NewName -Path $Game.TargetDir

    if ($newKey -ne $oldKey) {
        $oldDir = Join-Path $Script:BackupRoot $oldKey
        $newDir = Join-Path $Script:BackupRoot $newKey
        if (Test-Path -LiteralPath $oldDir) {
            try {
                if (Test-Path -LiteralPath $newDir) {
                    foreach ($c in @(Get-ChildItem -LiteralPath $oldDir -Force)) { Move-Item -LiteralPath $c.FullName -Destination $newDir -Force }
                    Remove-Item -LiteralPath $oldDir -Recurse -Force
                } else {
                    Move-Item -LiteralPath $oldDir -Destination $newDir -Force
                }
                $mf = Join-Path $newDir 'install.json'
                if (Test-Path -LiteralPath $mf) {
                    ((Get-Content -LiteralPath $mf -Raw) -replace [regex]::Escape($oldKey), $newKey) | Set-Content -LiteralPath $mf -Encoding utf8
                }
                Write-Log ('backup folder renamed: {0} -> {1}' -f $oldKey, $newKey)
            } catch { Write-Log ('backup folder rename failed: {0}' -f $_.Exception.Message) 'warn' }
        }
    }

    $st = Get-State
    $ov = @{}
    if ($st.nameOverrides) {
        if ($st.nameOverrides -is [hashtable]) { $ov = $st.nameOverrides }
        else { foreach ($p in $st.nameOverrides.PSObject.Properties) { $ov[$p.Name] = $p.Value } }
    }
    $ov[$Game.TargetDir] = $NewName
    $st.nameOverrides = $ov
    if ($st.manualGames) {
        foreach ($mg in $st.manualGames) { if ($mg -and $mg.TargetDir -eq $Game.TargetDir) { $mg.Name = $NewName } }
    }
    Save-State -State $st

    $Game.Name = $NewName
    $Game.Key  = $newKey
    if ($Script:Games) { Save-GameCache -Games $Script:Games -Deep ([bool]$st.lastDeep) }
    Write-Log ('renamed game to "{0}"' -f $NewName)
    return $true
}

# ---------------------------------------------------------------- steam scanning

function Get-SteamLibraries {
    $libs = New-Object System.Collections.Generic.List[string]
    $steam = $null

    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
        try {
            $p = (Get-ItemProperty -Path $key -ErrorAction Stop)
            foreach ($prop in @('SteamPath', 'InstallPath')) {
                if ($p.PSObject.Properties.Name -contains $prop -and $p.$prop) {
                    $steam = ($p.$prop -replace '/', '\'); break
                }
            }
        } catch { }
        if ($steam) { break }
    }
    if (-not $steam) {
        foreach ($guess in @("${env:ProgramFiles(x86)}\Steam", "$env:ProgramFiles\Steam", 'C:\Steam')) {
            if ($guess -and (Test-Path -LiteralPath $guess)) { $steam = $guess; break }
        }
    }

    if ($steam) {
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            $text = Get-Content -LiteralPath $vdf -Raw
            foreach ($m in [regex]::Matches($text, '"path"\s*"([^"]+)"')) {
                $p = $m.Groups[1].Value -replace '\\\\', '\'
                if (Test-Path -LiteralPath $p) { $libs.Add($p) }
            }
        }
        if ($libs.Count -eq 0) { $libs.Add($steam) }
    }

    return $libs
}

function Get-SteamAppId {
    param([string]$LibraryRoot, [string]$InstallDir)
    try {
        $acfs = @(Get-ChildItem -LiteralPath (Join-Path $LibraryRoot 'steamapps') -Filter '*.acf' -File -ErrorAction SilentlyContinue)
        foreach ($acf in $acfs) {
            $t = Get-Content -LiteralPath $acf.FullName -Raw
            $m = [regex]::Match($t, '"installdir"\s*"([^"]+)"')
            if ($m.Success -and $m.Groups[1].Value -eq $InstallDir) {
                $id = [regex]::Match($t, '"appid"\s*"(\d+)"')
                if ($id.Success) { return $id.Groups[1].Value }
            }
        }
    } catch { }
    return $null
}

function Test-AntiCheat {
    param([string]$GameRoot)
    try {
        $hits = @(Get-ChildItem -LiteralPath $GameRoot -Recurse -Depth 3 -Force -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match 'BattlEye|EasyAntiCheat|_BE\.exe$|EACLauncher|anticheat' } |
                  Select-Object -First 1)
        if ($hits.Count -gt 0) { return $hits[0].Name }
    } catch { }
    return $null
}

function Get-RenderExe {
    param([string]$Dir)
    try {
        $exes = @(Get-ChildItem -LiteralPath $Dir -Filter '*.exe' -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -notmatch $Script:ExeSkip } |
                  Sort-Object Length -Descending)
        if ($exes.Count -gt 0) { return $exes[0].FullName }
        # nothing survived the filter, fall back to the largest exe of any name
        $any = @(Get-ChildItem -LiteralPath $Dir -Filter '*.exe' -File -ErrorAction SilentlyContinue | Sort-Object Length -Descending)
        if ($any.Count -gt 0) { return $any[0].FullName }
    } catch { }
    return $null
}

function Get-GameNameFromPath {
    # Walk up the path and return the first folder that isn't a generic engine
    # subfolder, so a game in ...\MyGame\bin\x64 is named "MyGame" not "x64".
    param([string]$Dir)
    $segs = @($Dir -split '\\' | Where-Object { $_ -and $_ -notmatch '^[A-Za-z]:$' })
    for ($i = $segs.Count - 1; $i -ge 0; $i--) {
        if ($segs[$i] -notmatch '^(bin|binaries|win64|win32|winxx|x64|x86|retail|shipping|content|game|data)$') { return $segs[$i] }
    }
    if ($segs.Count) { return $segs[-1] }
    return $Dir
}

function Get-ExeProductName {
    # Prefer the render exe's embedded ProductName / FileDescription for a clean
    # display name (e.g. "Cyberpunk 2077"), ignoring generic engine placeholders.
    param([string]$Dir)
    $exe = Get-RenderExe -Dir $Dir
    if (-not $exe) { return $null }
    try {
        $vi = (Get-Item -LiteralPath $exe).VersionInfo
        foreach ($cand in @($vi.ProductName, $vi.FileDescription)) {
            if ($cand) {
                $c = ($cand -replace '\s+', ' ').Trim()
                if ($c.Length -ge 3 -and $c -notmatch '^(game|launcher|shipping|win64|winmain|application|unreal.*|ue4.*|ue5.*)$') { return $c }
            }
        }
    } catch { }
    return $null
}

function Get-BestGameName {
    # Best available display name for a folder: exe metadata, else path heuristic.
    param([string]$Dir)
    $n = Get-ExeProductName -Dir $Dir
    if ($n) { return $n }
    return (Get-GameNameFromPath -Dir $Dir)
}

function Test-BadName {
    # A name that should be replaced: empty, a bare drive letter, a path fragment,
    # or a generic engine folder token.
    param([string]$Name)
    if (-not $Name) { return $true }
    if ($Name -match '[:/]' -or $Name.Contains([string][char]92)) { return $true }
    if ($Name -match '^[A-Za-z]$') { return $true }
    if ($Name -match '^(bin|win64|win32|thirdparty|installed|binaries|content|x64|x86|game|data|production)$') { return $true }
    return $false
}

function New-GameEntry {
    param(
        [string]$Name, [string]$GameRoot, [string]$TargetDir,
        [string[]]$NgxFound, [string]$Source = 'Custom', [string]$AppId,
        [string]$LaunchUri, [bool]$Manual = $false
    )
    $hasFg = ($NgxFound -contains 'nvngx_dlssg.dll')
    if     ($hasFg)                { $fg = 'Yes' }
    elseif ($NgxFound.Count -gt 0) { $fg = 'DLSS only' }
    else                           { $fg = 'Unknown' }

    return [pscustomobject]@{
        Name       = $Name
        GameRoot   = $GameRoot
        TargetDir  = $TargetDir
        DllDirs    = @($TargetDir)
        RenderExe  = (Get-RenderExe -Dir $TargetDir)
        NgxFiles   = $NgxFound
        FgSupport  = $fg
        Source     = $Source
        AppId      = $AppId
        LaunchUri  = $LaunchUri
        AntiCheat  = (Test-AntiCheat -GameRoot $GameRoot)
        Key        = (Get-PathKey -Name $Name -Path $TargetDir)
        Manual     = $Manual
    }
}

function Get-GameDllDirs {
    # All folders that hold this game's nvngx DLLs (UE games split DLSS SR and
    # Streamline/Frame-Gen into separate plugin folders).
    param($Game)
    if ($Game.PSObject.Properties.Name -contains 'DllDirs' -and $Game.DllDirs -and @($Game.DllDirs).Count -gt 0) {
        return @(@($Game.DllDirs) | Where-Object { $_ })
    }
    return @($Game.TargetDir)
}

function Merge-GamesByRoot {
    # Collapse the per-folder scan rows into ONE row per game. Rows are the same game
    # when they share a game root, or one row's folder sits under another's root.
    param($Games)
    $bs = [char]92
    # NB: do not do @($Games) here; @() on a List[object] of entries can throw
    # "Argument types do not match" in Windows PowerShell 5.1. Iterating is safe.

    # unique normalized roots
    $roots = @($Games | ForEach-Object { $src = if ($_.GameRoot) { $_.GameRoot } else { $_.TargetDir }; $src.ToLower().TrimEnd($bs) } | Select-Object -Unique)
    # map each root to its shortest ancestor root, so subfolders fold into the game
    $canon = @{}
    foreach ($rk in $roots) {
        $c = $rk
        foreach ($anc in $roots) {
            if ($anc -ne $rk -and $rk.StartsWith($anc + $bs) -and $anc.Length -lt $c.Length) { $c = $anc }
        }
        $canon[$rk] = $c
    }
    # tag each game with its canonical group key, then group (Group-Object is robust)
    $tagged = foreach ($g in $Games) {
        $src = if ($g.GameRoot) { $g.GameRoot } else { $g.TargetDir }
        [pscustomobject]@{ GK = $canon[$src.ToLower().TrimEnd($bs)]; Game = $g }
    }

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($grpObj in ($tagged | Group-Object GK)) {
        $grp = @($grpObj.Group | ForEach-Object { $_.Game })
        if ($grp.Count -eq 1) { $out.Add($grp[0]); continue }

        $dllDirs = @($grp | Where-Object { @($_.NgxFiles).Count -gt 0 } | ForEach-Object { $_.TargetDir } | Select-Object -Unique)
        $ngx     = @($grp | ForEach-Object { @($_.NgxFiles) } | Where-Object { $_ } | Select-Object -Unique)
        $base = $grp | Where-Object { @($_.NgxFiles) -contains 'nvngx_dlss.dll' } | Select-Object -First 1
        if (-not $base) { $base = $grp | Where-Object { @($_.NgxFiles) -contains 'nvngx_dlssg.dll' } | Select-Object -First 1 }
        if (-not $base) { $base = $grp | Where-Object { @($_.NgxFiles).Count -gt 0 } | Select-Object -First 1 }
        if (-not $base) { $base = $grp[0] }
        if ($dllDirs.Count -eq 0) { $dllDirs = @($base.TargetDir) }

        $root = ($grp | ForEach-Object { $_.GameRoot } | Where-Object { $_ } | Sort-Object { $_.Length } | Select-Object -First 1)
        if ($root) { $base.GameRoot = $root }
        $base.DllDirs  = $dllDirs
        $base.NgxFiles = $ngx
        $base.FgSupport = if ($ngx -contains 'nvngx_dlssg.dll') { 'Yes' } elseif ($ngx.Count -gt 0) { 'DLSS' } else { 'Unknown' }
        $out.Add($base)
    }
    return $out.ToArray()   # @($out) can throw "Argument types do not match" in WinPS 5.1
}

function Get-FixedDrives {
    try {
        $d = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | Select-Object -ExpandProperty DeviceID)
        if ($d.Count -gt 0) { return $d }
    } catch { }
    return @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
             Where-Object { $_.Root -match '^[A-Za-z]:\\$' } | ForEach-Object { $_.Root.TrimEnd('\') })
}

# ---- per-launcher game locators. Each returns objects: Name, Root, Source, AppId, LaunchUri

function Get-SteamGames {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($lib in @(Get-SteamLibraries)) {
        $common = Join-Path $lib 'steamapps\common'
        if (-not (Test-Path -LiteralPath $common)) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $common -Directory -ErrorAction SilentlyContinue)) {
            $appid = Get-SteamAppId -LibraryRoot $lib -InstallDir $d.Name
            $uri   = if ($appid) { 'steam://rungameid/{0}' -f $appid } else { $null }
            $out.Add([pscustomobject]@{ Name = $d.Name; Root = $d.FullName; Source = 'Steam'; AppId = $appid; LaunchUri = $uri })
        }
    }
    return $out
}

function Get-EpicGames {
    $out = New-Object System.Collections.Generic.List[object]
    $man = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
    if (-not (Test-Path -LiteralPath $man)) { return $out }
    foreach ($f in @(Get-ChildItem -LiteralPath $man -Filter '*.item' -File -ErrorAction SilentlyContinue)) {
        try {
            $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
            if ($j.InstallLocation -and (Test-Path -LiteralPath $j.InstallLocation)) {
                $name = if ($j.DisplayName) { $j.DisplayName } else { Split-Path -Leaf $j.InstallLocation }
                $uri  = if ($j.AppName) { 'com.epicgames.launcher://apps/{0}?action=launch&silent=true' -f $j.AppName } else { $null }
                $out.Add([pscustomobject]@{ Name = $name; Root = $j.InstallLocation; Source = 'Epic'; AppId = $j.AppName; LaunchUri = $uri })
            }
        } catch { }
    }
    return $out
}

function Get-GogGames {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($base in @('HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games', 'HKLM:\SOFTWARE\GOG.com\Games')) {
        if (-not (Test-Path -LiteralPath $base)) { continue }
        foreach ($k in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
            try {
                $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
                if ($p.path -and (Test-Path -LiteralPath $p.path)) {
                    $name = if ($p.gameName) { $p.gameName } else { Split-Path -Leaf $p.path }
                    $out.Add([pscustomobject]@{ Name = $name; Root = $p.path; Source = 'GOG'; AppId = $p.gameID; LaunchUri = $null })
                }
            } catch { }
        }
    }
    return $out
}

function Get-UbisoftGames {
    $out = New-Object System.Collections.Generic.List[object]
    $base = 'HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher\Installs'
    if (-not (Test-Path -LiteralPath $base)) { return $out }
    foreach ($k in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
        try {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if ($p.InstallDir -and (Test-Path -LiteralPath $p.InstallDir)) {
                $out.Add([pscustomobject]@{ Name = (Split-Path -Leaf $p.InstallDir.TrimEnd('\')); Root = $p.InstallDir; Source = 'Ubisoft'; AppId = $k.PSChildName; LaunchUri = ('uplay://launch/{0}/0' -f $k.PSChildName) })
            }
        } catch { }
    }
    return $out
}

function Get-FolderScanGames {
    # EA / Origin / Battle.net / Riot and any generic game library folder that holds
    # one subfolder per game. Each immediate subfolder becomes a candidate root.
    $out   = New-Object System.Collections.Generic.List[object]
    $seen  = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($drive in @(Get-FixedDrives)) {
        $bases = @(
            "$drive\Program Files\EA Games", "$drive\Program Files (x86)\EA Games",
            "$drive\Program Files\Origin Games", "$drive\Program Files (x86)\Origin Games",
            "$drive\EA Games", "$drive\Origin Games",
            "$drive\Program Files (x86)\Battle.net", "$drive\Games", "$drive\Game",
            "$drive\XboxGames", "$drive\GOG Games", "$drive\Epic Games",
            "$drive\Program Files\Epic Games", "$drive\Riot Games", "$drive\Program Files\Riot Games"
        )
        foreach ($b in $bases) {
            if (-not (Test-Path -LiteralPath $b)) { continue }
            foreach ($sub in @(Get-ChildItem -LiteralPath $b -Directory -ErrorAction SilentlyContinue)) {
                # Xbox packages keep the real files under \Content
                $root = $sub.FullName
                $content = Join-Path $root 'Content'
                if (Test-Path -LiteralPath $content) { $root = $content }
                if ($seen.Add($root)) {
                    $src = if ($b -match 'XboxGames') { 'Xbox' } elseif ($b -match 'Battle\.net') { 'Battle.net' } elseif ($b -match 'EA |Origin') { 'EA' } elseif ($b -match 'Riot') { 'Riot' } else { 'Custom' }
                    $out.Add([pscustomobject]@{ Name = $sub.Name; Root = $root; Source = $src; AppId = $null; LaunchUri = $null })
                }
            }
        }
    }
    return $out
}

function Get-SweepRoots {
    # Broad but bounded roots that may contain custom-installed games. Swept for
    # nvngx DLLs at a depth limit; used to catch games no launcher registered.
    param([switch]$Deep)
    $roots = New-Object 'System.Collections.Generic.List[string]'
    $state = Get-State
    foreach ($drive in @(Get-FixedDrives)) {
        if ($Deep) {
            # every top-level folder on the drive except OS/system noise
            $deny = 'Windows|\$Recycle|System Volume|Recovery|PerfLogs|MSOCache|Config\.Msi|\$WinREAgent|OneDriveTemp|ProgramData'
            foreach ($top in @(Get-ChildItem -LiteralPath ('{0}\' -f $drive) -Directory -Force -ErrorAction SilentlyContinue |
                               Where-Object { $_.Name -notmatch $deny })) {
                $roots.Add($top.FullName)
            }
        } else {
            foreach ($c in @("$drive\Games", "$drive\Game", "$drive\Program Files", "$drive\Program Files (x86)")) {
                if (Test-Path -LiteralPath $c) { $roots.Add($c) }
            }
        }
    }
    foreach ($r in @($state.extraRoots)) { if ($r -and (Test-Path -LiteralPath $r)) { $roots.Add($r) } }
    return @($roots | Select-Object -Unique)
}

function Add-NgxEntries {
    # Scan one root for nvngx DLLs, group by folder, add non-duplicate entries.
    param($Root, [string]$Name, [string]$Source, [string]$AppId, [string]$LaunchUri,
          [int]$Depth, $Seen, $Result, [switch]$Quiet, [switch]$DeriveName)
    if (-not (Test-Path -LiteralPath $Root)) { return }
    try {
        $ngx = @(Get-ChildItem -LiteralPath $Root -Recurse -Depth $Depth -File -Filter 'nvngx_*.dll' -Force -ErrorAction SilentlyContinue)
    } catch { $ngx = @() }
    if ($ngx.Count -eq 0) { return }
    foreach ($grp in ($ngx | Group-Object DirectoryName)) {
        $dir = $grp.Name
        # skip non-game nvngx locations (the NVIDIA App / driver ships its own copies)
        if ($dir -match 'NvDLISR|\\NVIDIA App\\|\\NVIDIA Corporation\\|\\GeForce Experience\\') { continue }
        if (-not $Seen.Add($dir)) { continue }
        # anti-cheat scan + path-based naming want the game root, not the (deep) dll folder
        $groot = $Root
        if ($DeriveName -and $dir.ToLower().StartsWith($Root.ToLower())) {
            $rel = $dir.Substring($Root.Length).TrimStart('\'); $seg = ($rel -split '\\')[0]
            $groot = if ($seg) { Join-Path $Root $seg } else { $dir }
        }
        $gname = $Name
        if ($DeriveName -or -not $gname -or (Test-BadName -Name $gname)) {
            # prefer the exe's embedded product name (often in the dll folder), else path
            $exeName = Get-ExeProductName -Dir $dir
            if (-not $exeName) { $exeName = Get-ExeProductName -Dir $groot }
            $gname = if ($exeName) { $exeName } else { Get-GameNameFromPath -Dir $groot }
        }
        $entry = New-GameEntry -Name $gname -GameRoot $groot -TargetDir $dir `
                               -NgxFound @($grp.Group.Name) -Source $Source -AppId $AppId -LaunchUri $LaunchUri
        $Result.Add($entry)
        if (-not $Quiet) { Write-Log ('  {0,-11} {1}: FG {2} @ {3}' -f ("[$Source]"), $gname, $entry.FgSupport, $dir) }
    }
}

function Find-Games {
    param([switch]$Quiet, [switch]$Deep)
    $result = New-Object System.Collections.Generic.List[object]
    $seen   = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $state  = Get-State

    # 1. launcher-registered games, scanned at their exact install root
    $explicit = New-Object System.Collections.Generic.List[object]
    foreach ($fn in @('Get-SteamGames', 'Get-EpicGames', 'Get-GogGames', 'Get-UbisoftGames', 'Get-FolderScanGames')) {
        try { foreach ($g in @(& $fn)) { $explicit.Add($g) } }
        catch { Write-Log ('  {0} failed: {1}' -f $fn, $_.Exception.Message) 'warn' }
    }
    if (-not $Quiet) { Write-Log ('{0} launcher-registered game folder(s) to check' -f $explicit.Count) }

    foreach ($g in $explicit) {
        Add-NgxEntries -Root $g.Root -Name $g.Name -Source $g.Source -AppId $g.AppId -LaunchUri $g.LaunchUri `
                       -Depth 8 -Seen $seen -Result $result -Quiet:$Quiet
    }

    # 2. filesystem sweep for custom-installed games no launcher knows about
    $roots = @(Get-SweepRoots -Deep:$Deep)
    if (-not $Quiet) { Write-Log ('sweeping {0} folder root(s){1} for nvngx DLLs' -f $roots.Count, $(if ($Deep) { ' (deep, all drives)' } else { '' })) }
    $sweepDepth = if ($Deep) { 12 } else { 9 }
    foreach ($r in $roots) {
        if (-not $Quiet) { Write-Log ('  sweeping {0}' -f $r) }
        Add-NgxEntries -Root $r -Source 'Custom' -Depth $sweepDepth -Seen $seen -Result $result -Quiet:$Quiet -DeriveName
    }

    # 3. explicitly user-added folders. Scan recursively (like the launcher scanners)
    #    so the DLSS DLLs are found even when they live in a subfolder (e.g. bin\x64),
    #    and the entry's TargetDir points at the actual DLL folder.
    foreach ($mg in @($state.manualGames)) {
        if (-not $mg -or -not (Test-Path -LiteralPath $mg.TargetDir)) { continue }
        $before = $result.Count
        Add-NgxEntries -Root $mg.TargetDir -Name $mg.Name -Source 'Manual' -Depth 8 `
                       -Seen $seen -Result $result -Quiet:$Quiet
        # If it added nothing, either the game has no DLSS DLLs at all, or the sweep
        # already listed it. Only add a visible placeholder in the first case.
        if ($result.Count -eq $before) {
            $rootLc = $mg.TargetDir.ToLower()
            $already = @($result | Where-Object { $_.TargetDir -and $_.TargetDir.ToLower().StartsWith($rootLc) })
            if ($already.Count -eq 0 -and $seen.Add($mg.TargetDir)) {
                $result.Add((New-GameEntry -Name $mg.Name -GameRoot $mg.TargetDir -TargetDir $mg.TargetDir `
                                           -NgxFound @() -Source 'Manual' -Manual $true))
            }
        }
    }

    # collapse per-folder rows into one row per game (UE games split DLSS across folders)
    $merged = Merge-GamesByRoot -Games $result

    # apply any user rename overrides (keyed by TargetDir), and recompute the key
    $ov = $state.nameOverrides
    if ($ov) {
        foreach ($e in $merged) {
            $nm = Get-OverrideName -Overrides $ov -TargetDir $e.TargetDir
            if (-not $nm -and @($e.DllDirs)) { foreach ($d in @($e.DllDirs)) { $nm = Get-OverrideName -Overrides $ov -TargetDir $d; if ($nm) { break } } }
            if ($nm) { $e.Name = $nm; $e.Key = (Get-PathKey -Name $nm -Path $e.TargetDir) }
        }
    }

    return @($merged | Sort-Object @{ Expression = { $_.FgSupport -ne 'Yes' } }, Name)
}

function Get-OverrideName {
    # nameOverrides can be a hashtable (fresh) or a PSCustomObject (from JSON).
    # Exact folder match wins; otherwise the longest ancestor folder override applies,
    # so a game-root rename also covers its DLL subfolder (e.g. ...\NVStreamline\production).
    param($Overrides, [string]$TargetDir)
    if (-not $Overrides -or -not $TargetDir) { return $null }
    $pairs = New-Object System.Collections.Generic.List[object]
    if ($Overrides -is [hashtable]) { foreach ($e in $Overrides.GetEnumerator()) { $pairs.Add(@($e.Key, $e.Value)) } }
    else { foreach ($p in $Overrides.PSObject.Properties) { $pairs.Add(@($p.Name, $p.Value)) } }
    $bs  = [string][char]92
    $tdl = $TargetDir.ToLower().TrimEnd($bs)
    $best = $null; $bestLen = -1
    foreach ($pr in $pairs) {
        $k = ([string]$pr[0]).ToLower().TrimEnd($bs)
        if ($k -eq $tdl) { return $pr[1] }
        if ($tdl.StartsWith($k + $bs) -and $k.Length -gt $bestLen) { $best = $pr[1]; $bestLen = $k.Length }
    }
    return $best
}

# ---------------------------------------------------------------- mod source

function Get-ProxySourcePath {
    param([string]$ProxyName)
    if ($ProxyName -eq 'version.dll') { return (Join-Path $Script:ModSrc 'version.dll') }
    return (Join-Path $Script:ModSrc ('altnative\{0}' -f $ProxyName))
}

function Test-ModSource {
    if (-not (Test-Path -LiteralPath (Join-Path $Script:ModSrc 'version.dll'))) { return $false }
    return $true
}

function Update-ModSource {
    Write-Log 'downloading latest mod package from GitHub'
    $zip = Join-Path $env:TEMP ('dlssg_sm86_{0}.zip' -f (Get-Date -Format 'yyyyMMddHHmmss'))
    $tmp = Join-Path $env:TEMP ('dlssg_sm86_x_{0}' -f (Get-Date -Format 'yyyyMMddHHmmss'))
    try {
        $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Script:ModZipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 600
        $ProgressPreference = $old
        Write-Log ('downloaded {0:N1} MB' -f ((Get-Item -LiteralPath $zip).Length / 1MB))

        Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
        $inner = @(Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1)
        if ($inner.Count -eq 0) { throw 'archive layout unexpected' }

        if (Test-Path -LiteralPath $Script:ModSrc) {
            $keep = '{0}.old_{1}' -f $Script:ModSrc, (Get-Date -Format 'yyyyMMdd-HHmmss')
            Move-Item -LiteralPath $Script:ModSrc -Destination $keep
            Write-Log ('previous package moved to {0}' -f (Split-Path -Leaf $keep))
        }
        Move-Item -LiteralPath $inner[0].FullName -Destination $Script:ModSrc
        Write-Log 'mod package updated'
        return $true
    } catch {
        Write-Log ('download failed: {0}' -f $_.Exception.Message) 'error'
        return $false
    } finally {
        foreach ($p in @($zip, $tmp)) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } }
    }
}

function Get-ModVersion {
    $readme = Join-Path $Script:ModSrc 'README.en.md'
    if (Test-Path -LiteralPath $readme) {
        $first = (Get-Content -LiteralPath $readme -TotalCount 1)
        if ($first -match '([\d]+\.[\d]+\.[\d]+)') { return $Matches[1] }
    }
    return 'unknown'
}

# ---------------------------------------------------------------- ini

function New-ModIni {
    param([string]$Router, [string]$KernelImage, [int]$HardwareBilinear, [int]$MaxGeneratedFrames, [int]$LogLevel)
    return @"
; Native $(Get-ModVersion). Restart the game after changing this file.
; Written by DLSSG-Launcher.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm')
[Compatibility]
; SM86 for Ampere; SM75 for Turing or SM75 forward-JIT testing.
Router=$Router
; PTX uses driver JIT. Cubin requires an exact GPU/Router match.
; Auto selects Cubin on an exact match, otherwise PTX.
KernelImage=$KernelImage
; 0 = exact output (default); 1 = optional approximate sampling, SM86 only.
HardwareBilinear=$HardwareBilinear

[FrameGeneration]
; Capability limit: 1=2X, 2=3X, 3=4X. The game requests the actual multiplier.
MaxGeneratedFrames=$MaxGeneratedFrames

[Logging]
; 0=off, 1=errors, 2=diagnostics, 3=verbose.
Level=$LogLevel
"@
}

function Read-ModIni {
    param([string]$Path)
    $vals = @{ Router = $Script:GpuRoute; KernelImage = 'PTX'; HardwareBilinear = 0; MaxGeneratedFrames = 3; Level = 1 }
    if (-not (Test-Path -LiteralPath $Path)) { return $vals }
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match '^\s*;') { continue }
        if ($line -match '^\s*([A-Za-z]+)\s*=\s*([^\s;]+)') {
            $k = $Matches[1]; $v = $Matches[2]
            if ($vals.ContainsKey($k)) {
                if ($vals[$k] -is [int]) { $vals[$k] = [int]$v } else { $vals[$k] = $v }
            }
        }
    }
    return $vals
}

# ---------------------------------------------------------------- DLSS DLL manager
#
# Independent of the Frame-Gen mod: swaps a game's DLSS *upscaling* (nvngx_dlss.dll)
# and *Ray Reconstruction* (nvngx_dlssd.dll) DLLs to newer versions the user has
# placed in a local library folder. Latest (310.x+) DLLs contain the DLSS 4
# transformer model. These files are separate from the version.dll FG proxy, so
# this coexists with an installed Frame-Gen mod.

$Script:DllTypes = [ordered]@{
    'nvngx_dlss.dll'  = 'Super Resolution (upscaling)'
    'nvngx_dlssd.dll' = 'Ray Reconstruction (RT denoise)'
    'nvngx_dlssg.dll' = 'Frame Generation'
}

function Get-DllLibraryDir {
    $state = Get-State
    $dir = if ($state.dllLibrary) { $state.dllLibrary } else { Join-Path $Script:Root 'dll-library' }
    if (-not (Test-Path -LiteralPath $dir)) { try { [void](New-Item -ItemType Directory -Path $dir -Force) } catch { } }
    return $dir
}

function Get-FileVersionSafe {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $v = (Get-Item -LiteralPath $Path).VersionInfo.FileVersion
        if ($v) { return ($v -replace ',', '.' -replace '\s', '') }
    } catch { }
    return '?'
}

function Compare-DllVersion {
    # returns 1 if $A newer than $B, -1 if older, 0 if equal/unknown
    param([string]$A, [string]$B)
    if (-not $A -or -not $B -or $A -eq '?' -or $B -eq '?') { return 0 }
    try {
        $va = [version](($A -split '\.')[0..3] -join '.')
        $vb = [version](($B -split '\.')[0..3] -join '.')
        return $va.CompareTo($vb)
    } catch { return 0 }
}

function Get-UpscalerStatus {
    # Compact status of a game's DLSS Super Resolution DLL for the main list.
    # "latest"/"update" are judged against the library folder; without a library
    # reference it falls back to generation (310.x = DLSS 4+ transformer, else old).
    param($Game)
    $inst = $null
    foreach ($d in (Get-GameDllDirs -Game $Game)) { $v = Get-FileVersionSafe -Path (Join-Path $d 'nvngx_dlss.dll'); if ($v) { $inst = $v; break } }
    if (-not $inst) { return 'no DLSS' }
    $lib = Get-FileVersionSafe -Path (Join-Path (Get-DllLibraryDir) 'nvngx_dlss.dll')
    if ($lib -and $lib -ne '?') {
        if ((Compare-DllVersion -A $inst -B $lib) -ge 0) { return ('{0}  latest' -f $inst) }
        return ('{0}  UPDATE' -f $inst)
    }
    $major = 0; try { $major = [int](($inst -split '\.')[0]) } catch { }
    if ($major -ge 310) { return ('{0}  (DLSS4+)' -f $inst) }
    return ('{0}  (old)' -f $inst)
}

function Update-DlssDlls {
    param($Game, [string[]]$Files)
    $dirs = Get-GameDllDirs -Game $Game
    $applied = New-Object System.Collections.Generic.List[string]
    $lib = Get-DllLibraryDir
    foreach ($f in $Files) {
        $libFile = Join-Path $lib $f
        if (-not (Test-Path -LiteralPath $libFile)) { continue }
        # find whichever of the game's DLL folders holds this file
        $gameFile = $null
        foreach ($d in $dirs) { $gp = Join-Path $d $f; if (Test-Path -LiteralPath $gp) { $gameFile = $gp; break } }
        if (-not $gameFile) {
            Write-Log ('  {0} not present in this game, skipping (cannot add a feature the game lacks)' -f $f) 'warn'
            continue
        }
        $dir = Split-Path -Parent $gameFile
        if (-not (Test-DirWritable -Dir $dir)) {
            Write-Log ('  cannot write to {0}, skipping {1}' -f $dir, $f) 'error'
            continue
        }
        [void](New-Backup -Game $Game -FilesToSave @($f) -SourceDir $dir)
        $old = Get-FileVersionSafe -Path $gameFile
        try {
            Copy-Item -LiteralPath $libFile -Destination $gameFile -Force
            $new = Get-FileVersionSafe -Path $gameFile
            Write-Log ('  {0}: {1} -> {2}' -f $f, $old, $new)
            $applied.Add(('{0}: {1} -> {2}' -f $f, $old, $new))
        } catch { Write-Log ('  {0} swap failed: {1}' -f $f, $_.Exception.Message) 'error' }
    }
    return @($applied)
}

# ---- automated download from the DLSS Swapper manifest (open source, MD5-verified)
$Script:DllManifestUrl = 'https://raw.githubusercontent.com/beeradmoore/dlss-swapper-manifest-builder/main/manifest.json'
$Script:DllManifestMap = @{ 'nvngx_dlss.dll' = 'dlss'; 'nvngx_dlssd.dll' = 'dlss_d'; 'nvngx_dlssg.dll' = 'dlss_g' }

function Get-DllManifest {
    $tmp = Join-Path $env:TEMP ('dlss_manifest_{0}.json' -f (Get-Date -Format 'yyyyMMddHHmmss'))
    try {
        $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Script:DllManifestUrl -OutFile $tmp -UseBasicParsing -TimeoutSec 120
        $ProgressPreference = $old
        $j = Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json
        return $j
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
}

function Invoke-AutoDownloadDlls {
    # Downloads the newest version of each requested nvngx_*.dll into the library
    # folder, verifying both the zip and the extracted DLL against manifest MD5s.
    param([string[]]$Files, $Manifest)
    $lib = Get-DllLibraryDir
    $results = New-Object System.Collections.Generic.List[string]
    foreach ($f in $Files) {
        $key = $Script:DllManifestMap[$f]
        if (-not $key) { continue }
        $entry = @($Manifest.$key | Sort-Object version_number -Descending | Select-Object -First 1)[0]
        if (-not $entry) { $results.Add(('{0}: no manifest entry' -f $f)); continue }
        $zip = Join-Path $env:TEMP ('{0}_{1}.zip' -f $key, ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        $ex  = Join-Path $env:TEMP ('{0}_{1}'     -f $key, ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        try {
            $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $entry.download_url -OutFile $zip -UseBasicParsing -TimeoutSec 300
            $ProgressPreference = $old
            $zmd5 = (Get-FileHash -Algorithm MD5 -LiteralPath $zip).Hash
            if ($zmd5 -ine $entry.zip_md5_hash) { throw 'zip hash mismatch, download rejected' }
            Expand-Archive -LiteralPath $zip -DestinationPath $ex -Force
            $dll = @(Get-ChildItem -LiteralPath $ex -Recurse -File -Filter $f | Select-Object -First 1)[0]
            if (-not $dll) { throw ('{0} not found in package' -f $f) }
            $dmd5 = (Get-FileHash -Algorithm MD5 -LiteralPath $dll.FullName).Hash
            if ($dmd5 -ine $entry.md5_hash) { throw 'dll hash mismatch, download rejected' }
            Copy-Item -LiteralPath $dll.FullName -Destination (Join-Path $lib $f) -Force
            Write-Log ('  downloaded + verified {0} v{1}' -f $f, $entry.version)
            $results.Add(('{0}  v{1}  (verified)' -f $f, $entry.version))
        } catch {
            Write-Log ('  auto-download {0} failed: {1}' -f $f, $_.Exception.Message) 'error'
            $results.Add(('{0}  FAILED: {1}' -f $f, $_.Exception.Message))
        } finally {
            foreach ($p in @($zip, $ex)) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } }
        }
    }
    return @($results)
}

# ---------------------------------------------------------------- install state

function Get-ManifestPath { param($Game) return (Join-Path (Join-Path $Script:BackupRoot $Game.Key) 'install.json') }

function Get-ModDirOverride {
    param($Game)
    $st = Get-State
    if (-not $st.modDirOverrides) { return $null }
    $ov = $st.modDirOverrides
    $keys = @($Game.TargetDir, $Game.Key)
    foreach ($k in $keys) {
        if (-not $k) { continue }
        if ($ov -is [hashtable]) { if ($ov.ContainsKey($k)) { return $ov[$k] } }
        else { $p = $ov.PSObject.Properties[$k]; if ($p) { return $p.Value } }
    }
    return $null
}

function Set-ModDirOverride {
    param($Game, [string]$Dir)
    $st = Get-State
    $ov = @{}
    if ($st.modDirOverrides) {
        if ($st.modDirOverrides -is [hashtable]) { $ov = $st.modDirOverrides }
        else { foreach ($p in $st.modDirOverrides.PSObject.Properties) { $ov[$p.Name] = $p.Value } }
    }
    $ov[$Game.TargetDir] = $Dir
    $st.modDirOverrides = $ov
    Save-State -State $st
}

function Get-ModInstallDirInfo {
    # Works out where the FG proxy (version.dll) must go: next to the render exe the
    # OS launches. Returns the folder, the exe it keyed on, the detected engine, and a
    # confidence level so the install dialog can show it and let the user confirm.
    param($Game)

    $ov = Get-ModDirOverride -Game $Game
    if ($ov -and (Test-Path -LiteralPath $ov)) {
        return [pscustomobject]@{ Dir = $ov; Exe = (Get-RenderExe -Dir $ov); Engine = 'user-set'; Confidence = 'certain' }
    }
    if ($Game.PSObject.Properties.Name -contains 'ModDir' -and $Game.ModDir -and (Test-Path -LiteralPath $Game.ModDir)) {
        return [pscustomobject]@{ Dir = $Game.ModDir; Exe = (Get-RenderExe -Dir $Game.ModDir); Engine = 'cached'; Confidence = 'high' }
    }

    $root = if ($Game.GameRoot -and (Test-Path -LiteralPath $Game.GameRoot)) { $Game.GameRoot } else { $Game.TargetDir }

    # 1. Unreal Engine: the *-Shipping.exe in <Game>\Binaries\Win64 is authoritative
    try {
        $ship = @(Get-ChildItem -LiteralPath $root -Recurse -Depth 9 -File -Filter '*-Shipping.exe' -Force -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -notmatch $Script:ExeSkip } | Sort-Object Length -Descending | Select-Object -First 1)
        if ($ship.Count -gt 0) { return [pscustomobject]@{ Dir = (Split-Path -Parent $ship[0].FullName); Exe = $ship[0].FullName; Engine = 'Unreal Engine'; Confidence = 'high' } }
    } catch { }

    # 1b. Unreal with a renamed shipping exe: any real game exe inside a Binaries\Win64/WinGDK folder
    try {
        $ue = @(Get-ChildItem -LiteralPath $root -Recurse -Depth 9 -File -Filter '*.exe' -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch $Script:ExeSkip -and $_.DirectoryName -match '\\Binaries\\Win(64|GDK)$' } |
                Sort-Object Length -Descending | Select-Object -First 1)
        if ($ue.Count -gt 0) { return [pscustomobject]@{ Dir = (Split-Path -Parent $ue[0].FullName); Exe = $ue[0].FullName; Engine = 'Unreal Engine'; Confidence = 'high' } }
    } catch { }

    # 2. the nvngx DLL folder itself holds the render exe (e.g. Cyberpunk / RED bin\x64)
    $tExe = Get-RenderExe -Dir $Game.TargetDir
    if ($tExe) { return [pscustomobject]@{ Dir = $Game.TargetDir; Exe = $tExe; Engine = 'exe beside DLLs'; Confidence = 'high' } }

    # 3. Unity: the exe sitting next to a <Name>_Data folder
    try {
        $dataDir = @(Get-ChildItem -LiteralPath $root -Recurse -Depth 6 -Directory -Force -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -match '_Data$' } | Select-Object -First 1)
        if ($dataDir.Count -gt 0) {
            $unityRoot = Split-Path -Parent $dataDir[0].FullName
            $uexe = Get-RenderExe -Dir $unityRoot
            if ($uexe) { return [pscustomobject]@{ Dir = $unityRoot; Exe = $uexe; Engine = 'Unity'; Confidence = 'high' } }
        }
    } catch { }

    # 4. best guess: the largest real game exe anywhere under the root
    try {
        $any = @(Get-ChildItem -LiteralPath $root -Recurse -Depth 9 -File -Filter '*.exe' -Force -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -notmatch $Script:ExeSkip } | Sort-Object Length -Descending | Select-Object -First 1)
        if ($any.Count -gt 0) { return [pscustomobject]@{ Dir = (Split-Path -Parent $any[0].FullName); Exe = $any[0].FullName; Engine = 'largest exe'; Confidence = 'medium' } }
    } catch { }

    # 5. give up: the DLL folder (correct for same-folder games, a guess otherwise)
    return [pscustomobject]@{ Dir = $Game.TargetDir; Exe = $null; Engine = 'fallback'; Confidence = 'low' }
}

function Get-ModInstallDir {
    param($Game)
    return (Get-ModInstallDirInfo -Game $Game).Dir
}

function Get-InstallInfo {
    param($Game)
    $mf = Get-ManifestPath -Game $Game
    if (Test-Path -LiteralPath $mf) {
        try {
            $m = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json
            $md = if ($m.PSObject.Properties.Name -contains 'modDir' -and $m.modDir) { $m.modDir } else { $m.targetDir }
            if ($m.proxy -and (Test-Path -LiteralPath (Join-Path $md $m.proxy))) {
                return [pscustomobject]@{ Installed = $true; Proxy = $m.proxy; ModVersion = $m.modVersion; When = $m.installedAt; BackupDir = $m.backupDir; ModDir = $md }
            }
        } catch { }
    }
    # fall back to a size match against our own package (checks the DLL folder only, cheap)
    foreach ($p in $Script:ProxyNames) {
        $tgt = Join-Path $Game.TargetDir $p
        $src = Get-ProxySourcePath -ProxyName $p
        if ((Test-Path -LiteralPath $tgt) -and (Test-Path -LiteralPath $src)) {
            if ((Get-Item -LiteralPath $tgt).Length -eq (Get-Item -LiteralPath $src).Length) {
                return [pscustomobject]@{ Installed = $true; Proxy = $p; ModVersion = 'unknown'; When = 'unknown'; BackupDir = $null; ModDir = $Game.TargetDir }
            }
        }
    }
    return [pscustomobject]@{ Installed = $false; Proxy = $null; ModVersion = $null; When = $null; BackupDir = $null; ModDir = $null }
}

function Get-FreeProxySlots {
    param($Game)
    $free = New-Object System.Collections.Generic.List[string]
    $taken = New-Object System.Collections.Generic.List[string]
    $info = Get-InstallInfo -Game $Game
    $modDir = Get-ModInstallDir -Game $Game
    foreach ($p in $Script:ProxyNames) {
        if (-not (Test-Path -LiteralPath (Get-ProxySourcePath -ProxyName $p))) { continue }
        $tgt = Join-Path $modDir $p
        if ((Test-Path -LiteralPath $tgt) -and ($info.Proxy -ne $p)) { $taken.Add($p) } else { $free.Add($p) }
    }
    return [pscustomobject]@{ Free = @($free); Taken = @($taken) }
}

# ---------------------------------------------------------------- backup / install

function New-Backup {
    param($Game, [string[]]$FilesToSave, [string]$SourceDir)
    if (-not $SourceDir) { $SourceDir = $Game.TargetDir }

    $gameBackupRoot = Join-Path $Script:BackupRoot $Game.Key
    $stamp          = Get-Date -Format 'yyyyMMdd-HHmmss'
    $snapDir        = Join-Path $gameBackupRoot ('snapshot-{0}' -f $stamp)
    $origDir        = Join-Path $gameBackupRoot 'originals'

    [void](New-Item -ItemType Directory -Path $snapDir -Force)
    [void](New-Item -ItemType Directory -Path $origDir -Force)

    $saved = New-Object System.Collections.Generic.List[string]
    foreach ($f in $FilesToSave) {
        $src = Join-Path $SourceDir $f
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $snapDir $f) -Force
            $saved.Add($f)
            Write-Log ('  backed up existing {0}' -f $f)
        }
    }

    # one-time copy of the game's own DLSS DLLs (across every DLL folder), insurance
    foreach ($d in (Get-GameDllDirs -Game $Game)) {
        foreach ($n in $Script:NgxOriginals) {
            $src = Join-Path $d $n
            $dst = Join-Path $origDir $n
            if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $dst)) {
                Copy-Item -LiteralPath $src -Destination $dst -Force
                Write-Log ('  archived original {0}' -f $n)
            }
        }
    }

    $note = @"
DLSSG launcher backup
Game:       $($Game.Name)
Target dir: $($Game.TargetDir)
Created:    $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

snapshot-*  files that existed in the target dir before this install
originals\  the game's own nvngx_dlss*.dll, archived once

To restore by hand: copy the files from this folder back into the target dir
and delete the mod's proxy DLL plus dlssg_sm86.ini.
"@
    $note | Set-Content -LiteralPath (Join-Path $snapDir 'README.txt') -Encoding utf8

    return [pscustomobject]@{ SnapshotDir = $snapDir; OriginalsDir = $origDir; Saved = @($saved) }
}

function Install-Mod {
    param($Game, [string]$Proxy, $IniValues)

    if (-not (Test-ModSource)) { Show-Error "Mod package not found at:`n$Script:ModSrc`n`nUse 'Update mod from GitHub' first."; return $false }

    $src = Get-ProxySourcePath -ProxyName $Proxy
    if (-not (Test-Path -LiteralPath $src)) { Show-Error "Proxy DLL missing from package:`n$src"; return $false }

    if ($Game.AntiCheat) {
        Show-Error ("BLOCKED: this game ships anti-cheat ({0}).`n`n" -f $Game.AntiCheat) +
                   "A proxy DLL with LoadLibrary hooks looks exactly like a cheat to BattlEye and Easy Anti-Cheat, and a ban is not reversible. Refusing to install."
        Write-Log ('install blocked for {0}, anti-cheat detected: {1}' -f $Game.Name, $Game.AntiCheat) 'error'
        return $false
    }

    if (-not (Test-Path -LiteralPath $Game.TargetDir)) { Show-Error "Target folder no longer exists:`n$($Game.TargetDir)"; return $false }

    # the proxy must go next to the render exe, which for UE games is a different
    # folder than the nvngx DLLs (TargetDir)
    $modDir = Get-ModInstallDir -Game $Game

    if (-not (Test-DirWritable -Dir $modDir)) {
        Show-Error ("Cannot write to:`n{0}`n`nClose the game, then relaunch this tool with 'Run as administrator'." -f $modDir)
        return $false
    }

    # This mod must load exactly once. If one of OUR proxies is already installed here
    # (even under a different name), a second copy double-loads and crashes the game.
    $ourExisting = @()
    foreach ($p in $Script:ProxyNames) {
        $tp = Join-Path $modDir $p
        $sp = Get-ProxySourcePath -ProxyName $p
        if ((Test-Path -LiteralPath $tp) -and (Test-Path -LiteralPath $sp) -and ((Get-Item -LiteralPath $tp).Length -eq (Get-Item -LiteralPath $sp).Length)) { $ourExisting += $p }
    }
    $dupes = @($ourExisting | Where-Object { $_ -ne $Proxy })
    if ($dupes.Count -gt 0) {
        if (-not (Confirm-Action ("This mod is already installed here as: {0}`n`nInstalling a second copy as '{1}' would load the mod twice and crash the game.`n`nRemove the existing one and install '{1}' instead? (No = cancel)" -f ($dupes -join ', '), $Proxy) 'Already installed')) {
            return $false
        }
        foreach ($d in $dupes) {
            Remove-Item -LiteralPath (Join-Path $modDir $d) -Force -ErrorAction SilentlyContinue
            Write-Log ('  removed existing mod proxy {0} to avoid a double-load' -f $d)
        }
    }

    $slots = Get-FreeProxySlots -Game $Game
    if (($slots.Taken -contains $Proxy) -and ($ourExisting -notcontains $Proxy)) {
        if (-not (Confirm-Action ("{0} already exists next to the game exe and belongs to another mod.`n`nOverwrite it? A copy is saved to the backup folder first." -f $Proxy) 'Proxy in use')) {
            return $false
        }
    }

    Write-Log ('installing next to render exe: {0}' -f $modDir)
    if ($modDir -ne $Game.TargetDir) { Write-Log ('  (DLSS DLLs are in {0})' -f $Game.TargetDir) }
    $backup = New-Backup -Game $Game -FilesToSave @($Proxy, $Script:IniName) -SourceDir $modDir

    try {
        Copy-Item -LiteralPath $src -Destination (Join-Path $modDir $Proxy) -Force
        Write-Log ('  wrote {0}' -f $Proxy)

        $ini = New-ModIni -Router $IniValues.Router -KernelImage $IniValues.KernelImage `
                          -HardwareBilinear $IniValues.HardwareBilinear `
                          -MaxGeneratedFrames $IniValues.MaxGeneratedFrames -LogLevel $IniValues.Level
        $ini | Set-Content -LiteralPath (Join-Path $modDir $Script:IniName) -Encoding ascii
        Write-Log ('  wrote {0} (Router={1} Kernel={2} Bilinear={3} MaxFrames={4} Log={5})' -f `
                   $Script:IniName, $IniValues.Router, $IniValues.KernelImage, $IniValues.HardwareBilinear, `
                   $IniValues.MaxGeneratedFrames, $IniValues.Level)

        $manifest = [ordered]@{
            game        = $Game.Name
            targetDir   = $Game.TargetDir
            modDir      = $modDir
            proxy       = $Proxy
            iniFile     = $Script:IniName
            modVersion  = (Get-ModVersion)
            installedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            backupDir   = $backup.SnapshotDir
            savedFiles  = $backup.Saved
            ini         = $IniValues
        }
        $mfPath = Get-ManifestPath -Game $Game
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $mfPath) -Force)
        ($manifest | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $mfPath -Encoding utf8

        Write-Log ('INSTALLED {0} -> {1}' -f $Game.Name, $Proxy)
        return $true
    } catch {
        Write-Log ('install failed: {0}' -f $_.Exception.Message) 'error'
        Show-Error ("Install failed:`n{0}`n`nBackup is intact at:`n{1}" -f $_.Exception.Message, $backup.SnapshotDir)
        return $false
    }
}

function Uninstall-Mod {
    param($Game, [switch]$RestoreOriginals)

    $info = Get-InstallInfo -Game $Game
    $modDir = if ($info.ModDir) { $info.ModDir } else { Get-ModInstallDir -Game $Game }
    $removed = New-Object System.Collections.Generic.List[string]

    try {
        $proxies = if ($info.Proxy) { @($info.Proxy) } else { $Script:ProxyNames }
        foreach ($p in $proxies) {
            $tgt = Join-Path $modDir $p
            $src = Get-ProxySourcePath -ProxyName $p
            if (-not (Test-Path -LiteralPath $tgt)) { continue }
            # only delete a DLL that is genuinely ours
            $isOurs = $false
            if ($info.Proxy -eq $p) { $isOurs = $true }
            elseif ((Test-Path -LiteralPath $src) -and ((Get-Item -LiteralPath $tgt).Length -eq (Get-Item -LiteralPath $src).Length)) { $isOurs = $true }
            if ($isOurs) { Remove-Item -LiteralPath $tgt -Force; $removed.Add($p); Write-Log ('  removed {0}' -f $p) }
        }

        $iniPath = Join-Path $modDir $Script:IniName
        if (Test-Path -LiteralPath $iniPath) { Remove-Item -LiteralPath $iniPath -Force; $removed.Add($Script:IniName); Write-Log ('  removed {0}' -f $Script:IniName) }

        $logDir = Join-Path $modDir 'dlssg_sm86'
        if (Test-Path -LiteralPath $logDir) { Remove-Item -LiteralPath $logDir -Recurse -Force; Write-Log '  removed dlssg_sm86 log folder' }

        # put back anything we displaced (proxy/ini in the mod folder)
        if ($info.BackupDir -and (Test-Path -LiteralPath $info.BackupDir)) {
            foreach ($f in @(Get-ChildItem -LiteralPath $info.BackupDir -File | Where-Object { $_.Name -ne 'README.txt' })) {
                Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $modDir $f.Name) -Force
                Write-Log ('  restored {0} from backup' -f $f.Name)
            }
        }

        if ($RestoreOriginals) {
            $origDir = Join-Path (Join-Path $Script:BackupRoot $Game.Key) 'originals'
            if (Test-Path -LiteralPath $origDir) {
                foreach ($f in @(Get-ChildItem -LiteralPath $origDir -File)) {
                    Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $Game.TargetDir $f.Name) -Force
                    Write-Log ('  restored original {0}' -f $f.Name)
                }
            } else { Write-Log '  no archived originals for this game' 'warn' }
        }

        $mf = Get-ManifestPath -Game $Game
        if (Test-Path -LiteralPath $mf) { Remove-Item -LiteralPath $mf -Force }

        if ($removed.Count -eq 0) { Write-Log ('nothing to remove for {0}' -f $Game.Name) 'warn' }
        else { Write-Log ('UNINSTALLED {0}' -f $Game.Name) }
        return $true
    } catch {
        Write-Log ('uninstall failed: {0}' -f $_.Exception.Message) 'error'
        Show-Error ('Uninstall failed:' + "`n" + $_.Exception.Message)
        return $false
    }
}

# ---------------------------------------------------------------- UI

Initialize-Gpu

$form = New-Object System.Windows.Forms.Form
$form.Text = 'DLSSG SM86 Mod Launcher'
$form.Size = New-Object System.Drawing.Size(1140, 760)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(1000, 640)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

# --- header
$header = New-Object System.Windows.Forms.Label
$header.Location = New-Object System.Drawing.Point(14, 12)
$header.Size = New-Object System.Drawing.Size(1100, 20)
$header.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$header.Text = 'GPU: {0}     Route: {1}     Mod: {2}' -f $Script:GpuName, $Script:GpuRoute, (Get-ModVersion)
$form.Controls.Add($header)

if ($Script:GpuRoute -eq 'UNSUPPORTED' -or $Script:GpuRoute -eq 'NATIVE') {
    $header.ForeColor = [System.Drawing.Color]::FromArgb(180, 60, 0)
}

# --- game list
$lblGames = New-Object System.Windows.Forms.Label
$lblGames.Location = New-Object System.Drawing.Point(14, 40)
$lblGames.Size = New-Object System.Drawing.Size(300, 18)
$lblGames.Text = 'Detected games'
$form.Controls.Add($lblGames)

$list = New-Object System.Windows.Forms.ListView
$list.Location = New-Object System.Drawing.Point(14, 60)
$list.Size = New-Object System.Drawing.Size(660, 380)
$list.View = 'Details'
$list.FullRowSelect = $true
$list.MultiSelect = $false
$list.HideSelection = $false
$list.GridLines = $true
[void]$list.Columns.Add('Game', 160)
[void]$list.Columns.Add('Source', 60)
[void]$list.Columns.Add('Frame Gen', 60)
[void]$list.Columns.Add('DLSS DLL', 130)
[void]$list.Columns.Add('Mod', 100)
[void]$list.Columns.Add('Target folder', 150)
$form.Controls.Add($list)

# --- settings panel
$panel = New-Object System.Windows.Forms.GroupBox
$panel.Location = New-Object System.Drawing.Point(690, 40)
$panel.Size = New-Object System.Drawing.Size(420, 400)
$panel.Text = 'Mod settings'
$form.Controls.Add($panel)

function New-PanelLabel {
    param([string]$Text, [int]$Y)
    $l = New-Object System.Windows.Forms.Label
    $l.Location = New-Object System.Drawing.Point(14, ($Y + 3))
    $l.Size = New-Object System.Drawing.Size(150, 18)
    $l.Text = $Text
    $panel.Controls.Add($l)
    return $l
}
function New-PanelCombo {
    param([int]$Y, [string[]]$Items)
    $c = New-Object System.Windows.Forms.ComboBox
    $c.Location = New-Object System.Drawing.Point(170, $Y)
    $c.Size = New-Object System.Drawing.Size(230, 22)
    $c.DropDownStyle = 'DropDownList'
    foreach ($i in $Items) { [void]$c.Items.Add($i) }
    $panel.Controls.Add($c)
    return $c
}

[void](New-PanelLabel -Text 'Proxy DLL' -Y 28)
$cboProxy = New-PanelCombo -Y 28 -Items $Script:ProxyNames

[void](New-PanelLabel -Text 'Router' -Y 60)
$cboRouter = New-PanelCombo -Y 60 -Items @('SM86', 'SM75')

[void](New-PanelLabel -Text 'Kernel image' -Y 92)
$cboKernel = New-PanelCombo -Y 92 -Items @('PTX', 'Auto', 'Cubin')

[void](New-PanelLabel -Text 'Sampling' -Y 124)
$cboBilinear = New-PanelCombo -Y 124 -Items @('0 - exact (default)', '1 - approximate, faster')

[void](New-PanelLabel -Text 'Max multiplier' -Y 156)
$cboFrames = New-PanelCombo -Y 156 -Items @('1 - up to 2X', '2 - up to 3X', '3 - up to 4X')

[void](New-PanelLabel -Text 'Logging' -Y 188)
$cboLog = New-PanelCombo -Y 188 -Items @('0 - off', '1 - errors (default)', '2 - diagnostics', '3 - verbose')

$lblDetail = New-Object System.Windows.Forms.Label
$lblDetail.Location = New-Object System.Drawing.Point(14, 224)
$lblDetail.Size = New-Object System.Drawing.Size(390, 160)
$lblDetail.Text = 'Select a game.'
$panel.Controls.Add($lblDetail)

# --- buttons
function New-Button {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 150, [int]$H = 30)
    $b = New-Object System.Windows.Forms.Button
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($W, $H)
    $b.Text = $Text
    $form.Controls.Add($b)
    return $b
}

$btnScan      = New-Button -Text 'Rescan games'        -X 14   -Y 452 -W 130
$btnAdd       = New-Button -Text 'Add game manually'   -X 150  -Y 452 -W 140
$btnInstall   = New-Button -Text 'Install / update mod' -X 296 -Y 452 -W 150
$btnUninstall = New-Button -Text 'Uninstall + restore' -X 452  -Y 452 -W 150
$btnLaunch    = New-Button -Text 'Launch game'         -X 608  -Y 452 -W 120
$btnFolder    = New-Button -Text 'Open game folder'    -X 734  -Y 452 -W 130
$btnBackups   = New-Button -Text 'Open backups'        -X 870  -Y 452 -W 110
$btnUpdateMod = New-Button -Text 'Update mod'          -X 986  -Y 452 -W 124

# Row 2 (y=488): kept within ~960px so nothing clips even at the minimum window width.
$btnRestoreDlss = New-Button -Text 'Restore original DLLs' -X 14  -Y 488 -W 170 -H 26
$btnDll         = New-Button -Text 'Update DLSS DLLs'      -X 190 -Y 488 -W 170 -H 26
$btnViewIni     = New-Button -Text 'View INI'              -X 366 -Y 488 -W 70  -H 26
$btnModLogs     = New-Button -Text 'Diag logs'             -X 440 -Y 488 -W 95  -H 26
$btnDefender    = New-Button -Text 'Add AV exclusion'      -X 539 -Y 488 -W 120 -H 26
$btnAddRoot     = New-Button -Text 'Add search folder'     -X 663 -Y 488 -W 140 -H 26
$btnDeep        = New-Button -Text 'Deep scan (drives)'    -X 807 -Y 488 -W 150 -H 26
$btnRename      = New-Button -Text 'Rename'                -X 963 -Y 488 -W 100 -H 26

$btnDll.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

$btnInstall.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

# --- log box
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Location = New-Object System.Drawing.Point(14, 522)
$lblLog.Size = New-Object System.Drawing.Size(300, 18)
$lblLog.Text = 'Activity'
$form.Controls.Add($lblLog)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(14, 542)
$logBox.Size = New-Object System.Drawing.Size(1096, 170)
$logBox.Multiline = $true
$logBox.ScrollBars = 'Vertical'
$logBox.ReadOnly = $true
$logBox.BackColor = [System.Drawing.Color]::FromArgb(28, 28, 28)
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(210, 210, 210)
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($logBox)
$Script:LogBox = $logBox

# --- anchoring so resize behaves
$list.Anchor      = 'Top,Left,Bottom'
$panel.Anchor     = 'Top,Right,Bottom'
$logBox.Anchor    = 'Bottom,Left,Right'
$lblLog.Anchor    = 'Bottom,Left'
foreach ($b in @($btnScan, $btnAdd, $btnInstall, $btnUninstall, $btnLaunch, $btnFolder, $btnBackups, $btnUpdateMod, $btnRestoreDlss, $btnViewIni, $btnModLogs, $btnDeep, $btnAddRoot, $btnDefender, $btnDll, $btnRename)) {
    $b.Anchor = 'Bottom,Left'
}

# ---------------------------------------------------------------- UI logic

function Get-SelectedGame {
    if ($list.SelectedItems.Count -eq 0) { return $null }
    return $list.SelectedItems[0].Tag
}

function Update-GameList {
    param([switch]$Quiet)
    $list.BeginUpdate()
    $list.Items.Clear()
    foreach ($g in $Script:Games) {
        $info = Get-InstallInfo -Game $g
        if ($info.Installed) { $modCol = '{0} ({1})' -f $info.Proxy, $info.ModVersion } else { $modCol = 'not installed' }
        $srcCol = if ($g.PSObject.Properties.Name -contains 'Source' -and $g.Source) { $g.Source } else { 'Custom' }
        $item = New-Object System.Windows.Forms.ListViewItem($g.Name)
        [void]$item.SubItems.Add($srcCol)
        [void]$item.SubItems.Add($g.FgSupport)
        [void]$item.SubItems.Add((Get-UpscalerStatus -Game $g))
        [void]$item.SubItems.Add($modCol)
        [void]$item.SubItems.Add($g.TargetDir)
        $item.Tag = $g
        if ($g.AntiCheat)               { $item.ForeColor = [System.Drawing.Color]::FromArgb(190, 30, 30) }
        elseif ($info.Installed)        { $item.ForeColor = [System.Drawing.Color]::FromArgb(20, 120, 40) }
        elseif ($g.FgSupport -ne 'Yes') { $item.ForeColor = [System.Drawing.Color]::Gray }
        [void]$list.Items.Add($item)
    }
    $list.EndUpdate()
    if ($list.Items.Count -gt 0) { $list.Items[0].Selected = $true; $list.Select() }
    if (-not $Quiet) { Write-Log ('{0} candidate folder(s) listed' -f $list.Items.Count) }
}

function Invoke-Scan {
    param([switch]$Deep)
    $form.Cursor = 'WaitCursor'
    $btnScan.Enabled = $false; $btnDeep.Enabled = $false
    try {
        Write-Log ('starting {0} scan' -f $(if ($Deep) { 'DEEP (all drives)' } else { 'standard' }))
        $Script:Games = @(Find-Games -Deep:$Deep)
        Save-GameCache -Games $Script:Games -Deep ([bool]$Deep)
        Update-GameList
        Write-Log ('scan complete, {0} folder(s) cached' -f $Script:Games.Count)
    } finally {
        $btnScan.Enabled = $true; $btnDeep.Enabled = $true
        $form.Cursor = 'Default'
    }
}

function Load-FromCache {
    $Script:Games = @(Get-CachedGames)
    if ($Script:Games.Count -eq 0) { return $false }
    $state = Get-State
    # apply rename overrides to cached entries too, so names are correct before a rescan
    $ov = $state.nameOverrides
    if ($ov) {
        foreach ($e in $Script:Games) {
            $nm = Get-OverrideName -Overrides $ov -TargetDir $e.TargetDir
            if ($nm -and $nm -ne $e.Name) { $e.Name = $nm; $e.Key = (Get-PathKey -Name $nm -Path $e.TargetDir) }
        }
    }
    Update-GameList -Quiet
    Write-Log ('loaded {0} game(s) from cache (last scan {1}). Use Rescan to refresh.' -f $Script:Games.Count, $state.lastScan)
    return $true
}

function Update-DetailPanel {
    $g = Get-SelectedGame
    if (-not $g) {
        $lblDetail.Text = 'Select a game.'
        foreach ($c in @($btnInstall, $btnUninstall, $btnLaunch, $btnFolder, $btnRestoreDlss, $btnViewIni, $btnModLogs, $btnDll, $btnRename)) { $c.Enabled = $false }
        return
    }

    $info  = Get-InstallInfo -Game $g
    $slots = Get-FreeProxySlots -Game $g

    # repopulate proxy list: free slots first, mark taken ones
    $cboProxy.Items.Clear()
    $preferred = if ($info.Proxy) { $info.Proxy } else { $null }
    foreach ($p in $Script:ProxyNames) {
        if (-not (Test-Path -LiteralPath (Get-ProxySourcePath -ProxyName $p))) { continue }
        if ($slots.Taken -contains $p) { [void]$cboProxy.Items.Add(('{0}  (in use by another mod)' -f $p)) }
        else                           { [void]$cboProxy.Items.Add($p) }
    }
    $pick = 0
    for ($i = 0; $i -lt $cboProxy.Items.Count; $i++) {
        $txt = [string]$cboProxy.Items[$i]
        if ($preferred -and $txt -like ($preferred + '*')) { $pick = $i; break }
        if (-not $preferred -and $txt -notlike '*in use*') { $pick = $i; break }
    }
    if ($cboProxy.Items.Count -gt 0) { $cboProxy.SelectedIndex = $pick }

    $ini = Read-ModIni -Path (Join-Path (Get-ModInstallDir -Game $g) $Script:IniName)
    $cboRouter.SelectedItem = if ($Script:ProxyNames -and $ini.Router -eq 'SM75') { 'SM75' } else { $ini.Router }
    if (-not $cboRouter.SelectedItem) { $cboRouter.SelectedItem = $Script:GpuRoute }
    if (-not $cboRouter.SelectedItem) { $cboRouter.SelectedIndex = 0 }
    $cboKernel.SelectedItem   = $ini.KernelImage
    if (-not $cboKernel.SelectedItem) { $cboKernel.SelectedIndex = 0 }
    $cboBilinear.SelectedIndex = [Math]::Min([Math]::Max($ini.HardwareBilinear, 0), 1)
    $cboFrames.SelectedIndex   = [Math]::Min([Math]::Max($ini.MaxGeneratedFrames - 1, 0), 2)
    $cboLog.SelectedIndex      = [Math]::Min([Math]::Max($ini.Level, 0), 3)

    $exeName = if ($g.RenderExe) { Split-Path -Leaf $g.RenderExe } else { '(none found)' }
    $ngx     = if ($g.NgxFiles -and $g.NgxFiles.Count -gt 0) { ($g.NgxFiles -join ', ') } else { 'none' }

    $mdInfo = Get-ModInstallDirInfo -Game $g
    $lines = @()
    $lines += 'Render exe:   {0}' -f $exeName
    $lines += 'NGX present:  {0}' -f $ngx
    $lines += 'Frame Gen:    {0}' -f $g.FgSupport
    $lines += 'Mod folder:   {0}  [{1}, {2}]' -f (Split-Path -Leaf $mdInfo.Dir), $mdInfo.Engine, $mdInfo.Confidence
    if ($info.Installed) {
        $lines += ''
        $lines += 'Mod INSTALLED as {0}' -f $info.Proxy
        $lines += 'Version {0}, {1}' -f $info.ModVersion, $info.When
    } else {
        $lines += ''
        $lines += 'Mod not installed.'
    }
    if ($g.AntiCheat) {
        $lines += ''
        $lines += 'ANTI-CHEAT DETECTED: {0}' -f $g.AntiCheat
        $lines += 'Install is blocked. Ban risk is not reversible.'
    }
    if ($g.FgSupport -eq 'DLSS only') {
        $lines += ''
        $lines += 'No nvngx_dlssg.dll here, so this game most likely'
        $lines += 'has no Frame Generation support to unlock.'
    }
    $lblDetail.Text = ($lines -join "`r`n")

    $blocked = [bool]$g.AntiCheat
    $btnInstall.Enabled     = (-not $blocked)
    $btnUninstall.Enabled   = $info.Installed
    $btnLaunch.Enabled      = [bool]$g.RenderExe
    $btnFolder.Enabled      = $true
    $btnRestoreDlss.Enabled = $true
    $btnViewIni.Enabled     = (Test-Path -LiteralPath (Join-Path (Get-ModInstallDir -Game $g) $Script:IniName))
    $btnModLogs.Enabled     = (Test-Path -LiteralPath (Join-Path (Get-ModInstallDir -Game $g) 'dlssg_sm86'))
    $btnDll.Enabled         = ($g.NgxFiles -and $g.NgxFiles.Count -gt 0)
    $btnRename.Enabled      = $true
}

function Get-UiIniValues {
    return [ordered]@{
        Router             = [string]$cboRouter.SelectedItem
        KernelImage        = [string]$cboKernel.SelectedItem
        HardwareBilinear   = [int]([string]$cboBilinear.SelectedItem).Substring(0, 1)
        MaxGeneratedFrames = [int]([string]$cboFrames.SelectedItem).Substring(0, 1)
        Level              = [int]([string]$cboLog.SelectedItem).Substring(0, 1)
    }
}

function Show-DllManager {
    param($Game)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'DLSS DLL manager - {0}' -f $Game.Name
    $dlg.Size = New-Object System.Drawing.Size(720, 500)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Location = New-Object System.Drawing.Point(14, 12)
    $lblIntro.Size = New-Object System.Drawing.Size(680, 40)
    $lblIntro.Text = "Swaps this game's DLSS DLLs to the newer versions in your library folder. Latest (310.x+) versions include the DLSS 4 transformer model. Originals are backed up. This is separate from the Frame-Gen mod and safe to use alongside it."
    $dlg.Controls.Add($lblIntro)

    $grid = New-Object System.Windows.Forms.ListView
    $grid.Location = New-Object System.Drawing.Point(14, 58)
    $grid.Size = New-Object System.Drawing.Size(680, 150)
    $grid.View = 'Details'; $grid.FullRowSelect = $true; $grid.GridLines = $true
    [void]$grid.Columns.Add('DLSS component', 210)
    [void]$grid.Columns.Add('File', 130)
    [void]$grid.Columns.Add('In game', 110)
    [void]$grid.Columns.Add('In library', 110)
    [void]$grid.Columns.Add('Action', 110)
    $dlg.Controls.Add($grid)

    $lblLib = New-Object System.Windows.Forms.Label
    $lblLib.Location = New-Object System.Drawing.Point(14, 218)
    $lblLib.Size = New-Object System.Drawing.Size(680, 18)
    $dlg.Controls.Add($lblLib)

    $note = New-Object System.Windows.Forms.TextBox
    $note.Location = New-Object System.Drawing.Point(14, 240)
    $note.Size = New-Object System.Drawing.Size(680, 108)
    $note.Multiline = $true; $note.ReadOnly = $true; $note.ScrollBars = 'Vertical'
    $note.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
    $note.Text = @"
AUTOMATED (recommended): click 'Download latest (auto, verified)'. It pulls the
newest DLSS DLLs from the DLSS Swapper manifest (open source), checks each file's
MD5 hash, saves them to your library folder, then offers to apply them here.

MANUAL (alternative): 'Get manually (browser)' opens TechPowerUp; drop the .dll
files into your library folder ('Set library folder'), then 'Update this game now'.

Either way, originals are backed up and can be restored from the main window.

To actually USE the transformer model in-game, set it once in the NVIDIA App:
  Graphics > (per game or Global) > 'DLSS Override - Model Presets' > Latest.
  Driver-level, needs no extra files, will not conflict with the Frame-Gen mod.
Ray Reconstruction only appears in games that already support it. On your card the
Frame-Gen DLL swap does nothing (the version.dll mod provides Frame Gen instead).
"@
    $dlg.Controls.Add($note)

    function Refresh-Grid {
        $grid.Items.Clear()
        $lib = Get-DllLibraryDir
        $lblLib.Text = 'Library folder: {0}' -f $lib
        $dllDirs = Get-GameDllDirs -Game $Game
        foreach ($f in $Script:DllTypes.Keys) {
            $gameV = $null
            foreach ($d in $dllDirs) { $v = Get-FileVersionSafe -Path (Join-Path $d $f); if ($v) { $gameV = $v; break } }
            $libV  = Get-FileVersionSafe -Path (Join-Path $lib $f)
            $inGame = if ($gameV) { $gameV } else { 'not used' }
            $inLib  = if ($libV) { $libV } else { '-' }
            if (-not $gameV)        { $act = 'n/a (game lacks it)' }
            elseif (-not $libV)     { $act = 'no library file' }
            elseif ((Compare-DllVersion -A $libV -B $gameV) -gt 0) { $act = 'UPDATE available' }
            elseif ((Compare-DllVersion -A $libV -B $gameV) -eq 0 -and $libV -eq $gameV) { $act = 'up to date' }
            else                    { $act = 'library is older' }
            $it = New-Object System.Windows.Forms.ListViewItem($Script:DllTypes[$f])
            [void]$it.SubItems.Add($f); [void]$it.SubItems.Add($inGame); [void]$it.SubItems.Add($inLib); [void]$it.SubItems.Add($act)
            if ($act -eq 'UPDATE available') { $it.ForeColor = [System.Drawing.Color]::FromArgb(20, 110, 40) }
            elseif ($act -like 'n/a*')       { $it.ForeColor = [System.Drawing.Color]::Gray }
            [void]$grid.Items.Add($it)
        }
    }
    Refresh-Grid

    # Row 1: automated + apply (primary)
    $y1 = 356
    $bAuto = New-Object System.Windows.Forms.Button; $bAuto.Text = 'Download latest (auto, verified)'; $bAuto.Location = New-Object System.Drawing.Point(14, $y1); $bAuto.Size = New-Object System.Drawing.Size(210, 30); $bAuto.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold); $dlg.Controls.Add($bAuto)
    $bUpd  = New-Object System.Windows.Forms.Button; $bUpd.Text  = 'Update this game now';              $bUpd.Location  = New-Object System.Drawing.Point(230, $y1); $bUpd.Size  = New-Object System.Drawing.Size(160, 30); $bUpd.Font  = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold); $dlg.Controls.Add($bUpd)
    $bClose = New-Object System.Windows.Forms.Button; $bClose.Text = 'Close';                            $bClose.Location = New-Object System.Drawing.Point(574, $y1); $bClose.Size = New-Object System.Drawing.Size(120, 30); $dlg.Controls.Add($bClose)

    # Row 2: manual / utility
    $y2 = 394
    $bLib  = New-Object System.Windows.Forms.Button; $bLib.Text  = 'Set library folder';        $bLib.Location  = New-Object System.Drawing.Point(14, $y2);  $bLib.Size  = New-Object System.Drawing.Size(140, 28); $dlg.Controls.Add($bLib)
    $bOpen = New-Object System.Windows.Forms.Button; $bOpen.Text = 'Open library';              $bOpen.Location = New-Object System.Drawing.Point(160, $y2); $bOpen.Size = New-Object System.Drawing.Size(100, 28); $dlg.Controls.Add($bOpen)
    $bGet  = New-Object System.Windows.Forms.Button; $bGet.Text  = 'Get manually (browser)';    $bGet.Location  = New-Object System.Drawing.Point(266, $y2); $bGet.Size  = New-Object System.Drawing.Size(200, 28); $dlg.Controls.Add($bGet)

    $bAuto.Add_Click({
        if (-not (Confirm-Action "Download the newest DLSS DLLs into your library folder from the DLSS Swapper manifest (open source), verifying each file's MD5 hash?`n`nSuper Resolution, Ray Reconstruction and Frame Generation will be fetched." 'Auto-download')) { return }
        $dlg.Cursor = 'WaitCursor'; $bAuto.Enabled = $false
        try {
            $mani = Get-DllManifest
            $res  = Invoke-AutoDownloadDlls -Files @($Script:DllTypes.Keys) -Manifest $mani
        } catch {
            Show-Error ("Download failed:`n{0}" -f $_.Exception.Message); return
        } finally { $dlg.Cursor = 'Default'; $bAuto.Enabled = $true }
        Refresh-Grid
        $ok = @($res | Where-Object { $_ -notlike '*FAILED*' })
        if ($ok.Count -gt 0 -and (Confirm-Action ("Downloaded to library (verified):`n`n{0}`n`nApply these to {1} now? Originals are backed up first." -f ($res -join "`n"), $Game.Name) 'Downloaded')) {
            $applied = Update-DlssDlls -Game $Game -Files @($Script:DllTypes.Keys)
            Refresh-Grid
            Show-Info ("Applied:`n`n{0}`n`nNow set the preset to 'Latest' in the NVIDIA App to use the transformer model." -f ($(if ($applied.Count) { $applied -join "`n" } else { '(nothing applicable to this game)' })))
        } else {
            Show-Info ("Result:`n`n{0}" -f ($res -join "`n"))
        }
    })
    $bUpd.Add_Click({
        $files = @($Script:DllTypes.Keys)
        $applied = Update-DlssDlls -Game $Game -Files $files
        Refresh-Grid
        if ($applied.Count -gt 0) {
            Show-Info ("Updated:`n`n{0}`n`nRemember to set the preset to 'Latest' in the NVIDIA App to use the transformer model." -f ($applied -join "`n"))
        } else {
            Show-Info "Nothing to update. Either the library has no newer DLLs, or it has no nvngx_*.dll files yet. Use 'Download latest (auto)' or 'Get manually', then try again."
        }
    })
    $bLib.Add_Click({
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = 'Folder where you keep the latest nvngx_*.dll files'
        if ($fb.ShowDialog() -eq 'OK') {
            $st = Get-State; $st.dllLibrary = $fb.SelectedPath; Save-State -State $st
            Write-Log ('DLL library set to {0}' -f $fb.SelectedPath)
            Refresh-Grid
        }
    })
    $bOpen.Add_Click({ Start-Process explorer.exe -ArgumentList ('"{0}"' -f (Get-DllLibraryDir)) })
    $bGet.Add_Click({
        Start-Process 'https://www.techpowerup.com/download/nvidia-dlss-dll/'                        # nvngx_dlss.dll  (Super Resolution)
        Start-Process 'https://www.techpowerup.com/download/nvidia-dlss-3-ray-reconstruction-dll/'    # nvngx_dlssd.dll (Ray Reconstruction)
        Start-Process 'https://www.techpowerup.com/download/nvidia-dlss-3-frame-generation-dll/'      # nvngx_dlssg.dll (Frame Generation)
    })
    $bClose.Add_Click({ $dlg.Close() })

    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
    Update-GameList -Quiet
}

# ---------------------------------------------------------------- events

$list.Add_SelectedIndexChanged({ Update-DetailPanel })

$btnScan.Add_Click({ Invoke-Scan })

$btnDll.Add_Click({
    $g = Get-SelectedGame
    if (-not $g) { return }
    if (-not $g.NgxFiles -or $g.NgxFiles.Count -eq 0) { Show-Warn 'This game has no DLSS DLLs to update.'; return }
    Show-DllManager -Game $g
})

$btnRename.Add_Click({
    $g = Get-SelectedGame
    if (-not $g) { return }
    $new = [Microsoft.VisualBasic.Interaction]::InputBox("New name for this game:`n`n$($g.TargetDir)", 'Rename game', $g.Name)
    if (-not $new) { return }
    if (Rename-GameEntry -Game $g -NewName $new) {
        Update-GameList -Quiet
        foreach ($it in $list.Items) { if ($it.Tag.TargetDir -eq $g.TargetDir) { $it.Selected = $true; $it.EnsureVisible() } }
        Update-DetailPanel
    }
})

$btnAdd.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Select the game''s main EXE (its DLSS DLLs are found automatically, even in subfolders)'
    $dlg.Filter = 'Game executable (*.exe)|*.exe'
    if ($dlg.ShowDialog() -ne 'OK') { return }

    $dir  = Split-Path -Parent $dlg.FileName
    # name from the exe's own metadata first, then a sensible folder name
    try { $vi = (Get-Item -LiteralPath $dlg.FileName).VersionInfo } catch { $vi = $null }
    $name = $null
    if ($vi) { foreach ($c in @($vi.ProductName, $vi.FileDescription)) { if ($c -and ($c.Trim().Length -ge 3) -and $c -notmatch '^(game|launcher|shipping|application|unreal.*)$') { $name = $c.Trim(); break } } }
    if (-not $name) { $name = Get-GameNameFromPath -Dir $dir }

    $state = Get-State
    $manual = @(@($state.manualGames) | Where-Object { $_ })
    if ($manual | Where-Object { $_.TargetDir -eq $dir }) {
        Show-Info 'That folder is already in the list.'
        return
    }
    $state.manualGames = @($manual) + @([pscustomobject]@{ Name = $name; TargetDir = $dir })
    Save-State -State $state
    Write-Log ('added manual entry: {0} -> {1}' -f $name, $dir)
    Invoke-Scan
})

$btnInstall.Add_Click({
    $g = Get-SelectedGame
    if (-not $g) { return }

    $proxyText = [string]$cboProxy.SelectedItem
    if (-not $proxyText) { Show-Warn 'No proxy DLL available in the package.'; return }
    $proxy = ($proxyText -split '\s+')[0]

    $vals = Get-UiIniValues
    if ($Script:GpuRoute -in @('SM86', 'SM75') -and $vals.Router -ne $Script:GpuRoute) {
        if (-not (Confirm-Action ("Router is set to {0} but your GPU is {1}.`n`nContinue anyway?" -f $vals.Router, $Script:GpuRoute) 'Router mismatch')) { return }
    }

    # Work out where the proxy must go (next to the render exe) and let the user confirm
    # or override it, since no auto-detect is perfect for every game.
    $info = Get-ModInstallDirInfo -Game $g
    $exeName = if ($info.Exe) { Split-Path -Leaf $info.Exe } else { '(no exe found)' }
    $warn = switch ($info.Confidence) {
        'medium' { "`n`nNote: best guess (largest exe). Verify this is the game's main exe folder." }
        'low'    { "`n`nWARNING: could not confidently find the exe. Verify before installing." }
        default  { '' }
    }
    $dllNote = if ($info.Dir -ne $g.TargetDir) { "`n(DLSS DLLs stay in {0})" -f $g.TargetDir } else { '' }
    $msg = ("Install folder (next to the render exe):`n{0}`n`nBased on: {1}   [{2}, {3} confidence]{4}{5}`n`nProxy: {6}   Router: {7}`nAnything overwritten is backed up first. Close the game.`n`nYes = install here    No = pick a different folder    Cancel = abort" -f `
            $info.Dir, $exeName, $info.Engine, $info.Confidence, $dllNote, $warn, $proxy, $vals.Router)
    $res = [System.Windows.Forms.MessageBox]::Show($msg, 'Confirm install folder', 'YesNoCancel', 'Question')
    if ($res -eq 'Cancel') { return }
    if ($res -eq 'No') {
        $fd = New-Object System.Windows.Forms.OpenFileDialog
        $fd.Title = 'Pick the game''s main EXE (the mod installs into its folder)'
        $fd.Filter = 'Game executable (*.exe)|*.exe'
        if ($info.Dir -and (Test-Path -LiteralPath $info.Dir)) { $fd.InitialDirectory = $info.Dir }
        if ($fd.ShowDialog() -ne 'OK') { return }
        $chosen = Split-Path -Parent $fd.FileName
        Set-ModDirOverride -Game $g -Dir $chosen
        if ($g.PSObject.Properties.Name -contains 'ModDir') { $g.ModDir = $chosen } else { $g | Add-Member -NotePropertyName ModDir -NotePropertyValue $chosen -Force }
        Write-Log ('mod folder overridden -> {0}' -f $chosen)
    }

    $form.Cursor = 'WaitCursor'
    try {
        if (Install-Mod -Game $g -Proxy $proxy -IniValues $vals) {
            Update-GameList -Quiet
            foreach ($it in $list.Items) { if ($it.Tag.TargetDir -eq $g.TargetDir) { $it.Selected = $true } }
            Update-DetailPanel
            Show-Info ("Installed.`n`nNow launch the game, turn on DLSS Super Resolution and NVIDIA Reflex, then enable DLSS Frame Generation.`n`nIf VRAM runs short you get stutter rather than low FPS, so drop textures or resolution first.")
        }
    } finally { $form.Cursor = 'Default' }
})

$btnUninstall.Add_Click({
    $g = Get-SelectedGame
    if (-not $g) { return }
    if (-not (Confirm-Action ("Remove the mod from:`n{0}`n`nThis deletes the proxy DLL and INI, then restores anything the install displaced." -f $g.TargetDir) 'Uninstall')) { return }

    $form.Cursor = 'WaitCursor'
    try {
        if (Uninstall-Mod -Game $g) {
            Update-GameList -Quiet
            foreach ($it in $list.Items) { if ($it.Tag.TargetDir -eq $g.TargetDir) { $it.Selected = $true } }
            Update-DetailPanel
            Show-Info 'Mod removed and backups restored.'
        }
    } finally { $form.Cursor = 'Default' }
})

$btnRestoreDlss.Add_Click({
    $g = Get-SelectedGame
    if (-not $g) { return }
    $origDir = Join-Path (Join-Path $Script:BackupRoot $g.Key) 'originals'
    if (-not (Test-Path -LiteralPath $origDir)) { Show-Warn 'No archived originals for this game yet. They are archived on first install.'; return }
    $files = @(Get-ChildItem -LiteralPath $origDir -File)
    if ($files.Count -eq 0) { Show-Warn 'Originals folder is empty.'; return }
    if (-not (Confirm-Action ("Copy these back into the game folder, overwriting what is there?`n`n{0}" -f (($files.Name) -join "`n")) 'Restore originals')) { return }
    foreach ($f in $files) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $g.TargetDir $f.Name) -Force
        Write-Log ('  restored original {0}' -f $f.Name)
    }
    Show-Info 'Original DLSS DLLs restored.'
})

$btnLaunch.Add_Click({
    $g = Get-SelectedGame
    if (-not $g) { return }
    $uri = if ($g.PSObject.Properties.Name -contains 'LaunchUri') { $g.LaunchUri } else { $null }
    try {
        if ($uri) {
            Write-Log ('launching via {0}: {1}' -f $g.Source, $uri)
            Start-Process $uri
        } elseif ($g.RenderExe) {
            Write-Log ('launching {0}' -f $g.RenderExe)
            Start-Process -FilePath $g.RenderExe -WorkingDirectory $g.TargetDir
        } else {
            Show-Warn 'No launch method found for this game. Start it from its own launcher.'
        }
    } catch { Show-Error ('Could not launch:' + "`n" + $_.Exception.Message) }
})

$btnDeep.Add_Click({
    if (-not (Confirm-Action "Deep scan sweeps every folder on all fixed drives for DLSS games, including custom install locations.`n`nThis can take a few minutes on large or mechanical drives. Continue?" 'Deep scan')) { return }
    Invoke-Scan -Deep
})

$btnAddRoot.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Pick a folder that contains your games (it is remembered and swept on every scan)'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $state = Get-State
    $roots = @(@($state.extraRoots) | Where-Object { $_ })
    if ($roots -contains $dlg.SelectedPath) { Show-Info 'That folder is already a search root.'; return }
    $state.extraRoots = @($roots) + @($dlg.SelectedPath)
    Save-State -State $state
    Write-Log ('added search root: {0}' -f $dlg.SelectedPath)
    Invoke-Scan
})

$btnDefender.Add_Click({
    $g = Get-SelectedGame
    if (-not $g) { return }
    if (Test-PathExcluded -Path $g.TargetDir) {
        if (Confirm-Action ("This folder is already a Defender exclusion:`n{0}`n`nRemove the exclusion instead?" -f $g.TargetDir) 'Exclusion exists') {
            if (Remove-DefenderException -Game $g) { Show-Info 'Exclusion removed.' } else { Show-Warn 'Could not remove it (need admin, or third-party AV).' }
        }
        return
    }
    $msg = "Add a Windows Defender exclusion for:`n{0}`n`nThis tells Defender to trust this folder so the mod is not quarantined as a false positive. It does not change the files and can be undone here. Admin rights are required." -f $g.TargetDir
    if (-not (Confirm-Action $msg 'Add antivirus exclusion')) { return }
    $info = Get-InstallInfo -Game $g
    if (Add-DefenderException -Game $g -Proxy $info.Proxy) { Show-Info 'Defender exclusion added.' }
})

$btnFolder.Add_Click({
    $g = Get-SelectedGame
    if ($g) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $g.TargetDir) }
})

$btnBackups.Add_Click({
    [void](New-Item -ItemType Directory -Path $Script:BackupRoot -Force)
    Start-Process explorer.exe -ArgumentList ('"{0}"' -f $Script:BackupRoot)
})

$btnViewIni.Add_Click({
    $g = Get-SelectedGame
    if (-not $g) { return }
    $p = Join-Path (Get-ModInstallDir -Game $g) $Script:IniName
    if (Test-Path -LiteralPath $p) { Start-Process notepad.exe -ArgumentList ('"{0}"' -f $p) }
    else { Show-Warn 'No INI installed for this game.' }
})

$btnModLogs.Add_Click({
    $g = Get-SelectedGame
    if (-not $g) { return }
    $p = Join-Path (Get-ModInstallDir -Game $g) 'dlssg_sm86\logs'
    if (Test-Path -LiteralPath $p) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $p) }
    else { Show-Warn ("No logs yet.`n`nSet Logging to '2 - diagnostics', reinstall, run the game once, then check again.") }
})

$btnUpdateMod.Add_Click({
    if (-not (Confirm-Action "Download the latest package from GitHub?`n`nThe current package folder is kept as a .old_ copy. Games already modded are not touched until you reinstall." 'Update mod')) { return }
    $form.Cursor = 'WaitCursor'
    try {
        if (Update-ModSource) {
            $header.Text = 'GPU: {0}     Route: {1}     Mod: {2}' -f $Script:GpuName, $Script:GpuRoute, (Get-ModVersion)
            Update-GameList -Quiet
            Update-DetailPanel
            Show-Info ('Package updated to {0}. Reinstall on each game to apply it.' -f (Get-ModVersion))
        } else { Show-Error 'Download failed. See the activity log.' }
    } finally { $form.Cursor = 'Default' }
})

# ---------------------------------------------------------------- startup

$form.Add_Shown({
    Write-Log ('DLSSG launcher started, root {0}' -f $Script:Root)
    Write-Log ('GPU: {0}, route {1}' -f $Script:GpuName, $Script:GpuRoute)

    if ($Script:GpuRoute -eq 'NATIVE') {
        Show-Info 'Your GPU already supports DLSS Frame Generation natively. This mod is for RTX 20 and 30 series cards, you do not need it.'
    } elseif ($Script:GpuRoute -eq 'UNSUPPORTED') {
        Show-Warn 'No RTX 20/30 series NVIDIA GPU detected. This mod needs Ampere (SM86) or Turing (SM75) hardware and NVIDIA NGX/NVAPI/CUDA driver interfaces.'
    }

    if (-not (Test-ModSource)) {
        if (Confirm-Action ("Mod package not found at:`n{0}`n`nDownload it from GitHub now?" -f $Script:ModSrc) 'Package missing') {
            [void](Update-ModSource)
            $header.Text = 'GPU: {0}     Route: {1}     Mod: {2}' -f $Script:GpuName, $Script:GpuRoute, (Get-ModVersion)
        }
    }

    # Cache-first: load the last scan instead of rescanning on every launch.
    if (Load-FromCache) {
        $state = Get-State
        Write-Log ("showing cached results from {0}. Click 'Rescan games' to refresh." -f $state.lastScan)
    } else {
        Write-Log 'no cache yet, running first scan'
        Invoke-Scan
    }
    Update-DetailPanel
})

[void]$form.ShowDialog()
$form.Dispose()
