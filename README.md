# TakeCast: Record & Stream

Record an event in 4K on an iPhone and stream it live to YouTube at the same
time. The full-quality copy stays safe on the phone whatever happens to the
stream: two governors lower the broadcast for heat and for a weak network, and
neither can reach the recording. DockKit gimbals are supported (LOCK holds the
frame, the handle starts and stops recording, the wheel zooms).

Free, open source, no accounts and no server. The stream goes straight from the
phone to the YouTube HLS ingest URL you paste into Setup.

## Using it

1. Set up YouTube (or have someone set it up for you): a verified channel with
   live streaming enabled, and a stream key using the HLS protocol with
   Auto-start and Auto-stop on. **The first enable can take up to 24 hours.**
   The in-app guide (Setup > Help > Open YouTube setup guide) walks through it,
   with a one-page insert for support staff.
2. Open **Setup**: paste the ingest URL (or leave streaming off to record only),
   pick the frame rate and mic pattern, and read the pre-flight checks.
3. **Go to camera**, frame the shot, tap **LOCK**, press **REC**.
4. After **STOP**, open **Recordings** to play, share (Photos, Files, AirDrop)
   or delete each recording.

## Building

Xcode 27 or later, iOS 26.5 or later, iPhone only, landscape only. Open
`TakeCast.xcodeproj` and run the `TakeCast` scheme. Set your own development
team and bundle identifier to run it on a device.

The app is Objective-C with a single Swift file for DockKit
(`ESDockKitBridge.swift`). Class names keep the `ES` prefix from the project's
first name, ESCapture, as do the saved settings keys and the recording file
names (`ESCapture-yyyyMMdd-HHmmss.mov`), so installed builds keep their data.

Docs: `docs/EVENT-CHECKLIST.md` (preparing a phone for a long event) and
`docs/PRIVACY.md`.

## Support

Use the project's GitHub issues. Please **do not post logs, ingest URLs or
stream keys** there: an ingest URL lets anyone broadcast on your channel. The
app never writes the ingest URL or stream key to its own log.

## License

The source code is MIT licensed (see `LICENSE`). The name "TakeCast" and the
app icon are not covered by the license; please use your own for a fork you
distribute.
