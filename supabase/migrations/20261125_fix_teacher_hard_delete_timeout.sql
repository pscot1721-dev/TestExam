-- Optimize the admin teacher hard-delete path without deleting student accounts.
-- The Edge Function and frontend have a 20-second request timeout. The previous
-- implementation deleted data in a per-attempt loop and detached teacher links
-- one row at a time; the unlink trigger hard-deleted orphan students.
-- Replace it with set-based deletes and preserve student profiles/sessions.

CREATE INDEX IF NOT EXISTS teacher_students_teacher_id_idx
  ON astroexam.teacher_students (teacher_id);
CREATE INDEX IF NOT EXISTS class_members_teacher_id_idx
  ON astroexam.class_members (teacher_id);
CREATE INDEX IF NOT EXISTS profiles_created_by_idx
  ON astroexam.profiles (created_by);
CREATE INDEX IF NOT EXISTS profiles_advisor_teacher_id_idx
  ON astroexam.profiles (advisor_teacher_id);
CREATE INDEX IF NOT EXISTS admin_audit_target_id_idx
  ON astroexam.admin_audit (target_id);
CREATE INDEX IF NOT EXISTS admin_audit_actor_id_idx
  ON astroexam.admin_audit (actor_id);

CREATE OR REPLACE FUNCTION astroexam.cleanup_student_after_teacher_unlink()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'astroexam', 'extensions', 'pg_temp'
AS $function$
BEGIN
  -- Controlled teacher hard-delete must preserve the student's account.
  IF current_setting('app.teacher_hard_delete', true) = 'on' THEN
    RETURN OLD;
  END IF;

  PERFORM astroexam.hard_delete_orphan_student(OLD.student_id);
  RETURN OLD;
END;
$function$;

CREATE OR REPLACE FUNCTION astroexam.hard_delete_teacher(p_teacher uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'astroexam', 'extensions', 'pg_temp'
AS $function$
DECLARE
  t_code text;
BEGIN
  IF p_teacher IS NULL THEN
    RETURN;
  END IF;

  SELECT username INTO t_code
  FROM astroexam.profiles
  WHERE id = p_teacher AND role = 'teacher'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ไม่พบบัญชีครู';
  END IF;

  -- Delete only records owned by this teacher.
  DELETE FROM astroexam.security_events se
  USING astroexam.attempts a, astroexam.exams e
  WHERE se.attempt_id = a.id
    AND a.exam_id = e.id
    AND e.teacher_id = p_teacher;

  DELETE FROM astroexam.answers an
  USING astroexam.attempts a, astroexam.exams e
  WHERE an.attempt_id = a.id
    AND a.exam_id = e.id
    AND e.teacher_id = p_teacher;

  DELETE FROM astroexam.attempt_questions aq
  USING astroexam.attempts a, astroexam.exams e
  WHERE aq.attempt_id = a.id
    AND a.exam_id = e.id
    AND e.teacher_id = p_teacher;

  DELETE FROM astroexam.attempts a
  USING astroexam.exams e
  WHERE a.exam_id = e.id
    AND e.teacher_id = p_teacher;

  DELETE FROM astroexam.question_templates qt
  USING astroexam.exams e
  WHERE qt.exam_id = e.id
    AND e.teacher_id = p_teacher;

  DELETE FROM astroexam.exam_assignments
  WHERE teacher_id = p_teacher;

  DELETE FROM astroexam.exams
  WHERE teacher_id = p_teacher;

  DELETE FROM astroexam.class_members
  WHERE teacher_id = p_teacher;

  DELETE FROM astroexam.classes
  WHERE teacher_id = p_teacher;

  -- Retain student accounts, PIN hashes, and active student sessions.
  UPDATE astroexam.profiles
  SET created_by = NULL
  WHERE role = 'student' AND created_by = p_teacher;

  UPDATE astroexam.profiles
  SET advisor_teacher_id = NULL
  WHERE role = 'student' AND advisor_teacher_id = p_teacher;

  UPDATE astroexam.answers
  SET graded_by = NULL
  WHERE graded_by = p_teacher;

  DELETE FROM astroexam.staff_sessions
  WHERE staff_id = p_teacher;

  IF t_code IS NOT NULL THEN
    DELETE FROM astroexam.login_limits
    WHERE key = 'staff:' || lower(t_code);
  END IF;

  IF to_regclass('astroexam.admin_audit') IS NOT NULL THEN
    DELETE FROM astroexam.admin_audit
    WHERE target_id = p_teacher OR actor_id = p_teacher;
  END IF;

  -- This flag bypasses the orphan-student cleanup trigger only for this
  -- transaction. Regular teacher unlink behavior remains unchanged.
  PERFORM set_config('app.teacher_hard_delete', 'on', true);
  DELETE FROM astroexam.teacher_students
  WHERE teacher_id = p_teacher;

  -- Clear any remaining creator reference, without deleting student profiles.
  UPDATE astroexam.profiles
  SET created_by = NULL
  WHERE created_by = p_teacher;

  DELETE FROM astroexam.profiles
  WHERE id = p_teacher AND role = 'teacher';
END;
$function$;