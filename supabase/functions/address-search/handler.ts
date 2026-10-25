type Settings = { supabaseUrl: string; serviceKey: string; orsKey: string };
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
};
async function digest(value: string) {
  return Array.from(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)),
    ),
  )
    .map((v) => v.toString(16).padStart(2, "0")).join("");
}

export function createAddressHandler(settings: Settings, transport: typeof fetch = fetch) {
  const reply = (status: number, message: string, retry = 60) => new Response(JSON.stringify({error: message}), {
    status, headers: {...cors, ...(status === 429 ? {"Retry-After": String(retry)} : {})},
  });
  return async (request: Request): Promise<Response> => {
    if (request.method === "OPTIONS") return new Response("ok", {headers: cors});
    if (request.method !== "POST") return reply(405, "POST required");
    if (!settings.orsKey || !settings.serviceKey || !settings.supabaseUrl) return reply(503, "Address search unavailable");
    try {
      const reader = request.body?.getReader();
      if (!reader) return reply(400, "Address required");
      let raw = "";
      let size = 0;
      const decoder = new TextDecoder();
      while (true) {
        const {done, value} = await reader.read();
        if (done) break;
        size += value.length;
        if (size > 2048) { await reader.cancel(); return reply(413, "Address too long"); }
        raw += decoder.decode(value, {stream: true});
      }
      raw += decoder.decode();
      let query: string;
      try {
        const body = JSON.parse(raw);
        if (!body || typeof body.query !== "string" || Object.keys(body).length !== 1) return reply(400, "Invalid address");
        query = body.query.trim();
        if (query.length < 3 || query.length > 200 || /[\u0000-\u001f]/.test(query)) return reply(400, "Invalid address");
      } catch { return reply(400, "Invalid address"); }
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

      const claim = await transport(`${settings.supabaseUrl}/rest/v1/rpc/claim_address_request`, {
        method: "POST", headers: {apikey: settings.serviceKey, Authorization: `Bearer ${settings.serviceKey}`, "Content-Type": "application/json"},
        body: JSON.stringify({p_actor_hash: actorHash}), signal: AbortSignal.timeout(3000),
      });
      if (!claim.ok) return reply(503, "Address search unavailable");
      const quota = await claim.json();
      if (quota.granted !== true) return reply(429, "Address search limit reached. Try later or select a map point.", Math.max(1, Math.min(86400, Number(quota.retry_after) || 60)));
      // Reuse the nationwide NCES directory for named schools. Its official
      // address avoids locality aliases and missing venues in the geocoder.
      query = query.replace(/\b(high|middle|elementary)school\b/gi, "$1 school");
      if (!/^\d/.test(query) && /\bschool\b/i.test(query)) {
        try {
          const directory = await transport(`${settings.supabaseUrl}/rest/v1/rpc/search_schools`, {
            method: "POST",
            headers: {apikey: apiKey, "Content-Type": "application/json"},
            body: JSON.stringify({search_text: query, state_code: null}),
            signal: AbortSignal.timeout(2500),
          });
          if (directory.ok) {
            const rows = await directory.json();
            if (Array.isArray(rows)) {
              const suggestions = rows.slice(0, 5).flatMap((row) => {
                if (typeof row?.name !== "string" || !row.name.trim() ||
                    typeof row.latitude !== "number" || !Number.isFinite(row.latitude) || Math.abs(row.latitude) > 90 ||
                    typeof row.longitude !== "number" || !Number.isFinite(row.longitude) || Math.abs(row.longitude) > 180) return [];
                const label = [row.name, row.address, row.city, row.state, row.zip_code]
                  .filter((part) => typeof part === "string" && part.trim()).join(", ");
                return label.length > 500 ? [] : [{label, latitude: row.latitude, longitude: row.longitude}];
              });
              if (suggestions.length) return new Response(JSON.stringify({suggestions}), {headers: cors});
            }
          }
        } catch { /* Directory outages fall back to the address provider. */ }
      }
      const url = new URL("https://api.openrouteservice.org/geocode/autocomplete");
      url.search = new URLSearchParams({api_key: settings.orsKey, text: query, "boundary.country": "USA", size: "5"}).toString();
      const upstream = await transport(url, {signal: AbortSignal.timeout(8000)});
      if (!upstream.ok) return reply(upstream.status === 429 ? 429 : 503, "Address search unavailable");
      const rawResponse = await upstream.text();
      if (rawResponse.length > 100000) return reply(502, "Invalid address response");
      const data = JSON.parse(rawResponse);
      if (!Array.isArray(data.features)) return reply(502, "Invalid address response");
      const suggestions = [];
      for (const feature of data.features.slice(0, 5)) {
        const p = feature?.properties;
        const c = feature?.geometry?.coordinates;
        if (p?.country_a !== "USA") continue;
        if (typeof p.label !== "string" || !p.label.trim() || p.label.length > 500 ||
            feature.geometry.type !== "Point" || !Array.isArray(c) || c.length !== 2 ||
            !c.every((n: unknown) => typeof n === "number" && Number.isFinite(n)) || Math.abs(c[0]) > 180 || Math.abs(c[1]) > 90) {
          return reply(502, "Invalid address response");
        }
        suggestions.push({label: p.label, latitude: c[1], longitude: c[0]});
      }
      return new Response(JSON.stringify({suggestions}), {headers: cors});
    } catch { return reply(503, "Address search unavailable. Retry or select a map point."); }
  };
}
