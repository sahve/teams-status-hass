# ============================================================
# Installatie van Teams status -> Home Assistant
#
#   powershell.exe -ExecutionPolicy Bypass -File .\install.ps1
#   powershell.exe -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
#
# Doet: bestanden deblokkeren, config.ps1 aanmaken (webhook-URL vragen,
# proxy automatisch detecteren), een taak aanmaken die bij aanmelden
# onzichtbaar start met tray-icoon, en die taak meteen starten.
# Geen adminrechten nodig.
# ============================================================
 
param(
    [switch]$Uninstall
)
 
$ErrorActionPreference = "Stop"
$dir        = $PSScriptRoot
$script     = Join-Path $dir "teams-status.ps1"
$configPath = Join-Path $dir "config.ps1"
$taskName   = "Teams status HA"
$startupLnk = Join-Path ([Environment]::GetFolderPath("Startup")) "Teams status HA.lnk"
$userId     = "$env:USERDOMAIN\$env:USERNAME"
 
function Stop-RunningInstance {
    # Stopt een draaiend exemplaar (taak of los gestart).
    try { Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue } catch { }
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*teams-status.ps1*" -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
 
if ($Uninstall) {
    Stop-RunningInstance
    try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    Remove-Item $startupLnk -ErrorAction SilentlyContinue
    Write-Host "Verwijderd: taak/snelkoppeling '$taskName'. config.ps1 en de scripts zijn blijven staan." -ForegroundColor Green
    exit 0
}
 
if (-not (Test-Path $script)) {
    Write-Error "teams-status.ps1 niet gevonden in $dir"
}
 
# --- 1. Bestanden deblokkeren (Mark-of-the-Web van een zip-download) ---
Get-ChildItem $dir -File | Unblock-File
Write-Host "[1/4] Bestanden gedeblokkeerd." -ForegroundColor Cyan
 
# --- 2. config.ps1 ---
if (Test-Path $configPath) {
    Write-Host "[2/4] config.ps1 bestaat al, die laat ik ongemoeid." -ForegroundColor Cyan
} else {
    Write-Host "[2/4] config.ps1 aanmaken." -ForegroundColor Cyan
    do {
        $url = Read-Host "  Webhook-URL (https://<jouw-ha-domein>/api/webhook/<id>)"
    } until ($url -match '^https?://.+/api/webhook/[^/]+/?$')
 
    $proxy = ""
    $detected = ([System.Net.WebRequest]::GetSystemWebProxy()).GetProxy("https://example.com")
    if ($detected.Host -ne "example.com") {
        $proxy = "$($detected.Scheme)://$($detected.Authority)"
        Write-Host "  Proxy gedetecteerd: $proxy"
    } else {
        Write-Host "  Geen proxy gedetecteerd."
    }
 
    $example = Join-Path $dir "config.example.ps1"
    $content = Get-Content $example -Raw
    $content = $content -replace '(?m)^\$webhookUrl\s*=.*$', ('$webhookUrl = "' + $url + '"')
    $content = $content -replace '(?m)^\$proxyUrl\s*=.*$',   ('$proxyUrl = "' + $proxy + '"')
    Set-Content -Path $configPath -Value $content -Encoding UTF8
    Write-Host "  config.ps1 geschreven."
}
 
# --- 3. Autostart ---
Stop-RunningInstance
$arguments = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script`" -tray"
$registered = $false
try {
    $action    = New-ScheduledTaskAction -Execute "conhost.exe" -Argument $arguments -WorkingDirectory $dir
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $userId
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
    $null = Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
                -Settings $settings -Principal $principal -Force
    Remove-Item $startupLnk -ErrorAction SilentlyContinue
    $registered = $true
    Write-Host "[3/4] Taak '$taskName' aangemaakt (start bij aanmelden)." -ForegroundColor Cyan
} catch {
    # Mag je geen taken aanmaken? Dan een snelkoppeling in de map Opstarten.
    Write-Host "[3/4] Taak aanmaken mislukt ($($_.Exception.Message)); ik maak een snelkoppeling in Opstarten." -ForegroundColor Yellow
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($startupLnk)
    $lnk.TargetPath = "conhost.exe"
    $lnk.Arguments = $arguments
    $lnk.WorkingDirectory = $dir
    $lnk.Save()
}
 
# --- 4. Nu starten ---
if ($registered) {
    Start-ScheduledTask -TaskName $taskName
} else {
    Start-Process -FilePath "conhost.exe" -ArgumentList $arguments -WorkingDirectory $dir
}
Write-Host "[4/4] Gestart. Je ziet nu een bolletje naast de klok (evt. onder het ^-pijltje)." -ForegroundColor Green
Write-Host ""
Write-Host "Testen zonder je echte status: powershell.exe -ExecutionPolicy Bypass -File `"$script`" -test"
Write-Host "Verwijderen:                   powershell.exe -ExecutionPolicy Bypass -File `"$(Join-Path $dir 'install.ps1')`" -Uninstall"