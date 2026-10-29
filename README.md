# UniFi Protect Local — SmartThings Edge driver

Local integration between UniFi Protect and SmartThings, using the official **UniFi Protect Integration API** with a local API key. No cloud, no username/password.

## Features

Each Protect camera becomes a SmartThings device:

| Component | Capability | Use in routines |
|---|---|---|
| main | Button (doorbells only) | Doorbell ring = `pushed` |
| main | Motion sensor | Motion |
| person | Motion sensor | Person detected |
| vehicle | Motion sensor | Vehicle detected |
| animal | Motion sensor | Animal detected |
| sound | Sound sensor | Any AI audio detection (cameras with audio detection) |
| smoke | Smoke detector | Smoke alarm sound heard (cameras with audio detection) |
| co | Carbon monoxide detector | CO alarm sound heard (cameras with audio detection) |
| led | Switch | Status LED on/off |
| main | Video stream (optional) | Experimental, view via a camera group |

> Smoke and CO detection only means the camera *heard* an alarm. Never rely on it instead of real detectors.

Events arrive in real time over the Protect events WebSocket.

## Requirements

* UniFi OS console with UniFi Protect that supports the Integration API (tested target: UDR7)
* A local API key: UniFi OS > Control Plane > Integrations
* SmartThings hub on the same network as the console

## Install

1. Join the channel: **https://bestow-regional.api.smartthings.com/invite/qWjBdybRNG2y**
   Log in, accept, enroll your hub and install **UniFi Protect Local**.
2. In the SmartThings app: Add device > Scan nearby. A device **UniFi Protect** appears.
3. Open its settings and enter the **Console IP address** (e.g. `192.168.1.1`) and your **API key**.

Cameras are created automatically.

## Settings page on the hub (if the device settings do not open)

Some users cannot open the settings of the UniFi Protect device in the SmartThings app. The driver therefore also runs a small settings page on your SmartThings hub (not on the UniFi console).

The address of that page is `http://<IP of your SmartThings hub>:<port>/`. The port is not fixed: Edge drivers may not choose their own port, so the hub hands out a random free port each time the driver starts. The driver writes the full address to the hub log, so you read it from there.

You need the SmartThings CLI once: https://github.com/SmartThingsCommunity/smartthings-cli/releases (Windows: `smartthings.msi`).

1. Find the IP address of your SmartThings hub (SmartThings app: open the hub device > Information, or look it up in your router).
2. Open PowerShell, fill in your hub IP on the second line and paste the whole block:
   ```powershell
   $st     = "C:\Program Files\SmartThings\smartthings.exe"   # or just "smartthings" if it is on your PATH
   $hubIp  = "192.168.1.20"                                     # IP address of your SmartThings hub
   $driver = "27595fa5-a979-491e-8c16-6cf5362cd859"             # UniFi Protect Local
   # find the UniFi Protect device and ask it to print the address again in 8 seconds
   $all  = & $st devices --type LAN -j | Out-String | ConvertFrom-Json
   $id   = ($all | Where-Object { $_.lan.networkId -like "unifi-protect-local-*" -or $_.name -eq "UniFi Protect" } | Select-Object -First 1).deviceId
   Start-Job { Start-Sleep 8; & $using:st devices:commands $using:id refresh:refresh } | Out-Null
   # show only the lines of this driver; stop with Ctrl+C
   & $st edge:drivers:logcat $driver --hub-address $hubIp | Select-String "\[unifi\]"
   ```
   The first time, the CLI opens a browser to log in.
3. Within about 10 seconds you see a line like `[unifi] settings page: http://192.168.1.20:41234/`: your hub IP plus the port the hub handed out. (Without an API key the driver also repeats the address every minute in a `[unifi] controller not configured` line.) Pressing Refresh on the device does the same, but the block above works without opening the device.
4. Open that address in a browser on a device in your home network.
5. Enter the IP address of your UniFi console and your API key, then **Save and connect**.

Notes:
* The values are stored on your hub only. They are not part of the driver and are never shared.
* The page never shows your key. IP address and key are always saved together.
* The port changes every time the driver restarts (hub reboot, driver update). You only need the page once; the saved values survive restarts.
* Values entered in the SmartThings app settings take priority when filled in.

## Settings

| Setting | Default | Notes |
|---|---|---|
| Console IP address | 192.168.1.1 | IP of your UniFi console |
| API key | none | Local Integration API key |
| Detection reset (seconds) | 60 | Safety reset if Protect never sends an end event |
| Detection hold time (seconds) | 0 | Keep motion, person, vehicle and animal active this long after detection ends |
| Re-add removed cameras | off | Cameras you delete in SmartThings stay deleted; switch on to bring them back, then off |
| Video stream (experimental) | off | Exposes the RTSP stream to SmartThings |
| Video quality | medium | high, medium or low |
| Use RTSPS | off | Off = plain RTSP on port 7447 (best chance to work) |

## Build it yourself

```
smartthings edge:channels:create
smartthings edge:channels:enroll
smartthings edge:drivers:package . --install
```

If you cannot open the controller device in the app, use the **settings page** on your hub instead (see below). `src/local_config.lua` is a last resort fallback; never commit or share a filled in copy.

## Not supported

The Integration API has no endpoints for privacy mode (recording off) or NVR health metrics, so those are not included.

## Developer note

The hub refuses a driver update that changes the components of a profile already used by a device. Never edit existing profiles: add new ones (current set: `upl-*`) and migrate devices with `try_update_metadata`. The original `unifi-*` profiles are kept unchanged for that reason.

Fixed in v2.6 (2026-10-26): the vendored lustre WebSocket crashed once per keep-alive interval (`lustre/ws.lua: attempt to index a nil value (local 'recv')`) and the driver restarted every minute. It kept working because the hub restarts it, but events during the restart were lost. If your logcat shows that line, update to the channel version of 2026-10-26 or later.

`NotFoundError ... Failed to install Driver` on install: do not use the one step `edge:drivers:package . --channel <id> --hub <id>`. In tests (2026-10-29) that command failed every time, and the version it uploaded kept failing on later installs too. Package, assign and install as separate commands with about two minutes between each step; that version installs fine. If a version already failed, package a new one instead of retrying it. Removing unused drivers from a full v2 hub (`smartthings edge:drivers:prune --hub <id>`) does no harm either.

## Logs

`smartthings edge:drivers:logcat`, lines start with `[unifi]`.

## How it works

* REST: `https://<console>/proxy/protect/integration/v1/...` with header `X-API-KEY`
* Events: WebSocket `/proxy/protect/integration/v1/subscribe/events` (`ring`, `motion`, `smartDetectZone`, `smartDetectLine`, `smartAudioDetect`)
* Status LED: `PATCH /v1/cameras/{id}` with `ledSettings.isEnabled`
* Video: `/v1/cameras/{id}/rtsps-stream`, converted to plain RTSP (port 7447) unless RTSPS is enabled

## Terms

See [TERMS.md](TERMS.md).

## License

Apache License 2.0. Includes the `lustre` WebSocket library from the SmartThings Edge drivers repository (Apache 2.0), see NOTICE.
