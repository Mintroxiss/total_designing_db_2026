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

create table tst.ctx (ca uuid, rest uuid, prod uuid, odd uuid);


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


create function tst.salary(p_test text) returns void language plpgsql as $$
begin
    call shkuratetskiy_food.courier_salary();
    insert into tst.result(test, ok) values (p_test, true);
exception when others then
    insert into tst.result(test, ok, details) values (p_test, false, sqlstate || ': ' || sqlerrm);
end $$;


create function tst.mk_rest(p_name text) returns uuid language plpgsql as $$
declare
    a uuid;
    r uuid;
begin
    insert into address(street, house_number)
    values ('рест ' || nextval('tst.seq'), '1')
    returning address_id into a;

    insert into restaurant(restaurant_name, address_id, description, work_start, work_end, inn, ogrn, bank_account, status)
    values (p_name, a, 'д', '09:00', '22:00', '1234567890', '1234567890123', '12345678901234567890', 'активен')
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


create function tst.mk_order(p_ca uuid, p_rest uuid, p_status order_status,
                             p_prod uuid, p_qty numeric, p_courier uuid, p_ts timestamp)
returns uuid language plpgsql as $$
declare
    o uuid;
begin
    insert into "order"(client_address_id, restaurant_id, courier_id, order_timestamp, status)
    values (p_ca, p_rest, p_courier,
            case when p_status = 'доставлен' then p_ts - interval '1 minute'
                 else localtimestamp end,
            'создан')
    returning order_id into o;

    insert into order_structure(order_id, product_id, quantity, price)
    select o, p_prod, p_qty, p.price
    from product p where p.product_id = p_prod;

    if p_status = 'доставлен' then
        insert into payment(order_id, payment_type, amount, transaction_id, status)
        select o, 'карта', ord.total_amount, 'tx' || nextval('tst.seq'), 'успех'
        from "order" ord where ord.order_id = o;

        update "order" set status = 'доставлен', delivery_timestamp = p_ts where order_id = o;
    elsif p_status != 'создан' then
        update "order" set status = p_status where order_id = o;
    end if;

    return o;
end $$;


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
    insert into courier(last_name, first_name, middle_name, phone_number, status, hire_date, coefficient)
    values ('Курьер ' || nextval('tst.seq'), 'Иван', 'Иванович', '+79' || lpad(nextval('tst.seq')::text, 9, '0'),
            'свободен', current_date - 90, p_coef)
    returning courier_id into c;

    return c;
end $$;


-- Увольняет курьера после назначения заказов
create function tst.dismiss(p_courier uuid) returns void language plpgsql as $$
begin
    update courier set status = 'уволен', dismissal_date = current_date where courier_id = p_courier;
end $$;


create function tst.mk_assigned(p_courier uuid, p_status order_status, p_ts timestamp default null,
                                p_qty numeric default 1, p_prod uuid default null)
returns uuid language plpgsql as $$
declare
    x  record;
    ts timestamp := coalesce(p_ts, date_trunc('month', localtimestamp) + interval '1 hour');
begin
    select * into x from tst.ctx;

    return tst.mk_order(x.ca, x.rest, p_status, coalesce(p_prod, x.prod), p_qty, p_courier, ts);
end $$;


-- Создаёт доставки с комиссией 100 за заказ
create function tst.mk_deliv(p_courier uuid, p_n int, p_ts timestamp default null) returns void language plpgsql as $$
begin
    if p_n <= 0 then
        return;
    end if;

    for i in 1..p_n loop
        perform tst.mk_assigned(p_courier, 'доставлен', p_ts);
    end loop;
end $$;


-- Проверяет статусы заказов и границы месяца доставки
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
    perform tst.mk_assigned(ca, 'доставлен', ms);
    perform tst.mk_assigned(ca, 'доставлен', ms - interval '1 second');
    perform tst.mk_assigned(ca, 'доставлен', me);

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


-- Проверяет пороги коэффициента
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


