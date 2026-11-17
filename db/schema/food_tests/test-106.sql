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

-- функция вычисляется заново при каждом обращении к представлению
create view tst.s as
select * from shkuratetskiy_food.get_statistic();


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


-- запрос возвращает текст с описанием нарушений
create function tst.expect_empty(p_test text, p_query text)
returns void language plpgsql as $$
declare
    v text;
begin
    execute p_query into v;
    insert into tst.result(test, ok, details)
    values (p_test, coalesce(v, '') = '', nullif(v, ''));
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


-- Построители данных (order_amount и pay_status считают триггеры)
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


-- заказ с одной позицией
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


create function tst.seen(p_col text, p_rest text, p_n int default 60) returns text[] language plpgsql as $$
declare
    v   text;
    res text[] := '{}';
    i   int;
begin
    for i in 1..p_n loop
        execute format('select %I::text from tst.s where restaurant_name = %L', p_col, p_rest) into v;
        res := res || coalesce(v, '<null>');
    end loop;

    return array(select distinct x from unnest(res) x order by 1);
end $$;


do $t$
begin
    perform tst.expect_true('контракт: имена и порядок колонок',
        $q$select proargnames = array['restaurant_name','best_product_name','total_amount','avg_amount','best_user']
           from pg_proc where oid = 'shkuratetskiy_food.get_statistic()'::regprocedure$q$);

    perform tst.expect_true('контракт: функция возвращает таблицу (set)',
        $q$select proretset from pg_proc where oid = 'shkuratetskiy_food.get_statistic()'::regprocedure$q$);
end $t$;


-- 1. Форма результата
do $t$
declare
    r1 uuid; r2 uuid; c uuid; a uuid; p uuid;
begin
    perform tst.wipe();

    r1 := tst.mk_rest('f_full');
    r2 := tst.mk_rest('f_open');
    perform tst.mk_rest('f_empty');

    c := tst.mk_client('form_user');
    a := tst.mk_addr(c);

    p := tst.mk_prod(r1, 'form_dish');
    perform tst.mk_order(a, r1, 'доставлен', p, 1);

    p := tst.mk_prod(r2, 'open_dish');
    perform tst.mk_order(a, r2, 'создан', p, 1);

    perform tst.expect_true('форма: одна строка на каждый ресторан',
        'select (select count(*) from tst.s) = (select count(*) from restaurant)');

    perform tst.expect_true('форма: названия ресторанов не дублируются',
        'select count(*) = count(distinct restaurant_name) from tst.s');

    perform tst.expect_true('форма: ресторан с доставленным заказом заполнен целиком',
        $q$select count(*) = 1 and bool_and(best_product_name is not null and total_amount is not null
                                            and avg_amount is not null and best_user is not null)
           from tst.s where restaurant_name = 'f_full'$q$);

    perform tst.expect_true('форма: ресторан только с недоставленным заказом — остальные колонки NULL',
        $q$select count(*) = 1 and bool_and(best_product_name is null and total_amount is null
                                            and avg_amount is null and best_user is null)
           from tst.s where restaurant_name = 'f_open'$q$);

    perform tst.expect_true('форма: ресторан без заказов — остальные колонки NULL',
        $q$select count(*) = 1 and bool_and(best_product_name is null and total_amount is null
                                            and avg_amount is null and best_user is null)
           from tst.s where restaurant_name = 'f_empty'$q$);
end $t$;


-- 2. Фильтр по статусу: недоставленные заказы не влияют ни на одну колонку
do $t$
declare
    r uuid; c1 uuid; c2 uuid; a1 uuid; a2 uuid; pd uuid; pn uuid;
    st order_status;
