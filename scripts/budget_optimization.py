#!/usr/bin/env python3
"""
Marketing budget optimization (Part 3).

Chooses one coupon per segment to maximise total net incremental revenue,
subject to a spending budget. Solved exactly as an integer linear program
(scipy.optimize.milp) and cross-checked by brute force when the scenario is small.

------------------------------------------------------------------------------
THE CONSTRAINTS (the default is the case-study scenario)
------------------------------------------------------------------------------
The optimizer takes four inputs; the built-in DEFAULT is the case-study scenario:
    budget       = $10,000
    populations  = VIPs 150, Bargain Hunters 350, Occasional Shoppers 500
    coupons      = [0, 5, 10, 20]         one is chosen per segment, in dollars
    lift         = tested incremental revenue per customer at each coupon:
                     VIPs               0 / 15 / 35 / 60
                     Bargain Hunters    0 / 12 / 18 / 22
                     Occasional         0 /  8 / 22 / 30
Two rules are always enforced: (1) exactly one coupon per segment, and
(2) total coupon spend must not exceed the budget.

------------------------------------------------------------------------------
GIVING NEW CONSTRAINTS (for future scenarios)
------------------------------------------------------------------------------
Change only the budget:
    python budget_optimization.py --budget 8000
Change everything with a JSON scenario file (see scenario.json for a template):
    python budget_optimization.py --config scenario.json
A scenario file overrides only the keys it lists; the rest keep the defaults.
The number of segments and coupon levels is NOT fixed, add or remove them freely:
    {
      "budget": 15000,
      "populations": {"VIPs": 200, "Bargain Hunters": 400, "Occasional Shoppers": 600},
      "coupons": [0, 5, 10, 15, 20],
      "lift": {"VIPs": {"0":0,"5":15,"10":35,"15":48,"20":60}, ...}
    }

------------------------------------------------------------------------------
REUSE (self-contained)
------------------------------------------------------------------------------
No data files are needed: the defaults are built in, so a teammate can run
`python budget_optimization.py` for the standard plan, or point --config at
their own scenario. The script prints the plan, a plain-language reading of it,
and writes the plan to <outputs-dir>/coupon_allocation.csv.
"""
import argparse, os, json, itertools
import numpy as np, pandas as pd

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The default constraint = the case-study scenario.
DEFAULT_SCENARIO = {
    "budget": 10000,
    "populations": {"VIPs": 150, "Bargain Hunters": 350, "Occasional Shoppers": 500},
    "coupons": [0, 5, 10, 20],
    "lift": {"VIPs":               {0: 0, 5: 15, 10: 35, 20: 60},
             "Bargain Hunters":    {0: 0, 5: 12, 10: 18, 20: 22},
             "Occasional Shoppers":{0: 0, 5: 8,  10: 22, 20: 30}},
}

def load_scenario(config_path, budget_override):
    """Start from the default constraints and override with the user's file / budget."""
    scenario = json.loads(json.dumps(DEFAULT_SCENARIO))                      # deep copy of the defaults
    if config_path:
        scenario.update(json.load(open(config_path)))                       # override the keys the file provides
    scenario["lift"] = {s: {int(k): v for k, v in d.items()} for s, d in scenario["lift"].items()}  # JSON keys -> int
    if budget_override is not None:
        scenario["budget"] = budget_override
    return scenario

def solve(scenario):
    """Return the optimal coupon per segment, plus net and cost. Works for any number of segments/coupons."""
    from scipy.optimize import milp, LinearConstraint, Bounds
    segments, coupons, budget = list(scenario["populations"]), scenario["coupons"], scenario["budget"]
    N, L = scenario["populations"], scenario["lift"]
    nS, nC = len(segments), len(coupons)
    net  = np.array([[N[s] * (L[s][c] - c) for c in coupons] for s in segments])   # net dollars per segment/coupon
    cost = np.array([[N[s] * c              for c in coupons] for s in segments])   # spend per segment/coupon
    one_per = np.zeros((nS, nS * nC))                                       # exactly one coupon per segment
    for i in range(nS): one_per[i, i * nC:(i + 1) * nC] = 1
    res = milp(c=-net.flatten(),                                           # maximise net = minimise negative net
               constraints=[LinearConstraint(one_per, lb=1, ub=1),
                            LinearConstraint(cost.flatten().reshape(1, -1), lb=0, ub=budget)],
               integrality=np.ones(nS * nC), bounds=Bounds(0, 1))          # each choice is 0/1 (integer LP)
    if not res.success:
        raise SystemExit("No feasible plan within the budget for this scenario.")
    x = res.x.reshape(nS, nC).round().astype(int)
    plan = {segments[i]: coupons[int(np.argmax(x[i]))] for i in range(nS)}
    net_total, cost_total = int(round(-res.fun)), int(round((cost.flatten() * res.x).sum()))
    if nC ** nS <= 200000:                                                 # cross-check with brute force when small
        best = max((sum(N[s] * (L[s][a[s]] - a[s]) for s in segments)
                    for combo in itertools.product(coupons, repeat=nS)
                    for a in [dict(zip(segments, combo))]
                    if sum(N[s] * a[s] for s in segments) <= budget), default=None)
        assert best == net_total, "integer program and brute force disagree"
    return segments, plan, net_total, cost_total

