---
format: 1920x1080
message: "One panel. Type anything. It understands."
arc: Stillness → Ask → Remind → Note → Stillness (return)
audience: Mac users on X — people who live in keyboard shortcuts
music: none
---

<!--
DESIGN INTENT (read before building any frame)

This is a SILENT, screen-recording-style product demo. The whole identity is
RESTRAINT — the confidence to let three seconds pass with nothing happening.
No narration. No music. Only subtle keyboard-typing SFX and a soft panel
open/close UI sound.

The "product" is the Notch panel. We do NOT scrape a website; we reproduce the
shipping app's UI faithfully in HTML/CSS. All geometry, glass, fonts, colors,
and feedback strings come from the Swift source (see
capture/extracted/visible-text.txt → "GROUND TRUTH"). Two rules the user locked:

  1. The panel EXPANDS IN PLACE — it does NOT slide/fall down from the notch.
     Width grows 192→540px, bottom corner-radius grows 9→30px on a spring,
     content fades in. Top corners stay SQUARE, flush to the screen top edge.
  2. Reminder feedback is EXACTLY "Added to Reminders" — no "· 6:00 PM" suffix,
     no icon. Note feedback is EXACTLY "Added to Notes".

Real spring values (use verbatim, do NOT speed up):
  • open shell:  spring(response 0.50, dampingFraction 0.82)  → width + corner radius
  • module/body: spring(response 0.42, dampingFraction 0.82)  → answer/feedback fade
  • close shell: spring(response 0.34, dampingFraction 0.68)  → one soft settle
  On close, content fades out FIRST, then the shell retracts.

CONTINUITY: The opening desktop (Frame 1, 0–3s) and the closing desktop
(Frame 3, end) must be visually IDENTICAL — same gradient, same notch, no cursor.
The video should feel like it returns to exactly where it began.

SHARED COMPONENT: All three frames reuse one NotchPanel component
(compositions/components/notch-panel.html if extracted, or duplicated CSS):
the desktop gradient, the black notch hardware pill, and the glass panel.
Only the typed text, the recognized intent, and the response differ per frame.
-->

## Video direction

The whole film is one continuous "screen recording" of a single Mac desktop. One
shared NotchPanel reconstruction across all three frames; only the typed line,
the recognized intent, and the response change. Everything below is inherited by
every frame — per-frame Scene lines carry only the delta.

