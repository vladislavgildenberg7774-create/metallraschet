# МеталлРасчёт — агент станка.
# Забирает из облака чертежи, отправленные с сайта на этот станок, и кладёт их в папку.
# Работает в фоне, значок — в трее у часов. Настройки: config.json рядом с этим файлом.
# Windows PowerShell 5.1 (встроен в Windows 10/11), ничего устанавливать не нужно.

$ErrorActionPreference = 'Stop'
$Version = '1.4'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Неверная дата на компьютере станка (например, её переставляет программа лазера) не должна рвать связь.
# Прощаем ТОЛЬКО ошибки срока действия сертификата; подмена сервера (чужое имя, недоверенный сертификат) — по-прежнему отказ.
if (-not ('MrCertCheck' -as [type])) {
  Add-Type -TypeDefinition @'
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class MrCertCheck {
  public static bool Check(object s, X509Certificate c, X509Chain chain, SslPolicyErrors e) {
    if (e == SslPolicyErrors.None) return true;
    if (e != SslPolicyErrors.RemoteCertificateChainErrors || chain == null) return false;
    X509ChainStatusFlags ok = X509ChainStatusFlags.NotTimeValid | X509ChainStatusFlags.NotTimeNested |
      X509ChainStatusFlags.CtlNotTimeValid | X509ChainStatusFlags.RevocationStatusUnknown | X509ChainStatusFlags.OfflineRevocation;
    foreach (X509ChainStatus st in chain.ChainStatus) if ((st.Status & ~ok) != 0) return false;
    return true;
  }
  public static void Install() { ServicePointManager.ServerCertificateValidationCallback = Check; }
}
'@
}
[MrCertCheck]::Install()

# Интервалы считаем по секундомеру, а не по часам Windows: если дату переведут вперёд или назад, агент не «зависнет»
$Clock = [Diagnostics.Stopwatch]::StartNew()
function Now-Sec { return $Clock.Elapsed.TotalSeconds }

$AgentDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $AgentDir 'config.json'
$LogPath = Join-Path $AgentDir 'agent.log'

function Write-Log([string]$msg) {
  $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg
  try {
    if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 1MB) { Move-Item $LogPath "$LogPath.old" -Force }
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
  } catch { }
}

# Один экземпляр на пользователя
$mutex = New-Object System.Threading.Mutex($false, 'Local\MetallRaschetAgent')
if (-not $mutex.WaitOne(0)) { exit }

$cfg = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$secure = ConvertTo-SecureString $cfg.passwordEnc
$Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
$Interval = [Math]::Max(5, [int]$cfg.interval)

$script:Token = $null
$script:TokenTime = -1e9
$script:LastBeat = -1e9
$script:Fails = @{}
$script:Restart = $false
$script:LastJobs = -1e9

function Invoke-Api([string]$Method, [string]$Url, $Body = $null, [hashtable]$Extra = @{}, [string]$OutFile = $null) {
  $headers = @{ apikey = $cfg.key }
  if ($script:Token) { $headers['Authorization'] = "Bearer $($script:Token)" }
  foreach ($k in $Extra.Keys) { $headers[$k] = $Extra[$k] }
  $p = @{ Method = $Method; Uri = $Url; Headers = $headers; UseBasicParsing = $true; TimeoutSec = 120 }
  if ($null -ne $Body) {
    $json = $Body | ConvertTo-Json -Depth 5 -Compress
    $p['Body'] = [Text.Encoding]::UTF8.GetBytes($json)
    $p['ContentType'] = 'application/json; charset=utf-8'
  }
  if ($OutFile) { $p['OutFile'] = $OutFile; Invoke-WebRequest @p | Out-Null; return $null }
  $r = Invoke-WebRequest @p
  $bytes = $r.RawContentStream.ToArray()
  if ($bytes.Length -eq 0) { return $null }
  $text = [Text.Encoding]::UTF8.GetString($bytes)
  if (-not $text.Trim()) { return $null }
  return ($text | ConvertFrom-Json)
}

