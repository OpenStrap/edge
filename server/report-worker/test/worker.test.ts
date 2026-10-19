import { env, applyD1Migrations } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import worker, { cleanup, LIMITS, type Env } from "../src/index";

const e = env as unknown as Env & { MIGRATIONS: any };
const INSTALL = "123e4567-e89b-42d3-a456-426614174000";

const meta = (o: Record<string, unknown> = {}) => ({
  v: 1, installId: INSTALL, category: "sync", title: "Sync stuck", description: "It hangs",
  appVersion: "0.10.3+72", platform: "ios", osVersion: "19.0", deviceModel: "iPhone15,2",
  hasDatabase: false, hasScreenshot: false, ...o,
});
const blobOf = (size = 200, magic = "OSR1") => {
  const b = new Uint8Array(size);
  b.set(new TextEncoder().encode(magic));
  return b;
};
const b64url = (s: string) =>
  btoa(String.fromCharCode(...new TextEncoder().encode(s))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const metaHeader = (m: unknown) => b64url(typeof m === "string" ? m : JSON.stringify(m));
const req = (headers: Record<string, string>, body: BodyInit | null) =>
  worker.fetch(new Request("https://x/v1/reports", { method: "POST", body, headers }), e);
const post = (m: unknown, blob: Uint8Array | null = blobOf(), extra: Record<string, string> = {}) =>
  req({
    "content-type": "application/octet-stream", "x-report-meta": metaHeader(m),
    ...(blob ? { "content-length": String(blob.length) } : {}), ...extra,
  }, blob as BodyInit | null);
/** A body that arrives in [chunks] pieces and then either ends or errors (client gone). */
const streamOf = (chunks: Uint8Array[], abort = false) =>
  new ReadableStream<Uint8Array>({
    async pull(c) {
      const n = chunks.shift();
      if (n) c.enqueue(n);
      else if (abort) c.error(new Error("client gone"));
      else c.close();
    },
  });
const today = () => "day:" + new Date().toISOString().slice(0, 10);
const stat = async (k: string) => (await e.DB.prepare("SELECT v FROM stats WHERE k=?").bind(k).first<{ v: number }>())?.v ?? 0;
const sumBytes = async () => (await e.DB.prepare("SELECT COALESCE(SUM(blob_bytes),0) b FROM reports").first<any>()).b;
const setStat = (k: string, v: number) => e.DB.prepare("INSERT OR REPLACE INTO stats (k, v) VALUES (?, ?)").bind(k, v).run();
const admin = (path: string, token = "test-admin") =>
  worker.fetch(new Request("https://x" + path, { headers: { authorization: `Bearer ${token}` } }), e);

beforeAll(() => applyD1Migrations(e.DB, e.MIGRATIONS));
beforeEach(async () => {
  await e.DB.exec("DELETE FROM reports");
  await e.DB.exec("DELETE FROM stats");
  await e.DB.exec("INSERT INTO stats (k, v) VALUES ('bytes', 0)");
  const l = await e.BLOBS.list();
  await Promise.all(l.objects.map((o) => e.BLOBS.delete(o.key)));
  delete e.GITHUB_TOKEN; delete e.GITHUB_REPO;
});

describe("POST /v1/reports", () => {
  it("happy path stores blob under logs/ and hashes the token", async () => {
    const r = await post(meta());
    expect(await stat("bytes")).toBe(200);
    expect(await stat(today())).toBe(1);
    expect(r.status).toBe(201);
    const j = (await r.json()) as any;
    expect(j.id).toMatch(/^OS-[0-9A-HJKMNP-TV-Z]{6}$/);
    expect(j.deleteToken).toMatch(/^[0-9a-f]{32}$/);
    expect(Date.parse(j.expiresAt)).toBeGreaterThan(Date.now() + 29 * 864e5);
    expect(await e.BLOBS.head(`logs/${j.id}`)).not.toBeNull();
    const row = await e.DB.prepare("SELECT * FROM reports WHERE id=?").bind(j.id).first<any>();
    expect(row.delete_token_hash).toHaveLength(64);
    expect(row.delete_token_hash).not.toBe(j.deleteToken);
    expect(JSON.stringify(row)).not.toContain(j.deleteToken);
  });

  it("db report goes under db/ and expires in 14 days", async () => {
    const j = (await (await post(meta({ hasDatabase: true }), blobOf(500_000))).json()) as any;
    expect(await e.BLOBS.head(`db/${j.id}`)).not.toBeNull();
    expect(Date.parse(j.expiresAt)).toBeLessThan(Date.now() + 15 * 864e5);
  });

  it("rejects bad input", async () => {
    expect((await post(meta({ category: "bogus" }))).status).toBe(400);
    expect((await post(meta({ title: "x".repeat(121) }))).status).toBe(400);
    expect((await post(meta({ description: "x".repeat(4001) }))).status).toBe(400);
    expect((await post(meta({ installId: "nope" }))).status).toBe(400);
    expect((await post("{not json")).status).toBe(400);
    expect((await post(meta(), null)).status).toBe(411); // no body, no length
    expect((await post(meta({ rawDays: 15 }))).status).toBe(400);
    expect((await post(meta(), blobOf(200, "XXXX"))).status).toBe(400);
    expect((await post(meta(), blobOf(50))).status).toBe(400); // shorter than an empty OSR1 blob
    expect((await post(meta(), blobOf(), { "content-type": "multipart/form-data; boundary=x" })).status).toBe(400);
    expect((await post(meta(), blobOf(), { "x-report-meta": "x".repeat(LIMITS.metaHeader + 1) })).status).toBe(400);
    // Largest valid meta: every char of every field is a 6-byte JSON escape; plus a 3-byte UTF-8 description.
    const big = meta({ title: "\u0001".repeat(120), description: "\u0001".repeat(4000), deviceModel: "\u0001".repeat(64), osVersion: "\u0001".repeat(64) });
    expect(metaHeader(big).length).toBeLessThanOrEqual(LIMITS.metaHeader);
    expect((await post(big)).status).toBe(201);
    expect((await post(meta({ description: "я".repeat(4000) }))).status).toBe(201);
    expect((await req({ "content-type": "application/octet-stream", "content-length": "200" }, blobOf())).status).toBe(400);
  });

  it("keeps rawDays in the stored meta", async () => {
    const j = (await (await post(meta({ hasDatabase: true, rawDays: 7 }))).json()) as any;
    const row = await e.DB.prepare("SELECT meta FROM reports WHERE id=?").bind(j.id).first<any>();
    expect(JSON.parse(row.meta).rawDays).toBe(7);
  });

  it("requires Content-Length and refuses oversized ones before reading the body", async () => {
    const h = { "content-type": "application/octet-stream", "x-report-meta": metaHeader(meta()) };
    expect((await req(h, streamOf([blobOf()]))).status).toBe(411);
    const r = await req({ ...h, "content-length": String(LIMITS.blobDb + 1) }, streamOf([blobOf()]));
    expect(r.status).toBe(413);
    expect(await stat("bytes")).toBe(0);
  });

  it("streams a chunked body into R2 byte-for-byte", async () => {
    const b = blobOf(300_000);
    for (let i = 4; i < b.length; i++) b[i] = i & 255;
    const parts = [b.subarray(0, 2), b.subarray(2, 70_000), b.subarray(70_000)];
    const r = await req({ "content-type": "application/octet-stream", "content-length": String(b.length),
      "x-report-meta": metaHeader(meta({ hasDatabase: true })) }, streamOf(parts));
    expect(r.status).toBe(201);
    const j = (await r.json()) as any;
    const got = new Uint8Array(await (await e.BLOBS.get(`db/${j.id}`))!.arrayBuffer());
    expect(got).toEqual(b);
    expect(await stat("bytes")).toBe(b.length);
  });

  const cleanAfterFailure = async () => {
    expect((await e.BLOBS.list()).objects).toHaveLength(0);
    expect(await e.DB.prepare("SELECT COUNT(*) n FROM reports").first<any>()).toEqual({ n: 0 });
    expect(await stat("bytes")).toBe(0);
  };

  it("rolls back a bad prefix that arrives split across chunks", async () => {
    const b = blobOf(200, "OSRX");
    const r = await req({ "content-type": "application/octet-stream", "content-length": "200",
      "x-report-meta": metaHeader(meta()) }, streamOf([b.subarray(0, 3), b.subarray(3)]));
    expect(r.status).toBe(400);
    expect(await r.json()).toEqual({ error: "bad_blob" });
    await cleanAfterFailure();
  });

  it("rolls back a body shorter or longer than Content-Length, or one the client aborts", async () => {
    const h = (n: number) => ({ "content-type": "application/octet-stream", "content-length": String(n),
      "x-report-meta": metaHeader(meta()) });
    for (const [n, body] of [
      [300, streamOf([blobOf(200)])],
      [200, streamOf([blobOf(200), new Uint8Array(50)])],
      [400, streamOf([blobOf(200)], true)],
    ] as const) {
      const r = await req(h(n), body);
      expect(r.status).toBe(400);
      await cleanAfterFailure();
    }
  });

  it("enforces size limits by hasDatabase", async () => {
    expect((await post(meta(), blobOf(LIMITS.blobNoDb + 1))).status).toBe(413);
    expect((await post(meta({ hasDatabase: true }), blobOf(LIMITS.blobNoDb + 1))).status).toBe(201);
    expect((await post(meta({ hasDatabase: true }), blobOf(LIMITS.blobDb + 1))).status).toBe(413);
  });

  it("rate limits 3 per install per UTC day, per install", async () => {
    for (let i = 0; i < 3; i++) expect((await post(meta())).status).toBe(201);
    expect((await post(meta())).status).toBe(429);
    expect((await post(meta({ installId: "223e4567-e89b-42d3-a456-426614174000" }))).status).toBe(201);
  });

  it("returns 507 storage_full for a DB report over the ceiling, but still accepts logs-only", async () => {
    await e.DB.prepare(
      `INSERT INTO reports (id,install_id,created_at,category,title,description,meta,blob_key,blob_bytes,has_db,delete_token_hash)
       VALUES ('OS-AAAAAA','z',?,'sync','t','d','{}','db/OS-AAAAAA',?,1,'h')`)
      .bind(new Date().toISOString(), LIMITS.ceilingBytes - 100).run();
    await setStat("bytes", LIMITS.ceilingBytes - 100);
    const r = await post(meta({ hasDatabase: true }), blobOf(1000));
    expect(r.status).toBe(507);
    expect(await r.json()).toEqual({ error: "storage_full" });
    expect((await post(meta())).status).toBe(201);
  });

  it("refuses every report above the hard ceiling", async () => {
    await e.DB.prepare(
      `INSERT INTO reports (id,install_id,created_at,category,title,description,meta,blob_key,blob_bytes,has_db,delete_token_hash)
       VALUES ('OS-BBBBBB','z',?,'sync','t','d','{}','logs/OS-BBBBBB',?,0,'h')`)
      .bind(new Date().toISOString(), LIMITS.hardCeilingBytes - 100).run();
    await setStat("bytes", LIMITS.hardCeilingBytes - 100);
    const r = await post(meta(), blobOf(1000));
    expect(r.status).toBe(507);
  });

  it("caps reports per day across all installs", async () => {
    const now = new Date().toISOString();
    const stmt = e.DB.prepare(
      `INSERT INTO reports (id,install_id,created_at,category,title,description,meta,blob_key,blob_bytes,has_db,delete_token_hash)
       VALUES (?,?,?,'sync','t','d','{}','logs/x',0,0,'h')`);
    await e.DB.batch(Array.from({ length: LIMITS.dailyTotal }, (_, i) => stmt.bind(`OS-T${String(i).padStart(5, "0")}`, `i${i}`, now)));
    await setStat(today(), LIMITS.dailyTotal);
    const r = await post(meta({ installId: "323e4567-e89b-42d3-a456-426614174000" }));
    expect(r.status).toBe(429);
  });

  it("creates a GitHub issue when configured, without blob contents; failure still gives 201", async () => {
    e.GITHUB_TOKEN = "t"; e.GITHUB_REPO = "OpenStrap/reports";
    const spy = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      new Response(JSON.stringify({ html_url: "https://github.com/OpenStrap/reports/issues/1" }), { status: 201 }));
    const r = await post(meta());
    expect(r.status).toBe(201);
    const id = ((await r.json()) as any).id;
    const [url, init] = spy.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("https://api.github.com/repos/OpenStrap/reports/issues");
    const body = JSON.parse(init.body as string);
    expect(body.title).toBe(`[${id}] sync: Sync stuck`);
    expect(body.labels).toContain("sync");
    const row = await e.DB.prepare("SELECT github_issue_url u FROM reports WHERE id=?").bind(id).first<any>();
    expect(row.u).toContain("/issues/1");

    spy.mockRejectedValueOnce(new Error("down"));
    expect((await post(meta())).status).toBe(201);
    spy.mockRestore();
  });
});