- **Palette (from frame.md / Notch tokens).** Desktop = a calm near-black
  gradient (deep charcoal #0d0d10 → near-black #050506, very subtle top-center
  cool lift so the notch reads). Panel glass = dark smoked rgba(0,0,0,0.55) with
  heavy backdrop blur + a faint white rim gradient (top transparent → bottom
  white@26%) + soft drop shadow (black@30%, blur 9, y 5). Type = SF system,
  white ink: prompt white@96%, answer white@96%, the intent hint + feedback
  line white@40%. Accent (blue #669fff) and success (green #66d18c) exist in the
  system but are used **sparingly or not at all** — restraint is the brand. No
  gradients-as-decoration, no glow, no color washes on the desktop.

- **Motion grammar.** Real app springs, never sped up: panel OPEN =
  spring-pop-entrance tuned to (response 0.50, damping 0.82) driving width
  192→540px + bottom radius 9→30px, body fades in (opacity); content reveals
  (answer / feedback) ride the module spring (response 0.42, damping 0.82) as a
  short fade+rise; CLOSE = content fades out first, then the shell retracts on
  (response 0.34, damping 0.68) with one soft settle. Long-tail decel only
  (`power3` / the spring curves above) — NO bounce, NO overshoot, NO elastic.

- **Reveal model (this is a silent demo — the pace cue is the TYPING, not a VO).**
  Nothing front-loads. The line types on character-by-character (type-on with
  caret → `discrete-text-sequence` + `context-sensitive-cursor`); the caret
  blinks; the human pause AFTER typing is sacred (~0.8–1.0s of true stillness),
  and the recognition + response only appear AFTER that pause — never during
  typing. This delayed recognition is the whole point (it mirrors on-device
  intent classification firing when you stop).

- **Rhythm / held beats.** Each frame has two real holds: (1) the read after the
  response lands, (2) — for Frame 1 only — the 3s opening stillness. During any
  hold the desktop and notch are DEAD STILL (no breathing, no drift). The only
  sanctioned aliveness anywhere is the caret blink and, at most, an
  imperceptible `sine-wave-loop` low-amplitude jitter on nothing visible — in
  practice we hold perfectly still. Stillness is the aesthetic.

- **Continuity.** The desktop + notch layer is byte-identical in all three
  frames and at every moment the panel is closed; cuts between frames are
  invisible (same pixels). Frame 3's final closed desktop === Frame 1's opening
  closed desktop.

- **Negative list.** No cursor/pointer ever (the script says "光标不在"). No
  menu bar, no dock, no wallpaper photo, no app windows, no key-graphic for ⌥.
  No captions (silent). No bouncy/elastic springs. No front-load-then-freeze
  (slideshow) and no floating-everything (screensaver). No fake "· 6:00 PM" on
  the reminder, no SF-symbol icons on feedback — match the real app exactly.

## Frame 1 — Stillness, then Ask

- scene: 3s of empty desktop, then the panel expands and answers a question
- duration: 13s
- transition_in: cut
- status: animated
- intent: ask
- typed: "what's the time difference between SF and Shanghai"
- response: "Shanghai is 15 hours ahead of San Francisco."
- blueprint: compose
- focal: the NotchPanel (synthesized)
- roles: desktop = background (dead still) · notch = anchor · panel = cutout (the subject)
- sfx: pop, typing, click-soft
- src: compositions/frames/01-ask.html

Open cold. A calm dark desktop, the black notch sitting quietly at the top
center. No cursor, no UI, nothing moving. Hold for a full 3 seconds — this
emptiness IS the opening statement (Claude-style confidence).

At ~3s, the panel is summoned (double-tap ⌥, implied — no key graphic). The
shell expands in place on the real open spring: width 192→540px, bottom corners
9→30px, the dark glass body fades in with the "Type anything…" placeholder. A
soft open SFX.

Typing begins (~4s): the line types in character by character at a human
cadence with the typing SFX, the caret blinking. "what's the time difference
between SF and Shanghai". Around ~9.5s the typing stops — the hands rest.

A deliberate ~1s pause. THEN — and only then — the panel recognizes the line as
a question: a faint "— Ask" hint materializes, and the AI answer fades up below
the prompt on the module spring: "Shanghai is 15 hours ahead of San Francisco."

The answer holds, readable, ~2s. Then content fades out, and the shell retracts
on the close spring back to the bare notch. We're at a clean desktop again.

Shot sequence (13s):
- Scene 1 (0.0–3.0s): Centered. Desktop + notch only, dead still. No motion at
  all — the held opening. Caret absent (panel closed).
- Scene 2 (3.0–4.0s): The panel **spring-pops open in place** (width 192→540px,
  bottom radius 9→30px, body opacity 0→1) on the open spring; `panel-open` SFX;
  "Type anything…" placeholder sits at white@38%. Caret appears, begins blink
  (`context-sensitive-cursor`).
- Scene 3 (4.0–9.4s): **type-on with caret** (`discrete-text-sequence`) — the
  query types in at human cadence (~slightly irregular per-char), placeholder
  gone, typed text white@96%, soft `key-type` ticks. Panel width holds at 540px.
- Scene 4 (9.4–10.3s): typing stops. **True stillness** — the sacred pause. Only
  the caret blinks. Nothing else moves.
- Scene 5 (10.3–11.0s): recognition fires. A faint "— Ask" hint **materializes**
  (blur 4→0, opacity 0→1) at white@40% trailing the line; the answer
  "Shanghai is 15 hours ahead of San Francisco." **fades+rises** in below on the
  module spring (white@96%, ~15px). Panel grows intrinsically to fit.
- Scene 6 (11.0–12.0s): **hold the read** — answer still and readable. Caret
  blink only.
- Scene 7 (12.0–13.0s): **close** — content fades out first, then the shell
  retracts (radius 30→9, width 540→192) on the close spring with one soft
  settle; `panel-close` SFX. Ends on the bare clean desktop.

## Frame 2 — Remind

- scene: panel summoned again, types a reminder, recognized → "Added to Reminders"
- duration: 9s
- transition_in: cut
- status: animated
- intent: remind
- typed: "remind me to email the landlord at 6pm"
- response: "Added to Reminders"
- blueprint: compose
- focal: the NotchPanel (synthesized)
- roles: desktop = background (dead still) · notch = anchor · panel = cutout
- sfx: pop, typing, click-soft
- src: compositions/frames/02-remind.html

Same clean desktop continues seamlessly from Frame 1's end (no visible seam —
identical desktop + notch). The panel is summoned again: expand-in-place spring,
soft open SFX, "Type anything…" placeholder.