function Connect-Cloud {
  $script:Token = $null
  $r = Invoke-Api 'POST' "$($cfg.url)/auth/v1/token?grant_type=password" @{ email = $cfg.email; password = $Password }
  $script:Token = $r.access_token
  $script:TokenTime = Now-Sec
}

function Send-Heartbeat {
  $body = @{ machine = $cfg.machine; last_seen = (Get-Date).ToUniversalTime().ToString('o'); host = $env:COMPUTERNAME; folder = $cfg.folder; version = $Version }
  Invoke-Api 'POST' "$($cfg.url)/rest/v1/machine_status" $body @{ Prefer = 'resolution=merge-duplicates,return=minimal' } | Out-Null
}

function Set-JobStatus($id, [hashtable]$fields) {
  Invoke-Api 'PATCH' "$($cfg.url)/rest/v1/machine_jobs?id=eq.$id" $fields @{ Prefer = 'return=minimal' } | Out-Null
}

function Get-SafeName([string]$name) {
  $n = ($name -replace '[\\/:*?"<>|]', '_').Trim().TrimEnd('.')
  if ($n.Length -gt 150) { $n = $n.Substring(0, 150) }
  if (-not $n) { $n = 'chertezh' }
  return $n
}

function Get-FreePath([string]$dir, [string]$name) {
  $path = Join-Path $dir $name
  if (-not (Test-Path -LiteralPath $path)) { return $path }
  $base = [IO.Path]::GetFileNameWithoutExtension($name)
  $ext = [IO.Path]::GetExtension($name)
  for ($i = 2; $i -lt 1000; $i++) {
    $path = Join-Path $dir "$base ($i)$ext"
    if (-not (Test-Path -LiteralPath $path)) { return $path }
  }
  return (Join-Path $dir ("{0}_{1:HHmmss}{2}" -f $base, (Get-Date), $ext))
}

# --- значок в трее ---
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.SystemIcons]::Application
$tray.Text = "МеталлРасчёт: $($cfg.machineName)"
$tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenu
$miFolder = New-Object System.Windows.Forms.MenuItem('Открыть папку чертежей')
$miFolder.add_Click({ Start-Process explorer.exe $cfg.folder })
$miLog = New-Object System.Windows.Forms.MenuItem('Журнал агента')
$miLog.add_Click({ if (Test-Path $LogPath) { Start-Process notepad.exe $LogPath } })
$script:Quit = $false
$miExit = New-Object System.Windows.Forms.MenuItem('Выключить агента')
$miExit.add_Click({ $script:Quit = $true })
[void]$menu.MenuItems.Add($miFolder)
[void]$menu.MenuItems.Add($miLog)
[void]$menu.MenuItems.Add('-')
[void]$menu.MenuItems.Add($miExit)
$tray.ContextMenu = $menu
$tray.add_DoubleClick({ Start-Process explorer.exe $cfg.folder })

function Show-Note([string]$title, [string]$text, [string]$kind = 'Info') {
  if ($cfg.notify -eq $false) { return }
  $tray.BalloonTipIcon = $kind
  $tray.ShowBalloonTip(6000, $title, $text, $kind)
}

function Get-Drawing($job) {
  $dir = $cfg.folder
  if ($cfg.useSubfolders -and $job.subfolder) {
    # «2026-11 Ноябрь/18.11.2026 Заказ» → вложенные папки; «..» и пустые части отбрасываются
    foreach ($part in ($job.subfolder -split '[\\/]')) {
      $t = $part.Trim()
      if ($t -and $t -notmatch '^\.+$') { $dir = Join-Path $dir (Get-SafeName $t) }
    }
  }
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $tmp = Join-Path $env:TEMP ("mr_" + $job.id + ".part")
  $url = "$($cfg.url)/storage/v1/object/authenticated/drawings/$($job.storage_path)"
  Invoke-Api 'GET' $url $null @{} $tmp | Out-Null
  $dest = Get-FreePath $dir (Get-SafeName $job.file_name)
  Move-Item -LiteralPath $tmp -Destination $dest -Force
  Set-JobStatus $job.id @{ status = 'delivered'; delivered_at = (Get-Date).ToUniversalTime().ToString('o'); delivered_to = $dest; error = $null }
  Write-Log "Получен: $dest"
  return $dest
}

