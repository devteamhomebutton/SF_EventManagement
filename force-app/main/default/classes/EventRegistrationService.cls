/**
 * Public self-registration for an event, and delivery of the QR badge.
 *
 * WHY `without sharing`: this is the gateway a Salesforce Site guest user calls.
 * Running in system context means the guest needs no object or record
 * permissions at all - only access to the page and to this class - so it can do
 * exactly what the methods below allow and nothing else. Every method therefore
 * validates its own inputs and scopes every query to a single record.
 *
 * The QR image itself is produced in the browser and posted back, so there is
 * no QR encoder in Apex and no call to an external service. That image is an
 * email convenience only and is never trusted: the authoritative badge is
 * Badge_Token__c.
 */
public without sharing class EventRegistrationService
{
    private static final String REGISTRY_ACTIVE  = 'Active';
    private static final String STATUS_REGISTERED = 'Registered';
    private static final String REG_PREFIX       = 'REG-';
    private static final Integer ATTENDEE_KEY_MAX = 120;
    private static final Integer MAX_IMAGE_BYTES  = 500000;
    private static final String PNG_MAGIC         = '89504e47';

    // ------------------------------------------------------------- register

    public static RegistrationResult register ( Id eventRegistryId, BadgeScanService.WalkUpRequest details )
    {
        if ( details == null || String.isBlank(details.lastName) )
        {
            return failure('Please give us a last name.');
        }

        if ( String.isBlank(details.email) )
        {
            return failure('Please give us an email address so we can send your badge.');
        }

        Event_Registry__c registry = resolveRegistry(eventRegistryId);

        if ( registry == null )
        {
            return failure('That event could not be found.');
        }

        if ( registry.Status__c != REGISTRY_ACTIVE )
        {
            return failure(registry.Name + ' is not open for registration.');
        }

        String email = details.email.trim().toLowerCase();
        String key   = ( String.valueOf(registry.Id).left(18) + '|' + email ).left(ATTENDEE_KEY_MAX);

        // Registering twice re-sends the badge rather than adding a second row;
        // Attendee_Key__c is unique and would reject the insert anyway.
        List <Event_Attendee__c> already =
            [ SELECT Id, Name, Badge_Id__c, Badge_Token__c, First_Name__c, Last_Name__c, Contact__c
              FROM Event_Attendee__c WHERE Attendee_Key__c = :key LIMIT 1 ];

        if ( !already.isEmpty() )
        {
            Event_Attendee__c existing = already[0];

            if ( String.isBlank(existing.Badge_Token__c) )
            {
                // Loaded guest-list rows predate tokens; mint one on first use.
                existing.Badge_Token__c = BadgeScanService.newBadgeToken();
                update existing;
            }

            RegistrationResult repeat = success(existing, registry);
            repeat.alreadyRegistered = true;
            repeat.message = 'You are already registered. Here is your badge again.';

            return repeat;
        }

        Savepoint sp = Database.setSavepoint();

        try
        {
            Event_Attendee__c attendee = new Event_Attendee__c (
                Event_Registry__c = registry.Id,
                Badge_Id__c       = newBadgeId(),
                Badge_Token__c    = BadgeScanService.newBadgeToken(),
                Attendee_Key__c   = key,
                First_Name__c     = details.firstName,
                Last_Name__c      = details.lastName,
                Email__c          = email,
                Phone__c          = details.phone,
                Company__c        = details.company,
                Title__c          = details.title,
                Checked_In__c     = false
            );

            insert attendee;

            // Resolve the person now, with the same matcher the scanner uses, so
            // check-in later lands on this very Contact instead of a second copy.
            Contact person = BadgeScanService.resolveContact(attendee);

            registerAsMember(registry.Campaign__c, person.Id);

            update new Event_Attendee__c ( Id = attendee.Id, Contact__c = person.Id );

            Event_Attendee__c saved =
                [ SELECT Id, Name, Badge_Id__c, Badge_Token__c, First_Name__c, Last_Name__c, Contact__c
                  FROM Event_Attendee__c WHERE Id = :attendee.Id LIMIT 1 ];

            return success(saved, registry);
        }
        catch ( Exception e )
        {
            Database.rollback(sp);

            return failure('Registration failed: ' + e.getMessage());
        }
    }

    /**
     * Stores the browser-rendered QR and emails it. Separate from register() so
     * a registration is never lost waiting on an image or an email.
     */
    public static String attachBadgeAndEmail ( Id attendeeId, String base64Png, String badgeUrl )
    {
        if ( attendeeId == null )
        {
            return 'No attendee supplied.';
        }

        List <Event_Attendee__c> rows =
            [ SELECT Id, Name, Badge_Id__c, Badge_Token__c, First_Name__c, Last_Name__c, Email__c,
                     Contact__c, Event_Name__c
              FROM Event_Attendee__c WHERE Id = :attendeeId LIMIT 1 ];

        if ( rows.isEmpty() )
        {
            return 'That registration could not be found.';
        }

        Event_Attendee__c attendee = rows[0];
        Blob png = decodePng(base64Png);

        if ( png != null )
        {
            insert new ContentVersion (
                Title                  = 'Badge ' + attendee.Badge_Id__c,
                PathOnClient           = attendee.Badge_Id__c + '.png',
                VersionData            = png,
                FirstPublishLocationId = attendee.Id
            );
        }

        return sendBadgeEmail(attendee, png, badgeUrl);
    }

    /** Everything the public badge page may display, found by token only. */
    public static BadgeView findByToken ( String token )
    {
        if ( String.isBlank(token) )
        {
            return null;
        }

        String clean = token.trim();

        List <Event_Attendee__c> rows =
            [ SELECT Id, Name, Badge_Id__c, Badge_Token__c, First_Name__c, Last_Name__c,
                     Company__c, Title__c, Checked_In__c, Event_Name__c
              FROM Event_Attendee__c WHERE Badge_Token__c = :clean LIMIT 1 ];

        if ( rows.isEmpty() )
        {
            return null;
        }

        Event_Attendee__c attendee = rows[0];

        BadgeView view   = new BadgeView();
        view.attendeeId  = attendee.Id;
        view.badgeToken  = attendee.Badge_Token__c;
        view.badgeId     = attendee.Badge_Id__c;
        view.personName  = fullName(attendee);
        view.company     = attendee.Company__c;
        view.title       = attendee.Title__c;
        view.eventName   = attendee.Event_Name__c;
        view.checkedIn   = attendee.Checked_In__c;

        return view;
    }

    // -------------------------------------------------------------- helpers

    /** With no event supplied, fall back to the one that is open. */
    private static Event_Registry__c resolveRegistry ( Id eventRegistryId )
    {
        List <Event_Registry__c> found;

        if ( eventRegistryId == null )
        {
            found = [ SELECT Id, Name, Status__c, Campaign__c FROM Event_Registry__c
                      WHERE Status__c = :REGISTRY_ACTIVE ORDER BY Start_Date__c LIMIT 1 ];
        }
        else
        {
            found = [ SELECT Id, Name, Status__c, Campaign__c FROM Event_Registry__c
                      WHERE Id = :eventRegistryId LIMIT 1 ];
        }

        return found.isEmpty() ? null : found[0];
    }

    /**
     * Registered, not Attended - the campaign already carries both, so the
     * funnel reads Invited -> Registered -> Attended without any new fields.
     */
    private static void registerAsMember ( Id campaignId, Id contactId )
    {
        if ( campaignId == null )
        {
            return;
        }

        List <CampaignMember> existing =
            [ SELECT Id FROM CampaignMember
              WHERE CampaignId = :campaignId AND ContactId = :contactId LIMIT 1 ];

        if ( !existing.isEmpty() )
        {
            return;
        }

        CampaignMember member = new CampaignMember ( CampaignId = campaignId, ContactId = contactId );

        if ( hasStatus(campaignId, STATUS_REGISTERED) )
        {
            member.Status = STATUS_REGISTERED;
        }

        insert member;
    }

    private static Boolean hasStatus ( Id campaignId, String label )
    {
        return 0 < [ SELECT COUNT() FROM CampaignMemberStatus
                     WHERE CampaignId = :campaignId AND Label = :label ];
    }

    /** Rejects anything that is not a plausibly sized PNG. */
    private static Blob decodePng ( String base64Png )
    {
        if ( String.isBlank(base64Png) )
        {
            return null;
        }

        String payload = base64Png.contains(',') ? base64Png.substringAfter(',') : base64Png;

        try
        {
            Blob decoded = EncodingUtil.base64Decode(payload);

            if ( decoded == null || decoded.size() == 0 || decoded.size() > MAX_IMAGE_BYTES )
            {
                return null;
            }

            if ( !EncodingUtil.convertToHex(decoded).startsWith(PNG_MAGIC) )
            {
                return null;
            }

            return decoded;
        }
        catch ( Exception e )
        {
            return null;
        }
    }

    /**
     * Sent via setTargetObjectId rather than setToAddresses: Developer Edition
     * caps single emails to external addresses at 15 a day, and targeting a
     * record does not count against that cap. A few rehearsals would otherwise
     * exhaust the quota before the demo.
     */
    private static String sendBadgeEmail ( Event_Attendee__c attendee, Blob png, String badgeUrl )
    {
        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();

        if ( attendee.Contact__c != null )
        {
            mail.setTargetObjectId(attendee.Contact__c);
            mail.setTreatTargetObjectAsRecipient(true);
        }
        else if ( String.isNotBlank(attendee.Email__c) )
        {
            mail.setToAddresses(new List<String> { attendee.Email__c });
        }
        else
        {
            return 'Registered, but there was no address to send the badge to.';
        }

        mail.setSaveAsActivity(false);
        mail.setSubject('Your badge for ' + attendee.Event_Name__c);
        mail.setHtmlBody(badgeBody(attendee, badgeUrl));

        if ( png != null )
        {
            Messaging.EmailFileAttachment file = new Messaging.EmailFileAttachment();
            file.setFileName(attendee.Badge_Id__c + '.png');
            file.setContentType('image/png');
            file.setBody(png);
            mail.setFileAttachments(new List<Messaging.EmailFileAttachment> { file });
        }

        try
        {
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage> { mail });

            return 'Badge sent.';
        }
        catch ( Exception e )
        {
            // Registration already succeeded; a failed email must not undo it.
            return 'Registered, but the badge email could not be sent: ' + e.getMessage();
        }
    }

    private static String badgeBody ( Event_Attendee__c attendee, String badgeUrl )
    {
        String link = String.isBlank(badgeUrl) ? '' :
            '<p><a href="' + badgeUrl + '" style="background:#0176d3;color:#fff;padding:12px 20px;'
            + 'border-radius:4px;text-decoration:none;display:inline-block">Open my badge</a></p>'
            + '<p style="color:#747474;font-size:12px">Or paste this into a browser:<br/>' + badgeUrl + '</p>';

        return '<p>Hello ' + fullName(attendee) + ',</p>'
             + '<p>You are registered for <strong>' + attendee.Event_Name__c + '</strong>.</p>'
             + '<p>Show the QR code at the door to check in. It is attached to this email, and you '
             + 'can also open it on your phone with the button below.</p>'
             + link
             + '<p style="color:#747474;font-size:12px">Badge reference ' + attendee.Badge_Id__c + '</p>';
    }

    private static String newBadgeId ()
    {
        return REG_PREFIX + String.valueOf(Datetime.now().getTime())
             + '-' + String.valueOf(Math.abs(Crypto.getRandomInteger())).right(4);
    }

    private static String fullName ( Event_Attendee__c attendee )
    {
        String first = attendee.First_Name__c == null ? '' : attendee.First_Name__c;
        String last  = attendee.Last_Name__c  == null ? '' : attendee.Last_Name__c;

        return ( first + ' ' + last ).trim();
    }

    private static RegistrationResult failure ( String message )
    {
        RegistrationResult result = new RegistrationResult();
        result.success = false;
        result.message = message;

        return result;
    }

    private static RegistrationResult success ( Event_Attendee__c attendee, Event_Registry__c registry )
    {
        RegistrationResult result = new RegistrationResult();
        result.success    = true;
        result.attendeeId = attendee.Id;
        result.badgeToken = attendee.Badge_Token__c;
        result.badgeId    = attendee.Badge_Id__c;
        result.personName = fullName(attendee);
        result.eventName  = registry.Name;
        result.alreadyRegistered = false;
        result.message    = 'You are registered. Here is your badge.';

        return result;
    }

    // -------------------------------------------------------------- results

    public class RegistrationResult
    {
        public Boolean success           { get; set; }
        public String  message           { get; set; }
        public Id      attendeeId        { get; set; }
        public String  badgeToken        { get; set; }
        public String  badgeId           { get; set; }
        public String  personName        { get; set; }
        public String  eventName         { get; set; }
        public Boolean alreadyRegistered { get; set; }
    }

    public class BadgeView
    {
        public Id      attendeeId { get; set; }
        public String  badgeToken { get; set; }
        public String  badgeId    { get; set; }
        public String  personName { get; set; }
        public String  company    { get; set; }
        public String  title      { get; set; }
        public String  eventName  { get; set; }
        public Boolean checkedIn  { get; set; }
    }
}
