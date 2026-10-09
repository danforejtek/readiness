# On-phone checklist (items the Simulator cannot cover)

Plug the iPhone in, unlock it, and install the latest build first (Xcode › Run with "Dan – iPhone" selected,
or ask Claude to build and install). Tick items off as you go and note anything odd next to them.

## Install and icon

- [x] The app installs and opens. If iOS refuses: Settings › General › VPN & Device Management › trust your
      developer certificate again (needed after every 7-day re-sign with a free Apple ID).
- [x] Home screen shows the new icon (ring with heartbeat line).
- [x] Long-press the home screen › Edit › Customize › Dark: the dark icon variant appears. Tinted: the grey one.

## Apple Health (phase 5)

- [x] Settings tab › Apple Health › turn on *Save to Apple Health*. The Health permission sheet lists
      "Heart Rate Variability" and "Resting Heart Rate" under *write*. Allow both.
- [x] The line under the switch says "New measurements are saved to Apple Health."
- [x] Tap *Save N earlier measurements*. Your real mornings (band and Mac imports) go to Health; demo and replay
      data do not.
- [x] Health app › Browse › Heart › Heart Rate Variability: entries from Readiness at your measurement times.
      Same for Resting Heart Rate. (HRV in Health is SDNN, so it is higher than the RMSSD the app shows.)
- [ ] Take a morning measurement with the band. Afterwards a new HRV and resting-HR entry is in Health.
- [ ] Delete that measurement in History (swipe left). Its two Health entries disappear.
- [ ] Optional: turn the Health permission off in Health › Profile › Apps › Readiness, then toggle *Save to
      Apple Health* off and on in the app. It should explain how to allow it again.

## Morning reminder (phase 5)

- [x] Settings › Reminder › turn on *Morning reminder*, allow notifications, set a time 2–3 minutes from now.
- [ ] Lock the phone. The notification "Morning HRV" arrives at that time.
- [ ] Tap it. The app opens straight into the measurement screen.
- [ ] Measure (or replay) once, then set the time to 2 minutes from now again: no notification today, because
      you already measured. Set the time back to your real wake-up time.

## Bluetooth error paths (still open from phase 3)

- [x] Band switched off › *Measure now*: after 30 s a message explains the band's lights.
- [x] Bluetooth off in Control Centre › *Measure now*: the app asks you to turn Bluetooth on.
- [ ] During a measurement, walk away from the phone until it disconnects, come back within a minute: the
      countdown pauses and resumes. Stay away longer than 60 s: the measurement fails with a message.

## Settle period

- [ ] The measurement intro says "1:00 to settle, then 2:00 of measurement", and Settings › Morning protocol
      shows *Settle: 60 s*. If it still shows 15 s, the value was changed in Settings before: step it up to 60.
- [ ] During a measurement the ring counts down the 1:00 settle before the 2:00 start.

## Measurement extension

- [ ] Start a measurement and keep moving the arm or loosen the band so many beats are rejected (amber dots).
      When the 2:00 are up with fewer than 80 clean beats, the ring turns amber and shows
      "extending · N more clean beats"; it finishes as soon as 80 clean beats are in, or after at most 60 s more.
- [ ] A normal, still measurement finishes at 2:00 as before, with no extension.
- [ ] With eyes closed you feel the end: a success tap when the result appears, an error buzz if it fails, and one
      warning pulse when the extension starts.

## Rejected beats and older mornings

- [ ] First launch after updating: open an older morning that had amber (rejected) beats. Its Poincaré plot has
      no point for the pair of beats on either side of a rejected one, and SD1/SD2 may differ slightly from
      before (`Morning.breakIndices` recovered at launch; RMSSD and the verdict stay as stored). A clean morning
      looks exactly as before.
- [ ] A morning whose breathing rate is below 9/min shows "Slow breathing: LF/HF is not interpretable this
      morning." under the spectrum.

## Light and dark

- [x] Switch the phone to dark mode (Control Centre) and look at Today, Trends, a morning's detail and Settings.
      Text and charts should be readable in both modes.

## Check-in (phase 6)

- [ ] After a measurement, tap a feeling and a tag on the result screen; reopen the morning from History and
      check both are still selected.
- [ ] Settings › Prepare CSV export › Share export: two files (readiness.csv, readiness-beats.csv) are offered.

## Stress and Regeneration (phase A)

- [ ] After installing this build, open the app once: your band mornings get SD1, SD2 and the stress index filled
      in (History › a band morning › *All numbers* shows a stress index). Mac imports without beats stay at "–".
- [ ] Today shows *This week* (Mon–Sun, a dot on measured mornings, today circled, "N of 7 mornings measured")
      and *Today's numbers* with three rings: Regeneration, Readiness, Stress. Once you have 8 mornings,
      Regeneration and Stress show values; before that they say "after 7 mornings".
- [ ] Tap a dotted day in the week strip: that morning's detail opens.
- [ ] The ⓘ next to each ring explains it. The chips under the rings and under the HRV / resting-HR rows read like
      "▲ 8 % vs avg" / "▼ 1 % since last measurement"; green when the change is good (for Stress and resting HR,
      going down is good).
- [ ] Trends › *6 mo* and *1 yr* work; the Regeneration and Stress charts show a green 4–6 band.
- [ ] Do the values feel right? A good morning should give Regeneration above 5 and Stress below 5. Note any
      morning where they disagree with how you feel (the check-in records this for later tuning).

## Daily use

- [ ] Measure every morning right after waking for 7 days, with the check-in. On day 8 the first score and verdict appear.
- [ ] After four weeks, export and run `hrmon analyze` as described in docs/tuning.md.
- [ ] After two weeks, compare one morning with a Mac run (`.venv/bin/hrmon measure` right after the phone
      finishes): resting HR and lnRMSSD should be close.
