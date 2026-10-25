# DLSS Updater - aggiorna il file DLSS (nvngx_dlss.dll) dei giochi con l'ultima
# versione ufficiale NVIDIA, salvando sempre l'originale per poterlo ripristinare.
# Scarica solo dal repository ufficiale github.com/NVIDIA/DLSS e verifica che il
# file sia firmato da NVIDIA prima di usarlo. Non tocca giochi con anti-cheat.
#
# Creato da Sairiin. (c) 2026 Sairiin - Tutti i diritti riservati.
# Vietata la copia, la modifica e la distribuzione senza autorizzazione dell'autore.

#Requires -Version 5.1
param([switch]$NoElevate)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$CacheDir = Join-Path $Root 'cache'
$BackupDir = Join-Path $Root 'backup'
$BackupIndex = Join-Path $BackupDir 'indice.json'
$LogFile = Join-Path $Root 'registro.log'
$DllName = 'nvngx_dlss.dll'

# Program Files richiede i permessi di amministratore per scrivere.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $NoElevate) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($MyInvocation.MyCommand.Path)`""
    return
}

New-Item -ItemType Directory -Force $CacheDir, $BackupDir | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
. (Join-Path $Root 'NvidiaSettings.ps1')
$NvBackupDir = Join-Path $BackupDir 'nvidia'
$IconFile = Join-Path $Root 'DLSSUpdater.ico'
$Author = 'Sairiin'

function Write-Log([string]$msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg" | Add-Content -Path $LogFile -Encoding UTF8
}

function ConvertTo-DlssVersion([string]$raw) {
    if (-not $raw) { return [version]'0.0' }
    $clean = ($raw -replace ',', '.' -replace '\s', '') -replace '[^0-9\.]', ''
    try { return [version]$clean } catch { return [version]'0.0' }
}

# Nome commerciale della versione del file. 310.5.0 e' la prima con i preset L/M
# (Transformer di 2a generazione, DLSS 4.5). Il "DLSS 5" Neural Rendering usa un
# file diverso (nvngx_dlssnr.dll), quindi nvngx_dlss.dll non lo e' mai.
function Get-DlssGeneration([version]$v) {
    if ($v -ge [version]'310.5') { return 'DLSS 4.5' }
    if ($v -ge [version]'310.0') { return 'DLSS 4' }
    if ($v.Major -ge 3) { return 'DLSS 3' }
    if ($v.Major -eq 2) { return 'DLSS 2' }
    if ($v.Major -eq 1) { return 'DLSS 1' }
    return 'DLSS ?'
}

function Get-GameSource([string]$dir) {
    if ($dir -match '\\steamapps\\') { return 'Steam' }
    if ($dir -match '\\XboxGames\\|\\WindowsApps\\') { return 'Xbox' }
    if (Test-Path (Join-Path $dir '.build.info')) { return 'Battle.net' }
    if (Test-Path (Join-Path $dir '.egstore')) { return 'Epic' }
    if (Get-ChildItem $dir -Filter 'goggame-*.info' -ErrorAction SilentlyContinue | Select-Object -First 1) { return 'GOG' }
    if ($dir -match '\\Grinding Gear Games\\') { return 'Grinding Gear' }
    if ($dir -match '\\Ubisoft Game Launcher\\') { return 'Ubisoft' }
    if ($dir -match '\\(EA Games|Origin Games)\\') { return 'EA' }
    if ($dir -match '\\Rockstar Games\\') { return 'Rockstar' }
    return 'Altro'
}

# --- Indice dei backup: percorso del gioco -> file di backup + versione originale ---
function Get-BackupIndex {
    if (Test-Path $BackupIndex) {
        $h = @{}
        (Get-Content $BackupIndex -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }
        return $h
    }
    return @{}
}
function Save-BackupIndex($h) { $h | ConvertTo-Json -Depth 3 | Set-Content $BackupIndex -Encoding UTF8 }

# --- Ricerca dei giochi ---
# Cartelle aggiunte a mano dall'utente, salvate in config.json.
$ConfigFile = Join-Path $Root 'config.json'
# Preferenze: CartelleExtra (cartelle di giochi aggiunte a mano), FinestraMax (tutti i giochi in finestra massimizzata).
function Get-Config {
    $cfg = [ordered]@{ CartelleExtra = @(); FinestraMax = $false }
    if (Test-Path $ConfigFile) {
        try {
            $j = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            if ($j.CartelleExtra) { $cfg.CartelleExtra = @($j.CartelleExtra) }
            $cfg.FinestraMax = ($j.FinestraMax -eq $true)   # le versioni vecchie salvavano un elenco: vale come "spento"
        } catch {}
    }
    return [pscustomobject]$cfg
}
function Save-Config($cfg) { $cfg | ConvertTo-Json | Set-Content $ConfigFile -Encoding UTF8 }
function Get-ExtraFolders { @((Get-Config).CartelleExtra) }
function Add-ExtraFolder([string]$dir) {
    $cfg = Get-Config
    $cfg.CartelleExtra = @(@($cfg.CartelleExtra) + $dir | Where-Object { $_ } | Sort-Object -Unique)
    Save-Config $cfg
}
function Set-FinestraMax([bool]$on) {
    $cfg = Get-Config
    $cfg.FinestraMax = $on
    Save-Config $cfg
}

# Il DLSS dei giochi Unreal Engine sta molto in profondita'
# (Gioco\Engine\Plugins\Runtime\Nvidia\DLSS\Binaries\ThirdParty\Win64).
$DeepScan = 10
$ShallowScan = 4

