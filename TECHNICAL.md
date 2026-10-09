# Event Lead Management — technical documentation

Written for a developer who has to **present, defend and maintain** this app. It assumes you can
code but does not assume deep Salesforce platform knowledge, so every platform term used is defined
where it first matters.

- `DEMO.md` — the script to run on the day
- This document — what we used, why we used it, and how it works

---

## 1. What the app does

An attendee walks up to a booth at a trade show. They show a QR badge. Someone scans it. In one
transaction the system must:

1. Recognise who they are from the badge
2. Record that they physically arrived
3. Make sure they exist as a person exactly once, never duplicated
4. Raise a sales enquiry for them, once per event
5. Create a follow-up task so someone calls them
6. Log the scan — **including when it fails**

Everything below exists to serve those six things.

---

## 2. The technology stack — what each piece is and why we chose it

### 2.1 Apex — the back end

**What it is.** Salesforce's server-side programming language. Strongly typed, Java-like syntax,
runs inside Salesforce's multi-tenant servers. You cannot run arbitrary servers on Salesforce;
Apex is the only way to execute custom server logic.

**Why we used it here.** Four things made Apex mandatory rather than optional:

| Requirement | Why only Apex can do it |
|---|---|
| Roll back a half-finished check-in | `Database.setSavepoint()` / `Database.rollback()`. Declarative tools have no transaction control |
| Write the audit row *after* a rollback | Requires catching the exception and issuing fresh DML — impossible declaratively |
| Bypass the org's Lead duplicate rule | `Database.DMLOptions.DuplicateRuleHeader.AllowSave` is Apex-only |
| Branching logic with 4 outcomes and 2 entry points | Expressible in Flow, but unmaintainable and untestable at this complexity |

**Why not Flow?** Flow is Salesforce's declarative automation tool (drag-and-drop logic). It is the
right default for simple record automation and is preferred by Salesforce for maintainability. We
rejected it because it has no savepoints, no exception handling that survives rollback, no duplicate
rule override, and no unit test framework comparable to Apex tests. The audit-row-survives-rollback
behaviour — the core correctness property of this app — simply cannot be built in Flow.

**Key Apex concepts used:**

- **SOQL** (Salesforce Object Query Language) — read-only query language, SQL-like but with
  relationship traversal instead of joins: `SELECT Campaign__r.Name FROM Event_Registry__c`.
- **DML** (Data Manipulation Language) — the write statements: `insert`, `update`, `delete`,
  `upsert`. Each statement counts against a limit.
- **Governor limits** — because thousands of customers share the same servers, Salesforce caps what
  one transaction may consume: **100 SOQL queries** and **150 DML statements** per transaction, plus
  CPU and heap caps. Exceeding one is an unrecoverable error. This is the single biggest constraint
  on Salesforce design, and it is why you never put a query inside a loop.
- **Trigger** — Apex that runs automatically on a DML event (`before insert`, `before update`, …).
  `ContactTrigger` is one, and §9 explains how it broke this app.
- **`with sharing`** — the class respects the running user's record visibility. Without it, code
  runs in system context and sees everything. Ours is `with sharing` because a booth user should not
  gain access they do not otherwise have.
- **`@TestVisible`** — lets tests read private members without making them public.

### 2.2 LWC — the front end

**What it is.** **Lightning Web Components.** Salesforce's modern UI framework, built on genuine web
standards — Web Components (custom elements, shadow DOM), ES modules, plain modern JavaScript. A
component is a folder of `.js`, `.html`, `.css` and a `.js-meta.xml` configuration file.

**Why LWC over the alternatives:**

| Option | What it is | Why not |
|---|---|---|
| **Aura** | Salesforce's older component framework (2014) | Legacy, heavier, proprietary syntax. Salesforce recommends LWC for all new work |
| **Visualforce** | Original page technology, server-rendered HTML + Apex controllers | Full page reloads, no reactive UI, and **cannot access the mobile camera** |
| **Screen Flow** | Declarative wizard UI | No camera access, no custom result banners, limited layout control |
| **LWC** ✅ | Standards-based components | The only option with `lightning/mobileCapabilities`, i.e. the only one that can scan a badge with the phone camera |

