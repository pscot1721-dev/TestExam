-- The API dispatcher runs as the non-login ae_runtime role (SECURITY DEFINER).
-- Allow that role to access teacher-class links while keeping direct client
-- access denied by the existing deny policy.
GRANT USAGE ON SCHEMA astroexam TO ae_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE astroexam.teacher_classes TO ae_runtime;

DROP POLICY IF EXISTS teacher_classes_runtime_access ON astroexam.teacher_classes;
CREATE POLICY teacher_classes_runtime_access
ON astroexam.teacher_classes
FOR ALL TO ae_runtime
USING (true)
WITH CHECK (true);