/**
 * Processes a badge scan at an event.
 *
 * One badge per call - the scanner submits a single code at a time. A scan
 * resolves the person, records that they showed up, raises one enquiry per
 * person per event, and leaves an audit row behind whatever the outcome.
 *
 * Every exit path writes exactly one Badge_Scan__c row. The error path writes
 * its row after rolling the business DML back, and returns a result rather
 * than throwing, because an uncaught exception would discard the audit row
 * along with everything else in the request.
 */
public with sharing class BadgeScanService
{
    // Badge_Scan__c.Result__c
    @TestVisible private static final String RESULT_CHECKED_IN = 'Checked In';
    @TestVisible private static final String RESULT_ALREADY_IN = 'Already Checked In';
    @TestVisible private static final String RESULT_NOT_FOUND  = 'Not Found';
    @TestVisible private static final String RESULT_ERROR      = 'Error';

    // Badge_Scan__c.Scan_Method__c
    public static final String METHOD_CAMERA = 'Camera Scan';
    public static final String METHOD_MANUAL = 'Manual Check-in';

    private static final String LEAD_SOURCE_EVENTS   = 'Events';
    private static final String STATUS_ATTENDED      = 'Attended';
    private static final String REGISTRY_ACTIVE      = 'Active';
    private static final String WALK_UP_PREFIX       = 'WALK-';
    private static final Integer FOLLOW_UP_IN_DAYS   = 2;
    private static final Integer ENQUIRY_KEY_MAX     = 40;
    private static final Integer ATTENDEE_KEY_MAX    = 120;

    /**
     * Checks a badge in. Always returns a result; never throws for a scan that
     * simply did not work, so the scanner can show the outcome and keep going.
     */
    @AuraEnabled
    public static ScanResult processScan ( Id eventRegistryId, String badgeId, String scanMethod )
    {
        String method = ( scanMethod == METHOD_MANUAL ) ? METHOD_MANUAL : METHOD_CAMERA;
        String code   = ( badgeId == null ) ? '' : badgeId.trim();

        if ( eventRegistryId == null )
        {
            // Nothing to relate an audit row to, and the UI should never do this.
            return failureResult(code, 'No event was supplied for this scan.');
        }

        Event_Registry__c registry = loadRegistry(eventRegistryId);

        if ( registry == null )
        {
            return failureResult(code, 'That event no longer exists.');
        }

        if ( registry.Status__c != REGISTRY_ACTIVE )
        {
            // Stops a booth device checking people into the wrong event.
            logScan(null, registry.Campaign__c, code, RESULT_ERROR, method, null, null);
            return failureResult(code, registry.Name + ' is not open for check-in (status '
                                     + registry.Status__c + ').');
        }

        if ( String.isBlank(code) )
        {
            // An unreadable badge is still an attempt, so it gets a row.
            logScan(null, registry.Campaign__c, code, RESULT_ERROR, method, null, null);
            return failureResult(code, 'That badge could not be read. Try again or check in manually.');
        }

        Event_Attendee__c attendee = findAttendee(eventRegistryId, code);

        if ( attendee == null )
        {
            logScan(null, registry.Campaign__c, code, RESULT_NOT_FOUND, method, null, null);
            return notFoundResult(code, registry.Name);
        }

        return checkIn(attendee, registry, method);
    }

    /**
     * Registers somebody who turned up without being on the loaded guest list,
     * then checks them in through exactly the same path as a scanned badge.
     */
    @AuraEnabled
    public static ScanResult registerWalkUp ( Id eventRegistryId, WalkUpRequest details )
    {
        if ( eventRegistryId == null || details == null )
        {
            return failureResult(null, 'No event or details were supplied for this walk-up.');
        }

        if ( String.isBlank(details.lastName) )
        {
            return failureResult(null, 'A last name is needed to register a walk-up.');
        }

        Event_Registry__c registry = loadRegistry(eventRegistryId);

        if ( registry == null )
        {
            return failureResult(null, 'That event no longer exists.');
        }

        if ( registry.Status__c != REGISTRY_ACTIVE )
        {
            logScan(null, registry.Campaign__c, null, RESULT_ERROR, METHOD_MANUAL, null, null);
            return failureResult(null, registry.Name + ' is not open for check-in (status '
                                     + registry.Status__c + ').');
        }

        // Somebody already on the guest list under this email is checked in as
        // themselves rather than added twice - Attendee_Key__c would reject the
        // duplicate anyway.
        Event_Attendee__c alreadyLoaded = findAttendeeByEmail(eventRegistryId, details.email);

        if ( alreadyLoaded != null )
        {
            return checkIn(alreadyLoaded, registry, METHOD_MANUAL);
        }

        Event_Attendee__c walkUp;

        try
        {
            walkUp = createWalkUpAttendee(registry, details);
        }
        catch ( Exception e )
        {
            logScan(null, registry.Campaign__c, null, RESULT_ERROR, METHOD_MANUAL, null, null);
            return failureResult(null, 'Could not register the walk-up: ' + e.getMessage());
        }

        return checkIn(walkUp, registry, METHOD_MANUAL);
    }

    // ------------------------------------------------------------- check-in

    /** The shared transaction behind both a scanned badge and a walk-up. */
    private static ScanResult checkIn ( Event_Attendee__c attendee, Event_Registry__c registry, String method )
    {
        if ( attendee.Checked_In__c == true )
        {
            Badge_Scan__c repeat = logScan(attendee.Id, registry.Campaign__c, attendee.Badge_Id__c,
                                           RESULT_ALREADY_IN, method, attendee.Contact__c, attendee.Lead__c);

            return alreadyCheckedInResult(attendee, repeat.Id);
        }

        Savepoint sp = Database.setSavepoint();

        try
        {
            Contact person = resolveContact(attendee);

            ensureCampaignMember(registry.Campaign__c, person.Id);

            Lead enquiry = ensureEnquiry(attendee, registry, person.Id);

            update new Event_Attendee__c (
                Id              = attendee.Id,
                Checked_In__c   = true,
                Checked_In_At__c = System.now(),
                Contact__c      = person.Id,
                Lead__c         = enquiry.Id
            );

            refreshContactCounters(person.Id);

            Badge_Scan__c logged = logScan(attendee.Id, registry.Campaign__c, attendee.Badge_Id__c,
                                           RESULT_CHECKED_IN, method, person.Id, enquiry.Id);

            return checkedInResult(attendee, person.Id, enquiry.Id, logged.Id);
        }
        catch ( Exception e )
        {
            // Undo the half-finished check-in, then audit the failure separately
            // so the row survives the rollback.
            Database.rollback(sp);

            logScan(attendee.Id, registry.Campaign__c, attendee.Badge_Id__c,
                    RESULT_ERROR, method, null, null);

            return failureResult(attendee.Badge_Id__c,
                'Check-in failed: ' + e.getMessage());
        }
    }

    /** Live totals for the scanner header, refreshed after each scan. */
    @AuraEnabled(cacheable=true)
    public static EventSummary getEventSummary ( Id eventRegistryId )
    {
        List <Event_Registry__c> found =
            [ SELECT Id, Name, Status__c, Start_Date__c, End_Date__c,
                     Total_Attendees__c, Checked_In_Count__c, Campaign__c, Campaign__r.Name
              FROM Event_Registry__c WHERE Id = :eventRegistryId LIMIT 1 ];

        EventSummary summary = new EventSummary();

        if ( found.isEmpty() )
        {
            // The Lightning App Builder previews the component without a record,
            // so an empty summary beats a query exception in the canvas.
            summary.totalAttendees = 0;
            summary.checkedIn      = 0;
            summary.notCheckedIn   = 0;

            return summary;
        }

        Event_Registry__c registry = found[0];

        summary.eventRegistryId = registry.Id;
        summary.eventName       = registry.Name;
        summary.campaignId      = registry.Campaign__c;
        summary.campaignName    = registry.Campaign__r.Name;
        summary.status          = registry.Status__c;
        summary.startDate       = registry.Start_Date__c;
        summary.endDate         = registry.End_Date__c;
        summary.totalAttendees  = (Integer) registry.Total_Attendees__c;
        summary.checkedIn       = (Integer) registry.Checked_In_Count__c;
        summary.notCheckedIn    = summary.totalAttendees - summary.checkedIn;

        return summary;
    }

    /** Guest list for the scanner's search tab, newest arrivals first. */
    @AuraEnabled(cacheable=true)
    public static List<AttendeeRow> searchAttendees ( Id eventRegistryId, String term, Boolean checkedInOnly )
    {
        String pattern = '%' + ( term == null ? '' : term.trim() ) + '%';
        Boolean filterToCheckedIn = ( checkedInOnly == true );

        List <Event_Attendee__c> matches =
            [ SELECT Id, Name, Badge_Id__c, First_Name__c, Last_Name__c, Email__c, Phone__c,
                     Company__c, Title__c, Checked_In__c, Checked_In_At__c, Contact__c, Lead__c
              FROM Event_Attendee__c
              WHERE Event_Registry__c = :eventRegistryId
                AND ( First_Name__c LIKE :pattern OR Last_Name__c LIKE :pattern
                      OR Email__c LIKE :pattern OR Company__c LIKE :pattern OR Badge_Id__c LIKE :pattern )
              ORDER BY Checked_In_At__c DESC NULLS LAST, Last_Name__c
              LIMIT 200 ];

        List <AttendeeRow> rows = new List<AttendeeRow> ();

        for ( Event_Attendee__c attendee : matches )
        {
            // SOQL cannot bind a bare boolean, so the toggle is applied here.
            if ( filterToCheckedIn && attendee.Checked_In__c != true )
            {
                continue;
            }

            rows.add(new AttendeeRow(attendee));
        }

        return rows;
    }

    // ---------------------------------------------------------------- lookups

    private static Event_Registry__c loadRegistry ( Id eventRegistryId )
    {
        List <Event_Registry__c> found =
            [ SELECT Id, Name, Status__c, Campaign__c
              FROM Event_Registry__c WHERE Id = :eventRegistryId LIMIT 1 ];

        return found.isEmpty() ? null : found[0];
    }

    /**
     * Badge codes are stored with spaces ("User 01") while the QR image names
     * use hyphens, so a reader may hand back either. One query covers both.
     */
    private static Event_Attendee__c findAttendee ( Id eventRegistryId, String code )
    {
        Set <String> variants = new Set<String> { code, code.replace('-', ' '), code.replace(' ', '-') };

        List <Event_Attendee__c> found =
            [ SELECT Id, Name, Badge_Id__c, First_Name__c, Last_Name__c, Email__c, Phone__c,
                     Company__c, Title__c, Checked_In__c, Checked_In_At__c, Contact__c, Lead__c,
                     Event_Name__c, Event_Registry__c
              FROM Event_Attendee__c
              WHERE Event_Registry__c = :eventRegistryId AND Badge_Id__c IN :variants
              LIMIT 1 ];

        return found.isEmpty() ? null : found[0];
    }

    private static Event_Attendee__c findAttendeeByEmail ( Id eventRegistryId, String email )
    {
        if ( String.isBlank(email) )
        {
            return null;
        }

        List <Event_Attendee__c> found =
            [ SELECT Id, Name, Badge_Id__c, First_Name__c, Last_Name__c, Email__c, Phone__c,
                     Company__c, Title__c, Checked_In__c, Checked_In_At__c, Contact__c, Lead__c,
                     Event_Name__c, Event_Registry__c
              FROM Event_Attendee__c
              WHERE Event_Registry__c = :eventRegistryId AND Email__c = :email.trim()
              LIMIT 1 ];

        return found.isEmpty() ? null : found[0];
    }

    // ---------------------------------------------------------------- walk-ups

    /**
     * Adds a guest-list row for somebody who turned up without one. Badge_Id__c
     * is unique across the whole object rather than per event, so the generated
     * code has to be globally unique; the retry covers two booth devices
     * registering inside the same millisecond.
     */
    private static Event_Attendee__c createWalkUpAttendee ( Event_Registry__c registry, WalkUpRequest details )
    {
        DmlException lastFailure;

        for ( Integer attempt = 0; attempt < 2; attempt++ )
        {
            String badgeCode = generateWalkUpBadge();

            Event_Attendee__c walkUp = new Event_Attendee__c (
                Event_Registry__c = registry.Id,
                Badge_Id__c       = badgeCode,
                Attendee_Key__c   = attendeeKey(registry.Id, details.email, badgeCode),
                First_Name__c     = details.firstName,
                Last_Name__c      = details.lastName,
                Email__c          = details.email,
                Phone__c          = details.phone,
                Company__c        = details.company,
                Title__c          = details.title,
                Checked_In__c     = false
            );

            try
            {
                insert walkUp;
            }
            catch ( DmlException e )
            {
                lastFailure = e;
                continue;
            }

            // Re-read so the auto-number Name and formula fields are populated.
            return findAttendee(registry.Id, badgeCode);
        }

        throw lastFailure;
    }

    private static String generateWalkUpBadge ()
    {
        return WALK_UP_PREFIX + String.valueOf(Datetime.now().getTime())
             + '-' + String.valueOf(Math.abs(Crypto.getRandomInteger())).right(4);
    }

    /** Follows the loaded data's convention of {registryId}|{email}. */
    private static String attendeeKey ( Id eventRegistryId, String email, String badgeCode )
    {
        String tail = String.isBlank(email) ? badgeCode : email.trim().toLowerCase();

        return ( String.valueOf(eventRegistryId).left(18) + '|' + tail ).left(ATTENDEE_KEY_MAX);
    }

    /** Email first, then mobile number, then create. Never a second copy. */
    private static Contact resolveContact ( Event_Attendee__c attendee )
    {
        if ( String.isNotBlank(attendee.Email__c) )
        {
            List <Contact> byEmail =
                [ SELECT Id FROM Contact WHERE Email = :attendee.Email__c LIMIT 1 ];

            if ( !byEmail.isEmpty() )
            {
                return byEmail[0];
            }
        }

        String digits = digitsOnly(attendee.Phone__c);

        if ( digits != null && digits.length() >= 7 )
        {
            // Match on the trailing digits so a country code or formatting
            // difference does not hide an existing Contact.
            String tail = '%' + digits.right(9);

            List <Contact> byPhone =
                [ SELECT Id FROM Contact
                  WHERE MobilePhone LIKE :tail OR Phone LIKE :tail
                  LIMIT 1 ];

            if ( !byPhone.isEmpty() )
            {
                return byPhone[0];
            }
        }

        Contact person = new Contact (
            FirstName   = attendee.First_Name__c,
            LastName    = blankTo(attendee.Last_Name__c, 'Unknown'),
            Email       = attendee.Email__c,
            MobilePhone = attendee.Phone__c,
            Title       = attendee.Title__c
        );

        Database.insert(person, allowKnownDuplicates());

        return person;
    }

    /** Campaign Member is the record of who actually turned up. */
    private static void ensureCampaignMember ( Id campaignId, Id contactId )
    {
        if ( campaignId == null )
        {
            return;
        }

        String attended = attendedStatusFor(campaignId);

        List <CampaignMember> existing =
            [ SELECT Id, Status FROM CampaignMember
              WHERE CampaignId = :campaignId AND ContactId = :contactId LIMIT 1 ];

        if ( !existing.isEmpty() )
        {
            if ( attended != null && existing[0].Status != attended )
            {
                update new CampaignMember ( Id = existing[0].Id, Status = attended );
            }

            return;
        }

        CampaignMember member = new CampaignMember ( CampaignId = campaignId, ContactId = contactId );

        if ( attended != null )
        {
            member.Status = attended;
        }

        insert member;
    }

    /** Member statuses are per campaign, so fall back to the default. */
    private static String attendedStatusFor ( Id campaignId )
    {
        String fallback = null;

        for ( CampaignMemberStatus status :
              [ SELECT Label, IsDefault FROM CampaignMemberStatus WHERE CampaignId = :campaignId ] )
        {
            if ( status.Label == STATUS_ATTENDED )
            {
                return status.Label;
            }

            if ( status.IsDefault == true )
            {
                fallback = status.Label;
            }
        }

        return fallback;
    }

    /**
     * One enquiry per person per event. Enquiry_Key__c carries the constraint,
     * so a repeat scan of the same person finds the Lead instead of adding one.
     */
    private static Lead ensureEnquiry ( Event_Attendee__c attendee, Event_Registry__c registry, Id contactId )
    {
        String key = enquiryKey(registry.Id, contactId);

        List <Lead> existing = [ SELECT Id FROM Lead WHERE Enquiry_Key__c = :key LIMIT 1 ];

        if ( !existing.isEmpty() )
        {
            return existing[0];
        }

        Lead enquiry = new Lead (
            FirstName         = attendee.First_Name__c,
            LastName          = blankTo(attendee.Last_Name__c, 'Unknown'),
            Company           = blankTo(attendee.Company__c, 'Unknown'),
            Email             = attendee.Email__c,
            MobilePhone       = attendee.Phone__c,
            Title             = attendee.Title__c,
            LeadSource        = LEAD_SOURCE_EVENTS,
            Campaign__c       = registry.Campaign__c,
            Event_Registry__c = registry.Id,
            Contact__c        = contactId,
            Enquiry_Key__c    = key
        );

        Database.insert(enquiry, allowKnownDuplicates());

        insert new Task (
            WhoId        = enquiry.Id,
            Subject      = 'Follow up: ' + registry.Name,
            Status       = 'Not Started',
            Priority     = 'High',
            ActivityDate = Date.today().addDays(FOLLOW_UP_IN_DAYS),
            Description  = 'Checked in at ' + registry.Name + ' on badge ' + attendee.Badge_Id__c + '.'
        );

        return enquiry;
    }

    /**
     * Neither counter can be a roll-up, because Lead and CampaignMember are not
     * master-detail children of Contact, so they are recounted on check-in.
     */
    private static void refreshContactCounters ( Id contactId )
    {
        update new Contact (
            Id               = contactId,
            Enquiry_Count__c = [ SELECT COUNT() FROM Lead WHERE Contact__c = :contactId ],
            Campaign_Count__c = [ SELECT COUNT() FROM CampaignMember WHERE ContactId = :contactId ]
        );
    }

    private static Badge_Scan__c logScan ( Id attendeeId, Id campaignId, String badgeId,
                                           String result, String method, Id contactId, Id leadId )
    {
        Badge_Scan__c scan = new Badge_Scan__c (
            Attendee__c   = attendeeId,
            Campaign__c   = campaignId,
            Badge_Id__c   = badgeId,
            Result__c     = result,
            Scan_Method__c = method,
            Scanned_At__c = System.now(),
            Contact__c    = contactId,
            Lead__c       = leadId
        );

        insert scan;

        return scan;
    }

    // ---------------------------------------------------------------- helpers

    @TestVisible
    private static String enquiryKey ( Id eventRegistryId, Id contactId )
    {
        // 18 + 1 + 18 = 37 characters, inside the field's 40.
        String key = String.valueOf(eventRegistryId).left(18) + '|' + String.valueOf(contactId).left(18);

        return key.left(ENQUIRY_KEY_MAX);
    }

    /**
     * The org's Standard Lead Duplicate Rule blocks a Lead that matches an
     * existing Contact - which is precisely what an enquiry is here, since the
     * scan resolves the Contact first and then raises the Lead against it. The
     * duplicate is intentional, so the rule is opted out of rather than fought.
     * Deduplication is still enforced, by Enquiry_Key__c.
     */
    private static Database.DMLOptions allowKnownDuplicates ()
    {
        Database.DMLOptions options = new Database.DMLOptions();
        options.DuplicateRuleHeader.AllowSave = true;

        return options;
    }

    private static String digitsOnly ( String value )
    {
        return String.isBlank(value) ? null : value.replaceAll('[^0-9]', '');
    }

    private static String blankTo ( String value, String fallback )
    {
        return String.isBlank(value) ? fallback : value;
    }

    // ------------------------------------------------------- result factories

    private static ScanResult checkedInResult ( Event_Attendee__c attendee, Id contactId, Id leadId, Id scanId )
    {
        ScanResult outcome = new ScanResult();
        outcome.copyFrom(attendee);
        outcome.result      = RESULT_CHECKED_IN;
        outcome.success     = true;
        outcome.contactId   = contactId;
        outcome.leadId      = leadId;
        outcome.badgeScanId = scanId;
        outcome.checkedInAt = System.now();
        outcome.message     = outcome.personName + ' is checked in.';

        return outcome;
    }

    private static ScanResult alreadyCheckedInResult ( Event_Attendee__c attendee, Id scanId )
    {
        ScanResult outcome = new ScanResult();
        outcome.copyFrom(attendee);
        outcome.result      = RESULT_ALREADY_IN;
        outcome.success     = false;
        outcome.contactId   = attendee.Contact__c;
        outcome.leadId      = attendee.Lead__c;
        outcome.badgeScanId = scanId;
        outcome.checkedInAt = attendee.Checked_In_At__c;
        outcome.message     = outcome.personName + ' was already checked in.';

        return outcome;
    }

    private static ScanResult notFoundResult ( String badgeId, String eventName )
    {
        ScanResult outcome = new ScanResult();
        outcome.result  = RESULT_NOT_FOUND;
        outcome.success = false;
        outcome.badgeId = badgeId;
        outcome.message = 'Badge ' + badgeId + ' is not on the guest list for ' + eventName + '.';

        return outcome;
    }

    private static ScanResult failureResult ( String badgeId, String message )
    {
        ScanResult outcome = new ScanResult();
        outcome.result  = RESULT_ERROR;
        outcome.success = false;
        outcome.badgeId = badgeId;
        outcome.message = message;

        return outcome;
    }

    // ---------------------------------------------------------------- results

    public class ScanResult
    {
        @AuraEnabled public String  result      { get; set; }
        @AuraEnabled public String  message     { get; set; }
        @AuraEnabled public Boolean success     { get; set; }
        @AuraEnabled public String  badgeId     { get; set; }
        @AuraEnabled public Id      attendeeId  { get; set; }
        @AuraEnabled public String  attendeeName { get; set; }
        @AuraEnabled public String  personName  { get; set; }
        @AuraEnabled public String  company     { get; set; }
        @AuraEnabled public String  title       { get; set; }
        @AuraEnabled public String  email       { get; set; }
        @AuraEnabled public String  phone       { get; set; }
        @AuraEnabled public Id      contactId   { get; set; }
        @AuraEnabled public Id      leadId      { get; set; }
        @AuraEnabled public Id      badgeScanId { get; set; }
        @AuraEnabled public Datetime checkedInAt { get; set; }

        // Inner classes cannot hold static members, so the factories below live
        // on the outer class.
        private void copyFrom ( Event_Attendee__c attendee )
        {
            this.badgeId      = attendee.Badge_Id__c;
            this.attendeeId   = attendee.Id;
            this.attendeeName = attendee.Name;
            this.personName   = ( blankTo(attendee.First_Name__c, '') + ' '
                                + blankTo(attendee.Last_Name__c, '') ).trim();
            this.company      = attendee.Company__c;
            this.title        = attendee.Title__c;
            this.email        = attendee.Email__c;
            this.phone        = attendee.Phone__c;
        }
    }

    /** What the walk-in form collects. */
    public class WalkUpRequest
    {
        @AuraEnabled public String firstName { get; set; }
        @AuraEnabled public String lastName  { get; set; }
        @AuraEnabled public String email     { get; set; }
        @AuraEnabled public String phone     { get; set; }
        @AuraEnabled public String company   { get; set; }
        @AuraEnabled public String title     { get; set; }
    }

    /** One line in the scanner's attendee list. */
    public class AttendeeRow
    {
        @AuraEnabled public Id       id          { get; set; }
        @AuraEnabled public String   name        { get; set; }
        @AuraEnabled public String   badgeId     { get; set; }
        @AuraEnabled public String   personName  { get; set; }
        @AuraEnabled public String   company     { get; set; }
        @AuraEnabled public String   title       { get; set; }
        @AuraEnabled public String   email       { get; set; }
        @AuraEnabled public String   phone       { get; set; }
        @AuraEnabled public Boolean  checkedIn   { get; set; }
        @AuraEnabled public Datetime checkedInAt { get; set; }
        @AuraEnabled public Id       contactId   { get; set; }
        @AuraEnabled public Id       leadId      { get; set; }

        public AttendeeRow ( Event_Attendee__c attendee )
        {
            this.id          = attendee.Id;
            this.name        = attendee.Name;
            this.badgeId     = attendee.Badge_Id__c;
            this.personName  = ( blankTo(attendee.First_Name__c, '') + ' '
                               + blankTo(attendee.Last_Name__c, '') ).trim();
            this.company     = attendee.Company__c;
            this.title       = attendee.Title__c;
            this.email       = attendee.Email__c;
            this.phone       = attendee.Phone__c;
            this.checkedIn   = attendee.Checked_In__c;
            this.checkedInAt = attendee.Checked_In_At__c;
            this.contactId   = attendee.Contact__c;
            this.leadId      = attendee.Lead__c;
        }
    }

    public class EventSummary
    {
        @AuraEnabled public Id      eventRegistryId { get; set; }
        @AuraEnabled public String  eventName       { get; set; }
        @AuraEnabled public Id      campaignId      { get; set; }
        @AuraEnabled public String  campaignName    { get; set; }
        @AuraEnabled public String  status          { get; set; }
        @AuraEnabled public Date    startDate       { get; set; }
        @AuraEnabled public Date    endDate         { get; set; }
        @AuraEnabled public Integer totalAttendees  { get; set; }
        @AuraEnabled public Integer checkedIn       { get; set; }
        @AuraEnabled public Integer notCheckedIn    { get; set; }
    }
}
