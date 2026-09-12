# PRD: Gut Check (working title) — v0.3

**The health record for a house full of animals.**

Status: Draft v0.3 · Owner: Meagan · Last updated: Aug 2026

> **Built since v0.3 (Sep 2026), not yet folded into the spec:** the chronic-animal need cut in §11 came back as a concrete feature set once a chronically unwell dog in the house asked for it. Named food and meds as reusable items; a per-pet regimen with a morning/evening dose checklist on the home screen; long-term meds on an interval (next dose derived from the last one logged); fixed-length courses; local reminders. The W8 vet summary was reordered medication-first (current meds with adherence, then what changed, then what the gut did) and the generated "questions for the vet" were replaced by dated facts side by side plus the owner's own note. §10's AI surface gained one output-side element: a two-to-three-sentence opening line, fully cited and guarded in code. The README documents the shipped state; this document is kept as the spec the build started from.

> **What changed from v0.2:** Capture restructured around the **4Cs** — Consistency, Color, Coating, Contents — as four independent axes instead of one score plus a flag bucket. Consistency split into a **five-point owner scale** (logs / a little soft / soft serve / diarrhea / liquid) displayed over a stored 1–7 veterinary value, with the dry end demoted behind a *more* control. Flat red-flag list replaced with a **four-tier triage ladder** that mirrors the convention every vet-facing chart already uses. Icon asset strategy simplified to shape-plus-tint.
>
> *From v0.1:* continuous daily logging and single-pet assumptions were replaced by the **episode** state machine inside a **multi-pet household**; cross-feeding, protocol capture, and household-vs-pet item scoping added.

---

## 1. Problem

When an animal gets sick, its owner becomes an amateur epidemiologist overnight — watching outputs (stool, nasal discharge, vomit, appetite, energy) and trying to trace them back to inputs. The tracing runs entirely on memory, and memory fails in four specific ways:

1. **The lag.** Stool reflects intake from 12–36 hours earlier. People instinctively examine *today's* food, which is the wrong window.
2. **The blank baseline.** You can't tell what's abnormal for an animal if you never recorded what normal looked like. By the time you care, it's too late to establish it.
3. **The lost playbook.** You fast, add pumpkin, switch to bland, drop the new chew — it resolves. Four months later it happens again and you remember none of it.
4. **The exam room compression.** A month of observation becomes "he's been having some issues lately?" The signal dies exactly where it matters.

Current workaround: a camera roll full of poop photos and a text thread with your partner asking "does this look bad to you?"

## 2. Target user

**Primary: multi-pet DINK households.** No kids, disposable income, pets are dependents, high willingness to spend on animal health, already fluent in tracking apps. Typically 2–4 animals, at least one with a chronic or recurring issue.

**Why multi-pet is the wedge, not a feature:** a single healthy dog might have four episodes a year — that's a dormant app, and dormant apps get deleted before the moment they're needed. A household of three where one is chronically unwell is *never* fully quiet. The sick one drives daily engagement and gets the app installed; the healthy ones sit dormant at zero cost until the day they don't — and by then you have twelve months of their baseline. Every additional animal raises engagement and lowers churn **without adding proportional logging burden**, because most pets are in baseline mode at any given time. That's the inverse of most tracking apps.

**Trigger event:** a diagnosis, or a new puppy, or an unexplained recurring issue. Nobody installs this while everything is fine.

**Anti-persona:** single healthy pet, casual owner. Will not sustain. Do not design for them.

## 3. Goals & non-goals

**Goals**
- Capture an abnormal output in under 5 seconds, camera-first.
- Require near-zero effort from healthy animals.
- Detect patterns across episodes and across animals that no owner could see unaided.
- Record what was done to fix it, and hand it back next time.
- Produce a vet-legible summary on demand.
- Support a household logging against one shared timeline.

**Non-goals (v1)**
- Diagnosis. Ever. This is an observation instrument, not a clinical one.
- Telemedicine, vet marketplace, vet-side accounts.
- Wearables, activity, GPS.
- Continuous daily food logging. It's not how people behave and the product no longer needs it.

