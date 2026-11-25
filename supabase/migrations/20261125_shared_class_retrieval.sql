-- Shared classroom retrieval for teachers in the same organization.
-- A selected classroom is linked to the requesting teacher; its students are
-- linked to the teacher without creating duplicate student profiles.

CREATE OR REPLACE FUNCTION astroexam.link_student(p_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'astroexam','extensions','pg_temp'
AS $function$
DECLARE p astroexam.profiles; n integer; bucket text; c uuid; who uuid;
BEGIN
  who:=astroexam.actor();
  IF astroexam.actor_role()<>'teacher' THEN RAISE EXCEPTION 'ไม่มีสิทธิ์'; END IF;
  c:=(p_data->>'class_id')::uuid;
  IF NOT EXISTS(
    SELECT 1 FROM astroexam.teacher_classes tc
    JOIN astroexam.classes cl ON cl.id=tc.class_id
    WHERE tc.teacher_id=who AND tc.class_id=c AND NOT cl.archived
  ) THEN RAISE EXCEPTION 'ไม่พบห้องเรียนหรือไม่มีสิทธิ์เข้าถึง'; END IF;

  bucket:='link:'||who::text||':'||upper(trim(p_data->>'student_code'));
  INSERT INTO astroexam.login_limits AS l(key) VALUES(bucket)
  ON CONFLICT(key) DO UPDATE
    SET hits=CASE WHEN l.window_start<now()-interval '15 minutes' THEN 1 ELSE l.hits+1 END,
        window_start=CASE WHEN l.window_start<now()-interval '15 minutes' THEN now() ELSE l.window_start END
  RETURNING hits INTO n;
  IF n>5 THEN RETURN jsonb_build_object('error','ลองเกินกำหนด กรุณารอ 15 นาที'); END IF;

  SELECT * INTO p FROM astroexam.profiles
  WHERE role='student' AND student_code=upper(trim(p_data->>'student_code')) AND active;
  IF p.id IS NULL OR octet_length(coalesce(p_data->>'password',''))>72
     OR extensions.crypt(coalesce(p_data->>'password',''),coalesce(p.pin_hash,extensions.gen_salt('bf',10))) IS DISTINCT FROM p.pin_hash
  THEN RETURN jsonb_build_object('error','รหัสนักเรียนหรือรหัสผ่านไม่ถูกต้อง'); END IF;

  INSERT INTO astroexam.teacher_students(teacher_id,student_id)
  VALUES(who,p.id) ON CONFLICT(teacher_id,student_id) DO UPDATE SET active=true;
  INSERT INTO astroexam.class_members(class_id,teacher_id,student_id)
  VALUES(c,who,p.id) ON CONFLICT(class_id,student_id) DO NOTHING;
  DELETE FROM astroexam.login_limits WHERE key=bucket;
  RETURN jsonb_build_object('id',p.id);
END;
$function$;

CREATE OR REPLACE FUNCTION astroexam.school_students_action(p_mode text,p_data jsonb,p_actor uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'astroexam','extensions','pg_temp'
AS $function$
DECLARE org text; result jsonb; total_students integer:=0; linked_students integer:=0; newly_linked integer:=0;
BEGIN
  SELECT organization INTO org FROM astroexam.profiles
  WHERE id=p_actor AND role='teacher' AND active=true;
  IF NOT FOUND OR nullif(trim(coalesce(org,'')),'') IS NULL THEN
    RAISE EXCEPTION 'บัญชีครูยังไม่ได้กำหนดโรงเรียน หรือบัญชีไม่พร้อมใช้งาน';
  END IF;

  IF p_mode='school-classes' THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id',c.id,'name',c.name,'teacher_id',c.teacher_id,'teacher_name',coalesce(owner.name,''),
      'student_count',(SELECT count(DISTINCT cm.student_id)
        FROM astroexam.class_members cm
        JOIN astroexam.profiles st ON st.id=cm.student_id AND st.role='student'
        WHERE cm.class_id=c.id)
    ) ORDER BY c.name,owner.name),'[]'::jsonb) INTO result
    FROM astroexam.classes c
    JOIN astroexam.profiles owner ON owner.id=c.teacher_id AND owner.role='teacher' AND owner.active
    WHERE NOT c.archived AND lower(trim(coalesce(owner.organization,'')))=lower(trim(org));
    RETURN coalesce(result,'[]'::jsonb);

  ELSIF p_mode='school-retrieve' THEN
    IF jsonb_typeof(p_data->'class_ids') IS DISTINCT FROM 'array'
       OR jsonb_array_length(p_data->'class_ids') NOT BETWEEN 1 AND 100
    THEN RAISE EXCEPTION 'กรุณาเลือกห้องเรียน 1–100 ห้อง'; END IF;

    IF EXISTS(
      SELECT 1 FROM jsonb_array_elements_text(p_data->'class_ids') picked(class_id)
      WHERE NOT EXISTS(
        SELECT 1 FROM astroexam.classes c
        JOIN astroexam.profiles owner ON owner.id=c.teacher_id AND owner.role='teacher' AND owner.active
        WHERE c.id=picked.class_id::uuid AND NOT c.archived
          AND lower(trim(coalesce(owner.organization,'')))=lower(trim(org))
      )
    ) THEN RAISE EXCEPTION 'พบห้องเรียนที่อยู่นอกโรงเรียนของคุณหรือไม่มีสิทธิ์เข้าถึง'; END IF;

    SELECT count(DISTINCT cm.student_id)::int INTO total_students
    FROM astroexam.classes c
    JOIN astroexam.profiles owner ON owner.id=c.teacher_id AND owner.role='teacher' AND owner.active
    JOIN astroexam.class_members cm ON cm.class_id=c.id
    JOIN astroexam.profiles st ON st.id=cm.student_id AND st.role='student'
    WHERE c.id IN (SELECT value::uuid FROM jsonb_array_elements_text(p_data->'class_ids'))
      AND NOT c.archived AND lower(trim(coalesce(owner.organization,'')))=lower(trim(org));

    INSERT INTO astroexam.teacher_classes(teacher_id,class_id,linked_by)
    SELECT DISTINCT p_actor,c.id,p_actor
    FROM astroexam.classes c
    JOIN astroexam.profiles owner ON owner.id=c.teacher_id AND owner.role='teacher' AND owner.active
    WHERE c.id IN (SELECT value::uuid FROM jsonb_array_elements_text(p_data->'class_ids'))
      AND NOT c.archived AND lower(trim(coalesce(owner.organization,'')))=lower(trim(org))
    ON CONFLICT(teacher_id,class_id) DO NOTHING;

    INSERT INTO astroexam.teacher_students(teacher_id,student_id,active)
    SELECT DISTINCT p_actor,cm.student_id,true
    FROM astroexam.classes c
    JOIN astroexam.profiles owner ON owner.id=c.teacher_id AND owner.role='teacher' AND owner.active
    JOIN astroexam.class_members cm ON cm.class_id=c.id
    JOIN astroexam.profiles st ON st.id=cm.student_id AND st.role='student'
    WHERE c.id IN (SELECT value::uuid FROM jsonb_array_elements_text(p_data->'class_ids'))
      AND NOT c.archived AND lower(trim(coalesce(owner.organization,'')))=lower(trim(org))
    ON CONFLICT(teacher_id,student_id) DO UPDATE SET active=true;
    GET DIAGNOSTICS newly_linked=ROW_COUNT;

    SELECT count(DISTINCT cm.student_id)::int INTO linked_students
    FROM astroexam.classes c
    JOIN astroexam.profiles owner ON owner.id=c.teacher_id AND owner.role='teacher' AND owner.active
    JOIN astroexam.class_members cm ON cm.class_id=c.id
    JOIN astroexam.profiles st ON st.id=cm.student_id AND st.role='student'
    JOIN astroexam.teacher_students ts ON ts.teacher_id=p_actor AND ts.student_id=cm.student_id AND ts.active=true
    WHERE c.id IN (SELECT value::uuid FROM jsonb_array_elements_text(p_data->'class_ids'))
      AND NOT c.archived AND lower(trim(coalesce(owner.organization,'')))=lower(trim(org));

    RETURN jsonb_build_object('school',org,'selected_students',total_students,
      'linked_or_active',linked_students,'newly_linked',newly_linked);
  ELSE
    RAISE EXCEPTION 'Unknown school student action';
  END IF;
END;
$function$;