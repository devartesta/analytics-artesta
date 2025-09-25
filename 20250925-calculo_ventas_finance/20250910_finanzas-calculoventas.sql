DROP TABLE IF EXISTS shopify.usa_ventas_202508;

CREATE TABLE shopify.usa_ventas_202508 AS
WITH params AS (
  SELECT '202508'::text AS target_yyyymm
),

/* ==================== Refunds (mismo mes) sin duplicados ==================== */
tx_same_month AS (
  SELECT
    jo.order_id,
    t->>'id'                      AS transaction_id,
    (t->>'amount')::numeric       AS amount_presentment,
    (r->>'created_at')::timestamp AS refund_created_at
  FROM shopify.json_orders jo
  JOIN params p ON TRUE
  CROSS JOIN LATERAL jsonb_array_elements(jo.raw_json->'refunds') r
  LEFT  JOIN LATERAL jsonb_array_elements(COALESCE(r->'transactions','[]'::jsonb)) t ON TRUE
  WHERE to_char((r->>'created_at')::timestamp, 'YYYYMM') = p.target_yyyymm
    AND to_char((jo.raw_json->>'created_at')::timestamp, 'YYYYMM') = p.target_yyyymm
    AND t IS NOT NULL
    AND t->>'currency' = COALESCE(jo.raw_json->>'presentment_currency', jo.raw_json->>'currency')
),

taxes_same_month AS (
  SELECT
    jo.order_id,
    r->>'id'                      AS refund_id,
    SUM((rli->'total_tax_set'->'presentment_money'->>'amount')::numeric) AS tax_presentment_sum,
    (r->>'created_at')::timestamp AS refund_created_at
  FROM shopify.json_orders jo
  JOIN params p ON TRUE
  CROSS JOIN LATERAL jsonb_array_elements(jo.raw_json->'refunds') r
  LEFT  JOIN LATERAL jsonb_array_elements(COALESCE(r->'refund_line_items','[]'::jsonb)) rli ON TRUE
  WHERE to_char((r->>'created_at')::timestamp, 'YYYYMM') = p.target_yyyymm
    AND to_char((jo.raw_json->>'created_at')::timestamp, 'YYYYMM') = p.target_yyyymm
  GROUP BY jo.order_id, refund_id, refund_created_at
),

refunds_same_month AS (
  SELECT
    o.order_id,
    COALESCE(SUM(tx.amount_presentment), 0)     AS refund_amount_presentment_month, -- bruto devuelto (transacciones)
    COALESCE(SUM(taxes.tax_presentment_sum), 0) AS refund_tax_presentment_month,    -- impuestos devueltos
    MIN(COALESCE(tx.refund_created_at, taxes.refund_created_at)) AS first_refund_at,
    MAX(COALESCE(tx.refund_created_at, taxes.refund_created_at)) AS last_refund_at,
    COUNT(DISTINCT tx.transaction_id)::int      AS refund_ops_count
  FROM (
    SELECT DISTINCT jo.order_id
    FROM shopify.json_orders jo
    JOIN params p
      ON to_char((jo.raw_json->>'created_at')::timestamp, 'YYYYMM') = p.target_yyyymm
  ) o
  LEFT JOIN tx_same_month     tx    ON tx.order_id    = o.order_id
  LEFT JOIN taxes_same_month  taxes ON taxes.order_id = o.order_id
  GROUP BY o.order_id
),

