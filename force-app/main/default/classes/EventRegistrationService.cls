/**
 * Public self-registration for an event, and delivery of the QR badge.
 *
 * WHY `without sharing`: this is the gateway a Salesforce Site guest user calls.
 * It removes record-level sharing as a concern, but be clear that it does NOT
 * remove object-level permissions: unlike ordinary Apex, a Site guest user gets
 * no system-mode CRUD bypass, so every object touched here must be granted on
 * the guest profile, and a guest can never be granted Edit or Delete.
 *
 * Registration is therefore deliberately a single insert. The guest needs Read
 * on Event_Registry__c and Read + Create on Event_Attendee__c, and nothing
 * else. Every method validates its own inputs and scopes each query to one
 * record.
 *
 * The QR image itself is produced in the browser and posted back, so there is
 * no QR encoder in Apex and no call to an external service. That image is an
 * email convenience only and is never trusted: the authoritative badge is
 * Badge_Token__c.
 */
public without sharing class EventRegistrationService
{
    private static final String REGISTRY_ACTIVE  = 'Active';
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
            [ SELECT Id, Name, Badge_Id__c, Badge_Token__c, First_Name__c, Last_Name__c
              FROM Event_Attendee__c WHERE Attendee_Key__c = :key LIMIT 1 ];

        if ( !already.isEmpty() )
        {
            Event_Attendee__c existing = already[0];

            if ( String.isBlank(existing.Badge_Token__c) )
            {
                // Loaded guest-list rows predate tokens. Minting one is an Edit,
                // which a guest user can never be granted, so this only succeeds
                // for internal callers. backfillTokens.apex covers the rest.
                try
                {
                    existing.Badge_Token__c = BadgeScanService.newBadgeToken();
                    update existing;
                }
                catch ( Exception e )
                {
                    return failure('Your badge could not be reissued. Please ask at the desk.');
                }
            }

            RegistrationResult repeat = success(existing, registry);
            repeat.alreadyRegistered = true;
            repeat.message = 'You are already registered. Here is your badge again.';

            return repeat;
        }

        // A mistyped email looks like a different person, so fall back to the
        // same last name plus the same mobile number at the same event. This is
        // what catches someone registering twice as gmail.com and gamil.com.
        Event_Attendee__c samePerson = findBySurnameAndPhone(registry.Id, details.lastName, details.phone);

        if ( samePerson != null )
        {
            RegistrationResult repeat = success(samePerson, registry);
            repeat.alreadyRegistered = true;
            repeat.message = 'You are already registered under ' + samePerson.Email__c
                           + '. Here is that badge again.';

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
                Registered_At__c  = System.now(),
                Checked_In__c     = false
            );

            // Nothing but the guest-list row is created here. A Site guest user
            // is NOT given the usual system-mode CRUD bypass, so every object it
            // touches must be granted on the guest profile - and guest users can
            // never be granted Edit, which rules out a follow-up update. Keeping
            // registration to a single insert means the guest needs Read on the
            // registry and Read+Create on the attendee, and nothing else.
            //
            // The Contact and the Campaign Member are resolved at check-in
            // instead, which also matches the spec: a Campaign Member records
            // who actually showed up, not who said they would.
            insert attendee;

            // Deliberately no re-query. Everything the result needs is already
            // on the in-memory record, and a guest user cannot necessarily read
            // back a row it has just created.
            return success(attendee, registry);
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
                     Event_Name__c
              FROM Event_Attendee__c WHERE Id = :attendeeId LIMIT 1 ];

        if ( rows.isEmpty() )
        {
            return 'That registration could not be found.';
        }

        Event_Attendee__c attendee = rows[0];
        Blob png = decodePng(base64Png);

        if ( png != null )
        {
            // Best effort only. The email attachment does not depend on this,
            // and a Site guest user has no rights over Files.
            try
            {
                insert new ContentVersion (
                    Title                  = 'Badge ' + attendee.Badge_Id__c,
                    PathOnClient           = attendee.Badge_Id__c + '.png',
                    VersionData            = png,
                    FirstPublishLocationId = attendee.Id
                );
            }
            catch ( Exception e )
            {
                // Carry on and still send the badge.
            }
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

    /**
     * Second line of defence against the same person registering twice. Matches
     * on surname plus the trailing digits of the mobile, so a different country
     * code or formatting still counts as the same number. Surname is required
     * too, because a shared switchboard number would otherwise merge colleagues.
     */
    private static Event_Attendee__c findBySurnameAndPhone ( Id eventRegistryId, String lastName, String phone )
    {
        String digits = String.isBlank(phone) ? null : phone.replaceAll('[^0-9]', '');

        if ( String.isBlank(lastName) || digits == null || digits.length() < 7 )
        {
            return null;
        }

        String tail    = '%' + digits.right(9);
        String surname = lastName.trim();

        List <Event_Attendee__c> found =
            [ SELECT Id, Name, Badge_Id__c, Badge_Token__c, First_Name__c, Last_Name__c, Email__c
              FROM Event_Attendee__c
              WHERE Event_Registry__c = :eventRegistryId
                AND Last_Name__c = :surname
                AND Phone__c LIKE :tail
              LIMIT 1 ];

        return found.isEmpty() ? null : found[0];
    }


    /**
     * With no event supplied, fall back to the one that is open.
     *
     * Campaign__c is deliberately NOT selected. It is a required lookup, which
     * means it cannot be given field-level security, so a Site guest user can
     * never read it - selecting it makes the whole query fail for guests.
     * Registration does not need it, because the Campaign Member is created at
     * check-in rather than here.
     */
    private static Event_Registry__c resolveRegistry ( Id eventRegistryId )
    {
        List <Event_Registry__c> found;

        if ( eventRegistryId == null )
        {
            found = [ SELECT Id, Name, Status__c FROM Event_Registry__c
                      WHERE Status__c = :REGISTRY_ACTIVE ORDER BY Start_Date__c LIMIT 1 ];
        }
        else
        {
            found = [ SELECT Id, Name, Status__c FROM Event_Registry__c
                      WHERE Id = :eventRegistryId LIMIT 1 ];
        }

        return found.isEmpty() ? null : found[0];
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

        // Contact__c is a lookup to Contact, and a Site guest user has no access
        // to Contact, which makes the whole field unreadable for them. It is not
        // selected at all, so the badge always goes to the address given on the
        // form. That does count against Developer Edition's cap of 15 external
        // emails a day, which is worth remembering during rehearsals.
        if ( String.isBlank(attendee.Email__c) )
        {
            return 'Registered, but there was no address to send the badge to.';
        }

        mail.setToAddresses(new List<String> { attendee.Email__c });

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
