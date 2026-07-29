# Rapture end to end

A walkthrough for wiring voice capture into an agentic setup, written for
people who intend to point their own tooling at the output.

The shape:

```
you speak  ->  a note becomes a file  ->  your agent reads the folder
```

Everything below is about the middle step. Once files are landing, see
[`examples/`](../examples/) for the agent side.

There are two capture paths. They file into the same folder with the same
contract — a `source:` field in each note says which path produced it — and you
can run both at once. Start with the first one: it is free, takes about five
minutes, and needs no iPhone app at all.

---

## Path A: iMessage, phone locked, five minutes

Siri will send a text while your phone is locked, even though iOS will not let
it launch an app. That is the whole trick. Your Mac reads the message and files
it.

**1. Install Rapture for Mac.** Download the DMG from
[Releases](https://github.com/NoiseMeldOrg/rapture-mac/releases/latest) and drag
it to Applications.

**2. Grant Full Disk Access** when prompted. The app reads
`~/Library/Messages/chat.db`, which is where Messages stores everything
locally. macOS gates that behind FDA. Nothing works without it.

**3. Send yourself a note.** With the phone locked, in your pocket:

> "Hey Siri, text me the auth middleware should use row level security"

**4. Check the folder.** Within a second or two:

```
~/Documents/Rapture Notes/Notes/2026-07-29 The auth middleware should use row level security.md
```

Default titling is mechanical — the first words of the dictation, verbatim. The
opt-in AI tier writes condensed titles instead.

The app also replies in the Messages thread, so you get confirmation on the
phone without looking at the Mac.

**If nothing lands**, it is almost always Full Disk Access. Check System
Settings, Privacy & Security, Full Disk Access, and confirm Rapture for Mac is
listed and enabled. Quit and reopen the app after granting it.

That is the entire free path. No iPhone app, no account, no purchase.

---

## Path B: the iOS app, with on-device transcription

Path A uses Siri's own dictation. Path B runs the models on the phone instead:
Parakeet for speech on the Neural Engine, and a 1.7B Qwen through MLX to
structure the note. It also captures a whole rambling minute rather than a
single sentence, and pulls to-dos out as checkboxes.

The trade is that iOS will not launch an app while the phone is locked, so this
path needs a Face ID glance.

**1. Install Rapture** from the
[App Store](https://apps.apple.com/us/app/id6759532741) or
[Google Play](https://play.google.com/store/apps/details?id=com.noisemeld.rapture).

**2. Let the models download.** About 1.4 GB, once. Be on Wi-Fi.

> **Keep the screen awake for this.** If the phone sleeps, iOS suspends the app
> and the transfer stops. Plug in and leave the screen on until it finishes.
> This is a known rough edge and it is being fixed.

**3. Capture.** Say "Hey Siri, Rapture this" and talk. It stops on its own when
you stop speaking. Everything from here is on-device, so it works in airplane
mode.

**4. Turn on Mac delivery.** Settings, Destinations, Rapture Mac.

> This one is the paid feature. Capture, transcription, formatting, search and
> history are all free forever. Sending finished notes off the device is a
> single one-time unlock, not a subscription.

**5. The note appears in the same folder** as Path A, filed the same way.

The relay runs through your own iCloud. The phone writes each capture into a
hidden folder inside Rapture's iCloud container, which on the Mac is:

```
~/Library/Mobile Documents/iCloud~noisemeld~Rapture/Relay/
```

macOS syncs it down, the Mac app files the arrival and deletes the relay copy.
An empty relay folder means everything has been delivered. Neither app has
network code for this. It reads a local folder and the operating system moves
the bytes.

**If notes are not arriving**, check that the Mac is awake and signed into the
same iCloud account, and that Settings, General, iPhone App is on in the Mac
app. It is on by default and is a no-op until the relay folder first appears.

---

## What lands on disk

This is the part that matters if you are integrating.

```
~/Documents/Rapture Notes/
├── Notes/          voice notes
├── Links/          bare URLs, filed separately
│   └── Media/      fetched transcripts and article text (opt-in)
├── Tasks/          )
├── Ideas/          ) only with the opt-in AI tier
└── Journal/        )
```

Find the folder programmatically rather than assuming the default. The app
writes a sidecar — one line, the absolute path, no trailing newline:

```
~/Library/Application Support/Rapture for Mac/output-folder.path
```

Every note is Markdown with YAML frontmatter. A voice note:

```yaml
---
captured: 2026-07-29T14:32:11Z
source: rapture-mac
type: voice-note
---
```

A captured link, after classification:

```yaml
---
captured: 2026-07-29T15:04:56Z
source: rapture-mac
type: article-link
raw_media: https://example.com/some-article
---
```

The fields:

- `captured` — the UTC instant, ISO 8601. The filename carries the local
  calendar date; this field is the precise one.
- `source` — which app captured it: `rapture-mac` (the iMessage path — named
  for the app that does the capturing), `rapture-ios`, or `rapture-android`
  (the app relay). Optional: a note recovered from an old backlog can lack it.
- `type` — one of `voice-note`, `youtube-link`, `article-link`, `task`,
  `idea`, `journal`. The last three appear only with the AI tier on.
- `raw_media` — link notes only: the URL as captured, stable even after
  enrichment renames the note. Absent on everything else.

When a formatter changed the body — the AI tier, or the iOS app's structuring —
the verbatim transcription is preserved under a `## Raw` heading in the same
file. A body that is already verbatim gets no `## Raw` section.

Classification is deterministic by default. No AI, no network: bare links go to
`Links/`, everything else to `Notes/`. The optional AI tier refines into
`Tasks/`, `Ideas/` and `Journal/` using Apple Intelligence on-device where
available, or your own Anthropic key. It is off by default, and the verbatim
dictation is always preserved in the note either way.

Prefer raw timestamped `.txt` instead? Settings, Triage, then switch Filing to
"Raw text files, no triage". The same plain files the app wrote before triage
existed.

---

## Wiring it to an agent

The folder is the entire integration surface, so anything that reads files
works. Starter configs for the agents people usually arrive with live in
[`examples/`](../examples/): Claude Code, OpenClaw, Hermes, and a generic POSIX
shell script.

The shape they all share:

1. Resolve the output folder from the sidecar above.
2. Watch the triaged subfolders for new `.md` files. Skip `Links/Media/`, which
   holds fetched artifacts rather than notes.
3. Read the frontmatter, act on `type`.
4. Record the note as handled so it is not acted on twice.

The app has already done the classifying, so the interesting question moves up a
level. Not "what is this note" but "what should happen because of it."

---

## Rough edges, stated honestly

- **The model download does not survive the screen sleeping.** Path B only.
  Keep the screen on for the first launch. Being fixed.
- **Path B needs a Face ID glance.** iOS will not let Siri launch any app while
  locked. This is an OS constraint rather than a bug, and Path A exists because
  of it.
- **The relay needs the Mac awake.** Notes queue in iCloud and arrive when it
  next syncs. Nothing is lost, but it is not instant if the Mac is asleep.
- **Link enrichment is best-effort.** Fetching YouTube transcripts and article
  text can fail. The note is complete without it.

---

## Feedback

If something here does not match what your install actually does, that is worth
an issue. The examples in particular are written from current agent
documentation rather than tested against every install, and the gap between
those two things is exactly what is useful to hear about.
