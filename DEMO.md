# Event Lead Management — demo runbook

A Salesforce Lightning app for capturing event leads. Attendees scan their QR badge, check in,
and become Leads.

## The model

| Object | Role |
|---|---|
| **Campaign** (standard) | The marketing event. Everything hangs off it. |
| **Event Registry** (custom) | One per campaign. Event name, dates, status, attendance rollups. |
| **Event Attendee** (custom) | The guest list, loaded before the event. Who we *expected*. |
| **Campaign Member** (standard) | Created on a successful scan. Who actually *showed up*. |
| **Contact** (standard) | The person. Found by email, then mobile. Never created twice. |
| **Lead** (standard) | One enquiry per person per event, Lead Source `Events`, plus a follow-up Task. |
| **Badge Scan** (custom) | Audit log. Every attempt, including failures and repeats. |

Someone who registered but never scanned has an Event Attendee row and no Campaign Member.

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
| 1 | Show the record page header | Live counts and progress bar, driven by roll-up summaries, not code. |
| 2 | **Scan** tab → type `User 01` → Enter | A USB scanner is just a keyboard, so there is no integration to build. Green banner: Kavya Kumar is checked in. |
| 3 | Open Kavya's Contact | She already existed. The scan matched on email and reused her rather than creating a second copy. |
| 4 | Scan `User-03` | The QR images are named with hyphens, the badge codes stored with spaces. Either form resolves. |
| 5 | Scan `User 01` again | Yellow banner: already checked in. No second Lead, no second Campaign Member — but it is still audited. |
| 6 | Scan `Nobody 99` | Red banner: not on the guest list. Still audited. |
| 7 | **Search** tab → type `Nair` | Contains-match across name, email, company and badge. Check someone in from the list. |
| 8 | **Walk-in** tab → Zephr Zebra, Zoo Company | Registers a guest-list row with a generated badge code, then checks them in. |
| 9 | Badge Scans tab | Five rows, four outcomes: Checked In, Already Checked In, Not Found, and the manual walk-in. |
| 10 | Leads list view | One enquiry per person, Lead Source `Events`, each with a follow-up Task due in two days. |
| 11 | Salesforce mobile app → same record → **Scan with camera** | Continuous camera scanning. Desktop falls back to the badge input. |

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
- **Attendance totals are declarative.** `Total_Attendees__c` and `Checked_In_Count__c` are roll-up
  summaries, the second filtered on `Checked_In__c`. No code maintains them.
- **The counters that cannot be rollups are recounted.** `Contact.Enquiry_Count__c` and
  `Campaign_Count__c` have no master-detail path, so the service recounts them on check-in.

## Known limits

- Camera scanning works in the Salesforce mobile app only, via `lightning/mobileCapabilities` — not
  in a mobile browser. Desktop uses the badge input, which a USB scanner types into.
- Walk-ups have no QR image. `QR_Code__c` is a formula pointing into the `Attendee_QR_Codes` static
  resource, so a generated `WALK-…` badge renders a broken image on the record page.
- Check-in is refused unless the Event Registry is `Active`. `seedDemo.apex` asserts this.
- Contact matching by phone uses a trailing-digits `LIKE`, which is non-selective. Fine at this
  volume; a normalised indexed phone field is the fix before real scale.
- One scan per call. Bulk import of a scan file is not built.

## Not built (deliberately out of scope for the MVP)

Badge printing, digital badges via a Salesforce Site, badge email batches, driver's licence (AAMVA)
parsing, and platform events for multi-desk live refresh.