def main():
    ap = argparse.ArgumentParser(description="Marketing budget optimization (integer linear program).",
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("--config", default=None, help="JSON scenario file (populations, coupons, lift, budget)")
    ap.add_argument("--budget", type=int, default=None, help="override just the budget, in dollars")
    ap.add_argument("--outputs-dir", default=os.path.join(ROOT, "outputs"), help="where the plan is written")
    a = ap.parse_args(); os.makedirs(a.outputs_dir, exist_ok=True)

    scenario = load_scenario(a.config, a.budget)
    segments, plan, net_total, cost_total = solve(scenario)
    N, L, coupons, budget = scenario["populations"], scenario["lift"], scenario["coupons"], scenario["budget"]

    src = "default scenario" if (a.config is None and a.budget is None) else (a.config or f"--budget {a.budget}")
    print(f"Constraints: {src}  |  budget ${budget:,}  |  segments {N}  |  coupons {coupons}\n")
    print("Optimal coupon plan:")
    for s in segments:
        print(f"  {s:20s} coupon ${plan[s]:<3d} (spend ${N[s]*plan[s]:,}, net ${N[s]*(L[s][plan[s]]-plan[s]):,})")
    print(f"Total net incremental revenue: ${net_total:,}   |   spend ${cost_total:,} of the ${budget:,} budget")

    greedy = {s: max(coupons, key=lambda c: L[s][c] - c) for s in segments}  # best coupon per segment ignoring the budget
    greedy_cost = sum(N[s] * greedy[s] for s in segments)
    greedy_net = sum(N[s] * (L[s][greedy[s]] - greedy[s]) for s in segments)
    print("\nReading it:")
    print(f"  - Return on spend: {net_total/cost_total:.2f}x net (every $1 of coupon returns about ${(net_total+cost_total)/cost_total:.2f}).")
    print(f"  - ${budget-cost_total:,} of the budget is left unspent.")
    if greedy_cost > budget:
        trimmed = [s for s in segments if plan[s] < greedy[s]]
        print(f"  - The budget binds: the unconstrained best plan would cost ${greedy_cost:,} and earn ${greedy_net:,},")
        print(f"    so we trim {', '.join(trimmed)} (lowest return per extra dollar), giving up ${greedy_net-net_total:,} of net.")
    else:
        print("  - The budget does not bind: every segment already receives its own best coupon.")

    pd.DataFrame([{"segment": s, "population": N[s], "coupon": plan[s], "cost": N[s]*plan[s],
                   "net_revenue": N[s]*(L[s][plan[s]]-plan[s])} for s in segments]).to_csv(
        os.path.join(a.outputs_dir, "coupon_allocation.csv"), index=False)
    print(f"\nSaved the plan -> {a.outputs_dir}/coupon_allocation.csv")

    # for the default scenario, refresh results_summary.json if the other outputs exist
    seg_p, clv_p = os.path.join(a.outputs_dir, "customer_segments.csv"), os.path.join(a.outputs_dir, "clv_metrics.csv")
    if a.config is None and a.budget is None and os.path.exists(seg_p) and os.path.exists(clv_p):
        sc = pd.read_csv(seg_p)["segment"].value_counts(); m = pd.read_csv(clv_p).set_index("metric")["value"]
        summary = {"segment_sizes": {"vip": int(sc["VIPs"]), "bargain": int(sc["Bargain Hunters"]), "occasional": int(sc["Occasional Shoppers"])},
               "clv_test_error": {"rmse": float(m["test_rmse"]), "mae": float(m["test_mae"])},
               "coupon_per_customer": {"vip": plan["VIPs"], "bargain": plan["Bargain Hunters"], "occasional": plan["Occasional Shoppers"]},
               "expected_net_revenue": net_total}
        json.dump(summary, open(os.path.join(a.outputs_dir, "results_summary.json"), "w"), indent=2)
        print(f"Refreshed {a.outputs_dir}/results_summary.json")

if __name__ == "__main__":
    main()
