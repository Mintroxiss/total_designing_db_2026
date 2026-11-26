-- Требует запуска в тестовой базе
begin;

set local search_path to shkuratetskiy_food, exts, pg_temp;

create temp table result (
    id      int generated always as identity primary key,
    test    text    not null,
    ok      boolean not null,
    details text
);

create temp sequence seq;

create temp table ctx (ca uuid, rest uuid, prod uuid, courier uuid);


create function pg_temp.expect_true(p_test text, p_query text)
returns void language plpgsql as $$
declare
    b boolean;
begin
    execute p_query into b;
    insert into pg_temp.result(test, ok, details)
    values (p_test, coalesce(b, false), case when b is true then null else 'условие ложно/NULL: ' || p_query end);
exception when others then
    insert into pg_temp.result(test, ok, details) values (p_test, false, sqlstate || ': ' || sqlerrm);
end $$;


create function pg_temp.wipe() returns void language plpgsql as $$
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


create function pg_temp.mk_rest(p_name text) returns uuid language plpgsql as $$
declare
    a uuid;
    r uuid;
begin
    insert into address(street, house_number)
    values ('рест ' || nextval('pg_temp.seq'), '1')
    returning address_id into a;

    insert into restaurant(restaurant_name, address_id, description, work_start, work_end, inn, ogrn, bank_account, status)
    values (p_name, a, 'д', '09:00', '22:00', '1234567890', '1234567890123', '12345678901234567890', 'активен')
    returning restaurant_id into r;

    return r;
end $$;


create function pg_temp.mk_client(p_login text) returns uuid language plpgsql as $$
declare
    c uuid;
begin
    insert into client(login, password, phone_number)
    values (p_login, md5(p_login), '+79' || lpad(nextval('pg_temp.seq')::text, 9, '0'))
    returning client_id into c;

    return c;
end $$;


create function pg_temp.mk_addr(p_client uuid) returns uuid language plpgsql as $$
declare
    a  uuid;
    ca uuid;
begin
    insert into address(street, house_number)
    values ('кл ' || nextval('pg_temp.seq'), '1')
    returning address_id into a;

    insert into client_address(client_id, address_id)
    values (p_client, a)
    returning client_address_id into ca;

    return ca;
end $$;


create function pg_temp.mk_courier() returns uuid language plpgsql as $$
declare
    c uuid;
begin
    insert into courier(last_name, first_name, middle_name, phone_number, status, hire_date)
    values ('Курьер ' || nextval('pg_temp.seq'), 'Иван', 'Иванович',
            '+79' || lpad(nextval('pg_temp.seq')::text, 9, '0'), 'свободен', '2025-01-01')
    returning courier_id into c;

    return c;
end $$;


create function pg_temp.setup() returns void language plpgsql as $$
declare
    r uuid;
    a uuid;
    cat uuid;
    p uuid;
    c uuid;
begin
    perform pg_temp.wipe();
    delete from pg_temp.ctx;

    r := pg_temp.mk_rest('r');
    a := pg_temp.mk_addr(pg_temp.mk_client('rep_user'));
    c := pg_temp.mk_courier();

    insert into product_category(product_category_name)
    values ('категория') returning product_category_id into cat;

    insert into product(product_name, product_category_id, price, restaurant_id,
                        status, description, measure_unit)
    values ('блюдо', cat, 1000, r, 'доступно', 'д', 'шт')
    returning product_id into p;

    insert into pg_temp.ctx values (a, r, p, c);
end $$;


create function pg_temp.mk_order(p_status order_status, p_ts timestamp,
                             p_amount numeric, p_created timestamp default null)
returns void language plpgsql as $$
declare
    x record;
    o uuid;
begin
    select * into strict x from pg_temp.ctx;

    update product set price = p_amount where product_id = x.prod;

    insert into "order"(courier_id, client_address_id, restaurant_id,
                        order_timestamp, status)
    values (x.courier, x.ca, x.rest,
            coalesce(p_created, case when p_status = 'доставлен'
                                    then p_ts - interval '1 minute'
                                    else p_ts end), 'создан')
    returning order_id into o;

    insert into order_structure(order_id, product_id, quantity, price)
    select o, product_id, 1, price from product where product_id = x.prod;

    if p_status = 'доставлен' then
        insert into payment(order_id, payment_type, amount, transaction_id,
                            transaction_timestamp, status)
        select order_id, 'карта', total_amount, 'rep-tx-' || nextval('pg_temp.seq'),
               p_ts, 'успех'
        from "order" where order_id = o;

        update "order"
           set status = 'доставлен', delivery_timestamp = p_ts
         where order_id = o;
    elsif p_status != 'создан' then
        update "order" set status = p_status where order_id = o;
    end if;
