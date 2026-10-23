# ==============================================================
#  IRM OTIMIZADOR v1.0 - Manutencao & Performance Windows 10/11
#  Uso:  irm https://SEU-HOST/otimizar.ps1 | iex
#  Requer: PowerShell 5.1+ | Executar como Administrador
#  Tudo reversivel: backup em %USERPROFILE%\IRM-Backup
# ==============================================================

$IRM_URL = 'https://irm.abysm.com.br/otimizar.ps1'   # usado na auto-elevacao (irm | iex)
$AkerSetupUrl = 'https://irm.abysm.com.br/aker/setup.exe'   # <<< suba o instalador do Aker no bucket (pasta aker/)
$ScriptVersion = '1.1.0'

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$global:AutoYes = $false

$WinBuild = [int]((Get-CimInstance Win32_OperatingSystem).BuildNumber)
$IsWin11  = $WinBuild -ge 22000

$BackupDir    = Join-Path $env:USERPROFILE 'IRM-Backup'
$ManifestPath = Join-Path $BackupDir 'manifest.json'
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

# ---------- Restauracao de escopo / administrador ----------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$IsAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
    Write-Host ''
    Write-Host '  [!] Este otimizador precisa rodar como ADMINISTRADOR.' -ForegroundColor Yellow
    if ($IRM_URL -notmatch 'SEU-HOST') {
        try {
            $tmp = Join-Path $env:TEMP 'irm-otimizador.ps1'
            Invoke-WebRequest -Uri $IRM_URL -OutFile $tmp -UseBasicParsing
            Start-Process powershell.exe -Verb RunAs -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -File `"$tmp`"")
            Write-Host '  [i] Janela de Administrador aberta. Esta pode ser fechada.' -ForegroundColor Cyan
        } catch {
            Write-Host ("  [X] Falha na auto-elevacao: " + $_.Exception.Message) -ForegroundColor Red
            Write-Host '  [i] Abra o PowerShell como Administrador e rode novamente.' -ForegroundColor Cyan
        }
    } else {
        Write-Host '  [i] Abra o PowerShell como Administrador e rode novamente.' -ForegroundColor Cyan
    }
    return
}

# ---------- Helpers de saida ----------
function Info([string]$t) { Write-Host ("  " + $t) -ForegroundColor Gray }
function Ok([string]$t)   { Write-Host ("  [OK] " + $t) -ForegroundColor Green }
function Warn([string]$t) { Write-Host ("  [!] " + $t) -ForegroundColor Yellow }
function Err([string]$t)  { Write-Host ("  [X] " + $t) -ForegroundColor Red }
function Head([string]$t) { Write-Host ''; Write-Host ("=== " + $t + " ===") -ForegroundColor Cyan }

function Confirm-Action([string]$t) {
    if ($global:AutoYes) { Write-Host ("  [auto] " + $t) -ForegroundColor DarkGray; return $true }
    $r = Read-Host ("  " + $t + " [S/n]")
    return ($r -eq '' -or $r -match '^[sSyY]')
}
function Pause-Key { Write-Host ''; $null = Read-Host '  Pressione ENTER para continuar' }

function Get-SelectedIndexes([string]$sel, [int]$max) {
    $res = @()
    foreach ($tok in ($sel -split ',')) {
        $t = $tok.Trim()
        if ($t -match '^(\d+)\s*-\s*(\d+)$') {
            for ($i = [int]$Matches[1]; $i -le [int]$Matches[2]; $i++) { if ($i -ge 1 -and $i -le $max) { $res += $i } }
        } elseif ($t -match '^\d+$') {
            $i = [int]$t; if ($i -ge 1 -and $i -le $max) { $res += $i }
        }
    }
    return @($res | Sort-Object -Unique)
}

function Test-IsLaptop {
    try {
        $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
        if ($bat) { return $true }
        $enc = Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue
        if ($enc -and $enc.ChassisTypes) {
            foreach ($c in $enc.ChassisTypes) {
                if (@(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32) -contains $c) { return $true }
            }
        }
    } catch {}
    return $false
}

function Test-IsEntraJoined {
    try {
        $status = dsregcmd /status 2>$null
        foreach ($line in $status) {
            if ($line -match 'AzureAdJoined\s*:\s*YES') { return $true }
        }
    } catch {}
    return $false
}

function Invoke-BootCpuTweak {
    # msconfig -> Boot -> Opcoes avancadas: maximo de processadores.
    # Regra IRM: aplicar somente em maquinas NAO gerenciadas (Entra/AzureAD).
    if (Test-IsEntraJoined) {
        Info 'Maquina gerenciada pelo Entra/AzureAD - tweak de processadores do boot nao aplicado.'
        return
    }
    $threads = (Get-CimInstance Win32_Processor).NumberOfLogicalProcessors
    bcdedit /deletevalue '{current}' numproc 2>$null | Out-Null
    bcdedit /set '{current}' numproc $threads 2>&1 | Out-Null
    if (-not $Manifest.Flags.Contains('numproc')) { $Manifest.Flags.Add('numproc') }
    Save-Manifest
    Ok ("Boot: numproc = $threads (maximo de processadores, igual ao msconfig)")
    Info 'Nota honesta: no Windows 10/11 o SO ja usa todos os nucleos por padrao; o item do msconfig e diagnostico.'
    Info 'Reversivel em [9] RESTAURAR (remove o numproc) ou: bcdedit /deletevalue {current} numproc'
}

# ---------- Manifest / backup ----------
$Manifest = @{
    RegFiles = [System.Collections.Generic.List[string]]::new()
    Services = [System.Collections.Generic.List[object]]::new()
    Nagle    = [System.Collections.Generic.List[string]]::new()
    Appx     = [System.Collections.Generic.List[string]]::new()
    Tasks    = [System.Collections.Generic.List[string]]::new()
    Startup   = [System.Collections.Generic.List[string]]::new()
    Flags     = [System.Collections.Generic.List[string]]::new()
    PowerPlan = ''
}
if (Test-Path $ManifestPath) {
    try {
        $j = Get-Content $ManifestPath -Raw | ConvertFrom-Json
        foreach ($f in @($j.RegFiles)) { if ($f) { $Manifest.RegFiles.Add([string]$f) } }
        foreach ($s in @($j.Services)) { if ($s) { $Manifest.Services.Add($s) } }
        foreach ($n in @($j.Nagle))    { if ($n) { $Manifest.Nagle.Add([string]$n) } }
        foreach ($a in @($j.Appx))     { if ($a) { $Manifest.Appx.Add([string]$a) } }
        foreach ($tk in @($j.Tasks))   { if ($tk) { $Manifest.Tasks.Add([string]$tk) } }
        foreach ($st in @($j.Startup)) { if ($st) { $Manifest.Startup.Add([string]$st) } }
        foreach ($fl in @($j.Flags))   { if ($fl) { $Manifest.Flags.Add([string]$fl) } }
        if ($j.PowerPlan) { $Manifest.PowerPlan = [string]$j.PowerPlan }
    } catch {}
}

