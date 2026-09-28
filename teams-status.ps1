# ============================================================
# Teams status -> Home Assistant webhook
#
# Parst de lokale logbestanden van de nieuwe Microsoft Teams-client
# en stuurt bij elke statuswijziging een webhook-POST naar Home
# Assistant. Werkt zonder Microsoft Graph API-toegang of
# adminrechten -- alleen leestoegang tot je eigen Teams-logs nodig.
#
# Vereist: config.ps1 in dezelfde map (kopieer config.example.ps1).
# ============================================================

param(
    # Voer een testrun uit: stuur een reeks sample-payloads (alle statussen
    # + call-state) met 5 seconden ertussen en stop daarna. Handig om te
    # controleren of de webhook + Home Assistant-integratie werken.
    [switch]$test,

    # Draai als icoon in het systeemvak (rechtsonder naast de klok) in plaats
    # van in een consolevenster. Rechtsklik op het icoon om af te sluiten.
    [switch]$tray
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$configPath = Join-Path $PSScriptRoot "config.ps1"
if (-not (Test-Path $configPath)) {
    Write-Error "config.ps1 niet gevonden. Kopieer config.example.ps1 naar config.ps1 en vul je eigen waarden in."
    exit 1
}
. $configPath

# Verwijdert gevoelige gegevens (webhook-URL + het niet-raadbare webhook-ID)
# uit foutmeldingen, zodat ze nooit in de CLI-logs terechtkomen.
function Redact-Secret {
    param([string]$Text)
    if (-not $Text) { return $Text }

    # Het webhook-ID (het deel na /webhook/) is het echte geheim; het domein
    # is minder gevoelig maar redacten we voor de zekerheid ook.
    $webhookId = $null
    if ($webhookUrl -match '/([^/?#]+)/?$') {
        $webhookId = $Matches[1]
    }
    if ($webhookUrl) { $Text = $Text.Replace($webhookUrl, "[WEBHOOK-URL]") }
    if ($webhookId)  { $Text = $Text.Replace($webhookId,  "[WEBHOOK-ID]") }

    return $Text
}

function Get-TeamsStatus {
    param($LatestLogPath)

    $statusLine = Select-String -Path $LatestLogPath -Pattern "availability:\s*(\w+)" |
        Select-Object -Last 1

    if ($statusLine) { $statusLine.Matches[0].Groups[1].Value } else { "Unknown" }
}

function Get-TeamsCallState {
    param($LatestLogPath, $PreviousInCall)

    $callLine = Select-String -Path $LatestLogPath -Pattern "TeamsCallTracker: Call (became active|ended):" |
        Select-Object -Last 1

    # Geen call-event gevonden in dit (mogelijk net geroteerde) logbestand?
    # Dan de vorige bekende call-state behouden i.p.v. een gok te maken.
    if (-not $callLine) { return $PreviousInCall }

    return ($callLine.Line -match "became active")
}

function Send-StatusUpdate {
    param($Status, $InCall)

    $payload = @{
        status  = $Status
        in_call = $InCall
    } | ConvertTo-Json

    $params = @{
        Uri         = $webhookUrl
        Method      = "Post"
        Body        = $payload
        ContentType = "application/json"
        TimeoutSec  = 5
    }
    if ($proxyUrl) {
        $params["Proxy"] = $proxyUrl
        $params["ProxyUseDefaultCredentials"] = $true
    }

    Invoke-RestMethod @params
}

function Get-LatestTeamsLog {
    Get-ChildItem -Path $logDir -Filter "MSTeams_20*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

# Eén controle-ronde: logs lezen en bij een wijziging (of met -Force altijd)
# een update sturen. Geeft de huidige waarden terug, of $null als er geen
# logbestand is, zodat de tray-modus ze kan tonen.
function Invoke-StatusCheck {
    param($LatestLog, [switch]$Force)

    if (-not $LatestLog) { return $null }

    # --- Vorige state inlezen ---
    $lastStatus = ""
    $lastInCall = $false
    if (Test-Path $stateFile) {
        $saved = Get-Content $stateFile
        if ($saved.Count -ge 2) {
            $lastStatus = $saved[0]
            $lastInCall = [bool]::Parse($saved[1])
        }
    }

    $status = Get-TeamsStatus -LatestLogPath $LatestLog.FullName
    $inCall = Get-TeamsCallState -LatestLogPath $LatestLog.FullName -PreviousInCall $lastInCall
    $sendError = $null

    # --- Alleen versturen bij wijziging ---
    if ($Force -or $status -ne $lastStatus -or $inCall -ne $lastInCall) {
        try {
            Send-StatusUpdate -Status $status -InCall $inCall
            # State pas opslaan na een geslaagde POST, zodat een gemiste
            # wijziging (bv. door een tijdelijke netwerkstoring) bij de
            # volgende iteratie opnieuw geprobeerd wordt.
            Set-Content -Path $stateFile -Value @($status, $inCall.ToString())
        } catch {
            $sendError = Redact-Secret $_.Exception.Message
            Write-Warning "Kon status niet versturen: $sendError"
        }
    }

    return @{ Status = $status; InCall = $inCall; Error = $sendError }
}

# --- Testmodus: stuur sample-payloads en stop ---
if ($test) {
    Write-Host "Testmodus: stuur sample-payloads naar de webhook en stop daarna." -ForegroundColor Cyan
    if ($proxyUrl) { Write-Host "Proxy: $proxyUrl" }

    # Statussen zonder gesprek, daarna met gesprek.
    $samples = @(
        @{ status = "Available"; in_call = $false },
        @{ status = "Busy";     in_call = $false },
        @{ status = "Away";     in_call = $false },
        @{ status = "Available"; in_call = $true  },
        @{ status = "Busy";     in_call = $true  },
        @{ status = "Available"; in_call = $false }
    )

    foreach ($sample in $samples) {
        Write-Host ("-> status={0,-9} in_call={1}" -f $sample.status, $sample.in_call) -NoNewline
        try {
            Send-StatusUpdate -Status $sample.status -InCall $sample.in_call
            Write-Host "  [OK]" -ForegroundColor Green
        } catch {
            Write-Host "  [FOUT: $(Redact-Secret $_.Exception.Message)]" -ForegroundColor Red
        }

        # Geen sleep na het laatste sample.
        if ($sample -ne $samples[-1]) {
            Start-Sleep -Seconds 5
        }
    }

    Write-Host "Testmodus klaar." -ForegroundColor Cyan
    exit 0
}

# --- Tray-modus: icoon in het systeemvak, geen consolevenster ---
if ($tray) {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing

    # Maximaal één tray-icoon tegelijk (bv. als het script twee keer gestart wordt).
    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($true, "Local\TeamsStatusHass", [ref]$createdNew)
    if (-not $createdNew) { exit 0 }

    # Eigen consolevenster verbergen, voor als het script niet al verborgen
    # gestart is (zie README voor starten zonder zichtbaar venster). Alleen als
    # dit proces de enige gebruiker van de console is, zodat een PowerShell-
    # venster waaruit je het script handmatig start niet verdwijnt.
    try {
        Add-Type -Namespace Win32 -Name ConsoleWindow -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("kernel32.dll")] public static extern uint GetConsoleProcessList(uint[] list, uint count);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
        $hwnd = [Win32.ConsoleWindow]::GetConsoleWindow()
        $consoleProcs = [Win32.ConsoleWindow]::GetConsoleProcessList([uint32[]]::new(16), 16)
        if ($hwnd -ne [IntPtr]::Zero -and $consoleProcs -eq 1) {
            $null = [Win32.ConsoleWindow]::ShowWindow($hwnd, 0)
        }
    } catch { }

    # Gekleurd bolletje per status; wit stipje in het midden = in gesprek.
    # Iconen worden gecachet omdat GetHicon() een handle alloceert.
    $iconCache = @{}
    function Get-StatusIcon {
        param($Status, $InCall)

        $color = switch -Regex ($Status) {
            '^Available$'                                         { '#6BB700'; break }
            '^(Busy|DoNotDisturb|InACall|InAMeeting|Presenting)$' { '#C4314B'; break }
            '^(Away|BeRightBack)$'                                { '#FFAA44'; break }
            default                                               { '#8A8886' }
        }
        $key = "$color|$InCall"
        if (-not $iconCache.ContainsKey($key)) {
            $bmp = [System.Drawing.Bitmap]::new(16, 16)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $brush = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml($color))
            $g.FillEllipse($brush, 1, 1, 14, 14)
            if ($InCall) { $g.FillEllipse([System.Drawing.Brushes]::White, 5, 5, 6, 6) }
            $brush.Dispose()
            $g.Dispose()
            $iconCache[$key] = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
        }
        return $iconCache[$key]
    }

    function Update-TrayDisplay {
        param($Result)

        if (-not $Result) {
            $text = "Teams: geen logbestand gevonden"
            $notify.Icon = Get-StatusIcon -Status "Unknown" -InCall $false
        } else {
            $text = "Teams: $($Result.Status)"
            if ($Result.InCall) { $text += " (in gesprek)" }
            if ($Result.Error)  { $text += " - versturen mislukt" }
            $notify.Icon = Get-StatusIcon -Status $Result.Status -InCall $Result.InCall
        }
        # NotifyIcon.Text mag maximaal 63 tekens zijn.
        if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
        $notify.Text = $text
        $statusItem.Text = $text
    }

    $notify = [System.Windows.Forms.NotifyIcon]::new()
    $menu = [System.Windows.Forms.ContextMenuStrip]::new()
    $statusItem = $menu.Items.Add("Teams: opstarten...")
    $statusItem.Enabled = $false
    $null = $menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    $resendItem = $menu.Items.Add("Status opnieuw versturen")
    $quitItem = $menu.Items.Add("Afsluiten")
    $notify.ContextMenuStrip = $menu
    $notify.Icon = Get-StatusIcon -Status "Unknown" -InCall $false
    $notify.Text = "Teams: opstarten..."
    $notify.Visible = $true

    # In plaats van te blokkeren op de FileSystemWatcher (dat zou het menu
    # bevriezen) kijkt een timer elke 2 seconden goedkoop of het nieuwste
    # logbestand veranderd is (naam, grootte, schrijftijd). Alleen dan worden
    # de logs gelezen. Elke pollIntervalSeconds volgt sowieso een controle,
    # zodat een mislukte POST opnieuw geprobeerd wordt.
    $lastSignature = $null
    $lastCheck = [datetime]::MinValue
    $timer = [System.Windows.Forms.Timer]::new()
    $timer.Interval = 2000
    $timer.add_Tick({
        $timer.Stop()
        try {
            $log = Get-LatestTeamsLog
            $signature = if ($log) { "$($log.FullName)|$($log.Length)|$($log.LastWriteTimeUtc.Ticks)" } else { "" }
            $due = ((Get-Date) - $script:lastCheck).TotalSeconds -ge $pollIntervalSeconds
            if ($signature -ne $script:lastSignature -or $due) {
                $script:lastSignature = $signature
                $script:lastCheck = Get-Date
                Update-TrayDisplay (Invoke-StatusCheck -LatestLog $log)
            }
        } finally {
            $timer.Start()
        }
    })

    $resendItem.add_Click({
        Update-TrayDisplay (Invoke-StatusCheck -LatestLog (Get-LatestTeamsLog) -Force)
    })
    $quitItem.add_Click({
        $timer.Stop()
        $notify.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    })

    $timer.Start()
    [System.Windows.Forms.Application]::Run()

    $notify.Dispose()
    $mutex.ReleaseMutex()
    exit 0
}