end $$;


create function pg_temp.mk_deliv(p_ts timestamp, p_amount numeric default 1000, p_created timestamp default null)
returns void language plpgsql as $$
begin
    perform pg_temp.mk_order('доставлен', p_ts, p_amount, p_created);
end $$;


create function pg_temp.mk_other(p_status order_status, p_ts timestamp, p_amount numeric default 5000)
returns void language plpgsql as $$
begin
    perform pg_temp.mk_order(p_status, p_ts, p_amount);
end $$;


create function pg_temp.mk_pay(p_courier uuid, p_year int, p_month int, p_amount numeric) returns void language plpgsql as $$
begin
    insert into courier_pay(year, month, courier_id, amount, coefficient_used)
    values (p_year, p_month, p_courier, p_amount, 0.1);
end $$;


-- Проверяет диапазон месяцев
do $t$
begin
    perform pg_temp.setup();

    perform pg_temp.expect_true('серия: нет доставленных заказов — представление пустое',
        'select count(*) = 0 from how_much_money');

    perform pg_temp.mk_other('создан', '2026-03-10');

    perform pg_temp.expect_true('серия: только недоставленные заказы — представление пустое',
        'select count(*) = 0 from how_much_money');

    perform pg_temp.mk_deliv('2026-03-15 12:00');

    perform pg_temp.expect_true('серия: один месяц — ровно одна строка',
        $q$select count(*) = 1 and bool_and(year_month = '2026-03') from how_much_money$q$);

    -- Проверяет переход между годами с двумя месяцами без доставок
    perform pg_temp.setup();
    perform pg_temp.mk_deliv('2025-11-15 12:00');
    perform pg_temp.mk_deliv('2026-02-10 12:00');

    perform pg_temp.expect_true('серия: все месяцы от первого до последнего, без пропусков и дублей, формат YYYY-MM',
        $q$select array_agg(year_month order by year_month) = array['2025-11','2025-12','2026-01','2026-02'] from how_much_money$q$);

    perform pg_temp.expect_true('серия: месяцы без заказов — нулевые суммы',
        $q$select count(*) = 2 and bool_and(sum_no_commission = 0 and sum_with_commission = 0 and commission = 0)
           from how_much_money where year_month in ('2025-12', '2026-01')$q$);
end $t$;


-- Проверяет отбор по статусу и дате доставки
do $t$
declare
    st order_status;
begin
    perform pg_temp.setup();

    perform pg_temp.mk_deliv('2026-03-01 00:00:00', 1000);
    perform pg_temp.mk_deliv('2026-02-28 23:59:59', 2000);
    perform pg_temp.mk_deliv('2026-03-05 12:00', 3000, '2026-02-20 12:00');

    -- Добавляет недоставленные заказы за пределами периода доставок
    for st in select e from unnest(enum_range(null::order_status)) e where e != 'доставлен' loop
        perform pg_temp.mk_other(st, '2026-05-10');
        perform pg_temp.mk_other(st, '2025-12-10');
    end loop;

    perform pg_temp.expect_true('учёт: диапазон задают только доставленные заказы',
        $q$select array_agg(year_month order by year_month) = array['2026-02','2026-03'] from how_much_money$q$);

    perform pg_temp.expect_true('учёт: февраль — заказ за секунду до границы',
        $q$select sum_no_commission = 2000 and sum_with_commission = 2200 from how_much_money where year_month = '2026-02'$q$);

    perform pg_temp.expect_true('учёт: март — заказ на границе и заказ, доставленный в марте, но созданный в феврале',
        $q$select sum_no_commission = 4000 and sum_with_commission = 4400 from how_much_money where year_month = '2026-03'$q$);
end $t$;