**The deciding factor was mobile scanning.** Camera barcode scanning on Salesforce is exposed
through the `lightning/mobileCapabilities` module, which is **available to LWC only**. Had we used
Flow or Visualforce, the entire mobile half of this app would be impossible.

**Key LWC concepts used:**

- **`@api`** — marks a public property settable from outside. `@api recordId` is how a component on
  a record page learns which record it is on; the framework injects it automatically.
- **`@wire`** — reactive data binding. It calls an Apex method and re-calls it automatically
  whenever a referenced property changes. A `$` prefix marks reactivity: `'$recordId'`.
- **`@track`** — makes changes *inside* an object or array reactive. Plain reassignment of a
  primitive is already reactive without it.
- **`@AuraEnabled`** — the Apex-side annotation that exposes a method to Lightning components.
  Without it the method is invisible to the UI, whatever its access modifier.
- **`cacheable=true`** — allows the result to be cached client-side by **Lightning Data Service**
  and is **required for `@wire`**. A cacheable method **may not perform DML**. This is why
  `getEventSummary` and `searchAttendees` are cacheable but `processScan` is not.
- **`refreshApex`** — forces a cached wire to re-fetch. Essential here: after a scan the counts
  would otherwise be served from cache and never move.
- **Imperative Apex call** — a direct `await processScan({...})`, used when you need to act on a
  user event rather than react to data.
- **Shadow DOM** — each component's markup and CSS are encapsulated; styles do not leak in or out.
  This is why `eventCheckIn.css` can use plain class names like `.row` with no risk of collision.

### 2.3 Where the data lives

**Standard objects** are the ones Salesforce ships: Campaign, Contact, Lead, Task, CampaignMember.
**Custom objects** are ones you define; they end in `__c`, as do custom fields.

**Why we used both.** The guiding rule is *use standard objects wherever the concept already
exists*, because they come with reporting, list views, mobile support, campaign ROI and permissions
for free. We added custom objects only where the standard model genuinely had no equivalent:

| Concept | Where it lives | Reasoning |
|---|---|---|
| The event | **Campaign** (standard) | Salesforce's native marketing-event object. Gives campaign ROI and influence reporting at no cost |
| Who attended | **CampaignMember** (standard) | The native join between a Campaign and a Contact/Lead |
| The person | **Contact** (standard) | Never reinvent the person |
| The enquiry | **Lead** (standard) | Already has `LeadSource`, conversion, assignment rules, duplicate rules |
| Follow-up | **Task** (standard) | Appears natively in the activity timeline and in "my tasks" |
| Event metadata and totals | **`Event_Registry__c`** (custom) | Campaign has no start/end/status fields matching the brief, and no place to hang attendance roll-ups |
| The pre-loaded guest list | **`Event_Attendee__c`** (custom) | **No standard equivalent.** CampaignMember means "is a member"; we needed "was expected, badge issued, has not arrived yet" as a distinct state |
| Scan attempts | **`Badge_Scan__c`** (custom) | No standard object records *failed* attempts. CampaignMember records state, not events |

**The conceptual point to be able to defend:** `Event_Attendee__c` is who we **expected**;
`CampaignMember` is who **showed up**. Someone who registered but never scanned has an attendee row
and no campaign member. Collapsing the two — which is what a Campaign-only design does — loses the
ability to answer "who were the no-shows?" and loses the scan audit trail entirely.

### 2.4 Platform features used

