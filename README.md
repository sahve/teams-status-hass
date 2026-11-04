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

1. Kopieer `teams_status.yaml` naar de `packages/`-map van je HA-configuratie (zorg dat `packages: !include_dir_named packages` in je `configuration.yaml` staat).
2. Genereer een willekeurig webhook-ID: in PowerShell, `[guid]::NewGuid()`. Vul dit in op de plek van `<YOUR_WEBHOOK_ID>` in het YAML-bestand. Gebruik geen voorspelbare naam — dit endpoint is straks (indirect) publiek bereikbaar.
3. Herstart Home Assistant volledig (niet alleen een YAML-reload — webhook-registratie gebeurt bij het opstarten).
4. Optioneel: gebruik `example-teams-light.yaml` als startpunt voor een automation die iets doet met de status.

**Geen toegang tot je YAML-bestanden?** (bv. geen File editor/SSH) Dan kan het ook volledig via de UI: maak een Text-helper `Teams status` en een Toggle-helper `Teams in gesprek`, en een automation met een webhook-trigger (opties: *Alleen lokaal* uit) die ze vult:

```yaml
alias: Teams status webhook
triggers:
  - trigger: webhook
    webhook_id: "<YOUR_WEBHOOK_ID>"
    allowed_methods: [POST]
    local_only: false
actions:
  - action: input_text.set_value
    target:
      entity_id: input_text.teams_status
    data:
      value: "{{ trigger.json.status }}"
  - action: "input_boolean.turn_{{ 'on' if trigger.json.in_call else 'off' }}"
    target:
      entity_id: input_boolean.teams_in_gesprek
mode: queued
```

Je entities heten dan `input_text.teams_status` en `input_boolean.teams_in_gesprek` in plaats van `sensor.teams_status` en `binary_sensor.teams_in_gesprek`.

### 2. Home Assistant bereikbaar maken vanaf je laptop

Als je HA-instantie alleen lokaal bereikbaar is, moet je 'm extern (of via VPN/Tailscale) toegankelijk maken zodat je werklaptop de webhook kan bereiken. Dit valt buiten de scope van dit script — een paar aandachtspunten uit onze eigen ervaring:

- Zet in `configuration.yaml` je reverse-proxy netwerk in `trusted_proxies`, anders weigert HA verkeer via de proxy.
- **Op een bedrijfsnetwerk met SSL-inspectie (bv. Fortinet):** een gloednieuw subdomein kan actief geblokkeerd worden door domeinreputatie-filters, ook als het certificaat en de DNS verder correct zijn. Als dit gebeurt, helpt het vaak om een al langer bestaand, bij de firewall bekend subdomein te hergebruiken in plaats van een nieuw subdomein aan te maken.

### 3. Het script

1. Kopieer `teams-status.ps1` en `config.example.ps1` naar bijvoorbeeld `C:\Scripts\teams-status\` op je laptop. Gedownload als zip? Haal dan het internet-label eraf: `Get-ChildItem C:\Scripts\teams-status | Unblock-File`.
2. Kopieer `config.example.ps1` naar `config.ps1` en vul je eigen webhook-URL in (en proxy-adres, als je daarachter zit). Weet je niet of je achter een proxy zit? `([System.Net.WebRequest]::GetSystemWebProxy()).GetProxy("https://example.com")` — geeft dit gewoon `https://example.com` terug, dan is er geen proxy en laat je `$proxyUrl = ""`.
3. Test de webhook met sample-payloads:
   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\teams-status\teams-status.ps1" -test
   ```
   Let op: `[OK]` betekent alleen dat HA bereikbaar is — HA antwoordt ook OK op een onbekend webhook-ID. Controleer in Home Assistant (**Tools → States**, zoek op `teams`) of de status echt meebeweegt.
4. Test de echte koppeling met het tray-icoon:
   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\teams-status\teams-status.ps1" -tray
   ```
   Naast de klok verschijnt een gekleurd rondje (groen = Available, rood = Busy/DoNotDisturb/in gesprek, geel = Away, grijs = offline/fout); hover toont de status. Staat het onder het **^**-pijltje, sleep het naar de taakbalk. Rechtsklik → *Nu opnieuw versturen* of *Afsluiten*.
5. Zet 'm in Task Scheduler zodat hij automatisch en zonder venster start:
   - Trigger: "At log on" (geen herhaling nodig — het script draait zelf continu)
   - Actie: programma `conhost.exe`, argumenten:
     `--headless powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\teams-status\teams-status.ps1" -tray`
     (Op Windows 11 opent PowerShell standaard in Windows Terminal, die `-WindowStyle Hidden` negeert; `conhost --headless` voorkomt een zichtbaar venster en taakbalkknop.)
   - Conditions: "Start the task only if the computer is on AC power" **uit**
   - Settings: "Stop the task if it runs longer than" **uit**; "Do not start a new instance" als er al een instantie draait

Zonder `-tray` draait het script als console-lus (handig voor debuggen; stoppen met Ctrl+C).

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
