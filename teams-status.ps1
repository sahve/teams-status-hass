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

# TLS 1.2 toevoegen aan (niet: in plaats van) de standaardprotocollen, zodat
# TLS 1.3 beschikbaar blijft waar het systeem dat ondersteunt.
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$configPath = Join-Path $PSScriptRoot "config.ps1"
if (-not (Test-Path $configPath)) {
    Write-Error "config.ps1 niet gevonden. Kopieer config.example.ps1 naar config.ps1 en vul je eigen waarden in."
    exit 1
}
. $configPath

# Standaardwaarden voor instellingen die in een oudere config.ps1 ontbreken.
if ($null -eq $logDir)              { $logDir = "$env:LocalAppData\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs" }
if ($null -eq $pollIntervalSeconds) { $pollIntervalSeconds = 15 }
if ($null -eq $heartbeatMinutes)    { $heartbeatMinutes = 5 }
if ($null -eq $teamsProcessName)    { $teamsProcessName = "ms-teams" }

# Hoe vaak (in milliseconden) de logs gecontroleerd worden. Dat is goedkoop:
# alleen de nieuw geschreven regels worden gelezen.
$checkIntervalMs = 2000

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

function Get-TeamsLogs {
    Get-ChildItem -Path $logDir -Filter "MSTeams_20*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
}

function Test-TeamsRunning {
    if (-not $teamsProcessName) { return $true }
    return [bool](Get-Process -Name $teamsProcessName -ErrorAction SilentlyContinue)
}

# --- Log-lezer -------------------------------------------------------------
# Houdt bij tot waar het huidige logbestand gelezen is, zodat bij elke
# controle alleen de nieuwe regels gelezen worden in plaats van het hele
# (vaak meerdere MB grote) bestand.
$script:logPath   = $null
$script:logOffset = 0L

# Laatst bekende waarden uit de logs. Die blijven behouden als Teams naar een
# nieuw logbestand overschakelt: zo'n vers bestand bevat vaak nog geen
# status- of call-regel.
$script:teamsStatus = "Unknown"
$script:teamsInCall = $false

function Read-NewLogLines {
    param($LogFile)

    # Nieuw logbestand (rotatie) of ingekort bestand: vooraan beginnen.
    if ($LogFile.FullName -ne $script:logPath -or $LogFile.Length -lt $script:logOffset) {
        $script:logPath   = $LogFile.FullName
        $script:logOffset = 0L
    }
    if ($LogFile.Length -le $script:logOffset) { return @() }

    # FileShare.ReadWrite: Teams heeft het bestand open om naar te schrijven.
    $stream = [System.IO.File]::Open($LogFile.FullName, 'Open', 'Read', 'ReadWrite')
    try {
        $null = $stream.Seek($script:logOffset, 'Begin')
        $buffer = [System.IO.MemoryStream]::new()
        $stream.CopyTo($buffer)
        $bytes = $buffer.ToArray()
    } finally {
        $stream.Dispose()
    }

    # Alleen volledige regels verwerken; een half geschreven laatste regel
    # wordt bij de volgende controle opnieuw gelezen.
    $end = [Array]::LastIndexOf($bytes, [byte]10)
    if ($end -lt 0) { return @() }
    $script:logOffset += $end + 1

    return [System.Text.Encoding]::UTF8.GetString($bytes, 0, $end + 1) -split "`r?`n"
}

# Verwerkt logregels, bv.:
#   ... { availability: Busy, unread notification count: 1 }
#   ... TeamsCallTracker: Call became active: <call-id> (total: 1)
#   ... TeamsCallTracker: Call ended: <call-id> (remaining: 0)
function Update-TeamsState {
    param([string[]]$Lines)
    if (-not $Lines) { return }

    # Eerst snel filteren (werkt op de hele array tegelijk), dan pas per regel.
    foreach ($line in ($Lines -match 'availability:|TeamsCallTracker: Call ')) {
        if ($line -match 'availability:\s*(\w+)') {
            $script:teamsStatus = $Matches[1]
        } elseif ($line -match 'TeamsCallTracker: Call (?:became active|ended):.*\((?:total|remaining):\s*(\d+)\)') {
            # Aantal lopende gesprekken gebruiken, zodat het beëindigen van
            # één van meerdere gesprekken (wacht, doorverbinden) niet als
            # "niet meer in gesprek" telt.
            $script:teamsInCall = [int]$Matches[1] -gt 0
        } elseif ($line -match 'TeamsCallTracker: Call (became active|ended):') {
            $script:teamsInCall = $Matches[1] -eq 'became active'
        }
    }
}

