-- SmartExam: preserve Excel advisor text and link only an unambiguous teacher account.
-- Does not change student login codes, PINs, memberships, exams, or attempts.

begin;
set local search_path = astroexam, extensions, pg_temp;

alter table astroexam.profiles
  add column if not exists advisor_teacher_id uuid
  references astroexam.profiles(id) on delete set null;

create or replace function astroexam.match_advisor_teacher(p_name text,p_school text)
returns uuid
language plpgsql
stable
security definer
set search_path=astroexam,pg_temp
as $$
declare matched_id uuid;
begin
 if nullif(trim(coalesce(p_name,'')),'') is null
    or nullif(trim(coalesce(p_school,'')),'') is null then
  return null;
 end if;

 select min(t.id) into matched_id
 from profiles t
 where t.role='teacher'
   and t.active
   and lower(trim(coalesce(t.name,'')))=lower(trim(p_name))
   and lower(trim(coalesce(t.organization,'')))=lower(trim(p_school))
 having count(*)=1;

 return matched_id;
end;
$$;

create or replace function astroexam.set_student_advisor_link()
returns trigger
language plpgsql
security definer
set search_path=astroexam,pg_temp
as $$
begin
 if new.role='student' then
  if tg_op='INSERT'
     or new.advisor_name is distinct from old.advisor_name
     or new.school is distinct from old.school then
   new.advisor_teacher_id :=
     astroexam.match_advisor_teacher(new.advisor_name,new.school);
  end if;
 end if;
 return new;
end;
$$;

drop trigger if exists ae_student_advisor_link on astroexam.profiles;
create trigger ae_student_advisor_link
before insert or update of advisor_name,school on astroexam.profiles
for each row execute function astroexam.set_student_advisor_link();

-- Backfill only unique exact name + school matches; retain all original advisor text.
update astroexam.profiles s
set advisor_teacher_id=astroexam.match_advisor_teacher(s.advisor_name,s.school)
where s.role='student'
  and nullif(trim(coalesce(s.advisor_name,'')),'') is not null
  and nullif(trim(coalesce(s.school,'')),'') is not null;

-- Ensure the existing students response shows the linked advisor, never the importer.
do $migration$
declare fn text; original text;
begin
 select pg_get_functiondef('astroexam.api_action(text,jsonb,uuid,text)'::regprocedure) into fn;
 if fn is null then raise exception 'ไม่พบ astroexam.api_action(text,jsonb,uuid,text)'; end if;

 if position('left join profiles tp on tp.id=p.advisor_teacher_id' in fn)=0 then
  if position('left join profiles tp on tp.id=who.id and tp.role=''teacher''' in fn)=0 then
   raise exception 'ไม่พบ advisor join เดิมใน students action; ยกเลิกเพื่อป้องกันการแก้ฟังก์ชันผิดเวอร์ชัน';
  end if;
  fn:=replace(fn,
   'left join profiles tp on tp.id=who.id and tp.role=''teacher''',
   'left join profiles tp on tp.id=p.advisor_teacher_id and tp.role=''teacher'' and tp.active'
  );
 end if;

 if position('''advisor_teacher_id'',tp.id' in fn)>0 then
  fn:=replace(fn,'''advisor_teacher_id'',tp.id','''advisor_teacher_id'',p.advisor_teacher_id');
 end if;

 if position('''advisor_name'',coalesce(nullif(trim(tp.name),''''),nullif(trim(p.advisor_name),''''),'''' )' in fn)=0 then
  fn:=replace(fn,
   '''advisor_name'',coalesce(nullif(trim(tp.name),''''),nullif(trim(p.advisor_name),''''),''''),',
   '''advisor_name'',coalesce(nullif(trim(tp.name),''''),nullif(trim(p.advisor_name),''''),''''),'
  );
 end if;

 execute fn;
end
$migration$;

commit;

-- Verification:
-- select name,school,advisor_name,advisor_teacher_id
-- from astroexam.profiles where role='student' order by name limit 30;
-- If advisor_teacher_id is NULL, no unique active teacher with the same name
-- in the same school was found; advisor_name remains available as entered.
