import isValidAccount from "@cocalc/server/accounts/is-valid-account";
import { getPurchaseQuotas } from "./purchase-quotas";
import getBalance from "./get-balance";
import {
  Service,
  QUOTA_SPEC,
  MIN_CREDIT,
} from "@cocalc/util/db-schema/purchase-quotas";
import { GPT4_MAX_COST } from "@cocalc/server/openai/chatgpt";
import { currency } from "./util";

// Throws an exception if purchase is not allowed.  Code should
// call this before giving the thing and doing createPurchase.
// This is NOT part of createPurchase, since we could easily call
// createPurchase after providing the service.
// NOTE: user is not supposed to ever see these errors, in that the
// frontend should do the same checks and present an error there.
// This is a backend safety check.
interface Options {
  account_id: string;
  service: Service;
  cost?: number;
}

export async function isPurchaseAllowed({
  account_id,
  service,
  cost,
}: Options): Promise<{ allowed: boolean; reason?: string }> {
  if (!(await isValidAccount(account_id))) {
    return { allowed: false, reason: `${account_id} is not a valid account` };
  }
  if (QUOTA_SPEC[service] == null) {
    return {
      allowed: false,
      reason: `unknown service "${service}". The valid services are: ${Object.keys(
        QUOTA_SPEC
      ).join(", ")}`,
    };
  }
  if (cost == null) {
    cost = getCostEstimate(service);
  }
  if (cost == null) {
    return {
      allowed: false,
      reason: `cost estimate for service "${service}" not implemented`,
    };
  }
  if (!Number.isFinite(cost)) {
    return { allowed: false, reason: `cost must be finite` };
  }
  if (service == "credit") {
    if (cost > -MIN_CREDIT) {
      return {
        allowed: false,
        reason: `must credit account with at least ${currency(
          MIN_CREDIT
        )}, but you're trying to credit ${currency(-cost)}`,
      };
    }
    return { allowed: true };
  }

  if (cost <= 0) {
    // credit is specially excluded
    return { allowed: false, reason: `cost must be positive` };
  }
  const { services, global } = await getPurchaseQuotas(account_id);
  // First check that the overall quota is not exceeded
  const balance = await getBalance(account_id);
  if (balance + cost > global) {
    return {
      allowed: false,
      reason: `Insufficient quota.  balance + potential_cost > global quota.   ${currency(
        balance
      )} + ${currency(cost)} > ${currency(
        global
      )}.  Verify your email address, add credit, or contact support to increase your global quota.`,
    };
  }
  // Next check that the quota for the specific service is not exceeded
  const quotaForService = services[service];
  if (quotaForService == null) {
    return {
      allowed: false,
      reason: `You must explicitly set a quota for the "${
        QUOTA_SPEC[service]?.display ?? service
      }" service.`,
    };
  }
  // user has set a quota for this service.  is the total unpaid spend within this quota?
  // NOTE: This does NOT involve credits at all.  Even if the user has $10K in credits,
  // they can still limit their monthly spend on a particular service, as a safety.
  const balanceForService = await getBalance(account_id, service);
  if (balanceForService + cost > quotaForService) {
    return {
      allowed: false,
      reason: `Your quota ${currency(quotaForService)} for "${
        QUOTA_SPEC[service]?.display ?? service
      }" is not sufficient to make a purchase of up to ${currency(
        cost
      )} since you have a balance of ${currency(
        balanceForService
      )}.  Raise your ${
        QUOTA_SPEC[service]?.display ?? service
      } service quota or reduce your balance.`,
    };
  }

  // allowed :-)
  return { allowed: true };
}

export async function assertPurchaseAllowed(opts: Options) {
  const { allowed, reason } = await isPurchaseAllowed(opts);
  if (!allowed) {
    throw Error(reason);
  }
}

function getCostEstimate(service: Service): number | undefined {
  switch (service) {
    case "openai-gpt-4":
      return GPT4_MAX_COST;
    case "credit":
      return -MIN_CREDIT;
    default:
      return undefined;
  }
  return undefined;
}
