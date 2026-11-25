-- SmartExam relationship semantics:
-- 1) Student profiles are global accounts.
-- 2) Teacher/student and teacher/class are independent many-to-many links.
-- 3) Class membership is class/student and survives teacher removal.
-- 4) Removing a teacher/student link never deletes a student account.
-- 5) Deleting a class removes memberships/assignments only, not students.
-- This migration records the final function definitions installed in production.

ALTER TABLE astroexam.teacher_classes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS teacher_classes_deny_direct_access ON astroexam.teacher_classes;
CREATE POLICY teacher_classes_deny_direct_access ON astroexam.teacher_classes FOR ALL TO PUBLIC USING (false) WITH CHECK (false);

CREATE OR REPLACE FUNCTION astroexam.cleanup_student_after_teacher_unlink()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'astroexam','extensions','pg_temp'
AS $function$
BEGIN
  RETURN OLD;
END;
$function$;

CREATE OR REPLACE FUNCTION astroexam.safe_delete_class_for_teacher(p_teacher uuid,p_class uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'astroexam','extensions','pg_temp'
AS $function$
DECLARE removed_count integer := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM astroexam.profiles WHERE id=p_teacher AND role='teacher' AND active) THEN
    RAISE EXCEPTION 'บัญชีครูไม่ถูกต้อง';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM astroexam.classes WHERE id=p_class AND teacher_id=p_teacher) THEN
    RAISE EXCEPTION 'คุณไม่มีสิทธิ์ลบห้องเรียนนี้';
  END IF;
  SELECT count(*)::int INTO removed_count FROM astroexam.class_members WHERE class_id=p_class;
  DELETE FROM astroexam.classes WHERE id=p_class AND teacher_id=p_teacher;
  RETURN jsonb_build_object('ok',true,'scope','class_only','removed_memberships',removed_count,'students_deleted',0);
END;
$function$;

CREATE OR REPLACE FUNCTION astroexam.remove_student_from_teacher(p_teacher uuid,p_student uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'astroexam','extensions','pg_temp'
AS $function$
DECLARE removed_links integer := 0;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM astroexam.profiles WHERE id=p_teacher AND role='teacher' AND active) THEN
    RAISE EXCEPTION 'บัญชีครูไม่ถูกต้อง';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM astroexam.teacher_students WHERE teacher_id=p_teacher AND student_id=p_student) THEN
    RAISE EXCEPTION 'นักเรียนไม่อยู่ในความดูแลของครูคนนี้';
  END IF;
  DELETE FROM astroexam.exam_assignments x
  USING astroexam.exams e
  WHERE x.exam_id=e.id AND e.teacher_id=p_teacher AND x.student_id=p_student AND x.class_id IS NULL;
  DELETE FROM astroexam.teacher_students WHERE teacher_id=p_teacher AND student_id=p_student;
  GET DIAGNOSTICS removed_links=ROW_COUNT;
  RETURN jsonb_build_object('ok',true,'scope','teacher_link_only','removed_links',removed_links,'student_account_deleted',false);
END;
$function$;

