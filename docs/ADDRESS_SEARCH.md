# Street-address search

Start and End accept US street addresses with a city/state or ZIP. After 450 ms
without typing, up to five OpenRouteService/Pelias suggestions appear. Select a
suggestion to geocode that endpoint, then use the existing Compare routes action.
Coordinates, school-name lookup, map clicks and device location still work. Editing
a selected address invalidates that endpoint and its previous comparison. No
result is silently selected or assumed to be a school entrance.

Named schools use the existing nationwide NCES directory first, with the address
provider as fallback. Compound words such as `Highschool` are accepted as
`High School`. Directory results include the school's official street address,
city, state and ZIP. This avoids treating a missing geocoder venue as a missing
school. Explicit Set/Enter resolves a unique address result; multiple matches
remain visible for selection. A previously selected result retains its coordinates.

## Deployment

1. Apply `20261025223000_address_search_limits.sql` through the normal migration
   workflow (`supabase db push` against the intended project).
2. Enable geocoding/autocomplete on the existing OpenRouteService account. Check
   its current plan at https://openrouteservice.org/plans/ and API documentation
   at https://openrouteservice.org/dev/#/api-docs/geocode/autocomplete/get .
3. Keep `OPENROUTESERVICE_API_KEY` in Supabase Edge Function secrets, as with
   `route-directions`. Never put it in Flutter dart-defines or commit it. The
   platform supplies the server's Supabase URL and service role key.
4. Deploy `supabase functions deploy address-search`. Its project-key and optional
   user-session validation follow the existing routing proxy.
5. Test addresses in several states (including Alaska/Hawaii), ambiguous street
   names, no results, rate-limit recovery, and map-selected endpoints.

The fixed provider URL is `https://api.openrouteservice.org/geocode/autocomplete`,
with `boundary.country=USA` and at most five results. Search is not school-bound
or restricted to the current viewport. Coverage depends on provider data; choose
the correct city/state or use a map point. This uses the supported autocomplete
API, not public Nominatim.

## Budgets and privacy

Atomic shared budgets limit provider calls across Edge isolates: two per second,
20 per rolling minute and 400 per rolling day globally; 10/minute and 100/day per
hashed actor. Confirm these are below the deployed provider plan's current limits
and lower them if necessary. These are application caps, not provider guarantees.
Provider 429s and timeouts produce recoverable errors; quota-database failures
fail closed. Provider errors, URLs, keys and metadata are never returned.
Responses are `no-store`. No queries or coordinates are cached or stored by the
proxy; quota storage contains only actor hashes and timestamps. The geocoding
provider necessarily receives typed queries (minimum three characters). Do not
add address/request-body logging to analytics or Edge diagnostics.

Attribution: OpenRouteService/Pelias, OpenStreetMap contributors, OpenAddresses,
GeoNames and Who's On First. Confirm current provider attribution requirements.

## Checks

- `flutter analyze` and `flutter test`: service and autocomplete widget tests.
- `node --experimental-strip-types --test supabase/functions/address-search/handler_test.ts`:
  authentication, quota denial, US filtering, sanitization, malformed data,
  provider failures and empty results.
- `npm test --prefix supabase/tests`: disposable PostGIS, migrations, service-only
  permissions and second/minute/day budgets.
