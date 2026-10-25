import { createCommunityHandler } from "./handler.ts";
Deno.serve(
  createCommunityHandler({
    url: Deno.env.get("SUPABASE_URL") ?? "",
    key: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  }),
);
