/**
 * Controller for the public digital badge page.
 *
 * Returns display fields for exactly one attendee, found by an unguessable
 * 128-bit token and nothing else. `without sharing` so the guest user needs no
 * record access of its own.
 */
public without sharing class EventBadgeController
{
    public EventRegistrationService.BadgeView badge { get; private set; }
    public Boolean found { get; private set; }

    public EventBadgeController ()
    {
        String token = ApexPages.currentPage().getParameters().get('t');

        this.badge = EventRegistrationService.findByToken(token);
        this.found = ( this.badge != null );
    }
}
