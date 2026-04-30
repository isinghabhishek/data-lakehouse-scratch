{{ config(schema='gold') }}

select
    CAST(pickup_at AS DATE)                             as trip_date,
    COUNT(*)                                            as total_trips,
    CAST(AVG(fare_amount) AS DECIMAL(10,2))             as avg_fare,
    AVG(trip_distance)                                  as avg_distance,
    CAST(SUM(total_amount) AS DECIMAL(12,2))            as total_revenue
from {{ ref('stg_yellow_taxi') }}
where pickup_at IS NOT NULL
group by CAST(pickup_at AS DATE)
order by trip_date
