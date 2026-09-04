-- =========================================================================
-- Retail Analytics Capstone — Showcase Queries
-- BigQuery SQL | Data Analyst bootcamp capstone project
--
-- This is a curated selection from a larger project analyzing a
-- synthetic retail dataset (in-store device pings + transaction log).
-- Organized by business question rather than by original assignment
-- order. Table/column names and project IDs are placeholders — swap
-- `your-gcp-project.retail_capstone_2026` for your own dataset.
-- =========================================================================


-- #########################################################################
-- SECTION 1 — REVENUE & CUSTOMER SEGMENTATION
-- Who are the customers, how much are they worth, and are we retaining
-- them?
-- #########################################################################

-- ---------------------------------------------------------
-- Transaction count AND revenue by customer segmentation
-- (data source for two pie charts: one by count, one by sum(sale_amount))
-- NOTE: not_paying customers are excluded here - by
-- definition they never pay, so they'd always be an empty 0% slice.
-- no_app kept (shopper_id NULL).
-- ---------------------------------------------------------
WITH customer_roles AS (
  SELECT DISTINCT visitor_id, person_type
  FROM `your-gcp-project.retail_capstone_2026.device_pings`
  WHERE person_type IN ('repeat_customer', 'one_time_customer')
),

categorized_transactions AS (
  SELECT
    s.txn_id,
    s.sale_amount,
    CASE
      WHEN s.shopper_id IS NULL THEN 'no_app'
      WHEN cr.person_type = 'repeat_customer' THEN 'regular_customer'
      WHEN cr.person_type = 'one_time_customer' THEN 'occasional_customer'
    END AS customer_category
  FROM `your-gcp-project.retail_capstone_2026.transactions` s
  LEFT JOIN customer_roles cr ON s.shopper_id = cr.visitor_id
)

SELECT
  customer_category,
  COUNT(*) AS n_transactions,
  SUM(sale_amount) AS total_revenue
FROM categorized_transactions
WHERE customer_category IS NOT NULL
GROUP BY customer_category
ORDER BY n_transactions DESC;

-- ============================================================================
-- Occasional-but-returning customers (3+ visits): recency, frequency,
-- average basket size, and a four-quadrant customer investment/priority
-- matrix classification, all computed per customer in a single query
-- ============================================================================
-- For customers tagged as 'one_time_customer' in device_pings who nonetheless
-- visited 3+ times: shows each visit, days since join, and days since the
-- last visit relative to a fixed end-of-data date (2025-11-30). The
-- floor is 3 visits, not higher, because it doesn't need to be: the
-- most any customer in this segment visits over the whole study
-- period is 7, and most fall well short of that. 1-2 visit customers
-- are excluded not because they're one-time buyers, but because two
-- data points can't support a per-customer recency/frequency read.
--
-- The quadrant split itself (basket size vs. the group's own median,
-- crossed with a 30-day activity cutoff) is computed here rather than
-- downstream: the median comes from APPROX_QUANTILES on this same
-- customer set, so the threshold updates automatically if the
-- underlying data changes, instead of being a number hardcoded after
-- the fact. Only the chart that visualizes these quadrants is still
-- built downstream (see the RESULT comment below).

WITH one_time_customer_visits AS (
  SELECT
    s.shopper_id,
    DATE(s.event_ts) AS visit_date,
    subtotal AS basket_revenue
  FROM `your-gcp-project.retail_capstone_2026.transactions` s
  JOIN (
    SELECT DISTINCT visitor_id
    FROM `your-gcp-project.retail_capstone_2026.device_pings`
    WHERE person_type = 'one_time_customer'
  ) o ON s.shopper_id = o.visitor_id
),

customer_visit_counts AS (
  SELECT shopper_id, COUNT(*) AS n_visits
  FROM one_time_customer_visits
  GROUP BY shopper_id
  HAVING COUNT(*) >= 3
),

customer_last_visit AS (
  SELECT shopper_id, MAX(visit_date) AS last_visit_date
  FROM one_time_customer_visits
  GROUP BY shopper_id
),

customer_avg_basket AS (
  SELECT shopper_id, AVG(basket_revenue) AS avg_basket_size
  FROM one_time_customer_visits
  GROUP BY shopper_id
),

visit_gaps AS (
  SELECT
    shopper_id,
    visit_date,
    DATE_DIFF(
      visit_date,
      LAG(visit_date) OVER (PARTITION BY shopper_id ORDER BY visit_date),
      DAY
    ) AS days_between_visits
  FROM one_time_customer_visits
),

customer_median_gap AS (
  SELECT
    shopper_id,
    APPROX_QUANTILES(days_between_visits, 2)[OFFSET(1)] AS median_days_between_visits
  FROM visit_gaps
  WHERE days_between_visits IS NOT NULL
  GROUP BY shopper_id
),

per_customer AS (
  SELECT
    cvc.shopper_id,
    clv.last_visit_date,
    DATE_DIFF(DATE '2025-11-30', clv.last_visit_date, DAY) AS days_since_last_visit,
    cvc.n_visits AS total_visits,
    ROUND(cab.avg_basket_size, 2) AS avg_basket_size,
    cmg.median_days_between_visits
  FROM customer_visit_counts cvc
  JOIN customer_last_visit clv ON cvc.shopper_id = clv.shopper_id
  JOIN customer_avg_basket cab ON cvc.shopper_id = cab.shopper_id
  LEFT JOIN customer_median_gap cmg ON cvc.shopper_id = cmg.shopper_id
),

-- Median avg_basket_size across this same 149-customer set, derived
-- from the data rather than hardcoded - this is the "active top
-- spenders vs. cold low spenders" threshold used below.
basket_median AS (
  SELECT APPROX_QUANTILES(avg_basket_size, 2)[OFFSET(1)] AS median_basket_size
  FROM per_customer
)

SELECT
  pc.shopper_id,
  pc.last_visit_date,
  pc.days_since_last_visit,
  pc.total_visits,
  pc.avg_basket_size,
  pc.median_days_between_visits,
  bm.median_basket_size,
  -- Four-quadrant classification: basket size vs. the group median,
  -- crossed with a 30-day activity cutoff on days_since_last_visit.
  CASE
    WHEN pc.avg_basket_size >= bm.median_basket_size AND pc.days_since_last_visit <= 30
      THEN 'Active Top Spenders'
    WHEN pc.avg_basket_size >= bm.median_basket_size AND pc.days_since_last_visit > 30
      THEN 'Lapsed Top Spenders'
    WHEN pc.avg_basket_size < bm.median_basket_size AND pc.days_since_last_visit <= 30
      THEN 'Frequent Modest Spenders'
    ELSE 'Cold Low Spenders'
  END AS investment_quadrant
FROM per_customer pc
CROSS JOIN basket_median bm
ORDER BY pc.shopper_id;
-- RESULT (real data): 149 occasional customers have 3+ visits, with a
-- median avg_basket_size of NIS 317 (computed by the query itself, not
-- hardcoded). The investment_quadrant classification above reproduces
-- the four-quadrant customer investment/priority matrix directly in
-- SQL:
--   active top spenders     (basket >= median, active)   -> 40
--   lapsed top spenders     (basket >= median, inactive)  -> 35
--   frequent modest spenders (basket < median, active)    -> 35
--   cold low spenders       (basket < median, inactive)   -> 39
-- The four quadrants come back close to even - basket size and
-- continued activity aren't obviously correlated in this group. Visit
-- frequency (total_visits) drops off fast even within this
-- "returning" population: 93 of the 149 (62%) visited exactly 3
-- times, tapering to 34 at 4 visits, 18 at 5, and just 4 at 6-7. Only
-- the chart visualizing these quadrants is still built downstream
-- (see Tooling in the findings report).

-- ---------------------------------------------------------
-- KPI - Revenue concentration (Pareto / 80-20 check)
-- What % of total revenue comes from the top 10% of customers?
-- Tells you how dependent the business is on a small loyal core.
-- ---------------------------------------------------------
WITH customer_devices AS (
  SELECT DISTINCT visitor_id
  FROM `your-gcp-project.retail_capstone_2026.device_pings`
  WHERE person_type IN ('repeat_customer', 'one_time_customer')
),
customer_revenue AS (
  SELECT s.shopper_id, SUM(s.sale_amount) AS total_spent
  FROM `your-gcp-project.retail_capstone_2026.transactions` s
  JOIN customer_devices cd ON s.shopper_id = cd.visitor_id
  GROUP BY s.shopper_id
),
ranked AS (
  SELECT
    shopper_id,
    total_spent,
    NTILE(10) OVER (ORDER BY total_spent DESC) AS decile
    -- decile 1 = top 10% of spenders
  FROM customer_revenue
)
SELECT
  ROUND(SUM(CASE WHEN decile = 1 THEN total_spent ELSE 0 END) * 100.0
    / SUM(total_spent), 1) AS pct_revenue_from_top_10pct_customers