## 4. Core model: the episode

The central object is not a log entry. It's an **episode** — a bounded period of abnormality with a beginning, an intervention, and an end.

```
BASELINE  ──"Something's off"──►  WATCH  ──3 consecutive normals──►  RESOLVING
   ▲                                │                                    │
   └──────── confirm resolved ──────┴──────── prompt: what fixed it? ─────┘
```

**Baseline mode** — the default. Effectively dormant. Med reminders if any, an optional weekly ten-second check-in, nothing else. No streaks, no nudges, no guilt. A healthy animal costs the user nothing.

**Watch mode** — activated by the user tapping **Something's off**, or automatically suggested when an abnormal output is logged. Every output gets logged. Interventions get logged. The lookback fires. This is the intensive state and it's the only state that asks anything of the user.

**Resolution** — after three consecutive normal outputs, the app asks whether it's over. On confirmation, it captures the protocol while it's fresh and returns the pet to baseline.

**Chronic pets** can be pinned in a persistent watch state — for animals like a dog with an ongoing respiratory/gut condition, the episode never really closes, and forcing one would be dishonest.

**Why this matters:** it eliminates the input-decay risk that dominated v0.1. There is no daily logging to abandon. It also makes correlation honest — comparing four clean episodes is far stronger than inferring from four hundred noisy daily entries, and it can be stated without overclaiming: *"This is Navi's 4th soft-stool episode. Three of four began within 48h of a new chew."*

## 5. Core objects

| Object | Notes |
|---|---|
| **Household** | The account root. Members, pets, shared items. Billing unit. |
| **Pet** | name, species, breed, DOB, weight, conditions, photo, mode (baseline/watch/chronic) |
| **Item** | **Scoped: household or pet.** Food, treat, chew, med, supplement, water source. Brand, ingredients, first-introduced date |
| **Output event** | stool / nasal / vomit / urine. Photo, score, flags, timestamp, logged-by |
| **Intake deviation** | Only logged when it differs from the pet's baseline diet. Includes new items. |
| **Cross-feeding event** | who ate whose, approximate amount |
| **State event** | appetite, energy, mood, plus condition-specific trackers |
| **Intervention** | what the owner did: fasted, bland diet, added pumpkin, removed item, probiotic, vet visit, med |
| **Episode** | start, end, all events within, protocol used, outcome |
| **Protocol** | a reusable bundle of interventions, with an episode-count track record |
| **Insight** | detected pattern, strength, counter-evidence, status |

### Item scoping ⭐

The single most important structural decision in v0.2.

**Pet-scoped:** meals, prescription diets, medications, supplements. In a multi-diet household these differ per animal, which turns the household into a **natural control group** — if two animals on completely different foods degrade in the same week, food is largely ruled out.

**Household-scoped:** treats, chews, water source, yard, trail, table scraps, house guests, boarding. This is where culprits actually live. Meals are the most controlled part of an animal's intake — measured, scheduled, consistent. Treats are chaos: unmeasured, impulsive, handed out by two different people, forgotten by morning.

A household item correlating with symptoms in **multiple** animals is a dramatically stronger finding than anything a single-pet app can produce.

### Cross-feeding ⭐

Multiple diets under one roof means animals eat each other's food. Constantly. The puppy inhales the prescription GI food; the senior gets into puppy kibble. It's a Tuesday event, and it's precisely the thing that explains a bad stool 24 hours later and is completely forgotten by the time you're standing over it.

First-class event type, one tap: **who ate whose, roughly how much.** Feeds directly into the lookback. Invisible to every single-pet app on the market.

Also produces an unusually actionable recommendation. If the same theft repeatedly precedes the same symptom, the advice isn't dietary — it's *feed them in separate rooms.*

## 6. Capture model: the 4Cs

Reference charts across the category converge on four independent observations — **Consistency, Color, Coating, Contents**. They're independent because they carry different information: a perfectly formed stool can be black and tarry; a watery stool can be a normal brown. Collapsing them into one score loses the signal that matters most.

