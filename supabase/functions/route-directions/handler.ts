type Fetch = typeof fetch;
type Settings = { supabaseUrl: string; serviceKey: string; orsKey: string };
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
};
const profiles = new Set(["foot-walking", "cycling-regular"]);
function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
function point(value: unknown): value is number[] {
  return Array.isArray(value) && value.length === 2 &&
    value.every((v) => typeof v === "number" && Number.isFinite(v)) &&
    Math.abs(value[0]) <= 180 && Math.abs(value[1]) <= 85;
}

export function validateRoute(value: unknown) {
  if (
    !object(value) || !profiles.has(String(value.profile)) ||
    Object.keys(value).some((k) =>
      !["profile", "coordinates", "alternative_routes", "options"].includes(k)
    ) ||
    !Array.isArray(value.coordinates) || value.coordinates.length !== 2 ||
    !value.coordinates.every(point)
  ) throw new Error("Invalid route request");
  const body: Record<string, unknown> = {
    coordinates: value.coordinates,
    alternative_routes: {
      target_count: 2,
      share_factor: 0.7,
      weight_factor: 1.6,
    },
  };
  if (value.alternative_routes !== undefined) {
    const a = value.alternative_routes;
    if (
      !object(a) || a.target_count !== 2 || a.share_factor !== 0.7 ||
      a.weight_factor !== 1.6 ||
      Object.keys(a).length !== 3
    ) throw new Error("Invalid alternatives");
  }
  if (value.options !== undefined) {
    const options = value.options;
    if (
      !object(options) || Object.keys(options).length !== 1 ||
      !object(options.avoid_polygons)
    ) {
      throw new Error("Invalid avoidance options");
    }
    const geometry = options.avoid_polygons;
    if (
      !["Polygon", "MultiPolygon"].includes(String(geometry.type)) ||
      !Array.isArray(geometry.coordinates) || Object.keys(geometry).some((k) =>
        !["type", "coordinates"].includes(k)
      )
    ) {
      throw new Error("Invalid avoidance geometry");
    }
    const polygons = geometry.type === "Polygon"
      ? [geometry.coordinates]
      : geometry.coordinates;
    let vertices = 0;
    const all: number[][] = [];
    if (!polygons.length || polygons.length > 200) {
      throw new Error("Too many avoidance areas");
    }
    for (const polygon of polygons) {
      if (!Array.isArray(polygon) || polygon.length !== 1) {
        throw new Error("Invalid avoidance ring");
      }
      const ring = polygon[0];
      if (
        !Array.isArray(ring) || ring.length < 4 || ring.length > 128 ||
        !ring.every(point) ||
        ring[0][0] !== ring.at(-1)![0] || ring[0][1] !== ring.at(-1)![1]
      ) throw new Error("Invalid closed avoidance ring");
      vertices += ring.length;
      if (vertices > 5000) throw new Error("Avoidance request too complex");
      all.push(...ring);
    }
    const latitudes = all.map((p) => p[1]), longitudes = all.map((p) => p[0]);
    const north = Math.max(...latitudes), south = Math.min(...latitudes);
    if (
      (north - south) * 111320 > 20000 ||
      (Math.max(...longitudes) - Math.min(...longitudes)) * 111320 *
            Math.cos((north + south) * Math.PI / 360) > 20000
    ) {
      throw new Error("Avoidance area too broad");
    }
    body.options = { avoid_polygons: geometry };
  }
  return { profile: String(value.profile), body };
}

async function digest(value: string) {
  return Array.from(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)),
    ),
  )
    .map((v) => v.toString(16).padStart(2, "0")).join("");
}