function New-RestoreScript {
    $restore = @'
# ============================================
#  RESTAURAR - IRM Otimizador
#  Execute como ADMINISTRADOR.
#  Reimporta registry, restaura servicos, plano de energia,
#  desfaz tweaks de rede e remove tarefas criadas.
# ============================================
$BackupDir    = '__BACKUPDIR__'
$ManifestPath = '__MANIFEST__'
$m = Get-Content $ManifestPath -Raw | ConvertFrom-Json
Write-Host '1/5 Importando backups de registro...'
Get-ChildItem $BackupDir -Filter *.reg -ErrorAction SilentlyContinue | ForEach-Object { reg.exe import $_.FullName | Out-Null }
Write-Host '2/5 Restaurando servicos...'
foreach ($s in @($m.Services)) { try { Set-Service -Name $s.Name -StartupType $s.StartType -ErrorAction Stop } catch {} }
Write-Host '3/5 Restaurando plano de energia...'
if ($m.PowerPlan) { powercfg /setactive $m.PowerPlan | Out-Null }
if (($m.Flags -join ' ') -match 'numproc') { bcdedit /deletevalue '{current}' numproc 2>$null }
Write-Host '4/5 Desfazendo tweaks de rede...'
foreach ($n in @($m.Nagle)) {
    Remove-ItemProperty -Path $n -Name 'TcpAckFrequency' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $n -Name 'TCPNoDelay' -ErrorAction SilentlyContinue
}
Write-Host '5/5 Removendo tarefas criadas...'
foreach ($t in @($m.Tasks)) { schtasks /Delete /TN $t /F | Out-Null }
Write-Host ''
Write-Host 'Concluido. Appx removidos na sessao (reinstale pela Store se quiser):'
($m.Appx -join ', ')
Write-Host 'Reinicie o PC para aplicar tudo.'
$null = Read-Host 'ENTER para sair'
'@
    $restore = $restore.Replace('__BACKUPDIR__', $BackupDir).Replace('__MANIFEST__', $ManifestPath)
    [IO.File]::WriteAllText((Join-Path $BackupDir 'Restore-IRM.ps1'), $restore, (New-Object System.Text.UTF8Encoding($true)))
}

function Save-Manifest {
    $obj = [pscustomobject]@{
        GeradoEm  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        RegFiles  = @($Manifest.RegFiles)
        Services  = @($Manifest.Services)
        Nagle     = @($Manifest.Nagle)
        Appx      = @($Manifest.Appx)
        Tasks     = @($Manifest.Tasks)
        Startup   = @($Manifest.Startup)
        Flags     = @($Manifest.Flags)
        PowerPlan = $Manifest.PowerPlan
    }
    $obj | ConvertTo-Json -Depth 5 | Set-Content -Path $ManifestPath -Encoding UTF8
    New-RestoreScript
}

