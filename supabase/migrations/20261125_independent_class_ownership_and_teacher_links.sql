-- SmartExam: decouple class ownership, membership and teacher access.
-- A class survives deletion of its creator. Teachers receive access through
-- teacher_classes. Class membership is class/student, not teacher/student.
-- Student profiles remain global and are never deleted by class or teacher removal.

BEGIN;

CREATE TABLE IF NOT EXISTS astroexam.teacher_classes (
  teacher_id uuid NOT NULL REFERENCES astroexam.profiles(id) ON DELETE CASCADE,
  class_id uuid NOT NULL REFERENCES astroexam.classes(id) ON DELETE CASCADE,
  linked_at timestamptz NOT NULL DEFAULT now(),
  linked_by uuid NULL REFERENCES astroexam.profiles(id) ON DELETE SET NULL,
  PRIMARY KEY (teacher_id,class_id)
);

ALTER TABLE astroexam.classes ALTER COLUMN teacher_id DROP NOT NULL;
ALTER TABLE astroexam.classes DROP CONSTRAINT IF EXISTS classes_teacher_id_fkey;
ALTER TABLE astroexam.classes
  ADD CONSTRAINT classes_teacher_id_fkey
  FOREIGN KEY (teacher_id) REFERENCES astroexam.profiles(id) ON DELETE SET NULL;

ALTER TABLE astroexam.class_members ALTER COLUMN teacher_id DROP NOT NULL;
ALTER TABLE astroexam.class_members DROP CONSTRAINT IF EXISTS class_members_class_id_teacher_id_fkey;
ALTER TABLE astroexam.class_members DROP CONSTRAINT IF EXISTS class_members_teacher_id_student_id_fkey;
ALTER TABLE astroexam.class_members
  ADD CONSTRAINT class_members_class_id_fkey
  FOREIGN KEY (class_id) REFERENCES astroexam.classes(id) ON DELETE CASCADE;
ALTER TABLE astroexam.class_members
  ADD CONSTRAINT class_members_student_id_fkey
  FOREIGN KEY (student_id) REFERENCES astroexam.profiles(id) ON DELETE CASCADE;
ALTER TABLE astroexam.class_members
  ADD CONSTRAINT class_members_teacher_id_fkey
  FOREIGN KEY (teacher_id) REFERENCES astroexam.profiles(id) ON DELETE SET NULL;

ALTER TABLE astroexam.exam_assignments DROP CONSTRAINT IF EXISTS exam_assignments_class_id_teacher_id_fkey;
ALTER TABLE astroexam.exam_assignments DROP CONSTRAINT IF EXISTS exam_assignments_teacher_id_student_id_fkey;
ALTER TABLE astroexam.exam_assignments
  ADD CONSTRAINT exam_assignments_class_id_fkey
  FOREIGN KEY (class_id) REFERENCES astroexam.classes(id) ON DELETE CASCADE;
ALTER TABLE astroexam.exam_assignments
  ADD CONSTRAINT exam_assignments_student_id_fkey
  FOREIGN KEY (student_id) REFERENCES astroexam.profiles(id) ON DELETE CASCADE;

ALTER TABLE astroexam.profiles DROP CONSTRAINT IF EXISTS profiles_created_by_fkey;
ALTER TABLE astroexam.profiles
  ADD CONSTRAINT profiles_created_by_fkey
  FOREIGN KEY (created_by) REFERENCES astroexam.profiles(id) ON DELETE SET NULL;

ALTER TABLE astroexam.profiles DROP CONSTRAINT IF EXISTS profiles_created_by_fkey;
ALTER TABLE astroexam.profiles
  ADD CONSTRAINT profiles_created_by_fkey
  FOREIGN KEY (created_by) REFERENCES astroexam.profiles(id) ON DELETE SET NULL;

INSERT INTO astroexam.teacher_classes(teacher_id,class_id)
SELECT teacher_id,id FROM astroexam.classes WHERE teacher_id IS NOT NULL
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION astroexam.ensure_class_owner_link()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'astroexam','extensions','pg_temp'
AS $function$
BEGIN
  IF NEW.teacher_id IS NOT NULL THEN
    INSERT INTO astroexam.teacher_classes(teacher_id,class_id)
    VALUES(NEW.teacher_id,NEW.id) ON CONFLICT DO NOTHING;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS ae_class_owner_link ON astroexam.classes;
CREATE TRIGGER ae_class_owner_link
AFTER INSERT OR UPDATE OF teacher_id ON astroexam.classes
FOR EACH ROW EXECUTE FUNCTION astroexam.ensure_class_owner_link();

CREATE INDEX IF NOT EXISTS teacher_classes_class_id_idx ON astroexam.teacher_classes(class_id);
CREATE INDEX IF NOT EXISTS class_members_class_id_idx ON astroexam.class_members(class_id);
CREATE INDEX IF NOT EXISTS class_members_student_id_idx ON astroexam.class_members(student_id);
CREATE INDEX IF NOT EXISTS exam_assignments_class_id_idx ON astroexam.exam_assignments(class_id);
CREATE INDEX IF NOT EXISTS exam_assignments_student_id_idx ON astroexam.exam_assignments(student_id);

COMMENT ON TABLE astroexam.teacher_classes IS
  'Many-to-many access links between teachers and independently owned classrooms.';
COMMENT ON COLUMN astroexam.class_members.teacher_id IS
  'Legacy added-by teacher reference only; not used as classroom ownership or membership scope.';
COMMENT ON COLUMN astroexam.classes.teacher_id IS
  'Original classroom owner; becomes NULL if the owner account is deleted. Classroom remains.';

COMMIT;