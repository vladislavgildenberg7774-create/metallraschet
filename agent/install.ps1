# МеталлРасчёт — установка агента станка. Этот текст встраивается в установщик .cmd, который собирает сайт.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$Url = '__URL__'
$Key = '__KEY__'
$Email = '__EMAIL__'
$Machine = '__MACHINE__'
$MachineName = '__MACHINE_NAME__'
$DefaultFolder = '__FOLDER__'
$UseSubfolders = __SUBFOLDERS__
$SiteUrl = '__SITE__'
$AgentB64 = '__AGENT_B64__'

function Say([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c }

Say ''
Say "  МеталлРасчёт — установка агента для станка «$MachineName»" 'Cyan'
Say '  Агент будет сам забирать чертежи, отправленные с сайта, и класть их в папку.' 'Gray'
Say ''

# 1. Папка для чертежей — выбор в окне (можно оставить предложенную)
Add-Type -AssemblyName System.Windows.Forms
if (-not (Test-Path -LiteralPath $DefaultFolder)) { New-Item -ItemType Directory -Force -Path $DefaultFolder | Out-Null }
$dlg = New-Object System.Windows.Forms.FolderBrowserDialog
$dlg.Description = "Куда класть чертежи для «$MachineName»? (обычно папка, которую открывает программа лазера)"
$dlg.SelectedPath = $DefaultFolder
$dlg.ShowNewFolderButton = $true
Say '  Шаг 1. Выберите папку для чертежей в открывшемся окне…' 'Yellow'
$owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
$res = $dlg.ShowDialog($owner)
$Folder = if ($res -eq [System.Windows.Forms.DialogResult]::OK -and $dlg.SelectedPath) { $dlg.SelectedPath } else { $DefaultFolder }
New-Item -ItemType Directory -Force -Path $Folder | Out-Null
Say "         Папка: $Folder" 'Green'

# 2. Пароль агента — проверяем вход
$ok = $false
for ($try = 1; $try -le 3 -and -not $ok; $try++) {
  Say ''
  $pw = Read-Host "  Шаг 2. Введите пароль агента ($Email)" -AsSecureString
  $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw))
  try {
    $body = [Text.Encoding]::UTF8.GetBytes((@{ email = $Email; password = $plain } | ConvertTo-Json -Compress))
    $r = Invoke-WebRequest -Method POST -Uri "$Url/auth/v1/token?grant_type=password" -Headers @{ apikey = $Key } -Body $body -ContentType 'application/json; charset=utf-8' -UseBasicParsing -TimeoutSec 30
    $ok = $true
    Say '         Пароль верный, связь с облаком есть.' 'Green'
  } catch {
    $code = $null
    try { $code = [int]$_.Exception.Response.StatusCode } catch { }
    if ($code -eq 400) { Say '         Неверный пароль. Попробуйте ещё раз.' 'Red' }
    else { Say "         Нет связи с облаком: $($_.Exception.Message)" 'Red'; Say '         Проверьте интернет на этом компьютере.' 'Red' }
  }
}
if (-not $ok) { Say ''; Say '  Установка прервана.' 'Red'; return }

# 3. Файлы агента
$Dir = Join-Path $env:LOCALAPPDATA 'MetallRaschetAgent'
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
# остановить уже работающего агента (переустановка)
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*MetallRaschetAgent*agent.ps1*' } |
  ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
Start-Sleep -Milliseconds 500

$utf8bom = New-Object System.Text.UTF8Encoding($true)
$agentText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($AgentB64))
[IO.File]::WriteAllText((Join-Path $Dir 'agent.ps1'), $agentText, $utf8bom)

$config = [ordered]@{
  url = $Url; key = $Key; email = $Email
  passwordEnc = (ConvertFrom-SecureString $pw)   # зашифровано для этого пользователя Windows
  machine = $Machine; machineName = $MachineName
  folder = $Folder; useSubfolders = $UseSubfolders
  interval = 10; notify = $true
  siteUrl = $SiteUrl   # отсюда агент сам скачивает новые версии
}
[IO.File]::WriteAllText((Join-Path $Dir 'config.json'), ($config | ConvertTo-Json), $utf8bom)

# 4. Автозапуск при входе в Windows (без прав администратора) — скрытое окно
$agentPath = Join-Path $Dir 'agent.ps1'
$vbsText = "CreateObject(""WScript.Shell"").Run ""powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """"$agentPath"""""", 0, False"
$startup = [Environment]::GetFolderPath('Startup')
$vbs = Join-Path $startup 'MetallRaschetAgent.vbs'
[IO.File]::WriteAllText($vbs, $vbsText, [Text.Encoding]::Unicode)

# удаление агента
$unPs = @"
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { `$_.CommandLine -like '*MetallRaschetAgent*agent.ps1*' } | ForEach-Object { Stop-Process -Id `$_.ProcessId -Force }
Remove-Item -LiteralPath '$vbs' -Force -ErrorAction SilentlyContinue
Write-Host 'Агент удалён и больше не запускается. Папка с чертежами осталась на месте.'
"@
[IO.File]::WriteAllText((Join-Path $Dir 'uninstall.ps1'), $unPs, $utf8bom)
[IO.File]::WriteAllText((Join-Path $Dir 'uninstall.cmd'), "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File ""%~dp0uninstall.ps1""`r`npause`r`n", [Text.Encoding]::ASCII)

# 5. Запуск
Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $vbs + '"')
Start-Sleep -Seconds 3

Say ''
Say '  ✓ Готово! Агент работает и будет запускаться сам при включении компьютера.' 'Green'
Say "    Станок:  $MachineName" 'Gray'
Say "    Папка:   $Folder" 'Gray'
Say '    Значок агента — в трее у часов (двойной клик открывает папку).' 'Gray'
Say '    На сайте в окне «📤 На станок» у этого станка загорится зелёная точка «на связи».' 'Gray'
Say "    Удалить агента: $Dir\uninstall.cmd" 'DarkGray'
Say ''