# Tutti i giochi installati, letti dagli elenchi dei launcher (cosi' compaiono solo giochi):
# restituisce cartella -> @{ Nome; Fonte }. I nomi dei launcher (es. Steam) hanno la precedenza.
function Get-InstalledGames {
    $games = [ordered]@{}
    function AddGame([string]$dir, [string]$name, [string]$src) {
        if (-not $dir) { return }
        $dir = $dir.Trim('"').TrimEnd('\')
        if (-not (Test-Path $dir -PathType Container)) { return }
        if ($dir -match '\\(Battle\.net|Ubisoft Game Launcher|EA Desktop|Origin|Launcher|Steam|steamapps|common|Epic Games|GOG Galaxy)$') { return }   # launcher e librerie, non giochi
        if ($dir -match '\\steamapps\\') { $src = 'Steam' }   # l'editore lo registra, ma e' la copia di Steam
        if ($games.Contains($dir)) { return }
        if (-not $name) { $name = Split-Path $dir -Leaf }
        if ($name -match 'Launcher$') { return }
        $games[$dir] = [pscustomobject]@{ Nome = $name; Fonte = $src }
    }

    # Steam: i file appmanifest danno nome vero e cartella di ogni gioco.
    foreach ($s in "${env:ProgramFiles(x86)}\Steam", "$env:ProgramFiles\Steam", (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath) {
        if (-not $s) { continue }
        $vdf = Join-Path ($s -replace '/', '\') 'steamapps\libraryfolders.vdf'
        if (-not (Test-Path $vdf)) { continue }
        foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
            $lib = ($m.Groups[1].Value -replace '\\\\', '\') + '\steamapps'
            Get-ChildItem $lib -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue | ForEach-Object {
                $acf = Get-Content $_.FullName -Raw -Encoding UTF8
                $name = [regex]::Match($acf, '"name"\s+"([^"]+)"').Groups[1].Value
                $dir = [regex]::Match($acf, '"installdir"\s+"([^"]+)"').Groups[1].Value
                if ($name -match '^(Steamworks Common Redistributables|Steam Linux Runtime|Proton|SteamVR|Steam Controller)') { return }
                if ($dir) { AddGame (Join-Path $lib "common\$dir") $name 'Steam' }
            }
        }
    }
    Get-ChildItem "$env:ProgramData\Epic\EpicGamesLauncher\Data\Manifests" -Filter *.item -ErrorAction SilentlyContinue | ForEach-Object {
        try { $j = Get-Content $_.FullName -Raw | ConvertFrom-Json; AddGame $j.InstallLocation $j.DisplayName 'Epic' } catch {}
    }
    Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games' -ErrorAction SilentlyContinue | ForEach-Object { $p = Get-ItemProperty $_.PSPath; AddGame $p.path $p.gameName 'GOG' }
    Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher\Installs' -ErrorAction SilentlyContinue | ForEach-Object { AddGame (Get-ItemProperty $_.PSPath).InstallDir $null 'Ubisoft' }
    Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\EA Games', 'HKLM:\SOFTWARE\EA Games' -ErrorAction SilentlyContinue | ForEach-Object { AddGame (Get-ItemProperty $_.PSPath).'Install Dir' $_.PSChildName 'EA' }
    Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\Rockstar Games' -ErrorAction SilentlyContinue | ForEach-Object { AddGame (Get-ItemProperty $_.PSPath).InstallFolder $_.PSChildName 'Rockstar' }

    # Giochi registrati in "Programmi installati" dai principali editori.
    $publishers = [ordered]@{ 'Blizzard' = 'Battle.net'; 'Ubisoft' = 'Ubisoft'; 'Electronic Arts' = 'EA'; 'Rockstar' = 'Rockstar'; 'Grinding Gear' = 'Grinding Gear' }
    Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.InstallLocation -and $_.Publisher } | ForEach-Object {
            foreach ($k in $publishers.Keys) { if ($_.Publisher -match $k) { AddGame $_.InstallLocation $_.DisplayName $publishers[$k]; break } }
        }

    # Cartelle di giochi: ogni sottocartella e' un gioco.
    $typical = 'Games', 'Giochi', 'Juegos', 'SteamLibrary\steamapps\common', 'Epic Games', 'GOG Games', 'XboxGames', 'EA Games',
        'Program Files\EA Games', 'Program Files (x86)\Origin Games', 'Program Files (x86)\Ubisoft\Ubisoft Game Launcher\games',
        'Program Files\Rockstar Games', 'Program Files (x86)\GOG Galaxy\Games', 'Program Files\Epic Games'
    $folders = @(foreach ($d in Get-PSDrive -PSProvider FileSystem) { foreach ($sub in $typical) { Join-Path $d.Root $sub } }) + @(Get-ExtraFolders)
    foreach ($f in $folders) {
        if (-not (Test-Path $f)) { continue }
        Get-ChildItem $f -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^(GameSave|\.|Launcher$|DirectX|_CommonRedist)' } |
            ForEach-Object { AddGame $_.FullName $null (Get-GameSource $_.FullName) }
    }
    return $games
}

# File che rivelano le tecnologie di upscaling presenti in un gioco.
$FsrPattern = '^(ffx_fsr|amd_fidelityfx|ffx_backend|ffx_frameinterpolation|FidelityFX)'
$XessPattern = '^libxess'

function Test-AntiCheat([string]$gameDir) {
    $markers = 'EasyAntiCheat', 'BattlEye', 'EAAntiCheat', 'start_protected_game.exe', 'BEService*.exe', 'EasyAntiCheat_EOS*', 'nProtect', 'XignCode', 'GameGuard', 'mhyprot*'
    foreach ($m in $markers) {
        if (Get-ChildItem $gameDir -Recurse -Depth 2 -Filter $m -ErrorAction SilentlyContinue | Select-Object -First 1) { return $m }
    }
    return $null
}

# La cartella del gioco: se il file sta dentro la cartella di un gioco noto (Epic, GOG,
# Ubisoft...) e' quella; altrimenti la prima sotto la libreria piu' specifica che lo
# contiene (es. ...\steamapps\common\<Gioco>, non C:\Program Files (x86)\Steam).
function Get-GameRoot([string]$path, [string[]]$roots, [string[]]$gameDirs = @()) {
    $game = $gameDirs | Where-Object { $path.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object Length -Descending | Select-Object -First 1
    $best = $roots | Where-Object { $path.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object Length -Descending | Select-Object -First 1
    if ($game -and (-not $best -or $game.Length -gt $best.Length)) { return $game }
    if (-not $best) { return Split-Path $path -Parent }
    $parts = $path.Substring($best.Length + 1) -split '\\'
    $root = Join-Path $best $parts[0]
    # Cartelle dell'editore (es. "Grinding Gear Games\Path of Exile"): scendiamo di un livello.
    $technical = 'Content', 'Bin', 'Binaries', 'Game', 'Streamline', 'x64', 'Win64', 'Engine'
    if ($parts.Count -gt 2 -and $technical -notcontains $parts[1] -and
        -not (Get-ChildItem $root -Filter *.exe -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        $root = Join-Path $root $parts[1]
    }
    return $root
}

# Le copie "Development"/"Debug" dei giochi Unreal servono solo agli sviluppatori.
$SkipDirs = '\\(Windows|NVIDIA Corporation|Common Files|WindowsApps|DLSS Updater|Development|Debug|DebugGame)\\'

function New-GameEntry([string]$dir, [string]$name, [string]$src) {
    [pscustomobject]@{
        Nome = $name; Fonte = $src; Cartella = $dir; Dll = $null; Versione = [version]'0.0'
        Fsr = $false; Xess = $false; AntiCheat = $null; Exes = @(); Forzato = $false; Opti = $false
    }
}

function Find-Games {
    $installed = Get-InstalledGames
    $byDir = @{}
    $games = New-Object System.Collections.Generic.List[object]

    # 1) Ogni gioco installato: una sola passata per trovare DLSS, FSR e XeSS.
    foreach ($dir in $installed.Keys) {
        if ($script:onScan) { & $script:onScan $installed[$dir].Nome }
        $g = New-GameEntry $dir $installed[$dir].Nome $installed[$dir].Fonte
        $dlls = @(Get-ChildItem $dir -Recurse -Depth $DeepScan -Filter *.dll -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch $SkipDirs })
        $dlss = $dlls | Where-Object { $_.Name -eq $DllName } | Sort-Object { $_.FullName.Length } | Select-Object -First 1
        if ($dlss) { $g.Dll = $dlss.FullName; $g.Versione = ConvertTo-DlssVersion $dlss.VersionInfo.FileVersion }
        $g.Fsr = [bool]($dlls | Where-Object { $_.Name -match $FsrPattern } | Select-Object -First 1)
        $g.Xess = [bool]($dlls | Where-Object { $_.Name -match $XessPattern } | Select-Object -First 1)
        $games.Add($g); $byDir[$dir] = $g
    }

    # 2) Riserva: giochi con DLSS nei Program Files che nessun launcher elenca.
    $roots = @(foreach ($d in Get-PSDrive -PSProvider FileSystem) { foreach ($sub in 'Program Files (x86)', 'Program Files') { $p = Join-Path $d.Root $sub; if (Test-Path $p) { $p } } })
    $known = [string[]]@($installed.Keys)
    foreach ($r in $roots) {
        if ($script:onScan) { & $script:onScan $r }
        Get-ChildItem $r -Recurse -Depth $ShallowScan -Filter $DllName -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch $SkipDirs } | ForEach-Object {
            $path = $_.FullName
            if ($known | Where-Object { $path.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) }) { return }
            $root = Get-GameRoot $path ([string[]]$roots)
            if ($byDir.ContainsKey($root)) { return }
            $g = New-GameEntry $root (Split-Path $root -Leaf) (Get-GameSource $root)
            $g.Dll = $path; $g.Versione = ConvertTo-DlssVersion $_.VersionInfo.FileVersion
            $games.Add($g); $byDir[$root] = $g
        }
    }

    $opti = Get-OptiIndex
    foreach ($g in $games) {
        $g.AntiCheat = Test-AntiCheat $g.Cartella
        $g.Exes = Get-GameExes $g
        if ($g.Dll) { $g.Forzato = Test-Forced $g }
        $g.Opti = $opti.ContainsKey($g.Cartella)
    }
    # Prima i giochi con DLSS, poi gli altri, ognuno in ordine alfabetico.
    return $games | Sort-Object @{ Expression = { -not $_.Dll } }, Nome
}

# --- DLSS ufficiale NVIDIA ---
function Get-LatestDlss {
    $rel = Invoke-RestMethod 'https://api.github.com/repos/NVIDIA/DLSS/releases/latest' -UseBasicParsing -TimeoutSec 20
    $tag = $rel.tag_name
    $dest = Join-Path $CacheDir "$tag\$DllName"
    if (-not (Test-Path $dest)) {
        New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
        # GitHub indica l'indirizzo esatto del file per quella versione.
        $url = (Invoke-RestMethod "https://api.github.com/repos/NVIDIA/DLSS/contents/lib/Windows_x86_64/rel/$($DllName)?ref=$tag" -UseBasicParsing -TimeoutSec 20).download_url
        Invoke-WebRequest $url -OutFile "$dest.tmp" -UseBasicParsing -TimeoutSec 300
        $sig = Get-AuthenticodeSignature "$dest.tmp"
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'NVIDIA Corporation') {
            Remove-Item "$dest.tmp" -Force
            throw "Il file scaricato non ha una firma NVIDIA valida ($($sig.Status)): annullato."
        }
        Move-Item "$dest.tmp" $dest -Force
        Write-Log "Scaricato DLSS $tag da $url (firma NVIDIA valida)"
    }
    return [pscustomobject]@{ Tag = $tag; Path = $dest; Versione = ConvertTo-DlssVersion (Get-Item $dest).VersionInfo.FileVersion }
}

function Test-GameRunning($game) {
    return [bool](Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($game.Cartella + '\', [StringComparison]::OrdinalIgnoreCase) })
}

function Update-Game($game, $latest) {
    if ($game.AntiCheat) { throw "$($game.Nome) usa un anti-cheat ($($game.AntiCheat)): aggiornamento bloccato per evitare il rischio di ban." }
    if (-not (Get-RtxGpu)) { throw "Questo PC non ha una scheda NVIDIA RTX: il DLSS non funzionerebbe." }
    if ($game.Fonte -eq 'Xbox') { throw "$($game.Nome) e' un gioco dell'app Xbox: i suoi file sono protetti da Windows." }
    if (Test-GameRunning $game) { throw "$($game.Nome) e' aperto: chiudilo prima di aggiornare." }
    $idx = Get-BackupIndex
    if (-not $idx.ContainsKey($game.Dll)) {
        $bk = Join-Path $BackupDir ("{0}_{1}.dll" -f ($game.Nome -replace '[^\w\-]', '_'), [guid]::NewGuid().ToString('N').Substring(0, 8))
        Copy-Item $game.Dll $bk -Force
        $idx[$game.Dll] = [pscustomobject]@{ Backup = $bk; VersioneOriginale = "$($game.Versione)"; Data = (Get-Date -Format 'yyyy-MM-dd HH:mm') }
        Save-BackupIndex $idx
        Write-Log "Backup di $($game.Dll) (v$($game.Versione)) in $bk"
    }
    Copy-Item $latest.Path $game.Dll -Force
    Write-Log "Aggiornato $($game.Nome): $($game.Versione) -> $($latest.Versione) ($($game.Dll))"
}

# --- Override DLSS nel profilo del driver ("Forza DLSS") ---
$ForceIndex = Join-Path $BackupDir 'forzature.json'
function Get-ForceIndex {
    $h = @{}
    if (Test-Path $ForceIndex) { (Get-Content $ForceIndex -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value } }
    return $h
}
function Save-ForceIndex($h) { $h | ConvertTo-Json -Depth 4 | Set-Content $ForceIndex -Encoding UTF8 }

# Eseguibili del gioco per il profilo del driver (senza crash report, installer, launcher...).
function Get-GameExes($game) {
    $skip = 'CrashReport|Prereq|redist|UnityCrashHandler|dotnet|EpicWebHelper|CEFSubProcess|QtWebEngine|BsSndRpt|unins|PackCheck|setup|updater|BlizzardError|Battle\.net|Launcher|helper|Report|Cpp2IL|MonoMod|BepInEx|Il2Cpp'
    $key = (Split-Path $game.Cartella -Leaf) -replace '[^A-Za-z0-9]', ''
    # Prima gli eseguibili "veri" (Shipping di Unreal, col nome del gioco), poi i piu' grandi.
    @(Get-ChildItem $game.Cartella -Recurse -Depth 5 -Filter *.exe -File -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -notmatch $skip -and $_.FullName -notmatch $SkipDirs } |
        Sort-Object @{ Expression = { $_.Name -notmatch 'Shipping' } }, @{ Expression = { ($_.BaseName -replace '[^A-Za-z0-9]', '') -notlike "*$key*" } }, @{ Expression = { $_.Length }; Descending = $true } |
        ForEach-Object Name | Select-Object -Unique -First 8)
}
function Get-ProfileName($game) { "DLSS Updater - $($game.Nome)" }

# Da forzare: serve l'override nel driver, oppure il file e' vecchio (e si puo' toccare).
function Test-NeedsForce($game) {
    if (-not $script:gpu -or $game.Fonte -eq 'Xbox' -or -not $game.Dll) { return $false }
    return -not ($game.Forzato -and ($game.AntiCheat -or $game.Versione -ge $script:latest.Versione))
}

function Test-Forced($game) {
    if (-not $script:gpu -or -not $game.Exes) { return $false }
    try {
        $prof = $null
        $v = [NvDrs]::ReadApp([string[]]$game.Exes, (Get-ProfileName $game), [uint32[]]@($NvOverride.Values), [ref]$prof)
        return ($v[0] -eq 1 -and $v[1] -eq $NvLatestPreset)
    } catch { return $false }
}

function Save-NvBackup([string]$prefix) {
    New-Item -ItemType Directory -Force $NvBackupDir | Out-Null
    $f = Join-Path $NvBackupDir "$($prefix)_$(Get-Date -Format 'yyyyMMdd_HHmmss').nvdrs"
    [NvDrs]::Export($f)
    # Teniamo il primo backup ("originale") e gli ultimi 15.
    Get-ChildItem $NvBackupDir -Filter "$prefix*.nvdrs" | Sort-Object LastWriteTime -Descending | Select-Object -Skip 15 | Remove-Item -Force
    return $f
}

function Enable-GameOverride($game, $latest) {
    if (-not (Get-RtxGpu)) { throw "Questo PC non ha una scheda NVIDIA RTX." }
    if ($game.Fonte -eq 'Xbox') { throw "$($game.Nome) e' un gioco dell'app Xbox: i suoi file sono protetti da Windows." }
    if (-not $game.Exes) { throw "Non trovo l'eseguibile di $($game.Nome)." }
    if (Test-GameRunning $game) { throw "$($game.Nome) e' aperto: chiudilo prima di aggiornare il DLSS." }
    # Il file si aggiorna solo se non c'e' anti-cheat; l'override del driver non tocca i file del gioco.
    if (-not $game.AntiCheat -and $game.Versione -lt $latest.Versione) { Update-Game $game $latest }
    $bk = Save-NvBackup 'prima_di_forzare'
    $created = $false
    $prof = [NvDrs]::WriteApp([string[]]$game.Exes, (Get-ProfileName $game), [uint32[]]@($NvOverride.Values), $NvOverrideValues, [ref]$created)
    $idx = Get-ForceIndex
    if (-not $idx.ContainsKey($game.Cartella)) {
        $idx[$game.Cartella] = [pscustomobject]@{ Profilo = $prof; Creato = $created; Exe = $game.Exes; Data = (Get-Date -Format 'yyyy-MM-dd HH:mm') }
        Save-ForceIndex $idx
    }
    Write-Log "Forzato DLSS (modello piu' recente) per $($game.Nome) nel profilo driver '$prof'$(if ($created) { ' (creato)' }); backup driver: $bk"
}

function Disable-GameOverride($game) {
    $idx = Get-ForceIndex
    $entry = $idx[$game.Cartella]
    $exes = if ($entry) { [string[]]@($entry.Exe) } else { [string[]]$game.Exes }
    $prof = if ($entry) { $entry.Profilo } else { Get-ProfileName $game }
    [void](Save-NvBackup 'prima_di_ripristinare')
    [NvDrs]::ClearApp($exes, $prof, [uint32[]]@($NvOverride.Values), [bool]($entry -and $entry.Creato))
    if ($entry) { $idx.Remove($game.Cartella); Save-ForceIndex $idx }
    Write-Log "Tolto l'override DLSS per $($game.Nome) (profilo '$prof')"
}

# --- OptiScaler (github.com/optiscaler/OptiScaler, GPL-3.0): DLSS nei giochi che hanno solo FSR/XeSS ---
$OptiIndex = Join-Path $BackupDir 'optiscaler.json'
$OptiCache = Join-Path $CacheDir 'optiscaler'
function Get-OptiIndex {
    $h = @{}
    if (Test-Path $OptiIndex) { (Get-Content $OptiIndex -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value } }
    return $h
}
function Save-OptiIndex($h) { $h | ConvertTo-Json -Depth 5 | Set-Content $OptiIndex -Encoding UTF8 }

# Ultima versione ufficiale da GitHub, scaricata ed estratta con tar (incluso in Windows).
function Get-LatestOpti {
    $rel = Invoke-RestMethod 'https://api.github.com/repos/optiscaler/OptiScaler/releases/latest' -UseBasicParsing -TimeoutSec 20
    $dir = Join-Path $OptiCache $rel.tag_name
    if (-not (Test-Path (Join-Path $dir 'OptiScaler.dll'))) {
        $asset = $rel.assets | Where-Object { $_.name -like '*.7z' } | Select-Object -First 1
        if (-not $asset) { throw "Nella release $($rel.tag_name) di OptiScaler non c'e' l'archivio .7z." }
        New-Item -ItemType Directory -Force $dir | Out-Null
        $arc = Join-Path $OptiCache $asset.name
        Invoke-WebRequest $asset.browser_download_url -OutFile $arc -UseBasicParsing -TimeoutSec 300
        & tar.exe -xf $arc -C $dir
        if (-not (Test-Path (Join-Path $dir 'OptiScaler.dll'))) { throw "Estrazione di OptiScaler non riuscita." }
        Write-Log "Scaricato OptiScaler $($rel.tag_name) da $($asset.browser_download_url) (SHA256 $((Get-FileHash $arc).Hash))"
    }
    return [pscustomobject]@{ Tag = $rel.tag_name; Path = $dir }
}

# Cartella dell'eseguibile vero del gioco (nei giochi Unreal: ...\Binaries\Win64, non la radice).
function Get-ExeDir($game) {
    $skip = 'CrashReport|Prereq|redist|UnityCrashHandler|dotnet|EpicWebHelper|CEFSubProcess|unins|PackCheck|setup|updater|Launcher|helper|Report'
    $exes = @(Get-ChildItem $game.Cartella -Recurse -Depth 5 -Filter *.exe -File -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -notmatch $skip -and $_.FullName -notmatch $SkipDirs })
    if (-not $exes) { return $game.Cartella }
    $ship = $exes | Where-Object { $_.Name -match '-Win64-Shipping\.exe$|-WinGDK-Shipping\.exe$' } | Select-Object -First 1
    if ($ship) { return $ship.DirectoryName }
    $named = Get-GameExe $game.Cartella
    if ($named) { return Split-Path $named -Parent }
    return ($exes | Sort-Object Length -Descending | Select-Object -First 1).DirectoryName
}

function Install-Opti($game) {
    if (-not (Get-RtxGpu)) { throw "OptiScaler con DLSS richiede una scheda NVIDIA RTX." }
    if ($game.AntiCheat) { throw "$($game.Nome) usa un anti-cheat ($($game.AntiCheat)): OptiScaler inietta codice nel gioco, rischio di ban. Bloccato." }
    if ($game.Fonte -eq 'Xbox') { throw "$($game.Nome) e' un gioco dell'app Xbox: i suoi file sono protetti." }
    if ((Get-OptiIndex).ContainsKey($game.Cartella)) { throw "OptiScaler e' gia' installato in $($game.Nome)." }
    if (Test-GameRunning $game) { throw "$($game.Nome) e' aperto: chiudilo prima di installare OptiScaler." }
    $opti = Get-LatestOpti
    $dst = Get-ExeDir $game
    # Nome del file "ponte": dxgi.dll come lo script ufficiale, oppure winmm/version se gia' presente.
    $proxy = 'dxgi.dll', 'winmm.dll', 'version.dll' | Where-Object { -not (Test-Path (Join-Path $dst $_)) } | Select-Object -First 1
    if (-not $proxy) { throw "In $dst ci sono gia' dxgi.dll, winmm.dll e version.dll (forse un'altra mod): installazione annullata." }
    $bkDir = Join-Path $BackupDir ("optiscaler\" + ($game.Nome -replace '[^\w\-]', '_') + '_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $added = @(); $backups = @()
    $files = Get-ChildItem $opti.Path -Recurse -File | Where-Object { $_.Name -notmatch '^(setup_windows\.bat|setup_linux\.sh|!! README.*)$' }
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($opti.Path.Length + 1)
        if ($rel -eq 'OptiScaler.dll') { $rel = $proxy }
        $target = Join-Path $dst $rel
        if (Test-Path $target) {
            $b = Join-Path $bkDir $rel
            New-Item -ItemType Directory -Force (Split-Path $b) | Out-Null
            Copy-Item $target $b -Force
            $backups += $rel
        } else { $added += $rel }
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        Copy-Item $f.FullName $target -Force
    }
    # Con una scheda NVIDIA facciamo usare il DLSS come upscaler.
    $ini = Join-Path $dst 'OptiScaler.ini'
    (Get-Content $ini) -replace '^(Dx11Upscaler|Dx12Upscaler|VulkanUpscaler)=.*$', '$1=dlss' | Set-Content $ini -Encoding ASCII
    $dlssTarget = Join-Path $dst $DllName
    if (-not (Test-Path $dlssTarget)) { Copy-Item $script:latest.Path $dlssTarget; $added += $DllName }
    $idx = Get-OptiIndex
    $idx[$game.Cartella] = [pscustomobject]@{ Cartella = $dst; Versione = $opti.Tag; Ponte = $proxy; Aggiunti = $added; Salvati = $backups; Backup = $bkDir; Data = (Get-Date -Format 'yyyy-MM-dd HH:mm') }
    Save-OptiIndex $idx
    Write-Log "OptiScaler $($opti.Tag) installato in $($game.Nome) ($dst) come $proxy; file aggiunti: $($added.Count), sovrascritti (salvati): $($backups.Count)"
}

function Uninstall-Opti($game) {
    $idx = Get-OptiIndex
    $e = $idx[$game.Cartella]
    if (-not $e) { return }
    foreach ($rel in @($e.Aggiunti)) { Remove-Item (Join-Path $e.Cartella $rel) -Force -ErrorAction SilentlyContinue }
    foreach ($rel in @($e.Salvati)) { Copy-Item (Join-Path $e.Backup $rel) (Join-Path $e.Cartella $rel) -Force }
    foreach ($sub in 'D3D12_Optiscaler', 'Licenses') {
        $p = Join-Path $e.Cartella $sub
        if ((Test-Path $p) -and -not (Get-ChildItem $p -Recurse -File)) { Remove-Item $p -Recurse -Force }
    }
    Remove-Item $e.Backup -Recurse -Force -ErrorAction SilentlyContinue
    $idx.Remove($game.Cartella); Save-OptiIndex $idx
    Write-Log "OptiScaler rimosso da $($game.Nome) ($($e.Cartella))"
}

function Restore-Game($game) {
    if (Test-GameRunning $game) { throw "$($game.Nome) e' aperto: chiudilo prima di ripristinare." }
    if ($game.Opti) { Uninstall-Opti $game }
    if ($game.Forzato -or (Get-ForceIndex).ContainsKey($game.Cartella)) { Disable-GameOverride $game }
    $idx = Get-BackupIndex
    if (-not $game.Dll -or -not $idx.ContainsKey($game.Dll)) { return }
    $entry = $idx[$game.Dll]
    Copy-Item $entry.Backup $game.Dll -Force
    Remove-Item $entry.Backup -Force
    $idx.Remove($game.Dll)
    Save-BackupIndex $idx
    Write-Log "Ripristinato $($game.Nome) alla versione originale $($entry.VersioneOriginale)"
}

# Il DLSS funziona solo sulle schede NVIDIA RTX: su GTX, AMD e Intel il file non verrebbe usato.
function Get-RtxGpu {
    return Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'NVIDIA' -and $_.Name -match '\bRTX\b' } | Select-Object -First 1 -ExpandProperty Name
}