Four axes, and three of them are usually "normal" — so it stays fast.

### C1 — Consistency

**Two scales, one tap.** The owner sees five plain-language options; the AI grades finer and stores the veterinary 1–7 value underneath. Owners don't care about the difference between a 2 and a 3 — vets do, and the model can tell from the photo either way.

| What the owner taps | Stored | Tier |
|---|---|---|
| Logs | 2–3 | Normal |
| A little soft | 4 | Monitor |
| Soft serve | 5 | Monitor |
| Diarrhea | 6 | Concern |
| Liquid | 7 | Urgent if 3+ in 24h |
| *Hard* (secondary) | 1 | Monitor |

**Why the hard end is demoted.** In households with a chronically unwell animal, constipation is rarely what gets logged — nearly all the variance lives on the wet end, which is why the owner-facing scale splits finely there and collapses the dry end. Hard still exists (dehydration, low fiber, seniors, prescription diets) but sits behind a **more** control rather than occupying a primary chip. Same pattern applies to every axis: common values are one tap, rare values are two, nothing is unreachable.

**Chip ordering optimizes for correction speed, not clinical sequence.** Because the AI pre-fills and the user only corrects, the chip most likely to be reached for when the model is wrong should sit closest to the thumb. Real ordering is a usage-data question — build the flexibility now.

### C2 — Color

| Color | Common association | Tier |
|---|---|---|
| Brown | Normal | Normal |
| Green | Grass eating, high-veg diet, occasionally gall bladder or parasites | Monitor |
| Yellow / orange | Bile or liver, food intolerance, recent diet change | Concern |
| Grey / greasy | Fat malabsorption, pancreas | Concern |
| Red streaks | Lower-GI bleeding or rectal irritation | Concern |
| White / chalky | Excess calcium or bone | Monitor |
| Black / tarry | Upper-GI bleeding | **Urgent** |
| Pink / purple | Possible HGE | **Urgent** |

### C3 — Coating
None · mucus / slimy jelly-like (inflammation, parasites, stress) · greasy or shiny sheen.

### C4 — Contents
None · white rice-like specks (tapeworm) · grass · hair · foreign material · visible blood.

### Nasal (parallel ladder)
Clear → cloudy → yellow → green. One nostril or both. Same tier logic.

### Asset strategy

Because shape and color are independent axes, the icon set is **7 silhouettes × tint**, not one drawing per combination. 7 shapes × 8 colors = 56 states from 7 assets, with coating and contents rendered as small overlays. Tiny commission, complete clinical coverage.

**Visual direction:** flat silhouettes, single consistent stroke weight, morphology doing the work so the progression reads without labels. Expressiveness must *decrease* as severity rises — a cute face on chocolate brown is charming; a cute face on black-tarry-may-mean-internal-bleeding is a tonal failure. No faces past the Monitor tier.

**Not emoji.** A 1–7 scale must look ordinal — mismatched emoji art styles can't show that 4 sits between 3 and 5, several are food (in an app about what the animal ate), and they render differently across iOS/Android/web, meaning a clinical scale that changes appearance by device.

**Playfulness lives in the language, not the icons.** "Soft serve" as a label is funny and memorable. 🍦 as the icon is neither.

**Every dog's normal is different.** The published charts tell you what's normal in general; this app learns what's normal *for this animal*. That's the whole pitch, and it's the per-pet baseline argument in one line.

## 7. Workflows

### W1 — Onboarding (sequential, household-framed)
1. **"Who lives with you?"** — household frame established before any pet exists. Even for a single-pet user, this teaches the right mental model and means pet #2 later feels like completing the picture, not discovering an upsell.
2. Add pets **one at a time** — name, photo, species, age. Not a three-column form.
3. **"Which one are you worried about right now?"** — warm, natural, and it identifies the install reason.
4. **Lopsided setup by design.** Deep on the worried-about pet: diet, conditions, meds, current symptoms → straight into watch mode. Shallow on the others: name, photo, food, done. Framed explicitly as *"we'll fill these in as we go — they're here so we can compare."*
5. Household items get built opportunistically through use, not through a setup form.

