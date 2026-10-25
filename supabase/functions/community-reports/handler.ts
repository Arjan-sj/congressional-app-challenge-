type Settings = { url: string; key: string };
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "apikey, authorization, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
};
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function networkAddress(value: string | undefined): string | null {
  if (!value || value.length > 64) return null;
  if (/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/.test(value)) {
    const octets = value.split(".").map(Number);
    return octets.every((x) => x >= 0 && x <= 255) ? octets.join(".") : null;
  }
  if (!value.includes(":")) return null;
  try {
    return new URL("http://[" + value.replace(/^\[|\]$/g, "") + "]/").hostname
      .toLowerCase();
  } catch {
    return null;
  }
}
class Failure extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}
async function digest(key: string, value: string) {
  const hmac = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(key),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return Array.from(
    new Uint8Array(
      await crypto.subtle.sign("HMAC", hmac, new TextEncoder().encode(value)),
    ),
  ).map((x) => x.toString(16).padStart(2, "0")).join("");
}
export function createCommunityHandler(
  settings: Settings,
  request: typeof fetch = fetch,
) {
  const reply = (status: number, data: unknown) =>
    new Response(JSON.stringify(data), {
      status,
      headers: { ...cors, ...(status === 429 ? { "Retry-After": "900" } : {}) },
    });
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
    if (req.method !== "POST") return reply(405, { error: "POST required" });
    let uploaded: string | null = null, receiptUncertain = false;
    const serverHeaders = {
      apikey: settings.key,
      Authorization: `Bearer ${settings.key}`,
      "Content-Type": "application/json",
    };
    const removePhoto = async (path: string) => {
      const r = await request(
        settings.url + "/storage/v1/object/hazard-photos",
        {
          method: "DELETE",
          headers: serverHeaders,
          body: JSON.stringify({ prefixes: [path] }),
          signal: AbortSignal.timeout(10000),
        },
      );
      if (!r.ok) {
        throw new Failure(
          503,
          "Photo cleanup is pending. Retry the same submission.",
        );
      }
    };
    try {
      if (!settings.url || !settings.key) {
        throw new Failure(
          503,
          "Community service is unavailable. Please retry.",
        );
      }
      // Bound both declared and streamed payload sizes before decoding photo data.
      const max = 7_100_000;
      if (Number(req.headers.get("content-length") || 0) > max) {
        throw new Failure(413, "The photo is too large.");
      }
      const reader = req.body?.getReader();
      if (!reader) throw new Failure(400, "Contribution required.");
      const chunks: Uint8Array[] = [];
      let size = 0;
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.length;
        if (size > max) {
          await reader.cancel();
          throw new Failure(413, "The photo is too large.");
        }
        chunks.push(value);
      }
      const bytes = new Uint8Array(size);
      let offset = 0;
      for (const b of chunks) {
        bytes.set(b, offset);
        offset += b.length;
      }
      let p;
      try {
        p = JSON.parse(new TextDecoder().decode(bytes));
      } catch {
        throw new Failure(400, "Invalid contribution.");
      }
      if (
        !p || !["submit", "review", "summary"].includes(p.action) ||
        !uuid.test(p.report?.id ?? "") ||
        !/^[-_A-Za-z0-9]{43}$/.test(p.visitor ?? "")
      ) throw new Failure(400, "Invalid contribution.");
      const key = req.headers.get("apikey");
      if (!key || key.length > 2048) {
        throw new Failure(401, "Project key required.");
      }
      const valid = await request(settings.url + "/auth/v1/settings", {
        headers: { apikey: key },
        signal: AbortSignal.timeout(4000),
      });
      if (!valid.ok) throw new Failure(401, "Invalid project key.");
      // Use the gateway's nearest forwarding address, never a caller-selected first
      // address. No raw address or browser token is stored or returned. Missing
      // gateway metadata fails closed for writes rather than inventing identities.
      const network = networkAddress(
        req.headers.get("x-forwarded-for")?.split(",").at(-1)?.trim(),
      );
      if (!network) {
        throw new Failure(
          503,
          "Unable to validate this connection. Please retry.",
        );
      }
      const participant = await digest(
        settings.key,
        "community:visitor:" + p.visitor,
      );
      const networkHash = await digest(
        settings.key,
        "community:network:" + network,
      );
      const payload: Record<string, unknown> = { id: p.report.id };
      if (p.action === "submit") {
        const r = p.report;
        if (
          !Number.isFinite(r.latitude) || !Number.isFinite(r.longitude) ||
          Math.abs(r.latitude) > 90 || Math.abs(r.longitude) > 180 ||
          ![
            "missing_sidewalk",
            "difficult_crossing",
            "poor_lighting",
            "blocked_path",
            "bike_route",
          ].includes(r.type) || !Number.isInteger(r.severity) ||
          r.severity < 1 || r.severity > 5 ||
          typeof r.description !== "string" ||
          r.description.trim().length < 5 || r.description.trim().length > 250
        ) {
          throw new Failure(
            400,
            "Check the location, category, severity and description.",
          );
        }
        Object.assign(payload, {
          latitude: r.latitude,
          longitude: r.longitude,
          type: r.type,
          severity: r.severity,
          description: r.description.trim(),
        });
        const ready = await request(
          settings.url + "/rest/v1/rpc/community_action",
          {
            method: "POST",
            headers: serverHeaders,
            body: JSON.stringify({
              p_action: "prepare",
              p_participant_hash: participant,
              p_network_hash: networkHash,
              p_payload: { id: r.id },
            }),
            signal: AbortSignal.timeout(5000),
          },
        );
        if (!ready.ok) {
          const e = await ready.json().catch(() => ({}));
          throw new Failure(
            e.code === "P0429" ? 429 : 503,
            e.code === "P0429"
              ? "Contribution limit reached. Try again later."
              : "Community service is unavailable. Please retry.",
          );
        }
        if (p.photo != null) {
          if (
            typeof p.photo.base64 !== "string" ||
            p.photo.base64.length > 7_000_000
          ) throw new Failure(413, "The photo is too large.");
          let photo: Uint8Array;
          try {
            photo = Uint8Array.from(
              atob(p.photo.base64),
              (c) => c.charCodeAt(0),
            );
          } catch {
            throw new Failure(400, "Invalid photo.");
          }
          const jpeg = photo.length >= 3 && photo[0] === 255 &&
            photo[1] === 216 && photo[2] === 255;
          const png = photo.length >= 8 &&
            [137, 80, 78, 71, 13, 10, 26, 10].every((v, i) => photo[i] === v);
          const webp = photo.length >= 12 &&
            new TextDecoder().decode(photo.subarray(0, 4)) === "RIFF" &&
            new TextDecoder().decode(photo.subarray(8, 12)) === "WEBP";
          if (
            photo.length < 12 || photo.length > 5 * 1024 * 1024 ||
            !jpeg && !png && !webp
          ) throw new Failure(400, "Use a JPEG, PNG or WebP photo up to 5 MB.");
          const extension = jpeg ? "jpg" : png ? "png" : "webp",
            mime = jpeg ? "image/jpeg" : png ? "image/png" : "image/webp";
          uploaded = `${r.id}/${Date.now()}${
            crypto.getRandomValues(new Uint32Array(3)).join("")
          }.${extension}`;
          const upload = await request(
            settings.url + "/storage/v1/object/hazard-photos/" + uploaded,
            {
              method: "POST",
              headers: {
                ...serverHeaders,
                "Content-Type": mime,
                "x-upsert": "false",
              },
              body: new Uint8Array(photo).buffer,
              signal: AbortSignal.timeout(20000),
            },
          );
          if (!upload.ok) {
            throw new Failure(503, "Photo upload failed. Please retry.");
          }
          payload.photo_path = uploaded;
        }
      } else if (p.action === "review") {
        const r = p.report;
        if (
          !Number.isInteger(r.review_round) || r.review_round < 0 ||
          !["unverified", "verified", "resolved", "rejected"].includes(
            r.expected_status,
          ) ||
          !["verified", "resolved", "rejected", "flag"].includes(r.choice) ||
          typeof r.reason !== "string" || r.reason.trim().length < 5 ||
          r.reason.trim().length > 500
        ) {
          throw new Failure(
            400,
            "Choose an outcome and provide a reason (5–500 characters).",
          );
        }
        Object.assign(payload, {
          review_round: r.review_round,
          expected_status: r.expected_status,
          choice: r.choice,
          reason: r.reason.trim(),
        });
      }
      let rpc: Response;
      try {
        rpc = await request(settings.url + "/rest/v1/rpc/community_action", {
          method: "POST",
          headers: serverHeaders,
          body: JSON.stringify({
            p_action: p.action,
            p_participant_hash: participant,
            p_network_hash: networkHash,
            p_payload: payload,
          }),
          signal: AbortSignal.timeout(15000),
        });
      } catch {
        receiptUncertain = true;
        throw new Failure(
          503,
          "Submission receipt is unavailable. Retry the same report; do not submit a second copy.",
        );
      }
      if (!rpc.ok) {
        const e = await rpc.json().catch(() => ({}));
        const allowed = [
          "No nearby school was found. Move the map pin and retry.",
          "Report changed. Refresh before reviewing again.",
          "A recent community decision is cooling down. Try later.",
          "You cannot review your own submission",
          "This connection has already reviewed this report",
          "Report unavailable",
          "Report ID unavailable",
          "Contribution limit reached. Try again later.",
        ];
        throw new Failure(
          e.code === "P0429" ? 429 : e.code === "P0409" ? 409 : 400,
          allowed.includes(e.message)
            ? e.message
            : "Unable to save this contribution. Refresh and retry.",
        );
      }
      receiptUncertain = true;
      const data = await rpc.json();
      if (uploaded && uploaded !== data.photo_path) await removePhoto(uploaded);
      uploaded = null;
      // URLs are created only after the RPC explicitly checks public visibility.
      if (data.photo_path) {
        try {
          const signed = await request(
            settings.url + "/storage/v1/object/sign/hazard-photos/" +
              data.photo_path,
            {
              method: "POST",
              headers: serverHeaders,
              body: JSON.stringify({ expiresIn: 600 }),
              signal: AbortSignal.timeout(5000),
            },
          );
          if (signed.ok) {
            const body = await signed.json();
            if (typeof body.signedURL === "string") {
              data.photo_url = settings.url + "/storage/v1" + body.signedURL;
            }
          }
        } catch {
          /* Saved evidence remains available for a later signed-URL refresh. */
        }
      }
      return reply(200, data);
    } catch (e) {
      if (uploaded && !receiptUncertain) {
        try {
          await removePhoto(uploaded);
        } catch {
          return reply(503, {
            error: "Photo cleanup could not finish. Retry the same submission.",
          });
        }
      }
      return reply(e instanceof Failure ? e.status : 503, {
        error: e instanceof Failure
          ? e.message
          : "Community service is temporarily unavailable. Please retry.",
      });
    }
  };
}
