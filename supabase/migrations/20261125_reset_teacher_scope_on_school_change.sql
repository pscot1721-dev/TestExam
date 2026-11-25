-- Reset a teacher's classroom scope whenever their school changes.
-- Preserve global student accounts and historical attempts.
CREATE OR REPLACE FUNCTION astroexam.reset_teacher_school_scope_on_org_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'astroexam', 'extensions', 'pg_temp'
AS $function$
DECLARE
  student_row record;
BEGIN
  IF NEW.role <> 'teacher'
     OR OLD.role <> 'teacher'
     OR lower(trim(coalesce(NEW.organization,''))) = lower(trim(coalesce(OLD.organization,''))) THEN
    RETURN NEW;
  END IF;

  FOR student_row IN
    SELECT student_id
    FROM astroexam.teacher_students
    WHERE teacher_id = NEW.id
  LOOP
    PERFORM astroexam.remove_student_from_teacher(NEW.id, student_row.student_id);
  END LOOP;

  DELETE FROM astroexam.classes
  WHERE teacher_id = NEW.id;

  DELETE FROM astroexam.teacher_classes
  WHERE teacher_id = NEW.id;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_reset_teacher_school_scope_on_org_change ON astroexam.profiles;
CREATE TRIGGER trg_reset_teacher_school_scope_on_org_change
AFTER UPDATE OF organization ON astroexam.profiles
FOR EACH ROW
WHEN (
  OLD.role = 'teacher'
  AND NEW.role = 'teacher'
  AND lower(trim(coalesce(OLD.organization,''))) IS DISTINCT FROM lower(trim(coalesce(NEW.organization,'')))
)
EXECUTE FUNCTION astroexam.reset_teacher_school_scope_on_org_change();
