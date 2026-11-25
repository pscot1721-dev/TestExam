-- SmartExam: preserve advisor text and add school-first student retrieval.
-- Review and run this migration in Supabase SQL Editor. It does not alter student_code uniqueness.

ALTER TABLE astroexam.profiles
  ADD COLUMN IF NOT EXISTS advisor_teacher_id uuid
  REFERENCES astroexam.profiles(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS profiles_advisor_teacher_id_idx
  ON astroexam.profiles(advisor_teacher_id)
  WHERE advisor_teacher_id IS NOT NULL;

-- Link only an unambiguous teacher account. The advisor_name text is never overwritten.
CREATE OR REPLACE FUNCTION astroexam.resolve_student_advisor_link()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'astroexam', 'extensions', 'pg_temp'
AS $function$
DECLARE candidate uuid; matches integer;
BEGIN
  IF NEW.role <> 'student' THEN RETURN NEW; END IF;
  IF nullif(trim(coalesce(NEW.advisor_name,'')),'') IS NULL THEN
    NEW.advisor_teacher_id := NULL;
    RETURN NEW;
  END IF;

  SELECT min(t.id), count(*) INTO candidate, matches
  FROM profiles t
  WHERE t.role='teacher' AND t.active
    AND lower(trim(t.name))=lower(trim(NEW.advisor_name))
    AND (
      nullif(trim(t.organization),'') IS NULL
      OR nullif(trim(NEW.school),'') IS NULL
      OR lower(trim(t.organization))=lower(trim(NEW.school))
    );

  NEW.advisor_teacher_id := CASE WHEN matches=1 THEN candidate ELSE NULL END;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS profiles_resolve_student_advisor_link ON astroexam.profiles;
CREATE TRIGGER profiles_resolve_student_advisor_link
BEFORE INSERT OR UPDATE OF role, advisor_name, school ON astroexam.profiles
FOR EACH ROW EXECUTE FUNCTION astroexam.resolve_student_advisor_link();

-- When a teacher account is created later, link previously unmatched students.
-- This updates only advisor_teacher_id, never advisor_name.
CREATE OR REPLACE FUNCTION astroexam.link_new_teacher_to_student_advisors()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'astroexam', 'extensions', 'pg_temp'
AS $function$
BEGIN
  IF NEW.role='teacher' AND NEW.active THEN
    UPDATE profiles s
    SET advisor_teacher_id=NEW.id
    WHERE s.role='student'
      AND s.advisor_teacher_id IS NULL
      AND lower(trim(s.advisor_name))=lower(trim(NEW.name))
      AND (
        nullif(trim(NEW.organization),'') IS NULL
        OR nullif(trim(s.school),'') IS NULL
        OR lower(trim(NEW.organization))=lower(trim(s.school))
      )
      AND (
        SELECT count(*) FROM profiles t
        WHERE t.role='teacher' AND t.active
          AND lower(trim(t.name))=lower(trim(s.advisor_name))
          AND (
            nullif(trim(t.organization),'') IS NULL
            OR nullif(trim(s.school),'') IS NULL
            OR lower(trim(t.organization))=lower(trim(s.school))
          )
      )=1;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS profiles_link_new_teacher_to_student_advisors ON astroexam.profiles;
CREATE TRIGGER profiles_link_new_teacher_to_student_advisors
AFTER INSERT OR UPDATE OF name, organization, active, role ON astroexam.profiles
FOR EACH ROW EXECUTE FUNCTION astroexam.link_new_teacher_to_student_advisors();

CREATE OR REPLACE FUNCTION astroexam.student_directory_schools(p_teacher uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'astroexam', 'extensions', 'pg_temp'
AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id=p_teacher AND role='teacher' AND active) THEN
    RAISE EXCEPTION 'บัญชีครูไม่ถูกต้อง';
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'school', x.school,
      'student_count', x.student_count,
      'room_count', x.room_count
    ) ORDER BY x.school)
    FROM (
      SELECT p.school,
             count(DISTINCT p.id)::integer AS student_count,
             count(DISTINCT c.id)::integer AS room_count
      FROM profiles p
      JOIN class_members m ON m.student_id=p.id
      JOIN classes c ON c.id=m.class_id AND NOT c.archived
      WHERE p.role='student' AND p.active
        AND nullif(trim(p.school),'') IS NOT NULL
      GROUP BY p.school
    ) x
  ), '[]'::jsonb);
