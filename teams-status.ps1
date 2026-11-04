# ============================================================
# Teams status -> Home Assistant webhook
#
# Leest de lokale logbestanden van de nieuwe Microsoft Teams-client
# en het Windows-register (welke app gebruikt microfoon/camera) en
# stuurt bij elke wijziging, plus periodiek als hartslag, een
# webhook-POST naar Home Assistant. Werkt zonder Microsoft Graph
# API-toegang of adminrechten.
#
# Vereist: config.ps1 in dezelfde map (kopieer config.example.ps1,
# of draai install.ps1).
#
# Gebruik:
#   teams-status.ps1          console-modus (debuggen, Ctrl+C stopt)
#   teams-status.ps1 -tray    icoon naast de klok (normaal gebruik)
#   teams-status.ps1 -test    stuur sample-payloads en stop
# ============================================================
 
param(
    # Stuur een reeks sample-payloads met 5 seconden ertussen en stop daarna.
    [switch]$test,
 
    # Toon een statusicoon in het systeemvak (naast de klok), met menu.
    [switch]$tray
)
 
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
 
# --- Standaardwaarden; kunnen in config.ps1 overschreven worden ---
$proxyUrl             = ""
$logDir               = "$env:LocalAppData\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs"
$checkIntervalSeconds = 3      # hoe vaak logs + register gecheckt worden
$heartbeatSeconds     = 60     # ook zonder wijziging elke zoveel seconden versturen
$retrySeconds         = 30     # wachttijd na een mislukte verzending
$logFile              = "$env:TEMP\teams_ha.log"
$teamsProcessName     = "ms-teams"
$helpUrl              = "https://github.com/sahve/teams-status-hass#readme"
 
$configPath = Join-Path $PSScriptRoot "config.ps1"
if (-not (Test-Path $configPath)) {
    Write-Error "config.ps1 niet gevonden. Draai install.ps1, of kopieer config.example.ps1 naar config.ps1 en vul je eigen waarden in."
    exit 1
}
. $configPath
 
# ============================================================
# Hulpfuncties: redactie en logging
# ============================================================
 
# Verwijdert de webhook-URL en het webhook-ID uit tekst, zodat ze nooit in
# logs of foutmeldingen terechtkomen.
function Redact-Secret {
    param([string]$Text)
    if (-not $Text) { return $Text }
    $webhookId = $null
    if ($webhookUrl -match '/([^/?#]+)/?$') { $webhookId = $Matches[1] }
    if ($webhookUrl) { $Text = $Text.Replace($webhookUrl, "[WEBHOOK-URL]") }
    if ($webhookId)  { $Text = $Text.Replace($webhookId,  "[WEBHOOK-ID]") }
    return $Text
}
 
# Schrijft naar console en naar een logbestand van max. ~1 MB (daarna
# wordt het oude bestand hernoemd naar .old).
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $Level, (Redact-Secret $Message)
    Write-Host $line
    if (-not $logFile) { return }
    try {
        if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 1MB) {
            Move-Item -Path $logFile -Destination "$logFile.old" -Force
        }
        Add-Content -Path $logFile -Value $line
    } catch { }
}
 
# ============================================================
# Bron 1: Teams-logs (status + call-state), incrementeel gelezen
# ============================================================
 
# We onthouden tot welke byte we gelezen hebben en lezen bij elke check alleen
# wat er sindsdien bij is gekomen. Bij een nieuw logbestand (rotatie) of een
# kleiner geworden bestand beginnen we vooraan.
$script:tail = @{ Path = $null; Offset = 0L; Status = "Unknown"; InCall = $false }
 
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
 
# ============================================================
# Bron 2: Windows-register (welke app gebruikt microfoon/camera)
# ============================================================
 
# Windows houdt per app bij wanneer die microfoon/camera gebruikte. Staat
# LastUsedTimeStart op een waarde en LastUsedTimeStop op 0, dan is de app
# het apparaat nu aan het gebruiken. Packaged apps (Store/MSIX, zoals de
# nieuwe Teams) staan direct onder de capability; gewone .exe's onder
# NonPackaged, met het pad als sleutelnaam (\ vervangen door #).
$appNames = @{
    'MSTeams'              = 'Teams'
    'ms-teams.exe'         = 'Teams'
    'Teams.exe'            = 'Teams'
    'Zoom.exe'             = 'Zoom'
    'CptHost.exe'          = 'Zoom'
    'webex.exe'            = 'Webex'
    'CiscoCollabHost.exe'  = 'Webex'
    'atmgr.exe'            = 'Webex'
    'chrome.exe'           = 'Chrome'
    'msedge.exe'           = 'Edge'
    'msedgewebview2.exe'   = 'Edge'
    'firefox.exe'          = 'Firefox'
    'slack.exe'            = 'Slack'
    'Discord.exe'          = 'Discord'
    'WhatsAppDesktop'      = 'WhatsApp'
    'WindowsCamera'        = 'Camera'
    'WindowsSoundRecorder' = 'Geluidsrecorder'
}
 