-- Проверяет суммы заказов и комиссий
do $t$
begin
    perform pg_temp.setup();

    perform pg_temp.mk_deliv('2026-01-10 12:00', 1000);
    perform pg_temp.mk_deliv('2026-01-20 12:00', 1000.55);
    perform pg_temp.mk_deliv('2026-02-10 12:00', 3000);

    perform pg_temp.expect_true('суммы: январь — суммы и комиссия = итог минус сумма без комиссии',
        $q$select sum_no_commission = 2000.55 and sum_with_commission = 2200.61 and commission = 200.06
           from how_much_money where year_month = '2026-01'$q$);

    perform pg_temp.expect_true('суммы: февраль не смешивается с январём',
        $q$select sum_no_commission = 3000 and sum_with_commission = 3300 and commission = 300
           from how_much_money where year_month = '2026-02'$q$);
end $t$;


-- Сравнивает комиссии соседних месяцев
do $t$
begin
    perform pg_temp.setup();

    perform pg_temp.mk_deliv('2026-01-10 12:00', 2000);
    perform pg_temp.mk_deliv('2026-03-10 12:00', 1000);
    perform pg_temp.mk_deliv('2026-04-10 12:00', 5000);

    perform pg_temp.expect_true('сравнение: первый месяц — prev_commission и commission_diff NULL',
        $q$select prev_commission is null and commission_diff is null from how_much_money where year_month = '2026-01'$q$);

    perform pg_temp.expect_true('сравнение: пустой месяц — prev = комиссия января, diff отрицательный',
        $q$select prev_commission = 200 and commission = 0 and commission_diff = -200
           from how_much_money where year_month = '2026-02'$q$);

    perform pg_temp.expect_true('сравнение: после пустого месяца prev = 0',
        $q$select prev_commission = 0 and commission_diff = 100 from how_much_money where year_month = '2026-03'$q$);

    perform pg_temp.expect_true('сравнение: обычный месяц — prev и diff от предыдущей строки',
        $q$select prev_commission = 100 and commission_diff = 400 from how_much_money where year_month = '2026-04'$q$);
end $t$;


-- Проверяет выплаты курьерам и чистую прибыль
do $t$
declare
    c1 uuid; c2 uuid;
begin
    perform pg_temp.setup();

    perform pg_temp.mk_deliv('2026-01-10 12:00', 2000);
    perform pg_temp.mk_deliv('2026-02-10 12:00', 1000);
    perform pg_temp.mk_deliv('2026-04-10 12:00', 1000);
    perform pg_temp.mk_deliv('2026-06-10 12:00', 1000);

    c1 := pg_temp.mk_courier();
    c2 := pg_temp.mk_courier();

    perform pg_temp.mk_pay(c1, 2026, 1, 50);
    perform pg_temp.mk_pay(c2, 2026, 1, 30);
    perform pg_temp.mk_pay(c1, 2026, 2, 150);
    perform pg_temp.mk_pay(c1, 2026, 5, 40); -- добавляет выплату за месяц без заказов
    perform pg_temp.mk_pay(c1, 2026, 7, 99); -- добавляет выплату после последней доставки

    perform pg_temp.expect_true('выплаты: январь — сумма выплат всех курьеров, net_profit = комиссия − выплаты',
        $q$select courier_pay = 80 and net_profit = 120 from how_much_money where year_month = '2026-01'$q$);

    perform pg_temp.expect_true('выплаты: выплаты больше комиссии — net_profit отрицательный',
        $q$select courier_pay = 150 and net_profit = -50 from how_much_money where year_month = '2026-02'$q$);

    perform pg_temp.expect_true('выплаты: месяц без заказов и без выплат — нули, не NULL',
        $q$select courier_pay = 0 and net_profit = 0 from how_much_money where year_month = '2026-03'$q$);

    perform pg_temp.expect_true('выплаты: месяц с заказами, но без выплат — courier_pay = 0, net_profit = комиссия',
        $q$select courier_pay = 0 and net_profit = 100 from how_much_money where year_month = '2026-04'$q$);

    perform pg_temp.expect_true('выплаты: при выплате 40 за месяц без доставок net_profit равен -40',
        $q$select commission = 0 and courier_pay = 40 and net_profit = -40 from how_much_money where year_month = '2026-05'$q$);

    perform pg_temp.expect_true('выплаты: выплата после последнего доставленного заказа не расширяет диапазон',
        $q$select count(*) = 6 and max(year_month) = '2026-06' from how_much_money$q$);
end $t$;


select count(*) filter (where ok) as passed,
       count(*) filter (where not ok) as failed,
       count(*) as total
from pg_temp.result;

select id, test, details
from pg_temp.result
where not ok
order by id;

rollback;