describe("DELETE /v1/reports/:id", () => {
  const del = (id: string, token?: string) =>
    worker.fetch(new Request(`https://x/v1/reports/${id}`, { method: "DELETE", headers: token ? { "x-delete-token": token } : {} }), e);

  it("wrong token 403, right token 204 removes blob and frees bytes, still counts toward rate limit", async () => {
    const j = (await (await post(meta())).json()) as any;
    expect((await del(j.id, "0".repeat(32))).status).toBe(403);
    expect((await del(j.id)).status).toBe(403);
    expect(await e.BLOBS.head(`logs/${j.id}`)).not.toBeNull();
    expect((await del(j.id, j.deleteToken)).status).toBe(204);
    expect(await e.BLOBS.head(`logs/${j.id}`)).toBeNull();
    expect((await del(j.id, j.deleteToken)).status).toBe(404);
    expect(await sumBytes()).toBe(0);
    expect(await stat("bytes")).toBe(0);
    expect(await stat(today())).toBe(1); // deleting does not free a daily slot
    await post(meta()); await post(meta());
    expect((await post(meta())).status).toBe(429);
  });

  it("unknown id 404", async () => expect((await del("OS-ZZZZZZ", "x")).status).toBe(404));
});

describe("admin + health", () => {
  it("health", async () => {
    const r = await worker.fetch(new Request("https://x/v1/health"), e);
    expect(await r.json()).toEqual({ ok: true });
  });

  it("requires the bearer token", async () => {
    expect((await admin("/v1/admin/reports", "wrong")).status).toBe(401);
    expect((await worker.fetch(new Request("https://x/v1/admin/reports"), e)).status).toBe(401);
    expect((await admin("/v1/admin/reports/OS-AAAAAA/blob", "wrong")).status).toBe(401);
  });

  it("lists metadata and serves raw blob", async () => {
    const j = (await (await post(meta())).json()) as any;
    const list = (await (await admin("/v1/admin/reports?since=2020-01-01T00:00:00Z")).json()) as any;
    expect(list.reports.map((r: any) => r.id)).toContain(j.id);
    expect(list.reports[0].delete_token_hash).toBeUndefined();
    const b = await admin(`/v1/admin/reports/${j.id}/blob`);
    expect(b.status).toBe(200);
    expect(new TextDecoder().decode((await b.arrayBuffer()).slice(0, 4))).toBe("OSR1");
    expect((await admin("/v1/admin/reports/OS-AAAAAA/blob")).status).toBe(404);
    expect((await admin("/v1/admin/reports?since=garbage")).status).toBe(400);
  });
});