function Get-FriendlyAppName {
    param([string]$Key)
    if ($Key -match '#') {
        # NonPackaged: C:#Program Files#Zoom#bin#Zoom.exe -> Zoom.exe
        $name = ($Key -split '#')[-1]
    } else {
        # Packaged: Publisher.AppName_hash -> AppName
        $name = (($Key -split '_')[0] -split '\.')[-1]
    }
    if ($appNames.ContainsKey($name)) { return $appNames[$name] }
    return ($name -replace '\.exe$', '')
}
 
function Get-DeviceApps {
    param([string]$Capability)   # 'microphone' of 'webcam'
 
    $path = "Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$Capability"
    $root = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path)
    if (-not $root) { return ,@() }
 
    $apps = New-Object System.Collections.Generic.List[string]
 
    function Test-InUse($Parent, [string]$Name) {
        $k = $Parent.OpenSubKey($Name)
        if (-not $k) { return $false }
        try {
            $start = [int64]$k.GetValue('LastUsedTimeStart', 0)
            $stop  = [int64]$k.GetValue('LastUsedTimeStop', 0)
            return ($start -gt 0 -and $stop -eq 0)
        } finally { $k.Close() }
    }
 
    try {
        foreach ($name in $root.GetSubKeyNames()) {
            if ($name -eq 'NonPackaged') {
                $np = $root.OpenSubKey($name)
                if (-not $np) { continue }
                try {
                    foreach ($n in $np.GetSubKeyNames()) {
                        if (Test-InUse $np $n) { $apps.Add((Get-FriendlyAppName $n)) }
                    }
                } finally { $np.Close() }
            } elseif (Test-InUse $root $name) {
                $apps.Add((Get-FriendlyAppName $name))
            }
        }
    } finally { $root.Close() }
 
    return ,@($apps | Sort-Object -Unique)
}
 
# ============================================================
# Samenvoegen en versturen
# ============================================================
 
function Get-CurrentState {
    $teamsRunning = [bool](Get-Process -Name $teamsProcessName -ErrorAction SilentlyContinue)
 
    $latestLog = Get-ChildItem -Path $logDir -Filter "MSTeams_20*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latestLog) {
        try { Update-FromLog -Path $latestLog.FullName }
        catch { Write-Log "Kon Teams-log niet lezen: $($_.Exception.Message)" "WARN" }
    }
 
    if ($teamsRunning) {
        $status = $script:tail.Status
        $inCall = [bool]$script:tail.InCall
    } else {
        # Teams is dicht: de logs zeggen dan niets meer over het nu.
        $status = "Offline"
        $inCall = $false
        $script:tail.InCall = $false
    }
 
    $mic = Get-DeviceApps 'microphone'
    $cam = Get-DeviceApps 'webcam'
 
    [ordered]@{
        status     = $status
        in_call    = $inCall
        mic_in_use = ($mic.Count -gt 0)
        camera_on  = ($cam.Count -gt 0)
        mic_app    = ($mic -join ', ')
        camera_app = ($cam -join ', ')
    }
}
 
function Send-Payload {
    param([string]$Json)
    $params = @{
        Uri         = $webhookUrl
        Method      = "Post"
        Body        = [System.Text.Encoding]::UTF8.GetBytes($Json)
        ContentType = "application/json; charset=utf-8"
        TimeoutSec  = 5
    }
    if ($proxyUrl) {
        $params["Proxy"] = $proxyUrl
        $params["ProxyUseDefaultCredentials"] = $true
    }
    $null = Invoke-RestMethod @params
}
 
function Send-Offline {
    param([string]$Reason = "afgesloten")
    $json = [ordered]@{
        status = "Offline"; in_call = $false; mic_in_use = $false
        camera_on = $false; mic_app = ""; camera_app = ""
    } | ConvertTo-Json -Compress
    try {
        Send-Payload -Json $json
        Write-Log "Offline verstuurd ($Reason)"
    } catch {
        Write-Log "Kon Offline niet versturen ($Reason): $($_.Exception.Message)" "WARN"
    }
}
 