### W2 — Log an output (target: 5 seconds)
1. Widget or app icon → camera already open, pet pre-selected.
2. Snap. Timestamp captured, location optional (surfaces "always bad after the trail" patterns).
3. AI returns a suggestion across **all four axes** with per-axis confidence — consistency score, color, coating, contents.
4. Tap **Looks right** to accept all four, or correct any single axis. The median log is one tap — roughly four seconds from opening the camera.
5. Optional one-line note. Done.

**Urgent findings must break the layout, not just tint a banner.** When any axis hits the Urgent tier, the vet action is promoted to the primary button and confirm is demoted to a text link. Otherwise the muscle memory built from one-tapping normal logs will blow straight past the one that mattered.

**The photo is tappable to zoom** — the second-opinion flow means a partner is judging that image on their own phone.

**Why four axes helps speed rather than hurting it:** the model classifies four narrow things instead of one mushy composite, which raises accuracy, which means more one-tap accepts. Users only touch an axis when the AI got it wrong.

**Failure handling:** low confidence (grass, night, snow) → the app does *not* guess on that axis. It shows the options and asks. One confidently wrong score early destroys trust in every insight that follows.

**Photo storage:** option to auto-delete originals after N days, keeping the 4C values + thumbnail. Thousands of poop photos in someone's iCloud is a real objection.

### W3 — Enter watch mode
Triggered by the **Something's off** button (the primary home screen action) or offered automatically after an abnormal log.

On entry: confirm the pet, note what's wrong, run the lookback (W4). App shifts to intensive logging until resolution.

### W4 — The 48-hour lookback ⭐
Immediately on any abnormal output or watch-mode entry, the app shows everything logged in the relevant window — pet items, household items, cross-feeding events, new items highlighted.

Then one prompt: *"Anything we missed?"* with quick-add chips: found something outside · table food · new chew · med change · travel/boarding · stressful event · got into someone else's food.

This catches the user mid-trace — the exact moment they're standing there going "wait, what did she eat yesterday" — and captures the memory while it still exists.

### W5 — Intervention logging & protocol capture ⭐
Throughout watch mode, one-tap interventions: fasted · bland diet · added pumpkin/fiber · probiotic · removed an item · started a med · called the vet · vet visit.

**On resolution:** *"Looks like this cleared up. Here's what you did — anything else?"* Confirmed set is saved as a **protocol** attached to the episode.

**On the next episode:** the app opens with it.

> *This is Navi's 4th gut episode. Last time (March 14, 4 days): fasted 12h, chicken and rice from day 2, dropped bully sticks. Resolved day 4. Run the same protocol?*

This is the compounding asset — the app is worth more at episode three than episode one, which is the retention mechanic this product needs.

### W6 — The attribution problem (handled honestly) ⭐
People change three things at once. You fast, add pumpkin, drop the chew, and call the vet inside 48 hours, then it resolves. **Which one worked is not answerable**, and no controlled reintroduction is happening on a sick animal.

**The app does not pretend otherwise.** Three mechanisms instead:

1. **Record the bundle, not the cause.** "Here's what worked" is genuinely useful without any causal claim. Protocols are bundles by default.
2. **Narrow across episodes.** If episode 1 used four interventions and episode 2 resolved with two, the intersection tightens on its own. After several episodes: *"Bland diet appears in all 4 resolutions. Pumpkin appears in 2 of 4."* Still association, stated as such.
3. **Reintroduce after recovery, not during.** The safe window to test a suspected trigger is once the animal is well. Optional structured reintroduction: add the item back, watch 72h, record the result. Voluntary, never nagged, and the only path to genuine confirmation.

### W7 — Insights & cross-pet signals ⭐
Episode-level comparison rather than daily correlation. Rules that keep it honest: minimum 3 co-occurrences before surfacing; always framed as association; **counter-evidence always shown** (if the chew was given 10 times and only 3 preceded issues, say so); every insight confirmable or dismissable, and dismissals train the pet's model.