FROM ranked;

-- ---------------------------------------------------------
-- KPI - Customer lifetime value (over the observed period only)
-- SIMPLIFIED version: total revenue per repeat customer across the
-- whole dataset window. Not a true CLV (no repeat-purchase-
-- probability modeling, no time-value discounting) - just total
-- historical value observed so far. State this caveat if used.
-- ---------------------------------------------------------
WITH customer_devices AS (
  SELECT DISTINCT visitor_id
  FROM `your-gcp-project.retail_capstone_2026.device_pings`
  WHERE person_type = 'repeat_customer'
)
SELECT
  ROUND(AVG(total_spent), 2) AS avg_clv_repeat_customers,
  APPROX_QUANTILES(total_spent, 2)[OFFSET(1)] AS median_clv_repeat_customers
FROM (
  SELECT s.shopper_id, SUM(s.sale_amount) AS total_spent
  FROM `your-gcp-project.retail_capstone_2026.transactions` s
  JOIN customer_devices cd ON s.shopper_id = cd.visitor_id
  GROUP BY s.shopper_id
);

-- ---------------------------------------------------------
-- KPI - Churn / customer retention: are there regular customers
-- who dropped off over time? (satisfaction proxy)
-- Uses repeat_customer devices only - "regular customers abandoning
-- us" specifically means people who USED to visit often, not
-- one-time customers (who were never going to return anyway).
-- ---------------------------------------------------------

-- Version A - simple headline number: split the whole data period
-- into two halves, flag anyone active in the FIRST half but with
-- ZERO activity in the SECOND half as churned.
WITH date_bounds AS (
  SELECT
    MIN(DATE(event_ts)) AS min_d,
    MAX(DATE(event_ts)) AS max_d
  FROM `your-gcp-project.retail_capstone_2026.device_pings`
),
midpoint AS (
  SELECT DATE_ADD(min_d, INTERVAL DIV(DATE_DIFF(max_d, min_d, DAY), 2) DAY) AS mid_d
  FROM date_bounds
),
repeat_customer_activity AS (
  SELECT DISTINCT visitor_id, DATE(event_ts) AS activity_date
  FROM `your-gcp-project.retail_capstone_2026.device_pings`
  WHERE person_type = 'repeat_customer'
),
half_flags AS (
  SELECT
    a.visitor_id,
    MAX(CASE WHEN a.activity_date < m.mid_d THEN 1 ELSE 0 END) AS active_first_half,
    MAX(CASE WHEN a.activity_date >= m.mid_d THEN 1 ELSE 0 END) AS active_second_half
  FROM repeat_customer_activity a
  CROSS JOIN midpoint m
  GROUP BY a.visitor_id
)
SELECT
  COUNT(*) AS n_repeat_customers,
  COUNTIF(active_first_half = 1 AND active_second_half = 0) AS n_churned,
  ROUND(COUNTIF(active_first_half = 1 AND active_second_half = 0) * 100.0
    / COUNTIF(active_first_half = 1), 1) AS pct_churned_of_first_half_actives
FROM half_flags;
-- CAVEAT: a fixed 50/50 split is a blunt instrument - someone whose
-- last visit falls just before the midpoint looks identical to
-- someone who vanished at the very start of the period. Version B
-- below is more careful about WHEN exactly someone went quiet.

-- Version B - personalized: compare each customer's CURRENT gap
-- since their last visit to THEIR OWN typical historical gap between
-- visits, rather than a one-size-fits-all cutoff. A customer who
-- normally visits every 3 days going quiet for 2 weeks is a much
-- stronger signal than one who normally visits monthly.
WITH date_bounds AS (
  SELECT MAX(DATE(event_ts)) AS study_end_date
  FROM `your-gcp-project.retail_capstone_2026.device_pings`
),
repeat_customer_visits AS (
  -- one row per distinct day a repeat customer was seen (reuse this,
  -- or swap in the fuller visit-session logic elsewhere in the project
  -- for more precision if two visits happen on the same day)
  SELECT DISTINCT visitor_id, DATE(event_ts) AS visit_date
  FROM `your-gcp-project.retail_capstone_2026.device_pings`
  WHERE person_type = 'repeat_customer'
),
gaps AS (
  SELECT
    visitor_id,
    visit_date,
    DATE_DIFF(visit_date,
      LAG(visit_date) OVER (PARTITION BY visitor_id ORDER BY visit_date), DAY
    ) AS gap_days
  FROM repeat_customer_visits
),
customer_rhythm AS (
  SELECT
    visitor_id,
    COUNT(*) AS n_visits,
    AVG(gap_days) AS avg_gap_days,
    MAX(visit_date) AS last_visit_date
  FROM gaps
  GROUP BY visitor_id
  HAVING COUNT(*) >= 3  -- need enough history to establish a "normal rhythm"
                        -- at all - too few visits and this isn't meaningful
)
SELECT
  cr.visitor_id,
  cr.n_visits,
  ROUND(cr.avg_gap_days, 1) AS avg_gap_days,
  cr.last_visit_date,
  DATE_DIFF(db.study_end_date, cr.last_visit_date, DAY) AS days_since_last_visit,
  ROUND(DATE_DIFF(db.study_end_date, cr.last_visit_date, DAY)
    / NULLIF(cr.avg_gap_days, 0), 1) AS current_gap_vs_normal_rhythm_ratio
FROM customer_rhythm cr
CROSS JOIN date_bounds db
WHERE DATE_DIFF(db.study_end_date, cr.last_visit_date, DAY) > 3 * cr.avg_gap_days
  -- flag: currently quiet for 3x longer than their own typical gap
ORDER BY current_gap_vs_normal_rhythm_ratio DESC;
-- The 3x multiplier is a starting point, not a proven cutoff - tune
-- once you see the real distribution of ratios. Also worth noting:
-- anyone flagged near the very END of the study period might just be
-- "due for their next visit soon" rather than truly churned - there's
-- an unavoidable edge effect at the boundary of any finite dataset,
-- worth mentioning as a limitation rather than overclaiming certainty.

-- ---------------------------------------------------------
-- KPI - Churn, supporting proof: overall reach vs. weekly presence
-- Both Version A and B above come back near-zero churn for repeat
-- customers - this is why. Two-step comparison, on purpose:
-- Step 1 establishes each category's TOTAL distinct headcount over the
-- whole period (a person counted once, no matter how many times they
-- showed up). Step 2 re-counts the SAME categories WEEK BY WEEK. A
-- genuinely stable category (same people, every week) will show its
-- weekly count sitting right at its Step-1 total, week after week. A
-- rotating/churning category will sit well BELOW its own total, since
-- no single week captures everyone who ever appeared. Step 3 condenses
-- both into one row per category, so proving this doesn't require
-- eyeballing ~26 weekly rows per category.
-- This is what actually PROVES "repeat customers show up every single
-- week" rather than asserting it - the total from Step 1 and the
-- number in every weekly row of Step 2 are the same number, visibly,
-- not by coincidence. It also directly explains the regular_customer
-- -6.2% transaction-count finding further down: there's essentially
-- no one left to churn, so that decline has to be about existing
-- customers buying somewhat less often, not customers disappearing.
-- ---------------------------------------------------------

-- STEP 1: overall distinct headcount per category, whole period
SELECT
  CASE person_type
    WHEN 'repeat_customer' THEN 'regular_customer'
    WHEN 'one_time_customer' THEN 'occasional_customer'
    ELSE person_type
  END AS customer_category,
  COUNT(DISTINCT visitor_id) AS total_distinct_visitors
FROM `your-gcp-project.retail_capstone_2026.device_pings`
WHERE person_type IN ('repeat_customer', 'one_time_customer', 'not_paying')
GROUP BY customer_category
ORDER BY total_distinct_visitors DESC;

-- STEP 2: same categories, counted WEEK BY WEEK - excludes the
-- confirmed partial final week (same exclusion used in the weekly
-- revenue query below) so a short week doesn't look like a fake dip.
SELECT
  DATE_DIFF(DATE(event_ts), DATE('2025-06-01'), WEEK) + 1 AS week_number,
  CASE person_type
    WHEN 'repeat_customer' THEN 'regular_customer'
    WHEN 'one_time_customer' THEN 'occasional_customer'
    ELSE person_type
  END AS customer_category,
  COUNT(DISTINCT visitor_id) AS weekly_distinct_visitors
FROM `your-gcp-project.retail_capstone_2026.device_pings`
WHERE person_type IN ('repeat_customer', 'one_time_customer', 'not_paying')
  AND DATE(event_ts) < '2025-11-30'  -- excludes the confirmed partial final week
GROUP BY week_number, customer_category
ORDER BY customer_category, week_number;

-- STEP 3: the actual proof, condensed to one row per category - compares
-- each category's Step-1 total against the MIN and MAX weekly count it
-- ever hit. If min = max = the overall total, that category is proven
-- flat-identical every single week, no eyeballing required.
WITH overall AS (
  SELECT
    CASE person_type
      WHEN 'repeat_customer' THEN 'regular_customer'
      WHEN 'one_time_customer' THEN 'occasional_customer'
      ELSE person_type
    END AS customer_category,
    COUNT(DISTINCT visitor_id) AS total_distinct_visitors
  FROM `your-gcp-project.retail_capstone_2026.device_pings`
  WHERE person_type IN ('repeat_customer', 'one_time_customer', 'not_paying')
  GROUP BY customer_category
),
weekly AS (
  SELECT
    DATE_DIFF(DATE(event_ts), DATE('2025-06-01'), WEEK) + 1 AS week_number,
    CASE person_type
      WHEN 'repeat_customer' THEN 'regular_customer'
      WHEN 'one_time_customer' THEN 'occasional_customer'
      ELSE person_type
    END AS customer_category,
    COUNT(DISTINCT visitor_id) AS weekly_distinct_visitors
  FROM `your-gcp-project.retail_capstone_2026.device_pings`
  WHERE person_type IN ('repeat_customer', 'one_time_customer', 'not_paying')
    AND DATE(event_ts) < '2025-11-30'
  GROUP BY week_number, customer_category
),
weekly_range AS (
  SELECT
    customer_category,
    COUNT(*) AS n_weeks,
    MIN(weekly_distinct_visitors) AS min_weekly,
    MAX(weekly_distinct_visitors) AS max_weekly
  FROM weekly
  GROUP BY customer_category
)
SELECT
  o.customer_category,
  o.total_distinct_visitors,
  wr.n_weeks,
  wr.min_weekly,
  wr.max_weekly,
  CASE
    WHEN wr.min_weekly = wr.max_weekly AND wr.min_weekly = o.total_distinct_visitors
      THEN 'PERFECTLY FLAT - same people, every single week'
    ELSE 'varies week to week - rotating/partial population'
  END AS weekly_stability
FROM overall o
JOIN weekly_range wr ON o.customer_category = wr.customer_category
ORDER BY o.total_distinct_visitors DESC;

-- ---------------------------------------------------------
-- Weekly revenue over time - checking whether revenue follows the same
-- pattern as unique customer count
-- ---------------------------------------------------------
SELECT
  DATE_DIFF(DATE(event_ts), DATE('2025-06-01'), WEEK) + 1 AS week_number,
  DATE_TRUNC(DATE(event_ts), WEEK) AS week_start_date,
  ROUND(SUM(sale_amount), 2) AS weekly_revenue,
  COUNT(*) AS n_transactions
FROM `your-gcp-project.retail_capstone_2026.transactions`
WHERE DATE(event_ts) < '2025-11-30'  -- excludes the confirmed partial final week
GROUP BY week_number, week_start_date
ORDER BY week_number;

-- ---------------------------------------------------------
-- Weekly total revenue: trend, correlation, and statistical
-- significance. Tests whether total weekly revenue (pre-tax) is
-- trending down over time, using the same holiday exclusion and
-- Sunday-start weeks as the query above, so results are directly
-- comparable.
--
-- BigQuery has no native function to compute the statistical
-- significance (p-value) of a linear regression slope. CORR() and the
-- manual slope formula below give the trend direction and strength
-- (r, R²) in SQL; the p-value is computed downstream (e.g.
-- scipy.stats.linregress in Python) on this exact query's output.
-- ---------------------------------------------------------
WITH weekly_revenue AS (
  SELECT
    DATE_TRUNC(DATE(event_ts), WEEK(SUNDAY)) AS revenue_week,
    SUM(sale_amount) AS total_revenue  -- pre-tax revenue, consistent with the sales-per-labor-hour metric in Section 2
  FROM `your-gcp-project.retail_capstone_2026.transactions`
  WHERE DATE(event_ts) < '2025-11-30'  -- excludes the confirmed partial final week
    AND DATE_TRUNC(DATE(event_ts), WEEK(SUNDAY)) NOT IN ('2025-09-21', '2025-09-28')  -- excludes the two holiday weeks (Rosh Hashanah, Yom Kippur)
  GROUP BY revenue_week
),

weekly_indexed AS (
  SELECT
    revenue_week,
    total_revenue,
    ROW_NUMBER() OVER (ORDER BY revenue_week) AS week_index
  FROM weekly_revenue
)

-- Summary stats: slope, correlation, r-squared (see note above re: p-value)
SELECT
  COUNT(*) AS n_weeks,
  ROUND(AVG(total_revenue), 2) AS avg_weekly_revenue,
  ROUND(
    SAFE_DIVIDE(
      COUNT(*) * SUM(week_index * total_revenue) - SUM(week_index) * SUM(total_revenue),
      COUNT(*) * SUM(week_index * week_index) - POW(SUM(week_index), 2)
    ),
    2
  ) AS revenue_slope_per_week,
  ROUND(CORR(week_index, total_revenue), 4) AS correlation_r,
  ROUND(POW(CORR(week_index, total_revenue), 2), 4) AS r_squared
FROM weekly_indexed;
-- RESULT (real data, 24 non-holiday weeks): avg_weekly_revenue =
-- NIS 547,940.78, revenue_slope_per_week = -NIS 1,859.73/week
-- (-0.34%/week), correlation_r = -0.630, r_squared = 0.397, p=0.000967
-- (computed downstream in Google Sheets). That closely matches the decline
-- already found in total weekly transaction counts over the same
-- window (-7.5%, R2=0.415, p=0.0007) - consistent with revenue
-- falling mainly because transaction volume is falling, not because
-- average basket size is separately shrinking (confirmed FLAT below).
-- Decomposed by segment further below.

-- ---------------------------------------------------------
-- Weekly transaction count by customer category, including no_app -
-- a segment invisible to every prior regression in this project
-- (built entirely on device_pings, which structurally can't see
-- no_app customers - they only exist in transactions)
-- ---------------------------------------------------------
WITH categorized_sales AS (
  SELECT
    s.*,
    CASE
      WHEN g.visitor_id IS NULL THEN 'no_app'
      WHEN g.person_type = 'repeat_customer' THEN 'regular_customer'
      WHEN g.person_type = 'one_time_customer' THEN 'occasional_customer'
      ELSE g.person_type
    END AS customer_category,
    DATE_DIFF(DATE(s.event_ts), DATE('2025-06-01'), WEEK) + 1 AS week_number
  FROM `your-gcp-project.retail_capstone_2026.transactions` s
  LEFT JOIN (
    SELECT DISTINCT visitor_id, person_type
    FROM `your-gcp-project.retail_capstone_2026.device_pings`
  ) g
  ON g.visitor_id = s.shopper_id
  WHERE DATE(s.event_ts) < '2025-11-30'
)
SELECT
  week_number,
  customer_category,
  COUNT(*) AS n_transactions
FROM categorized_sales
GROUP BY week_number, customer_category
ORDER BY week_number, customer_category;
-- CONFIRMED (real data, holiday weeks excluded from the regression,
-- correct week-span methodology): avg basket size is FLAT (p=0.65,
-- not significant, -0.6% change) - the revenue decline is a
-- TRANSACTION-COUNT decline, not a basket-size decline. Broken down
-- by category, cumulative change over the ~24-26 week study window
-- (NOT a weekly rate, despite how that can read out of context):
-- no_app -11.2% (p=0.0096), occasional_customer -14.4% (p=0.0655,
-- borderline), regular_customer -6.2% (p=0.0018, highly significant).
-- In absolute terms (a real linear regression run directly on each
-- segment's weekly transaction counts, same p-values reproduced
-- exactly): no_app -0.67 transactions/week, occasional_customer -0.22
-- transactions/week, regular_customer -3.02 transactions/week - the
-- repeat segment's loss is the smallest by cumulative %, but the
-- largest in raw transactions/week, and by a wide margin (~4.5x
-- no_app, ~14x occasional_customer). IMPORTANT: this REFINES (does not
-- contradict) the earlier
-- finding that regular_customer's unique WEEKLY device count is
-- perfectly flat (352 exactly, 0% churn - see the Step 1/2/3 proof
-- above). These measure different things - unique weekly
-- participation (nobody drops out) vs total purchase frequency
-- (existing customers may be buying somewhat less often on average,
-- even though the same people keep showing up every week).

-- ---------------------------------------------------------
-- Per-customer weekly visit frequency trend (linear regression slope)
-- Fits a least-squares trend line to each repeat customer's own weekly
-- visit count, to check whether the aggregate -6.2% weekly decline
-- (see below) is concentrated in a distinct subgroup of customers, or
-- diffused broadly across the population.
--
-- Excludes the partial final week and the two holiday weeks
-- (2025-09-21 to 2025-10-04) from every customer's series - the same
-- anomalous windows excluded from the revenue-trend query above. Weeks
-- are bucketed Sunday-start (WEEK(SUNDAY)), consistent with the rest
-- of this file and with the Israeli business week the store actually
-- runs on, so the two holiday weeks fall exactly on the two
-- Sunday-start buckets 2025-09-21 and 2025-09-28 - the same dates
-- excluded in the revenue-trend query, with no partial-week boundary
-- issue to work around. A partial week would systematically deflate
-- whatever week_index lands on it and pull every customer's slope
-- more negative regardless of their real behavior, and the holiday
-- weeks add anomalous swings that inflate noise (lower R²) for the
-- same reason they're excluded from the revenue regression.
--
-- DELIBERATELY NOT CLASSIFIED: the query reports the raw slope and R²
-- per customer, with no "declining" / "stable" / "increasing" label.
-- No threshold does that job here, because the R² makes any such label
-- indefensible regardless of where a cutoff is drawn: across all 352
-- customers (holiday weeks and the partial final week excluded), R²
-- averages 0.048, medians 0.023, and tops out at 0.456 for a single
-- customer - only 15 of 352 even clear 0.2. A straight line explains
-- essentially none of any individual customer's own week-to-week
-- variation, so the honest output of this query is the raw slope and
-- R² per customer, with no classification layered on top.
-- ---------------------------------------------------------
WITH repeat_customers AS (
  SELECT DISTINCT visitor_id
  FROM `your-gcp-project.retail_capstone_2026.device_pings`
  WHERE person_type = 'repeat_customer'
),

visits AS (
  SELECT DISTINCT
    g.visitor_id AS shopper_id,
    DATE(g.event_ts) AS visit_date
  FROM `your-gcp-project.retail_capstone_2026.device_pings` g
  JOIN repeat_customers rc ON g.visitor_id = rc.visitor_id
  WHERE DATE(g.event_ts) < '2025-11-30'  -- excludes the confirmed partial final week (same cutoff used elsewhere in this file)
    AND DATE_TRUNC(DATE(g.event_ts), WEEK(SUNDAY)) NOT IN ('2025-09-21', '2025-09-28')  -- excludes the two holiday weeks (Rosh Hashanah, Yom Kippur), same dates and Sunday-start convention as the revenue-trend query above
),

weekly_visits AS (
  SELECT
    shopper_id,
    DATE_TRUNC(visit_date, WEEK(SUNDAY)) AS visit_week,
    COUNT(*) AS total_visits
  FROM visits
  GROUP BY shopper_id, visit_week
),

weekly_indexed AS (
  SELECT
    shopper_id,
    visit_week,
    total_visits,
    ROW_NUMBER() OVER (PARTITION BY shopper_id ORDER BY visit_week) AS week_index
  FROM weekly_visits
),

customer_trend AS (
  SELECT
    shopper_id,
    COUNT(*) AS n_weeks,
    ROUND(AVG(total_visits), 2) AS avg_weekly_visits,
    ROUND(
      SAFE_DIVIDE(
        COUNT(*) * SUM(week_index * total_visits) - SUM(week_index) * SUM(total_visits),
        COUNT(*) * SUM(week_index * week_index) - POW(SUM(week_index), 2)
      ),
      4
    ) AS visits_slope_per_week,
    -- How well a straight line actually describes THIS customer's own
    -- weeks, not just how steep it is - see note above on why this
    -- matters more than the slope threshold alone.
    ROUND(
      SAFE_DIVIDE(
        POW(COUNT(*) * SUM(week_index * total_visits) - SUM(week_index) * SUM(total_visits), 2),
        (COUNT(*) * SUM(week_index * week_index) - POW(SUM(week_index), 2))
          * (COUNT(*) * SUM(total_visits * total_visits) - POW(SUM(total_visits), 2))
      ),
      3
    ) AS r_squared
  FROM weekly_indexed
  GROUP BY shopper_id
)

SELECT
  shopper_id,
  n_weeks,
  avg_weekly_visits,
  visits_slope_per_week,
  r_squared
FROM customer_trend
ORDER BY r_squared DESC;
-- RESULT (352 customers, holiday weeks and the partial final week
-- excluded, n_weeks=24 for every customer):
-- R² mean=0.048, median=0.023, max=0.456 (one customer only), just 15
-- of 352 exceed 0.2 - even the BEST-fitting individual trend in the
-- whole customer base explained under half its own week-to-week
-- variation, alone at the top (second-best was R²=0.375), then a
-- steep drop-off into the 0.0-0.2 range where nearly everyone else
-- sat. Ordered by R² descending on purpose: read this table as "here's
-- how little any individual customer's own trend can be trusted," not
-- as a ranked list of people to act on.


-- #########################################################################
-- SECTION 2 — LOGISTICS OPTIMIZATION: STAFFING & SHIFTS
-- Are we staffed correctly by hour and day
-- #########################################################################

-- ---------------------------------------------------------
-- KPI - Sales per labor hour
-- Revenue generated per hour of ACTUAL staffed time (not guessed).
-- Labor hours come from a per-employee-per-day MIN/MAX of location
-- pings (see "Employee shifts" below for why that's a valid stand-in
-- for a real shift window: no employee has more than one shift a day,
-- and no shift crosses midnight).
-- ---------------------------------------------------------
WITH employee_daily_hours AS (
  SELECT
    visitor_id,
    DATE(event_ts) AS d,
    TIMESTAMP_DIFF(MAX(event_ts), MIN(event_ts), MINUTE) / 60.0 AS labor_hours
  FROM `your-gcp-project.retail_capstone_2026.device_pings`
  WHERE person_type IN (
    'manager', 'cashier', 'butcher', 'general_worker',
    'senior_general_worker', 'security_guy'
  )
  GROUP BY visitor_id, d
),
daily_labor AS (
  SELECT d, SUM(labor_hours) AS total_labor_hours
  FROM employee_daily_hours
  GROUP BY d
),
daily_revenue AS (
  SELECT DATE(s.event_ts) AS d, SUM(s.sale_amount) AS daily_revenue
  FROM `your-gcp-project.retail_capstone_2026.transactions` s
  GROUP BY d
)
SELECT
  r.d,
  r.daily_revenue,
  l.total_labor_hours,
  ROUND(r.daily_revenue / NULLIF(l.total_labor_hours, 0), 2) AS sales_per_labor_hour
FROM daily_revenue r
JOIN daily_labor l ON r.d = l.d
ORDER BY r.d;
-- Excludes delivery_guy from labor hours (they're not floor staff
-- serving customers) but keeps them excluded from revenue too (see
-- employee-exclusion pattern used throughout).

