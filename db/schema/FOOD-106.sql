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
    with d as materialized (
        select o.order_id,
               o.restaurant_id,
               o.total_amount,
               c.login
        from "order" o
        left join client_address ca on ca.client_address_id = o.client_address_id
        left join client c          on c.client_id = ca.client_id
        where o.status = 'доставлен'
          and o.restaurant_id is not null
    ),
    totals as (
        select restaurant_id,
               sum(total_amount)           as total_amount,
               round(avg(total_amount), 2) as avg_amount
        from d
        group by restaurant_id
    ),
    bu as (
        select distinct on (restaurant_id)
               restaurant_id, login
        from d
        where login is not null
        group by restaurant_id, login
        order by restaurant_id, count(*) desc, random()
    ),
    bp as (
        select distinct on (d.restaurant_id)
               d.restaurant_id, p.product_name
        from d
        join order_structure os on os.order_id = d.order_id
        join product p          on p.product_id = os.product_id
        group by d.restaurant_id, p.product_id, p.product_name
        order by d.restaurant_id, sum(os.quantity) desc, random()
    )
    select r.restaurant_name,
           bp.product_name,
           t.total_amount,
           t.avg_amount,
           bu.login
    from restaurant r
    left join totals t on t.restaurant_id = r.restaurant_id
    left join bp       on bp.restaurant_id = r.restaurant_id
    left join bu       on bu.restaurant_id = r.restaurant_id;
$$;