**Cross-pet signals — only possible in this product:**
- Two+ animals degrade in the same window on *different* diets → food largely ruled out, look at household items or environment.
- Two+ animals degrade after the same household treat → strong shared-trigger finding.
- One animal degrades, others fine, following cross-feeding → likely the stolen food.
- All animals fine except the chronic one → likely condition-related, not environmental.

### W8 — Vet summary
One tap, chosen date range, exports as PDF or link.

- **Headline:** "Navi, last 30 days: 3 episodes, 24 of 31 stools normal."
- **Episode cards:** dates, duration, symptoms, suspected triggers, protocol used, outcome.
- **Trend sparkline** with intake changes marked.
- **Flag log:** every blood/mucus/color event with dates and thumbnails.
- **Med adherence.**
- **Open questions for the vet** — phrased as questions, never conclusions.
- **Owner notes**, verbatim.

Print-friendly, one page by default, appendix behind it.

### W9 — Household & second opinion ⭐
Owner signs in, invites partner. Shared real-time timeline, every event stamped with who logged it.

**Second opinion loop** — replaces the existing text thread. Tag any entry *"Does this look bad to you?"* → pushes to the other member → 👍 fine / 😐 not sure / 👎 looks bad. Both opinions attach to the entry. Disagreement itself becomes data: *"You and Chris have disagreed on 8 of 30 — you score consistently softer."*

Later: read-only links for vets, sitters, walkers.

### W10 — Adding more pets
Skipping must be genuinely free — the app has to be good for one animal. Multi-pet is upside, not a dependency. The moment it feels required, a stressed person is doing chores for dogs they aren't worried about.

**Never prompt immediately after pet #1** — worst possible moment. Better hooks:
- **First treat log:** "Who else got one?" → pets added as a byproduct of something useful.
- **First insight:** "Only Navi is tracked, so we can't tell if this is him or the whole house." Value is self-evident rather than asserted.
- **A quiet persistent card** on the home screen. Not a modal. Not a nag.

### W11 — Triage tiers ⚠️
Replaces the flat red-flag list. Four tiers, mirroring the convention every vet-facing chart already uses — which makes it both vet-legible and familiar to users who have googled this before.

| Tier | Triggers | App behavior |
|---|---|---|
| **Normal** | Score 2–3, brown, no coating, no contents | Log and move on. No friction. |
| **Monitor** | Score 1, 4–5; green; white/chalky; rice-like specks | Gentle suggestion to open watch mode |
| **Concern** | Score 6; mucus coating; greasy; grey; yellow/orange; red streaks | Prominent notice + offer to generate a summary |
| **Urgent** | Black tarry; bright red; pink/purple; score 7 three or more times in 24h; no food 24h+; repeated vomiting; labored breathing | Non-dismissible notice, routed to vet immediately |

**This stays on the right side of the no-diagnosis line.** Urgency triage is not diagnosis. "This warrants a call today" is a different claim from "your dog has pancreatitis," and every published vet chart already tiers exactly this way.

Copy pattern: *"This is one of the things vets want to know about promptly. Want to generate a summary to bring or send?"* → vet summary.

Never "your dog may have X." Never "wait and see."

## 8. UX principles

1. **The home screen is one button: Something's off.** Everything else is secondary.
2. **Camera-first, not form-first.**
3. **Confirm, don't compose.** Typing is always optional.
4. **Healthy animals cost nothing.** Baseline mode is silent.
5. **No streaks, no guilt.** Someone tracking a sick animal must never feel they failed the app.
6. **Playful language, serious icons.** Nothing cute near a red flag.
7. **The app never says what's wrong.** It says what happened and what's unusual for this animal.

## 9. Screens (v1)

