# Scoop

**The health record for a house full of animals.** A native SwiftUI iOS app, built from [a full PRD](docs/PRD.md): the product thinking came first, the code implements it. (Built under the name Gut Check, which the Xcode target still carries; renamed Scoop after checking the App Store field, where nine existing "Gut Check" apps are all human IBS trackers and no pet app is named Scoop.)

When an animal gets sick, its owner becomes an amateur epidemiologist overnight, tracing outputs back to inputs entirely from memory. Memory fails in predictable ways (stool lags intake by 12–36h; nobody records what "normal" looked like; last episode's fix is forgotten by the next one). Scoop is the instrument: episode-based tracking across a multi-pet household, camera-first capture, a daily med checklist for the animal that's never fully well, and a vet-legible summary on demand.

## Screens

| Onboarding | Add an animal | Home |
|---|---|---|
| ![Onboarding](docs/screenshots/onboarding.png) | ![Add an animal](docs/screenshots/add-pet.png) | ![Home](docs/screenshots/home.png) |

| Capture (4C) | Urgent breaks the layout | Meds on the pet screen |
|---|---|---|
| ![Capture](docs/screenshots/capture.png) | ![Urgent](docs/screenshots/capture-urgent.png) | ![Meds](docs/screenshots/pet-meds.png) |

| Pet timeline | Vet summary |
|---|---|
| ![Timeline](docs/screenshots/pet-timeline.png) | ![Summary](docs/screenshots/vet-summary.png) |

## Product decisions worth noticing

- **Episodes, not daily logs.** The central object is a bounded period of abnormality (baseline → watch → 3 consecutive normals → resolution). Healthy animals cost the user nothing; there is no streak to abandon.
- **The 4Cs.** Consistency, Color, Coating, Contents as four independent axes: a perfectly formed stool can still be black and tarry. Owners tap a five-point plain-language scale ("soft serve"); the vet-standard 1–7 value is stored underneath.
- **Urgent findings break the layout.** One-tap muscle memory is the point of capture, so when an axis hits the Urgent tier, the vet action becomes the primary button and plain save demotes to a text link.
- **The camera, not the camera roll.** The capture tile opens the camera directly and the photo goes to Scoop's sandbox only. The app exists so that poop photos stop landing in the Photos library; routing capture through the library picker would have recreated the problem it solves.
- **Multi-pet is the wedge.** Different diets under one roof make the household a natural control group; cross-feeding ("who ate whose food") is a first-class event no single-pet app can represent.
- **Attribution handled honestly.** Anything that preceded an episode by ≤72h (cross-feeding, med changes, new items) is surfaced in the vet summary as association, with dated facts side by side so the vet forms the question. The app never diagnoses.
- **Triage colors mean triage.** The four tier colors are reserved for stool. Meds are blue, supplements teal, due doses and cross-feeding wear the brand color, and a watch-mode card takes the episode's worst tier rather than a fixed amber. If something is amber, it's because a stool was.
- **Playfulness lives in the language, not the icons.** "Soft serve" is a label, not a 🍦. Nothing cute appears past the Monitor tier, and poop photos are blurred until deliberately tapped.

## What's implemented

First-run onboarding (searchable breed picker, profile photo upload, "just looking" demo household) · household home with per-pet status, "Log a poop" as the one primary action, and add-an-animal and sync in the toolbar · 4C capture with direct camera capture and real AI photo scoring via Claude (see below), coating and contents folded into one row until they matter, and backdated logging ("just now / earlier today / yesterday" with a time picker for the retroactive options; the causal windows need honest timestamps) · named food and meds ("Food & meds": a piece of banana, a course of metronidazole, a daily CBD oil, each a reusable item so the third time it precedes an episode the record can say so) · per-pet regimen with morning/evening schedules, a one-tap daily checklist on the home screen, missed doses derived rather than stored, and local 7am/7pm reminders with a "Given" action · long-term meds on an interval (monthly heartworm, a monthly joint injection, a flea treatment every three months): the next dose is derived from the last one logged, surfaced on the pet screen and as a home-screen pill when it's due or coming up, reminded on the day and nagged each morning it's late, and reported to the vet as last given / next due · fixed-length courses ("weekly for 6 weeks", "twice a day for 10 days"): dose 3 of 6 on the checklist, nothing due past the end, and a one-tap "done with it" when the course is complete · four-tier triage ladder with liquid-frequency escalation · episode state machine (baseline → watch → 3 consecutive normals → resolved) with a manual end-episode escape hatch · one-tap interventions · 48-hour lookback · cross-feeding and med/stress exposure events · unified per-pet timeline with swipe-to-delete (mis-logs must be fixable; they feed triage and the vet summary) · pet editing (photo, breed, birthday, conditions) · archive/restore animals (history kept) · CloudKit household sync with partner invites (see below) · shareable vet summary, medication-first: current meds with adherence and stools-before-vs-since, what changed this month, what the gut did, flags, what preceded episodes by ≤72h, the owner's own one-line note (persisted on the pet), and an AI-written opening line on top (see below).

## Scope cuts

The PRD specs more than this. Three features were built, then deliberately cut to keep V1 honest. The core job is *track poop changes, capture what preceded them, hand the vet a summary*, and everything below needs episode history that a new user won't have:

- **Protocol capture & replay** ("this worked last time, run it again"). A retention feature that delivers nothing until episode #2, which may be months away. Interventions are still logged live ("what have you tried" is a question every vet asks), but they're a record, not a replayable protocol. Strongest V2 candidate.
- **The Insights tab.** The association engine's real distribution channel is the vet summary, where a professional interprets the correlations. A standalone insights screen is the most speculative surface in the app and the emptiest on day one.
- **Chronic pinning** (a mode for animals whose episode never closes). Real need, edge persona. The kind of thing you add when a chronically-ill-dog owner asks for it. *Partly back in:* the daily med checklist, long-term intervals, and fixed-length courses exist now because a chronically unwell dog in the house asked for them. They cost nothing for animals with no scheduled meds, which keeps the "healthy animals are free" rule intact, and they reshaped the vet summary: for a chronic animal the first thing the vet wants is the current regimen, so the summary now leads with it.

**Also not yet:** PDF export, the second-opinion loop, a backend proxy for the AI calls, and cross-episode pattern-spotting (designed but unbuilt; see "Where the AI is, and where it isn't" below).

## AI photo scoring

Attach a photo in capture and Claude (`claude-sonnet-5`, vision) scores all four axes and prefills the chips. Design choices worth noticing:

- **The model proposes, the owner disposes.** Scores prefill the chips; the human can override every axis before saving, and the stored record is always owner-confirmed. The AI never writes to the record directly, which is how the no-diagnosis principle survives adding a model.
- **Structured output, not parsed prose.** The request forces a strict tool call whose schema enums match the app's `Codable` raw values exactly, so a malformed response is impossible rather than parsed hopefully.
- **Honest abstention.** The model returns `unscorable` per axis when the photo doesn't support a judgment, and low-confidence axes are flagged as "double-check" in the UI. A non-stool photo is called out instead of scored.
- **Graceful degradation.** No API key means the copy changes and capture is fully manual. Nothing breaks for repo cloners.

To enable it locally, create `GutCheck/Secrets.plist` (gitignored, bundled by an optional build step, never referenced by the committed project):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>ANTHROPIC_API_KEY</key>
    <string>sk-ant-your-key-here</string>
</dict>
</plist>
```

A key in the app bundle is a local-development convenience; shipping this for real means a small backend proxy holding the key server-side.

## Where the AI is, and where it isn't

The vet summary is computed. The headline counts are arithmetic over the 30-day window, the "before episodes" list is date math over logged exposures and cross-feeds, and each med's adherence and stools-before-vs-since are counts. That's a decision, not a gap:

- **The summary is the document a vet acts on.** It's the last place you want generative variability. A deterministic summary is auditable: every line traces to a logged event, and nothing can be invented.
- **The dangerous failure isn't fabrication, it's soft inference.** A model summarizing "ate another pet's food 30h before onset" will drift toward "likely dietary indiscretion." Nothing was made up, but an association became a causal claim under the app's name.

There is one place the model does speak: the **opening line**, a card at the top of the summary. It is deliberately tiny. Not a summary of everything below it, but the two or three sentences an owner says in the first thirty seconds of the appointment ("she's on a daily probiotic, missed one dose; started a joint supplement ten days ago; soft stools the last two days, none before that") so the conversation with the vet starts faster and the vet reads the rest of the sheet already knowing what matters. The facts stay computed; the model only orders and phrases them.

What keeps it on the right side of the no-diagnosis line lives in code, not in the prompt:

- **Every sentence must cite the facts it restates.** The model returns sentences with fact numbers through a strict tool call; an uncited sentence is dropped before rendering.
- **Every number must appear in a cited fact next to the same neighbouring word.** "3 missed" has to exist somewhere in the cited facts as "3 missed". A recombined or invented figure drops the sentence.
- **Any causal wording drops the sentence.** "Likely", "because", "related", "consistent with", "suggests" and their kin are a blocklist. The model is allowed to restate; it is not allowed to explain.
- **The summary is complete without it.** No API key, no meds and no episodes, or a response that fails every guard, and the card simply isn't there.

So AI sits at the noisy input end (photo scoring, where a human reviews every proposal before saving) and at the very top of the output end as a short, fenced, fully cited restatement. The clinical body of the summary stays deterministic.

Still unbuilt, by design: a **cross-episode "patterns you might ask about" layer** that reads the structured event log and returns observations under the same citation rule, rendered as questions and visibly fenced off from the factual record. It's unbuilt for the same reason protocol replay was cut: pattern-spotting across episodes has nothing to say until a user has several, and a day-one summary would render an empty section. Strongest V2 pairing: replay says "this worked last time," patterns say "this preceded it last time."

## Household sync (CloudKit)

The multi-pet household is the wedge, so the household is also the sync unit: one partner owns the record zone in their private iCloud, shares it zone-wide (CKShare), and everyone else logs into the same zone from their own phone through the shared database. Built on CKSyncEngine with no backend at all; photos ride along as CKAssets.

- **The JSON store stays the source of truth.** CloudKit mirrors it: every domain record syncs as one CKRecord carrying the same JSON the local file stores, so there is exactly one schema and the tolerant-decoding rules protect both paths.
- **Graceful degradation, again.** No iCloud account, or a clone built without the CloudKit container, and the app is exactly as local-only as it was before sync existed. The sync row on the home screen says so instead of pretending.
- **Conflicts are last-writer-wins per record.** Two people rarely edit the same poop. The failure mode this accepts (simultaneous edits to the same record, one wins) is much cheaper than the merge machinery it avoids.
- **Joining replaces.** Accepting a household invite makes the shared household your household. V1 rule, documented rather than hidden.
- **The demo household never syncs.** "Just looking" is a clearly labeled local sandbox: the engines stay down while it's active, and it has an explicit exit back to onboarding. Demo animals that earlier builds leaked into a real household get scrubbed on sight, locally and from the zone. A demo animal that was renamed into a real one keeps its identity and loses only the pretend history it came with.

Activating it requires an Apple Developer Program membership (the iCloud container is provisioned through the paid account); without one the code paths above simply stay dark.

## Build & run

Requires Xcode with the iOS platform installed.

```bash
brew install xcodegen   # once
xcodegen generate
open GutCheck.xcodeproj
```

No dependencies: plain SwiftUI, iOS 16.4+, JSON persistence. The project file is generated from `project.yml`; domain logic (triage tiers, resolution counting, dose schedules) is UI-free in `GutCheck/Domain.swift` and unit-checked with the CLI toolchain alone. The simulator has no camera, so the capture tile falls back to the photo library there.

## Provenance

Spec'd in [PRD v0.3](docs/PRD.md) (problem → target user → core model → workflows → success metrics → risks), then built and iterated in-simulator with [Claude Code](https://claude.com/claude-code) and on two phones through TestFlight. PRD and product direction by Meagan Glenn.