begin
    perform tst.wipe();

    r  := tst.mk_rest('st');
    c1 := tst.mk_client('delivered_user');
    c2 := tst.mk_client('noise_user');
    a1 := tst.mk_addr(c1);
    a2 := tst.mk_addr(c2);
    pd := tst.mk_prod(r, 'dish_del');
    pn := tst.mk_prod(r, 'dish_noise');

    perform tst.mk_order(a1, r, 'доставлен', pd, 1);

    -- создан, готовится, в_доставке, отменён: у шума и заказов больше, и блюда больше
    for st in select e from unnest(enum_range(null::order_status)) e where e != 'доставлен' loop
        perform tst.mk_order(a2, r, st, pn, 5);
    end loop;

    perform tst.expect_true('статус: best_product_name только по доставленным',
        $q$select best_product_name = 'dish_del' from tst.s where restaurant_name = 'st'$q$);

    perform tst.expect_true('статус: best_user только по доставленным',
        $q$select best_user = 'delivered_user' from tst.s where restaurant_name = 'st'$q$);

    perform tst.expect_true('статус: total_amount и avg_amount только по доставленным',
        $q$select total_amount = 1100 and avg_amount = 1100 from tst.s where restaurant_name = 'st'$q$);
end $t$;


-- 3. total_amount и avg_amount
do $t$
declare
    r1 uuid; r2 uuid; r3 uuid; c uuid; a uuid; p uuid;
begin
    perform tst.wipe();

    c := tst.mk_client('sum_user');
    a := tst.mk_addr(c);

    -- sm: итоги 1100, 2200, 3300
    r1 := tst.mk_rest('sm');
    p  := tst.mk_prod(r1, 'sm_dish');
    perform tst.mk_order(a, r1, 'доставлен', p, 1);
    perform tst.mk_order(a, r1, 'доставлен', p, 2);
    perform tst.mk_order(a, r1, 'доставлен', p, 3);

    -- чужой ресторан с одним крупным заказом
    r2 := tst.mk_rest('other');
    p  := tst.mk_prod(r2, 'other_dish');
    perform tst.mk_order(a, r2, 'доставлен', p, 10);

    -- rnd: итоги 1100, 1100, 1210 -> avg 1136.666... (ожидается округление до 2 знаков)
    r3 := tst.mk_rest('rnd');
    p  := tst.mk_prod(r3, 'rnd_dish', 'кг');
    perform tst.mk_order(a, r3, 'доставлен', p, 1);
    perform tst.mk_order(a, r3, 'доставлен', p, 1);
    perform tst.mk_order(a, r3, 'доставлен', p, 1.1);

    perform tst.expect_true('суммы: total и avg по ресторану',
        $q$select total_amount = 6600 and avg_amount = 2200 from tst.s where restaurant_name = 'sm'$q$);

    perform tst.expect_true('суммы: заказы разных ресторанов не смешиваются',
        $q$select total_amount = 11000 and avg_amount = 11000 from tst.s where restaurant_name = 'other'$q$);

    perform tst.expect_true('суммы: avg округляется до 2 знаков',
        $q$select total_amount = 3410 and avg_amount = 1136.67 from tst.s where restaurant_name = 'rnd'$q$);

    perform tst.expect_empty('суммы: total_amount >= avg_amount везде',
        $q$select string_agg(restaurant_name, ', ') from tst.s where total_amount < avg_amount$q$);
end $t$;


-- 4. best_product_name
do $t$
declare
    r1 uuid; r2 uuid; r3 uuid; c uuid; a uuid; p1 uuid; p2 uuid; p3 uuid;
