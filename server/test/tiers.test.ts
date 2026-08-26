/**
 * The two access predicates, pinned as an exhaustive table.
 *
 * These decide who gets Opus and who passes the spend ceiling, and they used
 * to be five separate `tier !== "free"` comparisons. The table below has to be
 * edited by hand when a tier is added, which is the point: a new tier must not
 * be able to inherit *yes* from a negation.
 */

import { describe, expect, it } from "vitest";
import { hasPremiumAccess, isPaying, type Tier } from "../src/appstore";
import { poolFor } from "../src/cache";

const TIERS: Record<Tier, { access: boolean; paying: boolean; pool: "free" | "premium" }> = {
  free: { access: false, paying: false, pool: "free" },
  monthly: { access: true, paying: true, pool: "premium" },
  yearly: { access: true, paying: true, pool: "premium" },
  lifetime: { access: true, paying: true, pool: "premium" },
};

describe("tier predicates", () => {
  for (const [tier, want] of Object.entries(TIERS) as [Tier, (typeof TIERS)[Tier]][]) {
    it(`answers ${tier} explicitly`, () => {
      expect(hasPremiumAccess(tier)).toBe(want.access);
      expect(isPaying(tier)).toBe(want.paying);
      expect(poolFor(tier)).toBe(want.pool);
    });
  }

  /**
   * Today nothing holds access without a purchase. Stating that as an
   * assertion means the day something does, this test names it — and every
   * `isPaying` call site has to be re-read before the table is changed.
   */
  it("has no tier granting access without a purchase", () => {
    const unfunded = (Object.keys(TIERS) as Tier[]).filter(
      (tier) => hasPremiumAccess(tier) && !isPaying(tier),
    );
    expect(unfunded).toEqual([]);
  });

  it("never routes an unpaid tier into the premium pool", () => {
    for (const tier of Object.keys(TIERS) as Tier[]) {
      if (poolFor(tier) === "premium") expect(hasPremiumAccess(tier)).toBe(true);
    }
  });
});