END;
$function$;

CREATE OR REPLACE FUNCTION astroexam.student_directory_classes(p_teacher uuid, p_school text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'astroexam', 'extensions', 'pg_temp'
AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id=p_teacher AND role='teacher' AND active) THEN
    RAISE EXCEPTION 'บัญชีครูไม่ถูกต้อง';
  END IF;
  IF nullif(trim(coalesce(p_school,'')),'') IS NULL THEN
    RAISE EXCEPTION 'กรุณาเลือกโรงเรียน';
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id', x.id,
      'name', x.name,
      'student_count', x.student_count,
      'source_teacher', x.source_teacher
    ) ORDER BY x.name, x.source_teacher)
    FROM (
      SELECT c.id, c.name, tp.name AS source_teacher,
             count(DISTINCT p.id)::integer AS student_count
      FROM classes c
      JOIN class_members m ON m.class_id=c.id
      JOIN profiles p ON p.id=m.student_id
      LEFT JOIN profiles tp ON tp.id=c.teacher_id AND tp.role='teacher'
      WHERE NOT c.archived
        AND p.role='student' AND p.active
        AND p.school=trim(p_school)
      GROUP BY c.id, c.name, tp.name
      HAVING count(DISTINCT p.id)>0
    ) x
  ), '[]'::jsonb);
END;
$function$;

CREATE OR REPLACE FUNCTION astroexam.student_directory_import_rooms(
  p_teacher uuid, p_school text, p_class_ids uuid[]
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'astroexam', 'extensions', 'pg_temp'
AS $function$
DECLARE
  src record;
  stu record;
  target_class uuid;
  seen_students uuid[] := ARRAY[]::uuid[];
  room_count integer := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id=p_teacher AND role='teacher' AND active) THEN
    RAISE EXCEPTION 'บัญชีครูไม่ถูกต้อง';
  END IF;
  IF nullif(trim(coalesce(p_school,'')),'') IS NULL THEN
    RAISE EXCEPTION 'กรุณาเลือกโรงเรียน';
  END IF;
  IF coalesce(array_length(p_class_ids,1),0) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'กรุณาเลือกห้องเรียน 1–100 ห้อง';
  END IF;

  IF EXISTS (
    SELECT 1 FROM unnest(p_class_ids) chosen(id)
    WHERE NOT EXISTS (
      SELECT 1
      FROM classes c
      JOIN class_members m ON m.class_id=c.id
      JOIN profiles p ON p.id=m.student_id
      WHERE c.id=chosen.id AND NOT c.archived
        AND p.role='student' AND p.active AND p.school=trim(p_school)
    )
  ) THEN
    RAISE EXCEPTION 'มีห้องเรียนที่ไม่อยู่ในโรงเรียนที่เลือก กรุณาโหลดรายการใหม่';
  END IF;

  FOR src IN
    SELECT DISTINCT c.id, c.name, c.description
    FROM classes c
    WHERE c.id=ANY(p_class_ids) AND NOT c.archived
    ORDER BY c.name, c.id
  LOOP
    INSERT INTO classes(teacher_id,name,description)
    VALUES(p_teacher,src.name,coalesce(src.description,'นำเข้าจากฐานข้อมูล: '||trim(p_school)))
    ON CONFLICT(teacher_id,name) DO UPDATE
      SET description=coalesce(nullif(classes.description,''),excluded.description)
    RETURNING id INTO target_class;

    FOR stu IN
      SELECT p.id AS student_id, coalesce(m.student_number,'') AS student_number
      FROM class_members m
      JOIN profiles p ON p.id=m.student_id
      WHERE m.class_id=src.id
        AND p.role='student' AND p.active
        AND p.school=trim(p_school)
      ORDER BY nullif(m.student_number,'')::integer NULLS LAST, p.name
    LOOP
      INSERT INTO teacher_students(teacher_id,student_id,active)
      VALUES(p_teacher,stu.student_id,true)
      ON CONFLICT(teacher_id,student_id) DO UPDATE SET active=true;

      INSERT INTO class_members(class_id,teacher_id,student_id,student_number)
      VALUES(target_class,p_teacher,stu.student_id,stu.student_number)
      ON CONFLICT(class_id,student_id) DO UPDATE
        SET student_number=excluded.student_number;

      IF NOT (stu.student_id = ANY(seen_students)) THEN
        seen_students := array_append(seen_students,stu.student_id);
      END IF;
    END LOOP;
    room_count := room_count + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok',true,
    'imported',coalesce(array_length(seen_students,1),0),
    'rooms_imported',room_count,
    'school',trim(p_school)
  );