begin
    perform tst.wipe();

    c := tst.mk_client('prod_user');
    a := tst.mk_addr(c);

    -- победа по SUM(quantity), а не по числу заказов: 3 заказа по 1 шт. против одного на 5 шт.
    r1 := tst.mk_rest('bp');
    p1 := tst.mk_prod(r1, 'many_orders');
    p2 := tst.mk_prod(r1, 'big_qty');
    perform tst.mk_order(a, r1, 'доставлен', p1, 1);
    perform tst.mk_order(a, r1, 'доставлен', p1, 1);
    perform tst.mk_order(a, r1, 'доставлен', p1, 1);
    perform tst.mk_order(a, r1, 'доставлен', p2, 5);

    -- дробное количество суммируется без округления: 1.9 + 1.9 = 3.8 против 3
    r2 := tst.mk_rest('fr');
    p1 := tst.mk_prod(r2, 'int_dish');
    p2 := tst.mk_prod(r2, 'kg_dish', 'кг');
    perform tst.mk_order(a, r2, 'доставлен', p1, 3);
    perform tst.mk_order(a, r2, 'доставлен', p2, 1.9);
    perform tst.mk_order(a, r2, 'доставлен', p2, 1.9);

    -- равенство: два лидера по 2 шт., третье блюдо слабее
    r3 := tst.mk_rest('tp');
    p1 := tst.mk_prod(r3, 'tie_a');
    p2 := tst.mk_prod(r3, 'tie_b');
    p3 := tst.mk_prod(r3, 'low');
    perform tst.mk_order(a, r3, 'доставлен', p1, 2);
    perform tst.mk_order(a, r3, 'доставлен', p2, 2);
    perform tst.mk_order(a, r3, 'доставлен', p3, 1);

    perform tst.expect_true('блюдо: победа по сумме количества, а не по числу заказов',
        $q$select best_product_name = 'big_qty' from tst.s where restaurant_name = 'bp'$q$);

    perform tst.expect_true('блюдо: дробное количество (кг) суммируется корректно',
        $q$select best_product_name = 'kg_dish' from tst.s where restaurant_name = 'fr'$q$);

    perform tst.expect_true('блюдо: при равенстве ровно одна строка',
        $q$select count(*) = 1 from tst.s where restaurant_name = 'tp'$q$);

    perform tst.expect_true('блюдо: при равенстве выбор только из лидеров и выпадают оба',
        $q$select tst.seen('best_product_name', 'tp') = array['tie_a', 'tie_b']$q$);
end $t$;


-- 5. best_user
do $t$
declare
    r1 uuid; r2 uuid; p uuid; cf uuid; ro uuid; tx uuid; ty uuid;
    a1 uuid; a2 uuid; a3 uuid; ra uuid; xa uuid; ya uuid;
begin
    perform tst.wipe();

    -- cheap_fan: 3 дешёвых заказа с трёх разных адресов; rich_one: 2 дорогих с одного.
    -- Группировка по адресу или по сумме дала бы rich_one.
    r1 := tst.mk_rest('bu');
    p  := tst.mk_prod(r1, 'bu_dish');
    cf := tst.mk_client('cheap_fan');
    ro := tst.mk_client('rich_one');
    a1 := tst.mk_addr(cf);
    a2 := tst.mk_addr(cf);
    a3 := tst.mk_addr(cf);
    ra := tst.mk_addr(ro);

    perform tst.mk_order(a1, r1, 'доставлен', p, 1);
    perform tst.mk_order(a2, r1, 'доставлен', p, 1);
    perform tst.mk_order(a3, r1, 'доставлен', p, 1);
    perform tst.mk_order(ra, r1, 'доставлен', p, 50);
    perform tst.mk_order(ra, r1, 'доставлен', p, 50);

    -- равенство: по 2 заказа
    r2 := tst.mk_rest('tu');
    p  := tst.mk_prod(r2, 'tu_dish');
    tx := tst.mk_client('tie_x');
    ty := tst.mk_client('tie_y');
    xa := tst.mk_addr(tx);
    ya := tst.mk_addr(ty);

    perform tst.mk_order(xa, r2, 'доставлен', p, 1);
    perform tst.mk_order(xa, r2, 'доставлен', p, 1);
    perform tst.mk_order(ya, r2, 'доставлен', p, 1);
    perform tst.mk_order(ya, r2, 'доставлен', p, 1);

    perform tst.expect_true('клиент: победа по числу заказов, а не по сумме; адреса клиента объединяются',
        $q$select best_user = 'cheap_fan' from tst.s where restaurant_name = 'bu'$q$);

    perform tst.expect_true('клиент: при равенстве ровно одна строка',
        $q$select count(*) = 1 from tst.s where restaurant_name = 'tu'$q$);

    perform tst.expect_true('клиент: при равенстве выбор только из лидеров и выпадают оба',
        $q$select tst.seen('best_user', 'tu') = array['tie_x', 'tie_y']$q$);
