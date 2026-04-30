{{ config(schema='silver') }}

with source as (

    select
        vendor_id,
        tpep_pickup_datetime,
        tpep_dropoff_datetime,
        passenger_count,
        trip_distance,
        ratecodeID,
        payment_type,
        fare_amount,
        tip_amount,
        total_amount,
        _ingested_at,
        _source_file
    from iceberg.bronze.yellow_taxi_raw

),

cast_and_hash as (

    select
        -- Surrogate key: hash computed on raw VARCHAR columns for stability
        to_hex(
            md5(
                to_utf8(
                    concat_ws(
                        '|',
                        CAST(vendor_id AS VARCHAR),
                        tpep_pickup_datetime,
                        tpep_dropoff_datetime,
                        CAST(passenger_count AS VARCHAR)
                    )
                )
            )
        )                                                           as trip_id,

        -- Typed columns
        TRY_CAST(vendor_id AS INTEGER)                             as vendor_id,
        TRY_CAST(tpep_pickup_datetime AS TIMESTAMP(6))             as pickup_at,
        TRY_CAST(tpep_dropoff_datetime AS TIMESTAMP(6))            as dropoff_at,
        TRY_CAST(passenger_count AS INTEGER)                       as passenger_count,
        TRY_CAST(trip_distance AS DOUBLE)                          as trip_distance,
        TRY_CAST(ratecodeID AS INTEGER)                            as rate_code_id,
        TRY_CAST(payment_type AS INTEGER)                          as payment_type,
        TRY_CAST(fare_amount AS DECIMAL(10, 2))                    as fare_amount,
        TRY_CAST(tip_amount AS DECIMAL(10, 2))                     as tip_amount,
        TRY_CAST(total_amount AS DECIMAL(10, 2))                   as total_amount,

        -- Metadata columns passed through
        _ingested_at,
        _source_file,

        -- Silver load timestamp
        current_timestamp                                          as _silver_loaded_at

    from source

),

deduplicated as (

    select
        *,
        ROW_NUMBER() OVER (
            PARTITION BY trip_id
            ORDER BY _ingested_at DESC
        ) as rn
    from cast_and_hash
    where trip_id is not null

)

select
    trip_id,
    vendor_id,
    pickup_at,
    dropoff_at,
    passenger_count,
    trip_distance,
    rate_code_id,
    payment_type,
    fare_amount,
    tip_amount,
    total_amount,
    _ingested_at,
    _source_file,
    _silver_loaded_at
from deduplicated
where rn = 1