function Format-Dlss([version]$v) { "{0}  -  {1}.{2}.{3}" -f (Get-DlssGeneration $v), $v.Major, $v.Minor, [Math]::Max($v.Build, 0) }

# --- Finestra in stile app NVIDIA ---
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

# Finestra massimizzata senza bordi: per le finestre dei processi indicati toglie i bordi e
# le allarga a tutto il monitor su cui si trovano. Non inietta nulla: usa solo le API delle finestre.
if (-not ('WinMax' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class WinMax
{
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetLong(IntPtr h, int i);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetLong(IntPtr h, int i, IntPtr v);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }

    const int GWL_STYLE = -16, GWL_EXSTYLE = -20;
    const long WS_CAPTION = 0x00C00000, WS_THICKFRAME = 0x00040000, WS_SYSMENU = 0x00080000, WS_MINIMIZEBOX = 0x00020000, WS_MAXIMIZEBOX = 0x00010000;
    const long WS_EX_DLGMODALFRAME = 0x1, WS_EX_WINDOWEDGE = 0x100, WS_EX_CLIENTEDGE = 0x200, WS_EX_STATICEDGE = 0x20000;
    const uint SWP_NOZORDER = 0x4, SWP_NOOWNERZORDER = 0x200, SWP_FRAMECHANGED = 0x20, SWP_SHOWWINDOW = 0x40;

    // Restituisce quante finestre ha sistemato in questo giro.
    public static int Apply(int[] pids)
    {
        HashSet<uint> set = new HashSet<uint>();
        foreach (int p in pids) set.Add((uint)p);
        List<IntPtr> wins = new List<IntPtr>();
        EnumWindows(delegate (IntPtr h, IntPtr l)
        {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (set.Contains(pid) && IsWindowVisible(h) && !IsIconic(h) && GetWindow(h, 4) == IntPtr.Zero) wins.Add(h);   // 4 = GW_OWNER
            return true;
        }, IntPtr.Zero);

        int done = 0;
        foreach (IntPtr h in wins)
        {
            RECT r; GetWindowRect(h, out r);
            if (r.R - r.L < 640 || r.B - r.T < 360) continue;   // finestrelle, splash, menu
            MONITORINFO mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
            if (!GetMonitorInfo(MonitorFromWindow(h, 2), ref mi)) continue;   // 2 = MONITOR_DEFAULTTONEAREST
            RECT m = mi.rcMonitor;
            long style = GetLong(h, GWL_STYLE).ToInt64();
            bool framed = (style & (WS_CAPTION | WS_THICKFRAME)) != 0;
            bool fits = r.L == m.L && r.T == m.T && r.R == m.R && r.B == m.B;
            if (!framed && fits) continue;
            SetLong(h, GWL_STYLE, new IntPtr(style & ~(WS_CAPTION | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX)));
            long ex = GetLong(h, GWL_EXSTYLE).ToInt64();
            SetLong(h, GWL_EXSTYLE, new IntPtr(ex & ~(WS_EX_DLGMODALFRAME | WS_EX_WINDOWEDGE | WS_EX_CLIENTEDGE | WS_EX_STATICEDGE)));
            SetWindowPos(h, IntPtr.Zero, m.L, m.T, m.R - m.L, m.B - m.T, SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED | SWP_SHOWWINDOW);
            done++;
        }
        return done;
    }
}
'@
}

