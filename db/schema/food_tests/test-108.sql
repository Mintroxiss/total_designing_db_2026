-- Актуальная схема shkuratetskiy_food. Запускать весь скрипт в тестовой БД.
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

-- общие объекты сценария: адрес клиента, ресторан, блюдо и курьер
create table tst.ctx (ca uuid, rest uuid, prod uuid, courier uuid);


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


-- Построители данных
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


create function tst.mk_courier() returns uuid language plpgsql as $$
declare
    c uuid;
begin
    insert into courier(last_name, first_name, middle_name, phone_number, status, hire_date)
    values ('Курьер ' || nextval('tst.seq'), 'Иван', 'Иванович',
            '+79' || lpad(nextval('tst.seq')::text, 9, '0'), 'свободен', '2025-01-01')
    returning courier_id into c;

    return c;
end $$;


-- чистая база + общие объекты сценария
create function tst.setup() returns void language plpgsql as $$
declare
    r uuid;
    a uuid;
    cat uuid;
    p uuid;
    c uuid;
begin
    perform tst.wipe();
    delete from tst.ctx;

    r := tst.mk_rest('r');
    a := tst.mk_addr(tst.mk_client('rep_user'));
    c := tst.mk_courier();

    insert into product_category(product_category_name)
    values ('категория') returning product_category_id into cat;

    insert into product(product_name, product_category_id, price, restaurant_id,
                        status, description, measure_unit)
    values ('блюдо', cat, 1000, r, 'доступно', 'д', 'шт')
    returning product_id into p;

    insert into tst.ctx values (a, r, p, c);
end $$;


-- Создаём заказ с назначенным курьером и одной позицией.
-- Цена позиции фиксирует стоимость заказа; суммы вычисляют триггеры.
create function tst.mk_order(p_status order_status, p_ts timestamp,
                             p_amount numeric, p_created timestamp default null)
returns void language plpgsql as $$
declare
    x record;
    o uuid;
begin
    select * into strict x from tst.ctx;

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
        select order_id, 'карта', total_amount, 'rep-tx-' || nextval('tst.seq'),
               p_ts, 'успех'
        from "order" where order_id = o;

        update "order"
           set status = 'доставлен', delivery_timestamp = p_ts
         where order_id = o;
    elsif p_status != 'создан' then
        update "order" set status = p_status where order_id = o;
    end if;
end $$;


create function tst.mk_deliv(p_ts timestamp, p_amount numeric default 1000, p_created timestamp default null)
returns void language plpgsql as $$
begin
    perform tst.mk_order('доставлен', p_ts, p_amount, p_created);
end $$;


create function tst.mk_other(p_status order_status, p_ts timestamp, p_amount numeric default 5000)
returns void language plpgsql as $$
begin
    perform tst.mk_order(p_status, p_ts, p_amount);
end $$;


create function tst.mk_pay(p_courier uuid, p_year int, p_month int, p_amount numeric) returns void language plpgsql as $$
begin
    insert into courier_pay(year, month, courier_id, amount, coefficient_used)
    values (p_year, p_month, p_courier, p_amount, 0.1);
end $$;


-- 1. Серия месяцев
do $t$
begin
    perform tst.setup();

    perform tst.expect_true('серия: нет доставленных заказов — представление пустое',
        'select count(*) = 0 from how_much_money');

    -- недоставленный заказ диапазон не создаёт
    perform tst.mk_other('создан', '2026-03-10');

    perform tst.expect_true('серия: только недоставленные заказы — представление пустое',
        'select count(*) = 0 from how_much_money');

    -- один месяц
    perform tst.mk_deliv('2026-03-15 12:00');

    perform tst.expect_true('серия: один месяц — ровно одна строка',
        $q$select count(*) = 1 and bool_and(year_month = '2026-03') from how_much_money$q$);

    -- 2025-11 .. 2026-02: переход через границу года, месяцы 12 и 01 без заказов
    perform tst.setup();
    perform tst.mk_deliv('2025-11-15 12:00');
    perform tst.mk_deliv('2026-02-10 12:00');

    perform tst.expect_true('серия: все месяцы от первого до последнего, без пропусков и дублей, формат YYYY-MM',
        $q$select array_agg(year_month order by year_month) = array['2025-11','2025-12','2026-01','2026-02'] from how_much_money$q$);

    perform tst.expect_true('серия: месяцы без заказов — нулевые суммы',
        $q$select count(*) = 2 and bool_and(sum_no_commission = 0 and sum_with_commission = 0 and commission = 0)
           from how_much_money where year_month in ('2025-12', '2026-01')$q$);
end $t$;


-- 2. Какие заказы и в какой месяц попадают
do $t$
declare
    st order_status;
