@IsTest
private class ContactEmailDuplicationTest
{
    private static final String TAKEN_EMAIL = 'batman@justiceleague.test';

    @TestSetup
    static void makeData()
    {
        insert new Contact ( LastName = 'Wayne', Email = TAKEN_EMAIL );
    }

    private static Contact existingContact()
    {
        return [ SELECT Id, LastName, Email, Description FROM Contact WHERE Email = :TAKEN_EMAIL LIMIT 1 ];
    }

    private static Boolean isDuplicateError ( Database.SaveResult result )
    {
        for ( Database.Error err : result.getErrors() )
        {
            if ( err.getMessage().contains(ContactEmailDuplication.DUPLICATE_MESSAGE) )
            {
                return true;
            }
        }

        return false;
    }

    // The regression: editing a Contact without touching its email used to fail,
    // because the record matched its own email already in the database.

    @IsTest
    static void allowsUpdateWhenEmailUnchanged()
    {
        Contact con = existingContact();
        con.Description = 'edited';

        Test.startTest();
        Database.SaveResult result = Database.update(con, false);
        Test.stopTest();

        Assert.isTrue(result.isSuccess(), 'Updating a Contact without changing its email should succeed');
        Assert.areEqual('edited', existingContact().Description, 'The edit should have been saved');
    }

    @IsTest
    static void allowsUpdateToAFreeEmail()
    {
        Contact con = existingContact();
        con.Email = 'robin@justiceleague.test';

        Test.startTest();
        Database.SaveResult result = Database.update(con, false);
        Test.stopTest();

        Assert.isTrue(result.isSuccess(), 'Moving a Contact to an unused email should succeed');
    }

    @IsTest
    static void blocksUpdateOntoAnotherContactsEmail()
    {
        insert new Contact ( LastName = 'Kent', Email = 'superman@justiceleague.test' );

        Contact con = [ SELECT Id, Email FROM Contact WHERE Email = 'superman@justiceleague.test' LIMIT 1 ];
        con.Email = TAKEN_EMAIL;

        Test.startTest();
        Database.SaveResult result = Database.update(con, false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'Taking another Contact\'s email should be blocked');
        Assert.isTrue(isDuplicateError(result), 'The duplicate-email message should be returned');
    }

    @IsTest
    static void blocksInsertOfAnExistingEmail()
    {
        Contact con = new Contact ( LastName = 'Impostor', Email = TAKEN_EMAIL );

        Test.startTest();
        Database.SaveResult result = Database.insert(con, false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'Inserting an email already in use should be blocked');
        Assert.isTrue(isDuplicateError(result), 'The duplicate-email message should be returned');
    }

    @IsTest
    static void blocksInsertIsCaseInsensitive()
    {
        Contact con = new Contact ( LastName = 'Impostor', Email = TAKEN_EMAIL.toUpperCase() );

        Test.startTest();
        Database.SaveResult result = Database.insert(con, false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'Email matching should ignore case');
    }

    // Two records carrying the same new email inside one save: the old version
    // only compared against the database, so both slipped through.

    @IsTest
    static void blocksDuplicatesWithinTheSameInsert()
    {
        List <Contact> batch = new List<Contact>
        {
            new Contact ( LastName = 'Twin A', Email = 'twins@justiceleague.test' ),
            new Contact ( LastName = 'Twin B', Email = 'twins@justiceleague.test' )
        };

        Test.startTest();
        List <Database.SaveResult> results = Database.insert(batch, false);
        Test.stopTest();

        Assert.isFalse(results[0].isSuccess(), 'First of the in-batch duplicates should be blocked');
        Assert.isFalse(results[1].isSuccess(), 'Second of the in-batch duplicates should be blocked');
    }

    @IsTest
    static void allowsContactsWithoutAnEmail()
    {
        List <Contact> batch = new List<Contact>
        {
            new Contact ( LastName = 'No Email One' ),
            new Contact ( LastName = 'No Email Two' )
        };

        Test.startTest();
        List <Database.SaveResult> results = Database.insert(batch, false);
        Test.stopTest();

        Assert.isTrue(results[0].isSuccess(), 'A blank email should not be treated as a duplicate');
        Assert.isTrue(results[1].isSuccess(), 'Two blank emails should not collide with each other');
    }

    // 200 distinct emails in one save must stay inside one SOQL query.

    @IsTest
    static void handlesABulkInsertWithinGovernorLimits()
    {
        List <Contact> batch = new List<Contact> ();

        for ( Integer i = 0; i < 200; i++ )
        {
            batch.add(new Contact ( LastName = 'Bulk ' + i, Email = 'bulk' + i + '@justiceleague.test' ));
        }

        Test.startTest();
        insert batch;
        Integer queriesUsed = Limits.getQueries();
        Test.stopTest();

        Assert.areEqual(1, queriesUsed, 'The duplicate check should cost exactly one SOQL query per save');
        Assert.areEqual(201, [ SELECT COUNT() FROM Contact ], 'All 200 Contacts plus the setup record should exist');
    }
}
