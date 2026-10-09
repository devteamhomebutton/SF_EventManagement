@IsTest
private class EventRegistrationServiceTest
{
    private static final String EVENT_NAME = 'Registration Test Event';
    private static final String NEW_EMAIL  = 'zephr.zebra@eventmgmt.test';

    // A real 1x1 PNG, so the magic-byte check passes.
    private static final String TINY_PNG =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

    @TestSetup
    static void makeData()
    {
        Campaign show = new Campaign ( Name = EVENT_NAME, IsActive = true );
        insert show;

        insert new List<CampaignMemberStatus>
        {
            new CampaignMemberStatus ( CampaignId = show.Id, Label = 'Registered', SortOrder = 11 ),
            new CampaignMemberStatus ( CampaignId = show.Id, Label = 'Attended',   SortOrder = 12, HasResponded = true )
        };

        insert new Event_Registry__c (
            Name = EVENT_NAME, Campaign__c = show.Id, Campaign_Key__c = show.Id,
            Status__c = 'Active', Start_Date__c = Date.today()
        );
    }

    private static Event_Registry__c registry()
    {
        return [ SELECT Id, Name, Status__c, Campaign__c FROM Event_Registry__c LIMIT 1 ];
    }

    private static BadgeScanService.WalkUpRequest details ( String email )
    {
        BadgeScanService.WalkUpRequest request = new BadgeScanService.WalkUpRequest();
        request.firstName = 'Zephr';
        request.lastName  = 'Zebra';
        request.email     = email;
        request.phone     = '9900112233';
        request.company   = 'Zoo Company';
        request.title     = 'Keeper';

        return request;
    }

    @IsTest
    static void registeringCreatesAttendeeContactAndMember()
    {
        Event_Registry__c show = registry();

        Test.startTest();
        EventRegistrationService.RegistrationResult result =
            EventRegistrationService.register(show.Id, details(NEW_EMAIL));
        Test.stopTest();

        Assert.isTrue(result.success, 'A new registration should succeed');
        Assert.isFalse(result.alreadyRegistered, 'This is a first registration');
        Assert.areEqual('Zephr Zebra', result.personName, 'The name comes back for the badge');
        Assert.areEqual(32, result.badgeToken.length(), 'The token should be 128 bits as 32 hex chars');
        Assert.isTrue(result.badgeId.startsWith('REG-'), 'A registration badge code should be generated');

        Event_Attendee__c attendee = [
            SELECT Id, Email__c, Company__c, Checked_In__c, Contact__c, Badge_Token__c, Attendee_Key__c
            FROM Event_Attendee__c WHERE Id = :result.attendeeId
        ];
        Assert.areEqual(NEW_EMAIL, attendee.Email__c, 'Email should be stored lower-cased');
        Assert.isFalse(attendee.Checked_In__c, 'Registering is not arriving');
        Assert.isNotNull(attendee.Contact__c, 'The person should be resolved at registration');
        Assert.areEqual(show.Id + '|' + NEW_EMAIL, attendee.Attendee_Key__c, 'Key follows the loaded convention');

        List <CampaignMember> members = [ SELECT Status FROM CampaignMember WHERE CampaignId = :show.Campaign__c ];
        Assert.areEqual(1, members.size(), 'Registering should add a Campaign Member');
        Assert.areEqual('Registered', members[0].Status, 'They have registered, not yet attended');

        Assert.areEqual(0, [ SELECT COUNT() FROM Lead WHERE Event_Registry__c = :show.Id ],
            'No enquiry should be raised until they actually turn up');
    }

    @IsTest
    static void registeringTwiceResendsRatherThanDuplicating()
    {
        Event_Registry__c show = registry();

        Test.startTest();
        EventRegistrationService.RegistrationResult first =
            EventRegistrationService.register(show.Id, details(NEW_EMAIL));
        EventRegistrationService.RegistrationResult second =
            EventRegistrationService.register(show.Id, details(NEW_EMAIL.toUpperCase()));
        Test.stopTest();

        Assert.isTrue(second.success, 'A repeat registration is not an error');
        Assert.isTrue(second.alreadyRegistered, 'It should be reported as already registered');
        Assert.areEqual(first.badgeToken, second.badgeToken, 'The same badge should come back');
        Assert.areEqual(1, [ SELECT COUNT() FROM Event_Attendee__c WHERE Event_Registry__c = :show.Id ],
            'Registering twice must not create a second guest-list row');
    }

