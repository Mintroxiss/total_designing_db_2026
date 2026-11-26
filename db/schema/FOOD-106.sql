create or replace function shkuratetskiy_food.get_statistic()
returns table (
    restaurant_name   varchar,
    best_product_name varchar,
    total_amount      numeric,
    avg_amount        numeric,
    best_user         varchar
)
language sql
volatile
set search_path = shkuratetskiy_food
as $$
    -- Читает доставленные заказы один раз для всех расчётов
    with delivered_orders as materialized (
        select o.order_id,
               o.restaurant_id,
               o.client_address_id,
               o.total_amount
        from "order" o
        where o.status = 'доставлен'
    ),

    client_stats as (
        select d.restaurant_id,
               ca.client_id,
               count(*) as order_count,
               sum(d.total_amount) as order_sum
        from delivered_orders d
        join client_address ca
            on ca.client_address_id = d.client_address_id
        group by d.restaurant_id, ca.client_id
    ),

    client_max as (
        select cs.*,
               max(cs.order_count) over (
                   partition by cs.restaurant_id
               ) as max_order_count
        from client_stats cs
    ),

    restaurant_stats as (
        select cm.restaurant_id,
               sum(cm.order_sum) as total_amount,
               round(
                   sum(cm.order_sum) / sum(cm.order_count), 2
               ) as avg_amount,
               array_agg(cm.client_id) filter (
                   where cm.order_count = cm.max_order_count
               ) as best_client_ids
        from client_max cm
        group by cm.restaurant_id
    ),

    product_stats as (
        select d.restaurant_id,
               os.product_id,
               sum(os.quantity) as total_quantity
        from delivered_orders d
        join order_structure os
            on os.order_id = d.order_id
        group by d.restaurant_id, os.product_id
    ),

    product_max as (
        select ps.*,
               max(ps.total_quantity) over (
                   partition by ps.restaurant_id
               ) as max_quantity
        from product_stats ps
    ),

    best_products as (
        select pm.restaurant_id,
               array_agg(pm.product_id) filter (
                   where pm.total_quantity = pm.max_quantity
               ) as best_product_ids
        from product_max pm
        group by pm.restaurant_id
    ),

    -- Выбирает случайного кандидата при равенстве показателей
    selected as materialized (
        select r.restaurant_name,
               rs.total_amount,
               rs.avg_amount,

               case
                   when cardinality(rs.best_client_ids) > 1
                   then rs.best_client_ids[
                       1 + floor(
                           random() * cardinality(rs.best_client_ids)
                       )::int
                   ]
                   else rs.best_client_ids[1]
               end as client_id,

               case
                   when cardinality(bp.best_product_ids) > 1
                   then bp.best_product_ids[
                       1 + floor(
                           random() * cardinality(bp.best_product_ids)
                       )::int
                   ]
                   else bp.best_product_ids[1]
               end as product_id

        from restaurant r
        left join restaurant_stats rs
            on rs.restaurant_id = r.restaurant_id
        left join best_products bp
            on bp.restaurant_id = r.restaurant_id
    )

    select s.restaurant_name,
           p.product_name as best_product_name,
           s.total_amount,
           s.avg_amount,
           c.login as best_user
    from selected s
    left join product p on p.product_id = s.product_id
    left join client c on c.client_id = s.client_id;
$$;