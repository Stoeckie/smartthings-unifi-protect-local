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

Some users cannot open the settings of the UniFi Protect device in the SmartThings app. The driver therefore also runs a small settings page on your SmartThings hub.

You need the SmartThings CLI once: https://github.com/SmartThingsCommunity/smartthings-cli/releases (Windows: `smartthings.msi`).

1. Find the IP address of your SmartThings hub (SmartThings app: open the hub device > Information, or look it up in your router).
2. Start the log viewer (log in when asked):
   ```
   smartthings edge:drivers:logcat --hub-address <hub-ip>
   ```
   Choose **UniFi Protect Local** if you are asked for a driver.
3. Wait for a line like `[unifi] settings page: http://192.168.1.20:41234/`. While the driver has no API key, this line repeats every minute. Already configured? Press Refresh on the UniFi Protect device to show the line again.
4. Open that address in a browser on your home network.
5. Enter the console IP address and your API key, then **Save and connect**.

Notes:
* The values are stored on your hub only. They are not part of the driver and are never shared.
* The page never shows your key. IP address and key are always saved together.
* The port changes when the driver restarts; you only need the page once.
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
