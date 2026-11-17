begin;

drop schema if exists tst cascade;
create schema tst;
set local search_path to shkuratetskiy_food, exts, tst;

create table tst.result (
    id      int generated always as identity primary key,
    test    text    not null,
    ok      boolean not null,
    details text
);

create sequence tst.seq;

-- общие объекты сценария: адрес клиента, ресторан, два блюда
create table tst.ctx (ca uuid, rest uuid, prod uuid, odd uuid);


-- Инфраструктура
create function tst.expect_true(p_test text, p_query text)
returns void language plpgsql as $$
declare
    b boolean;
begin
    execute p_query into b;
    insert into tst.result(test, ok, details)
    values (p_test, coalesce(b, false), case when b is true then null else 'условие ложно/NULL: ' || p_query end);
exception when others then
    insert into tst.result(test, ok, details) values (p_test, false, sqlstate || ': ' || sqlerrm);
end $$;


create function tst.wipe() returns void language plpgsql as $$
declare
    v_tables text;
begin
    select string_agg(format('%I.%I', schemaname, tablename), ', ' order by tablename)
    into v_tables
    from pg_tables
    where schemaname = 'shkuratetskiy_food';

    if v_tables is not null then
        execute 'truncate table ' || v_tables || ' restart identity';
    end if;
end $$;


-- вызов процедуры с записью результата без исключений
create function tst.salary(p_test text) returns void language plpgsql as $$
begin
    call shkuratetskiy_food.courier_salary();
    insert into tst.result(test, ok) values (p_test, true);
exception when others then
    insert into tst.result(test, ok, details) values (p_test, false, sqlstate || ': ' || sqlerrm);
end $$;


-- Построители данных. Всё идёт через обычные insert: order_amount и pay_status считают триггеры
create function tst.mk_rest(p_name text) returns uuid language plpgsql as $$
declare
    a uuid;
    r uuid;
begin
    insert into address(street, house_number)
    values ('рест ' || nextval('tst.seq'), '1')
    returning address_id into a;

    insert into restaurant(restaurant_name, address_id, description, work_start, work_end, company_details, status)
    values (p_name, a, 'д', '09:00', '22:00', 'д', 'активен')
    returning restaurant_id into r;

    return r;
end $$;


create function tst.mk_client(p_login text) returns uuid language plpgsql as $$
declare
    c uuid;
begin
    insert into client(login, password, phone_number)
    values (p_login, md5(p_login), '+79' || lpad(nextval('tst.seq')::text, 9, '0'))
    returning client_id into c;

    return c;
end $$;


create function tst.mk_addr(p_client uuid) returns uuid language plpgsql as $$
declare
    a  uuid;
    ca uuid;
begin
    insert into address(street, house_number)
    values ('кл ' || nextval('tst.seq'), '1')
    returning address_id into a;

    insert into client_address(client_id, address_id)
    values (p_client, a)
    returning client_address_id into ca;

    return ca;
end $$;


create function tst.mk_prod(p_rest uuid, p_name text, p_unit measure_unit default 'шт', p_price numeric default 1000)
returns uuid language plpgsql as $$
declare
    cat uuid;
    p   uuid;
begin
    select product_category_id into cat from product_category limit 1;

    if cat is null then
        insert into product_category(product_category_name) values ('кат') returning product_category_id into cat;
    end if;

    insert into product(product_name, product_category_id, price, restaurant_id, status, description, measure_unit)
    values (p_name, cat, p_price, p_rest, 'доступно', 'д', p_unit)
    returning product_id into p;

    return p;
end $$;


-- заказ с одной позицией; доставленный проходит весь путь
create function tst.mk_order(p_ca uuid, p_rest uuid, p_status order_status, p_prod uuid, p_qty numeric)
returns uuid language plpgsql as $$
declare
    o uuid;
begin
    insert into "order"(client_address_id, restaurant_id, status)
    values (p_ca, p_rest, 'создан')
    returning order_id into o;

    insert into order_structure(order_id, product_id, quantity) values (o, p_prod, p_qty);

    if p_status = 'доставлен' then
        insert into payment(order_id, payment_type, transaction_id, status)
        values (o, 'карта', 'tx' || nextval('tst.seq'), 'успех');

        update "order" set status = 'доставлен', delivery_timestamp = localtimestamp where order_id = o;
    elsif p_status != 'создан' then
        update "order" set status = p_status where order_id = o;
    end if;

    return o;
