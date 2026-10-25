import { createAccountHandler } from "./handler.ts";
function assert(v: unknown, message = "Assertion failed"): asserts v {
  if (!v) throw Error(message);
}
const settings = {
  url: "https://project.test",
  serviceKey: "server-only-key",
  publicKey: "public-project-key",
};
const req = (body: unknown, key = "public-project-key") =>
  new Request("https://project.test/functions/v1/account-auth", {
    method: "POST",
    headers: { apikey: key, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
function fixture(
  {
    email = "private@example.test" as string | null,
    granted = true,
    passwordStatus = 200,
    confirmed = true,
    settingsStatus = 200,
  } = {},
) {
  const calls: { url: string; body: Record<string, unknown> }[] = [];
  const handler = createAccountHandler(
    settings,
    (async (url, options) => {
      const target = String(url),
        body = JSON.parse(String(options?.body ?? "{}"));
      calls.push({ url: target, body });
      const headers = new Headers(options?.headers);
      if (target.endsWith("/auth/v1/settings")) {
        return Response.json({}, {
          status: settingsStatus,
        });
      }
      if (target.endsWith("/claim_account_auth_attempt")) {
        assert(headers.get("apikey") === settings.serviceKey);
        assert(/^[0-9a-f]{64}$/.test(body.p_identifier_hash));
        assert(!JSON.stringify(body).includes("private@example.test"));
        return Response.json(granted);
      }
      if (target.endsWith("/resolve_account_login")) {
        assert(headers.get("apikey") === settings.serviceKey);
        return Response.json(email);
      }
      assert(target.endsWith("/auth/v1/token?grant_type=password"));
      assert(
        headers.get("apikey") === settings.publicKey,
        "Ordinary Auth verifies the password",
      );
      return Response.json(
        passwordStatus === 200
          ? {
            access_token: "synthetic-access-token",
            refresh_token: "synthetic-refresh-token",
            user: {
              email,
              email_confirmed_at: confirmed ? "2026-01-01" : null,
            },
          }
          : { error: "private backend error and email" },
        { status: passwordStatus },
      );
    }) as typeof fetch,
  );
  return { handler, calls };
}
Deno.test("username login resolves only server-side and returns tokens after ordinary Auth verification", async () => {
  const f = fixture();
  const response = await f.handler(
    req({
      action: "login",
      identifier: " Traveler ",
      password: "synthetic password",
    }),
  );
  const raw = await response.text();
  assert(response.status === 200);
  assert(!raw.includes("private@example.test"));
  assert(!raw.includes(settings.serviceKey));
  assert(
    f.calls.find((c) => c.url.endsWith("resolve_account_login"))?.body
      .p_username === "traveler",
  );
  const verify = f.calls.find((c) => c.url.includes("grant_type=password"))!;
  assert(verify.body.email === "private@example.test");
  assert(verify.body.password === "synthetic password");
  assert(response.headers.get("Cache-Control") === "no-store");
});
Deno.test("unknown usernames and wrong passwords have the same generic failure; unknowns still verify a dummy password", async () => {
  const unknown = fixture({ email: null, passwordStatus: 400 }),
    wrong = fixture({ passwordStatus: 400 });
  const a = await unknown.handler(
    req({ action: "login", identifier: "unknown", password: "incorrect" }),
  );
  const b = await wrong.handler(
    req({ action: "login", identifier: "known", password: "incorrect" }),
  );
  assert(a.status === 401 && b.status === 401);
  assert(await a.text() === await b.text());
  const body =
    unknown.calls.find((c) => c.url.includes("grant_type=password"))!.body;
  assert(String(body.email).endsWith("@login.invalid"));
});
Deno.test("email verification is required even if Auth returns a session", async () => {
  const f = fixture({ confirmed: false });
  const r = await f.handler(
    req({ action: "login", identifier: "traveler", password: "correct" }),
  );
  assert(r.status === 401);
  assert(!(await r.text()).includes("synthetic-access-token"));
});
Deno.test("native email/signup/recovery preflight rate limits without resolving emails or issuing sessions", async () => {
  const f = fixture();
  const r = await f.handler(
    req({ action: "preflight", identifier: "private@example.test" }),
  );
  assert(r.status === 200 && f.calls.length === 2);
  assert(!f.calls.some((c) => c.url.includes("resolve_account_login")));
  const limited = fixture({ granted: false });
  const no = await limited.handler(
    req({ action: "login", identifier: "traveler", password: "correct" }),
  );
  assert(no.status === 429 && no.headers.has("Retry-After"));
  assert(limited.calls.length === 2);
});
Deno.test("project-key, method, payload and service failure safeguards never expose lookup data", async () => {
  const denied = fixture({ settingsStatus: 401 });
  assert(
    (await denied.handler(req({ action: "preflight", identifier: "person" })))
      .status === 401,
  );
  assert(denied.calls.length === 1);
  const f = fixture();
  assert(
    (await f.handler(req({ action: "lookup", identifier: "traveler" })))
      .status === 400,
  );
  assert(
    (await f.handler(
      req({
        action: "login",
        identifier: "traveler",
        password: "x".repeat(300),
      }),
    )).status === 401,
  );
  assert((await f.handler(req({ padding: "x".repeat(9000) }))).status === 400);
  assert(
    (await f.handler(
      new Request("https://project.test", { method: "OPTIONS" }),
    )).status === 200,
  );
  assert((await f.handler(new Request("https://project.test"))).status === 405);
  const broken = createAccountHandler(
    settings,
    (() => {
      throw Error("secret details");
    }) as typeof fetch,
  );
  const r = await broken(req({ action: "preflight", identifier: "traveler" }));
  assert(r.status === 503);
  assert(!(await r.text()).includes("secret details"));
});