-- ---------------------------------------------------------
-- Employee shifts: daily presence window per employee.
-- Each employee's daily shift is taken as a simple MIN/MAX of that
-- day's location pings. This holds up because of two facts about the
-- data:
--   (1) no employee ever shows more than one detected shift on the
--       same calendar day - so there's no same-day boundary to find
--       (validated independently below via gap-detection on raw ping
--       timestamps);
--   (2) no shift can cross midnight in the first place - the store
--       isn't open overnight, so the gap between one day's last ping
--       and the next day's first is always large. This is a
--       structural guarantee from the store's operating hours.
-- ---------------------------------------------------------
SELECT
  visitor_id,
  person_type,
  DATE(event_ts) AS shift_date,
  MIN(event_ts) AS shift_start,
  MAX(event_ts) AS shift_end,
  TIMESTAMP_DIFF(MAX(event_ts), MIN(event_ts), MINUTE) AS shift_minutes
FROM `your-gcp-project.retail_capstone_2026.device_pings`
WHERE person_type IN (
  'manager', 'cashier', 'butcher', 'general_worker',
  'senior_general_worker', 'security_guy'
)  -- delivery_guy excluded - handled separately in an earlier check
GROUP BY visitor_id, person_type, shift_date
ORDER BY visitor_id, shift_start;

-- Check: confirms no employee ever has more than one detected shift
-- on the same calendar day. Run via independent LAG-based
-- gap-detection on raw ping timestamps rather than the per-day
-- MIN/MAX above, since a per-day GROUP BY can never produce more than
-- one row per employee per day by construction and so can't validate
-- itself.
WITH employee_pings AS (
  SELECT
    visitor_id, event_ts,
    LAG(event_ts) OVER (PARTITION BY visitor_id ORDER BY event_ts) AS prev_ts
  FROM `your-gcp-project.retail_capstone_2026.device_pings`
  WHERE person_type IN (
    'manager', 'cashier', 'butcher', 'general_worker',
    'senior_general_worker', 'security_guy'
  )
),
shifts_flagged AS (
  SELECT visitor_id, event_ts,
    CASE WHEN prev_ts IS NULL
      OR TIMESTAMP_DIFF(event_ts, prev_ts, MINUTE) > 100
    THEN 1 ELSE 0 END AS is_new_shift
  FROM employee_pings
),
shifts_numbered AS (
  SELECT visitor_id, event_ts,
    SUM(is_new_shift) OVER (PARTITION BY visitor_id ORDER BY event_ts) AS shift_id
  FROM shifts_flagged
),
shift_days AS (
  -- one row per detected shift, tagged with the calendar day it started
  SELECT visitor_id, shift_id, DATE(MIN(event_ts)) AS shift_date
  FROM shifts_numbered
  GROUP BY visitor_id, shift_id
)
SELECT COUNT(*) AS n_employee_days_with_multiple_shifts
FROM (
  SELECT visitor_id, shift_date
  FROM shift_days
  GROUP BY visitor_id, shift_date
  HAVING COUNT(*) > 1
);

-- Supporting check: distribution of the resulting daily shift
-- lengths - a pileup of very short days or absurdly long ones would
-- be a sign something's still off even after simplification (e.g. a
-- data gap, or a role that genuinely doesn't work standard shifts).
-- Also worth cross-checking shift_start/shift_end against the store's
-- known opening hours for that day of week.
WITH employee_daily AS (
  SELECT
    visitor_id,
    person_type,
    DATE(event_ts) AS shift_date,
    TIMESTAMP_DIFF(MAX(event_ts), MIN(event_ts), MINUTE) AS shift_minutes
  FROM `your-gcp-project.retail_capstone_2026.device_pings`
  WHERE person_type IN (
    'manager', 'cashier', 'butcher', 'general_worker',
    'senior_general_worker', 'security_guy'
  )
  GROUP BY visitor_id, person_type, shift_date
)
SELECT
  person_type,
  APPROX_QUANTILES(shift_minutes, 4) AS shift_length_quartiles_minutes,
  MIN(shift_minutes) AS shortest_shift,
  MAX(shift_minutes) AS longest_shift,
  COUNTIF(shift_minutes < 60) AS n_suspiciously_short_shifts,
  COUNTIF(shift_minutes > 14 * 60) AS n_suspiciously_long_shifts
FROM employee_daily
GROUP BY person_type;


-- ============================================================
-- Weekly Staffing Diagnostic: Transactions-per-Cashier Ratio
-- ============================================================
-- Goal: for every hour of the week, check whether the CURRENT staffing
-- level keeps the transactions-per-cashier ratio within a safe policy
-- range (not too high = risk of long waits; not too low = wasted labor
-- hours), and if not, recommend a whole-number staffing change.
-- ============================================================

WITH hourly_transactions AS (
  -- Raw transaction count per individual date and hour
  SELECT
    DATE(event_ts) AS d,
    EXTRACT(HOUR FROM event_ts) AS hour,
    EXTRACT(DAYOFWEEK FROM event_ts) AS day_num,  -- 1=Sunday ... 7=Saturday
    COUNT(*) AS n_transactions
  FROM `your-gcp-project.retail_capstone_2026.transactions`
  GROUP BY d, hour, day_num
),

hourly_cashiers AS (
  -- Distinct cashier headcount per individual date and hour, based on
  -- device_pings device pings tagged with person_type='cashier'
  SELECT
    DATE(event_ts) AS d,
    EXTRACT(HOUR FROM event_ts) AS hour,
    COUNT(DISTINCT visitor_id) AS n_cashiers
  FROM `your-gcp-project.retail_capstone_2026.device_pings`
  WHERE person_type = 'cashier'
  GROUP BY d, hour
),

daily_ratio AS (
  -- The REAL ratio for each specific date: that day's actual transaction
  -- count divided by that day's actual (unrounded) cashier headcount.
  -- Using an INNER JOIN here (not LEFT JOIN) is intentional: a ratio
  -- cannot be computed on a date with 0 cashiers tracked (division by
  -- zero), so those dates are necessarily excluded from this specific
  -- calculation. Note: this means avg_cashiers_current below reflects
  -- only staffed days, not a true blended average including zero-staff
  -- days - a separate, known limitation to flag rather than paper over.
  SELECT
    t.d,
    t.hour,
    t.day_num,
    t.n_transactions,
    c.n_cashiers,
    SAFE_DIVIDE(t.n_transactions, c.n_cashiers) AS ratio
  FROM hourly_transactions t
  JOIN hourly_cashiers c ON t.d = c.d AND t.hour = c.hour
  WHERE c.n_cashiers > 0
),

cell_stats AS (
  -- Aggregate across all historical dates for each (day-of-week, hour)
  -- combination. Both the median (stable, outlier-resistant) and the
  -- mean (more sensitive to variance) of the ratio are kept side by
  -- side and used as two independent safety checks, not one blended
  -- number - if either measure crosses its threshold, that's enough
  -- to flag a problem.
  SELECT
    day_num,
    CASE day_num
      WHEN 1 THEN 'Sunday' WHEN 2 THEN 'Monday' WHEN 3 THEN 'Tuesday'
      WHEN 4 THEN 'Wednesday' WHEN 5 THEN 'Thursday' WHEN 6 THEN 'Friday' END AS day_name,
    hour,
    COUNT(*) AS n_days_with_cashier,
    APPROX_QUANTILES(ratio, 100)[OFFSET(50)] AS median_ratio,
    AVG(ratio) AS mean_ratio,
    AVG(n_cashiers) AS avg_cashiers_current,
    -- Raw transaction volume, computed directly (NOT derived from the
    -- ratio) - kept purely as an independent sanity check: median_ratio
    -- should roughly equal median_transactions_RAW / current staff,
    -- give or take rounding. If it doesn't, something upstream broke.
    APPROX_QUANTILES(n_transactions, 100)[OFFSET(50)] AS median_transactions_RAW,
    AVG(n_transactions) AS mean_transactions_RAW
  FROM daily_ratio
  GROUP BY day_num, hour
),

with_recommendation AS (
  SELECT
    *,
    -- Back-solve two CANDIDATE recommended headcounts: given the
    -- CURRENT average headcount and the CURRENT ratio, infer the
    -- underlying typical transaction volume, then re-divide by the
    -- policy target (20 for the median measure, 25 for the mean
    -- measure) to get a new whole number of cashiers. CEIL() guarantees
    -- a real, staffable integer - never a fractional person. These are
    -- candidates, not the final answer - which one (or neither) gets
    -- used depends on staffing_status below (see the new_staff_ROUNDED
    -- logic further down), since blending them unconditionally would
    -- produce a headcount recommendation inconsistent with the label.
    CEIL(avg_cashiers_current * median_ratio / 20) AS new_staff_from_median,
    CEIL(avg_cashiers_current * mean_ratio / 25) AS new_staff_from_mean
  FROM cell_stats
),