end $$;


-- чистая база + общие объекты сценария
create function tst.setup() returns void language plpgsql as $$
declare
    r uuid;
    a uuid;
begin
    perform tst.wipe();
    delete from tst.ctx;

    r := tst.mk_rest('r');
    a := tst.mk_addr(tst.mk_client('sal_user'));

    insert into tst.ctx values (a, r, tst.mk_prod(r, 'dish'), tst.mk_prod(r, 'odd', 'шт', 1000.50));
end $$;


create function tst.mk_courier(p_coef numeric default 0.1) returns uuid language plpgsql as $$
declare
    c uuid;
begin
    insert into courier(full_name, phone_number, status, hire_date, coefficient)
    values ('курьер ' || nextval('tst.seq'), '+79' || lpad(nextval('tst.seq')::text, 9, '0'),
            'свободен', current_date - 90, p_coef)
    returning courier_id into c;

    return c;
end $$;


-- увольнять надо после назначения заказов: на уволенного курьера заказ назначить нельзя
create function tst.dismiss(p_courier uuid) returns void language plpgsql as $$
begin
    update courier set status = 'уволен', dismissal_date = current_date where courier_id = p_courier;
end $$;


-- заказ курьеру; для доставленного время доставки = p_ts
create function tst.mk_assigned(p_courier uuid, p_status order_status, p_ts timestamp default null,
                                p_qty numeric default 1, p_prod uuid default null)
returns uuid language plpgsql as $$
declare
    x  record;
    o  uuid;
    ts timestamp := coalesce(p_ts, date_trunc('month', localtimestamp) + interval '1 hour');
begin
    select * into x from tst.ctx;

    o := tst.mk_order(x.ca, x.rest, p_status, coalesce(p_prod, x.prod), p_qty);

    update "order" set courier_id = p_courier where order_id = o;

    if p_status = 'доставлен' then
        update "order"
           set order_timestamp = ts - interval '1 minute', delivery_timestamp = ts
         where order_id = o;
    end if;

    return o;
end $$;


-- p_n доставленных заказов в текущем месяце, комиссия каждого = 100.00.
create function tst.mk_deliv(p_courier uuid, p_n int, p_ts timestamp default null) returns void language plpgsql as $$
declare
    x  record;
    ts timestamp := coalesce(p_ts, date_trunc('month', localtimestamp) + interval '1 hour');
begin
    if p_n <= 0 then
        return;
    end if;

    select * into x from tst.ctx;

    alter table "order" disable trigger user;

    insert into "order"(courier_id, client_address_id, restaurant_id, order_timestamp, delivery_timestamp,
                        order_amount, status, pay_status)
    select p_courier, x.ca, x.rest, ts - interval '1 minute', ts, 1000, 'доставлен', 'оплачен'
    from generate_series(1, p_n);

    alter table "order" enable trigger user;
end $$;


-- 1. Что считается: только доставленные заказы курьера внутри текущего месяца
do $t$
declare
    ms timestamp := date_trunc('month', localtimestamp);
    me timestamp := date_trunc('month', localtimestamp) + interval '1 month';
    ca uuid; cb uuid; st order_status;
begin
    perform tst.setup();

    ca := tst.mk_courier(0.3);
    cb := tst.mk_courier(0.1);

    perform tst.mk_deliv(ca, 3);
    perform tst.mk_assigned(ca, 'доставлен', ms); -- ровно начало месяца: входит
    perform tst.mk_assigned(ca, 'доставлен', ms - interval '1 second'); -- прошлый месяц: не входит
    perform tst.mk_assigned(ca, 'доставлен', me); -- начало следующего: не входит

    -- создан, готовится, в_доставке, отменён: не входят
    for st in select e from unnest(enum_range(null::order_status)) e where e != 'доставлен' loop
        perform tst.mk_assigned(ca, st, null, 5);
    end loop;

    perform tst.mk_deliv(cb, 2);

    perform tst.salary('состав: вызов без исключений');

    perform tst.expect_true('состав: учтены 3 заказа + заказ на границе начала месяца, остальные нет',
        format('select amount = 120 and coefficient_used = 0.3 from courier_pay where courier_id = %L', ca));

    perform tst.expect_true('состав: заказы другого курьера не смешиваются',
        format('select amount = 20 and coefficient_used = 0.1 from courier_pay where courier_id = %L', cb));