function Backup-RegPath([string]$Path) {
    try {
        $hkey = $Path.TrimEnd('\') -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''
        $hkey = $hkey -replace '^HKLM:\\', 'HKLM\' -replace '^HKCU:\\', 'HKCU\' -replace '^HKCR:\\', 'HKCR\'
        $safe = ($hkey -replace '[\\:*?"<>|]', '_')
        if ($safe.Length -gt 110) { $safe = $safe.Substring($safe.Length - 110) }
        $file = Join-Path $BackupDir ($safe + '.reg')
        $null = reg.exe export $hkey $file /y 2>&1
        if (Test-Path $file) {
            if (-not $Manifest.RegFiles.Contains($file)) { $Manifest.RegFiles.Add($file) }
            return $file
        }
    } catch {}
    return $null
}

function Set-Reg([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    $null = Backup-RegPath $Path
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        Ok ("Registry: $Name -> $Value ($Type)")
    } catch {
        Err ("Falha registry $Path\$Name : " + $_.Exception.Message)
    }
}

function Disable-ServiceSmart([string]$Name) {
    try {
        $svc = Get-Service -Name $Name -ErrorAction Stop
        $start = [string]$svc.StartType
        $exists = $false
        foreach ($e in $Manifest.Services) { if ($e.Name -eq $Name) { $exists = $true; break } }
        if (-not $exists) { $Manifest.Services.Add([pscustomobject]@{ Name = $Name; StartType = $start }) }
        Save-Manifest
        Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        Ok ("Servico $Name desativado (era: $start)")
    } catch {
        Err ("Servico $Name : " + $_.Exception.Message)
    }
}


# ==============================================================
#  CATEGORIA 1 - ENERGIA & CPU
# ==============================================================
function Invoke-EnergyTweaks {
    Clear-Host
    Head 'ENERGIA & CPU'
    Info ("Plano ativo: " + ((powercfg /getactivescheme) -join ' ').Trim())

    if (Confirm-Action 'Ativar plano DESEMPENHO FINAL (Ultimate) + ajustes de maxima energia?') {
        try {
            if (-not $Manifest.PowerPlan) {
                $out = (powercfg /getactivescheme) -join ' '
                if ($out -match '([a-f0-9\-]{36})') { $Manifest.PowerPlan = $Matches[1]; Save-Manifest }
            }
            $newGuid = $null
            $list = (powercfg /list | Out-String)
            foreach ($line in ($list -split "`n")) {
                if ($line -match 'Desempenho Final|Ultimate Performance' -and $line -match '([a-f0-9\-]{36})') { $newGuid = $Matches[1] }
            }
            if (-not $newGuid) {
                $dup = (powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>&1 | Out-String)
                if ($dup -match '([a-f0-9\-]{36})') { $newGuid = $Matches[1] }
            }
            if ($newGuid) {
                powercfg /setacvalueindex $newGuid sub_processor PROCTHROTTLEMIN 100 | Out-Null
                powercfg /setacvalueindex $newGuid sub_processor PROCTHROTTLEMAX 100 | Out-Null
                powercfg /setacvalueindex $newGuid 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0 | Out-Null
                powercfg /setacvalueindex $newGuid 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 | Out-Null
                powercfg /setactive $newGuid | Out-Null
                powercfg /change disk-timeout-ac 0 | Out-Null
                powercfg /change standby-timeout-ac 0 | Out-Null
                powercfg /change hibernate-timeout-ac 0 | Out-Null
                if (Test-IsLaptop) {
                    powercfg /setdcvalueindex $newGuid sub_processor PROCTHROTTLEMIN 5 | Out-Null
                    powercfg /setdcvalueindex $newGuid sub_processor PROCTHROTTLEMAX 100 | Out-Null
                    powercfg /setdcvalueindex $newGuid 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 1 | Out-Null
                    Ok 'NOTEBOOK: desempenho MAXIMO na tomada (AC); na bateria volta a perfil economico + USB suspend ON'
                } else {
                    Ok 'Plano Desempenho Final ativo (CPU 100%, PCIe ASPM off, USB suspend off, discos sempre ligados)'
                }
            } else {
                Warn 'Plano Ultimate indisponivel nesta build. Aplicando ajustes no plano atual:'
                powercfg /setacvalueindex scheme_current sub_processor PROCTHROTTLEMIN 100 | Out-Null
                powercfg /setacvalueindex scheme_current sub_processor PROCTHROTTLEMAX 100 | Out-Null
                powercfg /setactive scheme_current | Out-Null
                Ok 'Ajustes aplicados no plano atual'
            }
        } catch { Err ("Energia: " + $_.Exception.Message) }
    }

    if (Confirm-Action 'Desligar Hibernacao e Inicializacao Rapida (libera ~13GB, evita erros de boot)?') {
        powercfg /h off | Out-Null
        Ok 'Hibernacao desligada (desfaca com: powercfg /h on)'
    }

    if (Confirm-Action 'Maximo de processadores no boot (msconfig) - somente se NAO for Entra/AzureAD?') {
        Invoke-BootCpuTweak
    }
    Pause-Key
}

# ==============================================================
#  CATEGORIA 2 - JOGOS & GPU
# ==============================================================
function Invoke-GamingTweaks {
    Clear-Host
    Head 'JOGOS & GPU'

    if (Confirm-Action 'Desativar GameDVR/gravacao em 2o plano (Game Bar fica, Game Mode ON)?') {
        Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
        Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'ShowStartupPanel' 0
        Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
        Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1
        Ok 'GameDVR desligado | Game Mode ativado'
    }

    if (Confirm-Action 'Ativar HAGS - agendamento de GPU por hardware (requer REBOOT)?') {
        if ($WinBuild -ge 19041) {
            Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
            Info 'Aplique apos reiniciar.'
        } else { Warn 'HAGS nao suportado nesta build.' }
    }

    if (Confirm-Action 'Prioridade maxima para app em foco (Win32PrioritySeparation=38)?') {
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38
    }

    if (Confirm-Action 'Desativar telemetria NVIDIA + tarefas NvTm?') {
        Get-Service | Where-Object { $_.Name -match '^NvTelemetry' -or $_.DisplayName -match 'NVIDIA Telemetry' } | ForEach-Object {
            Disable-ServiceSmart $_.Name
        }
        Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match '^NvTm' } | ForEach-Object {
            try { Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath | Out-Null; Ok ("Tarefa " + $_.TaskName + " desativada") } catch {}
        }
    }

    if (Confirm-Action 'Tweaks de rede para jogos (anti-Nagle + sem throttling de rede)?') {
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex' ([int]-1)
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 10
        $ifs = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -ErrorAction SilentlyContinue
        $count = 0
        foreach ($i in $ifs) {
            try {
                $null = Backup-RegPath $i.PSPath
                if (-not $Manifest.Nagle.Contains($i.PSPath)) { $Manifest.Nagle.Add($i.PSPath) }
                New-ItemProperty -Path $i.PSPath -Name 'TcpAckFrequency' -Value 1 -PropertyType DWord -Force | Out-Null
                New-ItemProperty -Path $i.PSPath -Name 'TCPNoDelay' -Value 1 -PropertyType DWord -Force | Out-Null
                $count++
            } catch {}
        }
        Save-Manifest
        Ok ("Anti-Nagle aplicado em $count interfaces")
    }

    Write-Host ''
    Info 'Manual (2 min): NVIDIA App > Global Settings > Low Latency: ON | Power management: Prefer max performance'
    Info 'Manual: Wallpaper Engine > Performance > Pausar quando aplicativo fullscreen estiver rodando'
    Pause-Key
}

# ==============================================================
#  CATEGORIA R - REDE & DNS
# ==============================================================
function Invoke-NetworkTweaks {
    Clear-Host
    Head 'REDE & DNS'
    Write-Host '  1) Cloudflare  (1.1.1.1 / 1.0.0.1) - rapido e privado'
    Write-Host '  2) Google      (8.8.8.8 / 8.8.4.4)'
    Write-Host '  3) Quad9       (9.9.9.9 - filtra malware)'
    Write-Host '  4) Nao mexer no DNS'
    $d = Read-Host '  Escolha [1-4]'
    $dns = $null
    if ($d -eq '1') { $dns = @('1.1.1.1', '1.0.0.1') }
    elseif ($d -eq '2') { $dns = @('8.8.8.8', '8.8.4.4') }
    elseif ($d -eq '3') { $dns = @('9.9.9.9') }
    if ($dns) {
        $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
        foreach ($a in $adapters) {
            try { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $dns -ErrorAction Stop; Ok ("DNS " + ($dns -join ' + ') + " em " + $a.Name) }
            catch { Err ("DNS em " + $a.Name + ": " + $_.Exception.Message) }
        }
        Clear-DnsClientCache
        ipconfig /flushdns | Out-Null
    }
    if (Confirm-Action 'Delivery Optimization: nao baixar de PCs de fora da sua rede (economia de banda)?') {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 1
        Info 'Reversivel em [9] RESTAURAR.'
    }
    Pause-Key
}

# ==============================================================
#  CATEGORIA 3 - INICIALIZACAO & VISUAL
# ==============================================================
function Test-StartupEnabled([string]$Area, [string]$Name) {
    $k = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$Area"
    if (Test-Path $k) {
        $props = (Get-Item $k).Property
        if ($props -contains $Name) {
            $b = (Get-ItemPropertyValue $k $Name)[0]
            return (($b -band 1) -eq 0)
        }
    }
    return $true
}

