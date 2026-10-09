/**
 * Controller for the public registration page.
 *
 * `without sharing` on purpose - see EventRegistrationService for the reasoning.
 * The guest user needs access only to this class and the page, never to the
 * objects themselves.
 */
public without sharing class EventRegisterController
{
    public Id      eventRegistryId { get; private set; }
    public String  eventName       { get; private set; }
    public Boolean eventOpen       { get; private set; }

    public EventRegisterController ()
    {
        String requested = ApexPages.currentPage().getParameters().get('e');

        Event_Registry__c registry = lookupRegistry(requested);

        this.eventOpen       = ( registry != null && registry.Status__c == 'Active' );
        this.eventRegistryId = ( registry == null ) ? null : registry.Id;
        this.eventName       = ( registry == null ) ? 'this event' : registry.Name;
    }

    private static Event_Registry__c lookupRegistry ( String requested )
    {
        List <Event_Registry__c> found;

        if ( String.isNotBlank(requested) )
        {
            try
            {
                Id registryId = (Id) requested;
                found = [ SELECT Id, Name, Status__c FROM Event_Registry__c WHERE Id = :registryId LIMIT 1 ];
            }
            catch ( Exception e )
            {
                return null;   // a malformed id in the URL is simply "not found"
            }
        }
        else
        {
            found = [ SELECT Id, Name, Status__c FROM Event_Registry__c
                      WHERE Status__c = 'Active' ORDER BY Start_Date__c LIMIT 1 ];
        }

        return found.isEmpty() ? null : found[0];
    }

    @RemoteAction
    public static EventRegistrationService.RegistrationResult register (
        String registryId, String firstName, String lastName,
        String email, String phone, String company, String title )
    {
        BadgeScanService.WalkUpRequest details = new BadgeScanService.WalkUpRequest();
        details.firstName = firstName;
        details.lastName  = lastName;
        details.email     = email;
        details.phone     = phone;
        details.company   = company;
        details.title     = title;

        Id registry = String.isBlank(registryId) ? null : (Id) registryId;

        return EventRegistrationService.register(registry, details);
    }

    @RemoteAction
    public static String attachBadge ( String attendeeId, String base64Png, String badgeUrl )
    {
        return EventRegistrationService.attachBadgeAndEmail((Id) attendeeId, base64Png, badgeUrl);
    }
}