| Feature | What it is | Why here |
|---|---|---|
| **Master-detail relationship** | Tight parent-child. Child is owned by the parent, deleted with it, inherits its sharing | `Event_Attendee__c → Event_Registry__c`. **Required for roll-up summaries** |
| **Lookup relationship** | Loose reference, like a nullable foreign key | Everywhere else — `Badge_Scan__c → Contact`, etc. |
| **Roll-up summary** | A declarative COUNT/SUM/MIN/MAX over master-detail children, maintained by the platform | `Total_Attendees__c`, `Checked_In_Count__c`. **No code maintains these** |
| **Formula field** | Computed on read, never stored | `QR_Code__c` (renders the badge image), `Event_Name__c` |
| **Unique + External ID** | Database-enforced uniqueness, indexed, usable as an upsert key | `Enquiry_Key__c`, `Badge_Id__c`, `Attendee_Key__c`, `Campaign_Key__c` — our **race-condition protection** |
| **AutoNumber** | Platform-generated sequential name | `ATT-{00000}`, `BS-{00000}`. Never set in code |
| **Static resource** | A file or zip hosted by the org, served from `/resource/<Name>` | `Attendee_QR_Codes` — the 30 badge PNGs |
| **Permission set** | An *additive* grant of access, assignable to many users | `Event_Check_In_User` |
| **Profile** | The single baseline permission container, exactly one per user | Not modified — permission sets are the modern, additive practice |
| **FlexiPage** | The metadata behind a Lightning page | `Event_Registry_Check_In` — hosts the component |
| **Duplicate rule** | Declarative duplicate blocking | `Standard_Lead_Duplicate_Rule`, which we deliberately bypass (§6.7) |

### 2.5 Tooling

- **Salesforce CLI (`sf`)** — deploys, retrieves, queries, runs tests and anonymous Apex.
- **SFDX source format** — metadata decomposed into readable per-field files
  (`objects/Event_Attendee__c/fields/Badge_Id__c.field-meta.xml`) rather than one giant XML blob.
  This is what makes the repo diffable in git.
- **`manifest/event-app.xml`** — the package manifest pinning exactly which metadata belongs to this
  project, so `sf project retrieve start --manifest manifest/event-app.xml` reproduces it.
- **Anonymous Apex** — ad-hoc script execution, used throughout for verification against real data
  inside a savepoint that is then rolled back.

---

## 3. Architecture

```
  Lightning record page  (Event_Registry__c)
  └── eventCheckIn  (LWC)
        │   @wire getEventSummary      ← cacheable, live counts
        │   @wire searchAttendees      ← cacheable, guest list
        │   imperative processScan / registerWalkUp
        ▼
      BadgeScanService  (Apex, with sharing)
        │
        ├── processScan(registryId, badgeId, method)      scanned badge
        └── registerWalkUp(registryId, details)           no badge
                    │
                    └──► checkIn()   ← ONE shared transaction
                              │
      ┌───────────────────────┼────────────────────────────┐
      ▼                       ▼                            ▼
   Contact              CampaignMember                   Lead
  (email→phone→new)      (status 'Attended')     (Enquiry_Key__c unique)
                                                          │
                                                          ▼
                                                        Task
                              │
                              ▼
                 Event_Attendee__c flags + Contact counters
                              │
                              ▼
                      Badge_Scan__c  ← always, every outcome
```

**The key structural decision:** `processScan` and `registerWalkUp` both funnel into one private
`checkIn()`. A walk-up and a scanned badge are identical from the moment an attendee row exists,
so walk-ups get a Lead, a Task and an audit row with zero duplicated logic.

---

## 4. Data model in detail

### `Event_Registry__c` — the event

| Field | Type | Purpose |
|---|---|---|
| `Campaign__c` | Lookup, required | The event *is* a Campaign; this wraps it with event metadata |
| `Campaign_Key__c` | Text(18), **unique**, external ID | Holds the Campaign Id. The unique index is what enforces "exactly one registry per campaign" — a database guarantee, not a validation rule that can be bypassed |
| `Status__c` | Picklist | Planned / Active / Completed / Cancelled. Check-in is refused unless Active |
| `Start_Date__c`, `End_Date__c` | Date | Event window |
| `Total_Attendees__c` | **Roll-up** COUNT | Every child attendee row |
| `Checked_In_Count__c` | **Roll-up** COUNT filtered `Checked_In__c = true` | Arrivals |

Two roll-ups over the same child relationship differing only by filter. Roll-ups require
master-detail, which is why the attendee relationship is master-detail and not a lookup.

### `Event_Attendee__c` — the guest list

