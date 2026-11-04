# Teams Status → Home Assistant

Stuur je Microsoft Teams-status (Available/Busy/Away/...), of je in een gesprek zit, en welke app je microfoon of camera gebruikt naar Home Assistant — zonder Microsoft Graph API-toegang of adminrechten. Handig op een werklaptop waar je de Graph API niet mag/kan gebruiken, maar wel wilt dat bijvoorbeeld een bezet-lampje aangaat of een speaker dempt tijdens een call.

## Hoe het werkt

Het script combineert twee lokale bronnen:

1. **Teams-logs** — de nieuwe Teams-client logt presence- en call-events naar platte tekstbestanden. Het script leest die incrementeel (alleen nieuwe regels).
2. **Windows-register** — Windows houdt per app bij wie de microfoon en camera gebruikt (dezelfde bron als het microfoon-icoontje in de taakbalk). Zo wordt ook een gesprek in Zoom, Webex, Meet (browser) enz. herkend.

Bij elke wijziging, en minstens elke 60 seconden als hartslag, gaat er een JSON-bericht naar een Home Assistant-webhook:

```json
{
  "status": "Busy",
  "in_call": true,
  "mic_in_use": true,
  "camera_on": false,
  "mic_app": "Teams",
  "camera_app": ""
}
```

Is Teams afgesloten, dan is `status` `Offline`. Bij het afsluiten van het script wordt een Offline-bericht gestuurd; komt er een paar minuten niets binnen (laptop dicht, geen netwerk), dan zet Home Assistant alles zelf op Offline (zie `ha_automation.yaml`).

Een icoon naast de klok toont je status in Teams-stijl, met badges voor microfoon (paars, rechtsonder), camera (blauw, rechtsboven) en verzendfouten (oranje, linksboven). Rechtsklik voor details, opnieuw versturen, het logbestand en deze helppagina.

Geen cloud-tussenlaag, geen extra software buiten PowerShell (ingebouwd in Windows).

**Beperkingen:**
- Status en `in_call` werken alleen met de nieuwe Teams-client (niet Teams Classic). `mic_in_use`/`camera_on` werken voor elke app.
- `mic_in_use` betekent "een app heeft de microfoon open" — ook bij dempen in Teams (gewenst), maar ook bij bv. spraakinvoer in de browser.
- Afhankelijk van Microsofts interne logformaat, dat in het verleden is gewijzigd. Zie troubleshooting.

## Vereisten

- Windows 10/11 met de nieuwe Microsoft Teams-client
- Een Home Assistant-instantie die vanaf je laptop bereikbaar is (voor de webhook)
- PowerShell 5.1 (standaard aanwezig op Windows)

## Installatie

### 1. Home Assistant

Kies één van twee routes.

**A. Via de UI (aanbevolen, met Offline-detectie)** — volg de instructies bovenin `ha_automation.yaml`: maak zes helpers aan en plak de automation in de YAML-editor. Je krijgt:

| Entity | Inhoud |
|---|---|
| `input_text.teams_status` | Available / Busy / Away / Offline / ... |
| `input_boolean.teams_in_gesprek` | in een Teams-gesprek (uit de logs) |
| `input_boolean.teams_microfoon` | een app gebruikt de microfoon |
| `input_boolean.teams_camera` | een app gebruikt de camera |
| `input_text.teams_microfoon_app` | welke app(s): Teams, Zoom, Webex, Chrome, ... of `geen` |
| `input_text.teams_camera_app` | idem voor de camera |

**B. Via een YAML-package** — kopieer `teams_status.yaml` naar de `packages/`-map van je HA-config (zorg dat `packages: !include_dir_named packages` in `configuration.yaml` staat) en herstart HA volledig. Je krijgt `sensor.`/`binary_sensor.`-entities met dezelfde inhoud, maar zonder automatische Offline-detectie.

Genereer in beide gevallen het webhook-ID met `[guid]::NewGuid()` in PowerShell. Gebruik nooit een voorspelbare naam — dit endpoint is publiek bereikbaar.

Voorbeelden van wat je ermee kunt: `example-teams-light.yaml` (bezet-lamp). Voor statistieken per app: maak een **History stats**-helper op `input_text.teams_microfoon_app` met status `Teams` (of `Zoom`, ...) en type "tijd" — dan zie je hoeveel uur per dag/week je in welke tool zat.

### 2. Home Assistant bereikbaar maken vanaf je laptop

