-- SmartExam advisor linking: preserve Excel text, resolve linked teacher profile live.
begin;
alter table astroexam.profiles
 add column if not exists advisor_teacher_id uuid
 references astroexam.profiles(id) on delete set null;

create or replace function astroexam.match_advisor_teacher(p_name text,p_school text)
returns uuid language plpgsql stable security definer
set search_path=astroexam,pg_temp as $$
declare matched_id uuid;
begin
 if nullif(trim(coalesce(p_name,'')),'') is null or nullif(trim(coalesce(p_school,'')),'') is null then return null; end if;
 select (array_agg(t.id))[1] into matched_id
 from astroexam.profiles t
 where t.role='teacher' and t.active
  and lower(trim(coalesce(t.name,'')))=lower(trim(p_name))
  and lower(trim(coalesce(t.organization,'')))=lower(trim(p_school))
 having count(*)=1;
 return matched_id;
end; $$;

create or replace function astroexam.set_student_advisor_link()
returns trigger language plpgsql security definer
set search_path=astroexam,pg_temp as $$
begin
 if new.role='student' and (tg_op='INSERT' or new.advisor_name is distinct from old.advisor_name or new.school is distinct from old.school) then
  new.advisor_teacher_id:=astroexam.match_advisor_teacher(new.advisor_name,new.school);
 end if;
 return new;
end; $$;
drop trigger if exists ae_student_advisor_link on astroexam.profiles;
create trigger ae_student_advisor_link before insert or update of advisor_name,school on astroexam.profiles
for each row execute function astroexam.set_student_advisor_link();

create or replace function astroexam.backfill_student_advisor_links_for_teacher()
returns trigger language plpgsql security definer
set search_path=astroexam,pg_temp as $$
begin
 if new.role='teacher' and new.active then
  update astroexam.profiles s
  set advisor_teacher_id=astroexam.match_advisor_teacher(s.advisor_name,s.school)
  where s.role='student' and s.advisor_teacher_id is null
   and lower(trim(coalesce(s.advisor_name,'')))=lower(trim(new.name))
   and lower(trim(coalesce(s.school,'')))=lower(trim(new.organization));
 end if;
 return new;
end; $$;
drop trigger if exists ae_teacher_backfill_student_advisors on astroexam.profiles;
create trigger ae_teacher_backfill_student_advisors after insert or update of name,organization,active on astroexam.profiles
for each row when (new.role='teacher') execute function astroexam.backfill_student_advisor_links_for_teacher();

update astroexam.profiles s
set advisor_teacher_id=astroexam.match_advisor_teacher(s.advisor_name,s.school)
where s.role='student' and nullif(trim(coalesce(s.advisor_name,'')),'') is not null
 and nullif(trim(coalesce(s.school,'')),'') is not null;

do $patch$
declare fn text;
begin
 select pg_get_functiondef('astroexam.api_action(text,jsonb,uuid,text)'::regprocedure) into fn;
 if fn is null then raise exception 'astroexam.api_action not found'; end if;
 if position('left join profiles tp on tp.id=who.id and tp.role=''teacher''' in fn)>0 then
  fn:=replace(fn,'left join profiles tp on tp.id=who.id and tp.role=''teacher''',
   'left join profiles tp on tp.id=p.advisor_teacher_id and tp.role=''teacher'' and tp.active');
 end if;
 if position('advisor_name=coalesce(nullif(trim(p_data->>''advisor_name''),''''),advisor_name,'''')' in fn)>0 then
  fn:=replace(fn,'advisor_name=coalesce(nullif(trim(p_data->>''advisor_name''),''''),advisor_name,'''')',
   'advisor_name=case when p_data ? ''advisor_name'' then coalesce(trim(p_data->>''advisor_name''),'''') else advisor_name end');
 end if;
 execute fn;
end; $patch$;
commit;