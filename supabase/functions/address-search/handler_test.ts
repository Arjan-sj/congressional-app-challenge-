import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createAddressHandler} from './handler.ts';
const settings = {supabaseUrl:'https://project.supabase.co', serviceKey:'server-secret', orsKey:'provider-secret'};
const feature = {geometry:{type:'Point',coordinates:[-77.0365,38.8977]}, properties:{label:'1600 Pennsylvania Avenue NW, Washington, DC, USA',country_a:'USA'}};
const request = (query: unknown = '1600 Pennsylvania Ave', key = 'public-key') => new Request('https://edge/address-search', {method:'POST',headers:{apikey:key},body:JSON.stringify({query})});
function transport(options: {quota?: boolean; providerStatus?: number; features?: unknown; authorized?: boolean} = {}) {
 const calls: string[] = [];
 const fetcher: typeof fetch = async (input) => {
  const url=String(input); calls.push(url);
  if(url.endsWith('/settings')) return new Response('{}',{status:options.authorized === false ? 401 : 200});
  if(url.includes('/rpc/')) return Response.json({granted: options.quota ?? true});
  return Response.json({features:options.features ?? [feature], metadata:{api_key:settings.orsKey}}, {status:options.providerStatus ?? 200});
 };
 return {fetcher,calls};
}
test('nationwide address coordinates are returned without keys or provider metadata',async()=>{
 const {fetcher,calls}=transport();
 const result=await createAddressHandler(settings,fetcher)(request());
 assert.equal(result.status,200);
 const body=await result.text(); assert(!body.includes('secret')); assert(!body.includes('metadata'));
 assert.deepEqual(JSON.parse(body).suggestions,[{label:feature.properties.label,latitude:38.8977,longitude:-77.0365}]);
 const url=new URL(calls.at(-1)!); assert.equal(url.searchParams.get('boundary.country'),'USA');assert.equal(url.searchParams.get('size'),'5');
 assert.equal(result.headers.get('cache-control'),'no-store');
});
test('short or malformed queries never reach provider',async()=>{
 const {fetcher,calls}=transport();const handler=createAddressHandler(settings,fetcher);
 for(const query of ['ab','a'.repeat(201),{},'foo\nbar']) assert.equal((await handler(request(query))).status,400);
 assert.equal(calls.length,0);
});
test('missing configuration fails closed',async()=>assert.equal((await createAddressHandler({...settings,orsKey:''})(request())).status,503));
test('missing and invalid project keys cannot consume quota',async()=>{
 const {fetcher,calls}=transport({authorized:false});const handler=createAddressHandler(settings,fetcher);
 assert.equal((await handler(request('123 Main',''))).status,401);
 assert.equal((await handler(request())).status,401);assert(!calls.some(c=>c.includes('/rpc/')));
});
test('quota denial prevents upstream requests',async()=>{
 const {fetcher,calls}=transport({quota:false});const response=await createAddressHandler(settings,fetcher)(request());
 assert.equal(response.status,429);assert(response.headers.has('retry-after'));assert(!calls.some(c=>c.includes('openrouteservice')));
});
test('provider quota and failures are sanitized',async()=>{
 for(const status of [429,403,500]) {
 const {fetcher}=transport({providerStatus:status}); const result=await createAddressHandler(settings,fetcher)(request());
 assert.equal(result.status,status===429?429:503);assert(!(await result.text()).includes('secret'));
 }
});
test('no results and foreign results yield an empty list',async()=>{
 for(const features of [[],[{...feature,properties:{...feature.properties,country_a:'CAN'}}]]) {
 const {fetcher}=transport({features});const result=await createAddressHandler(settings,fetcher)(request());
 assert.deepEqual(await result.json(),{suggestions:[]});
 }
});
test('invalid provider coordinates rejected',async()=>{
 const {fetcher}=transport({features:[{...feature,geometry:{type:'Point',coordinates:[999,42]}}]});
 assert.equal((await createAddressHandler(settings,fetcher)(request())).status,502);
});
test('timeouts and transport errors yield a sanitized error',async()=>{
 const fetcher:typeof fetch=async()=>{throw Error('provider-secret');};
 const result=await createAddressHandler(settings,fetcher)(request());assert.equal(result.status,503);assert(!(await result.text()).includes('secret'));
});
test('CORS preflight succeeds without credentials, GET is rejected',async()=>{
 const handler=createAddressHandler(settings);
 assert.equal((await handler(new Request('https://edge',{method:'OPTIONS'}))).status,200);
 assert.equal((await handler(new Request('https://edge'))).status,405);
});
test('Highschool uses the existing school directory and returns its official street address',async()=>{
 let providerCalls=0;
 const fetcher:typeof fetch=async(input,init)=>{
  const url=String(input);
  if(url.endsWith('/settings'))return Response.json({});
  if(url.includes('claim_address_request'))return Response.json({granted:true});
  if(url.endsWith('/search_schools')){
   assert.deepEqual(JSON.parse(String(init?.body)),{search_text:'Schaumburg High school',state_code:null});
   return Response.json([{name:'Schaumburg High School',address:'1100 W Schaumburg Rd',city:'Schaumburg',state:'IL',zip_code:'60194',latitude:42.027416,longitude:-88.106632}]);
  }
  providerCalls++;throw Error('Geocoder must not be needed');
 };
 const response=await createAddressHandler(settings,fetcher)(request('Schaumburg Highschool'));
 assert.equal(response.status,200);
 assert.deepEqual(await response.json(),{suggestions:[{label:'Schaumburg High School, 1100 W Schaumburg Rd, Schaumburg, IL, 60194',latitude:42.027416,longitude:-88.106632}]});
 assert.equal(providerCalls,0);
});
test('unavailable school directory falls back to geocoding with normalized words',async()=>{
 const fetcher:typeof fetch=async(input)=>{
  const url=String(input);
  if(url.endsWith('/settings'))return Response.json({});
  if(url.includes('claim_address_request'))return Response.json({granted:true});
  if(url.endsWith('/search_schools'))throw Error('Directory outage');
  assert.equal(new URL(url).searchParams.get('text'),'Schaumburg High school');
  return Response.json({features:[feature]});
 };
 const response=await createAddressHandler(settings,fetcher)(request('Schaumburg Highschool'));
 assert.equal(response.status,200);assert.equal((await response.json()).suggestions.length,1);
});
