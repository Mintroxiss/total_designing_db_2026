begin;

set local search_path to shkuratetskiy_food, exts;

-- Только бизнес-логика get_statistic(). Рабочие данные не удаляются.
create temp table statistic_test_result (
    id int generated always as identity primary key,
    test text not null,
    ok boolean not null,
    details text
);

create function pg_temp.expect_true(p_test text, p_ok boolean, p_details text default null)
returns void language sql as $$
    insert into pg_temp.statistic_test_result(test, ok, details)
    values (p_test, coalesce(p_ok, false),
            case when p_ok is not true then coalesce(p_details, 'условие ложно или NULL') end);
$$;

-- Один вызов статистики на проверку. NULL в массиве аргументов не нужен:
-- NULL вместо массива означает, что соответствующая колонка должна быть NULL.
create function pg_temp.expect_stat(
    p_test text, p_name text, p_products text[], p_total numeric,
    p_avg numeric, p_users text[]
) returns void language plpgsql as $$
declare
    n bigint;
    good bigint;
    actual jsonb;
begin
    select count(*), count(*) filter (where
               (case when p_products is null then s.best_product_name is null
                     else s.best_product_name = any(p_products) end)
               and s.total_amount is not distinct from p_total
               and s.avg_amount is not distinct from p_avg
               and (case when p_users is null then s.best_user is null
                         else s.best_user = any(p_users) end)),
           jsonb_agg(to_jsonb(s))
    into n, good, actual
    from shkuratetskiy_food.get_statistic() s
    where s.restaurant_name = p_name;

    perform pg_temp.expect_true(p_test, n = 1 and good = 1,
        format('ожидалась одна строка: блюдо=%s, total=%s, avg=%s, клиент=%s; получено: %s',
               coalesce(p_products::text, 'NULL'), coalesce(p_total::text, 'NULL'),
               coalesce(p_avg::text, 'NULL'), coalesce(p_users::text, 'NULL'),
               coalesce(actual::text, 'нет строк')));
exception when others then
    perform pg_temp.expect_true(p_test, false, sqlstate || ': ' || sqlerrm);
end;
$$;

-- Минимальные валидные фикстуры по актуальной схеме.
create function pg_temp.mk_rest(p_name text) returns uuid language plpgsql as $$
declare
    a uuid;
    r uuid := uuid_generate_v4();
begin
    insert into address(street, house_number)
    values ('Тест статистики ' || r, '1') returning address_id into a;

    insert into restaurant(restaurant_id, restaurant_name, address_id, description,
                           work_start, work_end, inn, ogrn, bank_account, status)
    values (r, p_name, a, 'Тест', '09:00', '22:00', '7701234567',
            '1027700132195', '40702810900000000001', 'активен');
    return r;
end;
$$;

create function pg_temp.mk_client(p_login text) returns uuid language plpgsql as $$
declare
    c uuid;
begin
    loop
        insert into client(login, password, phone_number)
        values (p_login, md5(p_login),
                '+79' || lpad(floor(random() * 1000000000)::bigint::text, 9, '0'))
        on conflict (phone_number) do nothing returning client_id into c;
        exit when c is not null;
    end loop;
    return c;
end;
$$;

create function pg_temp.mk_addr(p_client uuid) returns uuid language plpgsql as $$
declare
    a uuid;
    ca uuid;
begin
    insert into address(street, house_number)
    values ('Тест статистики ' || uuid_generate_v4(), '1') returning address_id into a;
    insert into client_address(client_id, address_id)
    values (p_client, a) returning client_address_id into ca;
    return ca;
end;
$$;

create function pg_temp.mk_prod(p_rest uuid, p_name text, p_price numeric default 1000,
                               p_unit measure_unit default 'шт')
returns uuid language plpgsql as $$
declare
    cat uuid;
    p uuid;
begin
    insert into product_category(product_category_name)
    values ('Тест статистики') returning product_category_id into cat;
    insert into product(product_name, product_category_id, price, restaurant_id,
                        status, description, measure_unit)
    values (p_name, cat, p_price, p_rest, 'доступно', 'Тест', p_unit)
    returning product_id into p;
    return p;
end;
$$;

-- Позиции могут быть множественными. Оплата и сумма заказа считаются штатно.
create function pg_temp.mk_order(p_ca uuid, p_rest uuid, p_courier uuid,
                                p_status order_status, p_products uuid[],
                                p_qty numeric[], p_paid boolean default false)
returns uuid language plpgsql as $$
declare
    o uuid;
