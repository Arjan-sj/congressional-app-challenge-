import { normalize } from './osm_normalize.ts';
import { overpassProvider, OVERPASS_USER_AGENT } from './overpass_provider.ts';
import { infrastructureFailure, infrastructurePayload, InfrastructureRequests, needsOverpass, validInfrastructureCache, type Bounds } from './infrastructure_response.ts';
// Public, read-only, geographically bounded fallback. No browser Overpass calls.
// verify_jwt=false supports Supabase publishable keys. Shared DB cooldown bounds
// upstream traffic even across Edge isolates and anonymous browser sessions.
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info', 'Content-Type': 'application/json' };
const base = Deno.env.get('SUPABASE_URL')!;
const secret = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const headers = { apikey: secret, Authorization: `Bearer ${secret}`, 'Content-Type': 'application/json' };
const requests = new InfrastructureRequests();
async function db(path: string, body?: unknown, method = 'POST') {
  const response = await fetch(`${base}/rest/v1/${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), signal:AbortSignal.timeout(5000) });
  if (!response.ok) throw new Error('Cache database unavailable');
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response('ok', {headers:cors});
  const reply = (body: unknown, status=200, retry?: number) => new Response(JSON.stringify(body), {status, headers:{...cors,...(retry ? {'Retry-After':String(retry)} : {})}});
  if (request.method !== 'POST') return reply({error:'POST required'},405);
  try {
    const apiKey = request.headers.get('apikey');
    if (!apiKey || apiKey.length > 2048) return reply({error:'API key required'},401);
    // Validate the public project key through the gateway. Never log it.
    const auth = await fetch(`${base}/auth/v1/settings`, {headers:{apikey:apiKey},signal:AbortSignal.timeout(5000)});
    if (!auth.ok) return reply({error:'Invalid project key'},401);
    if (Number(request.headers.get('content-length') ?? 0)>4096) return reply({error:'Request too large'},413);
    const p = await request.json();
    const coordinates = [p.min_lat,p.min_lon,p.max_lat,p.max_lon];
    if (!coordinates.every(v => typeof v === 'number' && Number.isFinite(v)) ||
        p.min_lat < -85 || p.max_lat > 85 || p.min_lon < -180 || p.max_lon > 180 ||
        p.min_lat >= p.max_lat || p.min_lon >= p.max_lon || p.max_lat-p.min_lat > .08 || p.max_lon-p.min_lon > .08 || typeof p.zoom !== 'number' || !Number.isFinite(p.zoom) || p.zoom < 15)
      return reply({error:'Zoom in for a small infrastructure viewport'},400);
    const allowed = ['crossing','sidewalk','bikePath','bikeLane','walkingPath'];
    if (!Array.isArray(p.categories) || p.categories.length>5 || !p.categories.every((c: unknown) => typeof c==='string' && allowed.includes(c)))
      return reply({error:'Invalid infrastructure categories'},400);
    const categories = [...new Set<string>(p.categories ?? [])].filter(c => allowed.includes(c)).sort();
    if (!categories.length) return reply(infrastructurePayload([],coordinates as Bounds,Date.now()));
    const bounds: Bounds = [Math.floor(p.min_lat*100)/100,Math.floor(p.min_lon*100)/100,Math.ceil(p.max_lat*100)/100,Math.ceil(p.max_lon*100)/100];
    // Recheck server-side even if a caller bypasses Flutter. Imported empty areas
    // are legitimate results; missing/stale coverage alone permits fallback.
    const primary = await db('rpc/infrastructure_viewport', {
      min_lat:p.min_lat,min_lon:p.min_lon,max_lat:p.max_lat,max_lon:p.max_lon,
      categories,zoom:p.zoom,after_id:'',
    });
    if (!needsOverpass(primary)) return reply({
      ...infrastructurePayload(primary.items,coordinates as Bounds,Date.now()),
      coverage:primary.items.length===500 ? 'partial' : primary.coverage,
      expires_at:primary.expires_at,source:'Supabase regional import',
    });
    const provider = overpassProvider(Deno.env.get('OVERPASS_URL'));
    const cell = `osm-v3:${provider.host}:${bounds.join(':')}:${categories.join(',')}`;
    const cached = await db(`map_provider_cache?cell=eq.${encodeURIComponent(cell)}&select=payload,expires_at`,undefined,'GET');
    const validCache = validInfrastructureCache(cached[0],coordinates as Bounds,Date.now());
    if (validCache) return reply(validCache);
    const result = await requests.run(cell,async () => {
    // Both a regional lock and a global provider budget, not a public-proxy free-for-all.
    if (!await db('rpc/claim_map_provider',{cache_cell:cell}) || !await db('rpc/claim_map_provider',{cache_cell:provider.cooldownKey}))
      return infrastructureFailure('rateLimited','Infrastructure cooling down; retry in a minute.',60);
    const bbox = bounds.join(',');
    const clauses: string[] = [];
    if (categories.includes('crossing')) clauses.push(`node[highway=crossing](${bbox});way[highway=footway][footway=crossing](${bbox});`);
    if (categories.includes('sidewalk')) clauses.push(`way[highway=footway][footway=sidewalk](${bbox});way[~"^sidewalk(:left|:right|:both)?$"~"^(yes|both|left|right)$"](${bbox});`);
    if (categories.includes('bikePath') || categories.includes('bikeLane')) clauses.push(`way[highway=cycleway](${bbox});way[~"^cycleway(:left|:right|:both)?$"~"^(track|lane|opposite_lane|opposite_track|shared_lane|share_busway)$"](${bbox});way[highway=path][bicycle=designated](${bbox});`);
    if (categories.includes('walkingPath')) clauses.push(`way[highway~"^(footway|path|pedestrian)$"](${bbox});`);
    const upstream = await fetch(provider.endpoint,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded','Accept':'application/json','User-Agent':OVERPASS_USER_AGENT},
      body:new URLSearchParams({data:`[out:json][timeout:15][maxsize:8388608];(${clauses.join('')});out tags geom;`}),signal:AbortSignal.timeout(18000)});
    if (!upstream.ok) {
      const retryHeader = upstream.headers.get('Retry-After');
      const retry = Math.min(3600, Math.max(60, Number(retryHeader) || (retryHeader ? Math.ceil((Date.parse(retryHeader)-Date.now())/1000) : 120) || 120));
      await db(`map_provider_cache?cell=eq.${encodeURIComponent(provider.cooldownKey)}`,{retry_at:new Date(Date.now()+retry*1000).toISOString()},'PATCH');
      return infrastructureFailure(upstream.status===429 ? 'rateLimited' : 'server',upstream.status===429 ? 'Infrastructure rate limited. Retry later.' : `Infrastructure provider unavailable (${upstream.status}).`,retry);
    }
    const raw = await upstream.text();
    if (raw.length>8388608) throw new Error('Infrastructure response too large');
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed.elements) || parsed.remark) throw new Error('Incomplete infrastructure response');
    const payload = {...infrastructurePayload(normalize(parsed.elements,categories),bounds,Date.now()),provider:provider.host};
    await db(`map_provider_cache?cell=eq.${encodeURIComponent(cell)}`,{payload,expires_at:payload.expires_at},'PATCH');
    return payload;
    });
    return reply(result,200,'retry_after' in result ? result.retry_after : undefined);
  } catch (error) {
    console.error('map-infrastructure',error instanceof Error ? error.name : 'error');
    return reply(infrastructureFailure(error instanceof Error && error.name==='TimeoutError' ? 'timeout' : 'server','Optional infrastructure unavailable. Schools and reports remain available.'),200,60);
  }
});
