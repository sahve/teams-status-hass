# Teams Status → Home Assistant

Stuur je Microsoft Teams-status (Available/Busy/Away/...) en of je in een gesprek zit naar Home Assistant, zonder Microsoft Graph API-toegang of adminrechten. Handig als je op een werklaptop zit waar je de Graph API niet mag/kan gebruiken, maar wel wilt dat bijvoorbeeld een bezet-lampje aangaat tijdens een call.

## Hoe het werkt

De nieuwe Teams-desktopclient logt lokaal presence- en call-events naar platte tekstbestanden. Dit project leest die logs, en post bij elke wijziging een klein JSON-bericht naar een Home Assistant webhook:

```json
{ "status": "Busy", "in_call": true }
```

Geen cloud-tussenlaag, geen extra software op je laptop buiten PowerShell (ingebouwd in Windows).

**Beperkingen:**
- Werkt alleen met de nieuwe Teams-client (niet Teams Classic).
- Detecteert géén los "In gesprek"-onderscheid via een `activity`-veld — dat bestaat niet in deze logs. In plaats daarvan wordt de call-tracker (start/eind van een call) gebruikt, wat in de praktijk net zo goed werkt.
- Afhankelijk van Microsoft's interne logformaat, dat in het verleden is gewijzigd. Zie de troubleshooting-sectie als het ooit stopt met werken.

## Vereisten

- Windows met de nieuwe Microsoft Teams-client
- Een Home Assistant-instantie die (op zijn minst voor de webhook) bereikbaar is vanaf je laptop
- PowerShell (standaard aanwezig op Windows)

## Installatie

### 1. Home Assistant

1. Kopieer `homeassistant/packages/teams_status.yaml` naar de `packages/`-map van je HA-configuratie (zorg dat `packages: !include_dir_named packages` in je `configuration.yaml` staat).
2. Genereer een willekeurig webhook-ID: in PowerShell, `[guid]::NewGuid()`. Vul dit in op de plek van `<YOUR_WEBHOOK_ID>` in het YAML-bestand. Gebruik geen voorspelbare naam — dit endpoint is straks (indirect) publiek bereikbaar.
3. Herstart Home Assistant volledig (niet alleen een YAML-reload — webhook-registratie gebeurt bij het opstarten).
4. Optioneel: kopieer `homeassistant/automations/example-teams-light.yaml` als startpunt voor een automation die iets doet met de status.

### 2. Home Assistant bereikbaar maken vanaf je laptop

Als je HA-instantie alleen lokaal bereikbaar is, moet je 'm extern (of via VPN/Tailscale) toegankelijk maken zodat je werklaptop de webhook kan bereiken. Dit valt buiten de scope van dit script — een paar aandachtspunten uit onze eigen ervaring:

- Zet in `configuration.yaml` je reverse-proxy netwerk in `trusted_proxies`, anders weigert HA verkeer via de proxy.
- **Op een bedrijfsnetwerk met SSL-inspectie (bv. Fortinet):** een gloednieuw subdomein kan actief geblokkeerd worden door domeinreputatie-filters, ook als het certificaat en de DNS verder correct zijn. Als dit gebeurt, helpt het vaak om een al langer bestaand, bij de firewall bekend subdomein te hergebruiken in plaats van een nieuw subdomein aan te maken.

### 3. Het script

1. Kopieer de hele `scripts/`-map naar bijvoorbeeld `C:\Scripts\` op je laptop.
2. Kopieer `config.example.ps1` naar `config.ps1` en vul je eigen webhook-URL in (en proxy-adres, als je daarachter zit).
3. Test handmatig:
   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\teams-status.ps1"
   ```
   Wissel je Teams-status en controleer in Home Assistant (**Ontwikkelaarshulpmiddelen → Staten**, zoek op `teams`) of `sensor.teams_status` meebeweegt.
   Alleen de webhook testen kan ook, met `-test`: dan worden een paar voorbeeldstatussen verstuurd en stopt het script.
4. Stop het testscript (Ctrl+C) en zet 'm in Task Scheduler zodat hij automatisch start (zie hieronder).

### 4. Op de achtergrond draaien, met icoon naast de klok

Met `-tray` draait het script zonder consolevenster, als een gekleurd bolletje in het systeemvak rechtsonder:

| Icoon | Betekenis |
|---|---|
| 🟢 groen | Available |
| 🔴 rood | Busy / Do not disturb |
| 🟠 oranje | Away / Be right back |
| ⚪ grijs | Offline / onbekend |
| wit stipje in het midden | je zit in een gesprek |

Beweeg met de muis over het icoon om de status te zien (en of het versturen mislukt is). Via rechtsklik kun je de status opnieuw versturen of het script afsluiten. Er draait altijd maar één tray-icoon tegelijk.

Zet het in Task Scheduler:
- Trigger: "At log on" (geen herhaling nodig — het script draait zelf continu)
- Actie: programma `conhost.exe`, argumenten:
  `--headless powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\teams-status.ps1" -tray`
- Conditions: "Start the task only if the computer is on AC power" **uit**
- Settings: "Do not start a new instance" als er al een instantie draait

`conhost.exe --headless` zorgt dat er helemaal geen venster verschijnt, ook niet heel even (op Windows 11 opent `powershell.exe -WindowStyle Hidden` anders toch kort een Terminal-venster). Werkt dat op jouw Windows-versie niet, gebruik dan als programma `powershell.exe` met de argumenten `-WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Scripts\teams-status.ps1" -tray`. Het script verbergt zijn eigen venster dan zelf, maar je ziet het misschien heel even flitsen bij het inloggen.

Pin het icoon eventueel vast via **Instellingen → Persoonlijke instellingen → Taakbalk → Andere systeemvakpictogrammen**, anders staat het achter het pijltje `^`.

## Troubleshooting

| Symptoom | Mogelijke oorzaak | Oplossing |
|---|---|---|
| `sensor.teams_status` verschijnt niet in HA | Package niet geladen, of nog geen webhook-POST ontvangen | Check `packages/`-bestandsnaam (underscore, geen koppelteken!) en HA-logs op laadfouten; volledige herstart nodig |
| `Invalid package definition ...: invalid slug` in HA-logs | Bestandsnaam bevat een `-` | Hernoem naar underscores, bv. `teams_status.yaml` |
| `407 Proxy Authentication Required` | Bedrijfsproxy vereist authenticatie | Vul `$proxyUrl` in `config.ps1` in — het script gebruikt automatisch je Windows-inlog voor de proxy |
| `Could not create SSL/TLS secure channel` | Verouderd TLS-protocol, of (bij bedrijfsnetwerken) domeinreputatie-blokkade | Script forceert al TLS 1.2; test of een ander, langer bestaand subdomein op dezelfde server wél werkt om te zien of het domein-specifiek is |
| Sensor blijft oude waarde tonen | State-file bevat al dezelfde status, dus er wordt terecht niets verstuurd | Verwijder `%TEMP%\teams_ha_state.txt` om een verse melding te forceren |
| Geen `availability:`-regels te vinden in de logs | Microsoft heeft het logformaat gewijzigd | Zoek handmatig met `Select-String -Path <logbestand> -Pattern "availability","presence"` naar het huidige patroon en pas het script aan |

## Hoe de logs eruitzien

Ter referentie, ten tijde van schrijven zagen de relevante regels er zo uit:

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