    @IsTest
    static void registrationIsRejectedWithoutNameOrEmail()
    {
        Event_Registry__c show = registry();

        BadgeScanService.WalkUpRequest noName = details(NEW_EMAIL);
        noName.lastName = null;

        BadgeScanService.WalkUpRequest noEmail = details(null);

        Test.startTest();
        EventRegistrationService.RegistrationResult a = EventRegistrationService.register(show.Id, noName);
        EventRegistrationService.RegistrationResult b = EventRegistrationService.register(show.Id, noEmail);
        Test.stopTest();

        Assert.isFalse(a.success, 'A last name is required');
        Assert.isFalse(b.success, 'An email is required, since that is where the badge goes');
        Assert.areEqual(0, [ SELECT COUNT() FROM Event_Attendee__c ], 'Nothing should have been created');
    }

    @IsTest
    static void registrationIsRefusedWhenTheEventIsClosed()
    {
        Event_Registry__c show = registry();
        show.Status__c = 'Completed';
        update show;

        Test.startTest();
        EventRegistrationService.RegistrationResult result =
            EventRegistrationService.register(show.Id, details(NEW_EMAIL));
        Test.stopTest();

        Assert.isFalse(result.success, 'A closed event should not accept registrations');
        Assert.areEqual(0, [ SELECT COUNT() FROM Event_Attendee__c ], 'Nothing should have been created');
    }

    @IsTest
    static void badgeIsFoundByTokenAndOnlyByToken()
    {
        Event_Registry__c show = registry();
        EventRegistrationService.RegistrationResult result =
            EventRegistrationService.register(show.Id, details(NEW_EMAIL));

        Test.startTest();
        EventRegistrationService.BadgeView found   = EventRegistrationService.findByToken(result.badgeToken);
        EventRegistrationService.BadgeView guessed = EventRegistrationService.findByToken('not-a-real-token');
        EventRegistrationService.BadgeView blank   = EventRegistrationService.findByToken('');
        Test.stopTest();

        Assert.isNotNull(found, 'A valid token should resolve to a badge');
        Assert.areEqual('Zephr Zebra', found.personName, 'The badge carries the display name');
        Assert.isFalse(found.checkedIn, 'They have not arrived yet');
        Assert.isNull(guessed, 'A wrong token must reveal nothing');
        Assert.isNull(blank, 'A blank token must reveal nothing');
    }

    @IsTest
    static void onlyRealPngsAreStored()
    {
        Event_Registry__c show = registry();
        EventRegistrationService.RegistrationResult result =
            EventRegistrationService.register(show.Id, details(NEW_EMAIL));

        Test.startTest();
        EventRegistrationService.attachBadgeAndEmail(result.attendeeId, 'bm90LWEtcG5n', 'https://example.test/b');
        Integer afterJunk = [ SELECT COUNT() FROM ContentVersion ];

        EventRegistrationService.attachBadgeAndEmail(result.attendeeId,
            'data:image/png;base64,' + TINY_PNG, 'https://example.test/b');
        Integer afterReal = [ SELECT COUNT() FROM ContentVersion ];
        Test.stopTest();

        Assert.areEqual(0, afterJunk, 'Anything that is not a PNG must be rejected');
        Assert.areEqual(1, afterReal, 'A real PNG should be stored against the registration');
    }

    // The point of the whole feature: register, then walk in and scan the token.
    @IsTest
    static void aRegisteredTokenChecksInAtTheDoor()
    {
        Event_Registry__c show = registry();
        EventRegistrationService.RegistrationResult registered =
            EventRegistrationService.register(show.Id, details(NEW_EMAIL));

        Test.startTest();
        BadgeScanService.ScanResult scan =
            BadgeScanService.processScan(show.Id, registered.badgeToken, BadgeScanService.METHOD_CAMERA);
        Test.stopTest();

        Assert.isTrue(scan.success, 'Scanning a registered badge token should check the person in');
        Assert.areEqual('Checked In', scan.result, 'Result should be Checked In');
        Assert.areEqual(registered.attendeeId, scan.attendeeId, 'It should be the same guest-list row');

        List <CampaignMember> members = [ SELECT Status FROM CampaignMember WHERE CampaignId = :show.Campaign__c ];
        Assert.areEqual(1, members.size(), 'Still one member, not a second');
        Assert.areEqual('Attended', members[0].Status, 'Registered should become Attended on arrival');

        Assert.areEqual(1, [ SELECT COUNT() FROM Lead WHERE Event_Registry__c = :show.Id ],
            'Arriving raises the enquiry that registering did not');
        Assert.areEqual(1, [ SELECT COUNT() FROM Contact WHERE Email = :NEW_EMAIL ],
            'Registration and check-in must land on one Contact, not two');
    }
}
