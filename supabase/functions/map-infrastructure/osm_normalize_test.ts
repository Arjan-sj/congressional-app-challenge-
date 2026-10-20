import { normalize } from './osm_normalize.ts';
function equal(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual)!==JSON.stringify(expected)) throw new Error(`Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
Deno.test('a crossing node and its connecting way represent one crossing', () => {
  const result = normalize([
    {type:'node',id:1,lat:42,lon:-88,tags:{highway:'crossing','crossing:signals':'yes'}},
    {type:'way',id:2,tags:{highway:'footway',footway:'crossing'},geometry:[{lat:42,lon:-88},{lat:42.0001,lon:-88}]},
  ],['crossing']);
  equal(result.length,1);
});
Deno.test('ordinary footways are walking paths, with directional cycle tags supported', () => {
  const result = normalize([
    {type:'way',id:1,tags:{highway:'footway'},geometry:[{lat:42,lon:-88},{lat:42.001,lon:-88}]},
    {type:'way',id:2,tags:{highway:'residential','cycleway:left':'lane'},geometry:[{lat:42,lon:-88},{lat:42.001,lon:-88}]},
  ],['sidewalk','walkingPath','bikeLane']) as {category:string}[];
  equal(result.map(r=>r.category),['walkingPath','bikeLane']);
});
Deno.test('hidden categories and explicit negative access are excluded', () => {
  const elements = [{type:'way',id:1,tags:{highway:'cycleway',bicycle:'no'},geometry:[{lat:42,lon:-88},{lat:42.001,lon:-88}]}];
  equal(normalize(elements,['bikePath']),[]);
  equal(normalize([{type:'node',id:1,lat:42,lon:-88,tags:{highway:'crossing'}}],['sidewalk']),[]);
});
