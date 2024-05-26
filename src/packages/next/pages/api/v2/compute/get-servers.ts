/*
Get compute servers
*/

import getAccountId from "lib/account/get-account";
import getServers from "@cocalc/server/compute/get-servers";
import getParams from "lib/api/get-params";

async function handle(req, res) {
  try {
    res.json(await get(req));
  } catch (err) {
    res.json({ error: `${err.message}` });
    return;
  }
}

async function get(req) {
  const account_id = await getAccountId(req);
  if (!account_id) {
    throw Error("must be signed in");
  }
  const { project_id, id } = getParams(req, {
    allowGet: true,
  });
  return await getServers({
    account_id,
    project_id,
    id,
  });
}

import { apiRoute, apiRouteOperation, z } from "lib/api";

const serversSchema = z.object({
  id: z.number(),
  title: z.string(),
});

export default apiRoute({
  computeGetServers: apiRouteOperation({
    method: "GET",
  })
    .input({
      contentType: "application/json",
      body: z
        .object({
          project_id: z.string().optional(),
          id: z.number().optional(),
        })
        .describe("Parameters that restrict compute servers to get."),
    })
    .outputs([
      {
        status: 200,
        contentType: "application/json",
        body: z.array(serversSchema),
      },
    ])
    .handler(handle),
});
