# Event Lead Management — demo runbook

A Salesforce Lightning app for capturing event leads. Attendees scan their QR badge, check in,
and become Leads.

## The model

| Object | Role |
|---|---|
| **Campaign** (standard) | The marketing event. Everything hangs off it. |
| **Event Registry** (custom) | One per campaign. Event name, dates, status, attendance totals. |
| **Event Attendee** (custom) | The guest list, loaded before the event. Who we *expected*. |
| **Campaign Member** (standard) | Created on a successful scan. Who actually *showed up*. |
| **Contact** (standard) | The person. Found by email, then mobile. Never created twice. |
| **Lead** (standard) | One enquiry per person per event, Lead Source `Events`, plus a follow-up Task. |
| **Badge Scan** (custom) | Audit log. Every attempt, including failures and repeats. Flags an ambiguous match. |
| **Account** (standard) | The company. Matched by name from the badge, created the first time it is seen. |

Someone who registered but never scanned has an Event Attendee row and no Campaign Member.

The funnel reads **Invited → Registered → Attended**: `Invited_At__c` is stamped when the guest
list is loaded, `Registered_At__c` when someone registers themselves, and `Checked_In_At__c` when
they arrive.

## The public registration page

```
https://orgfarm-3be7c7306a-dev-ed.develop.my.salesforce-sites.com/event/EventRegister
```

No login. Open it in a **private window** during the demo, so nobody can say it only worked
because you were signed in.

## Before each rehearsal

```bash
sf apex run --file scripts/apex/seedDemo.apex     # event Active, 'Attended' status, badges to scan
```

Prints the event Id and the first five badge codes. Both scripts are idempotent.

To clear everything the app created and start again:

```bash
sf apex run --file scripts/apex/resetDemo.apex
```

Returns the org to 22 Contacts / 24 Leads / 0 Badge Scans / 0 Campaign Members, with all 30
attendees unchecked and the event back to `Active`.

## Running it

Open the **Event Lead Management** app → **Event Registries** → *Trade Show 2026*. The check-in
component sits on the record page.

| Step | Do this | Point out |
|---|---|---|
| 1 | **Private window** → the public registration URL → register yourself | No login. Anyone can register from their phone. |
| 2 | Watch the QR badge appear on screen | Rendered in the browser from a 128-bit token, so there is no QR encoder in Apex and nothing is sent to an outside service. The same badge is emailed with the PNG attached. |
| 3 | Register again with the same email, then with a typo in the domain | Both return the original badge. Dedupe is on the email, then on surname plus mobile, which is what catches gmail versus gamil. |
| 4 | Back in Salesforce, open the new Event Attendee | Invited At, Registered At and a Badge Token. No Contact yet — registering is not attending. |
| 5 | Show the record page header | Live counts and a progress bar, counted in Apex rather than stored. |
| 6 | **Scan** tab → type `User 01` → Enter | A USB scanner is just a keyboard, so there is no integration to build. Green banner: Kavya Kumar is checked in. |
| 7 | Open Kavya's Contact | She already existed, so the scan reused her rather than creating a second copy. She is also now attached to the **Circuitry Labs** Account, matched from the badge. |
| 8 | Scan `User-03` | The QR images are named with hyphens, the badge codes stored with spaces. Either form resolves. |
| 9 | Scan `User 01` again | Yellow banner: already checked in. No second Lead, no second Campaign Member — but it is still audited. |
| 10 | Scan `Nobody 99` | Red banner: not on the guest list. Still audited. |
| 11 | **Search** tab → type `Nair` | Contains-match across name, email, company and badge. Check someone in from the list. |
| 12 | **Walk-in** tab → Zephr Zebra, Zoo Company | Registers a guest-list row with a generated badge code, then checks them in. |
| 13 | Badge Scans tab | Five rows, four outcomes: Checked In, Already Checked In, Not Found, and the manual walk-in. |
| 14 | Leads list view | One enquiry per person, Lead Source `Events`, each with a follow-up Task due in two days. |
| 15 | Salesforce mobile app → same record → **Scan with camera** | Continuous camera scanning. Desktop falls back to the badge input. |

### Also worth showing

- The Contact created by a scan is attached to an **Account** matched from the badge's company.
- If two Contacts match the same person, the scan still goes through but **Needs Review** is
  ticked on the audit row — the door keeps moving and the ambiguity is not hidden.

## What to say about the design

- **One service, two entry points.** `BadgeScanService.processScan` and `registerWalkUp` share a
  single check-in transaction, so a walk-up and a scanned badge follow exactly the same path.
- **Every attempt is audited.** Not Found, Already Checked In and Error all write a `Badge_Scan__c`
  row. The error path rolls the business DML back with a savepoint and then writes its audit row
  separately, because an uncaught exception in an `@AuraEnabled` method would discard the whole
  request including the audit.
- **Deduplication is in the data, not the code.** `Enquiry_Key__c` (`{registryId}|{contactId}`, 37
  of its 40 characters) is a unique external ID, so a repeat scan cannot raise a second enquiry even
  under a race.
- **The duplicate rule is opted out of deliberately.** The org's Standard Lead Duplicate Rule blocks
  a Lead matching an existing Contact — which is exactly what an enquiry is here. The service sets
  `DuplicateRuleHeader.AllowSave`, and relies on `Enquiry_Key__c` for real deduplication.
- **Attendance totals are counted, not stored.** They used to be roll-up summaries, but public
  registration required the attendee relationship to become a lookup and roll-ups only work on
  master-detail. `getEventSummary` counts instead, so the numbers cannot drift. Restoring them as
  stored fields is a record-triggered Flow, which is the planned next step.
- **The counters that cannot be rollups are recounted.** `Contact.Enquiry_Count__c` and
  `Campaign_Count__c` have no master-detail path, so the service recounts them on check-in.

## Known limits

- Camera scanning works in the Salesforce mobile app only, via `lightning/mobileCapabilities` — not
  in a mobile browser. Desktop uses the badge input, which a USB scanner types into.
- The old `QR_Code__c` formula only resolves for the 30 originally loaded badges, so a walk-up or a
  registration shows a broken image on the record page. Their real badge is the token one, rendered
  by the registration and badge pages.
- Check-in is refused unless the Event Registry is `Active`. `seedDemo.apex` asserts this.
- Contact matching by phone uses a trailing-digits `LIKE`, which is non-selective. Fine at this
  volume; a normalised indexed phone field is the fix before real scale.
- One scan per call. Bulk import of a scan file is not built.

## Not built (deliberately out of scope for the MVP)

Badge printing, driver's licence (AAMVA) parsing, platform events for multi-desk live refresh, and
booth-level product interest — the last of these is the one remaining use case, and it is not
additive: a second scan currently means "already checked in", whereas at a booth it would be a
legitimate visit.
