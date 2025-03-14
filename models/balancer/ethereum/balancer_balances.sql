{{config(alias='balances')}} 

    WITH pools AS (
        SELECT pool as pools
        FROM {{ source('balancer_ethereum', 'BFactory_evt_LOG_NEW_POOL') }}
    ),
    
    joins AS (
        SELECT p.pools as pool, date_trunc('day', e.evt_block_time) AS day, e.contract_address AS token, SUM(value) AS amount
        FROM {{ source('erc20_ethereum', 'evt_transfer') }} e
        INNER JOIN pools p ON e.`to` = p.pools
        GROUP BY 1, 2, 3

        UNION ALL

        SELECT e.`to` as pool, date_trunc('day', e.evt_block_time) AS day, e.contract_address AS token, SUM(value) AS amount
        FROM {{ source('erc20_ethereum', 'evt_transfer') }} e
        WHERE e.`to` = '0xba12222222228d8ba445958a75a0704d566bf2c8'
        GROUP BY 1, 2, 3

    ),

    exits AS (
        SELECT p.pools as pool, date_trunc('day', e.evt_block_time) AS day, e.contract_address AS token, -SUM(value) AS amount
        FROM {{ source('erc20_ethereum', 'evt_transfer') }} e
        INNER JOIN pools p ON e.`from` = p.pools   
        GROUP BY 1, 2, 3

        UNION ALL

        SELECT e.`from` as pool, date_trunc('day', e.evt_block_time) AS day, e.contract_address AS token, -SUM(value) AS amount
        FROM {{ source('erc20_ethereum', 'evt_transfer') }} e
        WHERE e.`from` = '0xba12222222228d8ba445958a75a0704d566bf2c8'
        GROUP BY 1, 2, 3
    ),
    
    daily_delta_balance_by_token AS (
        SELECT pool, day, token, SUM(COALESCE(amount, 0)) AS amount FROM 
        (SELECT *
        FROM joins j 
        UNION ALL
        SELECT * 
        FROM exits e) foo
        GROUP BY 1, 2, 3
    ),
    
    cumulative_balance_by_token AS (
        SELECT 
            pool, 
            token, 
            day, 
            LEAD(day, 1, now()) OVER (PARTITION BY token, pool ORDER BY day) AS day_of_next_change,
            SUM(amount) OVER (PARTITION BY pool, token ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_amount
        FROM daily_delta_balance_by_token
    ),
    
    calendar AS (
        SELECT explode(sequence(to_date('2022-01-01'), current_date, interval 1 day)) as day
    ),
    
    running_cumulative_balance_by_token AS (
        SELECT c.day, pool, token, cumulative_amount 
        FROM calendar c
        LEFT JOIN cumulative_balance_by_token b ON b.day <= c.day AND c.day < b.day_of_next_change
    )
    
    SELECT * FROM running_cumulative_balance_by_token
