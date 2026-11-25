-- School-limited read-only class directory and multi-class student retrieval.
begin;
do $patch$
declare fn text;
 injection text := $school$
 if p_action='students' and p_data->>'mode'='school-classes' then
  if nullif(trim(coalesce(who.organization,'')),'') is null then raise exception 'กรุณากำหนดโรงเรียนในโปรไฟล์ครูก่อน'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
   'id',c.id,'name',c.name,'teacher_id',c.teacher_id,'teacher_name',owner.name,
   'student_count',(select count(distinct cm.student_id) from class_members cm join profiles st on st.id=cm.student_id and st.role='student' where cm.class_id=c.id)
  ) order by c.name,owner.name)
  from classes c join profiles owner on owner.id=c.teacher_id and owner.role='teacher' and owner.active
  where not c.archived and lower(trim(coalesce(owner.organization,'')))=lower(trim(who.organization))),'[]'::jsonb);
 end if;

 if p_action='students' and p_data->>'mode'='school-retrieve' then
  if nullif(trim(coalesce(who.organization,'')),'') is null then raise exception 'กรุณากำหนดโรงเรียนในโปรไฟล์ครูก่อน'; end if;
  if jsonb_typeof(p_data->'class_ids') is distinct from 'array' or jsonb_array_length(p_data->'class_ids') not between 1 and 100 then raise exception 'กรุณาเลือกห้องเรียน 1–100 ห้อง'; end if;
  if exists(select 1 from jsonb_array_elements_text(p_data->'class_ids') picked(class_id)
   where not exists(select 1 from classes c join profiles owner on owner.id=c.teacher_id and owner.role='teacher' and owner.active
    where c.id=picked.class_id::uuid and not c.archived and lower(trim(coalesce(owner.organization,'')))=lower(trim(who.organization)))) then
   raise exception 'พบห้องเรียนที่อยู่นอกโรงเรียนของคุณหรือไม่มีสิทธิ์เข้าถึง';
  end if;
  return (with picked_classes as (
   select c.id,c.name,c.teacher_id from classes c join profiles owner on owner.id=c.teacher_id and owner.role='teacher' and owner.active
   where c.id in (select value::uuid from jsonb_array_elements_text(p_data->'class_ids')) and not c.archived
    and lower(trim(coalesce(owner.organization,'')))=lower(trim(who.organization))
  ), student_rows as (
   select st.id,(to_jsonb(st)-'pin_hash') student_profile,
    jsonb_agg(jsonb_build_object('id',pc.id,'name',pc.name,'teacher_id',pc.teacher_id,'student_number',coalesce(cm.student_number,'')) order by pc.name) student_classes
   from picked_classes pc join class_members cm on cm.class_id=pc.id
   join profiles st on st.id=cm.student_id and st.role='student' group by st.id
  )
  select jsonb_build_object('school',who.organization,'count',(select count(*) from student_rows),
   'students',coalesce((select jsonb_agg(student_profile||jsonb_build_object('classes',student_classes) order by student_profile->>'student_code') from student_rows),'[]'::jsonb)));
 end if;
$school$;
begin
 select pg_get_functiondef('astroexam.api_action(text,jsonb,uuid,text)'::regprocedure) into fn;
 if fn is null then raise exception 'astroexam.api_action not found'; end if;
 if position('p_data->>''mode''=''school-classes''' in fn)>0 then return; end if;
 if position('if p_action=''students'' then' in fn)=0 then raise exception 'Cannot find teacher students branch'; end if;
 fn:=replace(fn,'if p_action=''students'' then',injection||E'\n if p_action=''students'' then');
 execute fn;
end; $patch$;
commit;