end $t$;


-- 2. Пороги нового коэффициента: один курьер, число доставок растёт по ходу вызовов.
--    Перед каждым вызовом коэффициент сбрасывается в 0.5, чтобы изменение было заметно.
do $t$
declare
    c   uuid;
    adds int[]     := array[0, 150, 1, 99, 1, 249, 1];
    exp  numeric[] := array[0.1, 0.1, 0.2, 0.2, 0.3, 0.3, 0.5];
    tot  int := 0;
    i    int;
begin
    perform tst.setup();
    c := tst.mk_courier(0.5);

    for i in 1..cardinality(adds) loop
        perform tst.mk_deliv(c, adds[i]);
        tot := tot + adds[i];

        update courier set coefficient = 0.5 where courier_id = c;
        perform tst.salary(format('порог: вызов при %s доставках', tot));

        perform tst.expect_true(format('порог: %s доставок -> коэффициент %s', tot, exp[i]),
            format('select coefficient = %s from courier where courier_id = %L', exp[i], c));
    end loop;
end $t$;


-- 3. Зарплата и применённый коэффициент
do $t$
declare
    po uuid; c1 uuid; c2 uuid; c3 uuid; h text;
    cur text := 'year = extract(year from localtimestamp)::int and month = extract(month from localtimestamp)::int';
begin
    perform tst.setup();
    select odd into po from tst.ctx;

    c1 := tst.mk_courier(0.3);
    c2 := tst.mk_courier(0.5);
    c3 := tst.mk_courier(0.3);

    perform tst.mk_deliv(c1, 10); -- комиссии 1000
    perform tst.mk_deliv(c2, 2); -- комиссии 200
    perform tst.mk_assigned(c3, 'доставлен', null, 1, po); -- комиссия 100.05: 0.3 * 100.05 = 30.015

    -- запись за прошлый месяц: не должна измениться
    insert into courier_pay(year, month, courier_id, amount, coefficient_used)
    select extract(year from d)::int, extract(month from d)::int, c1, 777, 0.2
    from (select date_trunc('month', localtimestamp) - interval '1 month' as d) x;

    select md5((full_name, phone_number, status, hire_date, dismissal_date)::text) into h
    from courier where courier_id = c1;

    perform tst.salary('зарплата: вызов без исключений');

    perform tst.expect_true('зарплата: amount = коэффициент до вызова × сумма комиссий, coefficient_used = коэффициент до вызова',
        format('select count(*) = 1 and bool_and(amount = 300 and coefficient_used = 0.3) from courier_pay where courier_id = %L and %s', c1, cur));

    perform tst.expect_true('зарплата: другой коэффициент — другая сумма',
        format('select count(*) = 1 and bool_and(amount = 100 and coefficient_used = 0.5) from courier_pay where courier_id = %L and %s', c2, cur));

    perform tst.expect_true('зарплата: amount округляется до 2 знаков (30.015 -> 30.02)',
        format('select count(*) = 1 and bool_and(amount = 30.02) from courier_pay where courier_id = %L and %s', c3, cur));

    perform tst.expect_true('зарплата: запись за прошлый месяц не изменилась и не продублировалась',
        format('select count(*) = 1 and (select count(*) from courier_pay where courier_id = %1$L) = 2 from courier_pay where courier_id = %1$L and amount = 777 and coefficient_used = 0.2', c1));

    perform tst.expect_true('коэффициент: у работающего курьера обновлён по числу доставок (10 -> 0.1)',
        format('select coefficient = 0.1 from courier where courier_id = %L', c1));

    perform tst.expect_true('коэффициент: обновлён у всех работающих курьеров',
        format('select count(*) = 3 from courier where coefficient = 0.1 and courier_id in (%L, %L, %L)', c1, c2, c3));

    perform tst.expect_true('коэффициент: остальные колонки курьера не изменились',
        format('select md5((full_name, phone_number, status, hire_date, dismissal_date)::text) = %L from courier where courier_id = %L', h, c1));
