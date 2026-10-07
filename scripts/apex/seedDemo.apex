/**
 * Makes sure the demo preconditions hold, then prints what to scan.
 *
 *   sf apex run --file scripts/apex/seedDemo.apex
 *
 * Idempotent: run it before every rehearsal. It does not load the guest list,
 * which is already in the org - it only puts the org into a state where the
 * demo script works end to end.
 */

// 1. The event has to be Active or every scan is refused by design.
List<Event_Registry__c> registries = [
    SELECT Id, Name, Status__c, Campaign__c, Total_Attendees__c, Checked_In_Count__c
    FROM Event_Registry__c
];
for (Event_Registry__c registry : registries) {
    registry.Status__c = 'Active';
}
update registries;

// 2. 'Attended' is per campaign and is what the service looks for.
Set<Id> campaignIds = new Set<Id>();
for (Event_Registry__c registry : registries) {
    if (registry.Campaign__c != null) {
        campaignIds.add(registry.Campaign__c);
    }
}

Set<Id> haveAttended = new Set<Id>();
for (CampaignMemberStatus status : [
    SELECT CampaignId FROM CampaignMemberStatus WHERE CampaignId IN :campaignIds AND Label = 'Attended'
]) {
    haveAttended.add(status.CampaignId);
}

List<CampaignMemberStatus> toAdd = new List<CampaignMemberStatus>();
for (Id campaignId : campaignIds) {
    if (!haveAttended.contains(campaignId)) {
        toAdd.add(new CampaignMemberStatus(
            CampaignId = campaignId, Label = 'Attended', SortOrder = 12, HasResponded = true
        ));
    }
}
if (!toAdd.isEmpty()) {
    insert toAdd;
}

// 3. One guest already exists as a Contact, so the demo can show that a scan
//    reuses the person rather than creating a second copy.
List<Event_Attendee__c> sample = [
    SELECT First_Name__c, Last_Name__c, Email__c, Phone__c, Badge_Id__c
    FROM Event_Attendee__c
    WHERE Email__c != null
    ORDER BY Badge_Id__c
    LIMIT 1
];

String seededContact = 'none';
if (!sample.isEmpty()) {
    Event_Attendee__c guest = sample[0];
    List<Contact> already = [SELECT Id FROM Contact WHERE Email = :guest.Email__c LIMIT 1];

    if (already.isEmpty()) {
        insert new Contact(
            FirstName = guest.First_Name__c,
            LastName = guest.Last_Name__c,
            Email = guest.Email__c,
            MobilePhone = guest.Phone__c
        );
        seededContact = guest.First_Name__c + ' ' + guest.Last_Name__c + ' (badge ' + guest.Badge_Id__c + ')';
    } else {
        seededContact = guest.Email__c + ' already existed';
    }
}

// 4. Badges to scan during the demo.
List<Event_Attendee__c> badges = [
    SELECT Badge_Id__c, First_Name__c, Last_Name__c, Company__c, Checked_In__c
    FROM Event_Attendee__c
    ORDER BY Badge_Id__c
    LIMIT 5
];

System.debug('Seed complete.');
for (Event_Registry__c registry : registries) {
    System.debug('  event: ' + registry.Name + ' [' + registry.Id + '] status Active, '
        + registry.Total_Attendees__c + ' attendees, ' + registry.Checked_In_Count__c + ' checked in');
}
System.debug('  attended statuses added: ' + toAdd.size());
System.debug('  pre-existing contact:    ' + seededContact);
System.debug('  badges to scan:');
for (Event_Attendee__c badge : badges) {
    System.debug('    ' + badge.Badge_Id__c + '  ' + badge.First_Name__c + ' ' + badge.Last_Name__c
        + '  (' + badge.Company__c + ')' + (badge.Checked_In__c ? '  [already in]' : ''));
}