| Field | Type | Purpose |
|---|---|---|
| `Name` | **AutoNumber** `ATT-{00000}` | Platform-generated; never set in code |
| `Event_Registry__c` | **MasterDetail**, required | Parent. Enables the roll-ups |
| `Badge_Id__c` | Text(80), **unique org-wide** | Human-readable badge reference. Unique across the *whole object*, not per event — this drives the walk-up and registration code generators |
| `Badge_Token__c` | Text(32), unique, external ID | **The QR payload.** 128 bits from `Crypto.generateAesKey(128)` as hex. Replaced the guessable sequential `User 01`; `findAttendee` resolves either, so the originally printed badges still work |
| `Attendee_Key__c` | Text(120), unique | `{registryId}\|{email}`. Stops one person being loaded twice for one event |
| `First_Name__c` … `Title__c` | Text/Email/Phone | Badge details, copied to Contact and Lead on check-in |
| `Checked_In__c` | Checkbox | The flag the roll-up filters on |
| `Checked_In_At__c` | DateTime | When |
| `Contact__c`, `Lead__c` | Lookups | Filled at check-in — the link from *expected* to *actual* |
| `QR_Code__c` | **Formula** IMAGE | `IMAGE("/resource/Attendee_QR_Codes/" & SUBSTITUTE(Badge_Id__c," ","-") & ".png", …)` |
| `Event_Name__c` | **Formula** | `Event_Registry__r.Name` |

**The hyphen/space trap — remember this one.** Badge codes are stored with a space (`User 01`). The
QR *filenames* use a hyphen (`User-01.png`) because the formula substitutes one for the other. A
reader may therefore return either form. `findAttendee` builds all three variants and resolves them
in a single query rather than three:

```apex
Set<String> variants = new Set<String>{ code, code.replace('-',' '), code.replace(' ','-') };
... WHERE Event_Registry__c = :id AND Badge_Id__c IN :variants LIMIT 1
```

### `Badge_Scan__c` — the audit log

AutoNumber `BS-{00000}`. `Result__c` ∈ {Checked In, Already Checked In, Not Found, Error};
`Scan_Method__c` ∈ {Camera Scan, Manual Check-in}; `Scanned_At__c`; nullable lookups to Attendee,
Campaign, Contact and Lead — nullable because a failed scan may have none of them.

**Every exit path writes exactly one row.** The object records *attempts*, not state. State lives
on `Checked_In__c`.

### Standard object additions

- `Lead.Enquiry_Key__c` — Text(**40**), unique. The dedupe key; its 40-char cap shaped the key
  format (§6.6).
- `Lead.Campaign__c`, `Contact__c`, `Event_Registry__c` — context links.
- `Contact.Enquiry_Count__c`, `Campaign_Count__c` — plain Numbers. **They cannot be roll-ups**,
  because Lead and CampaignMember are not master-detail children of Contact. Apex recounts them.
- `LeadSource` already contains `Events`.

---

## 5. Navigation paths

### Desktop

```
App Launcher (⠿ top-left)
  └─ "Event Lead Management"
       ├─ Home
       ├─ Event Registries   ← start here
       │    └─ "Trade Show 2026"
       │         ├─ Highlights panel          (name, status)
       │         ├─ ▣ Event Check-In          ← the LWC
       │         │     ├─ Scan      tab
       │         │     ├─ Search    tab
       │         │     └─ Walk-in   tab
       │         ├─ Related lists              (Event Attendees, Badge Scans)
       │         └─ Details sidebar
       ├─ Event Attendees    (the loaded guest list, QR images visible here)
       └─ Badge Scans        (the audit log — show this after scanning)
```

Direct URL to the record page:
`/lightning/r/Event_Registry__c/a04jV000000XLnFQAW/view`

Open it from the CLI without logging in manually:

```bash
sf org open --path "/lightning/r/Event_Registry__c/a04jV000000XLnFQAW/view"
```

### Mobile (Salesforce mobile app)

```
Salesforce app  →  log in to the same org
  └─ ☰  →  Event Lead Management  →  Event Registries
       └─ "Trade Show 2026"
            └─ scroll past the highlights panel
                 └─ ▣ Event Check-In
                      └─ [ Scan with camera ]   ← appears on mobile only
```

