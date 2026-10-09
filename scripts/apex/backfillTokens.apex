/**
 * Gives every guest-list row an unguessable badge token.
 *
 *   sf apex run --file scripts/apex/backfillTokens.apex
 *
 * The originally loaded attendees predate Badge_Token__c and their QR codes
 * encode the sequential Badge Id instead, which is guessable. Scanning still
 * resolves either form, so this can be run at any time; it only affects rows
 * that have no token yet. Run it once after deploying the field.
 */
List<Event_Attendee__c> needTokens = [
    SELECT Id, Badge_Id__c, Badge_Token__c
    FROM Event_Attendee__c
    WHERE Badge_Token__c = null
];

for (Event_Attendee__c attendee : needTokens) {
    attendee.Badge_Token__c = BadgeScanService.newBadgeToken();
}

update needTokens;

System.debug('Tokens minted: ' + needTokens.size());
System.debug('Still without: ' + [SELECT COUNT() FROM Event_Attendee__c WHERE Badge_Token__c = null]);
