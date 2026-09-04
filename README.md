# Retail Analytics — SQL Showcase

BigQuery SQL from a data analyst capstone project analyzing a synthetic retail dataset (in-store device pings + a transaction log). This is a curated subset of a larger project, organized around three business questions rather than the original assignment structure.

## Section 1 — Revenue & Customer Segmentation
Who are the customers, what are they worth, and are we retaining them? (Full numbers and narrative for everything below: [findings report](./retail_analytics_findings.md).)
- Customer mix by transaction count and revenue (repeat / one-time / no-app)
- Recency, frequency, and average basket size for occasional-but-returning customers (3+ visits) — inputs for a customer investment/priority matrix that splits customers into four quadrants by basket size (above/below the group median) and current activity (active in the last 30 days vs. gone quiet)
- Revenue concentration (Pareto / 80–20 check)
- Simplified customer lifetime value
- Churn: two independent checks, cross-validated against each other, plus a supporting proof of *why* both come back near zero
  - **Version A** (headline number) — repeat customers active in the first half of the period with zero activity in the second half
  - **Version B** (personalized) — flags a customer only when they're currently quiet for 3x longer than *their own* typical gap between visits, rather than applying one fixed cutoff to everyone
  - **Supporting proof** — a three-step check (overall headcount per category → the same headcount broken out week by week → a one-row-per-category comparison of the two) showing whether repeat customers are actually disappearing week to week, or whether a separately-observed decline in purchase frequency has some other explanation
- Weekly revenue over time, plus a dedicated trend/correlation query (slope, r, and R² computed directly in BigQuery, since it's a single aggregate fit rather than one-per-customer) — and the same trend broken out by customer category in number of transactions, to isolate which segment is driving it
- Per-customer weekly visit frequency trend (a least-squares regression slope + R², computed per customer, in SQL, deliberately left unclassified — no threshold, no "declining" label) — checks whether the aggregate decline is concentrated in a distinct subgroup of customers or diffused broadly across the population
  - **Why there's no classification threshold:** relative to these customers' own visit-frequency baseline, even a small weekly shift would be real and non-trivial — but the per-customer R² is too low, almost across the board, to make a "declining" label defensible at any cutoff. The query reports the raw slope and R² per customer and stops there — no label, no list.

## Section 2 — Logistics Optimization: Staffing & Shifts
Are we staffed correctly by hour and day? (Full numbers and narrative: [findings report](./retail_analytics_findings.md).)
- Sales per labor hour, built on top of detected employee shifts (gap-detection from location pings, since there's no clock-in/out data)
- Employee shift-window detection + a sanity check on the resulting shift-length distribution
- Weekly staffing diagnostic: transactions-per-cashier ratio by hour and day of week, with a rule-based recommended headcount change (add/reduce/OK) — net effect across the week: about 55 fewer cashier-hours scheduled, roughly 1.4 full-time positions' worth

## Section 3 — Data Quality: Auditing a Public Store Registry
Cross-checking a public supermarket location registry against public census data to catch credibility problems in the registry itself. (Full numbers and narrative: [findings report](./retail_analytics_findings.md).)
- A full data-cleaning pipeline before any city is flagged:
  1. **Deduplicate** the raw store registry using real-world distance (BigQuery GIS `ST_DISTANCE`) instead of naive lat/lon rounding, which either wrongly splits or wrongly merges nearby points — real brand names cluster by name + distance alone, but generic placeholder names (e.g. "Mini Market," "מכולת") only cluster when they also share a city_name, and only if that city is actually small enough settlement that two close-together unnamed shops are more likely one store recorded twice than two unrelated ones
  2. **Sort by store type** — classify each row as chain supermarket / independent supermarket / convenience / specialty / nameless via name matching, since a population-per-store ratio is meaningless if it's counting cafes and gas-station kiosks alongside real supermarkets
- Population-per-registered-store ratio, run on the cleaned/categorized data from the pipeline above, to surface cities whose store count looks implausible for their population — candidates for a manual listing check
- **Reversed join — does the registry cover every populated place, or is it just silent about the ones it's missing?** The ratio check above can only produce a row for a city that already has at least one registered store; a city with zero would simply be absent from the output, not flagged. A second query starts from the census side instead (every populated place, LEFT JOIN the cleaned registry onto it) so a true zero shows up as a zero rather than a missing row — see [findings](./retail_analytics_findings.md) for what the real output reveals about where those zeros fall.

## Notes
- Table/column names and the project ID (`your-gcp-project.retail_capstone_2026`) are placeholders — swap in your own BigQuery project and dataset to run these.
- The underlying dataset is synthetic, built for a bootcamp capstone exercise.
- This is a subset of a larger project; queries were selected to each demonstrate a distinct technique (window functions, gap-detection via `LAG`, quantile-based benchmarking, BigQuery GIS, cohort-style churn logic) rather than to reproduce every analysis from the original assignment.
- Everything downstream of BigQuery (every p-value, two fits that aren't backed by a query here at all, and every chart image) was originally built in Google Sheets, except the customer-investment-matrix chart, which was built in Python. (The customer-investment-matrix quadrant split itself is computed directly in the SQL — see **Tooling** at the end of [the findings report](./retail_analytics_findings.md) for the chart tooling and the recommended Python equivalent (`pandas` + `scipy.stats` + `matplotlib`) for the rest.)