The highlights panel renders above the component because the page uses the
`flexipage:recordHomeTemplateDesktop` template; on a phone you scroll past it. A phone-specific page
assignment would put the scanner first, and is worth doing only if the scroll proves annoying.

### How the page is wired up

Two separate pieces of metadata, both required:

1. **`Event_Registry_Check_In.flexipage-meta.xml`** — the Lightning page itself, placing
   `eventCheckIn` in the `main` region.
2. **`actionOverrides` on `Event_Registry__c`** — assigns that page as the org default for the
   `View` action, for **both** `Large` (desktop) and `Small` (phone) form factors.

---

## 6. `BadgeScanService` walkthrough

`force-app/main/default/classes/BadgeScanService.cls`

### 6.1 Public surface

```apex
@AuraEnabled                  processScan(Id registryId, String badgeId, String scanMethod) → ScanResult
@AuraEnabled                  registerWalkUp(Id registryId, WalkUpRequest details)          → ScanResult
@AuraEnabled(cacheable=true)  getEventSummary(Id registryId)                                → EventSummary
@AuraEnabled(cacheable=true)  searchAttendees(Id registryId, String term, Boolean onlyIn)   → List<AttendeeRow>
```

Only the read methods are `cacheable` — a cacheable method may not perform DML.

### 6.2 `processScan` — the guard sequence

Order matters; each guard writes its own audit row where one is meaningful:

1. **Null registry** → failure, **no** audit row (nothing to relate it to; the UI should never do this)
2. **Registry not found** → failure
3. **`Status__c != 'Active'`** → audit `Error`. Stops a booth device checking people into last
   year's event
4. **Blank code** → audit `Error`. An unreadable badge *is* an attempt
5. **No matching attendee** → audit `Not Found`
6. Otherwise → `checkIn()`

### 6.3 `checkIn` — the shared transaction

```apex
if (attendee.Checked_In__c) { log 'Already Checked In'; return; }   // idempotent, still audited

Savepoint sp = Database.setSavepoint();
try {
    Contact person = resolveContact(attendee);
    ensureCampaignMember(registry.Campaign__c, person.Id);
    Lead enquiry   = ensureEnquiry(attendee, registry, person.Id);
    update attendee flags;
    refreshContactCounters(person.Id);
    log 'Checked In';
} catch (Exception e) {
    Database.rollback(sp);
    log 'Error';                  // ← separate DML, AFTER the rollback
    return failureResult(...);    // ← returns, does NOT throw
}
```

**Why it returns instead of throwing — the subtlest thing in the codebase.** An uncaught exception
in an `@AuraEnabled` method rolls back *every* DML in the request. If this method threw, the `Error`
audit row would be destroyed along with the failed check-in, and the audit log would silently lose
exactly the events it exists to capture. So: roll back the business DML by savepoint, write the
audit row as a fresh statement, hand the UI a result object.

### 6.4 `resolveContact` — email, then phone, then create

```apex
WHERE Email = :attendee.Email__c                       // exact; the field is case-insensitive
WHERE MobilePhone LIKE :tail OR Phone LIKE :tail       // tail = '%' + last 9 digits
```

Trailing digits, so `+91 94489 68265` still matches `9448968265`. `digitsOnly()` strips non-numerics
first.

**Known weakness — say it before you are asked:** a leading-wildcard `LIKE` is non-selective and
will table-scan as Contact volume grows. Acceptable at 22 Contacts and one scan per call; the real
fix is a normalised, indexed phone field.

### 6.5 `ensureCampaignMember`

Campaign member statuses are defined **per campaign**, so `Attended` is not guaranteed to exist.
`attendedStatusFor()` returns `Attended` if present, else the campaign's default. If a member
already exists (invited, then showed up) it updates the status — CampaignMember has a unique
constraint on campaign + contact, so a second insert would throw.

### 6.6 `ensureEnquiry` — the dedupe key

```apex
key = String.valueOf(registryId).left(18) + '|' + String.valueOf(contactId).left(18);
// 18 + 1 + 18 = 37 characters, inside Enquiry_Key__c's 40
```

