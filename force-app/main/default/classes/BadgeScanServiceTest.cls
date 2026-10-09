@IsTest
private class BadgeScanServiceTest
{
    private static final String EVENT_NAME = 'Trade Show Test';
    private static final String BADGE_ONE  = 'User 01';
    private static final String BADGE_TWO  = 'User 02';
    private static final String EMAIL_ONE  = 'scan.one@eventmgmt.test';
    private static final String EMAIL_TWO  = 'scan.two@eventmgmt.test';

    @TestSetup
    static void makeData()
    {
        Campaign show = new Campaign ( Name = EVENT_NAME, IsActive = true );
        insert show;

        // A new Campaign only gets the default statuses, so the one the service
        // looks for has to be added explicitly.
        insert new CampaignMemberStatus (
            CampaignId = show.Id, Label = 'Attended', SortOrder = 12, HasResponded = true
        );

        Event_Registry__c registry = new Event_Registry__c (
            Name           = EVENT_NAME,
            Campaign__c    = show.Id,
            Campaign_Key__c = show.Id,
            Status__c      = 'Active',
            Start_Date__c  = Date.today()
        );
        insert registry;

        insert new List<Event_Attendee__c>
        {
            newAttendee(registry.Id, BADGE_ONE, 'Kavya', 'Kumar',  EMAIL_ONE, '9448968265', 'Circuitry Labs'),
            newAttendee(registry.Id, BADGE_TWO, 'Diya',  'Sharma', EMAIL_TWO, '9456173735', 'Ohm Dynamics')
        };
    }

    private static Event_Attendee__c newAttendee ( Id registryId, String badge, String first,
                                                   String last, String email, String phone, String company )
    {
        return new Event_Attendee__c (
            Event_Registry__c = registryId,
            Badge_Id__c       = badge,
            Attendee_Key__c   = registryId + '|' + email,
            First_Name__c     = first,
            Last_Name__c      = last,
            Email__c          = email,
            Phone__c          = phone,
            Company__c        = company,
            Checked_In__c     = false
        );
    }

    private static Event_Registry__c registry()
    {
        return [ SELECT Id, Name, Status__c, Campaign__c FROM Event_Registry__c LIMIT 1 ];
    }

    private static Event_Attendee__c attendee ( String badge )
    {
        return [ SELECT Id, Badge_Id__c, Checked_In__c, Checked_In_At__c, Contact__c, Lead__c
                 FROM Event_Attendee__c WHERE Badge_Id__c = :badge LIMIT 1 ];
    }

    @IsTest
    static void scanChecksTheAttendeeIn()
    {
        Event_Registry__c show = registry();

        Test.startTest();
        BadgeScanService.ScanResult outcome =
            BadgeScanService.processScan(show.Id, BADGE_ONE, BadgeScanService.METHOD_CAMERA);
        Test.stopTest();

        Assert.isTrue(outcome.success, 'A first scan of a loaded badge should check the person in');
        Assert.areEqual('Checked In', outcome.result, 'Result should be Checked In');
        Assert.areEqual('Kavya Kumar', outcome.personName, 'The person name should come back for the UI');
        Assert.isNotNull(outcome.contactId, 'A Contact should have been resolved');
        Assert.isNotNull(outcome.leadId, 'An enquiry should have been raised');

        Assert.isTrue(attendee(BADGE_ONE).Checked_In__c, 'The attendee row should be flagged checked in');

        List <Lead> enquiries = [ SELECT Id, LeadSource, Company, Campaign__c, Contact__c,
                                         Event_Registry__c, Enquiry_Key__c
                                  FROM Lead WHERE Id = :outcome.leadId ];
        Assert.areEqual(1, enquiries.size(), 'Exactly one enquiry should exist');
        Assert.areEqual('Events', enquiries[0].LeadSource, 'Lead Source should be Events');
        Assert.areEqual('Circuitry Labs', enquiries[0].Company, 'Company should carry across from the badge');
        Assert.areEqual(show.Id, enquiries[0].Event_Registry__c, 'The enquiry should point back at the event');

        Assert.areEqual(1, [ SELECT COUNT() FROM Task WHERE WhoId = :outcome.leadId ],
            'One follow-up Task should be raised with the enquiry');

        List <CampaignMember> members = [ SELECT Id, Status FROM CampaignMember
                                          WHERE CampaignId = :show.Campaign__c ];
        Assert.areEqual(1, members.size(), 'The person should be recorded as a Campaign Member');
        Assert.areEqual('Attended', members[0].Status, 'Member status should be Attended');

        List <Badge_Scan__c> audit = [ SELECT Id, Result__c, Scan_Method__c, Badge_Id__c FROM Badge_Scan__c ];
        Assert.areEqual(1, audit.size(), 'The scan should leave exactly one audit row');
        Assert.areEqual('Checked In', audit[0].Result__c, 'The audit row should record the outcome');
        Assert.areEqual('Camera Scan', audit[0].Scan_Method__c, 'The audit row should record the method');
    }

