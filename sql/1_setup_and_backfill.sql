-- ============================================================
-- B&S BRAND PERFORMANCE DASHBOARD — SETUP + BACKFILL
-- Project:  commanding-air-450109-p0
-- Dataset:  analytics_287404213 (europe-west2)
-- Run once in the BigQuery console. Adjust @backfill start if needed.
--
-- Why aggregate tables instead of querying events_* live:
--   * The dashboard loads in <2s for everyone, every time
--   * Query cost drops from GBs per page-load to ~KBs
--   * The whole business can hammer it without racking up spend
-- ============================================================

DECLARE backfill_start DATE DEFAULT DATE '2024-04-01';

-- ------------------------------------------------------------
-- 1. ITEM-GRAIN DAILY: brand x category x product funnel + revenue
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE `commanding-air-450109-p0.analytics_287404213.brand_item_daily`
PARTITION BY date
CLUSTER BY brand, category
AS
SELECT
  PARSE_DATE('%Y%m%d', e._TABLE_SUFFIX) AS date,
  COALESCE(NULLIF(TRIM(i.item_brand), ''), a.brand, '(not set)')      AS brand,
  COALESCE(NULLIF(TRIM(i.item_category), ''), '(not set)')   AS category,
  COALESCE(NULLIF(TRIM(i.item_category2), ''), '(not set)')  AS subcategory,
  i.item_id                                                  AS item_id,
  ANY_VALUE(i.item_name)                                     AS item_name,
  COUNTIF(e.event_name = 'view_item')                        AS item_views,
  COUNTIF(e.event_name = 'add_to_cart')                      AS add_to_carts,
  COUNTIF(e.event_name = 'begin_checkout')                   AS checkouts,
  COUNTIF(e.event_name = 'purchase')                         AS purchase_events,
  SUM(IF(e.event_name = 'purchase', i.quantity, 0))          AS items_purchased,
  ROUND(SUM(IF(e.event_name = 'purchase', i.item_revenue, 0)), 2) AS item_revenue,
  COUNT(DISTINCT IF(e.event_name = 'purchase',
      e.ecommerce.transaction_id, NULL))                     AS transactions
FROM `commanding-air-450109-p0.analytics_287404213.events_*` e,
UNNEST(e.items) i
LEFT JOIN (SELECT mpn, ANY_VALUE(brand) AS brand
           FROM `commanding-air-450109-p0.analytics_287404213.bs_product_attributes`
           GROUP BY mpn) a ON i.item_id = a.mpn
WHERE e._TABLE_SUFFIX >= FORMAT_DATE('%Y%m%d', backfill_start)
  AND e.event_name IN ('view_item','add_to_cart','begin_checkout','purchase')
  AND i.item_id IS NOT NULL
GROUP BY date, brand, category, subcategory, item_id;

-- ------------------------------------------------------------
-- 2. BRAND-GRAIN DAILY: session-scoped metrics per brand
--    (a session counts for a brand if it viewed >=1 of its products)
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE `commanding-air-450109-p0.analytics_287404213.brand_daily`
PARTITION BY date
CLUSTER BY brand
AS
WITH brand_sessions AS (
  SELECT
    PARSE_DATE('%Y%m%d', e._TABLE_SUFFIX) AS date,
    COALESCE(NULLIF(TRIM(i.item_brand), ''), a.brand, '(not set)') AS brand,
    CONCAT(e.user_pseudo_id, '.',
      CAST((SELECT value.int_value FROM UNNEST(e.event_params)
            WHERE key = 'ga_session_id') AS STRING))       AS session_id,
    MAX(CAST((SELECT value.int_value FROM UNNEST(e.event_params)
            WHERE key = 'session_engaged') AS INT64))      AS engaged,
    COUNT(DISTINCT IF(e.event_name = 'purchase',
            e.ecommerce.transaction_id, NULL))             AS txns
  FROM `commanding-air-450109-p0.analytics_287404213.events_*` e,
  UNNEST(e.items) i
  LEFT JOIN (SELECT mpn, ANY_VALUE(brand) AS brand
             FROM `commanding-air-450109-p0.analytics_287404213.bs_product_attributes`
             GROUP BY mpn) a ON i.item_id = a.mpn
  WHERE e._TABLE_SUFFIX >= FORMAT_DATE('%Y%m%d', backfill_start)
    AND e.event_name IN ('view_item','add_to_cart','begin_checkout','purchase')
  GROUP BY date, brand, session_id
)
SELECT
  date,
  brand,
  COUNT(DISTINCT session_id)                    AS sessions,
  COUNT(DISTINCT IF(engaged = 1, session_id, NULL)) AS engaged_sessions,
  SUM(txns)                                     AS transactions
FROM brand_sessions
GROUP BY date, brand;

-- ------------------------------------------------------------
-- 3. BRAND PAGES DAILY: /brands/* landing + browsing behaviour
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE `commanding-air-450109-p0.analytics_287404213.brand_pages_daily`
PARTITION BY date
CLUSTER BY brand_slug
AS
WITH pv AS (
  SELECT
    PARSE_DATE('%Y%m%d', e._TABLE_SUFFIX) AS date,
    REGEXP_EXTRACT(
      (SELECT value.string_value FROM UNNEST(e.event_params) WHERE key = 'page_location'),
      r'https?://[^/]+(/brands/[^?#]*)') AS page_path,
    CONCAT(e.user_pseudo_id, '.',
      CAST((SELECT value.int_value FROM UNNEST(e.event_params)
            WHERE key = 'ga_session_id') AS STRING)) AS session_id,
    COALESCE(e.session_traffic_source_last_click
               .cross_channel_campaign.default_channel_group,
             'Unassigned') AS channel_group,
    CAST((SELECT value.int_value FROM UNNEST(e.event_params)
          WHERE key = 'session_engaged') AS INT64) AS engaged
  FROM `commanding-air-450109-p0.analytics_287404213.events_*` e
  WHERE e._TABLE_SUFFIX >= FORMAT_DATE('%Y%m%d', backfill_start)
    AND e.event_name = 'page_view'
)
SELECT
  date,
  page_path,
  REGEXP_EXTRACT(page_path, r'^/brands/([^/?#]+)') AS brand_slug,
  channel_group,
  COUNT(DISTINCT session_id) AS sessions,
  COUNT(DISTINCT IF(engaged = 1, session_id, NULL)) AS engaged_sessions,
  COUNT(*) AS page_views
FROM pv
WHERE page_path LIKE '/brands%'
GROUP BY date, page_path, brand_slug, channel_group;
