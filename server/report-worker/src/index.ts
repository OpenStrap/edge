export interface Env {
  DB: D1Database;
  BLOBS: R2Bucket;
  ADMIN_TOKEN: string;
  GITHUB_TOKEN?: string;
  GITHUB_REPO?: string;
}

const DAY = 86_400_000;
export const LIMITS = {
  blobNoDb: 5 * 1024 * 1024, // logs alone can pass 2 MB
  blobDb: 95 * 1024 * 1024, // under the 100 MB request-body cap of the Workers free plan
  metaHeader: 36 * 1024, // X-Report-Meta, base64url; worst valid meta (every char a 6-byte JSON escape) is ~35.3 KB
  perInstallPerDay: 3,
  ceilingBytes: 8 * 1024 ** 3, // database attachments refused above this
  hardCeilingBytes: 9 * 1024 ** 3, // every report refused above this: R2 free tier is 10 GB
  dailyTotal: 1000, // all installs together; install ids are client-chosen, so this is the real spam cap
  blobTtlDays: 30,
  dbTtlDays: 14,
  rowTtlDays: 90,
};
const CATEGORIES = ["sync", "sleep", "recovery", "workout", "pairing", "other"];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"; // no I L O U
const MIN_BLOB = 4 + 65 + 12 + 16;

const json = (body: unknown, status = 200, headers: HeadersInit = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });
const err = (status: number, error: string) => json({ error }, status);

const hex = (b: ArrayBuffer | Uint8Array) =>
  [...new Uint8Array(b instanceof Uint8Array ? b : new Uint8Array(b))].map((x) => x.toString(16).padStart(2, "0")).join("");
const sha256 = async (s: string) => new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));

/** Constant-time string compare: compare fixed-length digests, no early exit. */
async function safeEqual(a: string, b: string): Promise<boolean> {
  const [x, y] = await Promise.all([sha256(a), sha256(b)]);
  let d = 0;
  for (let i = 0; i < x.length; i++) d |= x[i] ^ y[i];
  return d === 0;
}

function newId(): string {
  const r = crypto.getRandomValues(new Uint8Array(6));
  return "OS-" + [...r].map((n) => CROCKFORD[n & 31]).join("");
}

export interface Meta {
  v: 1; installId: string; category: string; title: string; description: string;
  appVersion: string; platform: "ios" | "android"; osVersion: string; deviceModel: string;
  hasDatabase: boolean; hasScreenshot: boolean;
  /** Days of second-by-second data in the attached slice (1..14); absent when there is no database. */
  rawDays?: number;
}

/** Returns a normalised Meta or null. Unknown fields are dropped. */
export function validateMeta(raw: unknown): Meta | null {
  if (!raw || typeof raw !== "object") return null;
  const m = raw as Record<string, unknown>;
  const str = (k: string, max: number, min = 0): string | null => {
    const v = m[k];
    return typeof v === "string" && v.length >= min && v.length <= max ? v : null;
  };
  const installId = str("installId", 36, 36);
  const category = str("category", 16, 1);
  const title = str("title", 120, 1)?.trim();
  const description = str("description", 4000);
  const appVersion = str("appVersion", 32, 1);
  const osVersion = str("osVersion", 64);
  const deviceModel = str("deviceModel", 64);
  if (m.v !== 1 || !installId || !UUID.test(installId) || !category || !CATEGORIES.includes(category)) return null;
  if (!title || description === null || !appVersion || osVersion === null || deviceModel === null) return null;
  if (m.platform !== "ios" && m.platform !== "android") return null;
  if (typeof m.hasDatabase !== "boolean" || typeof m.hasScreenshot !== "boolean") return null;
  const rawDays = m.rawDays;
  if (rawDays !== undefined && !(Number.isInteger(rawDays) && (rawDays as number) >= 1 && (rawDays as number) <= 14)) return null;
  return {
    v: 1, installId: installId.toLowerCase(), category, title, description, appVersion,
    platform: m.platform, osVersion, deviceModel, hasDatabase: m.hasDatabase, hasScreenshot: m.hasScreenshot,
    ...(rawDays !== undefined && { rawDays: rawDays as number }),
  };
}

const expiry = (createdIso: string, hasDb: boolean) =>
  new Date(Date.parse(createdIso) + (hasDb ? LIMITS.dbTtlDays : LIMITS.blobTtlDays) * DAY).toISOString();

