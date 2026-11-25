-- Shared classroom deletion and roster edits must be scoped to the acting teacher.
-- A teacher may only remove memberships they added; another teacher's roster rows stay intact.
-- Deleting a classroom that is still shared detaches the deleting owner and transfers ownership.
CREATE OR REPLACE FUNCTION astroexam.safe_delete_class_for_teacher(p_teacher uuid, p_class uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'astroexam','extensions','pg_temp'
AS $function$
DECLARE next_owner uuid; removed_count integer := 0;
BEGIN
 IF NOT EXISTS (SELECT 1 FROM astroexam.profiles WHERE id=p_teacher AND role='teacher' AND active)
 THEN RAISE EXCEPTION 'บัญชีครูไม่ถูกต้อง'; END IF;
 IF NOT EXISTS (SELECT 1 FROM astroexam.classes WHERE id=p_class AND teacher_id=p_teacher)
 THEN RAISE EXCEPTION 'คุณไม่มีสิทธิ์ลบห้องเรียนนี้'; END IF;
 SELECT count(*)::int INTO removed_count FROM astroexam.class_members WHERE class_id=p_class;
 SELECT tc.teacher_id INTO next_owner
 FROM astroexam.teacher_classes tc
 JOIN astroexam.profiles p ON p.id=tc.teacher_id AND p.role='teacher' AND p.active
 WHERE tc.class_id=p_class AND tc.teacher_id<>p_teacher
 ORDER BY tc.linked_at NULLS LAST, tc.teacher_id LIMIT 1;
 IF next_owner IS NOT NULL THEN
   DELETE FROM astroexam.teacher_classes WHERE teacher_id=p_teacher AND class_id=p_class;
   UPDATE astroexam.classes SET teacher_id=next_owner WHERE id=p_class AND teacher_id=p_teacher;
   INSERT INTO astroexam.teacher_classes(teacher_id,class_id,linked_by)
   VALUES(next_owner,p_class,next_owner) ON CONFLICT(teacher_id,class_id) DO NOTHING;
   RETURN jsonb_build_object('ok',true,'scope','teacher_unlinked_shared_class','class_preserved',true,'new_owner',next_owner,'memberships_preserved',removed_count);
 END IF;
 DELETE FROM astroexam.classes WHERE id=p_class AND teacher_id=p_teacher;
 RETURN jsonb_build_object('ok',true,'scope','class_only','removed_memberships',removed_count,'students_deleted',0);
END;
$function$;

DO $patch$
DECLARE d text;
BEGIN
 d:=pg_get_functiondef('astroexam.api_action(text,jsonb,uuid,text)'::regprocedure);
 d:=replace(d,'delete from class_members where class_id=new_id;','delete from class_members where class_id=new_id and teacher_id=who.id;');
 d:=replace(d,'delete from class_members where class_id=(p_data->>''from_id'')::uuid and student_id=(p_data->>''student_id'')::uuid;','delete from class_members where class_id=(p_data->>''from_id'')::uuid and student_id=(p_data->>''student_id'')::uuid and teacher_id=who.id;');
 EXECUTE d;
END;
$patch$;
