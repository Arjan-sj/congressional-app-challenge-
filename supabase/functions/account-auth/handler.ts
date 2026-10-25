type Settings = { url: string; serviceKey: string; publicKey: string };
const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
};
const generic = "Unable to sign in. Check your details and verify your email.";
async function hash(value: string) {
  return Array.from(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)),
    ),
  ).map((v) => v.toString(16).padStart(2, "0")).join("");
}

export function createAccountHandler(
  settings: Settings,
  request: typeof fetch = fetch,
) {
  const reply = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), {
      status,
      headers: {
        ...headers,
        ...(status === 429 ? { "Retry-After": "900" } : {}),
      },
    });
  return async (req: Request): Promise<Response> => {
    const started = Date.now();
    const invalidLogin = async () => {
      const delay = Math.max(
        0,
        750 + Math.random() * 75 - (Date.now() - started),
      );
      await new Promise((resolve) => setTimeout(resolve, delay));
      return reply(401, { error: generic });
    };
    if (req.method === "OPTIONS") return new Response("ok", { headers });
    if (req.method !== "POST") return reply(405, { error: "POST required" });
    if (!settings.url || !settings.serviceKey || !settings.publicKey) {
      return reply(503, { error: "Account service unavailable" });
    }
    try {
      if (Number(req.headers.get("content-length") || 0) > 8192) {
        return reply(400, { error: generic });
      }
      const reader = req.body?.getReader();
      if (!reader) return reply(400, { error: generic });
      const chunks: Uint8Array[] = [];
      let size = 0;
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.length;
        if (size > 8192) {
          await reader.cancel();
          return reply(400, { error: generic });
        }
        chunks.push(value);
      }
      const bytes = new Uint8Array(size);
      let offset = 0;
      for (const part of chunks) {
        bytes.set(part, offset);
        offset += part.length;
      }
      let p;
      try {
        p = JSON.parse(new TextDecoder().decode(bytes));
      } catch {
        return reply(400, { error: generic });
      }
      if (
        !p || typeof p !== "object" ||
        !["login", "preflight"].includes(p.action) ||
        typeof p.identifier !== "string" || p.identifier.length > 320 ||
        !p.identifier.trim()
      ) return reply(400, { error: generic });
      const key = req.headers.get("apikey");
      if (!key || key.length > 2048) return reply(401, { error: generic });
      const verified = await request(settings.url + "/auth/v1/settings", {
        headers: { apikey: key },
        signal: AbortSignal.timeout(4000),
      });
      if (!verified.ok) return reply(401, { error: generic });
      const identifier = p.identifier.trim().toLowerCase();
      const identifierHash = await hash(identifier);
      const actorHash = await hash(
        req.headers.get("x-forwarded-for")?.split(",")[0].trim() || "anonymous",
      );
      const serverHeaders = {
        apikey: settings.serviceKey,
        Authorization: `Bearer ${settings.serviceKey}`,
        "Content-Type": "application/json",
      };
      const quota = await request(
        settings.url + "/rest/v1/rpc/claim_account_auth_attempt",
        {
          method: "POST",
          headers: serverHeaders,
          body: JSON.stringify({
            p_actor_hash: actorHash,
            p_identifier_hash: identifierHash,
          }),
          signal: AbortSignal.timeout(4000),
        },
      );
      if (!quota.ok) {
        return reply(503, { error: "Account service unavailable" });
      }
      if (await quota.json() !== true) {
        return reply(429, {
          error: "Too many attempts. Please try again later.",
        });
      }
      if (p.action === "preflight") return reply(200, { allowed: true });
      if (
        typeof p.password !== "string" || p.password.length < 1 ||
        p.password.length > 256 || identifier.includes("@")
      ) return reply(401, { error: generic });
      let email: string | null = null;
      if (/^[a-z][a-z0-9_]{2,23}$/.test(identifier)) {
        const lookup = await request(
          settings.url + "/rest/v1/rpc/resolve_account_login",
          {
            method: "POST",
            headers: serverHeaders,
            body: JSON.stringify({ p_username: identifier }),
            signal: AbortSignal.timeout(4000),
          },
        );
        if (!lookup.ok) {
          return reply(503, { error: "Account service unavailable" });
        }
        const resolved = await lookup.json();
        if (typeof resolved === "string") email = resolved;
      }
      // Always run ordinary Auth password verification, including a dummy identity
      // for unknown usernames. No public username-to-email response ever exists.
      const auth = await request(
        settings.url + "/auth/v1/token?grant_type=password",
        {
          method: "POST",
          headers: {
            apikey: settings.publicKey,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            email: email ?? `unknown-${identifierHash}@login.invalid`,
            password: p.password,
            ...(typeof p.captcha_token === "string"
              ? { gotrue_meta_security: { captcha_token: p.captcha_token } }
              : {}),
          }),
          signal: AbortSignal.timeout(10000),
        },
      );
      if (!auth.ok) return invalidLogin();
      const session = await auth.json();
      if (
        !email || typeof session.access_token !== "string" ||
        typeof session.refresh_token !== "string" ||
        !session.user?.email_confirmed_at
      ) return invalidLogin();
      return reply(200, {
        access_token: session.access_token,
        refresh_token: session.refresh_token,
      });
    } catch {
      return reply(503, { error: "Account service temporarily unavailable" });
    }
  };
}