# Icona dell'app: disegnata qui e salvata come .ico con immagini PNG (16-256 px).
function New-AppIcon([string]$file) {
    $green = [Drawing.Color]::FromArgb(118, 185, 0)
    $pngs = foreach ($size in 256, 48, 32, 16) {
        $bmp = New-Object Drawing.Bitmap($size, $size)
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
        $r = [int]($size * 0.22); $d = 2 * $r; $w = $size - 1
        $path = New-Object Drawing.Drawing2D.GraphicsPath
        $path.AddArc(0, 0, $d, $d, 180, 90); $path.AddArc($w - $d, 0, $d, $d, 270, 90)
        $path.AddArc($w - $d, $w - $d, $d, $d, 0, 90); $path.AddArc(0, $w - $d, $d, $d, 90, 90); $path.CloseFigure()
        $g.FillPath((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(20, 20, 20))), $path)
        $g.DrawPath((New-Object Drawing.Pen($green, [Math]::Max(1, $size / 24))), $path)
        $text = if ($size -ge 48) { 'DLSS' } else { 'D' }
        $font = New-Object Drawing.Font('Segoe UI Black', [float]($(if ($size -ge 48) { $size * 0.25 } else { $size * 0.62 })), [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
        $fmt = New-Object Drawing.StringFormat -Property @{ Alignment = 'Center'; LineAlignment = 'Center' }
        $g.DrawString($text, $font, (New-Object Drawing.SolidBrush($green)), (New-Object Drawing.RectangleF(0, 0, $size, $size * $(if ($size -ge 48) { 0.86 } else { 1 }))), $fmt)
        if ($size -ge 48) {
            # Freccia verso l'alto sotto la scritta: "aggiornamento".
            $cx = $size / 2; $top = $size * 0.66; $h = $size * 0.16
            $arrow = [Drawing.PointF[]]@((New-Object Drawing.PointF($cx, $top)), (New-Object Drawing.PointF(($cx + $h), ($top + $h))), (New-Object Drawing.PointF(($cx - $h), ($top + $h))))
            $g.FillPolygon((New-Object Drawing.SolidBrush([Drawing.Color]::White)), $arrow)
        }
        $g.Dispose()
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        , @($size, $ms.ToArray())
    }
    $out = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter($out)
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$pngs.Count)
    $offset = 6 + 16 * $pngs.Count
    foreach ($p in $pngs) {
        $dim = if ($p[0] -ge 256) { 0 } else { $p[0] }
        $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$p[1].Length); $bw.Write([uint32]$offset)
        $offset += $p[1].Length
    }
    foreach ($p in $pngs) { $bw.Write($p[1]) }
    [IO.File]::WriteAllBytes($file, $out.ToArray())
}
if (-not (Test-Path $IconFile)) { try { New-AppIcon $IconFile } catch { Write-Log "Icona non creata: $($_.Exception.Message)" } }

# L'eseguibile del gioco: quello col nome piu' simile alla cartella, scartando i
# programmi di servizio (controllo file, disinstallazione, crash report...).
function Get-GameExe([string]$gameDir) {
    $helper = 'PackCheck|unins|uninstall|crash|report|setup|redist|dxsetup|updater|BlizzardError|helper|UnityCrash'
    $exes = @(Get-ChildItem $gameDir -Filter *.exe -File -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -notmatch $helper })
    if (-not $exes) { return $null }
    $key = (Split-Path $gameDir -Leaf) -replace '[^A-Za-z0-9]', ''
    $named = $exes | Where-Object { ($_.BaseName -replace '[^A-Za-z0-9]', '') -like "*$key*" } | Sort-Object Length -Descending | Select-Object -First 1
    if ($named) { return $named.FullName }
    return ($exes | Sort-Object Length -Descending | Select-Object -First 1).FullName
}

# Logo dell'app Xbox, preso dal pacchetto installato (Microsoft.GamingApp).
function Get-XboxLogo {
    $pkg = Get-AppxPackage -Name Microsoft.GamingApp -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pkg) { return $null }
    try {
        $logo = ([xml](Get-Content (Join-Path $pkg.InstallLocation 'AppxManifest.xml'))).Package.Properties.Logo
        $dir = Join-Path $pkg.InstallLocation ([IO.Path]::GetDirectoryName($logo))
        $file = Get-ChildItem $dir -Filter "$([IO.Path]::GetFileNameWithoutExtension($logo))*.png" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch 'contrast' } | Sort-Object Length -Descending | Select-Object -First 1
        if (-not $file) { return $null }
        # Copia in memoria, cosi' il file dell'app non resta bloccato.
        $ms = New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($file.FullName))
        return New-Object Drawing.Bitmap([Drawing.Image]::FromStream($ms))
    } catch { return $null }
}