$script:lastPayload = $null
$script:lastSent    = [datetime]::MinValue
$script:nextAttempt = [datetime]::MinValue
$script:lastOk      = $true
 
# Haalt de huidige state op en verstuurt 'm bij een wijziging, of als de
# hartslag verlopen is. Geeft de state terug (plus 'ok' = laatste verzending
# gelukt) voor het tray-icoon.
function Invoke-StatusCheck {
    $state = Get-CurrentState
    $json  = $state | ConvertTo-Json -Compress
    $now   = Get-Date
 
    $changed      = $json -ne $script:lastPayload
    $heartbeatDue = ($now - $script:lastSent).TotalSeconds -ge $heartbeatSeconds
 
    if (($changed -or $heartbeatDue) -and $now -ge $script:nextAttempt) {
        try {
            Send-Payload -Json $json
            if ($changed) { Write-Log "Verstuurd: $json" }
            $script:lastPayload = $json
            $script:lastSent    = $now
            $script:lastOk      = $true
        } catch {
            Write-Log "Kon status niet versturen: $($_.Exception.Message)" "WARN"
            $script:lastOk      = $false
            $script:nextAttempt = $now.AddSeconds($retrySeconds)
        }
    }
 
    $state['ok'] = $script:lastOk
    return $state
}
 
# Forceert dat de volgende check sowieso verstuurt.
function Reset-SendState {
    $script:lastPayload = $null
    $script:nextAttempt = [datetime]::MinValue
}
 
# ============================================================
# Testmodus
# ============================================================
 
if ($test) {
    Write-Host "Testmodus: stuur sample-payloads naar de webhook en stop daarna." -ForegroundColor Cyan
    Write-Host "Let op: HA antwoordt ook OK op een onbekend webhook-ID; controleer de waarden in HA." -ForegroundColor DarkGray
    if ($proxyUrl) { Write-Host "Proxy: $proxyUrl" }
 
    $samples = @(
        [ordered]@{ status = "Available"; in_call = $false; mic_in_use = $false; camera_on = $false; mic_app = "";      camera_app = "" },
        [ordered]@{ status = "Busy";      in_call = $true;  mic_in_use = $true;  camera_on = $false; mic_app = "Teams"; camera_app = "" },
        [ordered]@{ status = "Busy";      in_call = $true;  mic_in_use = $true;  camera_on = $true;  mic_app = "Teams"; camera_app = "Teams" },
        [ordered]@{ status = "Away";      in_call = $false; mic_in_use = $true;  camera_on = $false; mic_app = "Zoom";  camera_app = "" },
        [ordered]@{ status = "Available"; in_call = $false; mic_in_use = $false; camera_on = $false; mic_app = "";      camera_app = "" }
    )
 
    for ($i = 0; $i -lt $samples.Count; $i++) {
        $json = $samples[$i] | ConvertTo-Json -Compress
        Write-Host "-> $json" -NoNewline
        try {
            Send-Payload -Json $json
            Write-Host "  [OK]" -ForegroundColor Green
        } catch {
            Write-Host "  [FOUT: $(Redact-Secret $_.Exception.Message)]" -ForegroundColor Red
        }
        if ($i -lt $samples.Count - 1) { Start-Sleep -Seconds 5 }
    }
 
    Write-Host "Testmodus klaar." -ForegroundColor Cyan
    exit 0
}
 
# ============================================================
# Maar één exemplaar tegelijk
# ============================================================
 
$createdNew = $false
$script:mutex = [System.Threading.Mutex]::new($true, "Local\TeamsStatusHA", [ref]$createdNew)
if (-not $createdNew) {
    Write-Log "Er draait al een exemplaar; deze start wordt overgeslagen."
    exit 0
}
 
# ============================================================
# Tray-modus
# ============================================================
 
