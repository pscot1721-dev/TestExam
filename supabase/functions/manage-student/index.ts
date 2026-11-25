// SmartExam Edge handler. Service role is used only inside Edge Functions, never in frontend.
const url = Deno.env.get('SUPABASE_URL')!;
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const origins = (Deno.env.get('ALLOWED_ORIGINS') || 'https://pscot1721-dev.github.io')
  .split(',')
  .map(x => x.trim());

const management = new Set([
  'staff-login','student-login','students','student-save','student-pin',
  'student-password','student-delete','student-delete-direct','students-import',
  'student-check-by-code','student-link-by-code','student-link-room-by-code',
  'student-remove-from-teacher','student-directory-schools',
  'student-directory-classes','student-directory-import-rooms',
  'classes','class-save','class-get','class-members',
  'class-move','class-delete','admin-overview','admin-teachers','admin-create',
  'admin-save','admin-password','admin-delete','admin-delete-direct'
]);

const teacherActions = new Set([
  'me','logout',...management,'profile-save','staff-own-password','exams',
  'exam-get','exam-save','exam-delete','exam-state','report','report-summary',
  'attempt-report','grade'
]);

const studentActions = new Set([
  'me','logout','student-login','my-attempts','assigned-exams','teacher-public',
  'start','attempt','save','submit','events'
]);

const publicActions = new Set(['staff-login','student-login']);

const serverHeaders = {
  apikey: serviceKey,
  Authorization: `Bearer ${serviceKey}`,
  'Content-Type': 'application/json'
};

async function rpc(action: string, data: unknown, actor: string | null, token: string | null) {
  const res = await fetch(`${url}/rest/v1/rpc/astroexam_api`, {
    method: 'POST',
    headers: serverHeaders,
    body: JSON.stringify({ p_action: action, p_data: data, p_actor: actor, p_token: token }),
    signal: AbortSignal.timeout(20000)
  });
  return { res, out: await res.json() };
}

export function handler(group: 'students' | 'exams') {
  return async (req: Request): Promise<Response> => {
    const origin = req.headers.get('origin') || '';
    const cors: Record<string, string> = {
      'Access-Control-Allow-Origin': origins.includes(origin) ? origin : origins[0],
      'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-student-token, x-staff-token, x-client-info',
      'Access-Control-Allow-Methods': 'POST, OPTIONS',
      'Vary': 'Origin',
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff'
    };
    const reply = (body: unknown, status = 200) => Response.json(body, { status, headers: cors });

    if (origin && !origins.includes(origin)) return reply({ error: 'Origin ไม่ได้รับอนุญาต' }, 403);
    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
    if (req.method !== 'POST') return reply({ error: 'ใช้ POST เท่านั้น' }, 405);

    const requestId = crypto.randomUUID();
    let diagnosticAction = 'parse';

    try {
      const reader = req.body?.getReader();
      if (!reader) return reply({ error: 'ไม่มีข้อมูล' }, 400);
      let size = 0;
      const chunks: Uint8Array[] = [];
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.length;
        if (size > 8_000_000) {
          await reader.cancel();
          return reply({ error: 'ข้อมูลใหญ่เกินกำหนด' }, 413);
        }
        chunks.push(value);
      }

      const bytes = new Uint8Array(size);
      let offset = 0;
      for (const chunk of chunks) {
        bytes.set(chunk, offset);
        offset += chunk.length;
      }

      const body = JSON.parse(new TextDecoder().decode(bytes));
      const action = body.action;
      const data = body.data || {};
      diagnosticAction = typeof action === 'string' ? action.slice(0, 60) : 'invalid';

      if (typeof action !== 'string' || !data || Array.isArray(data) || typeof data !== 'object') {
        return reply({ error: 'รูปแบบข้อมูลไม่ถูกต้อง' }, 400);
      }

      const studentToken = req.headers.get('x-student-token');
      const staffToken = req.headers.get('x-staff-token');
      let actor: string | null = null;

      if (!publicActions.has(action) && !studentToken && !staffToken) {
        const auth = req.headers.get('authorization');
        if (auth?.startsWith('Bearer ')) {
          const verification = await fetch(`${url}/auth/v1/user`, {
            headers: { apikey: serviceKey, Authorization: auth },
            signal: AbortSignal.timeout(15000)
          });
          if (!verification.ok) {
            return reply({ error: 'เซสชันหมดอายุ กรุณาเข้าสู่ระบบใหม่', unauthorized: true }, 401);
          }
          const user = await verification.json();
          actor = user.id || null;
        } else {
          return reply({ error: 'กรุณาเข้าสู่ระบบ', unauthorized: true }, 401);
        }
      }

      const hasStaffIdentity = Boolean(actor || staffToken);
      if (!publicActions.has(action) && !(hasStaffIdentity ? teacherActions : studentActions).has(action)) {
        return reply({ error: 'ไม่มีสิทธิ์ใช้คำสั่ง' }, 403);
      }

      const isManagement = management.has(action);
      if (
        isManagement !== (group === 'students') &&
        !(group === 'students' && action === 'teacher-public')
      ) {
        return reply({ error: 'Endpoint ไม่ถูกต้อง' }, 400);
      }

      const { res, out } = await rpc(action, data, actor, staffToken || studentToken);
      if (!res.ok) {
        const message = out.code === 'P0001'
          ? out.message
          : out.code === '23505'
            ? 'ข้อมูลซ้ำในระบบ ระบบจะใช้ข้อมูลเดิมเมื่อทำได้ กรุณาโหลดหน้าแล้วลองอีกครั้ง'
            : out.message
              ? `ฐานข้อมูลแจ้งว่า: ${out.message}`
              : 'ข้อมูลไม่ถูกต้องหรือฐานข้อมูลยังไม่ได้ติดตั้ง กรุณาตรวจค่าที่กรอกและ migration';
        console.error(JSON.stringify({ requestId, action: diagnosticAction, code: out.code, status: res.status }));
        return reply({ error: message, requestId }, 400);
      }

      return reply(out, out?.unauthorized ? 401 : out?.conflict ? 409 : out?.error ? 400 : 200);
    } catch (error) {
      console.error(JSON.stringify({
        requestId,
        action: diagnosticAction,
        type: error instanceof Error ? error.name : 'unknown'
      }));
      return reply({
        error: 'การเชื่อมต่อขัดข้อง กรุณาโหลดรายการเพื่อตรวจว่าบันทึกสำเร็จแล้วหรือไม่ ก่อนลองอีกครั้ง',
        requestId
      }, 500);
    }
  };
}