/* ==================== Pedidos del mes (original + shown con shipping) ==================== */
orders_in_month AS (
  SELECT
      jo.order_id,
      jo.raw_json->>'name' AS order_name,
      to_char((jo.raw_json->>'created_at')::timestamp, 'YYYYMM') AS order_month_yyyymm,
      to_char(((jo.raw_json->>'created_at')::timestamp)::date, 'DD/MM/YYYY') AS order_date,

      jo.raw_json->'shipping_address'->>'country_code'  AS shipping_country_code,
      CASE WHEN jo.raw_json->'shipping_address'->>'country_code' = 'US'
           THEN jo.raw_json->'shipping_address'->>'province_code' END AS shipping_state_code,

      COALESCE(jo.raw_json->>'presentment_currency', jo.raw_json->>'currency') AS payment_currency,
      COALESCE((SELECT (tl->>'rate')::numeric
                FROM jsonb_array_elements(jo.raw_json->'tax_lines') tl
                LIMIT 1), 0) AS tax_rate,

      CASE WHEN lower(jo.raw_json->>'tags') LIKE '%rever%'  THEN 1 ELSE 0 END AS is_rever_tag,
      CASE WHEN lower(jo.raw_json->>'tags') LIKE '%hannun%' THEN 1 ELSE 0 END AS is_hannun_tag,
      CASE WHEN lower(jo.raw_json->>'tags') LIKE '%mirakl%' THEN 1 ELSE 0 END AS is_mirakl_tag,
      CASE WHEN lower(jo.raw_json->>'tags') LIKE '%choose%' THEN 1 ELSE 0 END AS is_choose_tag,

      -- NUEVOS CAMPOS (tal cual):
      jo.raw_json->>'tags' AS tags,
      jo.raw_json->'payment_gateway_names' AS payment_gateway_names,

      -- Nota limpia (\n literal)
      regexp_replace(
        COALESCE(jo.raw_json->>'note', jo.raw_json->'order'->>'note'),
        E'[\\n\\r]+', E'\\\\n', 'g'
      ) AS order_note,

      /* ---- Shipping con DESCUENTOS ----
         Preferimos discounted_price_set; si no viene, usamos price_set - sum(discount_allocations) */
      COALESCE((
        SELECT SUM(
                 COALESCE(
                   (sl->'discounted_price_set'->'presentment_money'->>'amount')::numeric,
                   (sl->'price_set'->'presentment_money'->>'amount')::numeric
                   - COALESCE((
                       SELECT SUM((da->'amount_set'->'presentment_money'->>'amount')::numeric)
                       FROM jsonb_array_elements(COALESCE(sl->'discount_allocations','[]'::jsonb)) da
                     ), 0)
                 )
               )
        FROM jsonb_array_elements(jo.raw_json->'shipping_lines') sl
      ), 0) AS shipping_presentment_original,

      /* ---- Impuestos totales del pedido ---- */
      (jo.raw_json->'total_tax_set'->'presentment_money'->>'amount')::numeric AS tax_presentment_original,

      /* ---- Subtotal (productos tras descuentos) ---- */
      (jo.raw_json->'subtotal_price_set'->'presentment_money'->>'amount')::numeric AS subtotal_presentment_original,

      /* ---- GROSS ORIGINAL: subtotal + shipping(desc) + (si US, +tax) ---- */
      (
        (jo.raw_json->'subtotal_price_set'->'presentment_money'->>'amount')::numeric
        + COALESCE((
            SELECT SUM(
                     COALESCE(
                       (sl->'discounted_price_set'->'presentment_money'->>'amount')::numeric,
                       (sl->'price_set'->'presentment_money'->>'amount')::numeric
                       - COALESCE((
                           SELECT SUM((da->'amount_set'->'presentment_money'->>'amount')::numeric)
                           FROM jsonb_array_elements(COALESCE(sl->'discount_allocations','[]'::jsonb)) da
                         ), 0)
                     )
                   )
            FROM jsonb_array_elements(jo.raw_json->'shipping_lines') sl
          ), 0)
        + CASE
            WHEN jo.raw_json->'shipping_address'->>'country_code' = 'US'
              THEN COALESCE((jo.raw_json->'total_tax_set'->'presentment_money'->>'amount')::numeric, 0)
            ELSE 0
          END
      ) AS gross_presentment_original,

      /* ---- NET ORIGINAL = GROSS ORIGINAL - TAX ---- */
      (
        (
          (jo.raw_json->'subtotal_price_set'->'presentment_money'->>'amount')::numeric
          + COALESCE((
              SELECT SUM(
                       COALESCE(
                         (sl->'discounted_price_set'->'presentment_money'->>'amount')::numeric,
                         (sl->'price_set'->'presentment_money'->>'amount')::numeric
                         - COALESCE((
                             SELECT SUM((da->'amount_set'->'presentment_money'->>'amount')::numeric)
                             FROM jsonb_array_elements(COALESCE(sl->'discount_allocations','[]'::jsonb)) da
                           ), 0)
                       )
                     )
              FROM jsonb_array_elements(jo.raw_json->'shipping_lines') sl
            ), 0)
          + CASE
              WHEN jo.raw_json->'shipping_address'->>'country_code' = 'US'
                THEN COALESCE((jo.raw_json->'total_tax_set'->'presentment_money'->>'amount')::numeric, 0)
              ELSE 0
            END
        )
        - COALESCE((jo.raw_json->'total_tax_set'->'presentment_money'->>'amount')::numeric, 0)
      ) AS net_presentment_original,

      /* ---- Agregados de reembolso del mismo mes ---- */
      COALESCE(rm.refund_amount_presentment_month, 0) AS refund_amount_presentment_same_month,
      COALESCE(rm.refund_tax_presentment_month,   0) AS refund_tax_presentment_same_month,
      rm.last_refund_at,
      rm.refund_ops_count,

      /* ---- SHOWN GROSS: (misma lógica que GROSS ORIGINAL) - refunds_amount ---- */
      GREATEST(
        (
          (jo.raw_json->'subtotal_price_set'->'presentment_money'->>'amount')::numeric
          + COALESCE((
              SELECT SUM(
                       COALESCE(
                         (sl->'discounted_price_set'->'presentment_money'->>'amount')::numeric,
                         (sl->'price_set'->'presentment_money'->>'amount')::numeric
                         - COALESCE((
                             SELECT SUM((da->'amount_set'->'presentment_money'->>'amount')::numeric)
                             FROM jsonb_array_elements(COALESCE(sl->'discount_allocations','[]'::jsonb)) da
                           ), 0)
                       )
                     )
              FROM jsonb_array_elements(jo.raw_json->'shipping_lines') sl
            ), 0)
          + CASE
              WHEN jo.raw_json->'shipping_address'->>'country_code' = 'US'
                THEN COALESCE((jo.raw_json->'total_tax_set'->'presentment_money'->>'amount')::numeric, 0)
              ELSE 0
            END
          - COALESCE(rm.refund_amount_presentment_month, 0)
        ),
        0
      ) AS shown_gross_presentment,

      /* ---- SHOWN TAX: total_tax - refund_tax (IVA del shipping ya está en total_tax_set) ---- */
      GREATEST(
        (jo.raw_json->'total_tax_set'->'presentment_money'->>'amount')::numeric
        - COALESCE(rm.refund_tax_presentment_month, 0),
        0
      ) AS shown_tax_presentment,

      /* ---- SHOWN NET = SHOWN GROSS - SHOWN TAX ---- */
      GREATEST(
        (
          (
            (jo.raw_json->'subtotal_price_set'->'presentment_money'->>'amount')::numeric
            + COALESCE((
                SELECT SUM(
                         COALESCE(
                           (sl->'discounted_price_set'->'presentment_money'->>'amount')::numeric,
                           (sl->'price_set'->'presentment_money'->>'amount')::numeric
                           - COALESCE((
                               SELECT SUM((da->'amount_set'->'presentment_money'->>'amount')::numeric)
                               FROM jsonb_array_elements(COALESCE(sl->'discount_allocations','[]'::jsonb)) da
                             ), 0)
                         )
                       )
                FROM jsonb_array_elements(jo.raw_json->'shipping_lines') sl
              ), 0)
            + CASE
                WHEN jo.raw_json->'shipping_address'->>'country_code' = 'US'
                  THEN COALESCE((jo.raw_json->'total_tax_set'->'presentment_money'->>'amount')::numeric, 0)
                ELSE 0
              END
            - COALESCE(rm.refund_amount_presentment_month, 0)
          )
          - GREATEST(
              (jo.raw_json->'total_tax_set'->'presentment_money'->>'amount')::numeric
              - COALESCE(rm.refund_tax_presentment_month, 0),
              0
            )
        ),
        0
      ) AS shown_net_presentment

  FROM shopify.json_orders jo
  JOIN params p
    ON to_char((jo.raw_json->>'created_at')::timestamp, 'YYYYMM') = p.target_yyyymm
  LEFT JOIN refunds_same_month rm ON rm.order_id = jo.order_id
),

