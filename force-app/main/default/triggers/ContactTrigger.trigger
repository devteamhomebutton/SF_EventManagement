trigger ContactTrigger on Contact (before insert, before update) 
{
	ContactEmailDuplication.preventDuplicateEmail(Trigger.new, Trigger.oldMap);
}