classified AS (
  SELECT
    *,
    -- Classification logic (deliberately asymmetric, not the same rule
    -- applied to both directions):
    --  - UNDERSTAFFED if EITHER measure exceeds its ceiling (20 for
    --    median, 25 for mean) - a single bad signal is enough to flag
    --    risk, since understaffing is the costlier failure mode. This
    --    also does the outlier-accounting job on its own: the median
    --    ceiling catches a cell that's persistently busy on a typical
    --    day, the mean ceiling catches a cell where occasional outlier
    --    spikes push the average up even if most days look fine.
    --  - OVERSTAFFED only if the MEDIAN falls below the floor (12) - the
    --    mean is deliberately NOT part of this check. A single unusually
    --    quiet outlier day would drag the mean down without the typical
    --    day actually being slow, and cutting a cashier on that basis
    --    risks being caught short-staffed once the outlier passes. Since
    --    the whole reason the median is used elsewhere in this query is
    --    that it resists exactly that kind of outlier, recommending a
    --    reduction should rest on the median alone, not on a measure
    --    that a single quiet (or busy) day can swing on its own.
    --  - Otherwise OK - within the healthy operating band.
    --
    -- Where the 20/25 ceiling comes from (CONFIRMED, checked against two
    -- references, not picked round): the single busiest (day, hour) cell
    -- in the whole dataset averages 24.97 transactions/cashier/hour -
    -- right at the mean threshold, but individual cashier-hours elsewhere
    -- in this same dataset reach as high as ~60, so 25 sits well below
    -- what a cashier can actually process, not at some hard capacity
    -- wall. Separately, at 25/hour each transaction gets ~2.4 minutes
    -- end-to-end (60/25), which lines up closely with a published
    -- academic figure for European supermarket checkout throughput
    -- (~30 transactions/hour/cashier, cited in the full report) - a bit
    -- more conservative than that external benchmark, not detached from
    -- it.
    CASE
      WHEN median_ratio > 20 OR mean_ratio > 25 THEN 'UNDERSTAFFED - add a cashier'
      WHEN median_ratio < 12 THEN 'OVERSTAFFED - reduce a cashier'
      ELSE 'OK'
    END AS staffing_status
  FROM with_recommendation
)

SELECT
  day_num,
  day_name,
  hour,
  n_days_with_cashier,
  ROUND(median_transactions_RAW, 1) AS median_transactions_RAW,
  ROUND(mean_transactions_RAW, 1) AS mean_transactions_RAW,
  ROUND(median_ratio, 2) AS median_ratio,
  ROUND(mean_ratio, 2) AS mean_ratio,
  ROUND(avg_cashiers_current) AS current_staff_ROUNDED,
  staffing_status,
  -- Final recommended headcount: follows the SAME asymmetric rule as
  -- staffing_status, rather than blending both candidates
  -- unconditionally regardless of status (which would produce a
  -- recommendation inconsistent with the label above).
  -- UNDERSTAFFED takes the HIGHER of the two candidates - the more
  -- conservative/safer choice when the two measures disagree, since
  -- understaffing is the costlier mistake. OVERSTAFFED uses ONLY the
  -- median-based candidate, for the same outlier-resistance reason the
  -- classification above relies on the median alone: blending in the
  -- mean-based candidate here could silently raise the recommendation
  -- back toward (or above) current staff, undercutting a reduction the
  -- label itself says is warranted. OK cells get no change at all -
  -- the back-solved candidates target the 20/25 ceiling specifically,
  -- not the healthy band, so left unconditional they'd recommend a
  -- change even for a cell that's already fine.
  CASE
    WHEN staffing_status = 'UNDERSTAFFED - add a cashier'
      THEN GREATEST(new_staff_from_median, new_staff_from_mean)
    WHEN staffing_status = 'OVERSTAFFED - reduce a cashier'
      THEN new_staff_from_median
    ELSE ROUND(avg_cashiers_current)
  END AS new_staff_ROUNDED,
  CASE
    WHEN staffing_status = 'UNDERSTAFFED - add a cashier'
      THEN GREATEST(new_staff_from_median, new_staff_from_mean) - ROUND(avg_cashiers_current)
    WHEN staffing_status = 'OVERSTAFFED - reduce a cashier'
      THEN new_staff_from_median - ROUND(avg_cashiers_current)
    ELSE 0
  END AS staff_change
FROM classified
WHERE hour BETWEEN 7 AND 22  -- restrict to operating hours only
ORDER BY day_num, hour;


-- #########################################################################
-- SECTION 3 — DATA QUALITY: AUDITING A PUBLIC STORE REGISTRY
-- Cross-checking a public supermarket location registry against public
-- census data to catch credibility problems in the registry itself -
-- cities whose registered store count looks implausible for their
-- population, most likely reflecting gaps in how the registry is
-- maintained: duplicate listings, nameless placeholder entries, and
-- non-supermarket rows counted alongside real supermarkets.
-- #########################################################################

-- ---------------------------------------------------------
-- Population-to-registered-store ratio, built on a real data-cleaning
-- pipeline rather than the raw store registry: deduplicate near-
-- duplicate rows, sort stores into categories (chain supermarket vs.
-- independent vs. convenience/specialty, since only the first two
-- should count toward a credible "stores per city" figure), then
-- split cities into two tiers so that tiny settlements don't distort
-- the benchmark used to flag suspicious entries in bigger cities.
-- ---------------------------------------------------------

-- ============================================================
-- STEP 1: Deduplicate the raw store directory using a real-world
-- distance threshold (meters) via ST_DISTANCE on true geography points.
-- ============================================================

WITH base AS (
  SELECT *
  FROM `your-gcp-project.retail_capstone_2026.public_supermarket_directory`
  WHERE store_name != 'IT Computer Solutions' OR store_name IS NULL
),

-- Some rows carry a generic placeholder label instead of a real
-- brand/business store_name (e.g. "Stores", "Mini Market", "Kiosk",
-- "Supermarket", "Store", "Grocery", and their Hebrew equivalents
-- "מכולת", "מינימרקט", "חנות") - these show up across many
-- unrelated cities and are clearly fallback text, not an actual
-- shared store_name. Extend this array if you find other generic labels
-- (checking COUNT(DISTINCT city) per store_name is a good way to spot new
-- ones - a store_name spread across many unrelated cities is a red flag).
--
-- Generic names are clustered too, but only when both rows share the
-- same city AND that city's population is small: in a small town like
-- עדי, two rows both named "Mini Market" a few meters apart are very
-- likely the same store recorded twice, since a small place doesn't
-- have room for two unrelated unnamed shops that close together - the
-- opposite is true in a big city, so there generic-name rows are left
-- unmerged with each other. Real brand names, by contrast, cluster by
-- store_name + distance alone, ignoring city (that's what correctly
-- merges the "מחסני השוק" rows that straddle the בני ברק / רמת גן
-- border).
--
-- (Using inline array literals + IN UNNEST(...) instead of a CTE +
-- IN (SELECT ...), since BigQuery doesn't allow a subquery inside a
-- JOIN predicate.)

