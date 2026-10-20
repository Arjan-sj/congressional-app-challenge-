// A single configured provider; do not rotate instances after a rate limit.
export const DEFAULT_OVERPASS_URL = 'https://overpass.private.coffee/api/interpreter';
export const OVERPASS_USER_AGENT = 'SafeRoutes/1.0 (+https://github.com/Arjan-sj/congressional-app-challenge-)';

export function overpassProvider(configured?: string) {
  const endpoint = configured?.trim() || DEFAULT_OVERPASS_URL;
  const host = new URL(endpoint).host;
  return { endpoint, host, cooldownKey: `overpass:${host}` };
}