- **Keyed on Contact, not on the attendee row**, because "one enquiry per person per event" means
  *person*. Two guest-list rows resolving to the same Contact correctly yield one enquiry.
- **Enforced by a unique index, not by a code check.** Two simultaneous scans cannot both create a
  Lead, even though the code reads then writes. A SOQL check alone would race.

The Task is created **only alongside a new Lead**, so a repeat scan never duplicates it. It is left
unassigned, defaulting to the scanning user.

### 6.7 `allowKnownDuplicates` — the one that bit us

The org has **`Standard_Lead_Duplicate_Rule` active**, which blocks a Lead matching an existing
Contact. This app deliberately creates a Lead for a person it just resolved as a Contact — that *is*
the enquiry model. The first live run failed with `DUPLICATES_DETECTED`.

```apex
Database.DMLOptions options = new Database.DMLOptions();
options.DuplicateRuleHeader.AllowSave = true;
```

The rule is bypassed; the guarantee is not — `Enquiry_Key__c` and `resolveContact` still enforce
real deduplication, more strictly than the fuzzy standard rule.

### 6.8 Walk-ups

`Badge_Id__c` is unique **across the whole object**, so a generated code must be globally unique:

```apex
WALK- + epoch millis + '-' + 4 random digits      // WALK-1791397066551-7515
```

with **one retry on `DmlException`** for two devices registering in the same millisecond. If the
email already belongs to a loaded attendee, that person is checked in instead — the unique
`Attendee_Key__c` would reject the insert anyway, so it is handled deliberately.

### 6.9 Inner classes

`ScanResult`, `EventSummary`, `WalkUpRequest`, `AttendeeRow`, all with `@AuraEnabled` properties so
LWC can read them. **Apex forbids static members on inner classes**, which is why the result
factories (`checkedInResult`, `notFoundResult`, …) live on the outer class.

### 6.10 Measured governor cost

Real numbers from `Limits` in the org, not estimates:

| Path | SOQL | DML |
|---|---|---|
| New person checked in | **10** | **8** |
| Repeat scan | 2 | 1 |
| Unknown badge | 2 | 1 |
| Limit per transaction | 100 | 150 |

The 10 includes two queries from `ContactTrigger`, which fires on both the Contact insert and the
counter update. Headroom ≈ **10 scans per transaction** — ample for one-at-a-time scanning, and a
clear signal that a bulk import path would need restructuring rather than a loop.

---

## 7. `eventCheckIn` LWC

`force-app/main/default/lwc/eventCheckIn/`

```
eventCheckIn.js            logic
eventCheckIn.html          template
eventCheckIn.css           scoped styles (shadow DOM — no global leakage)
eventCheckIn.js-meta.xml   where it may be placed, and on which form factors
```

### 7.1 Reactivity

```js
@wire(getEventSummary,  { eventRegistryId: '$recordId' })
@wire(searchAttendees,  { eventRegistryId: '$recordId', term: '$searchTerm', checkedInOnly: '$checkedInOnly' })
```

`$` marks a reactive parameter — the wire re-runs whenever that property changes, so typing in the
search box re-queries automatically with no event wiring.

The wired **result envelopes** are stored, not just `.data`, because `refreshApex` needs the whole
object:

```js
await Promise.all([refreshApex(this.summaryResult), refreshApex(this.attendeeResult)]);
```

Called after every scan. Without it the header counts are served from the Lightning Data Service
cache and never move — the classic `cacheable=true` gotcha.

### 7.2 Three details that are easy to get wrong

- `getEventSummary` returns a **zeroed summary** when the record is not found, because the App
  Builder renders components on a blank canvas with no `recordId`; a single-row query assignment
  would throw `QueryException` and show an error instead of the component.
- `searchAttendees` applies the checked-in toggle **in Apex, not SOQL** — SOQL cannot bind a bare
  boolean (`AND :someBoolean = false` is invalid syntax).
- **`like` is a reserved word in Apex**; the search variable is named `pattern`.

---

## 8. Mobile scanning — how it actually works

### 8.1 The mechanism