# ---------- Самообновление: раз в 6 часов агент проверяет новую версию на сайте и ставит её сам ----------
$DefaultSite = 'https://vladislavgildenberg7774-create.github.io/metallraschet/agent/agent.ps1'
$script:LastUpdateCheck = (Now-Sec) - 6 * 3600 + 60   # первая проверка — через минуту после запуска
function Update-Self {
  $src = if ($cfg.siteUrl) { $cfg.siteUrl } else { $DefaultSite }
  $r = Invoke-WebRequest -Uri ("{0}?v={1}" -f $src, [DateTime]::UtcNow.Ticks) -UseBasicParsing -TimeoutSec 60
  $text = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()).TrimStart([char]0xFEFF)
  if ($text -notmatch "(?m)^\`$Version = '([\d.]+)'" ) { return }
  $new = [version]$Matches[1]
  if ($new -le [version]$Version) { return }
  if ($text -notmatch 'МеталлРасчёт — агент станка') { Write-Log 'Обновление отклонено: файл не похож на агента'; return }
  $toks = $null; $errs = $null
  [void][Management.Automation.Language.Parser]::ParseInput($text, [ref]$toks, [ref]$errs)
  if ($errs -and $errs.Count) { Write-Log "Обновление $new отклонено: ошибка в файле"; return }
  $me = Join-Path $AgentDir 'agent.ps1'
  Copy-Item -LiteralPath $me -Destination "$me.bak" -Force
  [IO.File]::WriteAllText($me, $text, (New-Object System.Text.UTF8Encoding($true)))
  Write-Log "Обновление: $Version → $new, перезапуск"
  $script:Restart = $true
  $script:Quit = $true
}

# ---------- Папка станка с сайта: команды из очереди machine_cmds ----------
$Root = [IO.Path]::GetFullPath($cfg.folder).TrimEnd('\')
function Resolve-In([string]$rel) {
  $rel = "$rel".Trim().TrimStart('\', '/')
  $full = if ($rel) { [IO.Path]::GetFullPath((Join-Path $Root $rel)) } else { $Root }
  $full = $full.TrimEnd('\')
  if ($full -ne $Root -and -not $full.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Путь вне папки чертежей' }
  return $full
}
function Rel-Of([string]$full) { if ($full.Length -le $Root.Length) { return '' } return $full.Substring($Root.Length + 1) }
function Check-Name([string]$n) {
  $n = "$n".Trim()
  if (-not $n -or $n -match '[\\/:*?"<>|]' -or $n -match '^\.+$') { throw 'Недопустимое имя' }
  return $n
}
Add-Type -AssemblyName Microsoft.VisualBasic

function Run-Cmd($c) {
  $a = $c.args
  switch ($c.cmd) {
    'list' {
      $dir = Resolve-In $a.path
      if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw 'Папка не найдена' }
      $items = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::Hidden) } |
        Sort-Object @{ e = { -not $_.PSIsContainer } }, Name | Select-Object -First 2000 | ForEach-Object {
          @{ name = $_.Name; dir = [bool]$_.PSIsContainer; size = $(if ($_.PSIsContainer) { $null } else { $_.Length }); mtime = $_.LastWriteTime.ToString('dd.MM.yyyy HH:mm') }
        })
      return @{ path = (Rel-Of $dir); entries = $items }
    }
    'download' {
      $f = Resolve-In $a.path
      if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { throw 'Файл не найден' }
      if ((Get-Item -LiteralPath $f).Length -gt 50MB) { throw 'Файл больше 50 МБ' }
      $dest = "$($a.upload)"
      if ($dest -notmatch '^[0-9a-f-]{36}/[^/]+/_out/[0-9a-f-]{36}\.bin$') { throw 'Неверный путь выгрузки' }
      $headers = @{ apikey = $cfg.key; Authorization = "Bearer $($script:Token)"; 'x-upsert' = 'false' }
      Invoke-WebRequest -Method POST -Uri "$($cfg.url)/storage/v1/object/drawings/$dest" -Headers $headers -InFile $f -ContentType 'application/octet-stream' -UseBasicParsing -TimeoutSec 300 | Out-Null
      return @{ upload = $dest; name = [IO.Path]::GetFileName($f) }
    }
    'delete' {
      $f = Resolve-In $a.path
      if ($f -eq $Root) { throw 'Корневую папку удалять нельзя' }
      if (Test-Path -LiteralPath $f -PathType Container) {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($f, 'OnlyErrorDialogs', 'SendToRecycleBin')
      } elseif (Test-Path -LiteralPath $f -PathType Leaf) {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($f, 'OnlyErrorDialogs', 'SendToRecycleBin')
      } else { throw 'Не найдено' }
      return @{ deleted = (Rel-Of $f) }
    }
    'rename' {
      $f = Resolve-In $a.path
      if ($f -eq $Root) { throw 'Корневую папку переименовать нельзя' }
      $n = Check-Name $a.name
      $to = Join-Path (Split-Path -Parent $f) $n
      if (Test-Path -LiteralPath $to) { throw 'Такое имя уже есть' }
      Rename-Item -LiteralPath $f -NewName $n
      return @{ path = (Rel-Of $to) }
    }
    'move' {
      $f = Resolve-In $a.path
      if ($f -eq $Root) { throw 'Корневую папку перемещать нельзя' }
      $toDir = Resolve-In $a.to
      if (-not (Test-Path -LiteralPath $toDir -PathType Container)) { throw 'Папка назначения не найдена' }
      if ($toDir.StartsWith($f + '\', [StringComparison]::OrdinalIgnoreCase) -or $toDir -eq $f) { throw 'Нельзя переместить папку в саму себя' }
      $to = Join-Path $toDir (Split-Path -Leaf $f)
      if (Test-Path -LiteralPath $to) { throw 'Там уже есть файл с таким именем' }
      Move-Item -LiteralPath $f -Destination $to
      return @{ path = (Rel-Of $to) }
    }
    'put' {
      # файл с сайта → в открытую папку станка (сайт кладёт его во временное <фирма>/<станок>/_in/<id>.bin)
      $dir = Resolve-In $a.path
      if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw 'Папка не найдена' }
      $src = "$($a.from)"
      if ($src -notmatch '^[0-9a-f-]{36}/[^/]+/_in/[0-9a-f-]{36}\.bin$') { throw 'Неверный путь файла' }
      $n = Get-SafeName (Check-Name $a.name)
      $tmp = Join-Path $env:TEMP ("mr_put_" + $c.id + ".part")
      Invoke-Api 'GET' "$($cfg.url)/storage/v1/object/authenticated/drawings/$src" $null @{} $tmp | Out-Null
      $dest = Get-FreePath $dir $n
      Move-Item -LiteralPath $tmp -Destination $dest -Force
      return @{ path = (Rel-Of $dest); name = [IO.Path]::GetFileName($dest) }
    }
    'mkdir' {
      $parent = Resolve-In $a.path
      $n = Check-Name $a.name
      $to = Join-Path $parent $n
      New-Item -ItemType Directory -Force -Path $to | Out-Null
      return @{ path = (Rel-Of $to) }
    }
    default { throw "Неизвестная команда $($c.cmd)" }
  }
}

function Process-Cmds {
  $q = "$($cfg.url)/rest/v1/machine_cmds?select=*&machine=eq.$($cfg.machine)&status=eq.queued&order=created_at.asc&limit=10"
  $list = @()
  try { $list = @(Invoke-Api 'GET' $q) } catch {
    $code = $null; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
    if ($code -eq 404 -or $code -eq 400) { return }   # в облаке ещё нет таблицы команд
    throw
  }
  foreach ($c in $list) {
    if (-not $c) { continue }
    try {
      $res = Run-Cmd $c
      Invoke-Api 'PATCH' "$($cfg.url)/rest/v1/machine_cmds?id=eq.$($c.id)" @{ status = 'done'; result = $res; error = $null } @{ Prefer = 'return=minimal' } | Out-Null
      if ($c.cmd -ne 'list') { Write-Log "Команда с сайта: $($c.cmd) $($c.args.path) ($($c.created_by))" }
    } catch {
      $msg = "$($_.Exception.Message)"
      try { Invoke-Api 'PATCH' "$($cfg.url)/rest/v1/machine_cmds?id=eq.$($c.id)" @{ status = 'error'; error = $msg } @{ Prefer = 'return=minimal' } | Out-Null } catch { }
    }
  }
}

function Wait-Seconds([int]$sec) {
  $until = (Now-Sec) + $sec
  while ((Now-Sec) -lt $until -and -not $script:Quit) {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 200
  }
}

Write-Log "Агент $Version запущен: станок $($cfg.machine) ($($cfg.machineName)), папка $($cfg.folder)"
New-Item -ItemType Directory -Force -Path $cfg.folder | Out-Null
$wasOffline = $false

while (-not $script:Quit) {
  try {
    if (-not $script:Token -or ((Now-Sec) - $script:TokenTime) -gt 45 * 60) { Connect-Cloud }
    if (((Now-Sec) - $script:LastBeat) -ge 30) { Send-Heartbeat; $script:LastBeat = Now-Sec }
    if ($wasOffline) { Write-Log 'Связь восстановлена'; $tray.Text = "МеталлРасчёт: $($cfg.machineName)"; $wasOffline = $false }
    Process-Cmds
    if (((Now-Sec) - $script:LastUpdateCheck) -ge 6 * 3600) {
      $script:LastUpdateCheck = Now-Sec
      try { Update-Self } catch { Write-Log "Проверка обновления не удалась: $($_.Exception.Message)" }
      if ($script:Quit) { break }
    }
    if (((Now-Sec) - $script:LastJobs) -lt $Interval) { Wait-Seconds 3; continue }
    $script:LastJobs = Now-Sec
    $q = "$($cfg.url)/rest/v1/machine_jobs?select=*&machine=eq.$($cfg.machine)&status=eq.queued&order=created_at.asc&limit=20"
    $jobs = @(Invoke-Api 'GET' $q)
    $got = @()
    foreach ($j in $jobs) {
      if (-not $j) { continue }
      try {
        $got += [IO.Path]::GetFileName((Get-Drawing $j))
        $script:Fails.Remove($j.id)
      } catch {
        $n = 1 + [int]$script:Fails[$j.id]
        $script:Fails[$j.id] = $n
        Write-Log "Не удалось получить $($j.file_name) (попытка $n): $($_.Exception.Message)"
        if ($n -ge 3) {
          try { Set-JobStatus $j.id @{ status = 'error'; error = "$($_.Exception.Message)" } } catch { }
          $script:Fails.Remove($j.id)
        }
      }
    }
    if ($got.Count -eq 1) { Show-Note "Новый чертёж — $($cfg.machineName)" $got[0] }
    elseif ($got.Count -gt 1) { Show-Note "Новые чертежи — $($cfg.machineName)" ("{0} файл.: {1}" -f $got.Count, ($got -join ', ')) }
  } catch {
    $code = $null
    try { $code = [int]$_.Exception.Response.StatusCode } catch { }
    if ($code -eq 401 -or $code -eq 403) { $script:Token = $null }
    if ($code -eq 400 -and -not $script:Token) { Write-Log 'Неверный пароль агента — переустановите агента с правильным паролем.' }
    if (-not $wasOffline) { Write-Log "Нет связи с облаком: $($_.Exception.Message)"; $tray.Text = "МеталлРасчёт: нет связи"; $wasOffline = $true }
    Wait-Seconds 20
  }
  Wait-Seconds 3
}

$tray.Visible = $false
$tray.Dispose()
$mutex.ReleaseMutex()
if ($script:Restart) {
  # запускаем новую версию тем же способом, что и автозагрузка (скрытое окно)
  Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', (Join-Path $AgentDir 'agent.ps1'))
} else {
  Write-Log 'Агент выключен'
}
