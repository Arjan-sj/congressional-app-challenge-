import { createCommunityHandler } from "./handler.ts";
function assert(value: unknown, message = "Assertion failed"): asserts value {
  if (!value) throw Error(message);
}
const id = "96000000-0000-0000-0000-000000000001",
  visitor = "a".repeat(43),
  url = "https://project.test",
  secret = "synthetic-service-only";
const report = {
  id,
  latitude: 44,
  longitude: -90,
  type: "blocked_path",
  severity: 3,
  description: "Observed a blocked public path",
};
const photo = {
  base64: btoa(
    String.fromCharCode(137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0),
  ),
};
const make = (body: unknown, ip = "203.0.113.10") =>
  new Request(url, {
    method: "POST",
    headers: {
      apikey: "project-key",
      "Content-Type": "application/json",
      ...(ip ? { "x-forwarded-for": ip } : {}),
    },
    body: JSON.stringify(body),
  });
function fixture(
  {
    quota = false,
    fail = false,
    timeout = false,
    signedFail = false,
    existingPhoto = "",
  } = {},
) {
  const calls: { url: string; method: string; body: any; headers: Headers }[] =
    [];
  let path = "";
  const handler = createCommunityHandler(
    { url, key: secret },
    (async (target, opts) => {
      const u = String(target),
        method = opts?.method ?? "GET",
        headers = new Headers(opts?.headers);
      const body = typeof opts?.body === "string"
        ? JSON.parse(opts.body)
        : opts?.body;
      calls.push({ url: u, method, headers, body });
      if (u.endsWith("/settings")) return Response.json({});
      assert(
        headers.get("apikey") === secret,
        "Only server requests use service key",
      );
      if (u.endsWith("/community_action")) {
        assert(/^[a-f0-9]{64}$/.test(body.p_participant_hash));
        assert(!JSON.stringify(body).includes(visitor));
        assert(!JSON.stringify(body).includes("203.0.113"));
        if (body.p_action === "prepare") {
          return quota
            ? Response.json({
              code: "P0429",
              message: "Contribution limit reached. Try again later.",
            }, { status: 400 })
            : Response.json({ allowed: true });
        }
        if (timeout) throw Error("Synthetic request receipt timeout");
        if (fail) {
          return Response.json({
            code: "23514",
            message: "Private SQL detail and private identifier",
          }, { status: 400 });
        }
        return Response.json({
          report: {
            ...report,
            school_id: "computer-selected-school",
            status: "unverified",
            created_at: "2026-10-25T00:00:00Z",
          },
          counts: { review_round: 0, verified: 1, flags: 0 },
          photo_path: existingPhoto || path,
          can_review: true,
          changed: false,
        });
      }
      if (u.includes("/object/sign/")) {
        if (signedFail) throw Error("Synthetic signing outage");
        return Response.json({
          signedURL: "/object/sign/hazard-photos/" + path + "?token=synthetic",
        });
      }
      if (method === "DELETE") return Response.json({});
      assert(u.includes("/object/hazard-photos/"));
      path = u.split("/object/hazard-photos/")[1];
      return Response.json({});
    }) as typeof fetch,
  );
  return { handler, calls };
}
Deno.test("anonymous submission forwards only validated fields and private hashes, never client authority", async () => {
  const f = fixture();
  const response = await f.handler(
    make({
      action: "submit",
      visitor,
      report: {
        ...report,
        school_id: "malicious-school",
        status: "verified",
        reporter_id: "forged",
        is_demo: true,
      },
    }),
  );
  assert(response.status === 200);
  const payload =
    f.calls.filter((x) => x.body?.p_action === "submit")[0].body.p_payload;
  assert(
    !("school_id" in payload) && !("status" in payload) &&
      !("reporter_id" in payload) && !("is_demo" in payload),
  );
  assert(
    (await response.json()).report.school_id === "computer-selected-school",
  );
  assert(response.headers.get("Cache-Control") === "no-store");
});
Deno.test("only the nearest gateway forwarding address counts; IPv6 aliases normalize", async () => {
  const a = fixture(), b = fixture();
  await a.handler(
    make(
      { action: "summary", visitor, report: { id } },
      "198.51.100.1, 203.0.113.10",
    ),
  );
  await b.handler(
    make(
      { action: "summary", visitor, report: { id } },
      "198.51.100.200, 203.0.113.10",
    ),
  );
  const hash = (f: ReturnType<typeof fixture>) =>
    f.calls.find((x) => x.body?.p_action === "summary")!.body.p_network_hash;
  assert(hash(a) === hash(b));
  const c = fixture(), d = fixture();
  await c.handler(
    make(
      { action: "summary", visitor, report: { id } },
      "2001:db8:0:0:0:0:0:1",
    ),
  );
  await d.handler(
    make({ action: "summary", visitor, report: { id } }, "2001:db8::1"),
  );
  assert(hash(c) === hash(d));
  assert(
    (await d.handler(
      make({ action: "summary", visitor, report: { id } }, "999.1.2.3"),
    )).status === 503,
  );
});
Deno.test("quota is checked before any photo Storage write", async () => {
  const f = fixture({ quota: true });
  const response = await f.handler(
    make({ action: "submit", visitor, report, photo }),
  );
  assert(response.status === 429);
  assert(!f.calls.some((c) => c.url.includes("/storage/")));
});
Deno.test("photo evidence uses supported Storage API, canonical metadata and signed URLs", async () => {
  const f = fixture();
  const response = await f.handler(
    make({ action: "submit", visitor, report, photo }),
  );
  assert(response.status === 200);
  const data = await response.json();
  assert(data.photo_url.startsWith(url + "/storage/v1/object/sign/"));
  const upload = f.calls.find((c) =>
    c.method === "POST" && c.url.includes("/object/hazard-photos/")
  )!;
  assert(upload.headers.get("Content-Type") === "image/png");
  assert(upload.headers.get("x-upsert") === "false");
});
Deno.test("failed database validation removes only this attempted upload through Storage API", async () => {
  const f = fixture({ fail: true });
  const response = await f.handler(
    make({ action: "submit", visitor, report, photo }),
  );
  assert(response.status === 400);
  assert(!(await response.text()).includes("Private SQL"));
  const deleted = f.calls.find((c) => c.method === "DELETE")!;
  assert(
    deleted.body.prefixes.length === 1 &&
      deleted.body.prefixes[0].startsWith(id + "/"),
  );
});
Deno.test("unknown commit receipt preserves photo evidence for safe idempotent retry", async () => {
  const f = fixture({ timeout: true });
  const response = await f.handler(
    make({ action: "submit", visitor, report, photo }),
  );
  assert(response.status === 503);
  assert((await response.text()).includes("Retry the same report"));
  assert(!f.calls.some((c) => c.method === "DELETE"));
});
Deno.test("repeated submission cleans only the redundant new object, signing failure does not undo saved report", async () => {
  const f = fixture({ existingPhoto: id + "/1.png", signedFail: true });
  const response = await f.handler(
    make({ action: "submit", visitor, report, photo }),
  );
  assert(response.status === 200);
  const deleted = f.calls.find((c) => c.method === "DELETE")!;
  assert(deleted.body.prefixes[0] !== id + "/1.png");
});
Deno.test("review carries expected round/status and cannot forge totals or immediate status changes", async () => {
  const f = fixture();
  const response = await f.handler(
    make({
      action: "review",
      visitor,
      report: {
        id,
        review_round: 0,
        expected_status: "unverified",
        choice: "verified",
        reason: "I observed the same concern",
        verified: 100,
        changed: true,
      },
    }),
  );
  assert(response.status === 200);
  const p = f.calls.find((c) => c.body?.p_action === "review")!.body.p_payload;
  assert(p.review_round === 0 && !("verified" in p) && !("changed" in p));
  assert((await response.json()).changed === false);
});
Deno.test("missing network metadata, invalid input, oversized photo and unsupported actions fail closed", async () => {
  const f = fixture();
  assert(
    (await f.handler(make({ action: "submit", visitor, report }, "")))
      .status === 503,
  );
  assert(
    (await f.handler(make({ action: "grant", visitor, report }))).status ===
      400,
  );
  assert(
    (await f.handler(
      make({ action: "submit", visitor, report: { ...report, latitude: 91 } }),
    )).status === 400,
  );
  assert(
    (await f.handler(
      make({
        action: "submit",
        visitor,
        report,
        photo: { base64: btoa("not an image") },
      }),
    )).status === 400,
  );
  assert((await f.handler(new Request(url))).status === 405);
  assert(
    (await f.handler(new Request(url, { method: "OPTIONS" }))).status === 200,
  );
  const raw = new Request(url, {
    method: "POST",
    headers: { "content-length": "8000000" },
    body: "{}",
  });
  assert((await f.handler(raw)).status === 413);
});