begin
    insert into "order"(client_address_id, restaurant_id, courier_id, status)
    values (p_ca, p_rest, p_courier, 'создан') returning order_id into o;

    insert into order_structure(order_id, product_id, quantity, price)
    select o, p.product_id, u.qty, p.price
    from unnest(p_products, p_qty) u(product_id, qty)
    join product p on p.product_id = u.product_id;

    if p_status = 'доставлен' or p_paid then
        insert into payment(order_id, payment_type, amount, transaction_id, status)
        select o, 'карта', total_amount, uuid_generate_v4()::text, 'успех'
        from "order" where order_id = o;
    end if;

    if p_status <> 'создан' then
        update "order"
        set status = p_status,
            delivery_timestamp = case when p_status = 'доставлен' then localtimestamp end
        where order_id = o;
    end if;
    return o;
end;
$$;

-- 1. Финансы, лидеры, фильтр статусов, независимость ресторанов.
do $$
declare
    prefix text := 'stat_' || replace(uuid_generate_v4()::text, '-', '');
    n text := prefix || '_main';
    n_other text := prefix || '_other';
    n_empty text := prefix || '_empty';
    n_open text := prefix || '_open';
    r uuid; r_other uuid; r_empty uuid; r_open uuid;
    courier uuid; c1 uuid; c2 uuid; a1 uuid; a2 uuid; a3 uuid; b uuid;
    p1 uuid; p2 uuid; p3 uuid; pn uuid; po uuid; px uuid;
    u1 text := prefix || '_fan';
    u2 text := prefix || '_rich';
    st order_status;
begin
    insert into shkuratetskiy_food.courier(last_name, first_name, middle_name, phone_number, status)
    values ('Тест', 'Тест', 'Тест', '+79000000000', 'свободен') returning courier_id into courier;

    r := pg_temp.mk_rest(n);
    r_other := pg_temp.mk_rest(n_other);
    r_empty := pg_temp.mk_rest(n_empty);
    r_open := pg_temp.mk_rest(n_open);
    c1 := pg_temp.mk_client(u1);
    c2 := pg_temp.mk_client(u2);
    a1 := pg_temp.mk_addr(c1);
    a2 := pg_temp.mk_addr(c1);
    a3 := pg_temp.mk_addr(c1);
    b := pg_temp.mk_addr(c2);
    p1 := pg_temp.mk_prod(r, 'many_orders', 2500);
    p2 := pg_temp.mk_prod(r, 'big_qty', 1000);
    p3 := pg_temp.mk_prod(r, 'extra', 5000);
    pn := pg_temp.mk_prod(r, 'noise');

    -- Клиент 1: 3 заказа по 2750 с разных адресов (8250).
    -- Клиент 2: 2 заказа на 7700 и 2200 (9900). Один заказ с двумя позициями.
    -- many_orders: 3 шт. на 7500; big_qty: 4 шт. на 4000; extra: 1 шт. на 5000.
    perform pg_temp.mk_order(a1, r, courier, 'доставлен', array[p1], array[1]::numeric[]);
    perform pg_temp.mk_order(a2, r, courier, 'доставлен', array[p1], array[1]::numeric[]);
    perform pg_temp.mk_order(a3, r, courier, 'доставлен', array[p1], array[1]::numeric[]);
    perform pg_temp.mk_order(b, r, courier, 'доставлен', array[p2,p3], array[2,1]::numeric[]);
    perform pg_temp.mk_order(b, r, courier, 'доставлен', array[p2], array[2]::numeric[]);

    perform pg_temp.expect_stat('финансы и лидеры: 5 заказов, разные адреса, несколько позиций',
                               n, array['big_qty'], 18150, 3630, array[u1]);

    -- Все недоставленные статусы: шум мог бы победить по количеству и заказам.
    -- Заказ в доставке уже оплачен: одного pay_status недостаточно.
    for st in select unnest(enum_range(null::order_status)) loop
        if st <> 'доставлен' then
            perform pg_temp.mk_order(b, r, courier, st, array[pn], array[10]::numeric[], st = 'в_доставке');
            perform pg_temp.expect_stat('фильтр статуса: ' || st,
                                       n, array['big_qty'], 18150, 3630, array[u1]);
        end if;
    end loop;

    -- Тот же клиент в другом ресторане; его заказы не смешиваются.
    po := pg_temp.mk_prod(r_other, 'other_dish');
    perform pg_temp.mk_order(b, r_other, courier, 'доставлен', array[po], array[10]::numeric[]);
    perform pg_temp.expect_stat('изоляция: другой ресторан', n_other, array['other_dish'], 11000, 11000, array[u2]);
    perform pg_temp.expect_stat('изоляция: исходный ресторан не изменился', n, array['big_qty'], 18150, 3630, array[u1]);

    -- Цена в каталоге может измениться: статистика учитывает цену в заказе.
    update product set price = 9000 where product_id = p1;
    perform pg_temp.expect_stat('финансы: изменение цены в каталоге не меняет историю заказов',
                               n, array['big_qty'], 18150, 3630, array[u1]);

    px := pg_temp.mk_prod(r_open, 'open_dish');
    perform pg_temp.mk_order(a1, r_open, courier, 'создан', array[px], array[1]::numeric[]);
    perform pg_temp.expect_stat('ресторан только с недоставленным заказом', n_open, null, null, null, null);
    perform pg_temp.expect_stat('ресторан без заказов', n_empty, null, null, null, null);