Typing (~14s): "remind me to email the landlord at 6pm", human cadence, typing
SFX, blinking caret. Around ~18.5s the typing stops.

Shot sequence (9s, frame-local t):
- Scene 1 (0.0–0.4s): Centered. Bare clean desktop + notch, dead still — exact
  continuation of Frame 1's last pixel (invisible cut).
- Scene 2 (0.4–1.4s): panel **spring-pops open in place** on the open spring;
  `panel-open` SFX; "Type anything…" placeholder; caret appears + blinks.
- Scene 3 (1.4–5.5s): **type-on with caret** — "remind me to email the landlord
  at 6pm" types in at human cadence; typed text white@96%; soft `key-type`.
- Scene 4 (5.5–6.4s): typing stops. **True stillness** — the sacred pause; caret
  blink only.
- Scene 5 (6.4–7.1s): recognition fires → a faint "— Remind" hint
  **materializes** (blur 4→0) at white@40%; the feedback line **fades+rises** in
  on the module spring: EXACTLY "Added to Reminders" (white@40%, 12px, no time
  suffix, no icon).
- Scene 6 (7.1–8.0s): **hold the read** (~1.7s app auto-dismiss feel), still.
- Scene 7 (8.0–9.0s): **close** — content fades out, shell retracts on the close
  spring with one soft settle; `panel-close` SFX. Back to the bare desktop.

The deliberate pause. THEN recognized as a reminder: a faint "— Remind" hint,
and the feedback line fades up on the module spring — EXACTLY "Added to
Reminders" (white@40%, 12px, no time suffix, no icon).

The feedback holds, readable (~1.7s, matching the app's auto-dismiss). Content
fades out, shell retracts to the bare notch.

## Frame 3 — Note, and return to stillness

- scene: third summon, types a note, recognized → "Added to Notes", retract to identical opening desktop
- duration: 8s
- transition_in: cut
- status: animated
- intent: note
- typed: "cabin booking code 4471"
- response: "Added to Notes"
- blueprint: compose
- focal: the NotchPanel (synthesized)
- roles: desktop = background (dead still) · notch = anchor · panel = cutout
- sfx: pop, typing, click-soft
- src: compositions/frames/03-note.html

Same clean desktop. Third and final summon: expand-in-place, soft open SFX,
placeholder.

Typing (~23s): "cabin booking code 4471", human cadence, typing SFX. Around
~26s the typing stops.

The pause. Recognized as a note: faint "— Note" hint, then the feedback fades up
— EXACTLY "Added to Notes" (white@40%, 12px, no icon).

Feedback holds briefly. Then content fades out and the shell retracts GENTLY
into the notch on the close spring — settling to a desktop that is byte-for-byte
identical to the very first frame (same gradient, same notch, no cursor). Hold
that stillness for a beat. End.

Shot sequence (8s, frame-local t):
- Scene 1 (0.0–0.4s): Centered. Bare clean desktop + notch, dead still —
  invisible cut from Frame 2's end.
- Scene 2 (0.4–1.4s): panel **spring-pops open in place**; `panel-open` SFX;
  placeholder; caret blinks.
- Scene 3 (1.4–3.6s): **type-on with caret** — "cabin booking code 4471" types
  in at human cadence (shorter line → finishes sooner); `key-type`.
- Scene 4 (3.6–4.5s): typing stops. **True stillness** — the sacred pause.
- Scene 5 (4.5–5.2s): recognition fires → faint "— Note" hint **materializes**;
  feedback **fades+rises** in: EXACTLY "Added to Notes" (white@40%, 12px,
  no icon).
- Scene 6 (5.2–6.2s): **hold the read**, still.
- Scene 7 (6.2–7.2s): **close** — content fades out, shell retracts GENTLY on
  the close spring; `panel-close` SFX.
- Scene 8 (7.2–8.0s): **final hold** — the bare clean desktop, byte-identical to
  Frame 1 Scene 1. Dead still. End.