named_clusters AS (

  -- Case 1: genuine named rows (not null, not generic) - cluster by
  -- store_name + real distance, regardless of city.
  SELECT
    a.store_id,
    MIN(b.store_id) AS representative_id
  FROM base a
  JOIN base b
    ON a.store_name = b.store_name
    AND a.store_name IS NOT NULL
    AND a.store_name NOT IN UNNEST([
      'Stores', 'Store', 'Mini Market', 'Kiosk', 'Supermarket', 'Grocery',
      'מכולת', 'מינימרקט', 'חנות'
    ])
    AND ST_DISTANCE(
          ST_GEOGPOINT(a.longitude, a.latitude),
          ST_GEOGPOINT(b.longitude, b.latitude)
        ) <= 50  -- DEDUP_RADIUS_METERS: CONFIRMED. Distance only ever
          -- applies on TOP of an exact store_name match (never merges
          -- two different-named rows on proximity alone), and the
          -- resulting clusters were manually checked for the failure
          -- mode that matters most here - two genuinely distinct
          -- stores getting collapsed into one - and none were found.
          -- Not independently checked: true duplicates of the same
          -- store sitting just over 50m apart that stay unmerged
          -- (under-merging) - a lower-stakes miss than a false merge,
          -- but not ruled out by this check.
  GROUP BY a.store_id

  UNION ALL

  -- Case 2: generic placeholder names. Every such row always includes
  -- itself as a candidate (the `a.store_id = b.store_id` branch below), so it
  -- always has a representative even when no merge applies - it just
  -- ends up being its own representative, i.e. kept as-is. It only
  -- merges with a DIFFERENT row when that row shares the same exact
  -- city AND the city's population is at/below SMALL_TOWN_POPULATION.
  SELECT
    a.store_id,
    MIN(b.store_id) AS representative_id
  FROM base a
  JOIN base b
    ON a.store_name = b.store_name
    AND a.store_name IN UNNEST([
      'Stores', 'Store', 'Mini Market', 'Kiosk', 'Supermarket', 'Grocery',
      'מכולת', 'מינימרקט', 'חנות'
    ])
    AND a.city = b.city
    AND ST_DISTANCE(
          ST_GEOGPOINT(a.longitude, a.latitude),
          ST_GEOGPOINT(b.longitude, b.latitude)
        ) <= 50  -- same DEDUP_RADIUS_METERS as Case 1 - CONFIRMED there too
  LEFT JOIN `your-gcp-project.retail_capstone_2026.israel_census_public` pop
    ON a.city = pop.city_name
  WHERE
    a.store_id = b.store_id  -- always keep the trivial self-pair (guarantees every generic row has a representative)
    OR (pop.total_population IS NOT NULL AND pop.total_population <= 2000)  -- SMALL_TOWN_POPULATION cutoff = 2000
  GROUP BY a.store_id
),

deduplicated AS (
  SELECT b.*
  FROM base b
  LEFT JOIN named_clusters nc ON b.store_id = nc.store_id
  WHERE
    b.store_name IS NULL                     -- nameless rows always pass through
    OR b.store_id = nc.representative_id     -- everyone else: keep only the cluster's representative
),
-- ------------------------------------------------------------
-- STEP 2: Categorize each deduplicated row by store type via name
-- matching (chain brand list, specialty/convenience keyword lists) -
-- the population-per-store ratio should only count real supermarkets,
-- not cafes, kiosks, or gas-station convenience stores.
-- ------------------------------------------------------------
-- NOTE: no join to israel_census_public here - confirmed unused
-- downstream (city_store_counts below only needs store_category and
-- city). The population data is joined once, later, at the city-level
-- aggregate in the final SELECT - joining it again here, per-row,
-- would add nothing but a fan-out risk if israel_census_public ever
-- has more than one row per city_name.
final_categorized_cleaned AS (SELECT
  d.store_id,
  d.city,
  CASE
    WHEN REGEXP_CONTAINS(LOWER(IFNULL(d.store_name, '')), LOWER(
      r'שופרסל|shufersal|רמי לוי|rami levy|rami levi|ויקטורי|victory|' ||
      r'יוחננוף|yochananof|מגה|יינות ביתן|חצי חינם|טיב טעם|tiv taam|' ||
      r'אושר עד|osher ad|קואופ|co-op|coop|קרפור|carrefour|' ||
      r'מחסני השוק|am:pm|am pm|סופר יודה|super yuda|זול ובגדול|' ||
      r'פרש מרקט|פרשמרקט|fresh market|קופיקס|סופר ספיר|סופר דוש|' ||
      r'מחסני כמעט חינם|כמעט חינם|מחסני להב|מעיין 2000|מעין 2000|' ||
      r'מעיין אלפיים|maayan 2000|קשת טעמים|ניצת הדובדבן|יש בשכונה|' ||
      r'סופר ברקת|סטופמרקט|בר כל|יש חסד|מרקט בעיר|אדום ירוק|' ||
      r'שוק העיר|סופרטל|פוליצר|הכי זול|דבאח'
    )) THEN 'Chain Supermarket'
    WHEN REGEXP_CONTAINS(LOWER(IFNULL(d.store_name, '')), LOWER(
      r'^red$|קפה בכיכר|גרעיני עפולה|מעדני רוסמן|פיצוחי ענהאל|' ||
      r'זמורה אורגני|פיצוציה|לי-לו-לה|הפינה המתוקה|' ||
      r'פיצוח|קפה|מעדני|מעדנייה|ירקות|פירות|' ||
      r'ג\'יימס ריצ\'ארדסון|james richardson|' ||
      r'משקאות|שוקולד|coffee|מתוק'
    )) THEN 'Specialty Store'
    WHEN REGEXP_CONTAINS(LOWER(IFNULL(d.store_name, '')), LOWER(
      r'yellow|מנטה|menta|sogood|so good|אלונית|7-eleven|' ||
      r'^kiosk$|^stores$|seven express|קיוסק|' ||
      r'תחנת דלק מיקה|ten\+|דור אלון|^פז$'
    )) THEN 'Convenience Store'
    WHEN d.store_name IS NULL THEN 'Nameless'
    ELSE 'Small Independent Supermarket'
  END AS store_category
FROM deduplicated d
ORDER BY store_category, d.city),

-- ============================================================
-- Known limitation vs. "true" dedup:
-- This picks the min-store_id representative from *direct* pairs within
-- the radius, it does not compute full transitive closure. So if
-- A-B are 40m apart and B-C are 40m apart but A-C are 90m apart,
-- all three still collapse to one row (via B), which is usually
-- the desired behavior for point-of-sale dedup.

-- ------------------------------------------------------------
-- STEP 3: Aggregate by city - store counts per category, combined
-- supermarket totals, population ratios, and city-level census
-- metadata joined in.
-- ------------------------------------------------------------

city_store_counts AS (
  SELECT
    city,
    -- Category Breakdown
    COUNTIF(store_category = 'Chain Supermarket') AS count_chain_supermarkets,
    COUNTIF(store_category = 'Small Independent Supermarket') AS count_independent_supermarkets,
    COUNTIF(store_category = 'Convenience Store') AS count_convenience_stores,
    COUNTIF(store_category = 'Specialty Store') AS count_specialty_stores,
    COUNTIF(store_category = 'Nameless') AS count_nameless_stores,
    COUNT(*) AS count_total_all_stores,

    -- Combined Columns
    COUNTIF(store_category IN ('Chain Supermarket', 'Small Independent Supermarket')) AS total_supermarkets,
    COUNTIF(store_category = 'Chain Supermarket') AS chain_supermarkets_only

  FROM final_categorized_cleaned
  WHERE city IS NOT NULL
  GROUP BY city
)

SELECT
  c.city,

  -- Store breakdown columns
  c.count_chain_supermarkets,
  c.count_independent_supermarkets,
  c.count_convenience_stores,
  c.count_specialty_stores,
  c.count_nameless_stores,
  c.count_total_all_stores,

  -- Requested custom combined columns
  c.total_supermarkets,
  c.chain_supermarkets_only,

  -- Population Ratios:
  -- 1) People per total supermarket
  ROUND(SAFE_DIVIDE(pop.total_population, c.total_supermarkets), 2) AS pop_per_total_supermarket,

  -- 2) People per chain supermarket
  ROUND(SAFE_DIVIDE(pop.total_population, c.chain_supermarkets_only), 2) AS pop_per_chain_supermarket,

   -- All demographic info from the Lamas table
  pop.* EXCEPT (city_name)

FROM city_store_counts c
LEFT JOIN `your-gcp-project.retail_capstone_2026.israel_census_public` pop
  ON c.city = pop.city_name
ORDER BY pop.total_population;

-- ============================================================
-- REVERSED CHECK: does the registry cover every populated place, or
-- does it silently have ZERO listings for real cities? The ratio
-- query above can only ever produce a row for a city that already has
-- at least one registered store - it starts FROM the store registry
-- and joins population onto it. A city with no registered store at
-- all would just be absent from that result, not flagged.
--
-- This query starts from the census side instead and LEFT JOINs the
-- cleaned store registry onto it, so a populated place with literally
-- no registered store still shows up, with its store counts at 0
-- rather than silently missing from the output.
--
-- Same dedup + categorization pipeline as STEP 1/2 above, repeated
-- here since this is a standalone runnable query.
-- ============================================================

WITH base AS (
  SELECT *
  FROM `your-gcp-project.retail_capstone_2026.public_supermarket_directory`
  WHERE store_name != 'IT Computer Solutions' OR store_name IS NULL
),

