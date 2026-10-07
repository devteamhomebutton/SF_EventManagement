/**
 * Returns the demo org to its pre-event state, so a rehearsal can be run again.
 *
 *   sf apex run --file scripts/apex/resetDemo.apex
 *
 * Removes everything the check-in app created and leaves the loaded guest list
 * untouched apart from clearing its check-in flags. Safe to run repeatedly.
 *
 * The Contact cleanup matches on the guest list's own email addresses, which in
 * this org are all @example.com and do not overlap the pre-existing Contacts.
 */

// 1. The audit log.
List<Badge_Scan__c> scans = [SELECT Id FROM Badge_Scan__c];
delete scans;

// 2. Enquiries raised by the app, with their follow-up Tasks (Tasks go with the Lead).
List<Lead> enquiries = [SELECT Id FROM Lead WHERE Event_Registry__c != null];
delete enquiries;

// 3. Campaign Members for the events in play.
Set<Id> campaignIds = new Set<Id>();
for (Event_Registry__c registry : [SELECT Campaign__c FROM Event_Registry__c WHERE Campaign__c != null]) {
    campaignIds.add(registry.Campaign__c);
}
List<CampaignMember> members = [SELECT Id FROM CampaignMember WHERE CampaignId IN :campaignIds];
delete members;

// 4. Collect every email on the object BEFORE anything is deleted. Walk-up rows
//    are about to go, and their Contacts have to be cleaned up too - gathering
//    emails after the delete would orphan them.
List<Event_Attendee__c> everyone = [
    SELECT Id, Email__c, Badge_Id__c, Checked_In__c, Checked_In_At__c, Contact__c, Lead__c
    FROM Event_Attendee__c
];

Set<String> guestEmails = new Set<String>();
List<Event_Attendee__c> walkUps = new List<Event_Attendee__c>();
List<Event_Attendee__c> guestList = new List<Event_Attendee__c>();

for (Event_Attendee__c attendee : everyone) {
    if (String.isNotBlank(attendee.Email__c)) {
        guestEmails.add(attendee.Email__c);
    }

    if (attendee.Badge_Id__c != null && attendee.Badge_Id__c.startsWith('WALK-')) {
        walkUps.add(attendee);
    } else {
        guestList.add(attendee);
    }
}

// 5. Walk-ups added on the day.
delete walkUps;

// 6. Clear the check-in flags on the loaded guest list.
for (Event_Attendee__c attendee : guestList) {
    attendee.Checked_In__c = false;
    attendee.Checked_In_At__c = null;
    attendee.Contact__c = null;
    attendee.Lead__c = null;
}
update guestList;

// 7. Contacts the scans created, walk-ups included.
List<Contact> created = [SELECT Id FROM Contact WHERE Email IN :guestEmails];
delete created;

// 8. Open the event back up.
List<Event_Registry__c> registries = [SELECT Id, Status__c FROM Event_Registry__c];
for (Event_Registry__c registry : registries) {
    registry.Status__c = 'Active';
}
update registries;

System.debug('Reset complete.');
System.debug('  badge scans deleted:      ' + scans.size());
System.debug('  enquiries deleted:        ' + enquiries.size());
System.debug('  campaign members deleted: ' + members.size());
System.debug('  walk-ups deleted:         ' + walkUps.size());
System.debug('  guest list cleared:       ' + guestList.size());
System.debug('  contacts deleted:         ' + created.size());
System.debug('  events set to Active:     ' + registries.size());
