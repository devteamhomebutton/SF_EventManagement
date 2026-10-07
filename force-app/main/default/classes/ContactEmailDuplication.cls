public class ContactEmailDuplication 
{
	public static void preventDuplicateEmail (List<Contact> newContacts)
    {
        //Get Existing Contacts
        
        List <Contact> existingContacts = [SELECT Id, Email FROM contact WHERE email != null];
        
        // Set the Emails from Existing Contacts
    	
        Set <String> existingEmails = new Set <String> ();
        
        for ( Contact c : existingContacts )
        {
            existingEmails.add(c.Email);
        }
        
        // Check for Duplicate Emails
        
        for ( Contact con : newContacts )
        {
            if ( existingEmails.contains(con.Email)  )
            {
                con.addError('This email is already taken by another Contact. Even the Justice League can\'t have two Batmans.');
            }
        }
    }
}