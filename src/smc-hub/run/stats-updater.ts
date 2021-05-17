#!/usr/bin/env node

/*
Periodically update the stats in the database.
*/

import * as postgres from "smc-hub/postgres";

const ttl = parseInt(process.env.STATS_TTL_S ?? "300");
const db = postgres.db({
  ensure_exists: false,
});

function update() {
  console.log("updating stats...");
  db.get_stats({
    update: true,
    ttl,
    cb(err, stats) {
      if (err) {
        console.log(`failed to update stats -- ${err}`);
      } else {
        console.log("updated stats", stats);
      }
    },
  });
}

update();
setInterval(update, ttl * 1000);