/* ==================== Refunds de pedidos de meses anteriores ==================== */
refunds_prev_months AS (
  SELECT
      jo.order_id,
      jo.raw_json->>'name' AS order_name,
      p.target_yyyymm      AS order_month_yyyymm,
      to_char(((jo.raw_json->>'created_at')::timestamp)::date, 'DD/MM/YYYY') AS order_date,

      jo.raw_json->'shipping_address'->>'country_code'  AS shipping_country_code,
      CASE WHEN jo.raw_json->'shipping_address'->>'country_code' = 'US'
           THEN jo.raw_json->'shipping_address'->>'province_code' END AS shipping_state_code,

      COALESCE(jo.raw_json->>'presentment_currency', jo.raw_json->>'currency') AS payment_currency,
      COALESCE((SELECT (tl->>'rate')::numeric
                FROM jsonb_array_elements(jo.raw_json->'tax_lines') tl
                LIMIT 1), 0) AS tax_rate,

      CASE WHEN lower(jo.raw_json->>'tags') LIKE '%rever%'  THEN 1 ELSE 0 END AS is_rever_tag,
      CASE WHEN lower(jo.raw_json->>'tags') LIKE '%hannun%' THEN 1 ELSE 0 END AS is_hannun_tag,
      CASE WHEN lower(jo.raw_json->>'tags') LIKE '%mirakl%' THEN 1 ELSE 0 END AS is_mirakl_tag,
      CASE WHEN lower(jo.raw_json->>'tags') LIKE '%choose%' THEN 1 ELSE 0 END AS is_choose_tag,

      -- NUEVOS CAMPOS (tal cual):
      jo.raw_json->>'tags' AS tags,
      jo.raw_json->'payment_gateway_names' AS payment_gateway_names,

      regexp_replace(
        COALESCE(jo.raw_json->>'note', jo.raw_json->'order'->>'note'),
        E'[\\n\\r]+', E'\\\\n', 'g'
      ) AS order_note,

      -- Filas negativas que representan el reembolso en el mes
      - COALESCE((SELECT SUM((t->>'amount')::numeric)
                  FROM jsonb_array_elements(COALESCE(r->'transactions','[]'::jsonb)) t
                  WHERE t->>'currency' = COALESCE(jo.raw_json->>'presentment_currency', jo.raw_json->>'currency')), 0)
        AS shown_gross_presentment,

      - COALESCE((SELECT SUM((rli->'total_tax_set'->'presentment_money'->>'amount')::numeric)
                  FROM jsonb_array_elements(COALESCE(r->'refund_line_items','[]'::jsonb)) rli), 0)
        AS shown_tax_presentment,

      (
        - COALESCE((SELECT SUM((t->>'amount')::numeric)
                    FROM jsonb_array_elements(COALESCE(r->'transactions','[]'::jsonb)) t
                    WHERE t->>'currency' = COALESCE(jo.raw_json->>'presentment_currency', jo.raw_json->>'currency')), 0)
        - COALESCE((SELECT SUM((rli->'total_tax_set'->'presentment_money'->>'amount')::numeric)
                    FROM jsonb_array_elements(COALESCE(r->'refund_line_items','[]'::jsonb)) rli), 0)
      ) AS shown_net_presentment,

      (r->>'created_at')::timestamp                    AS refund_at,
      to_char((r->>'created_at')::timestamp, 'YYYYMM') AS refund_month_yyyymm

  FROM shopify.json_orders jo
  JOIN params p ON TRUE
  CROSS JOIN LATERAL jsonb_array_elements(jo.raw_json->'refunds') r
  WHERE to_char((r->>'created_at')::timestamp, 'YYYYMM') = p.target_yyyymm
    AND to_char((jo.raw_json->>'created_at')::timestamp, 'YYYYMM') <> p.target_yyyymm
)