END;
$function$;

-- Extend the existing authenticated RPC dispatcher without changing the login/session flow.
CREATE OR REPLACE FUNCTION public.astroexam_api(
  p_action text,
  p_data jsonb DEFAULT '{}'::jsonb,
  p_actor uuid DEFAULT NULL::uuid,
  p_token text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'astroexam', 'extensions', 'pg_temp'
AS $function$
DECLARE
  who astroexam.profiles;
  result jsonb;
  token text;
  login_code text;
  bucket text;
  n integer;
BEGIN
  IF p_action='staff-login' THEN
    login_code:=lower(trim(coalesce(p_data->>'username','')));
    token:=coalesce(p_data->>'password','');
    IF login_code !~ '^[a-z0-9_.-]{3,40}$' OR length(token)<1 OR octet_length(token)>72 THEN
      RETURN jsonb_build_object('error','Username หรือ Password ไม่ถูกต้อง');
    END IF;
    bucket:='staff:'||login_code;
    INSERT INTO login_limits AS l(key) VALUES(bucket)
    ON CONFLICT(key) DO UPDATE
      SET hits=CASE WHEN l.window_start<now()-interval '15 minutes' THEN 1 ELSE l.hits+1 END,
          window_start=CASE WHEN l.window_start<now()-interval '15 minutes' THEN now() ELSE l.window_start END
    RETURNING hits INTO n;
    IF n>5 THEN RETURN jsonb_build_object('error','ลองเข้าสู่ระบบเกินกำหนด กรุณารอ 15 นาที'); END IF;
    SELECT * INTO who FROM profiles
    WHERE lower(username)=login_code AND role IN ('teacher','admin') AND active AND pin_hash IS NOT NULL;
    IF who.id IS NULL OR extensions.crypt(token,coalesce(who.pin_hash,extensions.gen_salt('bf',10))) IS DISTINCT FROM who.pin_hash THEN
      RETURN jsonb_build_object('error','Username หรือ Password ไม่ถูกต้อง');
    END IF;
    DELETE FROM login_limits WHERE key=bucket;
    token:=encode(extensions.gen_random_bytes(32),'hex');
    INSERT INTO staff_sessions(token_hash,staff_id)
    VALUES(encode(extensions.digest(token,'sha256'),'hex'),who.id);
    UPDATE profiles SET last_login_at=now() WHERE id=who.id;
    RETURN jsonb_build_object('token',token,'profile',to_jsonb(who)-'pin_hash','expires_at',now()+interval '12 hours');
  END IF;

  IF p_action='student-login' THEN
    login_code:=upper(trim(coalesce(p_data->>'code',p_data->>'username','')));
    token:=coalesce(p_data->>'password',p_data->>'pin','');
    IF login_code !~ '^[A-Z0-9_-]{1,40}$' OR length(token)<1 OR octet_length(token)>72 THEN
      RETURN jsonb_build_object('error','รหัสนักเรียนหรือรหัสผ่านไม่ถูกต้อง');
    END IF;
    bucket:='account:'||login_code;
    INSERT INTO login_limits AS l(key) VALUES(bucket)
    ON CONFLICT(key) DO UPDATE
      SET hits=CASE WHEN l.window_start<now()-interval '15 minutes' THEN 1 ELSE l.hits+1 END,
          window_start=CASE WHEN l.window_start<now()-interval '15 minutes' THEN now() ELSE l.hits+1 END
    RETURNING hits INTO n;
    IF n>5 THEN RETURN jsonb_build_object('error','ลองเข้าสู่ระบบเกินกำหนด กรุณารอ 15 นาที'); END IF;
    SELECT * INTO who FROM profiles
    WHERE student_code=login_code AND role='student' AND active;
    IF who.id IS NULL
       OR NOT EXISTS(SELECT 1 FROM teacher_students WHERE student_id=who.id AND active)
       OR extensions.crypt(token,coalesce(who.pin_hash,extensions.gen_salt('bf',10))) IS DISTINCT FROM who.pin_hash THEN
      RETURN jsonb_build_object('error','รหัสนักเรียนหรือรหัสผ่านไม่ถูกต้อง');
    END IF;
    DELETE FROM login_limits WHERE key=bucket;
    token:=encode(extensions.gen_random_bytes(32),'hex');
    INSERT INTO student_sessions(token_hash,student_id)
    VALUES(encode(extensions.digest(token,'sha256'),'hex'),who.id);
    UPDATE profiles SET last_login_at=now() WHERE id=who.id;
    RETURN jsonb_build_object('token',token,'profile',to_jsonb(who)-'pin_hash','expires_at',now()+interval '12 hours');
  END IF;

  IF p_actor IS NOT NULL THEN
    SELECT * INTO who FROM profiles
    WHERE auth_user_id=p_actor AND role IN ('teacher','admin') AND active;
  ELSE
    SELECT p.* INTO who
    FROM profiles p JOIN staff_sessions s ON s.staff_id=p.id
    WHERE s.token_hash=encode(extensions.digest(coalesce(p_token,''),'sha256'),'hex')
      AND s.expires_at>now() AND p.active AND p.role IN ('teacher','admin');
    IF who.id IS NULL THEN
      SELECT p.* INTO who
      FROM profiles p JOIN student_sessions s ON s.student_id=p.id
      WHERE s.token_hash=encode(extensions.digest(coalesce(p_token,''),'sha256'),'hex')
        AND s.expires_at>now() AND p.active AND p.role='student'
        AND EXISTS(SELECT 1 FROM teacher_students WHERE student_id=p.id AND active);
    END IF;
  END IF;

  IF who.id IS NULL THEN
    RETURN jsonb_build_object('error','เซสชันหมดอายุหรือบัญชีถูกปิด','unauthorized',true);
  END IF;

  IF p_action='logout' THEN
    IF who.role IN ('teacher','admin') THEN
      DELETE FROM staff_sessions WHERE token_hash=encode(extensions.digest(coalesce(p_token,''),'sha256'),'hex');
    ELSE
      DELETE FROM student_sessions WHERE token_hash=encode(extensions.digest(coalesce(p_token,''),'sha256'),'hex');
    END IF;
    RETURN '{"ok":true}';
  END IF;

  IF p_actor IS NOT NULL AND p_action='me' THEN
    UPDATE profiles SET last_login_at=(SELECT last_sign_in_at FROM auth.users WHERE id=p_actor)
    WHERE id=who.id;
  END IF;

  PERFORM set_config('ae.actor',who.id::text,true);
  PERFORM set_config('ae.role',who.role,true);

  IF who.role='teacher' AND p_action='student-directory-schools' THEN
    RETURN astroexam.student_directory_schools(who.id);
  ELSIF who.role='teacher' AND p_action='student-directory-classes' THEN
    RETURN astroexam.student_directory_classes(who.id,p_data->>'school');
  ELSIF who.role='teacher' AND p_action='student-directory-import-rooms' THEN
    RETURN astroexam.student_directory_import_rooms(
      who.id,
      p_data->>'school',
      ARRAY(SELECT jsonb_array_elements_text(coalesce(p_data->'class_ids','[]'::jsonb))::uuid)
    );
  END IF;

  result:=astroexam.api_action(p_action,p_data,null,p_token);

  -- The advisor display value is the stored Excel/manual text, not a teacher profile name.
  IF p_action='me' AND who.role='student' THEN
    result:=result || jsonb_build_object(
      'advisor_name',coalesce(who.advisor_name,''),
      'advisor_teacher_id',who.advisor_teacher_id
    );
  ELSIF p_action='students' AND who.role='teacher' THEN
    SELECT coalesce(jsonb_agg(
      item || jsonb_build_object('advisor_name',coalesce(p.advisor_name,''),'advisor_teacher_id',p.advisor_teacher_id)
    ),'[]'::jsonb)
    INTO result
    FROM jsonb_array_elements(coalesce(result,'[]'::jsonb)) item
    JOIN profiles p ON p.id=(item->>'id')::uuid;
  END IF;

  IF p_action='me' AND who.role IN ('teacher','admin') THEN
    result:=result||jsonb_build_object(
      'username',who.username,
      'email',(SELECT email FROM auth.users WHERE id=who.auth_user_id)
    );
  END IF;
  RETURN result;
END;
$function$;