CREATE OR REPLACE FUNCTION astroexam.sync_exam_class_assignment(p_exam uuid,p_teacher uuid,p_class uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'astroexam','extensions','pg_temp'
AS $function$
BEGIN
  IF p_exam IS NULL OR p_teacher IS NULL OR p_class IS NULL THEN RETURN; END IF;
  INSERT INTO astroexam.teacher_students(teacher_id,student_id,active)
  SELECT DISTINCT p_teacher,cm.student_id,true
  FROM astroexam.class_members cm
  JOIN astroexam.profiles st ON st.id=cm.student_id AND st.role='student' AND st.active
  WHERE cm.class_id=p_class
  ON CONFLICT(teacher_id,student_id) DO UPDATE SET active=true;

  DELETE FROM astroexam.exam_assignments
  WHERE exam_id=p_exam AND teacher_id=p_teacher AND class_id IS NULL
    AND assignment_scope='class_expanded'
    AND student_id IN (SELECT cm.student_id FROM astroexam.class_members cm WHERE cm.class_id=p_class);

  INSERT INTO astroexam.exam_assignments(exam_id,teacher_id,class_id,student_id,assignment_scope)
  SELECT DISTINCT p_exam,p_teacher,NULL::uuid,cm.student_id,'class_expanded'
  FROM astroexam.class_members cm
  JOIN astroexam.profiles st ON st.id=cm.student_id AND st.role='student' AND st.active
  WHERE cm.class_id=p_class
  ON CONFLICT(exam_id,student_id) DO UPDATE
    SET teacher_id=excluded.teacher_id,
        assignment_scope=CASE WHEN astroexam.exam_assignments.assignment_scope='manual'
          THEN 'manual' ELSE 'class_expanded' END;
END;
$function$;

CREATE OR REPLACE FUNCTION astroexam.hard_delete_teacher(p_teacher uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'astroexam','extensions','pg_temp'
AS $function$
DECLARE t_code text;
BEGIN
  IF p_teacher IS NULL THEN RETURN; END IF;
  SELECT username INTO t_code FROM astroexam.profiles
  WHERE id=p_teacher AND role='teacher' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ไม่พบบัญชีครู'; END IF;

  DELETE FROM astroexam.security_events se USING astroexam.attempts a,astroexam.exams e
  WHERE se.attempt_id=a.id AND a.exam_id=e.id AND e.teacher_id=p_teacher;
  DELETE FROM astroexam.answers an USING astroexam.attempts a,astroexam.exams e
  WHERE an.attempt_id=a.id AND a.exam_id=e.id AND e.teacher_id=p_teacher;
  DELETE FROM astroexam.attempt_questions aq USING astroexam.attempts a,astroexam.exams e
  WHERE aq.attempt_id=a.id AND a.exam_id=e.id AND e.teacher_id=p_teacher;
  DELETE FROM astroexam.attempts a USING astroexam.exams e
  WHERE a.exam_id=e.id AND e.teacher_id=p_teacher;
  DELETE FROM astroexam.question_templates qt USING astroexam.exams e
  WHERE qt.exam_id=e.id AND e.teacher_id=p_teacher;
  DELETE FROM astroexam.exam_assignments WHERE teacher_id=p_teacher;
  DELETE FROM astroexam.exams WHERE teacher_id=p_teacher;

  -- classes.teacher_id and class_members.teacher_id use ON DELETE SET NULL.
  -- teacher_classes and teacher_students are only the deleted teacher's links.
  DELETE FROM astroexam.staff_sessions WHERE staff_id=p_teacher;
  IF t_code IS NOT NULL THEN DELETE FROM astroexam.login_limits WHERE key='staff:'||lower(t_code); END IF;
  DELETE FROM astroexam.admin_audit WHERE target_id=p_teacher OR actor_id=p_teacher;
  UPDATE astroexam.profiles SET created_by=NULL WHERE created_by=p_teacher;
  UPDATE astroexam.profiles SET advisor_teacher_id=NULL WHERE advisor_teacher_id=p_teacher;
  UPDATE astroexam.answers SET graded_by=NULL WHERE graded_by=p_teacher;
  PERFORM set_config('app.teacher_hard_delete','on',true);
  DELETE FROM astroexam.teacher_students WHERE teacher_id=p_teacher;
  DELETE FROM astroexam.profiles WHERE id=p_teacher AND role='teacher';
END;
$function$;

CREATE OR REPLACE FUNCTION astroexam.assigned_exams_for_student(p_student uuid)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'astroexam','extensions','pg_temp'
AS $function$
 SELECT coalesce(jsonb_agg(
  to_jsonb(e)||jsonb_build_object(
   'server_now',clock_timestamp(),'attempt_id',att.id,'attempt_status',att.status,
   'attempt_count',coalesce(cnt.n,0),
   'retake_limit',greatest(1,least(20,coalesce(e.retake_limit,1))),
   'retakes_left',case when coalesce(e.allow_retake,false) then greatest(0,(1+greatest(1,least(20,coalesce(e.retake_limit,1))))-coalesce(cnt.n,0)) else 0 end,
   'can_retake',(coalesce(e.allow_retake,false) and att.status='submitted' and coalesce(cnt.n,0)<(1+greatest(1,least(20,coalesce(e.retake_limit,1)))) and clock_timestamp()<e.closes_at and e.state<>'closed' and coalesce(e.published,false)),
   'teacher_name',coalesce(t.name,''),'teacher_school',coalesce(t.organization,'')
  ) order by e.opens_at,e.title
 ),'[]'::jsonb)
 FROM astroexam.exams e
 JOIN astroexam.profiles t ON t.id=e.teacher_id AND t.role='teacher'
 LEFT JOIN LATERAL (
  SELECT * FROM astroexam.attempts a WHERE a.exam_id=e.id AND a.student_id=p_student
  ORDER BY CASE WHEN a.status='in_progress' THEN 0 ELSE 1 END,a.started_at DESC,a.id DESC LIMIT 1
 ) att ON true
 LEFT JOIN LATERAL (
  SELECT count(*)::int n FROM astroexam.attempts a WHERE a.exam_id=e.id AND a.student_id=p_student
 ) cnt ON true
 WHERE e.state<>'closed' AND coalesce(e.published,false)
   AND (att.id IS NOT NULL OR clock_timestamp()>=e.opens_at)
   AND (
     att.id IS NOT NULL
     OR EXISTS(SELECT 1 FROM astroexam.exam_assignments x WHERE x.exam_id=e.id AND x.student_id=p_student)
     OR EXISTS(SELECT 1 FROM astroexam.exam_assignments x
       JOIN astroexam.class_members m ON m.class_id=x.class_id AND m.student_id=p_student
       WHERE x.exam_id=e.id)
   );
$function$;

-- Keep profiles.created_by safe when the creator teacher is removed.
ALTER TABLE astroexam.profiles DROP CONSTRAINT IF EXISTS profiles_created_by_fkey;
ALTER TABLE astroexam.profiles ADD CONSTRAINT profiles_created_by_fkey
  FOREIGN KEY(created_by) REFERENCES astroexam.profiles(id) ON DELETE SET NULL;

-- Patch the central API dispatcher to use teacher_classes for room access,
-- class_members for independent rosters, and unlink instead of deleting students.
DO $patch$
DECLARE fn text;
BEGIN
  fn:=pg_get_functiondef('astroexam.api_action(text,jsonb,uuid,text)'::regprocedure);
  fn:=replace(fn,'from classes c where c.teacher_id=who.id',
    'from classes c join teacher_classes tc on tc.class_id=c.id and tc.teacher_id=who.id');
  fn:=replace(fn,'from classes c where c.id=(p_data->>''id'')::uuid and c.teacher_id=who.id',
    'from classes c join teacher_classes tc on tc.class_id=c.id and tc.teacher_id=who.id where c.id=(p_data->>''id'')::uuid');
  fn:=replace(fn,'from profiles p join teacher_students ts on ts.student_id=p.id where ts.teacher_id=who.id and ts.active',
    'from profiles p join class_members roster on roster.student_id=p.id and roster.class_id=c.id where p.role=''student''');
  fn:=replace(fn,'not exists(select 1 from classes where id=new_id and teacher_id=who.id and not archived)',
    'not exists(select 1 from classes c join teacher_classes tc on tc.class_id=c.id and tc.teacher_id=who.id where c.id=new_id and not c.archived)');
  fn:=replace(fn,'not exists(select 1 from classes where id=(p_data->>''from_id'')::uuid and teacher_id=who.id and not archived)',
    'not exists(select 1 from classes c join teacher_classes tc on tc.class_id=c.id and tc.teacher_id=who.id where c.id=(p_data->>''from_id'')::uuid and not c.archived)');
  fn:=replace(fn,'not exists(select 1 from classes where id=(p_data->>''to_id'')::uuid and teacher_id=who.id and not archived)',
    'not exists(select 1 from classes c join teacher_classes tc on tc.class_id=c.id and tc.teacher_id=who.id where c.id=(p_data->>''to_id'')::uuid and not c.archived)');
  fn:=replace(fn,'not exists(select 1 from classes where id=(p_data->>''class_id'')::uuid and teacher_id=who.id and not archived)',
    'not exists(select 1 from classes c join teacher_classes tc on tc.class_id=c.id and tc.teacher_id=who.id where c.id=(p_data->>''class_id'')::uuid and not c.archived)');
  fn:=replace(fn,'not exists(select 1 from classes where id=(item->>''class_id'')::uuid and teacher_id=who.id and not archived)',
    'not exists(select 1 from classes c join teacher_classes tc on tc.class_id=c.id and tc.teacher_id=who.id where c.id=(item->>''class_id'')::uuid and not c.archived)');
  fn:=replace(fn,'delete from class_members where class_id=new_id and teacher_id=who.id;',
    'delete from class_members where class_id=new_id;');
  fn:=replace(fn,'perform astroexam.force_hard_delete_student(new_id);',
    'perform astroexam.remove_student_from_teacher(who.id,new_id);');
  fn:=replace(fn,'fc.teacher_id=who.id',
    'exists(select 1 from teacher_classes tc where tc.teacher_id=who.id and tc.class_id=fc.class_id)');
  fn:=replace(fn,'join class_members m on m.class_id=c.id and m.teacher_id=c.teacher_id',
    'join class_members m on m.class_id=c.id');
  fn:=replace(fn,'join teacher_students ts on ts.teacher_id=m.teacher_id and ts.student_id=m.student_id and ts.active','');
  fn:=replace(fn,E'\n         join profiles tp on tp.id=c.teacher_id and tp.role=''teacher''',
    E'\n         left join profiles tp on tp.id=c.teacher_id and tp.role=''teacher''');
  fn:=replace(fn,'join profiles class_owner on class_owner.id=c.teacher_id and class_owner.role=''teacher'' and class_owner.active where m.student_id=p.id and not c.archived and lower(trim(coalesce(class_owner.organization,'''')))=lower(trim(coalesce(who.organization,'''')))',
    'join teacher_classes tcl on tcl.class_id=c.id and tcl.teacher_id=who.id left join profiles class_owner on class_owner.id=c.teacher_id and class_owner.role=''teacher'' where m.student_id=p.id and not c.archived and (class_owner.id is null or lower(trim(coalesce(class_owner.organization,'''')))=lower(trim(coalesce(who.organization,''''))))');
  fn:=replace(fn,
    'insert into classes(id,teacher_id,name,description,archived) values(new_id,who.id',
    'if nullif(p_data->>''id'','''') is not null and not exists(select 1 from classes where id=new_id and teacher_id=who.id) then raise exception ''คุณไม่มีสิทธิ์แก้ไขข้อมูลห้องเรียนนี้''; end if;'||chr(10)||'   insert into classes(id,teacher_id,name,description,archived) values(new_id,who.id');
  fn:=replace(fn,'and cm.teacher_id=who.id','');
  fn:=replace(fn,'join classes c on c.id=cm.class_id and c.teacher_id=cm.teacher_id where cm.teacher_id=new_id and cm.student_id=who.id and not c.archived',
    'join teacher_classes tc on tc.class_id=cm.class_id and tc.teacher_id=new_id join classes c on c.id=cm.class_id where cm.student_id=who.id and not c.archived');
  fn:=replace(fn,'where m.student_id=who.id and c.teacher_id=e.teacher_id',
    'where m.student_id=who.id and exists(select 1 from teacher_classes tc where tc.teacher_id=e.teacher_id and tc.class_id=c.id)');
  EXECUTE fn;
END
$patch$;