async function createIssue(env: Env, id: string, m: Meta): Promise<string | null> {
  if (!env.GITHUB_TOKEN || !env.GITHUB_REPO) return null;
  try {
    const body = [
      `**Report:** ${id}`, `**Category:** ${m.category}`,
      `**App:** ${m.appVersion} (${m.platform} ${m.osVersion}, ${m.deviceModel})`,
      `**Database attached:** ${m.hasDatabase ? "yes" : "no"} | **Screenshot:** ${m.hasScreenshot ? "yes" : "no"}`,
      "", m.description || "(no description)",
    ].join("\n");
    const res = await fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/issues`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${env.GITHUB_TOKEN}`, accept: "application/vnd.github+json",
        "user-agent": "openstrap-reports", "content-type": "application/json",
      },
      body: JSON.stringify({ title: `[${id}] ${m.category}: ${m.title}`, body, labels: [m.category, "report"] }),
      signal: AbortSignal.timeout(5000),
    });
    if (!res.ok) return null;
    const j = (await res.json()) as { html_url?: string };
    return typeof j.html_url === "string" ? j.html_url : null;
  } catch {
    return null;
  }
}

/** X-Report-Meta: base64url(JSON). Null when missing, oversized or invalid. */
function decodeMetaHeader(h: string | null): Meta | null {
  if (!h || h.length > LIMITS.metaHeader) return null;
  try {
    const b64 = h.replace(/-/g, "+").replace(/_/g, "/");
    const bin = atob(b64 + "===".slice((b64.length + 3) % 4));
    return validateMeta(JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(Uint8Array.from(bin, (c) => c.charCodeAt(0)))));
  } catch {
    return null;
  }
}

const MAGIC = [0x4f, 0x53, 0x52, 0x31]; // "OSR1"

/**
 * Body = raw OSR1 bytes, never buffered: everything is decided from the headers (Content-Length is the
 * byte count for every cap), then the stream goes straight into R2 through a FixedLengthStream. A wrong
 * prefix or a body that is shorter/longer than Content-Length fails the put and is rolled back.
 */
