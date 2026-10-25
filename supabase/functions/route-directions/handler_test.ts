import { createRouteHandler, validateRoute } from "./handler.ts";
function assert(value: unknown, message = "Assertion failed"): asserts value {
  if (!value) throw Error(message);
}
const settings = {
  supabaseUrl: "https://project.supabase.co",
  serviceKey: "server-service-secret",
  orsKey: "server-ors-secret",
};
const body = {
  profile: "foot-walking",
  coordinates: [[-88.1, 42], [-88.11, 42.01]],
  alternative_routes: {
    target_count: 2,
    share_factor: 0.7,
    weight_factor: 1.6,
  },
};
const geo = {
  type: "FeatureCollection",
  metadata: { query: { api_key: settings.orsKey } },
  features: [{
    type: "Feature",
    geometry: { type: "LineString", coordinates: body.coordinates },
    properties: { summary: { distance: 1400, duration: 900 }, private: "omit" },
  }],
};
const request = (
  data: unknown = body,
  headers: Record<string, string> = { apikey: "public-project-key" },
) =>
  new Request("https://project.supabase.co/functions/v1/route-directions", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: JSON.stringify(data),
  });
function fixture(
  options: {
    quota?: boolean;
    providerStatus?: number;
    networkFailure?: boolean;
    userStatus?: number;
  } = {},
) {
  let providers = 0, claims = 0, users = 0;
  const handler = createRouteHandler(
    settings,
    (async (input, init) => {
      const url = String(input);
      if (options.networkFailure) {
        throw new DOMException(
          "Timeout",
          "TimeoutError",
        );
      }
      if (url.endsWith("/auth/v1/settings")) return Response.json({});
      if (url.endsWith("/auth/v1/user")) {
        users++;
        return Response.json({ id: "verified-user" }, {
          status: options.userStatus || 200,
        });
      }
      if (url.endsWith("/claim_route_request")) {
        claims++;
        assert(
          new Headers(init?.headers).get("apikey") === settings.serviceKey,
        );
        return Response.json({
          granted: options.quota !== false,
          retry_after: 71,
        });
      }
      assert(url.startsWith("https://api.openrouteservice.org/v2/directions/"));
      assert(
        new Headers(init?.headers).get("Authorization") === settings.orsKey,
      );
      assert(!JSON.stringify(init?.body).includes(settings.serviceKey));
      providers++;
      await new Promise((resolve) => setTimeout(resolve, 3));
      return Response.json(
        options.providerStatus ? { error: "Rate limit exceeded" } : geo,
        {
          status: options.providerStatus || 200,
          headers: { "Retry-After": "90" },
        },
      );
    }) as typeof fetch,
  );
  return { handler, counts: () => ({ providers, claims, users }) };
}
Deno.test("walking/cycling GeoJSON, exact body options and secret redaction", async () => {
  const f = fixture();
  for (const profile of ["foot-walking", "cycling-regular"]) {
    const r = await f.handler(request({ ...body, profile }));
    const text = await r.text();
    assert(r.status === 200);
    assert(!text.includes(settings.orsKey));
    assert(!text.includes(settings.serviceKey));
    assert(!text.includes("private"));
    assert(JSON.parse(text).features[0].properties.summary.distance === 1400);
  }
  assert(f.counts().providers === 2);
});
Deno.test("identical concurrent and cached requests consume one provider request", async () => {
  const f = fixture();
  const responses = await Promise.all(
    Array.from({ length: 20 }, () => f.handler(request())),
  );
  assert(responses.every((r) => r.status === 200));
  assert((await f.handler(request())).status === 200);
  assert(f.counts().claims === 1 && f.counts().providers === 1);
});
Deno.test("ordinary callers cannot supply URLs, keys, unsupported profiles or invalid coordinates", async () => {
  const f = fixture();
  for (
    const data of [
      { ...body, url: "https://evil.test" },
      { ...body, api_key: "client" },
      { ...body, profile: "driving-car" },
      { ...body, coordinates: [[181, 42], [-88, 42]] },
      { ...body, coordinates: [[null, 42], [-88, 42]] },
      { ...body, alternative_routes: { target_count: 100 } },
    ]
  ) {
    assert((await f.handler(request(data))).status === 400);
  }
  assert(f.counts().providers === 0 && f.counts().claims === 0);
});
Deno.test("avoids retain exact coordinates and reject open/invalid/oversized rings", () => {
  const ring = [[-88.1, 42], [-88.101, 42], [-88.1, 42.001], [-88.1, 42]];
  const options = { avoid_polygons: { type: "Polygon", coordinates: [ring] } };
  assert(
    JSON.stringify(validateRoute({ ...body, options }).body.options) ===
      JSON.stringify(options),
  );
  for (
    const coordinates of [[], [ring.slice(0, 3)], [[...ring, [-88.2, 42]]], [[
      [-180, 0],
      [180, 0],
      [180, 1],
      [-180, 0],
    ]]]
  ) {
    let rejected = false;
    try {
      validateRoute({
        ...body,
        options: { avoid_polygons: { type: "Polygon", coordinates } },
      });
    } catch {
      rejected = true;
    }
    assert(rejected);
  }
});
Deno.test("project authentication, signed-in identity and invalid sessions are checked server-side", async () => {
  const f = fixture();
  assert((await f.handler(request(body, {}))).status === 401);
  assert(
    (await f.handler(
      request(body, {
        apikey: "public-project-key",
        authorization: "Bearer session",
      }),
    )).status === 200,
  );
  assert(f.counts().users === 1);
  const revoked = fixture({ userStatus: 401 });
  assert(
    (await revoked.handler(
      request(body, {
        apikey: "public-project-key",
        authorization: "Bearer invalid",
      }),
    )).status === 401,
  );
  assert(revoked.counts().providers === 0);
});
Deno.test("quotas and provider rate limits return bounded retry without a loop", async () => {
  const q = fixture({ quota: false });
  const denied = await q.handler(request());
  assert(denied.status === 429 && denied.headers.get("Retry-After") === "71");
  assert(q.counts().providers === 0);
  const f = fixture({ providerStatus: 429 });
  const r = await f.handler(request());
  assert(r.status === 429 && r.headers.get("Retry-After") === "90");
  assert(f.counts().providers === 1);
});
Deno.test("network failure, missing secret, method and payload guards fail safely", async () => {
  assert(
    (await fixture({ networkFailure: true }).handler(request())).status === 503,
  );
  const missing = createRouteHandler({ ...settings, orsKey: "" });
  assert((await missing(request())).status === 503);
  const f = fixture();
  assert(
    (await f.handler(new Request("https://project.test", { method: "GET" })))
      .status === 405,
  );
  assert(
    (await f.handler(
      new Request("https://project.test", { method: "OPTIONS" }),
    )).status === 200,
  );
  assert(
    (await f.handler(request({ padding: "x".repeat(300001) }))).status === 413,
  );
  assert(f.counts().providers === 0);
});