function Get-StartupItems {
    $list = @()
    foreach ($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run')) {
        if (Test-Path $key) {
            foreach ($n in (Get-Item $key).Property) {
                if ($n -like 'PS*') { continue }
                $scope = 'HKCU'; if ($key -like 'HKLM:*') { $scope = 'HKLM' }
                $list += [pscustomobject]@{
                    Name = $n; Area = 'Run'; Scope = $scope
                    Command = [string](Get-ItemPropertyValue $key $n)
                    Enabled = (Test-StartupEnabled 'Run' $n)
                }
            }
        }
    }
    foreach ($folder in @((Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup'), (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'))) {
        if (Test-Path $folder) {
            Get-ChildItem $folder -Filter '*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
                $list += [pscustomobject]@{
                    Name = $_.Name; Area = 'StartupFolder'; Scope = 'Folder'
                    Command = $_.FullName
                    Enabled = (Test-StartupEnabled 'StartupFolder' $_.Name)
                }
            }
        }
    }
    return $list
}

function Disable-StartupItem([string]$Name, [string]$Area) {
    $k = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$Area"
    $null = Backup-RegPath $k
    if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
    $bytes = [byte[]](3,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    New-ItemProperty -Path $k -Name $Name -Value $bytes -PropertyType Binary -Force | Out-Null
    $tag = "$Area\$Name"
    if (-not $Manifest.Startup.Contains($tag)) { $Manifest.Startup.Add($tag) }
    Save-Manifest
}

function Invoke-StartupTweaks {
    Clear-Host
    Head 'INICIALIZACAO'

    $items = Get-StartupItems
    if ($global:AutoYes) {
        $pattern = '^(EpicGamesLauncher|Discord|electron\.app\.Notion|Gemini|bloom|TaskBarHero)$|^MicrosoftEdgeAutoLaunch_|^GoogleUpdaterTaskUser'
        foreach ($it in $items) {
            if ($it.Scope -eq 'HKCU' -and $it.Enabled -and $it.Name -match $pattern) {
                Disable-StartupItem $it.Name $it.Area
                Ok ("Auto: desligado " + ($it.Name -replace '\.lnk$', ''))
            }
        }
    } else {
        if ($items.Count -eq 0) { Info 'Nenhum item de inicializacao encontrado.' } else {
            Write-Host '  Itens de inicializacao (estado atual):' -ForegroundColor White
            for ($i = 0; $i -lt $items.Count; $i++) {
                $st = 'LIGADO'; if (-not $items[$i].Enabled) { $st = 'desligado' }
                $disp = $items[$i].Name -replace '\.lnk$', ''
                $cmd = $items[$i].Command
                if ($cmd.Length -gt 55) { $cmd = $cmd.Substring(0, 55) + '...' }
                $color = 'White'; if ($st -eq 'desligado') { $color = 'DarkGray' }
                Write-Host ("  [{0,2}] {1,-30} {2,-10} {3}" -f ($i + 1), $disp, $st, $cmd) -ForegroundColor $color
            }
            Write-Host ''
            Info 'Mantenha: antivirus, teclado/mouse (RGB), ferramentas que voce usa de verdade.'
            $sel = Read-Host '  Numeros para DESLIGAR (ex: 1,3,5-8) | Enter = nao mexer'
            if ($sel -ne '') {
                foreach ($idx in (Get-SelectedIndexes $sel $items.Count)) {
                    $it = $items[$idx - 1]
                    if ($it.Scope -eq 'HKLM') { Warn (($it.Name) + ': item de maquina (HKLM) - use o Gerenciador de Tarefas para este'); continue }
                    Disable-StartupItem $it.Name $it.Area
                    Ok ('Desligado: ' + ($it.Name -replace '\.lnk$', ''))
                }
            }
        }
    }

    if (Confirm-Action 'Desativar Startup Boost e pre-carregamento do Edge?') {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0
    }

    if (Confirm-Action 'Efeitos visuais: preset DESEMPENHO+LEGIBILIDADE (miniaturas, fontes e taskbar suaves; animacoes e sombras off)?') {
        Set-Reg 'HKCU:\Control Panel\Desktop' 'UserPreferencesMask' ([byte[]](0x90,0x12,0x01,0x80,0x10,0x00,0x00,0x00)) 'Binary'
        Set-Reg 'HKCU:\Control Panel\Desktop' 'DragFullWindows' '0' 'String'
        Set-Reg 'HKCU:\Control Panel\Desktop' 'FontSmoothing' '2' 'String'
        Set-Reg 'HKCU:\Control Panel\Desktop' 'FontSmoothingType' 2
        Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'IconsOnly' 0
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewAlphaSelect' 0
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewShadow' 0
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 1
        Set-Reg 'HKCU:\Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0
        Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 3
        Info 'Preset "Personalizar": miniaturas ON, suavizacao da taskbar ON, fontes ON - animacoes/sombras/transparencia OFF (igual ao print).'
        Info 'Aplica por completo apos logoff/logon (ou reboot).'
    }
    Pause-Key
}

# ==============================================================
#  CATEGORIA 4 - LIMPEZA & DISCO
# ==============================================================
function Invoke-CleanupTweaks {
    Clear-Host
    Head 'LIMPEZA & DISCO'

    if (Confirm-Action 'Limpar temporarios, lixeira, cache de updates, dumps e DNS?') {
        $before = (Get-PSDrive C).Free
        foreach ($p in @($env:TEMP, (Join-Path $env:windir 'Temp'), (Join-Path $env:LOCALAPPDATA 'CrashDumps'))) {
            if (Test-Path $p) { Get-ChildItem $p -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
        }
        $sd = Join-Path $env:windir 'SoftwareDistribution\Download'
        if (Test-Path $sd) { Get-ChildItem $sd -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        try { Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue } catch {}
        ipconfig /flushdns | Out-Null
        $after = (Get-PSDrive C).Free
        Ok ("Limpeza concluida - liberado ~{0:N1} MB no C:" -f (($after - $before) / 1MB))
    }

    if (Confirm-Action 'Ativar Storage Sense (limpeza automatica semanal)?') {
        $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
        Set-Reg $k '01' 1
        Set-Reg $k '04' 1
        Set-Reg $k '08' 1
        Set-Reg $k '32' 7
    }

    if (Confirm-Action 'DISM StartComponentCleanup - limpa WinSxS antigo (demora minutos)?') {
        Write-Host '  Executando DISM... aguarde (sem barra de progresso).' -ForegroundColor Cyan
        $r = Start-Process -FilePath dism.exe -ArgumentList '/Online','/Cleanup-Image','/StartComponentCleanup' -Wait -PassThru -WindowStyle Hidden
        if ($r.ExitCode -eq 0) { Ok 'DISM concluido' } else { Warn ("DISM saiu com codigo " + $r.ExitCode) }
    }

    if (Confirm-Action 'Criar tarefas de manutencao (discos semanal + componentes mensal)?') {
        schtasks /Create /F /RL HIGHEST /RU SYSTEM /SC WEEKLY /D DOM /ST 03:00 /TN 'IRM\OtimizarDiscos' /TR 'defrag.exe /C /O' | Out-Null
        schtasks /Create /F /RL HIGHEST /RU SYSTEM /SC MONTHLY /D 1 /ST 04:00 /TN 'IRM\LimpezaComponentes' /TR 'Dism.exe /Online /Cleanup-Image /StartComponentCleanup' | Out-Null
        foreach ($t in @('IRM\OtimizarDiscos', 'IRM\LimpezaComponentes')) {
            if (-not $Manifest.Tasks.Contains($t)) { $Manifest.Tasks.Add($t) }
        }
        Save-Manifest
        Ok 'Tarefas criadas: IRM\OtimizarDiscos (dom 03:00) | IRM\LimpezaComponentes (dia 1, 04:00)'
    }

    if (Confirm-Action 'Otimizar TODOS os discos agora (TRIM nos SSD + defrag nos HDs)?') {
        Write-Host '  Otimizando... (pode demorar nos HDs A:/B:)' -ForegroundColor Cyan
        $null = Start-Process -FilePath defrag.exe -ArgumentList '/C','/O' -Wait -PassThru -WindowStyle Hidden
        Ok 'Otimizacao concluida'
    }

    if (Confirm-Action 'Verificacao de integridade do sistema (sfc /scannow, ~10min)?') {
        $r = Start-Process -FilePath sfc.exe -ArgumentList '/scannow' -Wait -PassThru -WindowStyle Hidden
        Ok ("SFC concluido (codigo " + $r.ExitCode + ")")
    }
    Pause-Key
}


# ==============================================================
#  CATEGORIA 5 - PRIVACIDADE & TELEMETRIA
# ==============================================================
function Invoke-PrivacyTweaks {
    Clear-Host
    Head 'PRIVACIDADE & TELEMETRIA'

    if (Confirm-Action 'Telemetria no minimo + desativar DiagTrack, CEIP e relatorios?') {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
        Disable-ServiceSmart 'DiagTrack'
        Disable-ServiceSmart 'dmwappushservice'
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows' 'CEIPEnable' 0
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1
        Set-Reg 'HKCU:\SOFTWARE\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0
        Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
        Set-Reg 'HKCU:\Software\Microsoft\Personalization\Settings' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
        foreach ($tn in @(
            '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
            '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
            '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
            '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip')) {
            try {
                $tp = $tn.Substring(0, $tn.LastIndexOf('\') + 1)
                $nm = $tn.Split('\')[-1]
                Disable-ScheduledTask -TaskPath $tp -TaskName $nm -ErrorAction Stop | Out-Null
                Ok ("Tarefa telemetria desativada: " + $nm)
            } catch {}
        }
    }

    if (Confirm-Action 'Desligar Widgets/noticias + sugestoes e anuncios do Windows?') {
        if ($IsWin11) { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0 }
        else { Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0 }
        $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        Set-Reg $cdm 'SubscribedContent-338387Enabled' 0
        Set-Reg $cdm 'SubscribedContent-338388Enabled' 0
        Set-Reg $cdm 'SubscribedContent-338389Enabled' 0
        Set-Reg $cdm 'SubscribedContent-310093Enabled' 0
        Set-Reg $cdm 'SystemPaneSuggestionsEnabled' 0
        Set-Reg $cdm 'SilentInstalledAppsEnabled' 0
        Set-Reg $cdm 'PreInstalledAppsEnabled' 0
        Set-Reg $cdm 'OemPreInstalledAppsEnabled' 0
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' 0
    }
    Pause-Key
}

# ==============================================================
#  CATEGORIA 5b - BLOATWARE MSIX
# ==============================================================
function Remove-AppxSmart([string]$Pattern) {
    $found = Get-AppxPackage -AllUsers -Name $Pattern -ErrorAction SilentlyContinue
    foreach ($p in $found) {
        try {
            Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop
            Ok ("Removido: " + $p.Name)
        } catch {
            try { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop; Ok ("Removido (usuario atual): " + $p.Name) }
            catch { Err ("Falha removendo " + $p.Name + ": " + $_.Exception.Message) }
        }
        if (-not $Manifest.Appx.Contains($p.Name)) { $Manifest.Appx.Add($p.Name) }
    }
    try {
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $Pattern } | ForEach-Object {
            Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {}
    Save-Manifest
}

function Invoke-BloatRemoval {
    Clear-Host
    Head 'BLOATWARE (remocao via Appx)'
    $bloat = @(
        'Microsoft.MicrosoftSolitaireCollection',
        'Microsoft.BingWeather',
        'Microsoft.BingNews',
        'Microsoft.BingSearch',
        'Microsoft.WindowsMaps',
        'Microsoft.MSPaint',
        'Microsoft.Microsoft3DViewer',
        'Microsoft.MixedReality.Portal',
        'Microsoft.People',
        'Microsoft.Windows.DevHome',
        'Microsoft.WindowsFeedbackHub',
        'Clipchamp.Clipchamp',
        'Microsoft.PowerAutomateDesktop',
        'Microsoft.MicrosoftOfficeHub',
        'Microsoft.GetStarted',
        'Microsoft.549981C3F5F10',
        'MSTeams',
        'MicrosoftTeams',
        'Microsoft.YourPhone',
        'Microsoft.Todos'
    )
    $avail = @()
    foreach ($b in $bloat) {
        $pk = Get-AppxPackage -AllUsers -Name $b -ErrorAction SilentlyContinue
        if ($pk) { $avail += [pscustomobject]@{ Name = $b; Label = $pk[0].Name } }
    }
    if ($avail.Count -eq 0) { Info 'Nenhum bloatware da lista encontrado.'; Pause-Key; return }
    Write-Host '  Encontrados (pode marcar varios):' -ForegroundColor White
    for ($i = 0; $i -lt $avail.Count; $i++) {
        Write-Host ("  [{0,2}] {1}" -f ($i + 1), $avail[$i].Name)
    }
    Info 'Nao mexe em: Fotos, Calculadora, Notepad, Terminal, Store, Camera, Xbox.'
    $sel = Read-Host '  Numeros para REMOVER (ex: 1,3,4-7) | a = todos | Enter = cancelar'
    if ($sel -eq '') { Pause-Key; return }
    if ($sel -eq 'a') { $chosen = @(1..$avail.Count) } else { $chosen = Get-SelectedIndexes $sel $avail.Count }
    foreach ($idx in $chosen) { Remove-AppxSmart $avail[$idx - 1].Name }
    Info 'Reboot recomendado. Reinstale qualquer um pela Microsoft Store se mudar de ideia.'
    Pause-Key
}

# ==============================================================
#  CATEGORIA 6 - SUITE ASUS (diet)
# ==============================================================
function Invoke-AsusDiet {
    Clear-Host
    Head 'SUITE ASUS (Armoury Crate / Aura / ROG)'

    $svcs = Get-Service -ErrorAction SilentlyContinue | Where-Object {
        ($_.Name -match 'asus|rog|armoury|aura|lighting') -or ($_.DisplayName -match 'ASUS|ROG|Armoury|AURA|Lighting')
    }
    if ($svcs.Count -gt 0) {
        Write-Host '  Servicos ASUS/ROG encontrados:' -ForegroundColor White
        $svcList = @($svcs)
        for ($i = 0; $i -lt $svcList.Count; $i++) {
            Write-Host ("  [{0,2}] {1,-28} ({2})" -f ($i + 1), $svcList[$i].Name, $svcList[$i].StartType)
        }
        if (Confirm-Action 'Desativar TODOS esses servicos (reversivel)?') {
            foreach ($s in $svcList) { Disable-ServiceSmart $s.Name }
        }
    } else { Info 'Nenhum servico ASUS/ROG encontrado.' }

    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $apps = Get-ItemProperty $paths -ErrorAction SilentlyContinue | Where-Object {
        $_.DisplayName -and ($_.DisplayName -match 'Armoury|AURA|ROG Live|ASUS Framework') -and ($_.DisplayName -notmatch 'FAN XPERT')
    }
    if ($apps) {
        $appList = @($apps)
        Write-Host ''
        Write-Host '  Programas ASUS para desinstalar (Fan Xpert sera PRESERVADO):' -ForegroundColor White
        for ($i = 0; $i -lt $appList.Count; $i++) { Write-Host ("  [{0,2}] {1}" -f ($i + 1), $appList[$i].DisplayName) }
        if (Confirm-Action 'Desinstalar todos acima (pode abrir janelas; reboot recomendado)?') {
            foreach ($e in $appList) {
                try {
                    $cmd = $e.QuietUninstallString
                    if (-not $cmd) {
                        $cmd = $e.UninstallString
                        if ($cmd -match '(?i)msiexec') { $cmd = ($cmd -replace '/I', '/X') + ' /qn /norestart' }
                        else { $cmd = $cmd + ' /S' }
                    }
                    Info ("Executando: " + $cmd)
                    $p = Start-Process cmd.exe -ArgumentList '/c', $cmd -Wait -PassThru -WindowStyle Hidden
                    if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) { Ok ("Desinstalado: " + $e.DisplayName) }
                    else { Warn ("Codigo " + $p.ExitCode + " ao desinstalar " + $e.DisplayName + " (confira em Configuracoes > Apps)") }
                } catch { Err ($e.DisplayName + ": " + $_.Exception.Message) }
            }
            Get-AppxPackage -AllUsers -Name '*ArmouryCrate*' -ErrorAction SilentlyContinue | ForEach-Object {
                Remove-AppxSmart $_.Name
            }
            Ok 'Suite ASUS removida. Configure fan curves no BIOS ou use o Fan Xpert.'
        }
    } else { Info 'Nenhum programa ASUS removivel encontrado (alem do Fan Xpert).' }
    Info 'Reboot recomendado apos a diet.'
    Pause-Key
}


# ==============================================================
#  CATEGORIA 7 - PROGRAMAS (WINGET)
# ==============================================================
function Install-StoreApp([string]$Nome, [string]$PidLoja) {
    if ($PidLoja) {
        & winget install --id $PidLoja -s msstore -e --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -eq 0) { return $true }
        Warn ("ID da loja " + $PidLoja + " falhou - tentando busca por '" + $Nome + "'")
    }
    $search = (& winget search $Nome --source msstore --accept-source-agreements 2>$null | Out-String)
    $id = $null
    foreach ($line in ($search -split "`n")) {
        if ($line -match $Nome -and $line -match '(?<= )(9[A-Z0-9]{11})(?= )') { $id = $Matches[1]; break }
    }
    if (-not $id) { Warn ("Nao achei '" + $Nome + "' na Store via winget search"); return $false }
    & winget install --id $id -s msstore -e --accept-package-agreements --accept-source-agreements
    return ($LASTEXITCODE -eq 0)
}

function Install-Office365 {
    try {
        $dir = Join-Path $env:TEMP 'IRM-ODT'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Info 'Baixando Office Deployment Tool...'
        Invoke-WebRequest 'https://go.microsoft.com/fwlink/?linkid=860280' -OutFile (Join-Path $dir 'odt.exe') -UseBasicParsing
        Start-Process -FilePath (Join-Path $dir 'odt.exe') -ArgumentList ("/extract:`"$dir`" /quiet") -Wait
        $setup = Join-Path $dir 'setup.exe'
        if (-not (Test-Path $setup)) { Err 'Setup.exe do ODT nao apareceu.'; return }
        $cfg = Join-Path $dir 'config.xml'
        @'
<Configuration>
  <Add OfficeClientEdition="64" Channel="Current">
    <Product ID="O365BusinessRetail">
      <Language ID="pt-br" />
      <ExcludeApp ID="Teams" />
      <ExcludeApp ID="Groove" />
    </Product>
  </Add>
  <Display Level="Full" AcceptEULA="TRUE" />
</Configuration>
'@ | Set-Content -Path $cfg -Encoding UTF8
        Info 'Instalando Office 365 (10-40 min conforme a rede)...'
        Start-Process -FilePath $setup -ArgumentList ("/configure `"$cfg`"") -Wait
        Ok 'Office 365 instalado'
    } catch { Err ("Office 365: " + $_.Exception.Message) }
}

function Install-AkerClient {
    try {
        if ([string]::IsNullOrWhiteSpace($AkerSetupUrl)) { Warn 'Configure $AkerSetupUrl no topo do script.'; return }
        $dst = Join-Path $env:TEMP 'aker-setup.exe'
        Info ('Baixando Aker Client: ' + $AkerSetupUrl)
        Invoke-WebRequest $AkerSetupUrl -OutFile $dst -UseBasicParsing
        Info 'Executando instalador (interativo)...'
        Start-Process -FilePath $dst -Wait
        Ok 'Aker Client instalado'
    } catch { Err ("Aker: suba o instalador no bucket R2 (pasta aker/setup.exe). Detalhe: " + $_.Exception.Message) }
}

function Invoke-ProgramsMenu {
    Clear-Host
    Head 'PROGRAMAS (WINGET)'
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Warn 'winget nao encontrado. Instale "Instalador de Aplicativo" na Microsoft Store.'
        Pause-Key
        return
    }

    if (Confirm-Action 'Atualizar TODOS os programas instalados (winget upgrade --all)?') {
        & winget upgrade --all --silent --accept-package-agreements --accept-source-agreements
        Ok 'Atualizacao concluida'
    }

    $catalog = @(
        @{ Cat = 'SUPORTE & REMOTO'; Apps = @(
            @{N = 'AnyDesk'; I = 'AnyDeskSoftwareGmbH.AnyDesk'; S = 'winget'; Q = ''},
            @{N = 'Aker Client (instalador do bucket R2)'; I = 'AKER'; S = 'aker'; Q = ''}) },
        @{ Cat = 'NAVEGADORES'; Apps = @(
            @{N = 'Google Chrome'; I = 'Google.Chrome'; S = 'winget'; Q = ''}) },
        @{ Cat = 'MICROSOFT & NUVEM'; Apps = @(
            @{N = 'OneDrive'; I = 'Microsoft.OneDrive'; S = 'winget'; Q = ''},
            @{N = 'Office 365 (via ODT)'; I = 'OFFICE'; S = 'office'; Q = ''},
            @{N = 'Teams'; I = 'Microsoft.Teams'; S = 'winget'; Q = ''},
            @{N = 'WhatsApp (Store)'; I = '9NKSQGP7F2NH'; S = 'msstore'; Q = ''},
            @{N = 'WhatsApp Beta (Store, busca automatica)'; I = ''; S = 'store'; Q = 'WhatsApp Beta'},
            @{N = 'Microsoft Imagens (Store, busca automatica)'; I = ''; S = 'store'; Q = 'Microsoft Imagens'},
            @{N = 'Calculadora (Store)'; I = '9WZDNCRFHVN5'; S = 'msstore'; Q = ''}) }
    )

    Write-Host '  Verificando programas instalados (aguarde)...' -ForegroundColor Cyan
    $installedOut = (& winget list --accept-source-agreements 2>$null | Out-String)
    $flat = @()
    foreach ($cat in $catalog) {
        Write-Host ''
        Write-Host ("  -- " + $cat.Cat + " --") -ForegroundColor Yellow
        foreach ($a in $cat.Apps) {
            $inst = (($a.S -eq 'winget') -or ($a.S -eq 'msstore')) -and ($installedOut -match [regex]::Escape($a.I))
            $flat += [pscustomobject]@{ N = $a.N; I = $a.I; S = $a.S; Q = $a.Q; Installed = $inst }
            $mark = '          '; if ($inst) { $mark = '[instalado]' }
            $color = 'White'; if ($inst) { $color = 'DarkGray' }
            Write-Host ("  [{0,2}] {1,-42} {2}" -f $flat.Count, $a.N, $mark) -ForegroundColor $color
        }
    }
    Write-Host ''
    $sel = Read-Host '  Numeros para INSTALAR (ex: 2,5,9-11) | a = TODOS que faltam | Enter = cancelar'
    if ($sel -eq '') { Pause-Key; return }
    if ($sel.Trim().ToLower() -eq 'a') { $chosen = @(1..$flat.Count) } else { $chosen = Get-SelectedIndexes $sel $flat.Count }
    foreach ($idx in $chosen) {
        $app = $flat[$idx - 1]
        if ($app.Installed) { Info ($app.N + ' ja instalado - pulando'); continue }
        Write-Host ("  Instalando " + $app.N + "...") -ForegroundColor Cyan
        $fino = $false
        switch ($app.S) {
            'office' { Install-Office365; $fino = $true }
            'aker' { Install-AkerClient; $fino = $true }
            'msstore' { $fino = Install-StoreApp $app.N $app.I }
            'store' { $fino = Install-StoreApp $app.Q '' }
            default {
                & winget install --id $app.I -e --silent --accept-package-agreements --accept-source-agreements
                $fino = ($LASTEXITCODE -eq 0)
            }
        }
        if ($fino) { Ok ($app.N + ' instalado') } else { Warn ($app.N + ' - confira manualmente se algo falhou') }
    }
    Pause-Key
}

# ==============================================================
#  CATEGORIA 8 - RELATORIOS
# ==============================================================
function Show-Reports {
    Clear-Host
    Head 'RELATORIOS DO SISTEMA'

    $os = Get-CimInstance Win32_OperatingSystem
    $up = (Get-Date) - $os.LastBootUpTime
    $ramPct = [math]::Round(100 * (1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize), 0)
    $cpu = Get-CimInstance Win32_Processor
    Write-Host ("  OS: {0} (build {1}) | {2}h{3}min de uso" -f $os.Caption, $os.BuildNumber, $up.Hours + ($up.Days * 24), $up.Minutes)
    Write-Host ("  CPU: {0} | carga {1}%  |  RAM: {2}% em uso de {3:N1} GB" -f $cpu.Name.Trim(), $cpu.LoadPercentage, $ramPct, ($os.TotalVisibleMemorySize / 1MB))
    Info ("Plano de energia: " + ((powercfg /getactivescheme) -join ' ').Trim())

    Write-Host ''
    Write-Host '  Discos:' -ForegroundColor White
    foreach ($d in (Get-PhysicalDisk)) {
        $rel = $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        $temp = ''; if ($rel -and $rel.Temperature) { $temp = (" | {0}C" -f $rel.Temperature) }
        Write-Host ("   {0,-28} {1,-6} {2,-8} {3,6:N0} GB{4}" -f $d.FriendlyName, $d.MediaType, $d.HealthStatus, ($d.Size / 1GB), $temp)
    }
    $c = Get-PSDrive C
    Write-Host ("   C: livre {0:N1} GB de {1:N1} GB" -f ($c.Free / 1GB), (($c.Used + $c.Free) / 1GB))

    Write-Host ''
    Write-Host '  Top processos (RAM):' -ForegroundColor White
    Get-Process | Sort-Object WS -Descending | Select-Object -First 8 | ForEach-Object {
        Write-Host ("   {0,-30} {1,8} MB" -f $_.Name, [math]::Round($_.WS / 1MB, 0))
    }

    Write-Host ''
    Write-Host '  Bibliotecas Steam:' -ForegroundColor White
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if ($steam) {
        $vdf = Join-Path $steam 'config\libraryfolders.vdf'
        if (Test-Path $vdf) {
            $libs = Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { ($_.Groups[1].Value -replace '\\\\', '\') } | Sort-Object -Unique
            foreach ($lib in $libs) {
                $drv = $lib.Substring(0, 1)
                $pd = Get-PSDrive -Name $drv -ErrorAction SilentlyContinue
                $free = ''; if ($pd) { $free = (" (livre {0:N0} GB)" -f ($pd.Free / 1GB)) }
                Write-Host ("   " + $lib + $free)
            }
            Info 'Dica: jogos em HD (A:/B:) carregam mais lento - mova os ativos para SSD (D: tem 931 GB livres).'
        }
    } else { Info 'Steam nao encontrado.' }

    Write-Host ''
    Write-Host '  Atualizacoes pendentes (winget):' -ForegroundColor White
    $upOut = (& winget upgrade 2>$null | Out-String)
    if ($upOut) { ($upOut -split "`n" | Select-Object -First 25) | ForEach-Object { Write-Host ("   " + $_.TrimEnd()) } }
    Pause-Key
}

# ==============================================================
#  RESTAURAR
# ==============================================================
function Invoke-RestoreNow {
    Clear-Host
    Head 'RESTAURAR BACKUP'
    if (-not (Test-Path $ManifestPath)) { Warn 'Nenhum backup/manifest encontrado.'; Pause-Key; return }
    if (Confirm-Action 'Importar todos os .reg e restaurar servicos/plano/rede/tarefas?') {
        Get-ChildItem $BackupDir -Filter '*.reg' -ErrorAction SilentlyContinue | ForEach-Object {
            $null = reg.exe import $_.FullName 2>&1
        }
        Ok ('Registry: ' + (Get-ChildItem $BackupDir -Filter '*.reg').Count + ' arquivos reimportados')
        foreach ($s in $Manifest.Services) {
            try { Set-Service -Name $s.Name -StartupType $s.StartType -ErrorAction Stop; Ok ("Servico " + $s.Name + " -> " + $s.StartType) } catch {}
        }
        if ($Manifest.PowerPlan) { powercfg /setactive $Manifest.PowerPlan | Out-Null; Ok 'Plano de energia restaurado' }
        foreach ($n in $Manifest.Nagle) {
            Remove-ItemProperty -Path $n -Name 'TcpAckFrequency' -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $n -Name 'TCPNoDelay' -ErrorAction SilentlyContinue
        }
        Ok 'Tweaks de rede removidos'
        foreach ($t in $Manifest.Tasks) { schtasks /Delete /TN $t /F | Out-Null }
        Ok 'Tarefas agendadas removidas'
        if ($Manifest.Appx.Count -gt 0) {
            Info ('Appx removidos (reinstale pela Store se quiser): ' + ($Manifest.Appx -join ', '))
        }
        Ok 'Restauracao concluida. Reinicie o PC.'
    }
    Pause-Key
}

# ==============================================================
#  APLICAR TUDO
# ==============================================================
function Invoke-ApplyAll {
    Clear-Host
    Head 'APLICAR TUDO (MODO COMPLETO)'
    Write-Host '  Executa: Energia, Jogos&GPU, Inicializacao(auto), Limpeza, Privacidade.'
    Write-Host '  Depois pergunta sobre: Bloatware e Suite ASUS.'
    Warn 'Tudo e reversivel pela opcao [9] ou pelo Restore-IRM.ps1 no backup.'
    if (-not (Confirm-Action 'Continuar?')) { return }
    $global:AutoYes = $true
    Invoke-EnergyTweaks
    Invoke-GamingTweaks
    Invoke-StartupTweaks
    Invoke-CleanupTweaks
    Invoke-PrivacyTweaks
    $global:AutoYes = $false
    if (Confirm-Action 'Aplicar REDE & DNS rapido (Cloudflare + Delivery Optimization local)?') { Invoke-NetworkTweaks }
    if (Confirm-Action 'Abrir remocao de BLOATWARE (lista interativa)?') { Invoke-BloatRemoval }
    if (Confirm-Action 'Abrir diet da SUITE ASUS?') { Invoke-AsusDiet }
    Ok 'Rotina completa finalizada. Reinicie o PC para aplicar tudo.'
    Pause-Key
}

# ==============================================================
#  MENU PRINCIPAL
# ==============================================================
function Show-MainMenu {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host '  ==========================================================' -ForegroundColor Cyan
        Write-Host ('   IRM OTIMIZADOR v' + $ScriptVersion + '  |  Windows 10/11  |  Reversivel') -ForegroundColor Cyan
        Write-Host '  ==========================================================' -ForegroundColor Cyan
        $os = Get-CimInstance Win32_OperatingSystem
        $up = (Get-Date) - $os.LastBootUpTime
        $ramPct = [math]::Round(100 * (1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize), 0)
        $plan = ((powercfg /getactivescheme) -join ' ') -replace '.*\((.*)\)\s*$', '$1'
        Write-Host ("   OS: {0} (build {1}) | RAM: {2}% | Uptime: {3}h{4}min" -f $(if ($IsWin11) { 'Win11' } else { 'Win10' }), $WinBuild, $ramPct, ($up.Hours + $up.Days * 24), $up.Minutes) -ForegroundColor DarkGray
        Write-Host ("   Plano: " + $plan) -ForegroundColor DarkGray
        Write-Host ("   Backup: " + $BackupDir) -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '   [1] Energia & CPU            [2] Jogos & GPU'
        Write-Host '   [3] Inicializacao & Visual   [4] Limpeza & Disco'
        Write-Host '   [5] Privacidade & Bloat      [6] Suite ASUS (diet)'
        Write-Host '   [7] Programas (Winget)       [8] Relatorios'
        Write-Host '   [R] Rede & DNS               [9] RESTAURAR backup'
        Write-Host '   [0] Aplicar TUDO             [X] Sair'
        Write-Host ''
        $op = Read-Host '  Opcao'
        switch ($op.Trim().ToUpper()) {
            '1' { Invoke-EnergyTweaks }
            '2' { Invoke-GamingTweaks }
            '3' { Invoke-StartupTweaks }
            '4' { Invoke-CleanupTweaks }
            '5' { Invoke-PrivacyTweaks; Invoke-BloatRemoval }
            '6' { Invoke-AsusDiet }
            '7' { Invoke-ProgramsMenu }
            'R' { Invoke-NetworkTweaks }
            '8' { Show-Reports }
            '9' { Invoke-RestoreNow }
            '0' { Invoke-ApplyAll }
            'X' {
                Write-Host ''
                Info ('Backups e restauracao em: ' + $BackupDir)
                Info 'Para desfazer depois: PowerShell admin -> .\Restore-IRM.ps1'
                return
            }
        }
    }
}

Save-Manifest
Show-MainMenu