Als je HA-instantie alleen lokaal bereikbaar is, moet je 'm extern (of via VPN/Tailscale) toegankelijk maken. Aandachtspunten:

- Zet in `configuration.yaml` je reverse-proxy netwerk in `trusted_proxies`, anders weigert HA verkeer via de proxy.
- **Op een bedrijfsnetwerk met SSL-inspectie (bv. Fortinet):** een gloednieuw subdomein kan geblokkeerd worden door domeinreputatie-filters. Hergebruik dan een al langer bestaand subdomein.

### 3. Het script

1. Download de repo (Code → Download ZIP) en pak uit naar bv. `C:\Scripts\teams-status\`.
2. Draai de installer:
   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\teams-status\install.ps1"
   ```
   Die deblokkeert de bestanden, vraagt je webhook-URL, detecteert een eventuele proxy, maakt een taak die bij aanmelden onzichtbaar start (met `conhost --headless`, zodat er op Windows 11 geen venster of taakbalkknop verschijnt), en start 'm meteen. Mag je geen geplande taken maken, dan valt hij terug op een snelkoppeling in de map Opstarten.
3. Wissel je Teams-status en kijk of het bolletje en de entities in HA meebewegen.

Verwijderen: `install.ps1 -Uninstall`.

**Handmatig / debuggen:**

```powershell
# Sample-payloads sturen (controleer daarna in HA of de waarden aankomen —
# HA antwoordt ook OK op een onbekend webhook-ID)
powershell.exe -ExecutionPolicy Bypass -File .\teams-status.ps1 -test

# Console-modus: zie live wat er verstuurd wordt (Ctrl+C stopt)
powershell.exe -ExecutionPolicy Bypass -File .\teams-status.ps1

# Tray-modus, zoals de taak 'm start
powershell.exe -ExecutionPolicy Bypass -File .\teams-status.ps1 -tray
```

Er draait altijd maar één exemplaar tegelijk. Het logbestand staat in `%TEMP%\teams_ha.log` (ook via het menu te openen).

Optionele instellingen (interval, hartslag, logbestand) staan uitgecommentarieerd in `config.example.ps1`.

## Troubleshooting

| Symptoom | Mogelijke oorzaak | Oplossing |
|---|---|---|
| Entities bewegen niet mee, `-test` geeft wel `[OK]` | Webhook-ID in `config.ps1` komt niet overeen met dat in HA | Vergelijk beide; bij de UI-route: kijk onder de automation → *Traces* of er runs zijn |
| `sensor.teams_status` verschijnt niet (package-route) | Package niet geladen | Bestandsnaam met underscore, HA-logs checken, volledige herstart |
| `407 Proxy Authentication Required` | Bedrijfsproxy | Vul `$proxyUrl` in `config.ps1` in — het script gebruikt je Windows-inlog voor de proxy |
| `Could not create SSL/TLS secure channel` | Oud TLS of domeinreputatie-blokkade | Script forceert TLS 1.2; test een ouder subdomein |
| Oranje badge op het icoon | Verzenden mislukt (netwerk/HA onbereikbaar) | Wordt elke 30 s opnieuw geprobeerd; zie het logbestand |
| Status blijft `Unknown` | Geen `availability:`-regels in de logs | Microsoft heeft het logformaat gewijzigd; zoek met `Select-String -Path <logbestand> -Pattern "availability","presence"` |
| Microfoon/camera-app wordt niet herkend | App staat niet in de naamlijst | Je ziet dan de exe-naam; voeg 'm toe aan `$appNames` in het script |
| Script start niet: "running scripts is disabled" | Groepsbeleid blokkeert scripts | Vraag IT om een uitzondering |

Controleren wie nu microfoon gebruikt:

```powershell
Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone" -Recurse |
  Get-ItemProperty | Where-Object { $_.LastUsedTimeStart -gt 0 -and $_.LastUsedTimeStop -eq 0 } |
  Select-Object PSChildName
```

## Hoe de logs eruitzien

Ten tijde van schrijven zagen de relevante regels er zo uit:

```
... UserDataCrossCloudModule: BroadcastGlobalState: New Global State Event: UserDataGlobalState total number of users: 1 { availability: Busy, unread notification count: 1 }
... TeamsCallTracker: Call became active: <call-id> (total: 1)
... TeamsCallTracker: Call ended: <call-id> (remaining: 0)
```

Logbestanden staan in:
```
%LocalAppData%\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs
```

## Licentie

Vrij te gebruiken en aan te passen binnen je organisatie.