# Simbolo di ogni servizio, preso dal suo programma se e' installato su questo PC.
$script:serviceIcons = @{}
function Get-ServiceIcon([string]$fonte, [string]$gameDir) {
    $key = if ($fonte -in 'Grinding Gear', 'Altro') { $gameDir } else { $fonte }
    if ($script:serviceIcons.ContainsKey($key)) { return $script:serviceIcons[$key] }
    $pf86 = ${env:ProgramFiles(x86)}
    $candidates = switch ($fonte) {
        'Steam' { (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamExe, "$pf86\Steam\steam.exe" }
        'Battle.net' { "$pf86\Battle.net\Battle.net.exe", "$pf86\Battle.net\Battle.net Launcher.exe" }
        'Epic' { "$pf86\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe", "$pf86\Epic Games\Launcher\Portal\Binaries\Win32\EpicGamesLauncher.exe" }
        'GOG' { "$pf86\GOG Galaxy\GalaxyClient.exe" }
        'Ubisoft' { "$pf86\Ubisoft\Ubisoft Game Launcher\UbisoftConnect.exe", "$pf86\Ubisoft\Ubisoft Game Launcher\upc.exe" }
        'EA' { "$env:ProgramFiles\Electronic Arts\EA Desktop\EA Desktop\EADesktop.exe", "$pf86\Origin\Origin.exe" }
        'Rockstar' { "$env:ProgramFiles\Rockstar Games\Launcher\Launcher.exe" }
        { $_ -in 'Grinding Gear', 'Altro' } { Get-GameExe $gameDir }
    }
    $img = $null
    if ($fonte -eq 'Xbox') { $img = Get-XboxLogo }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { try { $img = [Drawing.Icon]::ExtractAssociatedIcon(($c -replace '/', '\')).ToBitmap(); break } catch {} }
    }
    $script:serviceIcons[$key] = $img
    return $img
}

$C = @{
    Bg      = [Drawing.Color]::FromArgb(26, 26, 26)
    Header  = [Drawing.Color]::FromArgb(14, 14, 14)
    Card    = [Drawing.Color]::FromArgb(38, 38, 38)
    CardHi  = [Drawing.Color]::FromArgb(46, 46, 46)
    Text    = [Drawing.Color]::FromArgb(235, 235, 235)
    Sub     = [Drawing.Color]::FromArgb(150, 150, 150)
    Green   = [Drawing.Color]::FromArgb(118, 185, 0)
    Orange  = [Drawing.Color]::FromArgb(245, 166, 35)
    Red     = [Drawing.Color]::FromArgb(229, 72, 77)
    Btn     = [Drawing.Color]::FromArgb(58, 58, 58)
}
function New-Font([float]$size, [string]$style = 'Regular', [string]$face = 'Segoe UI') { New-Object Drawing.Font($face, $size, [Drawing.FontStyle]$style) }

function New-Label([string]$text, $font, $color, [int]$x, [int]$y) {
    New-Object Windows.Forms.Label -Property @{ Text = $text; Font = $font; ForeColor = $color; Location = "$x,$y"; AutoSize = $true; BackColor = 'Transparent' }
}

function New-FlatButton([string]$text, $back, $fore, [int]$w) {
    $b = New-Object Windows.Forms.Button -Property @{
        Text = $text; Width = $w; Height = 34; FlatStyle = 'Flat'; BackColor = $back; ForeColor = $fore
        Font = New-Font 9 'Bold'; Cursor = 'Hand'
    }
    $b.FlatAppearance.BorderSize = 0
    $b.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb([Math]::Min($back.R + 25, 255), [Math]::Min($back.G + 25, 255), [Math]::Min($back.B + 25, 255))
    return $b
}

$form = New-Object Windows.Forms.Form -Property @{
    Text = "DLSS Updater  -  by $Author"; Size = '1320,700'; MinimumSize = '1100,440'; StartPosition = 'CenterScreen'
    BackColor = $C.Bg; ForeColor = $C.Text; Font = New-Font 10
}
if (Test-Path $IconFile) { $form.Icon = New-Object Drawing.Icon($IconFile) }
$script:tips = New-Object Windows.Forms.ToolTip

# Piede con l'autore
$footer = New-Object Windows.Forms.Label -Property @{
    Dock = 'Bottom'; Height = 28; Padding = '22,6,0,0'; BackColor = $C.Header; ForeColor = $C.Sub; Font = New-Font 8.5
    Text = "Creato da $Author   |   (c) 2026 $Author - Tutti i diritti riservati. Vietata la copia e la distribuzione senza autorizzazione."
}

# Intestazione
$header = New-Object Windows.Forms.Panel -Property @{ Dock = 'Top'; Height = 76; BackColor = $C.Header }
$header.Controls.Add((New-Label 'DLSS' (New-Font 20 'Bold' 'Segoe UI Black') $C.Green 22 18))
$header.Controls.Add((New-Label 'UPDATER' (New-Font 20 'Regular' 'Segoe UI Light') $C.Text 102 18))
$lblLatest = New-Label 'Controllo ultima versione NVIDIA...' (New-Font 9) $C.Sub 290 14
$header.Controls.Add($lblLatest)
$lblGpuNote = New-Label '' (New-Font 8.5 'Bold') $C.Orange 290 52
$header.Controls.Add($lblGpuNote)
$btnAll = New-FlatButton 'APPLICA DLSS A TUTTI' $C.Green ([Drawing.Color]::Black) 200
$btnRefresh = New-FlatButton 'RICARICA' $C.Btn $C.Text 110
$btnLog = New-FlatButton 'REGISTRO' $C.Btn $C.Text 110
$btnNv = New-FlatButton 'IMPOSTAZIONI NVIDIA' $C.Btn $C.Green 180
$header.Controls.AddRange(@($btnAll, $btnRefresh, $btnLog, $btnNv))
$header.Add_Resize({
    $btnLog.Location = "$($header.Width - 130),21"
    $btnRefresh.Location = "$($header.Width - 250),21"
    $btnNv.Location = "$($header.Width - 440),21"
    $btnAll.Location = "$($header.Width - 650),21"
})
$accent = New-Object Windows.Forms.Panel -Property @{ Dock = 'Top'; Height = 2; BackColor = $C.Green }

# Riga di stato, con il link per aggiungere cartelle di giochi a mano
$statusBar = New-Object Windows.Forms.Panel -Property @{ Dock = 'Top'; Height = 34; BackColor = $C.Bg }
$status = New-Object Windows.Forms.Label -Property @{
    Dock = 'Fill'; Padding = '22,9,0,0'; ForeColor = $C.Sub; Font = New-Font 9.5; AutoEllipsis = $true
    Text = 'Ricerca dei giochi in corso...'
}
$lnkAdd = New-Object Windows.Forms.LinkLabel -Property @{
    Dock = 'Right'; Width = 250; Padding = '0,9,22,0'; TextAlign = 'TopRight'; Font = New-Font 9.5 'Bold'
    Text = '+ Aggiungi cartella giochi'; LinkColor = $C.Green; ActiveLinkColor = $C.Text; LinkBehavior = 'HoverUnderline'
}
$script:tips.SetToolTip($lnkAdd, 'Se un gioco non compare, indica la cartella dove sono installati i tuoi giochi: verra'' cercata anche in futuro.')
$statusBar.Controls.AddRange(@($status, $lnkAdd))

# Elenco dei giochi
$list = New-Object Windows.Forms.FlowLayoutPanel -Property @{
    Dock = 'Fill'; AutoScroll = $true; FlowDirection = 'TopDown'; WrapContents = $false; Padding = '18,6,18,18'; BackColor = $C.Bg
}
$list.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($list, $true, $null)

$form.Controls.AddRange(@($list, $statusBar, $accent, $header, $footer))

function Set-Status([string]$text, $color) { $status.Text = $text; $status.ForeColor = $color }

function Get-UpscalerText($g) {
    $t = @(); if ($g.Fsr) { $t += 'FSR' }; if ($g.Xess) { $t += 'XeSS' }
    if ($t) { $t -join ' + ' } else { 'non trovato' }
}

function New-GameCard($g, $idx) {
    $hasBackup = $g.Dll -and $idx.ContainsKey($g.Dll)
    $fileOk = $g.AntiCheat -or $g.Versione -ge $script:latest.Versione   # con anti-cheat il file non si tocca
    $done = $g.Forzato -and $fileOk
    $isDlss = [bool]$g.Dll -and -not $g.Opti
    if ($g.Fonte -eq 'Xbox') { $state = 'PROTETTO  -  APP XBOX'; $stateColor = $C.Sub }
    elseif ($g.Opti) { $state = 'OPTISCALER ATTIVO  -  DLSS AL POSTO DI FSR/XESS'; $stateColor = $C.Green }
    elseif ($isDlss -and $done -and $g.AntiCheat) { $state = 'AGGIORNATO DAL DRIVER  -  ANTI-CHEAT, FILE INTATTO'; $stateColor = $C.Green }
    elseif ($isDlss -and $done) { $state = 'AGGIORNATO  -  DLSS PIU'' RECENTE'; $stateColor = $C.Green }
    elseif ($isDlss -and $g.AntiCheat) { $state = 'ANTI-CHEAT  -  SI AGGIORNA SOLO DAL DRIVER'; $stateColor = $C.Orange }
    elseif ($isDlss) { $state = 'DA AGGIORNARE'; $stateColor = $C.Orange }
    elseif ($g.AntiCheat) { $state = 'NESSUN DLSS  -  ANTI-CHEAT: OPTISCALER BLOCCATO'; $stateColor = $C.Red }
    elseif ($g.Fsr -or $g.Xess) { $state = 'NESSUN DLSS  -  SI PUO'' AGGIUNGERE CON OPTISCALER'; $stateColor = $C.Orange }
    else { $state = 'NESSUN UPSCALER TROVATO'; $stateColor = $C.Sub }

    $card = New-Object Windows.Forms.Panel -Property @{ Height = 96; BackColor = $C.Card; Margin = '0,0,0,10' }
    $bar = New-Object Windows.Forms.Panel -Property @{ Dock = 'Left'; Width = 4; BackColor = $stateColor }
    $card.Controls.Add($bar)

    $title = New-Label $g.Nome (New-Font 13 'Bold') $C.Text 22 12
    $title.Name = 'title'
    $card.Controls.Add($title)
    $icon = Get-ServiceIcon $g.Fonte $g.Cartella
    if ($icon) {
        $src = New-Object Windows.Forms.PictureBox -Property @{ Name = 'src'; Image = $icon; SizeMode = 'Zoom'; Size = '22,22'; BackColor = 'Transparent' }
    } else {
        $src = New-Object Windows.Forms.Label -Property @{
            Name = 'src'; Text = $g.Fonte.ToUpper(); Font = New-Font 7.5 'Bold'; ForeColor = $C.Sub; BackColor = $C.Btn
            AutoSize = $true; Padding = '6,2,6,2'
        }
    }
    $script:tips.SetToolTip($src, $g.Fonte)
    $card.Controls.Add($src)
    $path = New-Label $g.Cartella (New-Font 8.5) $C.Sub 22 62
    $path.Name = 'path'; $path.AutoSize = $false; $path.Height = 18; $path.AutoEllipsis = $true
    $card.Controls.Add($path)

    # Le colonne vengono posizionate da Set-CardLayout in base alla larghezza.
    if ($g.Opti) { $e = (Get-OptiIndex)[$g.Cartella]; $capOrig = 'OPTISCALER'; $origText = "$($e.Versione) ($($e.Ponte))" }
    elseif ($isDlss) { $capOrig = 'ORIGINALE SALVATO'; $origText = if ($hasBackup) { Format-Dlss ([version]$idx[$g.Dll].VersioneOriginale) } else { '-' } }
    else { $capOrig = 'UPSCALER DEL GIOCO'; $origText = Get-UpscalerText $g }
    $curText = if ($g.Dll) { Format-Dlss $g.Versione } else { 'Nessun DLSS' }
    $cols = @(
        @('capCur', 'DLSS ATTUALE', (New-Font 7.5 'Bold'), $C.Sub, 18),
        @('valCur', $curText, (New-Font 11 'Bold'), $(if ($g.Dll) { $C.Text } else { $C.Sub }), 36),
        @('state', $state, (New-Font 8 'Bold'), $stateColor, 66),
        @('capOrig', $capOrig, (New-Font 7.5 'Bold'), $C.Sub, 18),
        @('valOrig', $origText, (New-Font 11), $C.Text, 36)
    )
    foreach ($col in $cols) { $l = New-Label $col[1] $col[2] $col[3] 0 $col[4]; $l.Name = $col[0]; $card.Controls.Add($l) }

    # Pulsante centrale: AGGIORNA DLSS per i giochi con DLSS, OPTISCALER per gli altri.
    if ($isDlss) {
        $canMain = [bool]$script:gpu -and $g.Fonte -ne 'Xbox' -and -not $done
        $bUp = New-FlatButton 'AGGIORNA DLSS' $(if ($canMain) { $C.Green } else { $C.Btn }) $(if ($canMain) { [Drawing.Color]::Black } else { $C.Sub }) 120
        $script:tips.SetToolTip($bUp, "Aggiorna il file del DLSS (se non c'e' anti-cheat) e attiva nel driver l'override DLSS con il modello piu' recente, come l'app NVIDIA.")
        $bUp.Add_Click({ $g = $this.Tag; Invoke-Action { Enable-GameOverride $g $script:latest } "$($g.Nome): DLSS aggiornato al modello piu' recente ($(Format-Dlss $script:latest.Versione)). Vale dal prossimo avvio del gioco." })
    } else {
        # OptiScaler sostituisce l'FSR/XeSS del gioco: se non ce ne sono, non avrebbe niente da sostituire.
        $hasUpscaler = $g.Fsr -or $g.Xess
        $canMain = [bool]$script:gpu -and $g.Fonte -ne 'Xbox' -and -not $g.AntiCheat -and -not $g.Opti -and $hasUpscaler
        $bUp = New-FlatButton 'OPTISCALER' $(if ($canMain) { $C.Orange } else { $C.Btn }) $(if ($canMain) { [Drawing.Color]::Black } else { $C.Sub }) 120
        $script:tips.SetToolTip($bUp, $(if ($hasUpscaler) { "Installa OptiScaler (open source, GitHub) per usare il DLSS al posto di FSR/XeSS. Solo per giochi single player: inietta codice nel gioco." } else { "In questo gioco non ho trovato FSR o XeSS: OptiScaler non avrebbe niente da sostituire con il DLSS." }))
        $bUp.Add_Click({ $g = $this.Tag; if (Confirm-Opti $g) { Invoke-Action { Install-Opti $g } "$($g.Nome): OptiScaler installato. Nel gioco scegli FSR o XeSS: verra' usato il DLSS. Menu di OptiScaler: tasto Inserisci." } })
    }
    $bUp.Enabled = $canMain
    $bUp.Name = 'up'; $bUp.Tag = $g

    $canRestore = $hasBackup -or $g.Forzato -or $g.Opti
    $bRe = New-FlatButton 'RIPRISTINA' $C.Btn $(if ($canRestore) { $C.Text } else { $C.Sub }) 120
    $bRe.Enabled = $canRestore
    $bRe.Name = 're'; $bRe.Tag = $g
    $script:tips.SetToolTip($bRe, "Rimette il gioco com'era: toglie override del driver e OptiScaler, rimette i file originali.")
    $bRe.Add_Click({ $g = $this.Tag; Invoke-Action { Restore-Game $g } "$($g.Nome): ripristinato com'era." })

    $card.Controls.AddRange(@($bUp, $bRe))

    # I gestori usano $this (il controllo che ha generato l'evento) e Tag (il gioco),
    # cosi' restano nello scope dello script e vedono le sue funzioni.
    $card.Add_Resize({ Set-CardLayout $this })
    $card.Add_MouseEnter({ $this.BackColor = $C.CardHi })
    $card.Add_MouseLeave({ $this.BackColor = $C.Card })
    return $card
}

function Confirm-Opti($g) {
    $msg = "OptiScaler e' un progetto open source (github.com/optiscaler/OptiScaler) che fa usare il DLSS ai giochi che hanno solo FSR o XeSS.`n`n" +
        "ATTENZIONE: inietta codice nel gioco. Usalo SOLO in giochi single player / offline: nei giochi online rischi il ban dell'account.`n`n"
    $msg += "Ogni file sovrascritto viene salvato: con RIPRISTINA il gioco torna com'era.`n`nInstallare OptiScaler in $($g.Nome)?"
    return ([Windows.Forms.MessageBox]::Show($msg, 'OptiScaler', 'YesNo', 'Warning') -eq 'Yes')
}

function Set-CardLayout($card) {
    $t = $card.Controls['title']
    $card.Controls['src'].Location = "$($t.Right + 10),$($t.Top + 4)"
    $card.Controls['re'].Location = "$($card.Width - 140),31"
    $card.Controls['up'].Location = "$($card.Width - 270),31"
    $xOrig = $card.Width - 270 - 30 - 190
    $xCur = $xOrig - 200
    foreach ($n in 'capCur', 'valCur', 'state') { $card.Controls[$n].Left = $xCur }
    foreach ($n in 'capOrig', 'valOrig') { $card.Controls[$n].Left = $xOrig }
    $card.Controls['path'].Width = [Math]::Max($xCur - 40, 60)
}

function Resize-Cards { foreach ($cardCtl in $list.Controls) { $cardCtl.Width = $list.ClientSize.Width - 40; Set-CardLayout $cardCtl } }
$list.Add_Resize({ Resize-Cards })

function Update-GameList {
    $form.Cursor = 'WaitCursor'
    try {
        if (-not $script:latest) { $script:latest = Get-LatestDlss }
        $lblLatest.Text = "Ultimo NVIDIA:  $(Format-Dlss $script:latest.Versione)  (verificato)" + $(if ($script:gpu) { "`n$($script:gpu -replace '^NVIDIA\s+', '')" } else { '' })
        $lblLatest.ForeColor = $C.Text
        # Mostra la cartella in esame: la ricerca profonda puo' richiedere qualche secondo.
        $savedText = $status.Text; $savedColor = $status.ForeColor
        $script:onScan = { param($p) $status.ForeColor = $C.Sub; $status.Text = "Ricerca dei giochi in corso...   $p"; [Windows.Forms.Application]::DoEvents() }
        try { $script:games = @(Find-Games) } finally { $script:onScan = $null }
        if ($script:keepStatus) { Set-Status $savedText $savedColor }
        $idx = Get-BackupIndex
        $list.SuspendLayout()
        $list.Controls.Clear()
        foreach ($g in $script:games) { $list.Controls.Add((New-GameCard $g $idx)) }
        Resize-Cards
        $list.ResumeLayout()
        $todo = @($script:games | Where-Object { Test-NeedsForce $_ }).Count
        $btnAll.Enabled = [bool]$script:gpu -and $todo -gt 0
        $btnAll.BackColor = if ($btnAll.Enabled) { $C.Green } else { $C.Btn }
        $btnAll.ForeColor = if ($btnAll.Enabled) { [Drawing.Color]::Black } else { $C.Sub }
        if (-not $script:gpu) {
            Set-Status "Nessuna scheda NVIDIA RTX trovata: il DLSS funziona solo su RTX serie 20 o superiori. Aggiornamento disattivato." $C.Orange
        } elseif (-not $script:keepStatus) {
            $nDlss = @($script:games | Where-Object { $_.Dll }).Count
            Set-Status "$($script:games.Count) giochi trovati ($nDlss con DLSS)  -  $todo da aggiornare.  File originali e impostazioni del driver vengono sempre salvati: si ripristina con un clic." $C.Sub
        }
        $script:keepStatus = $false
    } catch {
        Set-Status "Errore: $($_.Exception.Message)" $C.Red
        Write-Log "Errore aggiornamento elenco: $($_.Exception.Message)"
    } finally { $form.Cursor = 'Default' }
}

function Invoke-Action([scriptblock]$action, [string]$okText) {
    try { & $action; Set-Status $okText $C.Green }
    catch { Set-Status $_.Exception.Message $C.Red }
    $script:keepStatus = $true
    Update-GameList
}

$btnAll.Add_Click({
    $done = @(); $fail = @()
    foreach ($g in $script:games | Where-Object { Test-NeedsForce $_ }) {
        try { Enable-GameOverride $g $script:latest; $done += $g.Nome } catch { $fail += "$($g.Nome) ($($_.Exception.Message))" }
    }
    $msg = if ($done) { "DLSS aggiornato al modello piu' recente: $($done -join ', '). Vale dal prossimo avvio dei giochi." } else { '' }
    if ($fail) { Set-Status "$msg  Non eseguiti: $($fail -join '; ')" $C.Orange } else { Set-Status $msg $C.Green }
    $script:keepStatus = $true
    Update-GameList
})
# --- Impostazioni globali NVIDIA ---
$VSYNC_APP = [uint32]0x60925292; $VSYNC_ON = [uint32]0x47814940; $VSYNC_OFF = [uint32]0x08416747

function Format-NvValue([string]$key, $v) {
    switch ($key) {
        'VSync' { if ($null -eq $v -or $v -eq $VSYNC_APP) { 'Decide il gioco' } elseif ($v -eq $VSYNC_ON) { 'Attiva' } elseif ($v -eq $VSYNC_OFF) { 'Disattiva' } else { 'Altro (0x{0:X})' -f $v } }
        'LowLatency' { if ($null -eq $v -or $v -eq 0) { 'Disattivata' } elseif ($v -eq 1) { 'Attiva' } else { "Disattivata ($v fotogrammi)" } }
        'GSync' { switch ($v) { $null { 'Predefinito' } 0 { 'Disattivato' } 1 { 'Solo schermo intero' } 2 { 'Schermo intero e finestra' } default { "Altro ($v)" } } }
        'MaxFps' { if ($null -eq $v -or $v -eq 0) { 'Nessun limite' } else { "$v FPS" } }
        'ShaderMB' { if ($null -eq $v) { 'Predefinita' } elseif ($v -eq [uint32]::MaxValue) { 'Illimitata' } else { '{0:N0} GB' -f ($v / 1024) } }
    }
}

# Consigli per schede RTX da gioco. Con G-SYNC: G-SYNC + V-Sync dal driver + limite FPS
# appena sotto la frequenza del monitor (configurazione consigliata da Blur Busters).
function Get-NvPlan($cur, [bool]$gsync, [int]$hz) {
    $cap = [Math]::Max($hz - 3, 30)
    $rows = @(
        [pscustomobject]@{ Key = 'LowLatency'; Nome = 'Modalita bassa latenza'; Target = [uint32]1; Ok = ($cur.LowLatency -eq 1)
            Perche = 'Riduce il ritardo tra mouse e schermo.' }
        [pscustomobject]@{ Key = 'ShaderMB'; Nome = 'Dimensione cache shader'; Target = [uint32]102400; Ok = ($cur.ShaderMB -ge 102400)
            Perche = 'Meno scatti quando un gioco carica effetti nuovi.' }
    )
    if ($gsync) {
        $rows += [pscustomobject]@{ Key = 'GSync'; Nome = 'G-SYNC'; Target = [uint32]2; Ok = ($cur.GSync -in 1, 2)
            Perche = 'Elimina strappi e scatti dell''immagine.' }
        $rows += [pscustomobject]@{ Key = 'VSync'; Nome = 'Sincronizzazione verticale'; Target = $VSYNC_ON; Ok = ($cur.VSync -eq $VSYNC_ON)
            Perche = 'Con G-SYNC evita gli strappi residui.' }
        $rows += [pscustomobject]@{ Key = 'MaxFps'; Nome = 'Frequenza fotogrammi max'; Target = [uint32]$cap; Ok = ($cur.MaxFps -ge 30 -and $cur.MaxFps -le $cap)
            Perche = "Tiene il gioco dentro i $hz Hz del monitor." }
    } else {
        $rows += [pscustomobject]@{ Key = 'VSync'; Nome = 'Sincronizzazione verticale'; Target = $VSYNC_APP; Ok = ($null -eq $cur.VSync -or $cur.VSync -eq $VSYNC_APP)
            Perche = 'Senza G-SYNC meglio lasciarla decidere al gioco.' }
    }
    return $rows
}

function Get-MonitorHz {
    $hz = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1 -ExpandProperty CurrentRefreshRate
    if (-not $hz) { $hz = 60 }
    return [int]$hz
}

function Show-NvidiaDialog {
    $dlg = New-Object Windows.Forms.Form -Property @{
        Text = "Impostazioni NVIDIA  -  by $Author"; Size = '940,640'; StartPosition = 'CenterParent'; FormBorderStyle = 'FixedDialog'
        MaximizeBox = $false; MinimizeBox = $false; BackColor = $C.Bg; ForeColor = $C.Text; Font = New-Font 10
    }
    if ($form.Icon) { $dlg.Icon = $form.Icon }
    $dlg.Add_HandleCreated({ $on = 1; [void][Win.Dwm]::DwmSetWindowAttribute($this.Handle, 20, [ref]$on, 4) })

    $hz = Get-MonitorHz
    $dlg.Controls.Add((New-Label 'Impostazioni globali del driver NVIDIA' (New-Font 15 'Bold') $C.Text 24 18))
    $dlg.Controls.Add((New-Label "$($script:gpu -replace '^NVIDIA\s+', '')   |   monitor a $hz Hz" (New-Font 9.5) $C.Sub 26 52))

    $chk = New-Object Windows.Forms.CheckBox -Property @{
        Text = 'Il mio monitor supporta G-SYNC o FreeSync (frequenza variabile)'; Location = '26,84'; AutoSize = $true
        ForeColor = $C.Text; Font = New-Font 9.5
    }
    $dlg.Controls.Add($chk)

    $table = New-Object Windows.Forms.Panel -Property @{ Location = '24,118'; Size = '880,270'; BackColor = $C.Bg }
    $dlg.Controls.Add($table)
    $note = New-Object Windows.Forms.Label -Property @{ Location = '26,396'; Size = '880,44'; ForeColor = $C.Sub; Font = New-Font 9 }
    $dlg.Controls.Add($note)

    $bApply = New-FlatButton 'APPLICA CONSIGLIATE' $C.Green ([Drawing.Color]::Black) 200
    $bRestore = New-FlatButton 'RIPRISTINA BACKUP' $C.Btn $C.Text 180
    $bClose = New-FlatButton 'CHIUDI' $C.Btn $C.Text 110
    $bApply.Location = '24,452'; $bRestore.Location = '236,452'; $bClose.Location = '794,452'
    $dlg.Controls.AddRange(@($bApply, $bRestore, $bClose))

    # Indicatore DLSS ufficiale NVIDIA: scritta nell'angolo del gioco con versione e preset in uso.
    $ngxKey = 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NGXCore'
    $chkInd = New-Object Windows.Forms.CheckBox -Property @{
        Text = 'Mostra indicatore DLSS nei giochi (per verificare il modello in uso)'; Location = '26,504'; AutoSize = $true
        ForeColor = $C.Sub; Font = New-Font 9
        Checked = ((Get-ItemProperty $ngxKey -ErrorAction SilentlyContinue).ShowDlssIndicator -eq 0x400)
    }
    $chkInd.Add_CheckedChanged({
        try {
            if (-not (Test-Path $ngxKey)) { New-Item $ngxKey -Force | Out-Null }
            Set-ItemProperty $ngxKey -Name ShowDlssIndicator -Value $(if ($chkInd.Checked) { 0x400 } else { 0 }) -Type DWord
            Write-Log "Indicatore DLSS: $(if ($chkInd.Checked) { 'attivato' } else { 'disattivato' })"
        } catch { [void][Windows.Forms.MessageBox]::Show("Errore: $($_.Exception.Message)", 'Indicatore DLSS') }
    })
    $script:tips.SetToolTip($chkInd, "Durante il gioco compare in un angolo una scritta NVIDIA con la versione del DLSS e il preset (modello) usato. Utile per controllare che il DLSS sia davvero aggiornato. Si toglie da qui.")
    $dlg.Controls.Add($chkInd)

    # Finestra massimizzata senza bordi per tutti i giochi (la gestisce il tool, non il driver).
    $chkMax = New-Object Windows.Forms.CheckBox -Property @{
        Text = 'Apri tutti i giochi in finestra massimizzata senza bordi (consigliato con piu'' monitor)'; Location = '26,532'; AutoSize = $true
        ForeColor = $C.Sub; Font = New-Font 9; Checked = (Get-Config).FinestraMax
    }
    $chkMax.Add_CheckedChanged({
        Set-FinestraMax $chkMax.Checked
        Write-Log "Finestra massimizzata per tutti i giochi: $(if ($chkMax.Checked) { 'attivata' } else { 'disattivata' })"
        if ($chkMax.Checked) {
            [void][Windows.Forms.MessageBox]::Show("Attivata. Nelle opzioni di ogni gioco scegli la modalita' 'Finestra': il DLSS Updater togliera' i bordi e allarghera' il gioco a tutto il monitor su cui si trova.`n`nIl programma deve restare aperto: se lo chiudi resta attivo vicino all'orologio (tasto destro > Esci per uscire).", 'Finestra massimizzata')
        }
    })
    $script:tips.SetToolTip($chkMax, "Non e' un'impostazione del driver NVIDIA (non esiste): la applica il DLSS Updater. Funziona con i giochi aperti in modalita' Finestra; con lo schermo intero esclusivo il gioco controlla lo schermo da solo.")
    $dlg.Controls.Add($chkMax)

    $render = {
        $cur = Get-NvGlobalSettings
        $plan = Get-NvPlan $cur $chk.Checked $hz
        $table.Controls.Clear()
        $x = 0, 330, 530, 730
        $hdr = 'IMPOSTAZIONE', 'ATTUALE', 'CONSIGLIATA', 'STATO'
        for ($i = 0; $i -lt 4; $i++) { $table.Controls.Add((New-Label $hdr[$i] (New-Font 8 'Bold') $C.Sub $x[$i] 0)) }
        $y = 26
        foreach ($r in $plan) {
            $row = New-Object Windows.Forms.Panel -Property @{ Location = "0,$y"; Size = '880,44'; BackColor = $C.Card }
            $row.Controls.Add((New-Object Windows.Forms.Panel -Property @{ Dock = 'Left'; Width = 4; BackColor = $(if ($r.Ok) { $C.Green } else { $C.Orange }) }))
            $row.Controls.Add((New-Label $r.Nome (New-Font 10 'Bold') $C.Text 14 4))
            $row.Controls.Add((New-Label $r.Perche (New-Font 8) $C.Sub 14 24))
            $row.Controls.Add((New-Label (Format-NvValue $r.Key $cur[$r.Key]) (New-Font 10) $C.Text $x[1] 12))
            $row.Controls.Add((New-Label (Format-NvValue $r.Key $r.Target) (New-Font 10) $C.Green $x[2] 12))
            $row.Controls.Add((New-Label $(if ($r.Ok) { 'OTTIMALE' } else { 'DA MIGLIORARE' }) (New-Font 8.5 'Bold') $(if ($r.Ok) { $C.Green } else { $C.Orange }) $x[3] 13))
            $table.Controls.Add($row)
            $y += 50
        }
        $todo = @($plan | Where-Object { -not $_.Ok })
        $bApply.Enabled = $todo.Count -gt 0
        $bApply.BackColor = if ($bApply.Enabled) { $C.Green } else { $C.Btn }
        $bApply.ForeColor = if ($bApply.Enabled) { [Drawing.Color]::Black } else { $C.Sub }
        $last = Get-ChildItem $NvBackupDir -Filter *.nvdrs -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $bRestore.Enabled = [bool]$last
        $bRestore.ForeColor = if ($last) { $C.Text } else { $C.Sub }
        $msg = if ($todo.Count) { "$($todo.Count) impostazioni si possono migliorare. " } else { 'Le impostazioni sono gia'' ottimali per la tua scheda. ' }
        $msg += 'Prima di ogni modifica viene salvata una copia completa delle impostazioni NVIDIA.'
        if ($last) { $msg += "`nUltimo backup: $($last.LastWriteTime.ToString('dd/MM/yyyy HH:mm'))" }
        if ($chk.Checked) { $msg += "   |   G-SYNC va attivato anche nell'app NVIDIA: Sistema > Schermo > G-SYNC." }
        $note.Text = $msg
    }

    $chk.Checked = ((Get-NvGlobalSettings).GSync -in 1, 2)
    $chk.Add_CheckedChanged({ & $render })

    $bApply.Add_Click({
        try {
            $cur = Get-NvGlobalSettings
            $todo = @(Get-NvPlan $cur $chk.Checked $hz | Where-Object { -not $_.Ok })
            New-Item -ItemType Directory -Force $NvBackupDir | Out-Null
            $bk = Join-Path $NvBackupDir "prima_di_applicare_$(Get-Date -Format 'yyyyMMdd_HHmmss').nvdrs"
            [NvDrs]::Export($bk)
            [NvDrs]::Write([uint32[]]@($todo | ForEach-Object { $NvIds[$_.Key] }), [uint32[]]@($todo | ForEach-Object { $_.Target }))
            Write-Log "NVIDIA: backup in $bk; applicate: $(($todo | ForEach-Object { "$($_.Nome) = $(Format-NvValue $_.Key $_.Target)" }) -join '; ')"
            [void][Windows.Forms.MessageBox]::Show("Impostazioni applicate. Valgono dai giochi aperti da adesso in poi.`n`nBackup salvato:`n$bk", 'Impostazioni NVIDIA')
        } catch {
            [void][Windows.Forms.MessageBox]::Show("Errore: $($_.Exception.Message)`nNessuna impostazione e' stata cambiata dopo l'errore.", 'Impostazioni NVIDIA')
            Write-Log "NVIDIA: errore applicando le impostazioni: $($_.Exception.Message)"
        }
        & $render
    })

    $bRestore.Add_Click({
        $last = Get-ChildItem $NvBackupDir -Filter *.nvdrs -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $last) { return }
        $ans = [Windows.Forms.MessageBox]::Show("Ripristinare le impostazioni NVIDIA del $($last.LastWriteTime.ToString('dd/MM/yyyy HH:mm'))?", 'Impostazioni NVIDIA', 'YesNo')
        if ($ans -ne 'Yes') { return }
        try {
            [NvDrs]::Import($last.FullName)
            Write-Log "NVIDIA: ripristinato il backup $($last.FullName)"
            # Il backup usato si archivia, cosi' il prossimo "Ripristina" torna ancora piu' indietro.
            Rename-Item $last.FullName ($last.Name + '.usato') -Force
            [void][Windows.Forms.MessageBox]::Show('Impostazioni NVIDIA ripristinate.', 'Impostazioni NVIDIA')
        } catch {
            [void][Windows.Forms.MessageBox]::Show("Errore: $($_.Exception.Message)", 'Impostazioni NVIDIA')
            Write-Log "NVIDIA: errore nel ripristino: $($_.Exception.Message)"
        }
        & $render
    })
    $bClose.Add_Click({ $dlg.Close() })

    & $render
    [void]$dlg.ShowDialog($form)
}

$btnNv.Add_Click({
    if (-not $script:gpu) { [void][Windows.Forms.MessageBox]::Show('Serve una scheda NVIDIA RTX.', 'Impostazioni NVIDIA'); return }
    try { Show-NvidiaDialog } catch { Set-Status "Impostazioni NVIDIA non disponibili: $($_.Exception.Message)" $C.Red }
})
$btnRefresh.Add_Click({ $script:latest = $null; Update-GameList })
$lnkAdd.Add_LinkClicked({
    $fb = New-Object Windows.Forms.FolderBrowserDialog -Property @{ Description = 'Scegli la cartella dove sono installati i tuoi giochi (verranno cercati anche nelle sottocartelle)'; ShowNewFolderButton = $false }
    if ($fb.ShowDialog($form) -ne 'OK') { return }
    Add-ExtraFolder $fb.SelectedPath
    Write-Log "Aggiunta cartella giochi: $($fb.SelectedPath)"
    $before = $script:games.Count
    Update-GameList
    Set-Status "Cartella aggiunta: $($fb.SelectedPath)  -  giochi con DLSS trovati: $($script:games.Count) (prima $before)." $C.Green
})
$btnLog.Add_Click({ if (Test-Path $LogFile) { Start-Process notepad.exe $LogFile } })

$script:games = @()
$script:latest = $null
$script:keepStatus = $false
$script:gpu = Get-RtxGpu

# Sulle RTX 20 e 30 i modelli Transformer (DLSS 4 e 4.5) costano piu' FPS che sulle 40/50.
$GpuNoteText = "Sulle RTX serie 20 e 30 il DLSS 4 / 4.5 da' un'immagine molto piu' nitida, ma e' piu' pesante da calcolare: in alcuni giochi puoi perdere qualche FPS rispetto al DLSS vecchio.`n`nNei giochi leggeri non si nota. Se un gioco pesante gira peggio, premi RIPRISTINA su quel gioco e torna come prima.`n`nLa Frame Generation (fotogrammi generati) esiste solo dalle RTX 40 in su: e' normale non vederla nei giochi."
$script:olderRtx = $script:gpu -match 'RTX\s*(20|30)\d{2}'
if ($script:olderRtx) {
    $lblGpuNote.Text = 'RTX serie 20/30: il DLSS nuovo puo'' costare qualche FPS  (passa qui per i dettagli)'
    $script:tips.SetToolTip($lblGpuNote, $GpuNoteText)
    $flag = Join-Path $Root 'avviso_rtx20-30_mostrato.txt'
    if (-not (Test-Path $flag)) {
        $form.Add_Shown({
            [void][Windows.Forms.MessageBox]::Show($GpuNoteText, "La tua scheda: $($script:gpu -replace '^NVIDIA\s+', '')")
            Set-Content $flag "Avviso mostrato il $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        })
    }
}

# Barra del titolo scura (Windows 10 2004+ / Windows 11).
Add-Type -Namespace Win -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);'
$form.Add_HandleCreated({ $on = 1; [void][Win.Dwm]::DwmSetWindowAttribute($this.Handle, 20, [ref]$on, 4) })

# --- Finestra massimizzata: controllo ogni 2 secondi dei giochi con l'interruttore attivo ---
$maxTimer = New-Object Windows.Forms.Timer -Property @{ Interval = 2000 }
$maxTimer.Add_Tick({
    if (-not (Get-Config).FinestraMax) { return }
    $dirs = @($script:games | ForEach-Object Cartella)
    if (-not $dirs) { return }
    $pids = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $p = $_.Path; $p -and ($dirs | Where-Object { $p.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) })
        } | ForEach-Object Id)
    if ($pids) { try { [void][WinMax]::Apply([int[]]$pids) } catch {} }
})
$maxTimer.Start()

# Icona vicino all'orologio: con giochi in "finestra massimizzata", chiudere nasconde invece di uscire.
$tray = New-Object Windows.Forms.NotifyIcon -Property @{ Text = 'DLSS Updater - by Sairiin'; Visible = $true }
$tray.Icon = if ($form.Icon) { $form.Icon } else { [Drawing.SystemIcons]::Application }
$trayMenu = New-Object Windows.Forms.ContextMenuStrip
[void]$trayMenu.Items.Add('Apri DLSS Updater', $null, { $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })
[void]$trayMenu.Items.Add('Esci', $null, { $script:exiting = $true; $form.Close() })
$tray.ContextMenuStrip = $trayMenu
$tray.Add_DoubleClick({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })
$script:exiting = $false
$form.Add_FormClosing({
    param($s, $e)
    if (-not $script:exiting -and (Get-Config).FinestraMax) {
        $e.Cancel = $true
        $form.Hide()
        $tray.ShowBalloonTip(4000, 'DLSS Updater resta attivo', 'Continua a gestire la finestra massimizzata dei giochi. Per uscire: tasto destro su questa icona > Esci.', 'Info')
        return
    }
    $maxTimer.Stop(); $tray.Visible = $false; $tray.Dispose()
})

$form.Add_Shown({ $form.Refresh(); Update-GameList })
[void]$form.ShowDialog()

