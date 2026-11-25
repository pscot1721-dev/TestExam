-- School-wide class directory and multi-class student retrieval.
-- Uses a dedicated SECURITY DEFINER function because the normal teacher RLS policies
-- intentionally restrict class_members/profiles to a teacher's own records.
-- Every request is scoped from the authenticated actor's own active teacher profile.
begin;

create or replace function astroexam.school_students_action(p_mode text,p_data jsonb,p_actor uuid)
returns jsonb language plpgsql security definer
set search_path=astroexam,extensions,pg_temp as $$
declare org text; result jsonb;
begin
 select organization into org from astroexam.profiles
 where id=p_actor and role='teacher' and active=true;
 if not found or nullif(trim(coalesce(org,'')),'') is null then
  raise exception 'บัญชีครูยังไม่ได้กำหนดโรงเรียน หรือบัญชีไม่พร้อมใช้งาน';
 end if;

 if p_mode='school-classes' then
  select coalesce(jsonb_agg(jsonb_build_object(
   'id',c.id,'name',c.name,'teacher_id',c.teacher_id,'teacher_name',owner.name,
   'student_count',(select count(distinct cm.student_id)
    from astroexam.class_members cm join astroexam.profiles st on st.id=cm.student_id and st.role='student'
    where cm.class_id=c.id)
  ) order by c.name,owner.name),'[]'::jsonb) into result
  from astroexam.classes c join astroexam.profiles owner on owner.id=c.teacher_id and owner.role='teacher' and owner.active
  where not c.archived and lower(trim(coalesce(owner.organization,'')))=lower(trim(org));
  return coalesce(result,'[]'::jsonb);

 elsif p_mode='school-retrieve' then
  if jsonb_typeof(p_data->'class_ids') is distinct from 'array'
    or jsonb_array_length(p_data->'class_ids') not between 1 and 100 then
   raise exception 'กรุณาเลือกห้องเรียน 1–100 ห้อง';
  end if;
  if exists(select 1 from jsonb_array_elements_text(p_data->'class_ids') picked(class_id)
   where not exists(select 1 from astroexam.classes c join astroexam.profiles owner on owner.id=c.teacher_id and owner.role='teacher' and owner.active
    where c.id=picked.class_id::uuid and not c.archived and lower(trim(coalesce(owner.organization,'')))=lower(trim(org)))) then
   raise exception 'พบห้องเรียนที่อยู่นอกโรงเรียนของคุณหรือไม่มีสิทธิ์เข้าถึง';
  end if;
  with picked_classes as (
   select c.id,c.name,c.teacher_id from astroexam.classes c
   join astroexam.profiles owner on owner.id=c.teacher_id and owner.role='teacher' and owner.active
   where c.id in (select value::uuid from jsonb_array_elements_text(p_data->'class_ids'))
    and not c.archived and lower(trim(coalesce(owner.organization,'')))=lower(trim(org))
  ), student_rows as (
   select st.id,(to_jsonb(st)-'pin_hash') student_profile,
    jsonb_agg(jsonb_build_object('id',pc.id,'name',pc.name,'teacher_id',pc.teacher_id,'student_number',coalesce(cm.student_number,'')) order by pc.name) student_classes
   from picked_classes pc join astroexam.class_members cm on cm.class_id=pc.id
   join astroexam.profiles st on st.id=cm.student_id and st.role='student' group by st.id
  )
  select jsonb_build_object('school',org,'count',(select count(*) from student_rows),
   'students',coalesce((select jsonb_agg(student_profile||jsonb_build_object('classes',student_classes)
    order by student_profile->>'student_code') from student_rows),'[]'::jsonb)) into result;
  return result;
 else
  raise exception 'Unknown school student action';
 end if;
end; $$;

alter function astroexam.school_students_action(text,jsonb,uuid) owner to postgres;
revoke all on function astroexam.school_students_action(text,jsonb,uuid) from public;
grant execute on function astroexam.school_students_action(text,jsonb,uuid) to ae_runtime;

do $patch$
declare fn text; start_at integer; end_at integer; replacement text;
begin
 select pg_get_functiondef('astroexam.api_action(text,jsonb,uuid,text)'::regprocedure) into fn;
 if position('return astroexam.school_students_action' in fn)>0 then return; end if;
 start_at:=strpos(fn,'if p_action=''students'' and p_data->>''mode''=''school-classes'' then');
 if start_at=0 then raise exception 'School directory branch not found'; end if;
 end_at:=strpos(substring(fn from start_at+1),'if p_action=''students'' then');
 if end_at=0 then raise exception 'Following student branch not found'; end if;
 end_at:=start_at+end_at;
 replacement := $dispatch$
 if p_action='students' and p_data->>'mode' in ('school-classes','school-retrieve') then
  return astroexam.school_students_action(p_data->>'mode',p_data,who.id);
 end if;

 $dispatch$;
 fn:=overlay(fn placing replacement from start_at for end_at-start_at);
 execute fn;
end; $patch$;
commit;
