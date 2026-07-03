# B&S Brand Performance Dashboard

A single-file GitHub Pages dashboard covering every brand we sell (own-brand excluded), built on the GA4 BigQuery export. Replaces and extends the Looker Studio brand report.

**Tabs:** Overview (KPIs, sortable brand league table with sparklines, top products) · Trends (any metric by brand over time + small-multiples grid for spotting changes at a glance) · Categories (category → sub-category drilldown with period deltas) · Products (rising/falling movers, "viewed but not bought" opportunities, searchable top 500) · Onsite Behaviour (view→ATC→checkout→buy funnel, funnel leak table by brand, engagement rates) · Brand Pages (/brands/ sessions trend, page breakdown, channel mix).

**Global controls:** date presets + custom range, compare vs previous period or same period last year, day/week/month granularity, and a brand ribbon — click any brand chip to filter the entire dashboard to it. Every table has CSV export.

## Setup (one-off, ~20 mins)

### 1. Build the aggregate tables
Run `sql/1_setup_and_backfill.sql` in the BigQuery console. It backfills from 1 April 2024 (edit `backfill_start` if you want more). This creates three small partitioned tables (`brand_item_daily`, `brand_daily`, `brand_pages_daily`) so the dashboard queries kilobytes instead of scanning `events_*` every page load — fast and near-free for the whole business.

### 2. Schedule the daily refresh
BigQuery → Scheduled queries → Create → paste `sql/2_daily_refresh_scheduled.sql` → run daily ~09:00 Europe/London (after the GA4 export lands). It rebuilds the last 4 days each run to catch late-arriving hits.

### 3. Create an OAuth client (no service account keys — fixes the secret-scanning problem)
Google Cloud console → APIs & Services → Credentials → Create credentials → **OAuth client ID** → Web application. Add your GitHub Pages origin (e.g. `https://dlawrence-bands.github.io`) to *Authorised JavaScript origins*. Paste the client ID into `CONFIG.OAUTH_CLIENT_ID` in `index.html`.

Users sign in with their own Google account — nothing sensitive lives in the repo, so it can stay public without keys getting invalidated.

### 4. Give the team access
Each user (or better, a Google Group like `data-dashboards@`) needs:
- **BigQuery Data Viewer** on the `analytics_287404213` dataset
- **BigQuery Job User** on the project

### 5. Deploy
Push `index.html` to the repo, enable GitHub Pages. Done.

## Preview without BigQuery
Set `CONFIG.DEMO_MODE = true` and open `index.html` locally — it renders with generated data so you can review layout/UX before wiring anything up.

## Config
Everything lives in the `CONFIG` object at the top of `index.html`: project/dataset/location, excluded brands (`Barker and Stonehouse` variants + `(not set)`), product row limit, top-N brands on the trend chart.

## Notes & next steps
- **Category quality** depends on `item_category` / `item_category2` being populated in the GA4 item payload. If they're patchy, the fix is a `LEFT JOIN` in the setup SQL to `bs_product_attributes` on `item_id = mpn` to backfill categories from the feed — happy to add that if you spot gaps.
- **Product feed enrichment** (price, stock status, lead time) could be joined into `brand_item_daily` the same way — would enable "out of stock but still getting views" alerts.
- **Brand search terms** (the Search Console table in the old report): turn on the free GSC → BigQuery bulk export, and a Search tab can be added querying `searchdata_url_impression` filtered to `/brands/` URLs and brand-name queries.
- Data excludes today (yesterday is the latest complete day).
