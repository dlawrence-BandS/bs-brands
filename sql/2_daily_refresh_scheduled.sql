-- ============================================================
-- B&S BRAND DASHBOARD — DAILY REFRESH (Scheduled Query)
-- Schedule: every day ~09:00 UK (after the GA4 daily export lands).
-- Rebuilds the last 4 days to pick up late-arriving hits and the
-- intraday -> daily table swap.
-- Set up: BigQuery > Scheduled queries > Create, paste this, no
-- destination table needed (it manages its own DELETE + INSERT).
-- ============================================================

DECLARE refresh_from DATE DEFAULT DATE_SUB(CURRENT_DATE('Europe/London'), INTERVAL 4 DAY);
DECLARE suffix_from STRING DEFAULT FORMAT_DATE('%Y%m%d', refresh_from);

-- ---------- 1. brand_item_daily ----------
DELETE FROM `commanding-air-450109-p0.analytics_287404213.brand_item_daily`
WHERE date >= refresh_from;

INSERT INTO `commanding-air-450109-p0.analytics_287404213.brand_item_daily`
SELECT
  PARSE_DATE('%Y%m%d', e._TABLE_SUFFIX) AS date,
  COALESCE(NULLIF(TRIM(i.item_brand), ''), a.brand, '(not set)'),
  COALESCE(NULLIF(TRIM(i.item_category), ''), '(not set)'),
  COALESCE(NULLIF(TRIM(i.item_category2), ''), '(not set)'),
  i.item_id,
  ANY_VALUE(i.item_name),
  COUNTIF(e.event_name = 'view_item'),
  COUNTIF(e.event_name = 'add_to_cart'),
  COUNTIF(e.event_name = 'begin_checkout'),
  COUNTIF(e.event_name = 'purchase'),
  SUM(IF(e.event_name = 'purchase', i.quantity, 0)),
  ROUND(SUM(IF(e.event_name = 'purchase', i.item_revenue, 0)), 2),
  COUNT(DISTINCT IF(e.event_name = 'purchase', e.ecommerce.transaction_id, NULL))
FROM `commanding-air-450109-p0.analytics_287404213.events_*` e,
UNNEST(e.items) i
LEFT JOIN (SELECT mpn, ANY_VALUE(brand) AS brand
           FROM `commanding-air-450109-p0.analytics_287404213.bs_product_attributes`
           GROUP BY mpn) a ON i.item_id = a.mpn
WHERE e._TABLE_SUFFIX >= suffix_from
  AND e.event_name IN ('view_item','add_to_cart','begin_checkout','purchase')
  AND i.item_id IS NOT NULL
GROUP BY 1, 2, 3, 4, 5;

-- ---------- 2. brand_daily ----------
DELETE FROM `commanding-air-450109-p0.analytics_287404213.brand_daily`
WHERE date >= refresh_from;

INSERT INTO `commanding-air-450109-p0.analytics_287404213.brand_daily`
WITH brand_sessions AS (
  SELECT
    PARSE_DATE('%Y%m%d', e._TABLE_SUFFIX) AS date,
    COALESCE(NULLIF(TRIM(i.item_brand), ''), a.brand, '(not set)') AS brand,
    CONCAT(e.user_pseudo_id, '.',
      CAST((SELECT value.int_value FROM UNNEST(e.event_params)
            WHERE key = 'ga_session_id') AS STRING)) AS session_id,
    MAX(CAST((SELECT value.int_value FROM UNNEST(e.event_params)
            WHERE key = 'session_engaged') AS INT64)) AS engaged,
    COUNT(DISTINCT IF(e.event_name = 'purchase',
            e.ecommerce.transaction_id, NULL)) AS txns
  FROM `commanding-air-450109-p0.analytics_287404213.events_*` e,
  UNNEST(e.items) i
  LEFT JOIN (SELECT mpn, ANY_VALUE(brand) AS brand
             FROM `commanding-air-450109-p0.analytics_287404213.bs_product_attributes`
             GROUP BY mpn) a ON i.item_id = a.mpn
  WHERE e._TABLE_SUFFIX >= suffix_from
    AND e.event_name IN ('view_item','add_to_cart','begin_checkout','purchase')
  GROUP BY date, brand, session_id
)
SELECT date, brand,
  COUNT(DISTINCT session_id),
  COUNT(DISTINCT IF(engaged = 1, session_id, NULL)),
  SUM(txns)
FROM brand_sessions
GROUP BY date, brand;

-- ---------- 3. brand_pages_daily ----------
DELETE FROM `commanding-air-450109-p0.analytics_287404213.brand_pages_daily`
WHERE date >= refresh_from;

INSERT INTO `commanding-air-450109-p0.analytics_287404213.brand_pages_daily`
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
  WHERE e._TABLE_SUFFIX >= suffix_from
    AND e.event_name = 'page_view'
)
SELECT
  date, page_path,
  REGEXP_EXTRACT(page_path, r'^/brands/([^/?#]+)'),
  channel_group,
  COUNT(DISTINCT session_id),
  COUNT(DISTINCT IF(engaged = 1, session_id, NULL)),
  COUNT(*)
FROM pv
WHERE page_path LIKE '/brands%'
GROUP BY 1, 2, 3, 4;