    @IsTest
    static void repeatScanIsAuditedButChangesNothing()
    {
        Event_Registry__c show = registry();

        Test.startTest();
        BadgeScanService.processScan(show.Id, BADGE_ONE, BadgeScanService.METHOD_CAMERA);
        BadgeScanService.ScanResult second =
            BadgeScanService.processScan(show.Id, BADGE_ONE, BadgeScanService.METHOD_CAMERA);
        Test.stopTest();

        Assert.isFalse(second.success, 'A repeat scan is not a fresh check-in');
        Assert.areEqual('Already Checked In', second.result, 'The repeat should be reported as such');

        Assert.areEqual(2, [ SELECT COUNT() FROM Badge_Scan__c ],
            'Both attempts should be audited, including the repeat');
        Assert.areEqual(1, [ SELECT COUNT() FROM Lead WHERE Event_Registry__c = :show.Id ],
            'A repeat scan must not raise a second enquiry');
        Assert.areEqual(1, [ SELECT COUNT() FROM CampaignMember WHERE CampaignId = :show.Campaign__c ],
            'A repeat scan must not add a second Campaign Member');
    }

    @IsTest
    static void unknownBadgeIsRecordedAsNotFound()
    {
        Event_Registry__c show = registry();

        Test.startTest();
        BadgeScanService.ScanResult outcome =
            BadgeScanService.processScan(show.Id, 'Nobody 99', BadgeScanService.METHOD_CAMERA);
        Test.stopTest();

        Assert.isFalse(outcome.success, 'A badge that is not on the guest list cannot check in');
        Assert.areEqual('Not Found', outcome.result, 'Result should be Not Found');

        List <Badge_Scan__c> audit = [ SELECT Id, Result__c, Badge_Id__c, Attendee__c FROM Badge_Scan__c ];
        Assert.areEqual(1, audit.size(), 'A failed scan still gets an audit row');
        Assert.areEqual('Not Found', audit[0].Result__c, 'The audit row should record Not Found');
        Assert.isNull(audit[0].Attendee__c, 'There is no attendee to relate the row to');
        Assert.areEqual(0, [ SELECT COUNT() FROM Lead WHERE Event_Registry__c = :show.Id ],
            'An unknown badge must not raise an enquiry');
    }

    // The QR images are named with hyphens while the badge codes are stored with
    // spaces, so a reader may hand back either form.
    @IsTest
    static void hyphenatedBadgeResolvesToTheSameAttendee()
    {
        Event_Registry__c show = registry();

        Test.startTest();
        BadgeScanService.ScanResult outcome =
            BadgeScanService.processScan(show.Id, 'User-01', BadgeScanService.METHOD_CAMERA);
        Test.stopTest();

        Assert.isTrue(outcome.success, 'The hyphenated form of the badge should resolve');
        Assert.areEqual(BADGE_ONE, outcome.badgeId, 'It should match the stored badge code');
    }

    @IsTest
    static void existingContactIsReusedNotDuplicated()
    {
        insert new Contact ( LastName = 'Kumar', FirstName = 'Kavya', Email = EMAIL_ONE );

        Event_Registry__c show = registry();

        Test.startTest();
        BadgeScanService.ScanResult outcome =
            BadgeScanService.processScan(show.Id, BADGE_ONE, BadgeScanService.METHOD_CAMERA);
        Test.stopTest();

        Assert.isTrue(outcome.success, 'Matching an existing Contact should still check the person in');
        Assert.areEqual(1, [ SELECT COUNT() FROM Contact WHERE Email = :EMAIL_ONE ],
            'The scan should reuse the existing Contact rather than create a second');
    }

