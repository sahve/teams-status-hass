# ============================================================
# Configuratie voor teams-status.ps1
# Kopieer dit bestand naar config.ps1 en vul je eigen waarden in
# (of draai install.ps1, die doet dat voor je).
# config.ps1 staat in .gitignore en wordt dus niet mee gecommit.
# ============================================================
 
# Je Home Assistant webhook-URL, inclusief het (lange, niet-raadbare) webhook-ID.
# Genereer een ID met: [guid]::NewGuid()
$webhookUrl = "https://<jouw-ha-domein>/api/webhook/<jouw-guid>"
 
# Bedrijfsproxy, indien van toepassing. Laat leeg ("") als je geen proxy nodig hebt.
$proxyUrl = ""
 
# --- Optioneel: onderstaande waarden hebben verstandige standaarden ---
 
# Hoe vaak (seconden) Teams-logs en microfoon/camera gecheckt worden.
# $checkIntervalSeconds = 3
 
# Ook zonder wijziging elke zoveel seconden versturen (hartslag). Home Assistant
# zet de status op Offline als er een paar minuten niets binnenkomt.
# $heartbeatSeconds = 60
 
# Logbestand (max ~1 MB, daarna wordt het oude bestand .old).
# $logFile = "$env:TEMP\teams_ha.log"
 
# Locatie van de Teams-logs (standaard voor de nieuwe Teams-client).
# $logDir = "$env:LocalAppData\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs"