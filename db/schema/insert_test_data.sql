create procedure shkuratetskiy_food.insert_test_data(value int)
language plpgsql
set search_path = shkuratetskiy_food, exts
as $$
declare
    n    int       := value;
    nf   int       := value / 5; -- сколько курьеров уволить
    w    timestamp := date_trunc('month', localtimestamp - interval '5 months');
    t    timestamp := localtimestamp;
    ru   text      := 'абвгдеёжзийклмнопрстуфхцчшщъыьэюя';
    lt   text      := 'abcdefghijklmnopqrstuvwxyz';
    en   text      := 'abcdefghijklmnopqrstuvwxyz0123456789_';
    cs   courier_status[] := array(
             select x from unnest(enum_range(null::courier_status)) x where x != 'уволен');
    cat  uuid[]; cou uuid[]; fir uuid[]; act uuid[];
    adr  uuid[]; ara uuid[]; adc uuid[];
    rst  uuid[]; cli uuid[]; cad uuid[]; prd uuid[];
    ords uuid[]; sts order_status[];
    rvs  uuid[]; r_o uuid[]; r_k text[]; r_p uuid[]; r_r uuid[]; r_d timestamp[];
    tmp  uuid[];
    m    int;
    ms   date;
begin
    if n < 1 then
        raise exception 'value должно быть >= 1';
    end if;

    -- product_category
    cat := array(select exts.uuid_generate_v4() from generate_series(1, n));
    insert into product_category(product_category_id, product_category_name)
    select u.id,
           (select string_agg(substr(ru, 1 + floor(random() * length(ru))::int, 1), '')
            from generate_series(1, 1 + floor(random() * 100)::int + (u.id is null)::int) k)
    from unnest(cat) as u(id);

    -- триггеры не дадут создать уволенного
    cou := array(select exts.uuid_generate_v4() from generate_series(1, n));
    fir := cou[n - nf + 1 : n];
    act := cou[1 : n - nf];
    insert into courier(courier_id, full_name, phone_number, status, hire_date, coefficient)
    select u.id,
           (select string_agg(substr(ru, 1 + floor(random() * length(ru))::int, 1), '')
            from generate_series(1, 1 + floor(random() * 150)::int + (u.id is null)::int) k),
            '+79' || lpad(floor(random() * 1e9)::bigint::text, 9, '0'),
            cs[1 + floor(random() * cardinality(cs))::int],
            w::date + floor(random() * (current_date - w::date))::int,
            0.1
    from unnest(cou) as u(id);

    -- address
    adr := array(select exts.uuid_generate_v4() from generate_series(1, 5 * n));
    ara := adr[1 : n];
    adc := adr[n + 1 : 5 * n];
    loop
        insert into address(address_id, street, house_number, apartment_office)
        select u.id,
               (select string_agg(substr(ru, 1 + floor(random() * length(ru))::int, 1), '')
                from generate_series(1, 1 + floor(random() * 150)::int + (u.id is null)::int) k),
               (1 + floor(random() * 200))::int::text,
               case when random() < 0.3 then null
                    else (1 + floor(random() * 300))::int::text end
        from unnest(adr) as u(id)
        where not exists (select 1 from address a where a.address_id = u.id)
        on conflict do nothing;

        exit when (select count(*) from address where address_id = any(adr)) = 5 * n;
    end loop;

    -- restaurant
    rst := array(select exts.uuid_generate_v4() from generate_series(1, n));
    insert into restaurant(restaurant_id, restaurant_name, address_id, description,
                           work_start, work_end, company_details, status)
    select s.id,
           (select string_agg(substr(ru, 1 + floor(random() * length(ru))::int, 1), '')
            from generate_series(1, 1 + floor(random() * 100)::int + (s.id is null)::int) k),
           s.aid,
           (select string_agg(substr(ru, 1 + floor(random() * length(ru))::int, 1), '')
            from generate_series(1, 1 + floor(random() * 200)::int + (s.id is null)::int) k),
           time '06:00' + s.h * interval '1 hour',
           time '12:00' + (s.h + s.d) * interval '1 hour', -- end - start >= 6 ч
           (select string_agg(substr(ru, 1 + floor(random() * length(ru))::int, 1), '')
            from generate_series(1, 1 + floor(random() * 200)::int + (s.id is null)::int) k),
           (enum_range(null::restaurant_status))[
               1 + floor(random() * cardinality(enum_range(null::restaurant_status)))::int]
    from (select u.id, u.aid, floor(random() * 7)::int h, floor(random() * 6)::int d
          from unnest(rst, ara) as u(id, aid)) s;

    -- client
    cli := '{}';
    while cardinality(cli) < n loop
        with i as (
            insert into client(client_id, login, password, phone_number)
            select exts.uuid_generate_v4(),
                   (select substr(lt, 1 + floor(random() * length(lt))::int, 1)
                    || string_agg(substr(en, 1 + floor(random() * length(en))::int, 1), '')
                    from generate_series(1, 2 + floor(random() * 48)::int + (g is null)::int) k),
                    md5(random()::text),
                    '+79' || lpad(floor(random() * 1e9)::bigint::text, 9, '0')
            from generate_series(1, n - cardinality(cli)) as g
            on conflict do nothing
            returning client_id
        )
        select coalesce(array_agg(client_id), '{}') into tmp from i;
        cli := cli || tmp;
    end loop;

    -- client_address
    cad := array(select exts.uuid_generate_v4() from generate_series(1, 4 * n));
    insert into client_address(client_address_id, client_id, address_id)
    select u.id, cli[1 + ((u.j - 1) % n)::int], u.aid
    from unnest(cad, adc) with ordinality as u(id, aid, j);

    -- product
    prd := array(select exts.uuid_generate_v4() from generate_series(1, 5 * n));
    insert into product(product_id, product_name, product_category_id, price, restaurant_id,
                        photo_url, status, description, measure_unit)
    select u.id,
           (select string_agg(substr(ru, 1 + floor(random() * length(ru))::int, 1), '')
            from generate_series(1, 1 + floor(random() * 150)::int + (u.id is null)::int) k),
           cat[1 + floor(random() * cardinality(cat))::int],
           round((50 + random() * 1950)::numeric, 2),
           rst[1 + ((u.i - 1) % n)::int],
           case when random() < 0.3 then null
                else 'https://cdn.foodexpress.ru/img/' || md5(random()::text) || '.jpg' end,
           case when u.i <= n then 'доступно'::product_status
                else (enum_range(null::product_status))[
                         1 + floor(random() * cardinality(enum_range(null::product_status)))::int]
           end,
           (select string_agg(substr(ru, 1 + floor(random() * length(ru))::int, 1), '')
            from generate_series(1, 1 + floor(random() * 200)::int + (u.id is null)::int) k),
           (enum_range(null::measure_unit))[
               1 + floor(random() * cardinality(enum_range(null::measure_unit)))::int]
    from unnest(prd) with ordinality as u(id, i);

    -- order
    ords := array(select exts.uuid_generate_v4() from generate_series(1, 5 * n));
    sts  := array(
        select case when g <= 2 * n then 'доставлен'::order_status -- запас под отзывы
                    else (enum_range(null::order_status))[
                             1 + floor(random() * cardinality(enum_range(null::order_status)))::int]
               end
        from generate_series(1, 5 * n) g);

    insert into "order"(order_id, client_address_id, restaurant_id, order_timestamp, status, description)
    select u.id,
           cad[1 + floor(random() * cardinality(cad))::int],
           rst[1 + floor(random() * cardinality(rst))::int],
           w + random() * (t - interval '3 hours' - w),
           'создан',
           (select string_agg(substr(ru, 1 + floor(random() * length(ru))::int, 1), '')
            from generate_series(1, 1 + floor(random() * 200)::int + (u.id is null)::int) k)
    from unnest(ords) as u(id);

    -- order_structure
    with o as materialized (
        select order_id as o_id, restaurant_id as r_id, 1 + floor(random() * 5)::int as k
        from "order" where order_id = any(ords)
    ), x as (
        select o.o_id, p.product_id as p_id, p.price, o.k,
               case when p.measure_unit = 'шт' then (1 + floor(random() * 5))::numeric
                    else ((1 + floor(random() * 8)) / 2)::numeric end as q,
               row_number() over (partition by o.o_id order by random()) as rn
        from o
        join product p on p.restaurant_id = o.r_id
                      and p.status = 'доступно'
                      and p.product_id = any(prd)
    )
    insert into order_structure(order_id, product_id, quantity, price)
    select o_id, p_id,
           case when rn = 1 then greatest(q, ceil(1000 / price)) else q end, -- сумма >= 1000
           price
    from x
    where rn <= k;

    -- payment
    insert into payment(payment_id, order_id, payment_type, amount, transaction_id,
                        transaction_timestamp, status)
    select exts.uuid_generate_v4(), o.order_id,
           (enum_range(null::payment_type))[
               1 + floor(random() * cardinality(enum_range(null::payment_type)))::int],
           o.total_amount,
           replace(exts.uuid_generate_v4()::text, '-', ''),
           o.order_timestamp + random() * interval '10 minutes',
           case when u.st in ('доставлен', 'готовится', 'в_доставке') then 'успех'
                when u.st = 'создан' then 'в_обработке'
                else 'ошибка' end::transaction_status
    from unnest(ords, sts) as u(id, st)
    join "order" o on o.order_id = u.id;

    -- итоговые статусы, курьеры, время доставки
    update "order" o
       set status = u.st,
           courier_id = case u.st
               when 'доставлен'  then
                   -- перекос: 30% доставок первому курьеру, 20% второму, 10% третьему, остальное равномерно
                   case when q.r < 0.3 then cou[1]
                        when q.r < 0.5 then coalesce(cou[2], cou[1])
                        when q.r < 0.6 then coalesce(cou[3], cou[1])
                        else cou[1 + floor(random() * cardinality(cou))::int]
                   end
               when 'готовится'  then act[1 + floor(random() * cardinality(act))::int]
               when 'в_доставке' then act[1 + floor(random() * cardinality(act))::int]
           end,
           delivery_timestamp = case when u.st = 'доставлен'
               then o.order_timestamp + (30 + floor(random() * 90)::int) * interval '1 minute'
           end
       from unnest(ords, sts) as u(id, st),
           lateral (select random() + (u.id is null)::int * 0 as r) q
     where o.order_id = u.id and u.st != 'создан';

    -- restaurant_payout
    insert into restaurant_payout(payout_id, order_id, amount, payout_timestamp, transaction_id, status)
    select exts.uuid_generate_v4(), o.order_id, o.order_amount,
           o.delivery_timestamp + random() * interval '1 hour',
           replace(exts.uuid_generate_v4()::text, '-', ''),
           case when random() < 0.8 then 'успех'::transaction_status
                else (enum_range(null::transaction_status))[
                         1 + floor(random() * cardinality(enum_range(null::transaction_status)))::int]
           end
    from "order" o
    where o.order_id = any(ords) and o.status = 'доставлен';

    update courier c
       set hire_date = least(c.hire_date, x.d)
      from (select courier_id, min(order_timestamp)::date as d
            from "order" where courier_id = any(cou) group by courier_id) x
     where c.courier_id = x.courier_id;

    update courier c
       set status = 'уволен',
           dismissal_date = greatest(c.hire_date + 1,
               coalesce((select max(o.delivery_timestamp)::date
                         from "order" o where o.courier_id = c.courier_id),
                        c.hire_date + 1))
     where c.courier_id = any(fir);

    -- review
    with d as (
        select order_id as o_id, restaurant_id as r_id, delivery_timestamp as dt
        from "order" where order_id = any(ords) and status = 'доставлен'
    ), c as (
        select o_id, r_id, 'o' as kd, null::uuid as p_id, dt from d
        union all
        select o_id, r_id, 'r', null::uuid, dt from d
        union all
        select d.o_id, d.r_id, 'p', os.product_id, d.dt
        from d join order_structure os on os.order_id = d.o_id
    ), z as (
        select c.*, row_number() over (partition by kd order by random()) as rk from c
    ), pk as (
        select * from z order by (rk > 1), random() limit 5 * n
    )
    select array_agg(exts.uuid_generate_v4()), array_agg(o_id), array_agg(kd),
           array_agg(p_id), array_agg(r_id), array_agg(dt)
      into rvs, r_o, r_k, r_p, r_r, r_d
      from pk;

    insert into review(review_id, review_timestamp, order_id, description, photo_url, rating)
    select u.id,
           u.dt + random() * interval '1 hour',
           u.o_id,
           (select string_agg(substr(ru, 1 + floor(random() * length(ru))::int, 1), '')
            from generate_series(1, 1 + floor(random() * 200)::int + (u.id is null)::int) k),
           case when random() < 0.5 then null
                else 'https://cdn.foodexpress.ru/img/' || md5(random()::text) || '.jpg' end,
           round((1 + random() * 4)::numeric, 1)
    from unnest(rvs, r_o, r_d) as u(id, o_id, dt);

    insert into product_review(review_id, product_id)
    select u.id, u.p_id from unnest(rvs, r_k, r_p) as u(id, kd, p_id) where u.kd = 'p';

    insert into restaurant_review(review_id, restaurant_id)
    select u.id, u.r_id from unnest(rvs, r_k, r_r) as u(id, kd, r_id) where u.kd = 'r';

    insert into order_review(review_id)
    select u.id from unnest(rvs, r_k) as u(id, kd) where u.kd = 'o';

    update product p set rating = x.rt
      from (select pr.product_id, round(avg(r.rating), 2) as rt
            from product_review pr join review r using (review_id)
            where pr.product_id = any(prd) group by pr.product_id) x
     where p.product_id = x.product_id;

    update restaurant s set rating = x.rt
      from (select rr.restaurant_id, round(avg(r.rating), 2) as rt
            from restaurant_review rr join review r using (review_id)
            where rr.restaurant_id = any(rst) group by rr.restaurant_id) x
     where s.restaurant_id = x.restaurant_id;

    -- courier_pay
    for m in 0..5 loop
        ms := (date_trunc('month', localtimestamp) - (5 - m) * interval '1 month')::date;

        insert into courier_pay(courier_pay_id, year, month, courier_id, amount, coefficient_used)
        select exts.uuid_generate_v4(),
               extract(year from ms)::int,
               extract(month from ms)::int,
               c.courier_id,
               round(c.coefficient * coalesce(sum(o.commission), 0), 2),
               c.coefficient
        from courier c
        left join "order" o on o.courier_id = c.courier_id
                           and o.status = 'доставлен'
                           and o.delivery_timestamp >= ms
                           and o.delivery_timestamp <  ms + interval '1 month'
        where c.courier_id = any(cou)
        group by c.courier_id, c.coefficient;

        update courier c
            set coefficient = case when x.cnt <= 150 then 0.1
                                  when x.cnt <= 250 then 0.2
                                  when x.cnt <= 500 then 0.3
                                  else 0.5 end
            from (select c2.courier_id, count(o.order_id) as cnt
                  from courier c2
                  left join "order" o on o.courier_id = c2.courier_id
                                   and o.status = 'доставлен'
                                   and o.delivery_timestamp >= ms
                                   and o.delivery_timestamp <  ms + interval '1 month'
                  where c2.courier_id = any(cou)
                  group by c2.courier_id) x
        where c.courier_id = x.courier_id;
    end loop;
end;
$$;