    @IsTest
    static void walkUpIsRegisteredThenCheckedIn()
    {
        Event_Registry__c show = registry();

        BadgeScanService.WalkUpRequest details = new BadgeScanService.WalkUpRequest();
        details.firstName = 'Zephr';
        details.lastName  = 'Zebra';
        details.email     = 'zephr.zebra@eventmgmt.test';
        details.company   = 'Zoo Company';

        Test.startTest();
        BadgeScanService.ScanResult outcome = BadgeScanService.registerWalkUp(show.Id, details);
        Test.stopTest();

        Assert.isTrue(outcome.success, 'A walk-up should be registered and checked in');
        Assert.areEqual('Checked In', outcome.result, 'Result should be Checked In');
        Assert.isTrue(outcome.badgeId.startsWith('WALK-'), 'A walk-up badge code should be generated');

        Assert.areEqual(3, [ SELECT COUNT() FROM Event_Attendee__c WHERE Event_Registry__c = :show.Id ],
            'The walk-up should be added to the guest list alongside the two loaded rows');
        Assert.areEqual(1, [ SELECT COUNT() FROM Lead WHERE Event_Registry__c = :show.Id ],
            'The walk-up should raise an enquiry like any other check-in');

        List <Badge_Scan__c> audit = [ SELECT Id, Result__c, Scan_Method__c FROM Badge_Scan__c ];
        Assert.areEqual(1, audit.size(), 'The walk-up check-in should be audited');
        Assert.areEqual('Manual Check-in', audit[0].Scan_Method__c, 'A walk-up is a manual check-in');
    }

    @IsTest
    static void walkUpMatchingALoadedAttendeeChecksThatPersonIn()
    {
        Event_Registry__c show = registry();

        BadgeScanService.WalkUpRequest details = new BadgeScanService.WalkUpRequest();
        details.firstName = 'Kavya';
        details.lastName  = 'Kumar';
        details.email     = EMAIL_ONE;

        Test.startTest();
        BadgeScanService.ScanResult outcome = BadgeScanService.registerWalkUp(show.Id, details);
        Test.stopTest();

        Assert.isTrue(outcome.success, 'The person on the guest list should be checked in');
        Assert.areEqual(BADGE_ONE, outcome.badgeId, 'Their loaded badge should be used, not a new one');
        Assert.areEqual(2, [ SELECT COUNT() FROM Event_Attendee__c WHERE Event_Registry__c = :show.Id ],
            'No duplicate guest-list row should be created');
    }

    // Use case 10: the person should land on a real Account, not float as a
    // private Contact with no company behind them.
    @IsTest
    static void checkingInGivesThePersonAnAccount()
    {
        Event_Registry__c show = registry();

        Test.startTest();
        BadgeScanService.ScanResult outcome =
            BadgeScanService.processScan(show.Id, BADGE_ONE, BadgeScanService.METHOD_CAMERA);
        Test.stopTest();

        Contact person = [ SELECT Id, AccountId, Account.Name FROM Contact WHERE Id = :outcome.contactId ];
        Assert.isNotNull(person.AccountId, 'The Contact should be attached to an Account');
        Assert.areEqual('Circuitry Labs', person.Account.Name, 'Named from the badge company');
        Assert.areEqual(1, [ SELECT COUNT() FROM Account WHERE Name = 'Circuitry Labs' ],
            'The Account should be created once, not per scan');
    }

    @IsTest
    static void anExistingAccountIsReusedNotDuplicated()
    {
        insert new Account ( Name = 'Circuitry Labs' );

        Event_Registry__c show = registry();

        Test.startTest();
        BadgeScanService.ScanResult outcome =
            BadgeScanService.processScan(show.Id, BADGE_ONE, BadgeScanService.METHOD_CAMERA);
        Test.stopTest();

        Assert.areEqual(1, [ SELECT COUNT() FROM Account WHERE Name = 'Circuitry Labs' ],
            'The existing company should be matched, not duplicated');
        Assert.isNotNull([ SELECT AccountId FROM Contact WHERE Id = :outcome.contactId ].AccountId,
            'And the person attached to it');
    }

