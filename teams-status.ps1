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
 
    # Toon een icoontje in het systeemvak (naast de klok) met de huidige
    # status, met een rechtsklikmenu om het script af te sluiten.
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
 
# Incrementeel lezen van het Teams-log: we onthouden tot welke byte we gelezen
# hebben en lezen bij elke check alleen wat er sindsdien bij is gekomen. Bij een
# nieuw logbestand (rotatie) of een kleiner geworden bestand beginnen we vooraan.
$script:tail = @{ Path = $null; Offset = 0L; Status = "Unknown"; InCall = $null }
 
function Update-FromLog {
    param([string]$Path)
 
    if ($script:tail.Path -ne $Path) {
        # Nieuw logbestand: vanaf het begin lezen. Status en call-state van het
        # vorige bestand houden we vast tot het nieuwe bestand iets anders zegt.
        $script:tail.Path = $Path
        $script:tail.Offset = 0L
    }
 
    # Teams houdt het bestand open, dus delen met ReadWrite (en Delete, zodat
    # we Teams' logrotatie niet blokkeren).
    $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    try {
        $len = $fs.Length
        if ($len -lt $script:tail.Offset) { $script:tail.Offset = 0L }
        if ($len -eq $script:tail.Offset) { return }
 
        $null = $fs.Seek($script:tail.Offset, [System.IO.SeekOrigin]::Begin)
        $count = [int]($len - $script:tail.Offset)
        $buf = New-Object byte[] $count
        $read = 0
        while ($read -lt $count) {
            $n = $fs.Read($buf, $read, $count - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        if ($read -le 0) { return }
 
        # Alleen complete regels verwerken; een half geschreven laatste regel
        # pakken we de volgende keer mee.
        $lastNewline = [Array]::LastIndexOf($buf, [byte]10, $read - 1)
        if ($lastNewline -lt 0) { return }
 
        $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $lastNewline + 1)
        $script:tail.Offset += $lastNewline + 1
    } finally {
        $fs.Dispose()
    }
 
    $statusMatches = [regex]::Matches($text, 'availability:\s*(\w+)')
    if ($statusMatches.Count -gt 0) {
        $script:tail.Status = $statusMatches[$statusMatches.Count - 1].Groups[1].Value
    }
 
    $callMatches = [regex]::Matches($text, 'TeamsCallTracker: Call (became active|ended):')
    if ($callMatches.Count -gt 0) {
        $script:tail.InCall = ($callMatches[$callMatches.Count - 1].Groups[1].Value -eq 'became active')
    }
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
 
# Leest de laatste status uit de logs en stuurt 'm naar HA als hij gewijzigd is.
# Geeft een object terug met de status, call-state en of het versturen lukte.
function Invoke-StatusCheck {
    $latestLog = Get-ChildItem -Path $logDir -Filter "MSTeams_20*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latestLog) { return $null }
 
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
 
    Update-FromLog -Path $latestLog.FullName
    $status = $script:tail.Status
    # Nog geen call-event gezien? Dan de laatst bekende call-state aanhouden.
    $inCall = if ($null -ne $script:tail.InCall) { $script:tail.InCall } else { $lastInCall }
    $ok = $true
 
    # --- Alleen versturen bij wijziging ---
    if ($status -ne $lastStatus -or $inCall -ne $lastInCall) {
        try {
            Send-StatusUpdate -Status $status -InCall $inCall
            # State pas opslaan na een geslaagde POST, zodat een gemiste
            # wijziging (bv. door een tijdelijke netwerkstoring) bij de
            # volgende iteratie opnieuw geprobeerd wordt.
            Set-Content -Path $stateFile -Value @($status, $inCall.ToString())
        } catch {
            Write-Warning "Kon status niet versturen: $(Redact-Secret $_.Exception.Message)"
            $ok = $false
        }
    }
 
    [pscustomobject]@{
        Status  = $status
        InCall  = $inCall
        Ok      = $ok
    }
}
 
# --- Tray-modus: icoontje naast de klok ---
if ($tray) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
 
    # Maakt een 16x16 icoon met een gekleurd rondje.
    function New-DotIcon([System.Drawing.Color]$Color) {
        $bmp = New-Object System.Drawing.Bitmap 16, 16
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $brush = New-Object System.Drawing.SolidBrush $Color
        $g.FillEllipse($brush, 1, 1, 14, 14)
        $g.Dispose(); $brush.Dispose()
        [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    }
 
    $icons = @{
        Green  = New-DotIcon ([System.Drawing.Color]::FromArgb(146, 195, 83))
        Red    = New-DotIcon ([System.Drawing.Color]::FromArgb(196, 49, 75))
        Yellow = New-DotIcon ([System.Drawing.Color]::FromArgb(252, 209, 22))
        Grey   = New-DotIcon ([System.Drawing.Color]::FromArgb(140, 140, 140))
    }
 
    $script:notify = New-Object System.Windows.Forms.NotifyIcon
    $script:notify.Icon = $icons.Grey
    $script:notify.Text = "Teams -> HA: starten..."
    $script:notify.Visible = $true
 
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $null = $menu.Items.Add("Nu opnieuw versturen", $null, {
        # State-file weg = volgende check stuurt de status sowieso opnieuw.
        Remove-Item $stateFile -ErrorAction SilentlyContinue
    })
    $null = $menu.Items.Add("Afsluiten", $null, {
        $script:notify.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    })
    $script:notify.ContextMenuStrip = $menu
 
 
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 3000
    $timer.Add_Tick({
        try {
            # Elke tick: alleen de nieuwe bytes van het log lezen (goedkoop).
            $r = Invoke-StatusCheck
            if (-not $r) {
                $script:notify.Icon = $icons.Grey
                $script:notify.Text = "Teams -> HA: geen Teams-logs gevonden"
                return
            }
 
            $icon = switch -Regex ($r.Status) {
                '^Available$'                        { $icons.Green }
                '^(Busy|DoNotDisturb|Presenting)$'   { $icons.Red }
                '^(Away|BeRightBack)$'               { $icons.Yellow }
                default                              { $icons.Grey }
            }
            if ($r.InCall) { $icon = $icons.Red }
 
            $text = "Teams: $($r.Status)"
            if ($r.InCall) { $text += " (in gesprek)" }
            if (-not $r.Ok) { $text += " - versturen mislukt"; $icon = $icons.Grey }
            if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
 
            $script:notify.Icon = $icon
            $script:notify.Text = $text
        } catch {
            $script:notify.Icon = $icons.Grey
            $script:notify.Text = "Teams -> HA: fout, zie log"
        }
    })
 
    $timer.Start()
    [System.Windows.Forms.Application]::Run()
 
    $timer.Stop()
    $script:notify.Dispose()
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
    $null = Invoke-StatusCheck
 
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
 