-- ==================== SALIDA FINAL ====================
SELECT
  order_id,
  order_name,
  order_month_yyyymm,
  order_date,

  shipping_country_code,
  shipping_state_code,

  payment_currency,
  CASE WHEN shown_gross_presentment = 0 THEN 0 ELSE tax_rate END AS tax_rate,

  -- Originales
  subtotal_presentment_original,
  shipping_presentment_original,   -- ya con descuento aplicado
  tax_presentment_original,
  gross_presentment_original,
  net_presentment_original,

  -- Shown (tras refunds del mes)
  shown_gross_presentment,
  CASE WHEN shown_gross_presentment = 0 THEN 0 ELSE shown_tax_presentment END AS shown_tax_presentment,
  shown_net_presentment,

  -- Flags + NUEVOS CAMPOS
  is_rever_tag,
  is_hannun_tag,
  is_mirakl_tag,
  is_choose_tag,
  tags,
  payment_gateway_names,
  order_note,

  CASE WHEN refund_ops_count > 0 THEN to_char(last_refund_at::date, 'DD/MM/YYYY') END AS same_month_refund_date,
  CASE WHEN refund_ops_count > 0 THEN to_char(last_refund_at, 'YYYYMM') END           AS same_month_refund_yyyymm,
  CASE WHEN refund_ops_count > 0 THEN -refund_amount_presentment_same_month ELSE NULL END AS same_month_refund_amount_presentment
