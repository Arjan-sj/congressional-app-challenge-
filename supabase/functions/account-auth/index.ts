// Retired endpoint: the application now uses anonymous community contributions.
Deno.serve(() =>
  new Response(
    JSON.stringify({
      error:
        "This endpoint has been retired. Update SafeRoutes to use community contributions.",
    }),
    {
      status: 410,
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers":
          "apikey,authorization,content-type,x-client-info",
        "Cache-Control": "no-store",
      },
    },
  )
);