named_clusters AS (
  SELECT
    a.store_id,
    MIN(b.store_id) AS representative_id
  FROM base a
  JOIN base b
    ON a.store_name = b.store_name
    AND a.store_name IS NOT NULL
    AND a.store_name NOT IN UNNEST([
      'Stores', 'Store', 'Mini Market', 'Kiosk', 'Supermarket', 'Grocery',
      'מכולת', 'מינימרקט', 'חנות'
    ])
    AND ST_DISTANCE(
          ST_GEOGPOINT(a.longitude, a.latitude),
          ST_GEOGPOINT(b.longitude, b.latitude)
        ) <= 50
  GROUP BY a.store_id

  UNION ALL

  SELECT
    a.store_id,
    MIN(b.store_id) AS representative_id
  FROM base a
  JOIN base b
    ON a.store_name = b.store_name
    AND a.store_name IN UNNEST([
      'Stores', 'Store', 'Mini Market', 'Kiosk', 'Supermarket', 'Grocery',
      'מכולת', 'מינימרקט', 'חנות'
    ])
    AND a.city = b.city
    AND ST_DISTANCE(
          ST_GEOGPOINT(a.longitude, a.latitude),
          ST_GEOGPOINT(b.longitude, b.latitude)
        ) <= 50
  LEFT JOIN `your-gcp-project.retail_capstone_2026.israel_census_public` pop
    ON a.city = pop.city_name
  WHERE
    a.store_id = b.store_id
    OR (pop.total_population IS NOT NULL AND pop.total_population <= 2000)
  GROUP BY a.store_id
),

deduplicated AS (
  SELECT b.*
  FROM base b
  LEFT JOIN named_clusters nc ON b.store_id = nc.store_id
  WHERE
    b.store_name IS NULL
    OR b.store_id = nc.representative_id
),

final_categorized_cleaned AS (
  SELECT
    d.store_id,
    d.city,
    CASE
      WHEN REGEXP_CONTAINS(LOWER(IFNULL(d.store_name, '')), LOWER(
        r'שופרסל|shufersal|רמי לוי|rami levy|rami levi|ויקטורי|victory|' ||
        r'יוחננוף|yochananof|מגה|יינות ביתן|חצי חינם|טיב טעם|tiv taam|' ||
        r'אושר עד|osher ad|קואופ|co-op|coop|קרפור|carrefour|' ||
        r'מחסני השוק|am:pm|am pm|סופר יודה|super yuda|זול ובגדול|' ||
        r'פרש מרקט|פרשמרקט|fresh market|קופיקס|סופר ספיר|סופר דוש|' ||
        r'מחסני כמעט חינם|כמעט חינם|מחסני להב|מעיין 2000|מעין 2000|' ||
        r'מעיין אלפיים|maayan 2000|קשת טעמים|ניצת הדובדבן|יש בשכונה|' ||
        r'סופר ברקת|סטופמרקט|בר כל|יש חסד|מרקט בעיר|אדום ירוק|' ||
        r'שוק העיר|סופרטל|פוליצר|הכי זול|דבאח'
      )) THEN 'Chain Supermarket'
      WHEN REGEXP_CONTAINS(LOWER(IFNULL(d.store_name, '')), LOWER(
        r'^red$|קפה בכיכר|גרעיני עפולה|מעדני רוסמן|פיצוחי ענהאל|' ||
        r'זמורה אורגני|פיצוציה|לי-לו-לה|הפינה המתוקה|' ||
        r'פיצוח|קפה|מעדני|מעדנייה|ירקות|פירות|' ||
        r'ג\'יימס ריצ\'ארדסון|james richardson|' ||
        r'משקאות|שוקולד|coffee|מתוק'
      )) THEN 'Specialty Store'
      WHEN REGEXP_CONTAINS(LOWER(IFNULL(d.store_name, '')), LOWER(
        r'yellow|מנטה|menta|sogood|so good|אלונית|7-eleven|' ||
        r'^kiosk$|^stores$|seven express|קיוסק|' ||
        r'תחנת דלק מיקה|ten\+|דור אלון|^פז$'
      )) THEN 'Convenience Store'
      WHEN d.store_name IS NULL THEN 'Nameless'
      ELSE 'Small Independent Supermarket'
    END AS store_category
  FROM deduplicated d
),

city_store_counts AS (
  SELECT
    city,
    COUNT(*) AS count_total_all_stores,
    COUNTIF(store_category IN ('Chain Supermarket', 'Small Independent Supermarket')) AS total_supermarkets
  FROM final_categorized_cleaned
  WHERE city IS NOT NULL
  GROUP BY city
)

-- THE REVERSED JOIN: every populated place in the census table, not
-- just places the store registry already knows about. NOTE this
-- assumes `israel_census_public` also carries a `napa` (sub-district)
-- column - used below only to flag the West Bank/PA sub-districts
-- this commercial registry never covers by construction, not as a
-- data-quality signal. TRIM() matters here - the real column comes
-- back with trailing whitespace ("חברון ", not "חברון").
SELECT
  pop.city_name,
  pop.napa,
  pop.total_population,
  COALESCE(c.count_total_all_stores, 0) AS count_total_all_stores,
  COALESCE(c.total_supermarkets, 0) AS total_supermarkets,
  TRIM(pop.napa) IN (
    'רמאללה', 'חברון', 'בית לחם', 'שכם', 'ג\'נין', 'טול כרם', 'ירדן )יריחו('
  ) AS is_west_bank_napa
FROM `your-gcp-project.retail_capstone_2026.israel_census_public` pop
LEFT JOIN city_store_counts c ON pop.city_name = c.city
ORDER BY pop.total_population DESC;
-- CONFIRMED (real output, 1,269 localities): only 332 have even one
-- registered store; 937 have zero. Of those 937, 135 (~537,000
-- people) sit in the seven West Bank/PA sub-districts above - out of
-- this registry's scope by construction, not a credibility problem
-- (this is the real number behind the exclusion noted in the full
-- project's report, not just the narrative claim). The remaining 802
-- (~1.61M people) are ordinary Israeli localities with zero listed
-- stores. Most are genuinely tiny (see the bucket breakdown below),
-- but 38 have 10,000+ residents and STILL show zero - see the chart
-- and bucket query below.

-- ---------------------------------------------------------
-- Population-bucket summary of the zero-store gap (West Bank/PA
-- sub-districts excluded - see is_west_bank_napa above). Reuses the
-- same pipeline; only the final SELECT differs.
-- ---------------------------------------------------------
SELECT
  CASE
    WHEN pop.total_population < 2000 THEN 'under 2,000'
    WHEN pop.total_population < 5000 THEN '2,000-5,000'
    WHEN pop.total_population < 10000 THEN '5,000-10,000'
    ELSE '10,000+'
  END AS population_bucket,
  COUNT(*) AS n_localities_with_zero_stores,
  SUM(pop.total_population) AS total_population_affected
FROM `your-gcp-project.retail_capstone_2026.israel_census_public` pop
LEFT JOIN city_store_counts c ON pop.city_name = c.city
WHERE COALESCE(c.count_total_all_stores, 0) = 0
  AND TRIM(pop.napa) NOT IN (
    'רמאללה', 'חברון', 'בית לחם', 'שכם', 'ג\'נין', 'טול כרם', 'ירדן )יריחו('
  )
GROUP BY population_bucket
ORDER BY MIN(pop.total_population);
-- CONFIRMED (real output): under 2,000 -> 693 localities, ~518,000
-- people (plausible - too small to expect a listed supermarket).
-- 2,000-10,000 -> 71 localities, ~311,000 people. 10,000+ -> 38
-- localities, ~782,000 people - real cities that size have grocery
-- stores; a registry showing zero for them is a coverage gap, not a
-- population fact.
--
-- Checked by hand: of those 38, all but 2 (Kfar Yona, Tzur Hadassah)
-- are Arab-Israeli or Bedouin towns/villages - a demographically
-- patterned gap, not scattered noise, which is a stronger and more
-- specific "is this registry credible" finding than the
-- population-per-store ratio check above. Widening the same check to
-- ALL cities with 10,000+ residents (not just the zero-store ones,
-- West Bank/PA still excluded): population predicts real-supermarket
-- count reasonably well (R²=0.76, ~1 supermarket per 6,400 residents
-- on the margin) - but 48 of those 140 cities (34%) sit at zero real
-- supermarkets regardless of population, well below what the trend
-- line would predict. See the chart in the report for this one -
-- it's a much clearer visual than a table of 140 rows.