FROM orders_in_month

UNION ALL

SELECT
  order_id,
  order_name,
  order_month_yyyymm,
  order_date,
  shipping_country_code,
  shipping_state_code,
  payment_currency,
  tax_rate,

  -- Originales no aplican en refunds de meses previos
  NULL::numeric AS subtotal_presentment_original,
  NULL::numeric AS shipping_presentment_original,
  NULL::numeric AS tax_presentment_original,
  NULL::numeric AS gross_presentment_original,
  NULL::numeric AS net_presentment_original,

  -- Shown negativos (esta fila representa el reembolso)
  shown_gross_presentment,
  CASE WHEN shown_gross_presentment = 0 THEN 0 ELSE shown_tax_presentment END AS shown_tax_presentment,
  shown_net_presentment,

  -- Flags + NUEVOS CAMPOS
  is_rever_tag,
  is_hannun_tag,
  is_mirakl_tag,
  is_choose_tag,
  tags,
  payment_gateway_names,
  order_note,
  to_char(refund_at::date, 'DD/MM/YYYY')  AS same_month_refund_date,
  refund_month_yyyymm                     AS same_month_refund_yyyymm,
  NULL::numeric                           AS same_month_refund_amount_presentment
FROM refunds_prev_months

ORDER BY order_date, same_month_refund_date NULLS FIRST, order_id;


