-- SmartExam full data reset after schema migration and verified pre-reset snapshot.
-- Keep the single administrator profile and all Auth users so admin login remains recoverable.
-- Remove all business data and student accounts. Schema, functions, and backups remain.

BEGIN;

DELETE FROM astroexam.security_events;
DELETE FROM astroexam.answers;
DELETE FROM astroexam.attempt_questions;
DELETE FROM astroexam.attempts;
DELETE FROM astroexam.exam_assignments;
DELETE FROM astroexam.question_templates;
DELETE FROM astroexam.exams;

DELETE FROM astroexam.class_members;
DELETE FROM astroexam.teacher_classes;
DELETE FROM astroexam.teacher_students;
DELETE FROM astroexam.classes;

DELETE FROM astroexam.student_sessions;
DELETE FROM astroexam.staff_sessions;
DELETE FROM astroexam.login_limits;
DELETE FROM astroexam.admin_audit;

DELETE FROM astroexam.profiles WHERE role='student';
DELETE FROM astroexam.profiles WHERE role='teacher';

COMMIT;