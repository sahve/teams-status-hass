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
    [switch]$test
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
    $latestLog = Get-ChildItem -Path $logDir -Filter "MSTeams_20*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if ($latestLog) {
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

        $status = Get-TeamsStatus -LatestLogPath $latestLog.FullName
        $inCall = Get-TeamsCallState -LatestLogPath $latestLog.FullName -PreviousInCall $lastInCall

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
            }
        }
    }

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
