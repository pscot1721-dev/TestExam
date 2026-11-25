-- Normalize common Thai academic/professional honorifics before matching advisors.
-- Original advisor_name text is preserved; only advisor_teacher_id is backfilled.
begin;
create or replace function astroexam.normalize_advisor_name(p_name text)
returns text language sql immutable
set search_path=astroexam,pg_temp
as $$
 select lower(trim(regexp_replace(
  regexp_replace(coalesce(p_name,''),'^(ศ\\.?|รศ\\.?|ผศ\\.?|ดร\\.?|อาจารย์|นาย|นางสาว|นาง)[[:space:]]*','', 'i'),
  '[[:space:]]+',' ','g'
 )));
$$;

create or replace function astroexam.match_advisor_teacher(p_name text,p_school text)
returns uuid language plpgsql stable security definer
set search_path=astroexam,pg_temp as $$
declare matched_id uuid;
begin
 if nullif(trim(coalesce(p_name,'')),'') is null or nullif(trim(coalesce(p_school,'')),'') is null then return null; end if;
 select (array_agg(t.id))[1] into matched_id
 from astroexam.profiles t
 where t.role='teacher' and t.active
  and astroexam.normalize_advisor_name(t.name)=astroexam.normalize_advisor_name(p_name)
  and lower(trim(coalesce(t.organization,'')))=lower(trim(p_school))
 having count(*)=1;
 return matched_id;
end; $$;

update astroexam.profiles s
set advisor_teacher_id=astroexam.match_advisor_teacher(s.advisor_name,s.school)
where s.role='student'
 and nullif(trim(coalesce(s.advisor_name,'')),'') is not null
 and nullif(trim(coalesce(s.school,'')),'') is not null;
commit;
