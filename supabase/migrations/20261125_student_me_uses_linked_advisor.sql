-- Student-facing profile: show linked advisor profile, with raw Excel text as fallback.
begin;
do $patch$
declare fn text; new_block text;
begin
 select pg_get_functiondef('astroexam.api_action(text,jsonb,uuid,text)'::regprocedure) into fn;
 new_block := $new$
'advisor_name', coalesce(
 (select nullif(trim(advisor.name),'') from profiles advisor
  where advisor.id=who.advisor_teacher_id and advisor.role='teacher' and advisor.active),
 nullif(trim(who.advisor_name),''),''
),
'advisor_teacher_id', who.advisor_teacher_id,
'classes'
$new$;
 if fn !~ $re$'advisor_name', coalesce\((.|\n)*?'classes'$re$ then
  raise exception 'Cannot locate advisor block safely';
 end if;
 fn:=regexp_replace(fn,$re$'advisor_name', coalesce\((.|\n)*?'classes'$re$,new_block,'');
 execute fn;
end; $patch$;
commit;
