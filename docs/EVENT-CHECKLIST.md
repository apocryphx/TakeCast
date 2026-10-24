# Event checklist

How to prepare an iPhone for a long, continuous recording and broadcast with
TakeCast: a ceremony, a talk, a defense, a celebration.

The recording is never at risk from anything below. Two governors bend the
broadcast for heat and for the network, and neither can reach the recording.
Everything here protects the stream, or keeps the app from being taken off
screen.

## The day before

Alarms first, because they are the one thing that ignores everything else.
A recurring alarm rings and vibrates straight through both Do Not Disturb
and Silent mode. Open Clock and clear anything scheduled for the day.

Configure the Focus rather than trusting its defaults. Out of the box, Do
Not Disturb still admits Favorites and still honours a repeated call within
three minutes, which is exactly the guest who cannot find the venue.

- Allow Calls From: No One
- Allow Repeated Calls: off
- Time Sensitive Notifications: off
- Add the Silent filter, so one switch engages both
- Check Emergency Bypass on individual contacts. It overrides the Focus
  entirely and it is set per contact, usually years ago and forgotten
- If the Focus is scheduled, check when it turns itself off. A schedule
  ending mid event undoes all of this at the worst possible moment

Then the rest of Settings:

- Sounds & Haptics, Haptics: Don't Play in Silent Mode. A phone clamped in
  a gimbal is rigidly coupled to the shot, so a buzz is a visible bump in a
  locked 4K frame, not merely a noise
- Phone, Incoming Calls: Banner rather than Full Screen
- Siri: turn off Listen for "Siri". Someone saying the word near the phone
  is a plausible way to lose the app for a moment
- Cellular, Cellular Data: Allow Cellular Data Switching on, if the phone has
  two lines. It covers loss of coverage, not congestion, so it will not save
  a stream that is merely slow, but it costs nothing
- Accessibility: enable Guided Access and set its passcode

Rehearse the whole arrangement rather than trusting it. Put the phone in
the exact configuration, recording, and have someone call twice in a row,
send a message, and try the Siri wake word. Ten minutes converts every
assumption above into something watched working on the actual hardware.

At the venue, on the day if possible: test the network where the phone will
actually stand, and run a short private test stream end to end. Cellular
during a packed event is nothing like a quiet scouting visit. Open Setup and
check that the Storage line covers the full running time.

## Setting up

- External power. A multi hour 4K recording plus continuous upload is not a
  battery job
- Screen brightness well down. The display stays on from REC to STOP, and
  that heat is spent against the same budget the thermal governor uses to
  hold the broadcast tier. Dimmer screen, better stream, for longer
- Wi-Fi off, unless the venue Wi-Fi is known to be good. An associated Wi-Fi
  wins over cellular and iOS will not step back to cellular just because the
  Wi-Fi went bad. Keep venue Wi-Fi as the fallback, switched on deliberately
- Focus on, and confirm Silent actually engaged
- In Setup: paste the stream URL and read the host back, choose frame rate,
  codec and mic pattern, and go through the pre-flight checks. Setup is not
  reachable once recording starts
- Frame the shot, then LOCK. Exposure, white balance and focus stop hunting
  and a docked gimbal stops panning

## Rolling

REC first, then triple click the side button for Guided Access. That order
matters, and so does knowing the way out: leaving Guided Access is another
triple click plus the passcode or Face ID, and you will need to do that
before you can press STOP.

Confirm the REC and LIVE lamps before walking away.

At the end, roll past the moment. Endings are protected by continuing to
record, never by padding.

## If something looks wrong

Read the BCAST and THERM lamps side by side (or `tier` and `therm` in the
STAT lines of the log). They come from two different governors and the
difference is the whole diagnosis.

- BCAST 720p net, THERM nominal: the uplink, not heat. The remedy is manual,
  because no API lets the app choose a carrier. On a phone with two lines,
  switch the cellular data line in Settings
- Stream degraded and staying degraded: check whether Wi-Fi crept back on.
  The network governor measures delivery and will downshift faithfully, but
  it cannot change interface, so a bad Wi-Fi presents as a slow network
- BCAST off therm, THERM critical: heat shut the broadcast down. The
  recording continues, and the message on screen says so

If the app is ever pushed to the background, capture stops. The lamp reads
REC INTERRUPTED in yellow, and the log takes an INTERRUPTED line naming the
reason followed by RESUMED with the number of seconds missing. Get back to
the foreground immediately. Capture resumes by itself, with a hole where it
was away. If it was away long enough, YouTube's Auto-stop will have ended
the broadcast, and resuming means a new stream and a second recording on
YouTube.

The same lamp and the same two lines cover the interruptions that happen
while the app is still on screen, which are the ones you would otherwise
have no explanation for: the camera or the audio device taken by something
else, or the session shut down under system pressure.

This is what Guided Access is for. It is the difference between a risk you
have to remember and a risk you have removed.