    // Use case 9: two Contacts share the badge's phone number, so the match is
    // ambiguous. The door still moves, but the scan is flagged.
    @IsTest
    static void anAmbiguousContactMatchIsFlaggedForReview()
    {
        insert new List<Contact>
        {
            new Contact ( LastName = 'Kumar',  MobilePhone = '9448968265' ),
            new Contact ( LastName = 'Kumaar', MobilePhone = '9448968265' )
        };

        // Blank the email so matching has to fall through to the phone.
        Event_Attendee__c attendee = attendee(BADGE_ONE);
        update new Event_Attendee__c ( Id = attendee.Id, Email__c = null );

        Event_Registry__c show = registry();

        Test.startTest();
        BadgeScanService.ScanResult outcome =
            BadgeScanService.processScan(show.Id, BADGE_ONE, BadgeScanService.METHOD_CAMERA);
        Test.stopTest();

        Assert.isTrue(outcome.success, 'An ambiguous match must not block the queue');
        Assert.isTrue(outcome.needsReview, 'But it should be reported as needing review');
        Assert.isTrue(outcome.message.contains('review'), 'And say so on screen');

        List <Badge_Scan__c> audit = [ SELECT Needs_Review__c FROM Badge_Scan__c ];
        Assert.areEqual(1, audit.size(), 'One audit row as always');
        Assert.isTrue(audit[0].Needs_Review__c, 'Flagged on the audit row so it can be found later');
    }

    @IsTest
    static void aSingleCleanMatchIsNotFlagged()
    {
        Event_Registry__c show = registry();

        Test.startTest();
        BadgeScanService.ScanResult outcome =
            BadgeScanService.processScan(show.Id, BADGE_ONE, BadgeScanService.METHOD_CAMERA);
        Test.stopTest();

        Assert.isFalse(outcome.needsReview, 'An unambiguous scan should not be flagged');
        Assert.isFalse([ SELECT Needs_Review__c FROM Badge_Scan__c LIMIT 1 ].Needs_Review__c,
            'Nor its audit row');
    }

    @IsTest
    static void inactiveEventRefusesCheckIn()
    {
        Event_Registry__c show = registry();
        show.Status__c = 'Completed';
        update show;

        Test.startTest();
        BadgeScanService.ScanResult outcome =
            BadgeScanService.processScan(show.Id, BADGE_ONE, BadgeScanService.METHOD_CAMERA);
        Test.stopTest();

        Assert.isFalse(outcome.success, 'A closed event should not accept check-ins');
        Assert.areEqual('Error', outcome.result, 'The refusal should be reported as an error');
        Assert.isFalse(attendee(BADGE_ONE).Checked_In__c, 'Nobody should be checked in');
        Assert.areEqual(1, [ SELECT COUNT() FROM Badge_Scan__c ],
            'The refused attempt should still be audited');
    }

    // The App Builder renders the component with no record behind it.
    @IsTest
    static void summaryWithoutARecordReturnsZeros()
    {
        Test.startTest();
        BadgeScanService.EventSummary summary = BadgeScanService.getEventSummary(null);
        Test.stopTest();

        Assert.areEqual(0, summary.totalAttendees, 'An unknown event should report no attendees');
        Assert.areEqual(0, summary.checkedIn, 'An unknown event should report nobody checked in');
        Assert.isNull(summary.eventName, 'There is no event name to report');
    }

    @IsTest
    static void summaryAndSearchFeedTheScanner()
    {
        Event_Registry__c show = registry();

        Test.startTest();
        BadgeScanService.processScan(show.Id, BADGE_ONE, BadgeScanService.METHOD_CAMERA);
        BadgeScanService.EventSummary summary = BadgeScanService.getEventSummary(show.Id);
        List <BadgeScanService.AttendeeRow> all     = BadgeScanService.searchAttendees(show.Id, '', false);
        List <BadgeScanService.AttendeeRow> kavya   = BadgeScanService.searchAttendees(show.Id, 'Kav', false);
        List <BadgeScanService.AttendeeRow> arrived = BadgeScanService.searchAttendees(show.Id, '', true);
        Test.stopTest();

        Assert.areEqual(2, summary.totalAttendees, 'Both loaded attendees should be counted');
        Assert.areEqual(1, summary.checkedIn, 'One of them has arrived');
        Assert.areEqual(1, summary.notCheckedIn, 'The other has not');

        Assert.areEqual(2, all.size(), 'An empty search term should list the whole guest list');
        Assert.areEqual(1, kavya.size(), 'Searching should match on first name');
        Assert.areEqual('Kavya Kumar', kavya[0].personName, 'The row should carry a display name');
        Assert.areEqual(1, arrived.size(), 'The checked-in filter should narrow the list');
    }
}
