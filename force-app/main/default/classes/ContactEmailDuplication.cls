public class ContactEmailDuplication
{
    @TestVisible
    private static final String DUPLICATE_MESSAGE =
        'This email is already taken by another Contact. Even the Justice League can\'t have two Batmans.';

    public static void preventDuplicateEmail (List<Contact> newContacts, Map<Id, Contact> oldContacts)
    {
        // Only the emails that actually need checking: every new Contact with an
        // email, plus existing ones whose email just changed. Skipping unchanged
        // emails is what stops an update from matching the record against itself.

        Map <String, List<Contact>> contactsByEmail = new Map <String, List<Contact>> ();

        for ( Contact con : newContacts )
        {
            if ( String.isBlank(con.Email) )
            {
                continue;
            }

            Contact oldContact = ( oldContacts == null ) ? null : oldContacts.get(con.Id);

            if ( oldContact != null && con.Email.equalsIgnoreCase(oldContact.Email) )
            {
                continue;
            }

            String emailKey = con.Email.toLowerCase();

            if ( !contactsByEmail.containsKey(emailKey) )
            {
                contactsByEmail.put(emailKey, new List<Contact> ());
            }

            contactsByEmail.get(emailKey).add(con);
        }

        if ( contactsByEmail.isEmpty() )
        {
            return;
        }

        // One targeted query for just those emails, excluding the records being
        // saved, instead of pulling every Contact in the org.

        Set <Id> idsBeingSaved = ( oldContacts == null ) ? new Set<Id> () : oldContacts.keySet();

        Set <String> takenEmails = new Set <String> ();

        for ( Contact existing : [ SELECT Id, Email FROM Contact
                                   WHERE Email IN :contactsByEmail.keySet()
                                   AND Id NOT IN :idsBeingSaved ] )
        {
            takenEmails.add(existing.Email.toLowerCase());
        }

        // Flag anything already in the database, and anything duplicated inside
        // this same save.

        for ( String emailKey : contactsByEmail.keySet() )
        {
            List <Contact> sharingThisEmail = contactsByEmail.get(emailKey);

            if ( takenEmails.contains(emailKey) || sharingThisEmail.size() > 1 )
            {
                for ( Contact con : sharingThisEmail )
                {
                    con.Email.addError(DUPLICATE_MESSAGE);
                }
            }
        }
    }
}
