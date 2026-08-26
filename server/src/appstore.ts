/**
 * Subscription verification against the App Store Server API.
 *
 * The trust model, because it is the point of this file: StoreKit hands the
 * app a `jwsRepresentation` whose header carries an `x5c` certificate chain.
 * Verifying that locally means X.509 chain validation up to Apple's root, and
 * Workers has no X.509 parser — hand-rolling chain validation in the code
 * that decides who gets paid features is the wrong place to invent security.
 *
 * So the JWS is treated as an *untrusted claim* about which subscription to
 * ask about. We decode it without verifying, pull `originalTransactionId`,
 * and then ask Apple directly over TLS with a request Apple authenticates.
 * The answer is authoritative because of who we asked, not because of a
 * signature we checked.
 */

export type Tier = "free" | "monthly" | "yearly" | "lifetime";

/**
 * Grants the premium *experience*: every window, go-deeper, the premium cache
 * pool, and the expensive model.
 *
 * Mirrors `Tier.hasPremiumAccess` in SpareCore, and is written as an
 * exhaustive switch rather than `tier !== "free"` for the same reason. A tier
 * that grants access without money behind it would inherit *yes* from
 * `!== "free"` at every call site, including the ones asking the other
 * question -- see `isPaying`. Adding a member must break this switch.
 */
export function hasPremiumAccess(tier: Tier): boolean {
  switch (tier) {
    case "free":
      return false;
    case "monthly":
    case "yearly":
    case "lifetime":
      return true;
  }
}

/**
 * There is a verified purchase behind this tier.
 *
 * This is the one that guards the global spend ceiling. The ceiling exists so
 * that a runaway month cannot outrun revenue, and the reason paying readers
 * pass through it is precisely that their requests are funded. A tier holding
 * access without a receipt is not funded and must stop at the ceiling like
 * anyone else.
 */
export function isPaying(tier: Tier): boolean {
  switch (tier) {
    case "free":
      return false;
    case "monthly":
    case "yearly":
    case "lifetime":
      return true;
  }
}

export interface VerifiedEntitlement {
  tier: Tier;
  /** Milliseconds since epoch. `null` for a non-expiring purchase. */
  expiresAt: number | null;
  originalTransactionId: string;
  /** Which Apple host answered. Useful in logs; sandbox is expected in dev. */
  environment: "production" | "sandbox";
}

export const FREE_ENTITLEMENT: VerifiedEntitlement = {
  tier: "free",
  expiresAt: null,
  originalTransactionId: "",
  environment: "production",
};

const PRODUCTION_HOST = "https://api.storekit.itunes.apple.com";
const SANDBOX_HOST = "https://api.storekit-sandbox.itunes.apple.com";

/**
 * Ten minutes. Apple rejects tokens whose `exp` is too far past `iat`, and
 * published guidance disagrees on whether the ceiling is 20 or 60 minutes —
 * this is inside both, and a short-lived token costs nothing to re-mint.
 */
const TOKEN_LIFETIME_SECONDS = 600;

export interface AppStoreConfig {
  keyId: string;
  issuerId: string;
  bundleId: string;
  /** PEM contents of the App Store Connect `.p8`. From a secret binding. */
  privateKeyPem: string;
}

/** Product identifiers, mirroring `ProductCatalog` in SpareCore. */
const PRODUCT_TIERS: Record<string, Tier> = {
  "app.spare.premium.monthly": "monthly",
  "app.spare.premium.yearly": "yearly",
  "app.spare.premium.lifetime": "lifetime",
};

/** Strongest wins, so a lifetime buyer with a lapsing subscription keeps it. */
const TIER_RANK: Record<Tier, number> = {
  free: 0,
  monthly: 1,
  yearly: 2,
  lifetime: 3,
};