begin
    perform tst.setup();

    perform tst.mk_deliv('2026-03-01 00:00:00', 1000); -- ровно начало месяца: март
    perform tst.mk_deliv('2026-02-28 23:59:59', 2000); -- за секунду до: февраль
    perform tst.mk_deliv('2026-03-05 12:00', 3000, '2026-02-20 12:00'); -- создан в феврале, доставлен в марте: март

    -- создан, готовится, в_доставке, отменён: ни в суммах, ни в диапазоне (раньше и позже доставленных)
    for st in select e from unnest(enum_range(null::order_status)) e where e != 'доставлен' loop
        perform tst.mk_other(st, '2026-05-10');
        perform tst.mk_other(st, '2025-12-10');
    end loop;

    perform tst.expect_true('учёт: диапазон задают только доставленные заказы',
        $q$select array_agg(year_month order by year_month) = array['2026-02','2026-03'] from how_much_money$q$);

    perform tst.expect_true('учёт: февраль — заказ за секунду до границы',
        $q$select sum_no_commission = 2000 and sum_with_commission = 2200 from how_much_money where year_month = '2026-02'$q$);

    perform tst.expect_true('учёт: март — заказ на границе и заказ, доставленный в марте, но созданный в феврале',
        $q$select sum_no_commission = 4000 and sum_with_commission = 4400 from how_much_money where year_month = '2026-03'$q$);
end $t$;


-- 3. Суммы и комиссия
do $t$
begin
    perform tst.setup();

    -- январь: 1000 -> 1100.00 и 1000.55 -> 1100.61; февраль: 3000 -> 3300
    perform tst.mk_deliv('2026-01-10 12:00', 1000);
    perform tst.mk_deliv('2026-01-20 12:00', 1000.55);
    perform tst.mk_deliv('2026-02-10 12:00', 3000);

    perform tst.expect_true('суммы: январь — суммы и комиссия = итог минус сумма без комиссии',
        $q$select sum_no_commission = 2000.55 and sum_with_commission = 2200.61 and commission = 200.06
           from how_much_money where year_month = '2026-01'$q$);

    perform tst.expect_true('суммы: февраль не смешивается с январём',
        $q$select sum_no_commission = 3000 and sum_with_commission = 3300 and commission = 300
           from how_much_money where year_month = '2026-02'$q$);
end $t$;


-- 4. prev_commission и commission_diff: январь 200, февраль 0, март 100, апрель 500
do $t$
begin
    perform tst.setup();

    perform tst.mk_deliv('2026-01-10 12:00', 2000);
    perform tst.mk_deliv('2026-03-10 12:00', 1000);
    perform tst.mk_deliv('2026-04-10 12:00', 5000);

    perform tst.expect_true('сравнение: первый месяц — prev_commission и commission_diff NULL',
        $q$select prev_commission is null and commission_diff is null from how_much_money where year_month = '2026-01'$q$);

    perform tst.expect_true('сравнение: пустой месяц — prev = комиссия января, diff отрицательный',
        $q$select prev_commission = 200 and commission = 0 and commission_diff = -200
           from how_much_money where year_month = '2026-02'$q$);

    perform tst.expect_true('сравнение: после пустого месяца prev = 0',
        $q$select prev_commission = 0 and commission_diff = 100 from how_much_money where year_month = '2026-03'$q$);

    perform tst.expect_true('сравнение: обычный месяц — prev и diff от предыдущей строки',
        $q$select prev_commission = 100 and commission_diff = 400 from how_much_money where year_month = '2026-04'$q$);
end $t$;


-- 5. courier_pay и net_profit: заказы в январе, феврале, апреле и июне
do $t$
declare
    c1 uuid; c2 uuid;
begin
    perform tst.setup();

    perform tst.mk_deliv('2026-01-10 12:00', 2000); -- комиссия 200
    perform tst.mk_deliv('2026-02-10 12:00', 1000); -- комиссия 100
    perform tst.mk_deliv('2026-04-10 12:00', 1000); -- комиссия 100
    perform tst.mk_deliv('2026-06-10 12:00', 1000); -- комиссия 100

    c1 := tst.mk_courier();
    c2 := tst.mk_courier();

    perform tst.mk_pay(c1, 2026, 1, 50);
    perform tst.mk_pay(c2, 2026, 1, 30);
    perform tst.mk_pay(c1, 2026, 2, 150);
    perform tst.mk_pay(c1, 2026, 5, 40); -- месяц без заказов
    perform tst.mk_pay(c1, 2026, 7, 99); -- после последнего доставленного заказа

    perform tst.expect_true('выплаты: январь — сумма выплат всех курьеров, net_profit = комиссия − выплаты',
        $q$select courier_pay = 80 and net_profit = 120 from how_much_money where year_month = '2026-01'$q$);

    perform tst.expect_true('выплаты: выплаты больше комиссии — net_profit отрицательный',
        $q$select courier_pay = 150 and net_profit = -50 from how_much_money where year_month = '2026-02'$q$);

    perform tst.expect_true('выплаты: месяц без заказов и без выплат — нули, не NULL',
        $q$select courier_pay = 0 and net_profit = 0 from how_much_money where year_month = '2026-03'$q$);

    perform tst.expect_true('выплаты: месяц с заказами, но без выплат — courier_pay = 0, net_profit = комиссия',
        $q$select courier_pay = 0 and net_profit = 100 from how_much_money where year_month = '2026-04'$q$);

    perform tst.expect_true('выплаты: месяц без заказов, но с выплатой — net_profit = −выплата',
        $q$select commission = 0 and courier_pay = 40 and net_profit = -40 from how_much_money where year_month = '2026-05'$q$);

    perform tst.expect_true('выплаты: выплата после последнего доставленного заказа не расширяет диапазон',
        $q$select count(*) = 6 and max(year_month) = '2026-06' from how_much_money$q$);
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