Write-Host "Teams status -> Home Assistant gestart. Ctrl+C om te stoppen."

# Bestandswatcher op de Teams-logmap. In plaats van een vaste sleep wachten we
# passief op een wijziging (lagere latency, geen periodieke wake-ups). De timeout
# (pollIntervalSeconds) is alleen een veiligheidsnet voor gemiste events, bv. bij
# logrotatie: dan wordt er een nieuw bestand aangemaakt, niet alleen geschreven.
# Als de map niet bestaat (bv. de nieuwe Teams-client is nog niet geïnstalleerd)
# of de watcher niet aangemaakt kan worden, valt het script terug op polling.
$watcher = $null
if (Test-Path $logDir) {
    try {
        $watcher = [System.IO.FileSystemWatcher]::new($logDir, "MSTeams_20*.log")
        $watcher.IncludeSubdirectories = $false
        $watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor
                                [System.IO.NotifyFilters]::FileName
    } catch {
        Write-Warning "Kon geen bestandswatcher aanmaken, val terug op polling: $($_.Exception.Message)"
        $watcher = $null
    }
} else {
    Write-Warning "Logmap niet gevonden: $logDir"
}

while ($true) {
    $null = Invoke-StatusCheck -LatestLog (Get-LatestTeamsLog)

    # Wacht tot het logbestand wijzigt of roteert. Bij timeout (geen wijziging
    # binnen pollIntervalSeconds) loopt de lus gewoon door en wordt er opnieuw
    # gecheckt; dat vangt eventuele gemiste events op.
    if ($watcher) {
        $null = $watcher.WaitForChanged(
            [System.IO.WatcherChangeTypes]::All,
            $pollIntervalSeconds * 1000
        )
    } else {
        Start-Sleep -Seconds $pollIntervalSeconds
    }
}