function base64UrlToBytes(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(padded + "=".repeat((4 - (padded.length % 4)) % 4));
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function bytesToBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/**
 * Reads a JWS payload **without verifying it**.
 *
 * Named to make that impossible to miss at a call site. The only field taken
 * from here is the transaction id we are about to ask Apple about; nothing
 * read from this function is allowed to grant anything.
 */
export function decodeUnverifiedPayload(jws: string): Record<string, unknown> | null {
  const parts = jws.split(".");
  if (parts.length !== 3) return null;
  try {
    const json = new TextDecoder().decode(base64UrlToBytes(parts[1]));
    const parsed = JSON.parse(json);
    return typeof parsed === "object" && parsed !== null ? parsed : null;
  } catch {
    return null;
  }
}

/** Imports the `.p8` for ES256 signing. */
async function importSigningKey(pem: string): Promise<CryptoKey> {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  return crypto.subtle.importKey(
    "pkcs8",
    base64UrlToBytes(body.replace(/\+/g, "-").replace(/\//g, "_")),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

/**
 * Mints the bearer token for an App Store Server API request.
 *
 * Claim set confirmed against Apple's current documentation: ES256, `kid` in
 * the header, and `iss`/`iat`/`exp`/`aud`/`bid` in the payload with `aud`
 * fixed to `appstoreconnect-v1`. Getting `bid` wrong is the usual cause of a
 * 401 that looks like a key problem.
 */
export async function mintAppStoreToken(
  config: AppStoreConfig,
  now: number = Date.now(),
): Promise<string> {
  const issuedAt = Math.floor(now / 1000);
  const header = { alg: "ES256", kid: config.keyId, typ: "JWT" };
  const payload = {
    iss: config.issuerId,
    iat: issuedAt,
    exp: issuedAt + TOKEN_LIFETIME_SECONDS,
    aud: "appstoreconnect-v1",
    bid: config.bundleId,
  };

  const encoder = new TextEncoder();
  const signingInput = `${bytesToBase64Url(encoder.encode(JSON.stringify(header)))}.${bytesToBase64Url(
    encoder.encode(JSON.stringify(payload)),
  )}`;

  const key = await importSigningKey(config.privateKeyPem);
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    encoder.encode(signingInput),
  );
  return `${signingInput}.${bytesToBase64Url(new Uint8Array(signature))}`;
}

interface SubscriptionStatusResponse {
  data?: Array<{
    lastTransactions?: Array<{
      status?: number;
      signedTransactionInfo?: string;
    }>;
  }>;
}

/**
 * Statuses that mean "currently entitled".
 *
 * 1 active, 2 expired, 3 in billing retry, 4 in grace period, 5 revoked.
 * Grace period counts: the subscription is late, not cancelled, and cutting
 * someone off mid-grace for Apple's billing hiccup is the wrong default.
 * Billing retry does not — by then the renewal has already failed.
 */
const ENTITLING_STATUSES = new Set([1, 4]);

/**
 * Asks Apple about a transaction and derives the entitlement.
 *
 * Tries production, then sandbox. A TestFlight or sandbox purchase does not
 * exist on the production host, so without the fallback every internal build
 * reads as unsubscribed — which looks like a verification bug and is not one.
 */
export async function verifyEntitlement(
  jws: string,
  config: AppStoreConfig,
  fetcher: typeof fetch = fetch,
  now: number = Date.now(),
): Promise<VerifiedEntitlement> {
  const claim = decodeUnverifiedPayload(jws);
  const originalTransactionId =
    typeof claim?.originalTransactionId === "string" ? claim.originalTransactionId : null;
  if (!originalTransactionId) return FREE_ENTITLEMENT;

  // Deploying with only ANTHROPIC_API_KEY set is a legitimate first step: the
  // free tier works, and nothing reads the App Store secrets until a receipt
  // arrives. When one does, an unset secret would otherwise reach WebCrypto as
  // undefined and throw a TypeError, which the router rethrows as an unhandled
  // 500 — the app would show "something went wrong" for what is really a
  // half-finished deploy. Reported as a verification outage instead: still
  // failing closed to free, but retryable and named.
  if (!config.keyId || !config.issuerId || !config.bundleId || !config.privateKeyPem) {
    throw new AppStoreVerificationError(0, "unconfigured");
  }

  const token = await mintAppStoreToken(config, now);

  for (const [host, environment] of [
    [PRODUCTION_HOST, "production"],
    [SANDBOX_HOST, "sandbox"],
  ] as const) {
    const response = await fetcher(`${host}/inApps/v1/subscriptions/${originalTransactionId}`, {
      headers: { Authorization: `Bearer ${token}` },
    });

    if (response.status === 404) continue; // Not on this host; try the other.
    if (!response.ok) {
      // A 401 or 5xx is our problem, not the user's. Fail closed to free
      // rather than open to premium: an outage must not hand out paid
      // content, and the caller surfaces it as a retryable error.
      throw new AppStoreVerificationError(response.status, environment);
    }

    const body = (await response.json()) as SubscriptionStatusResponse;
    const entitlement = deriveEntitlement(body, originalTransactionId, environment, now);
    if (entitlement) return entitlement;
    return { ...FREE_ENTITLEMENT, originalTransactionId, environment };
  }

  return { ...FREE_ENTITLEMENT, originalTransactionId };
}

export class AppStoreVerificationError extends Error {
  constructor(
    readonly status: number,
    /**
     * Which host answered, or `"unconfigured"` when the App Store secrets are
     * not set and no host was asked. Carried so a log distinguishes "Apple is
     * down" from "this deploy is half finished" — the client sees the same
     * retryable error either way, but only one of them is fixed by waiting.
     */
    readonly environment: "production" | "sandbox" | "unconfigured",
  ) {
    super(`App Store verification failed with ${status} on ${environment}`);
    this.name = "AppStoreVerificationError";
  }
}

/** Picks the strongest currently-entitling transaction from a status response. */
export function deriveEntitlement(
  body: SubscriptionStatusResponse,
  originalTransactionId: string,
  environment: "production" | "sandbox",
  now: number,
): VerifiedEntitlement | null {
  let best: VerifiedEntitlement | null = null;

  for (const group of body.data ?? []) {
    for (const transaction of group.lastTransactions ?? []) {
      if (transaction.status === undefined || !ENTITLING_STATUSES.has(transaction.status)) continue;
      if (!transaction.signedTransactionInfo) continue;

      // Safe to decode without verifying: this whole response came from
      // Apple over an authenticated TLS request.
      const info = decodeUnverifiedPayload(transaction.signedTransactionInfo);
      const productId = typeof info?.productId === "string" ? info.productId : null;
      const tier = productId ? PRODUCT_TIERS[productId] : undefined;
      if (!tier) continue;

      const expiresRaw = info?.expiresDate;
      const expiresAt = typeof expiresRaw === "number" ? expiresRaw : null;
      // A subscription past its expiry is not entitling even if the status
      // field lags — statuses are computed when Apple last looked.
      if (expiresAt !== null && expiresAt <= now) continue;

      const candidate: VerifiedEntitlement = {
        tier,
        expiresAt: tier === "lifetime" ? null : expiresAt,
        originalTransactionId,
        environment,
      };
      if (!best || TIER_RANK[candidate.tier] > TIER_RANK[best.tier]) best = candidate;
    }
  }

  return best;
}