exception when others then
    perform pg_temp.expect_true('сценарий 1: ошибка подготовки или выполнения', false, sqlstate || ': ' || sqlerrm);
end;
$$;

-- 2. Дробное количество, округление среднего чека в обе стороны.
do $$
declare
    prefix text := 'stat_' || replace(uuid_generate_v4()::text, '-', '');
    n text;
    u text := prefix || '_user';
    r uuid; c uuid; a uuid; courier uuid; p uuid; q uuid;
begin
    insert into shkuratetskiy_food.courier(last_name, first_name, middle_name, phone_number, status)
    values ('Тест', 'Тест', 'Тест', '+79000000000', 'свободен') returning courier_id into courier;
    c := pg_temp.mk_client(u);
    a := pg_temp.mk_addr(c);

    n := prefix || '_fraction';
    r := pg_temp.mk_rest(n);
    p := pg_temp.mk_prod(r, 'piece_dish');
    q := pg_temp.mk_prod(r, 'weight_dish', 1000, 'кг');
    perform pg_temp.mk_order(a, r, courier, 'доставлен', array[p], array[3]::numeric[]);
    perform pg_temp.mk_order(a, r, courier, 'доставлен', array[q], array[1.9]::numeric[]);
    perform pg_temp.mk_order(a, r, courier, 'доставлен', array[q], array[1.9]::numeric[]);
    -- 3.8 кг против 3 шт.; 3300 + 2090 + 2090 = 7480; avg = 2493.33.
    perform pg_temp.expect_stat('дробное количество и округление среднего вниз',
                               n, array['weight_dish'], 7480, 2493.33, array[u]);

    n := prefix || '_round';
    r := pg_temp.mk_rest(n);
    p := pg_temp.mk_prod(r, 'round_dish', 1000, 'кг');
    perform pg_temp.mk_order(a, r, courier, 'доставлен', array[p], array[1]::numeric[]);
    perform pg_temp.mk_order(a, r, courier, 'доставлен', array[p], array[1]::numeric[]);
    perform pg_temp.mk_order(a, r, courier, 'доставлен', array[p], array[1.1]::numeric[]);
    perform pg_temp.expect_stat('округление среднего вверх: 3410 / 3',
                               n, array['round_dish'], 3410, 1136.67, array[u]);
exception when others then
    perform pg_temp.expect_true('сценарий 2: ошибка подготовки или выполнения', false, sqlstate || ': ' || sqlerrm);
end;
$$;

-- 3. Ничья: только кандидаты с максимумом, ровно одна строка на вызов.
-- Не требуем выпадения всех вариантов за конечное число вызовов.
do $$
declare
    prefix text := 'stat_' || replace(uuid_generate_v4()::text, '-', '');
    n text := prefix || '_tie';
    u1 text := prefix || '_a'; u2 text := prefix || '_b'; u3 text := prefix || '_c';
    r uuid; courier uuid; a uuid; b uuid; c uuid; p1 uuid; p2 uuid; p3 uuid;
    i int;
    actual record;
    valid boolean := true;
    seen_products text[] := '{}'; seen_users text[] := '{}';
    bad text;