describe("admin paging", () => {
  it("does not skip rows that share a created_at", async () => {
    const ts = "2031-01-01T00:00:00.000Z";
    for (const id of ["OS-TIE001", "OS-TIE002"])
      await e.DB.prepare(`INSERT INTO reports (id,install_id,created_at,category,title,description,meta,blob_bytes,has_db,delete_token_hash)
        VALUES (?,?,?,?,?,?,?,?,?,?)`).bind(id, "i", ts, "other", "t", "", "{}", 0, 0, "h").run();
    const page = async (after: string) =>
      ((await (await admin(`/v1/admin/reports?since=${ts}&after_id=${after}`)).json()) as any).reports.map((r: any) => r.id);
    expect(await page("OS-TIE001")).toEqual(["OS-TIE002"]);
    expect(await page("")).toEqual(["OS-TIE001", "OS-TIE002"]);
  });
});

describe("cleanup cron", () => {
  it("expires db blobs at 14d, plain at 30d, rows at 90d, and keeps the bytes total honest", async () => {
    const ago = (d: number) => new Date(Date.now() - d * 864e5).toISOString();
    const ins = async (id: string, days: number, db: number) => {
      const key = `${db ? "db" : "logs"}/${id}`;
      await e.BLOBS.put(key, new Uint8Array(10));
      await e.DB.prepare(`INSERT INTO reports (id,install_id,created_at,category,title,description,meta,blob_key,blob_bytes,has_db,delete_token_hash)
        VALUES (?,?,?,'sync','t','d','{}',?,10,?,'h')`).bind(id, "i", ago(days), key, db).run();
    };
    await setStat("bytes", 40);
    await ins("OS-DB0001", 15, 1);   // expired
    await ins("OS-DB0002", 10, 1);   // kept
    await ins("OS-LG0001", 31, 0);   // expired
    await ins("OS-LG0002", 20, 0);   // kept
    await e.DB.prepare(`INSERT INTO reports (id,install_id,created_at,category,title,description,meta,blob_bytes,has_db,delete_token_hash)
      VALUES ('OS-OLD001','i',?,'sync','t','d','{}',0,0,'h')`).bind(ago(91)).run();
    const r = await cleanup(e);
    expect(r).toEqual({ blobs: 2, rows: 1 });
    expect(await e.BLOBS.head("db/OS-DB0001")).toBeNull();
    expect(await e.BLOBS.head("db/OS-DB0002")).not.toBeNull();
    expect(await e.BLOBS.head("logs/OS-LG0001")).toBeNull();
    expect(await sumBytes()).toBe(20);
    expect(await stat("bytes")).toBe(20);
    expect(await stat("bytes")).toBe(await sumBytes());
  });

  it("drops stale day counters and subtracts bytes of rows deleted at 90d", async () => {
    await setStat("day:2000-01-01", 5);
    await setStat(today(), 7);
    await setStat("bytes", 10);
    await e.DB.prepare(`INSERT INTO reports (id,install_id,created_at,category,title,description,meta,blob_key,blob_bytes,has_db,delete_token_hash)
      VALUES ('OS-OLD002','i',?,'sync','t','d','{}',NULL,10,0,'h')`).bind(new Date(Date.now() - 91 * 864e5).toISOString()).run();
    await cleanup(e);
    expect(await stat("bytes")).toBe(0);
    expect(await stat("day:2000-01-01")).toBe(0);
    expect(await stat(today())).toBe(7);
  });

  it("sweeps rows an upload left without a blob once they are an hour old", async () => {
    await setStat("bytes", 60);
    const ins = (id: string, ageMs: number, bytes: number) => e.DB.prepare(`INSERT INTO reports (id,install_id,created_at,category,title,description,meta,blob_key,blob_bytes,has_db,delete_token_hash)
      VALUES (?,'i',?,'sync','t','d','{}',?,?,1,'h')`).bind(id, new Date(Date.now() - ageMs).toISOString(), `db/${id}`, bytes).run();
    await ins("OS-ORPH01", 2 * 3600e3, 20); // orphan: no blob, old enough
    await ins("OS-KEEP01", 2 * 3600e3, 30); // blob present
    await ins("OS-FRESH1", 60e3, 10); // may still be uploading
    await e.BLOBS.put("db/OS-KEEP01", new Uint8Array(30));
    await cleanup(e);
    const ids = (await e.DB.prepare("SELECT id FROM reports ORDER BY id").all<any>()).results.map((r) => r.id);
    expect(ids).toEqual(["OS-FRESH1", "OS-KEEP01"]);
    expect(await stat("bytes")).toBe(40);
  });

  it("concurrent posts cannot both pass the byte ceiling", async () => {
    await setStat("bytes", LIMITS.hardCeilingBytes - 300);
    const rs = await Promise.all([post(meta({ installId: "423e4567-e89b-42d3-a456-426614174000" })), post(meta({ installId: "523e4567-e89b-42d3-a456-426614174000" }))]);
    expect(rs.map((r) => r.status).sort()).toEqual([201, 507]);
    expect(await stat("bytes")).toBe(LIMITS.hardCeilingBytes - 100);
  });
});
