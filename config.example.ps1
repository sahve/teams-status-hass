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

# Waar de laatst-verstuurde status lokaal wordt bijgehouden (voorkomt dubbele webhook-calls).
$stateFile = "$env:TEMP\teams_ha_state.txt"

# Hoe vaak (in seconden) het script de logs checkt. Wegens filechange-events kan dit hoger dan 5 seconden gezet worden
$pollIntervalSeconds = 15
