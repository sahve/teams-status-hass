# ============================================================
# Configuratie voor teams-status.ps1
# Kopieer dit bestand naar config.ps1 en vul je eigen waarden in.
# config.ps1 staat in .gitignore en wordt dus niet mee gecommit.
# ============================================================

# Je Home Assistant webhook-URL, inclusief het (lange, niet-raadbare) webhook-ID.
# Genereer een ID met: [guid]::NewGuid()
$webhookUrl = "https://<jouw-ha-domein>/api/webhook/<jouw-guid>"

# Bedrijfsproxy, indien van toepassing. Laat leeg ("") als je geen proxy nodig hebt.
$proxyUrl = "http://<jouw-proxy-adres>:8080"

# Locatie van de Teams-logs. Dit pad is standaard voor de nieuwe Teams-client
# en hoeft normaal niet aangepast te worden.
$logDir = "$env:LocalAppData\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs"

# Na een mislukte verzending (bv. HA of netwerk even weg) wordt het na zoveel
# seconden opnieuw geprobeerd.
$pollIntervalSeconds = 15

# Stuur de status ook zonder wijziging elke zoveel minuten opnieuw ("heartbeat").
# Zo komt HA na een herstart vanzelf weer bij, en kan HA zien dat je laptop weg
# is als de heartbeat uitblijft (zie teams_status.yaml). 0 = uit.
$heartbeatMinutes = 5

# Procesnaam van de nieuwe Teams-client. Draait dit proces niet, dan wordt
# "Offline" en "niet in gesprek" gemeld. Laat leeg ("") om dit uit te zetten.
$teamsProcessName = "ms-teams"