select order_month_yyyymm,
case when shipping_country_code not in ('ES','DE','FR','IT','AT','NL','BE','PT','GB','US') then 'XX' else shipping_country_code end as shipping_country_code , 
payment_currency, 
is_rever_tag, is_hannun_tag, is_mirakl_tag, 
sum(shown_tax_presentment) tax, 
sum(shown_gross_presentment) gross, 
sum(shown_net_presentment) net
from shopify.usa_ventas_202501
where is_choose_tag = 0
group by order_month_yyyymm, shipping_country_code, payment_currency, 
is_rever_tag, is_hannun_tag, is_mirakl_tag
union all
select order_month_yyyymm,
case when shipping_country_code not in ('ES','DE','FR','IT','AT','NL','BE','PT','GB','US') then 'XX' else shipping_country_code end as shipping_country_code , 
payment_currency, 
is_rever_tag, is_hannun_tag, is_mirakl_tag, 
sum(shown_tax_presentment) tax, 
sum(shown_gross_presentment) gross, 
sum(shown_net_presentment) net
from shopify.usa_ventas_202502
where is_choose_tag = 0
group by order_month_yyyymm, shipping_country_code, payment_currency, 
is_rever_tag, is_hannun_tag, is_mirakl_tag
union all
select order_month_yyyymm,
case when shipping_country_code not in ('ES','DE','FR','IT','AT','NL','BE','PT','GB','US') then 'XX' else shipping_country_code end as shipping_country_code , 
payment_currency, 
is_rever_tag, is_hannun_tag, is_mirakl_tag, 
sum(shown_tax_presentment) tax, 
sum(shown_gross_presentment) gross, 
sum(shown_net_presentment) net
from shopify.usa_ventas_202503
where is_choose_tag = 0
group by order_month_yyyymm, shipping_country_code, payment_currency, 
is_rever_tag, is_hannun_tag, is_mirakl_tag
union all
select order_month_yyyymm,
case when shipping_country_code not in ('ES','DE','FR','IT','AT','NL','BE','PT','GB','US') then 'XX' else shipping_country_code end as shipping_country_code , 
payment_currency, 
is_rever_tag, is_hannun_tag, is_mirakl_tag, 
sum(shown_tax_presentment) tax, 
sum(shown_gross_presentment) gross, 
sum(shown_net_presentment) net
from shopify.usa_ventas_202504
where is_choose_tag = 0
group by order_month_yyyymm, shipping_country_code, payment_currency, 
is_rever_tag, is_hannun_tag, is_mirakl_tag
union all
select order_month_yyyymm,
case when shipping_country_code not in ('ES','DE','FR','IT','AT','NL','BE','PT','GB','US') then 'XX' else shipping_country_code end as shipping_country_code , 
payment_currency, 
is_rever_tag, is_hannun_tag, is_mirakl_tag, 
sum(shown_tax_presentment) tax, 
sum(shown_gross_presentment) gross, 
sum(shown_net_presentment) net
from shopify.usa_ventas_202505
where is_choose_tag = 0
group by order_month_yyyymm, shipping_country_code, payment_currency, 
is_rever_tag, is_hannun_tag, is_mirakl_tag
union all
select order_month_yyyymm,
case when shipping_country_code not in ('ES','DE','FR','IT','AT','NL','BE','PT','GB','US') then 'XX' else shipping_country_code end as shipping_country_code , 
payment_currency, 
is_rever_tag, is_hannun_tag, is_mirakl_tag, 
sum(shown_tax_presentment) tax, 
sum(shown_gross_presentment) gross, 
sum(shown_net_presentment) net
from shopify.usa_ventas_202506
where is_choose_tag = 0
group by order_month_yyyymm, shipping_country_code, payment_currency, 
is_rever_tag, is_hannun_tag, is_mirakl_tag
union all
select order_month_yyyymm,
case when shipping_country_code not in ('ES','DE','FR','IT','AT','NL','BE','PT','GB','US') then 'XX' else shipping_country_code end as shipping_country_code , 
payment_currency, 
is_rever_tag, is_hannun_tag, is_mirakl_tag, 
sum(shown_tax_presentment) tax, 
sum(shown_gross_presentment) gross, 
sum(shown_net_presentment) net
from shopify.usa_ventas_202507
where is_choose_tag = 0
group by order_month_yyyymm, shipping_country_code, payment_currency, 
is_rever_tag, is_hannun_tag, is_mirakl_tag
union all
select order_month_yyyymm,
case when shipping_country_code not in ('ES','DE','FR','IT','AT','NL','BE','PT','GB','US') then 'XX' else shipping_country_code end as shipping_country_code , 
payment_currency, 
is_rever_tag, is_hannun_tag, is_mirakl_tag, 
sum(shown_tax_presentment) tax, 
sum(shown_gross_presentment) gross, 
sum(shown_net_presentment) net
from shopify.usa_ventas_202508
where is_choose_tag = 0
group by order_month_yyyymm, shipping_country_code, payment_currency, 
is_rever_tag, is_hannun_tag, is_mirakl_tag
;