async function postReport(req: Request, env: Env): Promise<Response> {
  const clHeader = req.headers.get("content-length");
  if (clHeader === null) return err(411, "length_required");
  if (!/^\d{1,12}$/.test(clHeader)) return err(400, "bad_request");
  const cl = Number(clHeader);
  if (cl > LIMITS.blobDb) return err(413, "too_large");
  if ((req.headers.get("content-type") ?? "").toLowerCase().split(";")[0].trim() !== "application/octet-stream")
    return err(400, "bad_request");
  const meta = decodeMetaHeader(req.headers.get("x-report-meta"));
  if (!meta) return err(400, "bad_meta");
  if (cl > (meta.hasDatabase ? LIMITS.blobDb : LIMITS.blobNoDb)) return err(413, "too_large");
  if (cl < MIN_BLOB || !req.body) return err(400, "bad_blob");

  const now = new Date();
  const dayStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate())).toISOString();

  const deleteToken = hex(crypto.getRandomValues(new Uint8Array(16)));
  const tokenHash = hex(await sha256(deleteToken));
  const createdAt = now.toISOString();
  let id = "";
  let key = "";
  for (let i = 0; i < 5; i++) {
    id = newId();
    key = `${meta.hasDatabase ? "db" : "logs"}/${id}`;
    try {
      // One atomic batch: the first statement checks the caps against O(1) counters (stats rows and the
      // (install_id, created_at) index) and inserts; the counter bumps only apply if that insert landed.
      const dayKey = "day:" + dayStart.slice(0, 10);
      const bump = (k: string, n: number) =>
        env.DB.prepare(
          `INSERT INTO stats (k, v) SELECT ?, ? WHERE EXISTS (SELECT 1 FROM reports WHERE id = ?)
           ON CONFLICT (k) DO UPDATE SET v = v + excluded.v`).bind(k, n, id);
      const [ins] = await env.DB.batch([
        env.DB.prepare(
          `INSERT INTO reports (id, install_id, created_at, category, title, description, meta, blob_key, blob_bytes, has_db, delete_token_hash)
           SELECT ?,?,?,?,?,?,?,?,?,?,?
           WHERE (SELECT COUNT(*) FROM reports WHERE install_id = ? AND created_at >= ?) < ?
             AND COALESCE((SELECT v FROM stats WHERE k = ?), 0) < ?
             AND COALESCE((SELECT v FROM stats WHERE k = 'bytes'), 0) + ? <= ?`)
          .bind(id, meta.installId, createdAt, meta.category, meta.title, meta.description, JSON.stringify(meta),
            key, cl, meta.hasDatabase ? 1 : 0, tokenHash,
            meta.installId, dayStart, LIMITS.perInstallPerDay,
            dayKey, LIMITS.dailyTotal,
            cl, meta.hasDatabase ? LIMITS.ceilingBytes : LIMITS.hardCeilingBytes),
        bump("bytes", cl),
        bump(dayKey, 1),
      ]);
      if (!ins.meta.changes) {
        const used = await env.DB.prepare(
          "SELECT (SELECT COUNT(*) FROM reports WHERE install_id = ? AND created_at >= ?) AS mine, COALESCE((SELECT v FROM stats WHERE k = ?), 0) AS all_")
          .bind(meta.installId, dayStart, dayKey).first<{ mine: number; all_: number }>();
        return (used?.mine ?? 0) >= LIMITS.perInstallPerDay || (used?.all_ ?? 0) >= LIMITS.dailyTotal
          ? err(429, "rate_limited") : err(507, "storage_full");
      }
      break;
    } catch (e) {
      if (i === 4 || !/UNIQUE|constraint/i.test(String(e))) throw e; // id collision: retry
    }
  }
  let seen = 0; // prefix bytes checked so far
  let received = 0;
  let badPrefix = false;
  const check = new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, c) {
      for (let i = 0; seen < 4 && i < chunk.length; i++) {
        if (chunk[i] !== MAGIC[seen]) { badPrefix = true; c.error(new Error("bad_prefix")); return; }
        seen++;
      }
      received += chunk.length;
      c.enqueue(chunk);
    },
  });
  const fixed = new FixedLengthStream(cl);
  const [put, pipe] = await Promise.allSettled([
    env.BLOBS.put(key, fixed.readable),
    req.body.pipeThrough(check).pipeTo(fixed.writable),
  ]);
  if (put.status === "rejected" || pipe.status === "rejected") {
    // Undo the insert and its byte count; the day counter keeps the attempt (conservative).
    await env.BLOBS.delete(key).catch(() => {});
    await env.DB.batch([
      env.DB.prepare("UPDATE stats SET v = v - (SELECT blob_bytes FROM reports WHERE id = ?) WHERE k = 'bytes'").bind(id),
      env.DB.prepare("DELETE FROM reports WHERE id = ?").bind(id),
    ]);
    if (badPrefix) return err(400, "bad_blob");
    if (received !== cl) return err(400, "length_mismatch"); // client aborted or lied about the length
    throw put.status === "rejected" ? put.reason : (pipe as PromiseRejectedResult).reason;
  }

  const url = await createIssue(env, id, meta);
  if (url) await env.DB.prepare("UPDATE reports SET github_issue_url = ? WHERE id = ?").bind(url, id).run();
  return json({ id, deleteToken, expiresAt: expiry(createdAt, meta.hasDatabase) }, 201);
}

async function deleteReport(req: Request, env: Env, id: string): Promise<Response> {
  const token = req.headers.get("x-delete-token") ?? "";
  const row = await env.DB.prepare("SELECT delete_token_hash, blob_key FROM reports WHERE id = ?")
    .bind(id).first<{ delete_token_hash: string; blob_key: string | null }>();
  if (!row || !row.delete_token_hash) return err(404, "not_found");
  if (!(await safeEqual(hex(await sha256(token)), row.delete_token_hash))) return err(403, "forbidden");
  if (row.blob_key) await env.BLOBS.delete(row.blob_key);
  // Scrub but keep the row so the per-day rate limit still counts it; the cron removes it at 90 days.
  // Stats first: it reads the row's blob_bytes before the scrub zeroes it (a repeat delete subtracts 0).
  await env.DB.batch([
    env.DB.prepare("UPDATE stats SET v = v - (SELECT blob_bytes FROM reports WHERE id = ?) WHERE k = 'bytes'").bind(id),
    env.DB.prepare(
      `UPDATE reports SET blob_key=NULL, blob_bytes=0, title='', description='', meta='{}', delete_token_hash='' WHERE id = ?`)
      .bind(id),
  ]);
  return new Response(null, { status: 204 });
}