-- Проверяет сумму выплаты и применённый коэффициент
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

    perform tst.mk_deliv(c1, 10);
    perform tst.mk_deliv(c2, 2);
    perform tst.mk_assigned(c3, 'доставлен', null, 1, po);

    insert into courier_pay(year, month, courier_id, amount, coefficient_used)
    select extract(year from d)::int, extract(month from d)::int, c1, 777, 0.2
    from (select date_trunc('month', localtimestamp) - interval '1 month' as d) x;

    select md5((last_name, first_name, middle_name, phone_number, status, hire_date, dismissal_date)::text) into h
    from courier where courier_id = c1;

    perform tst.salary('зарплата: вызов без исключений');

    perform tst.expect_true('зарплата: amount = коэффициент до вызова × сумма комиссий, coefficient_used = коэффициент до вызова',
        format('select count(*) = 1 and bool_and(amount = 300 and coefficient_used = 0.3) from courier_pay where courier_id = %L and %s', c1, cur));

    perform tst.expect_true('зарплата: другой коэффициент — другая сумма',
        format('select count(*) = 1 and bool_and(amount = 100 and coefficient_used = 0.5) from courier_pay where courier_id = %L and %s', c2, cur));

    perform tst.expect_true('зарплата: округление 30.015 до 30.02',
        format('select count(*) = 1 and bool_and(amount = 30.02) from courier_pay where courier_id = %L and %s', c3, cur));

    perform tst.expect_true('зарплата: запись за прошлый месяц не изменилась и не продублировалась',
        format('select count(*) = 1 and (select count(*) from courier_pay where courier_id = %1$L) = 2 from courier_pay where courier_id = %1$L and amount = 777 and coefficient_used = 0.2', c1));

    perform tst.expect_true('коэффициент: 0.1 после 10 доставок',
        format('select coefficient = 0.1 from courier where courier_id = %L', c1));

    perform tst.expect_true('коэффициент: обновлён у всех работающих курьеров',
        format('select count(*) = 3 from courier where coefficient = 0.1 and courier_id in (%L, %L, %L)', c1, c2, c3));

    perform tst.expect_true('коэффициент: остальные колонки курьера не изменились',
        format('select md5((last_name, first_name, middle_name, phone_number, status, hire_date, dismissal_date)::text) = %L from courier where courier_id = %L', h, c1));
end $t$;


-- Проверяет выплату за месяц увольнения
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

    perform tst.expect_true('уволенный: коэффициент остался 0.3',
        format('select coefficient = 0.3 from courier where courier_id = %L', d));

    perform tst.expect_true('уволенный: контроль — у работающего с теми же данными coefficient обновился',
        format('select coefficient = 0.1 from courier where courier_id = %L', e));
end $t$;


-- Проверяет пересчёт выплаты после добавления доставок
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

    perform tst.mk_deliv(c, 5);

    perform tst.salary('повтор: второй вызов без исключений');

    perform tst.expect_true('повтор: запись обновлена, а не продублирована',
        format('select count(*) = 1 from courier_pay where courier_id = %L and %s', c, cur));

    perform tst.expect_true('повтор: выплата пересчитана с коэффициентом 0.3',
        format('select amount = 450 and coefficient_used = 0.3 from courier_pay where courier_id = %L and %s', c, cur));

    perform tst.expect_true('повтор: courier.coefficient соответствует числу доставок',
        format('select coefficient = 0.1 from courier where courier_id = %L', c));

    perform tst.salary('повтор: третий вызов без исключений');

    perform tst.expect_true('повтор: вызов без изменений данных даёт тот же результат',
        format('select count(*) = 1 and bool_and(amount = 450 and coefficient_used = 0.3) from courier_pay where courier_id = %L and %s', c, cur));
end $t$;


-- Проверяет расчёт при отсутствии доставок и при отсутствии курьеров
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


select count(*) filter (where ok) as passed,
       count(*) filter (where not ok) as failed,
       count(*) as total
from tst.result;

select id, test, details
from tst.result
where not ok
order by id;

rollback;