```js
import { getBarcodeScanner } from 'lightning/mobileCapabilities';

this.scanner = getBarcodeScanner();
this.cameraAvailable = !!this.scanner && this.scanner.isAvailable();
```

`lightning/mobileCapabilities` is a **bridge module**. The Salesforce mobile app is a native iOS or
Android application that renders Lightning pages inside an embedded web view. That module is the
JavaScript end of a bridge into the **native** camera and barcode decoder.

Consequences you must understand:

- `getBarcodeScanner()` returns a usable scanner **only inside the Salesforce mobile app**.
- In a desktop browser, or even a *mobile browser* visiting Salesforce, `isAvailable()` is `false`.
- Decoding happens in **native code**, not JavaScript. That is why it is fast, works in poor light,
  and needs no QR-decoding library bundled into the component.

### 8.2 Continuous capture

```js
const options = {
    barcodeTypes: [this.scanner.barcodeTypes.QR, this.scanner.barcodeTypes.CODE_128],
    instructionText: 'Point the camera at a badge',
    successText: 'Badge read'
};

let barcode = await this.scanner.beginCapture(options);   // opens the native camera UI

while (barcode) {
    await this.submitScan(barcode.value, 'Camera Scan');  // round-trip to Apex
    barcode = await this.scanner.resumeCapture();         // camera stays open
}
```

- **`beginCapture`** opens the native scanner and resolves with the first barcode.
- **`resumeCapture`** keeps the same session open for the next badge — this is what makes a queue of
  attendees flow without reopening the camera each time.
- **`endCapture`** closes it, in a `finally` block so it always runs.

```js
catch (error) {
    if (error && error.code !== 'userDismissedScanner') { showError(); }
}
```

**`userDismissedScanner` is the normal exit, not a failure.** The user closing the camera rejects
the promise. Treating it as an error would show a red banner every single time someone finished
scanning.

`barcode.value` is just a string — the badge code. It goes straight to `processScan` as `badgeId`,
which is why camera, USB scanner and typing all converge on identical server logic.

### 8.3 Desktop: a USB scanner needs no integration at all

A handheld or USB barcode scanner is a **keyboard-wedge** device: the operating system sees a
keyboard. It "types" the decoded characters and sends `Enter`. So the desktop path is simply:

```js
handleBadgeKey(event) {
    if (event.key === 'Enter') { this.submitScan(event.target.value, 'Manual Check-in'); ... }
}
```

No driver, no SDK, no integration. Plugging in a scanner just works. This is worth saying out loud
in the demo — people expect it to be complicated.

### 8.4 Form factors — the bug worth remembering

An LWC on a record page is **desktop-only unless it declares otherwise**. Without this, the App
Builder shows "Unsupported form factor" in Phone view, locking the component out of the only
environment where its camera scanner can run:

```xml
<supportedFormFactors>
    <supportedFormFactor type="Large"/>
    <supportedFormFactor type="Small"/>
</supportedFormFactors>
```

This is **separate from** the page assignment form factor set in the object's `actionOverrides`.
Both are required; we initially had only the latter.

### 8.5 What the QR contains

`Badge_Token__c` — 32 hex characters, 128 bits of randomness. The earlier design encoded
`Badge_Id__c` (`User 01`, `User 02`, …), which was sequential and therefore guessable: anyone could
type `User 07` and check in as someone else.

`findAttendee` resolves **either** form in one query, so the 30 originally printed badges still
scan while everything issued since carries a token:

```apex
WHERE Event_Registry__c = :id AND ( Badge_Token__c = :code OR Badge_Id__c IN :variants )
```

`scripts/apex/backfillTokens.apex` minted tokens for the 30 loaded rows.

## 9. Permission set, scripts, tests

**`Event_Check_In_User`** — Apex class access to `BadgeScanService`, object permissions on the three
custom objects, 34 field permissions, tab and app visibility. Formula, master-detail and
required-lookup fields are **excluded** from `fieldPermissions`; Salesforce rejects FLS on them.
The file is generated from local field metadata rather than hand-written, for exactly that reason.

