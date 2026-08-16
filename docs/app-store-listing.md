# App Store listing draft

Everything App Store Connect will ask for, in the order it asks. Character limits noted.

## App information

- **Name** (30): Scoop: Pet Poop & Gut Tracker
- **Subtitle** (30): Health records for every animal
- **Bundle ID**: com.meagan.scoop
- **SKU**: scoop-ios
- **Primary category**: Health & Fitness
- **Secondary category**: Lifestyle
- **Content rights**: does not contain third-party content
- **Age rating**: answer "None" to everything; unrestricted (4+)

## Pricing and availability

Free. All territories.

## Privacy

- **Privacy policy URL**: publish `docs/privacy.md` (GitHub Pages on the repo, or the README's raw link works for review)
- **Data collection**: if the AI scorer is disabled for the release build, answer "Data Not Collected". If enabled, declare **Photos or Videos** under "Data Not Linked to You", purpose "App Functionality", not used for tracking.
- CloudKit household data stays in the user's iCloud, which Apple treats as not collected by the developer.

## Version information

**Promotional text** (170, editable without a new build):
Track poop, appetite, and stress for every animal in the house. Know when it's a wait-and-see and when it's a call-the-vet.

**Description** (4000):

Scoop is the health record for a house full of animals.

Log what came out, what went in, and what changed, in about ten seconds. Scoop keeps it as episodes, not a pile of entries, so you can see whether things are getting better or worse and hand your vet a clean summary instead of a scroll through your camera roll.

BUILT FOR MULTI-PET HOMES
- Add every animal once, with photo and breed
- Log for one pet or several at a time (yes, including who stole whose food)
- One timeline for the whole household

CAPTURE THAT TAKES SECONDS
- Four quick taps: consistency, color, coating, content
- Optional photo attach
- Urgent signs get a different screen, because that's not the moment for chips

EPISODES, NOT ENTRIES
- Scoop groups related events into an episode and tracks it to resolution
- 48-hour lookback: what did they eat, what changed, what meds or stress happened
- Cross-feeding and exposure tracking across pets

A SUMMARY YOUR VET WILL ACTUALLY READ
- One-tap vet summary with timeline, exposures, and ages
- Every line traces to something you logged. No guesses.

PRIVATE BY DESIGN
- Everything stays on your phone
- Optional household sync through your own iCloud, so partners see the same records
- No accounts, no ads, no analytics

Scoop is a tracker, not a diagnosis. When something looks urgent, it tells you to call your vet.

**Keywords** (100, comma separated, no spaces):
pet health,dog poop,cat poop,stool tracker,vet,pet diary,dog health,cat health,symptom log,pet record

**Support URL**: https://github.com/meagan-glenn/gutcheck
**Marketing URL**: (optional, leave blank)
**Copyright**: 2026 Meagan Glenn

**What's New** (1.0): First release.

## Screenshots

Required: 6.9" iPhone (1320 x 2868 or 1290 x 2796). Regenerate `docs/screenshots` on the iPhone 17 Pro Max simulator. Suggested order:
1. Home, multi-pet household with an open episode
2. Capture sheet, four axes
3. Episode timeline
4. Vet summary
5. Household sync / onboarding

Optional: 6.5" set is auto-scaled from 6.9" if omitted.

## App Review information

- **Sign-in required**: No
- **Notes for reviewer**: "Scoop is a local-first pet health tracker. No account is needed. Tap 'load a demo household' on the welcome screen to see it populated. Household sync uses the reviewer's own iCloud and is optional."
- **Contact**: Meagan Glenn, meag.glenn@gmail.com, phone on file

## Export compliance

Uses only HTTPS (exempt). Answer: uses encryption → yes; qualifies for exemption → yes.

## Before you press Submit

- [ ] Decide AI scorer: off for 1.0 (delete Secrets.plist before archiving) or behind a proxy
- [ ] MARKETING_VERSION 1.0.0, CURRENT_PROJECT_VERSION bumped
- [ ] Triage copy says "call your vet", never diagnoses
- [ ] Privacy policy URL live
- [ ] Screenshots uploaded at 6.9"
- [ ] TestFlight build has run on two real phones for at least a week
