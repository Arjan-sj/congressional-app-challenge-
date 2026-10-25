import { createRouteHandler } from "./handler.ts";

Deno.serve(createRouteHandler({
  supabaseUrl: Deno.env.get("SUPABASE_URL") ?? "",
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  orsKey: Deno.env.get("OPENROUTESERVICE_API_KEY") ?? "",
}));