*Why a permission set and not a profile edit:* permission sets are additive and assignable to many
users without changing anyone's baseline. Modern Salesforce practice is to keep profiles minimal.

**`scripts/apex/seedDemo.apex`** — forces every registry to `Active`, ensures an `Attended` member
status exists, seeds one Contact matching a guest so the "reuses the existing person" path can be
shown, prints the badge codes. Idempotent.

**`scripts/apex/resetDemo.apex`** — deletes scans, enquiries (Tasks go with the Lead), members and
walk-ups; clears the guest-list flags; deletes Contacts the scans created; reopens the event.

> **A real bug was found and fixed here.** The first version collected attendee emails *after*
> deleting walk-up rows, so the walk-up's Contact survived with counters pointing at deleted
> records. Emails are now gathered before any delete. Order of operations in cleanup code matters.

**Tests** — `BadgeScanServiceTest` (10) and `ContactEmailDuplicationTest` (9): 20 total, 100%
passing, `BadgeScanService` at 91%, org-wide 91%. Note that `CampaignMemberStatus` for `Attended`
must be inserted in `@TestSetup`, because a Campaign created inside a test only receives the default
statuses.

Salesforce requires **75% coverage to deploy to production**. A Developer Edition org does not
enforce it, but the bar is met anyway.

---

## 10. The `ContactTrigger` fix (commit `c776490`)

Pre-existing code, unrelated to events, that blocked this app completely.

```apex
// before: queried EVERY Contact with an email, compared, addError
List<Contact> existing = [SELECT Id, Email FROM Contact WHERE Email != null];
```

On `before update` the record's own email was already in the database, so **every Contact matched
itself**, and any update with a non-blank email failed. Since check-in must update Contact counters,
nothing could work until this was fixed. Three defects in one method:

1. No `Trigger.oldMap` comparison → the self-match
2. Unbounded query → governor failure at scale
3. Database-only comparison → duplicates inside a single bulk save slipped through

All three fixed, with a test asserting exactly **one** SOQL query for a 200-record insert.

---

## 11. Likely questions

**"Why custom objects instead of just Campaign and Campaign Member?"**
The spec distinguishes who we *expected* from who *showed up*. Collapsing them loses that and loses
the scan audit log. A Campaign-only model cannot answer "how many registered badges never turned
up?" or "how many scans failed?"

**"Why LWC and not Flow?"**
Camera scanning is exposed only through `lightning/mobileCapabilities`, which is LWC-only. Flow also
could not express the savepoint/audit behaviour.

**"Why Apex and not Flow for the logic?"**
Savepoint rollback, writing an audit row that survives that rollback, and the duplicate-rule
override are all Apex-only capabilities.

**"What stops a double check-in?"**
Three layers: the `Checked_In__c` guard returns early; `Enquiry_Key__c` is a unique index so a
second Lead cannot be created even under a race; CampaignMember has its own unique constraint.

**"Is it bulk-safe?"**
No, deliberately — one scan per call, because a scanner submits one badge at a time. Measured at
10 SOQL / 8 DML per check-in, roughly 10 per transaction. A bulk path would hoist the queries out of
the per-record methods.

**"What happens if something fails halfway?"**
Savepoint rollback, then the `Error` audit row written separately so it survives, and a result
returned rather than an exception. Nothing is left half-created.

**"Why bypass the duplicate rule?"**
The duplicate is intentional in this model — the Lead *is* the enquiry for a known Contact.
`Enquiry_Key__c` enforces deduplication more strictly than the fuzzy standard rule.

**"What is not built?"**
Badge printing, public self-registration, digital badges via a Salesforce Site, email delivery,
AAMVA licence parsing, platform events for multi-desk refresh, offline queueing. Deliberate MVP
scope cuts, not oversights.

**"Why does the public form create so little?"**
Because a Site guest user does not get Apex's usual system-mode CRUD bypass — see §12.4. Every
object it touches must be granted on the guest profile, and guests can never hold Edit. Keeping
registration to a single insert keeps that grant list to two objects.

**"What would you fix first?"**
Rate limiting on the public form. It is open to the internet with no captcha, which is fine for a
short-lived demo org and not for production.