async function admin(req: Request, env: Env, url: URL): Promise<Response> {
  const auth = req.headers.get("authorization") ?? "";
  if (!env.ADMIN_TOKEN || !(await safeEqual(auth, `Bearer ${env.ADMIN_TOKEN}`))) return err(401, "unauthorized");
  const m = url.pathname.match(/^\/v1\/admin\/reports\/(OS-[0-9A-Z]{6})\/blob$/);
  if (m) {
    const row = await env.DB.prepare("SELECT blob_key FROM reports WHERE id = ?").bind(m[1]).first<{ blob_key: string | null }>();
    const obj = row?.blob_key ? await env.BLOBS.get(row.blob_key) : null;
    if (!obj) return err(404, "not_found");
    return new Response(obj.body, { headers: { "content-type": "application/octet-stream" } });
  }
  if (url.pathname === "/v1/admin/reports") {
    const since = url.searchParams.get("since");
    if (since && Number.isNaN(Date.parse(since))) return err(400, "bad_since");
    // Tie-safe paging: pass the last row's created_at as `since` and its id as `after_id`.
    const afterId = url.searchParams.get("after_id") ?? "";
    const sinceIso = since ? new Date(since).toISOString() : "";
    const { results } = await env.DB.prepare(
      `SELECT id, install_id, created_at, category, title, description, meta, blob_key, blob_bytes, has_db, github_issue_url
       FROM reports WHERE title != '' AND (created_at > ? OR (created_at = ? AND id > ?))
       ORDER BY created_at, id LIMIT 1000`)
      .bind(sinceIso, sinceIso, afterId).all();
    return json({ reports: results });
  }
  return err(404, "not_found");
}

export async function cleanup(env: Env, now = new Date()): Promise<{ blobs: number; rows: number }> {
  const cut = (days: number) => new Date(now.getTime() - days * DAY).toISOString();
  const { results } = await env.DB.prepare(
    `SELECT id, blob_key FROM reports WHERE blob_key IS NOT NULL AND
       ((has_db = 1 AND created_at < ?) OR (has_db = 0 AND created_at < ?))`)
    .bind(cut(LIMITS.dbTtlDays), cut(LIMITS.blobTtlDays)).all<{ id: string; blob_key: string }>();
  for (const r of results) {
    await env.BLOBS.delete(r.blob_key);
    await env.DB.batch([
      env.DB.prepare("UPDATE stats SET v = v - (SELECT blob_bytes FROM reports WHERE id = ?) WHERE k = 'bytes'").bind(r.id),
      env.DB.prepare("UPDATE reports SET blob_key=NULL, blob_bytes=0 WHERE id = ?").bind(r.id),
    ]);
  }
  // Rows past retention should already be blob-free; subtract any stragglers so the counter cannot drift.
  const [, rows] = await env.DB.batch([
    env.DB.prepare("UPDATE stats SET v = v - COALESCE((SELECT SUM(blob_bytes) FROM reports WHERE created_at < ?), 0) WHERE k = 'bytes'").bind(cut(LIMITS.rowTtlDays)),
    env.DB.prepare("DELETE FROM reports WHERE created_at < ?").bind(cut(LIMITS.rowTtlDays)),
    env.DB.prepare("DELETE FROM stats WHERE k LIKE 'day:%' AND k < ?").bind("day:" + cut(2).slice(0, 10)),
  ]);
  return { blobs: results.length, rows: rows.meta.changes ?? 0 };
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const p = url.pathname;
    try {
      if (p === "/v1/health" && req.method === "GET") return json({ ok: true });
      if (p === "/v1/reports" && req.method === "POST") return await postReport(req, env);
      const d = p.match(/^\/v1\/reports\/(OS-[0-9A-Z]{6})$/);
      if (d && req.method === "DELETE") return await deleteReport(req, env, d[1]);
      if (p.startsWith("/v1/admin/") && req.method === "GET") return await admin(req, env, url);
      return err(404, "not_found");
    } catch (e) {
      console.error("report-worker", String(e));
      return err(500, "internal");
    }
  },
  async scheduled(_e: ScheduledController, env: Env, ctx: ExecutionContext) {
    ctx.waitUntil(cleanup(env));
  },
};
