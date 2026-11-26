create or replace procedure shkuratetskiy_food.insert_test_data(value int)
language plpgsql
set search_path = shkuratetskiy_food, exts
as $$
declare
    n    int := value;
    nf   int := value / 5;
    t    timestamp := localtimestamp;
    w    timestamp := date_trunc('month', t) - interval '5 months';
    ms   date;
    m    int;
    cat  uuid[];
    cou  uuid[];
    act  uuid[];
    adr  uuid[];
    rst  uuid[];
    cli  uuid[] := '{}';
    cad  uuid[];
    prd  uuid[];
    ords uuid[];
    sts  order_status[];
    tmp  uuid[];
    cs   courier_status[] := array(select x from unnest(enum_range(null::courier_status)) x where x <> 'уволен');
    rs   restaurant_status[] := enum_range(null::restaurant_status);
    ps   product_status[] := enum_range(null::product_status);
    mu   measure_unit[] := enum_range(null::measure_unit);
    os   order_status[] := enum_range(null::order_status);
    pt   payment_type[] := enum_range(null::payment_type);
    pms  payment_status[] := enum_range(null::payment_status);
    et   entity_type[] := enum_range(null::entity_type);
begin
    if n is null or n < 1 then
        raise exception 'value должно быть >= 1';
    end if;

    -- В текущей схеме courier_pay.year >= 2026.
    if w::date < date '2026-01-01' then
        raise exception 'Схема courier_pay не допускает все 6 месяцев до 2026 года';
    end if;

    -- product_category
    cat := array(select exts.uuid_generate_v4() from generate_series(1, n));
    insert into product_category(product_category_id, product_category_name)
    select id, 'Категория ' || left(id::text, 8)
    from unnest(cat) u(id);

    -- courier: первые n - nf остаются активными, остальные увольняются после заказов.
    cou := array(select exts.uuid_generate_v4() from generate_series(1, n));
    act := cou[1 : n - nf];
    insert into courier(courier_id, last_name, first_name, middle_name, phone_number,
                        status, hire_date, coefficient)
    select id, 'Иванов ' || left(id::text, 8),
           (array['Иван', 'Александр', 'Михаил'])[1 + (i - 1)::int % 3],
           'Александрович',
           '+79' || lpad(floor(random() * 1e9)::bigint::text, 9, '0'),
           cs[1 + (i - 1)::int % cardinality(cs)], w::date, 0.1
    from unnest(cou) with ordinality u(id, i);

    -- address: UUID в названии улицы защищает от коллизии физических адресов.
    adr := array(select exts.uuid_generate_v4() from generate_series(1, 5 * n));
    insert into address(address_id, street, house_number, apartment_office)
    select id, 'Улица ' || id::text,
           (1 + floor(random() * 200)::int)::text,
           case when i % 3 = 0 then null else (1 + floor(random() * 300)::int)::text end
    from unnest(adr) with ordinality u(id, i);

    -- restaurant: первые n адресов.
    rst := array(select exts.uuid_generate_v4() from generate_series(1, n));
    insert into restaurant(restaurant_id, restaurant_name, address_id, description,
                           work_start, work_end, inn, ogrn, bank_account, status)
    select id, 'Ресторан ' || left(id::text, 8), adr[i::int],
           'Описание ресторана ' || i,
           time '08:00' + (i % 4) * interval '1 hour', time '22:00',
           lpad(floor(random() * 1e10)::bigint::text, 10, '0'),
           lpad(floor(random() * 1e13)::bigint::text, 13, '0'),
           '40702' || lpad(floor(random() * 1e15)::bigint::text, 15, '0'),
           rs[1 + (i - 1)::int % cardinality(rs)]
    from unnest(rst) with ordinality u(id, i);

    -- client: повторяем вставку при совпадении уникального номера/логина.
    while cardinality(cli) < n loop
        with ids as materialized (
            select exts.uuid_generate_v4() as id
            from generate_series(1, n - cardinality(cli))
        ), ins as (
            insert into client(client_id, login, password, phone_number)
            select id, 'u_' || replace(id::text, '-', ''), md5(random()::text),
                   '+79' || lpad(floor(random() * 1e9)::bigint::text, 9, '0')
            from ids
            on conflict do nothing
            returning client_id
        )
        select coalesce(array_agg(client_id), '{}') into tmp from ins;
        cli := cli || tmp;
    end loop;

    -- client_address: оставшиеся 4n адресов, ровно 4 на клиента.
    cad := array(select exts.uuid_generate_v4() from generate_series(1, 4 * n));
    insert into client_address(client_address_id, client_id, address_id)
    select id, cli[1 + (i - 1)::int % n], adr[n + i::int]
    from unnest(cad) with ordinality u(id, i);

    -- product: 5 блюд на ресторан, минимум одно доступное.
    prd := array(select exts.uuid_generate_v4() from generate_series(1, 5 * n));
    insert into product(product_id, product_name, product_category_id, price, restaurant_id,
                        photo_url, status, description, measure_unit)
    select id, 'Блюдо ' || left(id::text, 8),
           cat[1 + floor(random() * n)::int], round((50 + random() * 1950)::numeric, 2),
           rst[1 + (i - 1)::int % n],
           case when i % 3 = 0 then null else 'https://example.test/img/' || id || '.jpg' end,
           case when i <= n then 'доступно'::product_status
                else ps[1 + (i - n - 1)::int % cardinality(ps)] end,
           'Описание блюда ' || i, mu[1 + (i - 1)::int % cardinality(mu)]
    from unnest(prd) with ordinality u(id, i);

    -- order: минимум 2n доставленных, остальные статусы циклически из enum_range.
    ords := array(select exts.uuid_generate_v4() from generate_series(1, 5 * n));
    sts := array(
        select case when g <= 2 * n then 'доставлен'::order_status
                    else os[1 + (g - 2 * n - 1) % cardinality(os)] end
        from generate_series(1, 5 * n) g order by g
    );

    -- Сначала заказ без позиций и оплаты должен иметь статус «создан».
    -- Стратификация времени распределяет заказы по всему интервалу.
    insert into "order"(order_id, client_address_id, restaurant_id, order_timestamp, status, description)
    select id, cad[1 + (i - 1)::int % (4 * n)], rst[1 + (i - 1)::int % n],
           w + ((i - 1 + random()) / (5.0 * n)) * (t - interval '3 hours' - w),
           'создан', 'Комментарий к заказу ' || i
    from unnest(ords) with ordinality u(id, i);

    -- order_structure: 1–5 доступных блюд ресторана заказа.
    -- Первая позиция гарантирует сумму заказа >= 1000, количество для шт — целое.
    with o as materialized (
        select order_id, restaurant_id, 1 + floor(random() * 5)::int as k
        from "order" where order_id = any(ords)
    ), items as (
        select o.order_id, p.product_id, p.price, o.k,
               case when p.measure_unit = 'шт' then 1 + floor(random() * 5)::numeric
                    else (1 + floor(random() * 8)::numeric) / 2 end as q,
               row_number() over (partition by o.order_id order by random()) as rn
        from o join product p on p.restaurant_id = o.restaurant_id
        where p.status = 'доступно' and p.product_id = any(prd)
    )
    insert into order_structure(order_id, product_id, quantity, price)
    select order_id, product_id,
           case when rn = 1 then greatest(q, ceil(1000 / price)) else q end, price
    from items where rn <= k;

    -- payment: order_amount/commission/total_amount уже вычислены схемой.
    insert into payment(payment_id, order_id, payment_type, amount, transaction_id,
                        transaction_timestamp, status)
    select exts.uuid_generate_v4(), o.order_id, pt[1 + (u.i - 1)::int % cardinality(pt)],
           o.total_amount, replace(exts.uuid_generate_v4()::text, '-', ''),
           o.order_timestamp + random() * interval '10 minutes',
           case when u.st = 'создан' then pms[array_position(pms, 'в_обработке')]
                when u.st = 'отменён' then pms[array_position(pms, 'ошибка')]
                else pms[array_position(pms, 'успех')] end
    from unnest(ords, sts) with ordinality u(id, st, i)
    join "order" o on o.order_id = u.id;

    -- Триггер payment уже установил pay_status. Теперь можно доставить заказ.
    -- 30/20/10% доставок первым трём курьерам, остальное случайно.
    with x as (
        select id, st, (row_number() over (partition by st order by i) - 1) % 10 as r
        from unnest(ords, sts) with ordinality u(id, st, i)
    )
    update "order" o
       set status = x.st,
           courier_id = case when x.st = 'доставлен' then
                           case when x.r < 3 then cou[1]
                                when x.r < 5 then coalesce(cou[2], cou[1])
                                when x.r < 6 then coalesce(cou[3], cou[1])
                                else cou[1 + floor(random() * n)::int] end
                         when x.st in ('готовится', 'в_доставке') then
                           act[1 + floor(random() * cardinality(act))::int] end,
           delivery_timestamp = case when x.st = 'доставлен' then
               o.order_timestamp + (30 + floor(random() * 90)::int) * interval '1 minute' end
    from x where o.order_id = x.id and x.st <> 'создан';

    -- Увольнение только после последней доставки; при n >= 1 остаётся активный курьер.
    update courier c
       set status = 'уволен',
           dismissal_date = coalesce((select max(o.delivery_timestamp)::date
                                      from "order" o where o.courier_id = c.courier_id), c.hire_date)
    where c.courier_id = any(cou[n - nf + 1 : n]);

    if not exists (select 1 from courier where dismissal_date is null) then
        raise exception 'Требуется хотя бы один активный курьер';
    end if;

    -- review: 3 вида объектов в одной таблице, только фактически заказанные объекты.
    -- 2n доставленных заказов дают минимум 6n кандидатов, из них берём ровно 5n.
    with d as materialized (
        select order_id, restaurant_id, delivery_timestamp
        from "order" where order_id = any(ords) and status = 'доставлен'
    ), candidates as (
        select order_id, order_id as entity_id, et[array_position(et, 'заказ')] as kind, delivery_timestamp from d
        union all
        select order_id, restaurant_id, et[array_position(et, 'ресторан')], delivery_timestamp from d
        union all
        select d.order_id, s.product_id, et[array_position(et, 'блюдо')], d.delivery_timestamp
        from d join order_structure s using (order_id)
    ), ranked as (
        select *, row_number() over (partition by kind order by random()) as rn
        from candidates
    ), picked as (
        select * from ranked order by (rn > 1), random() limit 5 * n
    )
    insert into review(review_id, review_timestamp, entity_id, entity_type, order_id,
                       description, photo_url, rating)
    select exts.uuid_generate_v4(), delivery_timestamp + random() * interval '1 hour',
           entity_id, kind, order_id, 'Отзыв о заказе',
           case when row_number() over (order by order_id, kind, entity_id) % 2 = 0 then null
                else 'https://example.test/review/' || exts.uuid_generate_v4() || '.jpg' end,
           round((1 + random() * 4)::numeric, 1)
    from picked;

    -- Рейтинг вычисляется только по отзывам нужного типа; без отзывов — NULL.
    update product p set rating = x.rating
    from (select entity_id, round(avg(rating), 2) as rating from review
          where entity_type = 'блюдо' and order_id = any(ords) group by entity_id) x
    where p.product_id = x.entity_id and p.product_id = any(prd);

    update restaurant r set rating = x.rating
    from (select entity_id, round(avg(rating), 2) as rating from review
          where entity_type = 'ресторан' and order_id = any(ords) group by entity_id) x
    where r.restaurant_id = x.entity_id and r.restaurant_id = any(rst);

    -- courier_pay: шесть календарных месяцев, включая текущий.
    -- Идём от старого месяца к новому; сначала выплата, затем новый коэффициент.
    for m in 0..5 loop
        ms := (w + m * interval '1 month')::date;

        insert into courier_pay(courier_pay_id, year, month, courier_id, amount, coefficient_used)
        select exts.uuid_generate_v4(), extract(year from ms)::int, extract(month from ms)::int,
               c.courier_id, round(c.coefficient * coalesce(sum(o.commission), 0), 2), c.coefficient
        from courier c
        left join "order" o on o.courier_id = c.courier_id and o.status = 'доставлен'
                           and o.delivery_timestamp >= ms and o.delivery_timestamp < ms + interval '1 month'
        where c.courier_id = any(cou)
        group by c.courier_id, c.coefficient;

        update courier c set coefficient = case when x.cnt <= 150 then 0.1
                                                when x.cnt <= 250 then 0.2
                                                when x.cnt <= 500 then 0.3
                                                else 0.5 end
        from (select c2.courier_id, count(o.order_id) as cnt
              from courier c2
              left join "order" o on o.courier_id = c2.courier_id and o.status = 'доставлен'
                                 and o.delivery_timestamp >= ms and o.delivery_timestamp < ms + interval '1 month'
              where c2.courier_id = any(cou)
              group by c2.courier_id) x
        where c.courier_id = x.courier_id;
    end loop;
end;
$$;
