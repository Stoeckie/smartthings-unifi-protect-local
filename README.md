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

If you cannot open the controller device in the app, `src/local_config.lua` offers a fallback for IP and key. Never commit or share a filled in copy.

## Not supported

The Integration API has no endpoints for privacy mode (recording off) or NVR health metrics, so those are not included.

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