/** Only memory caches: route geometry is never persisted in the shared database. */
export function createRouteHandler(
  settings: Settings,
  transport: Fetch = fetch,
) {
  const cache = new Map<string, { expires: number; body: string }>();
  const pending = new Map<string, Promise<Response>>();
  const reply = (status: number, message: string, retry?: number) =>
    new Response(JSON.stringify({ error: message }), {
      status,
      headers: { ...cors, ...(retry ? { "Retry-After": String(retry) } : {}) },
    });
  return async (request: Request): Promise<Response> => {
    if (request.method === "OPTIONS") {
      return new Response("ok", { headers: cors });
    }
    if (request.method !== "POST") return reply(405, "POST required");
    if (!settings.orsKey || !settings.serviceKey || !settings.supabaseUrl) {
      return reply(503, "Route service unavailable");
    }
    try {
      if (Number(request.headers.get("content-length") || 0) > 300000) {
        return reply(413, "Route request too large");
      }
      // Bound streamed input as well: Content-Length is client supplied.
      const reader = request.body?.getReader();
      if (!reader) return reply(400, "Route request required");
      let size = 0;
      const chunks: Uint8Array[] = [];
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.length;
        if (size > 300000) {
          await reader.cancel();
          return reply(413, "Route request too large");
        }
        chunks.push(value);
      }
      const bytes = new Uint8Array(size);
      let offset = 0;
      for (const chunk of chunks) {
        bytes.set(chunk, offset);
        offset += chunk.length;
      }
      let route: ReturnType<typeof validateRoute>;
      try {
        route = validateRoute(JSON.parse(new TextDecoder().decode(bytes)));
      } catch {
        return reply(400, "Invalid route coordinates or avoidance options");
      }
      const apiKey = request.headers.get("apikey");
      if (!apiKey || apiKey.length > 2048) {
        return reply(401, "Project key required");
      }
      const verified = await transport(
        `${settings.supabaseUrl}/auth/v1/settings`,
        { headers: { apikey: apiKey }, signal: AbortSignal.timeout(4000) },
      );
      if (!verified.ok) return reply(401, "Invalid project key");
      let actor = "ip:" +
        (request.headers.get("x-forwarded-for")?.split(",")[0].trim() ||
          "anonymous");
      const auth = request.headers.get("authorization");
      if (auth && auth !== `Bearer ${apiKey}`) {
        const user = await transport(`${settings.supabaseUrl}/auth/v1/user`, {
          headers: { apikey: apiKey, Authorization: auth },
          signal: AbortSignal.timeout(4000),
        });
        if (!user.ok) return reply(401, "Session could not be verified");
        const identity = await user.json();
        if (typeof identity.id !== "string") {
          return reply(401, "Session could not be verified");
        }
        actor = "user:" + identity.id;
      }
      const actorHash = await digest(actor);
      // Exact body + actor scope prevents sharing report-derived routes across users.
      const key = await digest(
        actorHash + route.profile + JSON.stringify(route.body),
      );
      const hit = cache.get(key);
      if (hit && hit.expires > Date.now()) {
        return new Response(hit.body, { headers: cors });
      }
      const current = pending.get(key);
      if (current) return (await current).clone();
      const load = async () => {
        const claim = await transport(
          `${settings.supabaseUrl}/rest/v1/rpc/claim_route_request`,
          {
            method: "POST",
            headers: {
              apikey: settings.serviceKey,
              Authorization: `Bearer ${settings.serviceKey}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ p_actor_hash: actorHash }),
            signal: AbortSignal.timeout(3000),
          },
        );
        if (!claim.ok) return reply(503, "Route service unavailable");
        const quota = await claim.json();
        if (quota.granted !== true) {
          return reply(
            429,
            "Route requests are cooling down",
            Math.max(1, Math.min(86400, Number(quota.retry_after) || 60)),
          );
        }
        const upstream = await transport(
          `https://api.openrouteservice.org/v2/directions/${route.profile}/geojson`,
          {
            method: "POST",
            headers: {
              Authorization: settings.orsKey,
              "Content-Type": "application/json",
              "Accept": "application/geo+json",
            },
            body: JSON.stringify(route.body),
            signal: AbortSignal.timeout(18000),
          },
        );
        if (!upstream.ok) {
          const providerMessage = upstream.status === 403
            ? (await upstream.text()).slice(0, 2048)
            : "";
          if (
            upstream.status === 429 ||
            upstream.status === 403 && /rate|quota|limit/i.test(providerMessage)
          ) {
            const header = upstream.headers.get("Retry-After");
            const seconds = Number(header) ||
              (header
                ? Math.ceil((Date.parse(header) - Date.now()) / 1000)
                : 60);
            return reply(
              429,
              "Routing provider limit reached",
              Math.min(86400, Math.max(60, seconds || 60)),
            );
          }
          return reply(
            upstream.status === 400 || upstream.status === 404 ? 400 : 503,
            "Route could not be calculated",
          );
        }
        // Provider output is bounded; never forward provider errors or headers/secrets.
        const raw = await upstream.text();
        if (raw.length > 4000000) return reply(502, "Route response too large");
        let decoded;
        try {
          decoded = JSON.parse(raw);
        } catch {
          return reply(502, "Invalid route response");
        }
        if (
          !object(decoded) || decoded.type !== "FeatureCollection" ||
          !Array.isArray(decoded.features) ||
          decoded.features.length < 1 || decoded.features.length > 3
        ) return reply(502, "Invalid route response");
        // Rebuild the public response; omit provider metadata.query and unknown fields.
        const features = [];
        for (const f of decoded.features) {
          if (
            !object(f) || !object(f.geometry) ||
            f.geometry.type !== "LineString" ||
            !Array.isArray(f.geometry.coordinates) ||
            f.geometry.coordinates.length < 2 ||
            f.geometry.coordinates.length > 100000 ||
            !f.geometry.coordinates.every(point) ||
            !object(f.properties) || !object(f.properties.summary)
          ) return reply(502, "Invalid route response");
          const summary = f.properties.summary;
          if (
            !["distance", "duration"].every((k) =>
              typeof summary[k] === "number" &&
              Number.isFinite(summary[k]) && summary[k] >= 0
            )
          ) return reply(502, "Invalid route response");
          features.push({
            type: "Feature",
            geometry: {
              type: "LineString",
              coordinates: f.geometry.coordinates,
            },
            properties: {
              summary: {
                distance: summary.distance,
                duration: summary.duration,
              },
            },
          });
        }
        const clean = JSON.stringify({ type: "FeatureCollection", features });
        for (const [entry, value] of cache) {
          if (value.expires <= Date.now()) cache.delete(entry);
        }
        if (cache.size >= 32) cache.delete(cache.keys().next().value!);
        cache.set(key, { body: clean, expires: Date.now() + 30000 });
        return new Response(clean, { headers: cors });
      };
      const work = load();
      pending.set(key, work);
      try {
        return (await work).clone();
      } finally {
        if (pending.get(key) === work) pending.delete(key);
      }
    } catch {
      return reply(503, "Route service temporarily unavailable");
    }
  };
}