begin
    insert into shkuratetskiy_food.courier(last_name, first_name, middle_name, phone_number, status)
    values ('Тест', 'Тест', 'Тест', '+79000000000', 'свободен') returning courier_id into courier;
    r := pg_temp.mk_rest(n);
    a := pg_temp.mk_addr(pg_temp.mk_client(u1));
    b := pg_temp.mk_addr(pg_temp.mk_client(u2));
    c := pg_temp.mk_addr(pg_temp.mk_client(u3));
    p1 := pg_temp.mk_prod(r, 'tie_a');
    p2 := pg_temp.mk_prod(r, 'tie_b');
    p3 := pg_temp.mk_prod(r, 'not_leader');
    perform pg_temp.mk_order(a, r, courier, 'доставлен', array[p1], array[1]::numeric[]);
    perform pg_temp.mk_order(a, r, courier, 'доставлен', array[p1], array[1]::numeric[]);
    perform pg_temp.mk_order(b, r, courier, 'доставлен', array[p2], array[1]::numeric[]);
    perform pg_temp.mk_order(b, r, courier, 'доставлен', array[p2], array[1]::numeric[]);
    perform pg_temp.mk_order(c, r, courier, 'доставлен', array[p3], array[1]::numeric[]);

    for i in 1..20 loop
        select count(*) as n,
               count(*) filter (where s.best_product_name in ('tie_a', 'tie_b')
                                  and s.best_user in (u1, u2)
                                  and s.total_amount = 5500 and s.avg_amount = 1100) as good,
               min(s.best_product_name) as product_name, min(s.best_user) as login,
               jsonb_agg(to_jsonb(s)) as rows
        into actual
        from shkuratetskiy_food.get_statistic() s where s.restaurant_name = n;
        if actual.n <> 1 or actual.good <> 1 then
            valid := false;
            bad := format('вызов %s: %s', i, coalesce(actual.rows::text, 'нет строк'));
            exit;
        end if;
        if not (actual.product_name = any(seen_products)) then
            seen_products := array_append(seen_products, actual.product_name::text);
        end if;
        if not (actual.login = any(seen_users)) then
            seen_users := array_append(seen_users, actual.login::text);
        end if;
    end loop;
    perform pg_temp.expect_true('ничья: 20 вызовов, одна строка, только лидеры, финансы неизменны', valid, bad);
    raise notice 'Ничья (диагностика, не критерий успеха): блюда %, клиенты %', seen_products, seen_users;
exception when others then
    perform pg_temp.expect_true('сценарий 3: ошибка подготовки или выполнения', false, sqlstate || ': ' || sqlerrm);
end;
$$;

-- 4. Названия ресторанов не уникальны: нельзя группировать по имени.
do $$
declare
    prefix text := 'stat_' || replace(uuid_generate_v4()::text, '-', '');
    n text := prefix || '_same';
    u text := prefix || '_user';
    r1 uuid; r2 uuid; p uuid; a uuid; courier uuid;
    actual record;
begin
    insert into shkuratetskiy_food.courier(last_name, first_name, middle_name, phone_number, status)
    values ('Тест', 'Тест', 'Тест', '+79000000000', 'свободен') returning courier_id into courier;
    r1 := pg_temp.mk_rest(n);
    r2 := pg_temp.mk_rest(n);
    a := pg_temp.mk_addr(pg_temp.mk_client(u));
    p := pg_temp.mk_prod(r1, 'same_name_a');
    perform pg_temp.mk_order(a, r1, courier, 'доставлен', array[p], array[1]::numeric[]);
    p := pg_temp.mk_prod(r2, 'same_name_b');
    perform pg_temp.mk_order(a, r2, courier, 'доставлен', array[p], array[3]::numeric[]);

    select count(*) as n,
           count(*) filter (where best_product_name = 'same_name_a' and total_amount = 1100
                            and avg_amount = 1100 and best_user = u) as a_count,
           count(*) filter (where best_product_name = 'same_name_b' and total_amount = 3300
                            and avg_amount = 3300 and best_user = u) as b_count,
           jsonb_agg(to_jsonb(s)) as rows
    into actual
    from shkuratetskiy_food.get_statistic() s where s.restaurant_name = n;
    perform pg_temp.expect_true('одинаковые названия: две независимые строки',
                               actual.n = 2 and actual.a_count = 1 and actual.b_count = 1,
                               coalesce(actual.rows::text, 'нет строк'));
exception when others then
    perform pg_temp.expect_true('сценарий 4: ошибка подготовки или выполнения', false, sqlstate || ': ' || sqlerrm);
end;
$$;

-- 5. Кардинальность результата по всей схеме (включая существующие данные).
do $$
begin
    perform pg_temp.expect_true('одна строка на каждый ресторан (по названиям с учётом повторов)',
        not exists (
            select restaurant_name
            from (
                select restaurant_name, 1 as delta from restaurant
                union all
                select restaurant_name, -1 from shkuratetskiy_food.get_statistic()
            ) x
            group by restaurant_name
            having sum(delta) <> 0
        ));
exception when others then
    perform pg_temp.expect_true('одна строка на каждый ресторан', false, sqlstate || ': ' || sqlerrm);
end;
$$;

select count(*) filter (where ok) as passed,
       count(*) filter (where not ok) as failed,
       count(*) as total
from pg_temp.statistic_test_result;

select id, test, details
from pg_temp.statistic_test_result
where not ok
order by id;

rollback;