end $t$;


-- 4. Уволенные курьеры: зарплата начисляется, коэффициент не трогается
do $t$
declare
    d uuid; e uuid;
    cur text := 'year = extract(year from localtimestamp)::int and month = extract(month from localtimestamp)::int';
begin
    perform tst.setup();

    d := tst.mk_courier(0.3);
    e := tst.mk_courier(0.3);

    perform tst.mk_deliv(d, 10);
    perform tst.mk_deliv(e, 10);
    perform tst.dismiss(d);

    perform tst.salary('уволенный: вызов без исключений');

    perform tst.expect_true('уволенный: запись в courier_pay создана',
        format('select count(*) = 1 and bool_and(amount = 300 and coefficient_used = 0.3) from courier_pay where courier_id = %L and %s', d, cur));

    perform tst.expect_true('уволенный: coefficient не изменился (по доставкам было бы 0.1)',
        format('select coefficient = 0.3 from courier where courier_id = %L', d));

    perform tst.expect_true('уволенный: контроль — у работающего с теми же данными coefficient обновился',
        format('select coefficient = 0.1 from courier where courier_id = %L', e));
end $t$;


-- 5. Повторный вызов за тот же месяц
do $t$
declare
    c uuid;
    cur text := 'year = extract(year from localtimestamp)::int and month = extract(month from localtimestamp)::int';
begin
    perform tst.setup();
    c := tst.mk_courier(0.3);
    perform tst.mk_deliv(c, 10);

    perform tst.salary('повтор: первый вызов без исключений');

    perform tst.expect_true('повтор: после первого вызова amount = 300, coefficient_used = 0.3',
        format('select count(*) = 1 and bool_and(amount = 300 and coefficient_used = 0.3) from courier_pay where courier_id = %L and %s', c, cur));

    -- между вызовами появились ещё доставки (всего 15, комиссии 1500)
    perform tst.mk_deliv(c, 5);

    perform tst.salary('повтор: второй вызов без исключений');

    perform tst.expect_true('повтор: запись обновлена, а не продублирована',
        format('select count(*) = 1 from courier_pay where courier_id = %L and %s', c, cur));

    perform tst.expect_true('повтор: amount пересчитан по новым доставкам, coefficient_used остался коэффициентом месяца (0.3, а не новым 0.1)',
        format('select amount = 450 and coefficient_used = 0.3 from courier_pay where courier_id = %L and %s', c, cur));

    perform tst.expect_true('повтор: courier.coefficient соответствует числу доставок',
        format('select coefficient = 0.1 from courier where courier_id = %L', c));

    perform tst.salary('повтор: третий вызов без исключений');

    perform tst.expect_true('повтор: вызов без изменений данных даёт тот же результат',
        format('select count(*) = 1 and bool_and(amount = 450 and coefficient_used = 0.3) from courier_pay where courier_id = %L and %s', c, cur));
end $t$;


-- 6. Курьер без доставок и пустая таблица курьеров
do $t$
declare
    z uuid;
    cur text := 'year = extract(year from localtimestamp)::int and month = extract(month from localtimestamp)::int';
begin
    perform tst.setup();
    z := tst.mk_courier(0.4);

    perform tst.salary('без доставок: вызов без исключений');

    perform tst.expect_true('без доставок: зарплата 0 и применённый коэффициент = текущему',
        format('select count(*) = 1 and bool_and(amount = 0 and coefficient_used = 0.4) from courier_pay where courier_id = %L and %s', z, cur));

    perform tst.expect_true('без доставок: новый коэффициент 0.1',
        format('select coefficient = 0.1 from courier where courier_id = %L', z));

    perform tst.wipe();
    perform tst.salary('пустая таблица курьеров: вызов без исключений');

    perform tst.expect_true('пустая таблица курьеров: записей нет',
        'select count(*) = 0 from courier_pay');
end $t$;


-- Итог
select count(*) filter (where ok) as passed,
       count(*) filter (where not ok) as failed,
       count(*) as total
from tst.result;

select id, test, details
from tst.result
where not ok
order by id;

rollback;