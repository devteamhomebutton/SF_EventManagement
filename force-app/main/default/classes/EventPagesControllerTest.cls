@IsTest
private class EventPagesControllerTest
{
    private static final String EVENT_NAME = 'Pages Test Event';
    private static final String EMAIL      = 'pages.test@eventmgmt.test';

    private static final String TINY_PNG =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

    @TestSetup
    static void makeData()
    {
        Campaign show = new Campaign ( Name = EVENT_NAME, IsActive = true );
        insert show;

        insert new CampaignMemberStatus ( CampaignId = show.Id, Label = 'Registered', SortOrder = 11 );

        insert new Event_Registry__c (
            Name = EVENT_NAME, Campaign__c = show.Id, Campaign_Key__c = show.Id,
            Status__c = 'Active', Start_Date__c = Date.today()
        );
    }

    private static Event_Registry__c registry()
    {
        return [ SELECT Id, Name, Status__c FROM Event_Registry__c LIMIT 1 ];
    }

    @IsTest
    static void registerPageFindsTheEventFromTheUrl()
    {
        Event_Registry__c show = registry();

        Test.setCurrentPage(Page.EventRegister);
        ApexPages.currentPage().getParameters().put('e', show.Id);

        Test.startTest();
        EventRegisterController controller = new EventRegisterController();
        Test.stopTest();

        Assert.areEqual(show.Id, controller.eventRegistryId, 'The event should come from the URL');
        Assert.areEqual(EVENT_NAME, controller.eventName, 'The page should show the event name');
        Assert.isTrue(controller.eventOpen, 'An Active event is open for registration');
    }

    @IsTest
    static void registerPageFallsBackToTheOpenEventAndHandlesRubbish()
    {
        Test.setCurrentPage(Page.EventRegister);

        Test.startTest();
        EventRegisterController noParam = new EventRegisterController();

        ApexPages.currentPage().getParameters().put('e', 'not-an-id');
        EventRegisterController badParam = new EventRegisterController();
        Test.stopTest();

        Assert.isTrue(noParam.eventOpen, 'With no event in the URL it should fall back to the open one');
        Assert.areEqual(EVENT_NAME, noParam.eventName, 'And name it');

        Assert.isFalse(badParam.eventOpen, 'A malformed id in the URL is simply not found');
        Assert.isNull(badParam.eventRegistryId, 'And yields no event');
    }

    @IsTest
    static void registerPageIsClosedWhenTheEventIs()
    {
        Event_Registry__c show = registry();
        show.Status__c = 'Planned';
        update show;

        Test.setCurrentPage(Page.EventRegister);
        ApexPages.currentPage().getParameters().put('e', show.Id);

        Test.startTest();
        EventRegisterController controller = new EventRegisterController();
        Test.stopTest();

        Assert.isFalse(controller.eventOpen, 'A Planned event should not accept registrations');
    }

    @IsTest
    static void remoteActionsRegisterThenAttachTheBadge()
    {
        Event_Registry__c show = registry();

        Test.startTest();
        EventRegistrationService.RegistrationResult result = EventRegisterController.register(
            show.Id, 'Pages', 'Tester', EMAIL, '9900112233', 'Test Co', 'Tester'
        );

        String status = EventRegisterController.attachBadge(
            result.attendeeId, 'data:image/png;base64,' + TINY_PNG, 'https://example.test/badge'
        );
        Test.stopTest();

        Assert.isTrue(result.success, 'The remote action should register the person');
        Assert.areEqual(32, result.badgeToken.length(), 'A token should be minted');
        Assert.isNotNull(status, 'Attaching the badge should report back to the page');
        Assert.areEqual(1, [ SELECT COUNT() FROM ContentVersion ], 'The badge PNG should be stored');
    }

    @IsTest
    static void badgePageShowsOneAttendeeForAValidToken()
    {
        Event_Registry__c show = registry();
        EventRegistrationService.RegistrationResult registered = EventRegisterController.register(
            show.Id, 'Pages', 'Tester', EMAIL, null, 'Test Co', 'Tester'
        );

        Test.setCurrentPage(Page.EventBadge);
        ApexPages.currentPage().getParameters().put('t', registered.badgeToken);

        Test.startTest();
        EventBadgeController controller = new EventBadgeController();
        Test.stopTest();

        Assert.isTrue(controller.found, 'A valid token should resolve');
        Assert.areEqual('Pages Tester', controller.badge.personName, 'The badge names the person');
        Assert.areEqual(EVENT_NAME, controller.badge.eventName, 'And the event');
        Assert.isFalse(controller.badge.checkedIn, 'They have not arrived yet');
    }

    @IsTest
    static void badgePageRevealsNothingWithoutAValidToken()
    {
        Test.setCurrentPage(Page.EventBadge);

        Test.startTest();
        EventBadgeController missing = new EventBadgeController();

        ApexPages.currentPage().getParameters().put('t', 'deadbeefdeadbeefdeadbeefdeadbeef');
        EventBadgeController guessed = new EventBadgeController();
        Test.stopTest();

        Assert.isFalse(missing.found, 'No token means no badge');
        Assert.isNull(missing.badge, 'And nothing to display');
        Assert.isFalse(guessed.found, 'A guessed token must reveal nothing');
    }
}
