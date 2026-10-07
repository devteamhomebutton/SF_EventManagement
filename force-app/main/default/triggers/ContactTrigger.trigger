trigger ContactTrigger on Contact (before insert, before update) 
{
	ContactEmailDuplication.preventDuplicateEmail(Trigger.new);
}