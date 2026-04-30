{{ config(schema='gold') }}

select
    vendor_id,
    DATE_TRUNC('month', pickup_at)                                              as trip_month,
    COUNT(*)                                                                    as total_trips,
    CAST(
        AVG(
            CAST(tip_amount AS DOUBLE) / NULLIF(CAST(fare_amount AS DOUBLE), 0) * 100
        ) AS DECIMAL(10,2)
    )                                                                           as avg_tip_pct,
    CAST(AVG(CAST(passenger_count AS DOUBLE)) AS DECIMAL(10,2))                as avg_passenger_count
from {{ ref('stg_yellow_taxi') }}
where pickup_at IS NOT NULL
  and vendor_id IS NOT NULL
group by vendor_id, DATE_TRUNC('month', pickup_at)
order by vendor_id, trip_month
