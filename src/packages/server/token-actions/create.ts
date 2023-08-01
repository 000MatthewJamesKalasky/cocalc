import type { Description } from "@cocalc/util/db-schema/token-actions";
import { generateToken } from "@cocalc/util/db-schema/token-actions";
import dayjs from "dayjs";
import getPool from "@cocalc/database/pool";
import siteURL from "@cocalc/server/settings/site-url";

export default async function createTokenAction(
  description: Description,
  expire?: Date
): Promise<string> {
  const pool = getPool();
  const token = generateToken();
  await pool.query(
    "INSERT INTO token_actions(token, expire, description) VALUES($1,$2,$3)",
    [token, expire ?? dayjs().add(3, "days").toDate(), description]
  );
  return token;
}

export async function disableDailyStatements(
  account_id: string
): Promise<string> {
  return await createTokenAction({
    type: "disable-daily-statements",
    account_id,
  });
}

export async function getTokenUrl(token: string): Promise<string> {
  return `${await siteURL()}/token?${token}`;
}
