// Query completeness is not a claim about completeness of real-world mapping.
export type Bounds = [number, number, number, number];
export const INFRASTRUCTURE_TTL_MS = 24 * 60 * 60 * 1000;

/** Missing metadata fails closed: a public request cannot force upstream work. */
export function needsOverpass(value: unknown): boolean {
  if (!value || typeof value !== 'object') throw new Error('Coverage unavailable');
  const p = value as Record<string, unknown>;
  if (!Array.isArray(p.items) || typeof p.fallback_required !== 'boolean' ||
      !['complete', 'partial', 'missing', 'stale'].includes(String(p.import_coverage))) {
    throw new Error('Invalid coverage response');
  }
  return p.items.length === 0 && p.import_coverage !== 'complete' && p.fallback_required;
}

export function infrastructurePayload(
  items: unknown[],
  bounds: Bounds,
  now: number,
) {
  return {
    items: items.slice(0, 5000),
    bounds,
    coverage: items.length > 5000 ? "partial" : "complete",
    source: "Overpass cached",
    fetched_at: new Date(now).toISOString(),
    expires_at: new Date(now + INFRASTRUCTURE_TTL_MS).toISOString(),
  };
}

export function validInfrastructureCache(
  row: { payload?: unknown; expires_at?: string } | undefined,
  requested: Bounds,
  now: number,
): Record<string, unknown> | null {
  if (!row?.payload || typeof row.payload !== "object") return null;
  const p = row.payload as Record<string, unknown>;
  const box = p.bounds as unknown[];
  const fetched = Date.parse(String(p.fetched_at));
  const expiry = Math.min(
    Date.parse(String(row.expires_at)),
    Date.parse(String(p.expires_at)),
    fetched + INFRASTRUCTURE_TTL_MS,
  );
  if (
    !Array.isArray(p.items) || p.warning || !Number.isFinite(fetched) ||
    fetched > now + 300000 ||
    !Number.isFinite(expiry) || expiry <= now || !Array.isArray(box) ||
    box.length !== 4 ||
    !box.every((v) => typeof v === "number" && Number.isFinite(v))
  ) return null;
  const [south, west, north, east] = box as Bounds;
  if (
    south > requested[0] || west > requested[1] || north < requested[2] ||
    east < requested[3] || south >= north || west >= east
  ) return null;
  return { ...p, expires_at: new Date(expiry).toISOString() };
}

export function infrastructureFailure(
  failure: string,
  warning: string,
  retry = 60,
) {
  return {
    items: [],
    coverage: "unavailable",
    warning,
    failure,
    retry_after: Math.min(
      3600,
      Math.max(1, Math.ceil(Number.isFinite(retry) ? retry : 60)),
    ),
  };
}

/** Concurrent identical reads share work; failures never remain cached. */
export class InfrastructureRequests {
  private pending = new Map<string, Promise<unknown>>();
  run<T>(key: string, load: () => Promise<T>): Promise<T> {
    const existing = this.pending.get(key);
    if (existing) return existing as Promise<T>;
    const result = Promise.resolve().then(load);
    this.pending.set(key, result);
    return result.finally(() => {
      if (this.pending.get(key) === result) this.pending.delete(key);
    });
  }
}
