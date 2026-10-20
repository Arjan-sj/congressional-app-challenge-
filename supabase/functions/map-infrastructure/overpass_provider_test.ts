import { DEFAULT_OVERPASS_URL, overpassProvider } from './overpass_provider.ts';
function equal(actual: unknown, expected: unknown) {
  if (actual !== expected) throw new Error(`Expected ${expected}, got ${actual}`);
}
Deno.test('default mirror is Private.coffee, including blank configuration', () => {
  equal(DEFAULT_OVERPASS_URL, 'https://overpass.private.coffee/api/interpreter');
  equal(overpassProvider().endpoint, DEFAULT_OVERPASS_URL);
  equal(overpassProvider('  ').endpoint, DEFAULT_OVERPASS_URL);
});
Deno.test('server override is preserved without exposing URL credentials in cache keys', () => {
  const provider = overpassProvider(' https://managed.example/secret-key/api/interpreter ');
  equal(provider.endpoint, 'https://managed.example/secret-key/api/interpreter');
  equal(provider.cooldownKey, 'overpass:managed.example');
});
Deno.test('provider cooldowns are independent across an explicit endpoint switch', () => {
  equal(overpassProvider().cooldownKey, 'overpass:overpass.private.coffee');
  equal(overpassProvider('https://maps.mail.ru/osm/tools/overpass/api/interpreter').cooldownKey, 'overpass:maps.mail.ru');
});