# Bij de allereerste controle: als het nieuwste logbestand nog geen
# status-regel bevat (net geroteerd), de laatste status uit het vorige
# logbestand halen i.p.v. "Unknown" te melden.
function Initialize-FromPreviousLog {
    param($PreviousLog)

    if ($script:teamsStatus -ne "Unknown" -or -not $PreviousLog) { return }
    $statusLine = Select-String -Path $PreviousLog.FullName -Pattern "availability:\s*(\w+)" |
        Select-Object -Last 1
    if ($statusLine) { $script:teamsStatus = $statusLine.Matches[0].Groups[1].Value }
}

# --- Versturen ---------------------------------------------------------------
# Laatst succesvol verstuurde waarden (alleen in het geheugen: bij het
# opstarten wordt de status altijd één keer verstuurd).
$script:sentStatus   = $null
$script:sentInCall   = $null
$script:lastSendTime = [datetime]::MinValue
$script:lastFailTime = [datetime]::MinValue
$script:lastError    = $null
$script:initialized  = $false

# Eén controle-ronde: logs bijwerken en een update sturen bij een wijziging,
# als de heartbeat verlopen is, of met -Force altijd. Geeft de huidige waarden
# terug, zodat de tray-modus ze kan tonen.
function Invoke-StatusCheck {
    param([switch]$Force)

    if (Test-TeamsRunning) {
        $logs = @(Get-TeamsLogs)
        if ($logs.Count -gt 0) {
            try {
                Update-TeamsState (Read-NewLogLines $logs[0])
                if (-not $script:initialized) {
                    $script:initialized = $true
                    if ($logs.Count -gt 1) { Initialize-FromPreviousLog $logs[1] }
                }
            } catch {
                Write-Warning "Kon logbestand niet lezen: $($_.Exception.Message)"
            }
        }
        $status = $script:teamsStatus
        $inCall = $script:teamsInCall
    } else {
        # Teams is afgesloten of gecrasht. Er komt dan nooit meer een
        # "Call ended"-regel, dus de call-state hier resetten zodat die niet
        # op 'true' blijft hangen.
        $script:teamsInCall = $false
        $status = "Offline"
        $inCall = $false
    }

    $now = Get-Date
    $changed = $status -ne $script:sentStatus -or $inCall -ne $script:sentInCall
    $heartbeatDue = $heartbeatMinutes -gt 0 -and
        ($now - $script:lastSendTime).TotalMinutes -ge $heartbeatMinutes
    # Na een mislukte poging pas na pollIntervalSeconds opnieuw proberen, zodat
    # een onbereikbare HA niet bij elke controle een time-out van 5 s kost.
    $waitForRetry = $script:lastError -and
        ($now - $script:lastFailTime).TotalSeconds -lt $pollIntervalSeconds

    if ($Force -or (($changed -or $heartbeatDue) -and -not $waitForRetry)) {
        try {
            Send-StatusUpdate -Status $status -InCall $inCall
            $script:sentStatus   = $status
            $script:sentInCall   = $inCall
            $script:lastSendTime = $now
            $script:lastError    = $null
        } catch {
            $script:lastError    = Redact-Secret $_.Exception.Message
            $script:lastFailTime = $now
            Write-Warning "Kon status niet versturen: $($script:lastError)"
        }
    }

    return @{ Status = $status; InCall = $inCall; Error = $script:lastError }
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

if (-not (Test-Path $logDir)) {
    Write-Warning "Logmap niet gevonden: $logDir"
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

        $text = "Teams: $($Result.Status)"
        if ($Result.InCall) { $text += " (in gesprek)" }
        if ($Result.Error)  { $text += " - versturen mislukt" }
        $notify.Icon = Get-StatusIcon -Status $Result.Status -InCall $Result.InCall

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

    # Een Forms-timer i.p.v. een blokkerende lus, zodat het menu blijft reageren.
    $timer = [System.Windows.Forms.Timer]::new()
    $timer.Interval = $checkIntervalMs
    $timer.add_Tick({
        $timer.Stop()
        try {
            Update-TrayDisplay (Invoke-StatusCheck)
        } finally {
            $timer.Start()
        }
    })

    $resendItem.add_Click({
        Update-TrayDisplay (Invoke-StatusCheck -Force)
    })
    $quitItem.add_Click({
        $timer.Stop()
        $notify.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    })

    Update-TrayDisplay (Invoke-StatusCheck)
    $timer.Start()
    [System.Windows.Forms.Application]::Run()

    $notify.Dispose()
    $mutex.ReleaseMutex()
    exit 0
}

# --- Consolemodus ---
Write-Host "Teams status -> Home Assistant gestart. Ctrl+C om te stoppen."

while ($true) {
    $null = Invoke-StatusCheck
    Start-Sleep -Milliseconds $checkIntervalMs
}