if ($tray) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
 
    # --- Iconen tekenen ---------------------------------------------------
    # Op 32x32 getekend (scherp op hoge DPI), in de stijl van de Teams-
    # presence-bolletjes, met kleine badges voor microfoon/camera/fout.
 
    $colors = @{
        Green  = [System.Drawing.Color]::FromArgb(108, 181, 69)
        Red    = [System.Drawing.Color]::FromArgb(209, 52, 56)
        Yellow = [System.Drawing.Color]::FromArgb(255, 170, 68)
        Grey   = [System.Drawing.Color]::FromArgb(138, 136, 134)
        Purple = [System.Drawing.Color]::FromArgb(98, 100, 167)
        Blue   = [System.Drawing.Color]::FromArgb(0, 120, 212)
        Orange = [System.Drawing.Color]::FromArgb(247, 99, 12)
        White  = [System.Drawing.Color]::White
    }
 
    # Vertaalt de Teams-status naar een vorm + kleur.
    function Get-PresenceStyle([string]$Status) {
        switch -Regex ($Status) {
            '^Available$'                                { return @{ Color = $colors.Green;  Glyph = 'check' } }
            '^(Busy|InACall|InAMeeting|OnThePhone)$'     { return @{ Color = $colors.Red;    Glyph = 'none' } }
            '^(DoNotDisturb|Presenting|Focusing)$'       { return @{ Color = $colors.Red;    Glyph = 'bar' } }
            '^(Away|BeRightBack)$'                       { return @{ Color = $colors.Yellow; Glyph = 'clock' } }
            '^Offline$'                                  { return @{ Color = $colors.Grey;   Glyph = 'offline' } }
            default                                      { return @{ Color = $colors.Grey;   Glyph = 'unknown' } }
        }
    }
 
    function Draw-Badge($G, [float]$X, [float]$Y, [System.Drawing.Color]$Color, [string]$Kind) {
        $d = 14
        $ring = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(32, 32, 32))
        $G.FillEllipse($ring, $X - 1.5, $Y - 1.5, $d + 3, $d + 3)
        $fill = New-Object System.Drawing.SolidBrush $Color
        $G.FillEllipse($fill, $X, $Y, $d, $d)
        $pen = New-Object System.Drawing.Pen ($colors.White, 1.8)
        $white = New-Object System.Drawing.SolidBrush $colors.White
        switch ($Kind) {
            'mic' {
                # Microfoonkop (capsule) + beugel + steel + voet
                $G.FillEllipse($white, $X + 5, $Y + 2.2, 4, 4)
                $G.FillRectangle($white, $X + 5, $Y + 4.2, 4, 2.6)
                $G.FillEllipse($white, $X + 5, $Y + 4.8, 4, 4)
                $thin = New-Object System.Drawing.Pen ($colors.White, 1.4)
                $G.DrawArc($thin, $X + 3, $Y + 4.2, 8, 6.4, 0, 180)
                $G.DrawLine($thin, $X + 7, $Y + 10.6, $X + 7, $Y + 12)
                $G.DrawLine($thin, $X + 5, $Y + 12, $X + 9, $Y + 12)
                $thin.Dispose()
            }
            'cam' {
                # Camerabody + lens-driehoek
                $G.FillRectangle($white, $X + 2.5, $Y + 4.5, 6.5, 5)
                $pts = [System.Drawing.PointF[]]@(
                    [System.Drawing.PointF]::new($X + 9, $Y + 7),
                    [System.Drawing.PointF]::new($X + 12, $Y + 4.5),
                    [System.Drawing.PointF]::new($X + 12, $Y + 9.5))
                $G.FillPolygon($white, $pts)
            }
            'error' {
                $G.FillRectangle($white, $X + 6, $Y + 3, 2, 5.5)
                $G.FillRectangle($white, $X + 6, $Y + 10, 2, 2)
            }
        }
        $ring.Dispose(); $fill.Dispose(); $pen.Dispose(); $white.Dispose()
    }
 
    function New-StatusIcon([string]$Status, [bool]$Mic, [bool]$Cam, [bool]$Ok) {
        $style = Get-PresenceStyle $Status
        $bmp = New-Object System.Drawing.Bitmap 32, 32
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
 
        $white = New-Object System.Drawing.SolidBrush $colors.White
        $pen = New-Object System.Drawing.Pen ($colors.White, 3.2)
        $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
        $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
 
        # Hoofdbolletje (met donkere rand zodat hij op lichte en donkere
        # taakbalken leesbaar blijft).
        $outline = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(40, 40, 40))
        $g.FillEllipse($outline, 1, 1, 26, 26)
        if ($style.Glyph -eq 'offline') {
            $ringPen = New-Object System.Drawing.Pen ($style.Color, 3.5)
            $g.FillEllipse($white, 2.5, 2.5, 23, 23)
            $g.DrawEllipse($ringPen, 4.2, 4.2, 19.6, 19.6)
            $xPen = New-Object System.Drawing.Pen ($style.Color, 3)
            $xPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $xPen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
            $g.DrawLine($xPen, 10.5, 10.5, 17.5, 17.5)
            $g.DrawLine($xPen, 17.5, 10.5, 10.5, 17.5)
            $ringPen.Dispose(); $xPen.Dispose()
        } else {
            $fill = New-Object System.Drawing.SolidBrush $style.Color
            $g.FillEllipse($fill, 2.5, 2.5, 23, 23)
            $fill.Dispose()
            switch ($style.Glyph) {
                'check' {
                    $g.DrawLines($pen, [System.Drawing.PointF[]]@(
                        [System.Drawing.PointF]::new(8.5, 14.5),
                        [System.Drawing.PointF]::new(12.5, 18.5),
                        [System.Drawing.PointF]::new(19.5, 10)))
                }
                'bar'   { $g.DrawLine($pen, 8.5, 14, 19.5, 14) }
                'clock' {
                    $g.DrawLines($pen, [System.Drawing.PointF[]]@(
                        [System.Drawing.PointF]::new(14, 8),
                        [System.Drawing.PointF]::new(14, 14.5),
                        [System.Drawing.PointF]::new(18.5, 17)))
                }
                'unknown' {
                    $font = New-Object System.Drawing.Font ("Segoe UI", 13, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
                    $sf = New-Object System.Drawing.StringFormat
                    $sf.Alignment = [System.Drawing.StringAlignment]::Center
                    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
                    $g.DrawString("?", $font, $white, [System.Drawing.RectangleF]::new(2.5, 3, 23, 23), $sf)
                    $font.Dispose(); $sf.Dispose()
                }
            }
        }
 
        # Badges: microfoon rechtsonder, camera rechtsboven, fout linksboven.
        if ($Mic) { Draw-Badge $g 17 17 $colors.Purple 'mic' }
        if ($Cam) { Draw-Badge $g 17 0  $colors.Blue   'cam' }
        if (-not $Ok) { Draw-Badge $g 0 0 $colors.Orange 'error' }
 
        $outline.Dispose(); $white.Dispose(); $pen.Dispose(); $g.Dispose()
        $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
        $bmp.Dispose()
        return $icon
    }
 
    # Iconen worden per combinatie één keer gemaakt en bewaard (GetHicon
    # lekt anders een handle per keer).
    $script:iconCache = @{}
    function Get-StatusIcon([string]$Status, [bool]$Mic, [bool]$Cam, [bool]$Ok) {
        $key = "$Status|$Mic|$Cam|$Ok"
        if (-not $script:iconCache.ContainsKey($key)) {
            $script:iconCache[$key] = New-StatusIcon $Status $Mic $Cam $Ok
        }
        return $script:iconCache[$key]
    }
 
    # --- Statusvertaling voor tooltip/menu -------------------------------
    $statusNl = @{
        Available = 'Beschikbaar'; Busy = 'Bezet'; DoNotDisturb = 'Niet storen'
        Presenting = 'Presenteert'; Focusing = 'Focus'; Away = 'Afwezig'
        BeRightBack = 'Ben zo terug'; Offline = 'Offline'; Unknown = 'Onbekend'
        InACall = 'In gesprek'; InAMeeting = 'In vergadering'; OnThePhone = 'Aan de telefoon'
    }
 
    # --- Tray-icoon en menu ------------------------------------------------
    $script:notify = New-Object System.Windows.Forms.NotifyIcon
    $script:notify.Icon = Get-StatusIcon "Unknown" $false $false $true
    $script:notify.Text = "Teams -> Home Assistant: starten..."
    $script:notify.Visible = $true
 
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
 
    # Bovenaan: niet-klikbare regels met de actuele details.
    $script:miStatus = New-Object System.Windows.Forms.ToolStripMenuItem "Status: ..."
    $script:miStatus.Enabled = $false
    $script:miDevices = New-Object System.Windows.Forms.ToolStripMenuItem "Microfoon/camera: ..."
    $script:miDevices.Enabled = $false
    $script:miSent = New-Object System.Windows.Forms.ToolStripMenuItem "Laatst verstuurd: nog niet"
    $script:miSent.Enabled = $false
    $null = $menu.Items.Add($script:miStatus)
    $null = $menu.Items.Add($script:miDevices)
    $null = $menu.Items.Add($script:miSent)
    $null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
 
    $null = $menu.Items.Add("Nu opnieuw versturen", $null, { Reset-SendState })
    $null = $menu.Items.Add("Logbestand openen", $null, {
        if (Test-Path $logFile) { Start-Process notepad.exe -ArgumentList "`"$logFile`"" }
    })
    $null = $menu.Items.Add("Help en documentatie (GitHub)", $null, { Start-Process $helpUrl })
    $null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $null = $menu.Items.Add("Afsluiten", $null, {
        $script:timer.Stop()
        Send-Offline -Reason "afgesloten via menu"
        $script:notify.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    })
    $script:notify.ContextMenuStrip = $menu
 
    # Dubbelklik op het icoon opent de help.
    $script:notify.Add_DoubleClick({ Start-Process $helpUrl })
 
    # --- Timer: periodieke check -------------------------------------------
    $script:lastTick = Get-Date
    $script:timer = New-Object System.Windows.Forms.Timer
    $script:timer.Interval = $checkIntervalSeconds * 1000
    $script:timer.Add_Tick({
        try {
            # Grote gat tussen twee ticks = laptop kwam uit slaapstand: dan
            # direct opnieuw versturen (HA heeft ons intussen op Offline gezet).
            $now = Get-Date
            if (($now - $script:lastTick).TotalSeconds -gt ($checkIntervalSeconds * 3 + 10)) {
                Write-Log "Hervat na pauze/slaapstand, status opnieuw versturen."
                Reset-SendState
            }
            $script:lastTick = $now
 
            $s = Invoke-StatusCheck
 
            $label = if ($statusNl.ContainsKey($s.status)) { $statusNl[$s.status] } else { $s.status }
            $parts = @("Teams: $label")
            if ($s.in_call)    { $parts += "in gesprek" }
            if ($s.mic_in_use) { $parts += "mic: $($s.mic_app)" }
            if ($s.camera_on)  { $parts += "cam: $($s.camera_app)" }
            if (-not $s.ok)    { $parts += "versturen mislukt" }
            $text = $parts -join " | "
            if ($text.Length -gt 63) { $text = $text.Substring(0, 60) + "..." }
 
            $script:notify.Icon = Get-StatusIcon $s.status ([bool]($s.mic_in_use -or $s.in_call)) ([bool]$s.camera_on) ([bool]$s.ok)
            $script:notify.Text = $text
 
            $script:miStatus.Text = "Status: $label" + $(if ($s.in_call) { " (in gesprek)" } else { "" })
            $mic = if ($s.mic_in_use) { $s.mic_app } else { "uit" }
            $cam = if ($s.camera_on)  { $s.camera_app } else { "uit" }
            $script:miDevices.Text = "Microfoon: $mic   Camera: $cam"
            $script:miSent.Text = if ($script:lastSent -gt [datetime]::MinValue) {
                "Laatst verstuurd: {0:HH:mm:ss}" -f $script:lastSent + $(if (-not $s.ok) { " (laatste poging mislukt)" } else { "" })
            } else { "Laatst verstuurd: nog niet" }
        } catch {
            Write-Log "Fout in statuscheck: $($_.Exception.Message)" "ERROR"
            $script:notify.Icon = Get-StatusIcon "Unknown" $false $false $false
            $script:notify.Text = "Teams -> HA: fout, zie logbestand"
        }
    })
 
    Write-Log "Gestart (tray-modus)."
    $script:timer.Start()
    [System.Windows.Forms.Application]::Run()
 
    $script:notify.Dispose()
    $script:mutex.ReleaseMutex()
    exit 0
}
 
# ============================================================
# Console-modus
# ============================================================
 
Write-Log "Gestart (console-modus). Ctrl+C om te stoppen."
try {
    $lastTick = Get-Date
    while ($true) {
        $now = Get-Date
        if (($now - $lastTick).TotalSeconds -gt ($checkIntervalSeconds * 3 + 10)) {
            Write-Log "Hervat na pauze/slaapstand, status opnieuw versturen."
            Reset-SendState
        }
        $lastTick = $now
 
        try { $null = Invoke-StatusCheck }
        catch { Write-Log "Fout in statuscheck: $($_.Exception.Message)" "ERROR" }
 
        Start-Sleep -Seconds $checkIntervalSeconds
    }
} finally {
    Send-Offline -Reason "console gestopt"
    $script:mutex.ReleaseMutex()
}