- **Home** — Something's off button; per-pet status cards; anything active
- **Capture** — camera → score confirm
- **Watch mode** — active episode view: timeline, interventions, resolution progress
- **Episode history** — past episodes per pet, with protocols
- **Insights** — open patterns, confirmed triggers, cross-pet signals
- **Pet profile** — baseline, diet, conditions, items
- **Household** — members, pets, shared item library
- **Summary builder**

## 10. AI surface

| Feature | Job |
|---|---|
| Photo scoring | 4C classification (consistency 1–7, color, coating, contents) with per-axis confidence gating |
| Nasal classification | Clear → green ladder |
| Episode correlation | Cross-episode and cross-pet association with significance floor |
| Protocol narrowing | Intersection analysis across resolutions |
| Summary generation | Log → vet-legible narrative + questions |
| Note parsing | "only ate half and seemed tired" → structured events |
| Voice logging (v2) | Hands-free while holding a leash and a bag |

**Guardrails:** confidence thresholds with graceful "not sure — you tell me"; zero diagnostic language in generated text; every generated claim traceable to logged entries; disclaimer on all exports.

## 11. Scope

**MVP**
Household onboarding (sequential) · episode state machine · photo capture + AI scoring with manual override · custom icon scale · 48h lookback · intervention logging + protocol capture and replay · household vs pet item scoping · cross-feeding events · basic cross-pet signals · vet summary PDF · household invite + second opinion · red flag notices.

**V2**
Post-recovery reintroduction testing · elimination trial mode · voice logging · cats · condition-specific modules (respiratory, skin, joint) · vet read-only links · ingredient-level analysis · barcode food scanning.

**V3**
Anonymized cohort benchmarks · food database with ingredient parsing · breed-specific baselines · vet-side dashboard.

## 12. Success metrics

- **Activation:** household created with 2+ pets, one episode opened, within 48h of install.
- **Multi-pet attach rate:** % of households with 2+ animals. The core thesis — if this is low, the wedge is wrong.
- **Episode completion rate:** % of opened episodes that reach confirmed resolution with a captured protocol. Abandoned episodes mean watch mode is too heavy.
- **Protocol replay rate:** % of episodes 2+ that start from a prior protocol. **This is the retention proof** — it means the app got more valuable over time.
- **Insight confirm rate:** confirmed vs dismissed. Below ~40% means the engine is generating noise and eroding trust.
- **Summary generation:** % generating a vet summary within 30 days — the moment the product proves it was worth installing.
- **Household attach rate:** % with 2+ human members.

## 13. Risks

| Risk | Mitigation |
|---|---|
| Watch mode too heavy, episodes abandoned mid-stream | Ruthless 5-second capture; interventions one tap; never require notes |
| Dormancy between episodes | Multi-pet household union is rarely quiet; chronic pet drives daily opens |
| Photo scoring fails in real conditions | Confidence gating, always-available manual scale, capture tips |
| Insight engine surfaces noise | Occurrence floor, counter-evidence shown, dismissals train the model |
| Perceived as practicing veterinary medicine | Strict non-diagnostic copy, disclaimers, red flags route to vet |
| Onboarding wall with 3 pets | Sequential, lopsided depth, opportunistic item building |
| Pricing taxes the thesis | Price per **household**, never per pet |
| It's a poop app and people are squeamish | Lean in. The humor is the marketing. |

## 14. Open questions

1. **Free vs paid line.** Logging free, insights + summaries + protocol history paid? Household pricing confirmed, but at what tier?
2. **Does the vet actually read it?** Worth 5 informal interviews with vet techs on acceptable format.
3. **AI accuracy floor.** How wrong can first-suggestion scoring be before trust breaks? Guess: needs ~85%+.
4. **Cats.** Litter box observation is more frequent and cat owners over-index on health anxiety. Fast follow or v1?
5. **Second opinion async vs real-time.** Is there a genuine "look at this *now*" moment?
6. **Chronic pinning.** Does a permanently-watched animal need a different, lighter interaction model than an acute episode?
7. **Scale validation.** Confirm the 1–7 numbering and tier assignments against the chart the target clinic actually uses — several published variants disagree at the margins.
