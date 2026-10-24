import {
  infrastructureFailure,
  infrastructurePayload,
  InfrastructureRequests,
  validInfrastructureCache,
} from "./infrastructure_response.ts";
const area: [number, number, number, number] = [42, -88.12, 42.02, -88.10];
const now = Date.parse("2026-10-24T12:00:00Z");
function assert(ok: unknown, message: string) {
  if (!ok) throw new Error(message);
}

Deno.test("fresh bounded empty payload is successful, with query coverage and expiry", () => {
  const p = infrastructurePayload([], area, now);
  assert(
    p.items.length === 0 && p.coverage === "complete",
    "Empty is a successful complete query",
  );
  assert(
    validInfrastructureCache(
      { payload: p, expires_at: p.expires_at },
      area,
      now,
    ) !== null,
    "Fresh scoped cache is usable",
  );
});
Deno.test("feature budgets report partial query coverage instead of pretending completion", () => {
  const p = infrastructurePayload(
    Array.from({ length: 5001 }, (_, id) => ({ id })),
    area,
    now,
  );
  assert(
    p.items.length === 5000 && p.coverage === "partial",
    "Bounded partial response",
  );
});
Deno.test("expired, wrong-viewport and legacy unscoped payloads never masquerade as valid cache", () => {
  const p = infrastructurePayload([{ id: "sidewalk" }], area, now);
  assert(
    validInfrastructureCache(
      { payload: p, expires_at: p.expires_at },
      area,
      now + 86400001,
    ) === null,
    "Expired data rejected",
  );
  assert(
    validInfrastructureCache({ payload: p, expires_at: p.expires_at }, [
      41,
      -87,
      41.02,
      -86.98,
    ], now) === null,
    "Wrong viewport rejected",
  );
  assert(
    validInfrastructureCache(
      { payload: { items: [] }, expires_at: p.expires_at },
      area,
      now,
    ) === null,
    "Unknown legacy provenance rejected",
  );
  assert(
    validInfrastructureCache(
      { payload: p, expires_at: new Date(now - 1).toISOString() },
      area,
      now,
    ) === null,
    "DB expiry bounds payload expiry",
  );
  assert(
    validInfrastructureCache(
      {
        payload: { ...p, warning: "partial failure" },
        expires_at: p.expires_at,
      },
      area,
      now,
    ) === null,
    "Warning is not a successful cache",
  );
});
Deno.test("nested viewports reuse cache while invented future timestamps are rejected", () => {
  const p = infrastructurePayload([], area, now);
  assert(
    validInfrastructureCache({ payload: p, expires_at: p.expires_at }, [
      42.001,
      -88.119,
      42.019,
      -88.101,
    ], now) !== null,
    "Contained viewport valid",
  );
  assert(
    validInfrastructureCache(
      {
        payload: { ...p, fetched_at: new Date(now + 600000).toISOString() },
        expires_at: p.expires_at,
      },
      area,
      now,
    ) === null,
    "Future timestamp rejected",
  );
});
Deno.test("cooldown, timeout and server errors have explicit failure coverage and bounded Retry-After", () => {
  for (const kind of ["rateLimited", "timeout", "server"]) {
    const p = infrastructureFailure(
      kind,
      "Optional infrastructure unavailable",
      Infinity,
    );
    assert(
      p.failure === kind && p.coverage === "unavailable" &&
        p.warning !== undefined,
      "Not an empty successful query",
    );
    assert(p.retry_after === 60, "Nonfinite retry bounded");
  }
  assert(
    infrastructureFailure("rateLimited", "Busy", 999999).retry_after === 3600,
    "Retry upper bound",
  );
  assert(
    infrastructureFailure("rateLimited", "Busy", -5).retry_after === 1,
    "Retry lower bound",
  );
});
Deno.test("identical concurrent requests share upstream work and responses remain independently serializable", async () => {
  const pool = new InfrastructureRequests();
  let calls = 0;
  const load = async () => {
    calls++;
    await Promise.resolve();
    return infrastructurePayload([], area, now);
  };
  const [a, b] = await Promise.all([
    pool.run("same-cell", load),
    pool.run("same-cell", load),
  ]);
  assert(calls === 1, "Only one upstream request");
  assert(
    JSON.stringify(a) === JSON.stringify(b),
    "Equal independently serializable payloads",
  );
  await pool.run("same-cell", load);
  assert(calls === 2, "Settled work is released");
});
Deno.test("failed shared requests are released for a later retry", async () => {
  const pool = new InfrastructureRequests();
  let calls = 0;
  const fail = async () => {
    calls++;
    throw new Error("timeout");
  };
  const results = await Promise.allSettled([
    pool.run("cell", fail),
    pool.run("cell", fail),
  ]);
  assert(
    calls === 1 && results.every((r) => r.status === "rejected"),
    "Shared failure settles all callers",
  );
  const result = await pool.run(
    "cell",
    async () => infrastructurePayload([], area, now),
  );
  assert(result.items.length === 0, "Can recover after a failure");
});