end $t$;


-- 6. Заказы без клиента (client удалён -> client_address.client_id = NULL)
do $t$
declare
    r1 uuid; r2 uuid; p uuid; gone uuid; stay uuid; ga uuid; sa uuid;
begin
    perform tst.wipe();

    -- у ушедшего клиента заказов больше, но он не может быть best_user
    r1   := tst.mk_rest('nc1');
    p    := tst.mk_prod(r1, 'nc1_dish');
    gone := tst.mk_client('gone_big');
    stay := tst.mk_client('stays');
    ga   := tst.mk_addr(gone);
    sa   := tst.mk_addr(stay);

    perform tst.mk_order(ga, r1, 'доставлен', p, 1);
    perform tst.mk_order(ga, r1, 'доставлен', p, 1);
    perform tst.mk_order(ga, r1, 'доставлен', p, 1);
    perform tst.mk_order(sa, r1, 'доставлен', p, 1);

    -- все доставленные заказы без клиента
    r2 := tst.mk_rest('nc2');
    p  := tst.mk_prod(r2, 'nc2_dish');
    ga := tst.mk_addr(tst.mk_client('gone_only'));

    perform tst.mk_order(ga, r2, 'доставлен', p, 1);
    perform tst.mk_order(ga, r2, 'доставлен', p, 1);

    delete from client where login in ('gone_big', 'gone_only');

    perform tst.expect_true('без клиента: заказ входит в total_amount и avg_amount',
        $q$select total_amount = 4400 and avg_amount = 1100 from tst.s where restaurant_name = 'nc1'$q$);

    perform tst.expect_true('без клиента: заказ не участвует в выборе best_user',
        $q$select best_user = 'stays' from tst.s where restaurant_name = 'nc1'$q$);

    perform tst.expect_true('без клиента: все заказы без клиента -> best_user NULL, остальное заполнено',
        $q$select count(*) = 1 and bool_and(best_user is null and best_product_name = 'nc2_dish'
                                            and total_amount = 2200 and avg_amount = 1100)
           from tst.s where restaurant_name = 'nc2'$q$);
end $t$;


-- 7. Заказ без ресторана
-- Триггеры-защитники не дают обнулить ресторан напрямую, поэтому на время апдейта отключаем их
do $t$
declare
    r uuid; c uuid; a uuid; p uuid; o uuid;
begin
    perform tst.wipe();

    r := tst.mk_rest('nr');
    c := tst.mk_client('nr_user');
    a := tst.mk_addr(c);
    p := tst.mk_prod(r, 'nr_dish');

    perform tst.mk_order(a, r, 'доставлен', p, 1);
    o := tst.mk_order(a, r, 'доставлен', p, 50);

    alter table "order" disable trigger trg_order_parties_guard;
    alter table "order" disable trigger trg_order_restaurant_guard;
    update "order" set restaurant_id = null where order_id = o;
    alter table "order" enable trigger trg_order_parties_guard;
    alter table "order" enable trigger trg_order_restaurant_guard;

    perform tst.expect_true('без ресторана: заказ не попадает ни в один ресторан и не ломает функцию',
        $q$select count(*) = 1 and bool_and(total_amount = 1100 and avg_amount = 1100)
           from tst.s where restaurant_name = 'nr'$q$);

    perform tst.expect_true('без ресторана: нет лишних строк, одна на ресторан',
        'select (select count(*) from tst.s) = (select count(*) from restaurant)');

    perform tst.expect_true('без ресторана: нет строки с NULL в restaurant_name',
        'select not exists (select 1 from tst.s where restaurant_name is null)');
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