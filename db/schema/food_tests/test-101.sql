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

-- Инфраструктура
create function tst.expect_error(p_test text, p_sql text, p_sqlstate text default null, p_msg text default null)
returns void language plpgsql as $$
declare
    st  text;
    msg text;
begin
    begin
        execute p_sql;
        execute 'set constraints all deferred';
    exception when others then
        get stacked diagnostics st = returned_sqlstate, msg = message_text;
        if p_sqlstate is not null and st != p_sqlstate then
            insert into tst.result(test, ok, details)
            values (p_test, false, format('ожидался SQLSTATE %s, получен %s: %s', p_sqlstate, st, msg));
        elsif p_msg is not null and position(p_msg in msg) = 0 then
            insert into tst.result(test, ok, details)
            values (p_test, false, format('сообщение «%s» не содержит «%s»', msg, p_msg));
        else
            insert into tst.result(test, ok) values (p_test, true);
        end if;
        return;
    end;
    insert into tst.result(test, ok, details) values (p_test, false, 'ожидалась ошибка, но запрос выполнился');
end $$;

create function tst.expect_ok(p_test text, p_sql text)
returns void language plpgsql as $$
begin
    execute p_sql;
    execute 'set constraints all deferred';
    insert into tst.result(test, ok) values (p_test, true);
exception when others then
    insert into tst.result(test, ok, details) values (p_test, false, sqlstate || ': ' || sqlerrm);
end $$;

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

create function tst.rnd(n int default 8) returns text language sql as $$
    select substr(md5(random()::text || clock_timestamp()::text), 1, n)
$$;

create function tst.phone() returns text language sql as $$
    select '+79' || lpad((floor(random() * 1e9))::bigint::text, 9, '0')
$$;

-- обёртка для проверки отложенных триггеров (BR-9.1)
create function tst.chk(p_sql text) returns text language sql as $$
    select 'set constraints all deferred; ' || p_sql || '; set constraints all immediate'
$$;

-- Фабрики данных
create function tst.mk_address() returns uuid language plpgsql as $$
declare id uuid;
begin
    insert into address(street, house_number) values ('ул. ' || tst.rnd(12), tst.rnd(4))
    returning address_id into id;
    return id;
end $$;

create function tst.mk_client() returns uuid language plpgsql as $$
declare id uuid;
begin
    insert into client(login, password, phone_number)
    values ('u' || tst.rnd(10), md5(random()::text), tst.phone())
    returning client_id into id;
    return id;
end $$;

create function tst.mk_client_address(p_client uuid default null) returns uuid language plpgsql as $$
declare
    c  uuid := coalesce(p_client, tst.mk_client());
    id uuid;
begin
    insert into client_address(client_id, address_id) values (c, tst.mk_address())
    returning client_address_id into id;
    return id;
end $$;

create function tst.mk_restaurant() returns uuid language plpgsql as $$
declare id uuid;
begin
    insert into restaurant(restaurant_name, address_id, description, work_start, work_end, company_details, status)
    values ('Р ' || tst.rnd(), tst.mk_address(), 'описание', '09:00', '22:00', 'реквизиты', 'активен')
    returning restaurant_id into id;
    return id;
end $$;

create function tst.mk_product(p_rest uuid, p_price numeric default 1000,
                               p_unit measure_unit default 'шт', p_status product_status default 'доступно')
returns uuid language plpgsql as $$
declare
    cat uuid;
    id  uuid;
begin
    insert into product_category(product_category_name) values ('к ' || tst.rnd()) returning product_category_id into cat;
    insert into product(product_name, product_category_id, price, restaurant_id, status, description, measure_unit)
    values ('п ' || tst.rnd(), cat, p_price, p_rest, p_status, 'описание', p_unit)
    returning product_id into id;
    return id;
end $$;

create function tst.mk_courier(p_status courier_status default 'свободен') returns uuid language plpgsql as $$
declare id uuid;
begin
    insert into courier(full_name, phone_number, status, hire_date, dismissal_date)
    values ('К ' || tst.rnd(), tst.phone(), p_status, current_date - 30,
            case when p_status = 'уволен' then current_date end)
    returning courier_id into id;
    return id;
end $$;

create function tst.mk_order(p_ca uuid, p_rest uuid, p_courier uuid default null) returns uuid language plpgsql as $$
declare id uuid;
begin
    insert into "order"(client_address_id, restaurant_id, courier_id, status)
    values (p_ca, p_rest, p_courier, 'создан')
    returning order_id into id;
    return id;
end $$;

-- Заказ с двумя позициями по 1000 руб (order_amount = 2000, total_amount = 2200)
create function tst.mk_order_full(p_paid boolean default false, p_delivered boolean default false,
                                  out o uuid, out r uuid, out p uuid, out p2 uuid, out ca uuid)
language plpgsql as $$
begin
    r  := tst.mk_restaurant();
    ca := tst.mk_client_address();
    p  := tst.mk_product(r);
    p2 := tst.mk_product(r);
    o  := tst.mk_order(ca, r);
    insert into order_structure(order_id, product_id, quantity) values (o, p, 1), (o, p2, 1);
    if p_paid or p_delivered then
        insert into payment(order_id, payment_type, transaction_id, status)
        values (o, 'карта', tst.rnd(24), 'успех');
    end if;
    if p_delivered then
        update "order" set status = 'доставлен', delivery_timestamp = localtimestamp where order_id = o;
    end if;
end $$;

-- SQL-строители
create function tst.ins_item(p_order uuid, p_product uuid, p_qty text default '1', p_price text default 'null')
returns text language sql as $$
    select format('insert into order_structure(order_id, product_id, quantity, price) values (%L, %L, %s, %s)',
                  p_order, p_product, p_qty, p_price)
$$;

create function tst.pay_sql(p_order uuid, p_status text, p_amount text default 'null') returns text language sql as $$
    select format('insert into payment(order_id, payment_type, amount, transaction_id, status) values (%L, ''карта'', %s, %L, %L)',
                  p_order, p_amount, tst.rnd(24), p_status)
$$;

create function tst.payout_sql(p_order uuid, p_status text, p_amount text default 'null') returns text language sql as $$
    select format('insert into restaurant_payout(order_id, amount, transaction_id, status) values (%L, %s, %L, %L)',
                  p_order, p_amount, tst.rnd(24), p_status)
$$;

-- p_sub: 'product' | 'restaurant' | 'order' | 'none'
create function tst.rv_sql(p_rid uuid, p_order uuid, p_sub text, p_target uuid default null) returns text language sql as $$
    select format('insert into review(review_id, order_id, description, rating) values (%L, %L, ''текст'', 5); ', p_rid, p_order)
        || case p_sub
               when 'product'    then format('insert into product_review(review_id, product_id) values (%L, %L)', p_rid, p_target)
               when 'restaurant' then format('insert into restaurant_review(review_id, restaurant_id) values (%L, %L)', p_rid, p_target)
               when 'order'      then format('insert into order_review(review_id) values (%L)', p_rid)
               else 'select 1'
           end
$$;

create function tst.mk_review(p_order uuid, p_sub text, p_target uuid default null) returns uuid language plpgsql as $$
declare rid uuid := uuid_generate_v4();
begin
    execute tst.rv_sql(rid, p_order, p_sub, p_target);
    return rid;
end $$;

create function tst.amount_is(p_order uuid, p_expected text) returns text language sql as $$
    select format('select order_amount is not distinct from %s from "order" where order_id = %L', p_expected, p_order)
$$;

create function tst.pay_status_is(p_order uuid, p_expected text) returns text language sql as $$
    select format('select pay_status = %L from "order" where order_id = %L', p_expected, p_order)
$$;


-- 1. order_amount_guard, order_pay_status_guard (BR-7.8–7.10, BR-8.7)
do $t$
declare
    r uuid; ca uuid; o uuid := uuid_generate_v4(); o2 uuid := uuid_generate_v4();
begin
    r := tst.mk_restaurant(); ca := tst.mk_client_address();

    perform tst.expect_ok('order_amount_guard: INSERT с order_amount принимается',
        format($f$insert into "order"(order_id, client_address_id, restaurant_id, status, order_amount)
                  values (%L, %L, %L, 'создан', 5000)$f$, o, ca, r));
    perform tst.expect_true('order_amount_guard: INSERT обнуляет order_amount', tst.amount_is(o, 'null'));

    perform tst.expect_error('order_amount_guard: ручной UPDATE order_amount запрещён',
        format('update "order" set order_amount = 5000 where order_id = %L', o), 'P0001', 'вычисляется');

    perform tst.expect_ok('order_pay_status_guard: INSERT с pay_status=оплачен принимается',
        format($f$insert into "order"(order_id, client_address_id, restaurant_id, status, pay_status)
                  values (%L, %L, %L, 'создан', 'оплачен')$f$, o2, ca, r));
    perform tst.expect_true('order_pay_status_guard: INSERT сбрасывает pay_status в «ожидает»', tst.pay_status_is(o2, 'ожидает'));

    perform tst.expect_error('order_pay_status_guard: ручной UPDATE pay_status запрещён',
        format($f$update "order" set pay_status = 'оплачен' where order_id = %L$f$, o2), 'P0001', 'вычисляется');
end $t$;


-- 2. item_before / item_after / check_quantity_measure / check_order_structure_restaurant
--    (BR-5.5, BR-7.3, BR-7.10, BR-7.11, BR-7.14–7.16)
do $t$
declare
    r uuid; r_other uuid; ca uuid; o uuid; o2 uuid; o3 uuid;
    p uuid; p_b uuid; p_kg uuid; p_other uuid; p_arch uuid; p_out uuid; p_cheap uuid;
begin
    r := tst.mk_restaurant(); r_other := tst.mk_restaurant(); ca := tst.mk_client_address();
    o := tst.mk_order(ca, r); o2 := tst.mk_order(ca, r); o3 := tst.mk_order(ca, r);
    p       := tst.mk_product(r);
    p_b     := tst.mk_product(r);
    p_kg    := tst.mk_product(r, 1000, 'кг');
    p_other := tst.mk_product(r_other);
    p_arch  := tst.mk_product(r, 1000, 'шт', 'архив');
    p_out   := tst.mk_product(r, 1000, 'шт', 'нет_в_наличии');
    p_cheap := tst.mk_product(r, 500);

    -- check_order_structure_restaurant
    perform tst.expect_error('order_structure: блюдо из чужого ресторана', tst.ins_item(o, p_other), '23514', 'не из ресторана');

    -- item_before: INSERT
    perform tst.expect_error('item_before: блюдо в архиве', tst.ins_item(o, p_arch), '23514', 'недоступно');
    perform tst.expect_error('item_before: блюда нет в наличии', tst.ins_item(o, p_out), '23514', 'недоступно');
    perform tst.expect_error('item_before: несуществующее блюдо', tst.ins_item(o, uuid_generate_v4()), '23503');
    perform tst.expect_error('item_before: цена не совпадает с ценой блюда', tst.ins_item(o, p, '1', '5'), 'P0001', 'совпадать');
    perform tst.expect_ok('item_before: цена совпадает с ценой блюда', tst.ins_item(o2, p, '1', '1000'));
    perform tst.expect_ok('item_before: price=NULL подставляется из блюда', tst.ins_item(o, p));
    perform tst.expect_true('item_before: price = цена блюда',
        format('select price = 1000 from order_structure where order_id = %L and product_id = %L', o, p));

    -- item_after: пересчёт суммы
    perform tst.expect_true('item_after: order_amount = 1000 после первой позиции', tst.amount_is(o, '1000'));
    perform tst.expect_true('order: commission = 10%, total_amount = 110%',
        format('select commission = 100 and total_amount = 1100 from "order" where order_id = %L', o));

    perform tst.expect_error('order_structure: дубль блюда в заказе (BR-7.16)', tst.ins_item(o, p), '23505');
    perform tst.expect_error('order_structure: quantity = 0', tst.ins_item(o, p_b, '0'), '23514');

    -- check_quantity_measure
    perform tst.expect_error('check_quantity_measure: дробное количество для «шт»', tst.ins_item(o, p_b, '1.5'), '23514', 'штуках');
    perform tst.expect_ok('check_quantity_measure: дробное количество для «кг»', tst.ins_item(o, p_kg, '0.5'));
    perform tst.expect_true('item_after: сумма с дробным количеством = 1500', tst.amount_is(o, '1500'));

    -- item_before: UPDATE
    perform tst.expect_ok('item_before: UPDATE quantity разрешён',
        format('update order_structure set quantity = 2.5 where order_id = %L and product_id = %L', o, p_kg));
    perform tst.expect_true('item_after: сумма после UPDATE quantity = 3500', tst.amount_is(o, '3500'));
    perform tst.expect_error('check_quantity_measure: UPDATE quantity на дробное для «шт»',
        format('update order_structure set quantity = 1.5 where order_id = %L and product_id = %L', o, p), '23514');
    perform tst.expect_error('item_before: UPDATE price запрещён',
        format('update order_structure set price = 1 where order_id = %L and product_id = %L', o, p), 'P0001', 'фиксируется');
    perform tst.expect_error('item_before: перенос позиции в другой заказ',
        format('update order_structure set order_id = %L where order_id = %L and product_id = %L', o3, o, p), '23514', 'другой заказ');
    perform tst.expect_error('item_before: смена блюда в позиции',
        format('update order_structure set product_id = %L where order_id = %L and product_id = %L', p_b, o, p), '23514', 'менять блюдо');

    -- item_before / item_after: DELETE
    perform tst.expect_ok('item_before: DELETE позиции в заказе «создан»',
        format('delete from order_structure where order_id = %L and product_id = %L', o, p_kg));
    perform tst.expect_true('item_after: сумма после DELETE = 1000', tst.amount_is(o, '1000'));
    perform tst.expect_ok('item_before: DELETE последней позиции',
        format('delete from order_structure where order_id = %L and product_id = %L', o, p));
    perform tst.expect_true('item_after: пустой заказ → order_amount NULL', tst.amount_is(o, 'null'));

    -- порог 1000 руб (BR-7.11)
    perform tst.expect_ok('item_after: заказ на 500 ₽', tst.ins_item(o3, p_cheap, '1'));
    perform tst.expect_true('item_after: итог < 1000 ₽ → order_amount NULL', tst.amount_is(o3, 'null'));
    perform tst.expect_ok('item_after: увеличиваем количество до 2', format('update order_structure set quantity = 2 where order_id = %L', o3));
    perform tst.expect_true('item_after: итог 1100 ₽ → order_amount = 1000', tst.amount_is(o3, '1000'));
end $t$;

-- item_before: блокировка состава
do $t$
declare
    o uuid; r uuid; p uuid; p2 uuid; ca uuid; p_new uuid;
begin
    -- статус не "создан"
    select * into o, r, p, p2, ca from tst.mk_order_full();
    p_new := tst.mk_product(r);
    update "order" set status = 'готовится' where order_id = o;
    perform tst.expect_error('item_before: INSERT в заказ «готовится»', tst.ins_item(o, p_new), 'P0001', 'изменять нельзя');
    perform tst.expect_error('item_before: DELETE из заказа «готовится»',
        format('delete from order_structure where order_id = %L and product_id = %L', o, p), 'P0001', 'изменять нельзя');
    perform tst.expect_error('item_before: UPDATE в заказе «готовится»',
        format('update order_structure set quantity = 3 where order_id = %L and product_id = %L', o, p), 'P0001', 'изменять нельзя');

    -- есть попытка оплаты
    select * into o, r, p, p2, ca from tst.mk_order_full();
    p_new := tst.mk_product(r);
    execute tst.pay_sql(o, 'в_обработке');
    perform tst.expect_error('item_before: INSERT при наличии платежа', tst.ins_item(o, p_new), 'P0001', 'изменять нельзя');
    perform tst.expect_error('item_before: DELETE при наличии платежа',
        format('delete from order_structure where order_id = %L and product_id = %L', o, p), 'P0001', 'изменять нельзя');

    -- есть выплата ресторану
    select * into o, r, p, p2, ca from tst.mk_order_full(true);
    p_new := tst.mk_product(r);
    execute tst.payout_sql(o, 'в_обработке');
    perform tst.expect_error('item_before: INSERT при наличии выплаты', tst.ins_item(o, p_new), 'P0001', 'изменять нельзя');
end $t$;


-- 3. payment_copy_amount, payment_closed_guard, prevent_success_transaction_change,
--    order_pay_status_sync, sync_order_pay_status (BR-8.1, 8.4, 8.7)
do $t$
declare
    o uuid; r uuid; p uuid; p2 uuid; ca uuid; oe uuid; oc uuid; o_dst uuid;
    tot text;
begin
    select * into o, r, p, p2, ca from tst.mk_order_full();
    tot := format('(select total_amount from "order" where order_id = %L)', o);

    -- payment_copy_amount: INSERT
    perform tst.expect_ok('payment_copy_amount: amount = NULL допустим', tst.pay_sql(o, 'в_обработке'));
    perform tst.expect_true('payment_copy_amount: amount скопирован из total_amount',
        format('select pm.amount = od.total_amount and od.total_amount = 2200 from payment pm join "order" od using (order_id) where od.order_id = %L', o));
    perform tst.expect_true('order_pay_status_sync: «в_обработке» → ожидает', tst.pay_status_is(o, 'ожидает'));
    perform tst.expect_error('payment_copy_amount: сумма не равна сумме заказа', tst.pay_sql(o, 'в_обработке', '1'), 'P0001', 'не равна');
    perform tst.expect_ok('payment_copy_amount: сумма равна сумме заказа', tst.pay_sql(o, 'ошибка', tot));
    perform tst.expect_true('order_pay_status_sync: «в_обработке» + «ошибка» → ожидает', tst.pay_status_is(o, 'ожидает'));

    oe := tst.mk_order(ca, r);
    perform tst.expect_error('payment_copy_amount: заказ без суммы', tst.pay_sql(oe, 'в_обработке'), 'P0001', 'не определена');
    perform tst.expect_error('payment_copy_amount: заказ не найден', tst.pay_sql(uuid_generate_v4(), 'в_обработке'), 'P0001', 'не найден');
    perform tst.expect_error('payment_copy_amount: order_id = NULL', tst.pay_sql(null, 'в_обработке'), 'P0001', 'не найден');

    select * into oc, r, p, p2, ca from tst.mk_order_full();
    update "order" set status = 'отменён' where order_id = oc;
    perform tst.expect_error('payment_copy_amount: заказ отменён', tst.pay_sql(oc, 'в_обработке'), 'P0001', 'отменён');

    -- payment_copy_amount: UPDATE
    perform tst.expect_error('payment_copy_amount: UPDATE amount запрещён',
        format('update payment set amount = 1 where order_id = %L and status = ''ошибка''', o), 'P0001', 'менять сумму');
    perform tst.expect_error('payment_copy_amount: UPDATE order_id запрещён',
        format('update payment set order_id = %L where order_id = %L and status = ''ошибка''', oc, o), 'P0001', 'менять заказ');

    -- order_pay_status_sync: UPDATE status
    perform tst.expect_ok('order_pay_status_sync: «в_обработке» → «ошибка»',
        format($f$update payment set status = 'ошибка' where order_id = %L and status = 'в_обработке'$f$, o));
    perform tst.expect_true('order_pay_status_sync: все «ошибка» → ошибка', tst.pay_status_is(o, 'ошибка'));

    perform tst.expect_ok('order_pay_status_sync: успешная попытка', tst.pay_sql(o, 'успех'));
    perform tst.expect_true('order_pay_status_sync: есть «успех» → оплачен', tst.pay_status_is(o, 'оплачен'));

    -- payment_closed_guard
    perform tst.expect_error('payment_closed_guard: новая попытка у оплаченного заказа', tst.pay_sql(o, 'ошибка'), '23514', 'уже оплачен');
    perform tst.expect_error('payment_closed_guard: вторая успешная попытка', tst.pay_sql(o, 'успех'), '23514', 'уже оплачен');

    -- prevent_success_transaction_change
    perform tst.expect_error('prevent_success_transaction_change: payment успех → ошибка',
        format($f$update payment set status = 'ошибка' where order_id = %L and status = 'успех'$f$, o), 'P0001', 'успешной');
    perform tst.expect_error('prevent_success_transaction_change: payment успех → в_обработке',
        format($f$update payment set status = 'в_обработке' where order_id = %L and status = 'успех'$f$, o), 'P0001', 'успешной');

    -- order_pay_status_sync: DELETE
    perform tst.expect_ok('order_pay_status_sync: DELETE успешной попытки',
        format($f$delete from payment where order_id = %L and status = 'успех'$f$, o));
    perform tst.expect_true('order_pay_status_sync: после DELETE «успех» остались «ошибка» → ошибка', tst.pay_status_is(o, 'ошибка'));
    perform tst.expect_ok('order_pay_status_sync: DELETE всех попыток', format('delete from payment where order_id = %L', o));
    perform tst.expect_true('order_pay_status_sync: нет попыток → ожидает', tst.pay_status_is(o, 'ожидает'));

    -- sync_order_pay_status напрямую
    perform tst.expect_ok('sync_order_pay_status: несуществующий заказ — no-op', 'select sync_order_pay_status(uuid_generate_v4())');
    perform tst.expect_ok('sync_order_pay_status: статус не меняется — no-op', format('select sync_order_pay_status(%L)', o));
    perform tst.expect_true('sync_order_pay_status: статус остался «ожидает»', tst.pay_status_is(o, 'ожидает'));
end $t$;


-- 4. payout_copy_amount (BR-1.5)
do $t$
declare
    o uuid; r uuid; p uuid; p2 uuid; ca uuid; o_unpaid uuid; o_cancel uuid; o_other uuid;
begin
    select * into o, r, p, p2, ca from tst.mk_order_full(true);
    select * into o_unpaid, r, p, p2, ca from tst.mk_order_full();
    select * into o_cancel, r, p, p2, ca from tst.mk_order_full(true);
    select * into o_other, r, p, p2, ca from tst.mk_order_full(true);
    update "order" set status = 'отменён' where order_id = o_cancel;

    perform tst.expect_ok('payout_copy_amount: amount = NULL допустим', tst.payout_sql(o, 'в_обработке'));
    perform tst.expect_true('payout_copy_amount: amount = order_amount (без комиссии)',
        format('select po.amount = od.order_amount and od.order_amount = 2000 from restaurant_payout po join "order" od using (order_id) where od.order_id = %L', o));
    perform tst.expect_error('payout_copy_amount: сумма не равна стоимости блюд', tst.payout_sql(o, 'ошибка', '2200'), '23514', 'не равна');
    perform tst.expect_ok('payout_copy_amount: сумма равна стоимости блюд', tst.payout_sql(o, 'ошибка', '2000'));
    perform tst.expect_error('payout_copy_amount: заказ не оплачен', tst.payout_sql(o_unpaid, 'в_обработке'), '23514', 'не оплачен');
    perform tst.expect_error('payout_copy_amount: заказ отменён', tst.payout_sql(o_cancel, 'в_обработке'), '23514', 'отменён');
    perform tst.expect_error('payout_copy_amount: заказ не найден', tst.payout_sql(uuid_generate_v4(), 'в_обработке'), '23503');

    perform tst.expect_error('payout_copy_amount: UPDATE amount запрещён',
        format($f$update restaurant_payout set amount = 1 where order_id = %L and status = 'ошибка'$f$, o), 'P0001', 'менять сумму');
    perform tst.expect_error('payout_copy_amount: перенос выплаты на другой заказ',
        format($f$update restaurant_payout set order_id = %L where order_id = %L and status = 'ошибка'$f$, o_other, o), 'P0001', 'другой заказ');

    -- prevent_success_transaction_change для выплат
    perform tst.expect_ok('payout: успешная выплата', tst.payout_sql(o, 'успех'));
    perform tst.expect_error('prevent_success_transaction_change: payout успех → ошибка',
        format($f$update restaurant_payout set status = 'ошибка' where order_id = %L and status = 'успех'$f$, o), 'P0001', 'успешной');
    perform tst.expect_ok('prevent_success_transaction_change: payout ошибка → в_обработке разрешён',
        format($f$update restaurant_payout set status = 'в_обработке' where order_id = %L and status = 'ошибка'$f$, o));
end $t$;


-- 5. Отзывы: review_lock_order, check_product_review, check_restaurant_review,
--    check_order_review, check_review_single_type, check_review_exactly_one_type,
--    review_order_immutable, order_client_guard, order_restaurant_guard (BR-9.x)
do $t$
declare
    o uuid; r uuid; p uuid; p2 uuid; ca uuid; p3 uuid; r_other uuid; ca_other uuid;
    o_nd uuid; o_b uuid; r_b uuid; p_b uuid; o_c uuid; r_c uuid; p_c uuid; p2_c uuid; ca_c uuid;
    o_d uuid; p_d uuid; p2_d uuid; o_e uuid;
    rid uuid; rid2 uuid;
begin
    -- review_lock_order
    select * into o_nd, r, p, p2, ca from tst.mk_order_full(true); -- оплачен, но не доставлен
    perform tst.expect_error('review_lock_order: заказ не доставлен',
        tst.rv_sql(uuid_generate_v4(), o_nd, 'order'), '23514', 'доставленный');
    perform tst.expect_error('review_lock_order: заказ не найден',
        tst.rv_sql(uuid_generate_v4(), uuid_generate_v4(), 'order'), '23503', 'не найден');

    -- check_product_review
    select * into o, r, p, p2, ca from tst.mk_order_full(true, true);
    r_other := tst.mk_restaurant();
    p3 := tst.mk_product(r); -- не входит в заказ
    ca_other := tst.mk_client_address();

    perform tst.expect_ok('check_product_review: отзыв на блюдо из заказа',
        tst.chk(tst.rv_sql(uuid_generate_v4(), o, 'product', p)));
    perform tst.expect_error('check_product_review: второй отзыв на то же блюдо в заказе',
        tst.chk(tst.rv_sql(uuid_generate_v4(), o, 'product', p)), '23505', 'уже есть отзыв');
    perform tst.expect_ok('check_product_review: отзыв на другое блюдо в том же заказе',
        tst.chk(tst.rv_sql(uuid_generate_v4(), o, 'product', p2)));
    perform tst.expect_error('check_product_review: блюда нет в заказе',
        tst.chk(tst.rv_sql(uuid_generate_v4(), o, 'product', p3)), '23514', 'нет в заказе');
    perform tst.expect_error('check_product_review: отзыв не найден',
        format('insert into product_review(review_id, product_id) values (%L, %L)', uuid_generate_v4(), p), '23503', 'не найден');

    -- check_restaurant_review
    perform tst.expect_ok('check_restaurant_review: отзыв на ресторан заказа',
        tst.chk(tst.rv_sql(uuid_generate_v4(), o, 'restaurant', r)));
    perform tst.expect_error('check_restaurant_review: второй отзыв на ресторан в заказе',
        tst.chk(tst.rv_sql(uuid_generate_v4(), o, 'restaurant', r)), '23505', 'уже есть отзыв');
    perform tst.expect_error('check_restaurant_review: заказ сделан не в этом ресторане',
        tst.chk(tst.rv_sql(uuid_generate_v4(), o, 'restaurant', r_other)), '23514', 'сделан не в ресторане');
    perform tst.expect_error('check_restaurant_review: отзыв не найден',
        format('insert into restaurant_review(review_id, restaurant_id) values (%L, %L)', uuid_generate_v4(), r), '23503', 'не найден');

    -- check_order_review
    perform tst.expect_ok('check_order_review: отзыв на заказ', tst.chk(tst.rv_sql(uuid_generate_v4(), o, 'order')));
    perform tst.expect_error('check_order_review: второй отзыв на заказ',
        tst.chk(tst.rv_sql(uuid_generate_v4(), o, 'order')), '23505', 'уже есть отзыв');
    perform tst.expect_error('check_order_review: отзыв не найден',
        format('insert into order_review(review_id) values (%L)', uuid_generate_v4()), '23503', 'не найден');

    -- order_client_guard / order_restaurant_guard / позиции у доставленного заказа (в заказе o уже есть отзывы)
    perform tst.expect_error('order_client_guard: смена адреса у заказа с отзывом',
        format('update "order" set client_address_id = %L where order_id = %L', ca_other, o), '23514', 'уже есть отзыв');
    perform tst.expect_error('order_restaurant_guard: смена ресторана у заказа с позициями',
        format('update "order" set restaurant_id = %L where order_id = %L', r_other, o), '23514', 'с позициями');
    perform tst.expect_error('item_before: INSERT в доставленный заказ', tst.ins_item(o, p3), 'P0001', 'изменять нельзя');
    perform tst.expect_error('item_before: DELETE из доставленного заказа',
        format('delete from order_structure where order_id = %L and product_id = %L', o, p), 'P0001', 'изменять нельзя');

    -- check_review_single_type
    select * into o_b, r_b, p_b, p2, ca from tst.mk_order_full(true, true);
    rid := uuid_generate_v4();
    perform tst.expect_error('check_review_single_type: product_review + restaurant_review',
        tst.chk(tst.rv_sql(rid, o_b, 'product', p_b) || format('; insert into restaurant_review(review_id, restaurant_id) values (%L, %L)', rid, r_b)),
        '23514', 'уже привязан');
    perform tst.expect_error('check_review_single_type: product_review + order_review',
        tst.chk(tst.rv_sql(rid, o_b, 'product', p_b) || format('; insert into order_review(review_id) values (%L)', rid)),
        '23514', 'уже привязан');
    perform tst.expect_error('check_review_single_type: order_review + product_review',
        tst.chk(tst.rv_sql(rid, o_b, 'order') || format('; insert into product_review(review_id, product_id) values (%L, %L)', rid, p_b)),
        '23514', 'уже привязан');
    perform tst.expect_error('check_review_single_type: restaurant_review + order_review',
        tst.chk(tst.rv_sql(rid, o_b, 'restaurant', r_b) || format('; insert into order_review(review_id) values (%L)', rid)),
        '23514', 'уже привязан');

    -- check_review_exactly_one_type
    perform tst.expect_error('exactly_one_type: отзыв без подтипа',
        tst.chk(tst.rv_sql(uuid_generate_v4(), o_b, 'none')), '23514', 'ровно один');

    select * into o_c, r_c, p_c, p2_c, ca_c from tst.mk_order_full(true, true);
    rid := tst.mk_review(o_c, 'order');
    perform tst.expect_error('exactly_one_type: удаление единственного подтипа',
        tst.chk(format('delete from order_review where review_id = %L', rid)), '23514', 'ровно один');
    perform tst.expect_ok('exactly_one_type: UPDATE review (rating)',
        tst.chk(format('update review set rating = 3 where review_id = %L', rid)));
    perform tst.expect_true('exactly_one_type: rating обновлён',
        format('select rating = 3 from review where review_id = %L', rid));

    rid2 := tst.mk_review(o_c, 'product', p_c);
    perform tst.expect_ok('exactly_one_type: DELETE review каскадом удаляет подтип',
        tst.chk(format('delete from review where review_id = %L', rid2)));
    perform tst.expect_true('exactly_one_type: подтип удалён каскадом',
        format('select not exists (select 1 from product_review where review_id = %L)', rid2));

    select * into o_d, r, p_d, p2_d, ca from tst.mk_order_full(true, true);
    rid := tst.mk_review(o_d, 'product', p_d);
    perform tst.expect_ok('exactly_one_type: UPDATE product_review.product_id (ветка UPDATE)',
        tst.chk(format('update product_review set product_id = %L where review_id = %L', p2_d, rid)));
    perform tst.expect_true('product_review: product_id изменён',
        format('select product_id = %L from product_review where review_id = %L', p2_d, rid));

    -- review_order_immutable
    select * into o_e, r, p, p2, ca from tst.mk_order_full(true, true);
    perform tst.expect_error('review_order_immutable: смена заказа у отзыва',
        format('update review set order_id = %L where review_id = %L', o_e, rid), '23514', 'Нельзя менять заказ');
    perform tst.expect_error('review_order_immutable: обнуление заказа у отзыва вручную',
        format('update review set order_id = null where review_id = %L', rid), '23514', 'Нельзя менять заказ');
end $t$;

-- 5.1. UPDATE product_review.product_id: блюдо отсутствует в заказе
do $t$
declare
    o uuid; r uuid; p uuid; p2 uuid; ca uuid;
    p_other uuid;
    rid uuid;
begin
    select * into o, r, p, p2, ca from tst.mk_order_full(true, true);

    p_other := tst.mk_product(r);
    rid := tst.mk_review(o, 'product', p);

    perform tst.expect_error(
        'check_product_review: UPDATE product_id на блюдо вне заказа',
        format(
            'update product_review set product_id = %L where review_id = %L',
            p_other, rid
        ),
        '23514',
        'нет в заказе'
    );
end $t$;

-- 5.2. UPDATE restaurant_review.restaurant_id
do $t$
declare
    o uuid; r uuid; p uuid; p2 uuid; ca uuid;
    r_other uuid;
    rid uuid;
begin
    select * into o, r, p, p2, ca from tst.mk_order_full(true, true);

    r_other := tst.mk_restaurant();
    rid := tst.mk_review(o, 'restaurant', r);

    perform tst.expect_error(
        'check_restaurant_review: UPDATE restaurant_id на другой ресторан',
        format(
            'update restaurant_review set restaurant_id = %L where review_id = %L',
            r_other, rid
        ),
        '23514',
        'сделан не в ресторане'
    );
end $t$;

-- 5.3. check_review_single_type: UPDATE review_id во всех подтипах
do $t$
declare
    o1 uuid; r1 uuid; p1 uuid; p12 uuid; ca1 uuid;
    o2 uuid; r2 uuid; p2 uuid; p22 uuid; ca2 uuid;
    o3 uuid; r3 uuid; p3 uuid; p32 uuid; ca3 uuid;
    o4 uuid; r4 uuid; p4 uuid; p42 uuid; ca4 uuid;
    o5 uuid; r5 uuid; p5 uuid; p52 uuid; ca5 uuid;
    o6 uuid; r6 uuid; p6 uuid; p62 uuid; ca6 uuid;

    rid_product_source uuid;
    rid_restaurant_target uuid;

    rid_restaurant_source uuid;
    rid_order_target uuid;

    rid_order_source uuid;
    rid_product_target uuid;
begin
    -- product_review -> review с уже существующим restaurant_review
    select * into o1, r1, p1, p12, ca1 from tst.mk_order_full(true, true);
    select * into o2, r2, p2, p22, ca2 from tst.mk_order_full(true, true);

    rid_product_source := tst.mk_review(o1, 'product', p1);
    rid_restaurant_target := tst.mk_review(o2, 'restaurant', r2);

    perform tst.expect_error(
        'check_review_single_type: UPDATE product_review.review_id на restaurant_review',
        format(
            'update product_review set review_id = %L, product_id = %L where review_id = %L',
            rid_restaurant_target, p2, rid_product_source
        ),
        '23514',
        'уже привязан'
    );

    -- restaurant_review -> review с уже существующим order_review
    select * into o3, r3, p3, p32, ca3 from tst.mk_order_full(true, true);
    select * into o4, r4, p4, p42, ca4 from tst.mk_order_full(true, true);

    rid_restaurant_source := tst.mk_review(o3, 'restaurant', r3);
    rid_order_target := tst.mk_review(o4, 'order');

    perform tst.expect_error(
        'check_review_single_type: UPDATE restaurant_review.review_id на order_review',
        format(
            'update restaurant_review set review_id = %L, restaurant_id = %L where review_id = %L',
            rid_order_target, r4, rid_restaurant_source
        ),
        '23514',
        'уже привязан'
    );

    -- order_review -> review с уже существующим product_review
    select * into o5, r5, p5, p52, ca5 from tst.mk_order_full(true, true);
    select * into o6, r6, p6, p62, ca6 from tst.mk_order_full(true, true);

    rid_order_source := tst.mk_review(o5, 'order');
    rid_product_target := tst.mk_review(o6, 'product', p6);

    perform tst.expect_error(
        'check_review_single_type: UPDATE order_review.review_id на product_review',
        format(
            'update order_review set review_id = %L where review_id = %L',
            rid_product_target, rid_order_source
        ),
        '23514',
        'уже привязан'
    );
end $t$;

-- 5.4. check_review_exactly_one_type: явное принудительное выполнение constraint trigger
do $t$
declare
    o uuid; r uuid; p uuid; p2 uuid; ca uuid;
    rid uuid := uuid_generate_v4();
begin
    select * into o, r, p, p2, ca from tst.mk_order_full(true, true);

    perform tst.expect_error(
        'check_review_exactly_one_type: ошибка при SET CONSTRAINTS IMMEDIATE',
        format(
            $q$
                set constraints all deferred;

                insert into review(review_id, order_id, description, rating)
                values (%L, %L, 'текст', 5);

                set constraints
                    trg_review_exactly_one_type,
                    trg_product_review_exactly_one_type,
                    trg_restaurant_review_exactly_one_type,
                    trg_order_review_exactly_one_type
                immediate;
            $q$,
            rid, o
        ),
        '23514',
        'ровно один подтип'
    );
end $t$;



-- 6. Адреса: check_client_address_not_restaurant, check_restaurant_address_not_client,
--    uq_address_physical (BR-2.5, BR-3.3, BR-3.4)
do $t$
declare
    r uuid; ra uuid; c uuid; c2 uuid; ca uuid; ad uuid; s text := 'Ул ' || tst.rnd(10);
    ins_rest text := $f$insert into restaurant(restaurant_name, address_id, description, work_start, work_end, company_details, status)
                        values ('x', %L, 'd', '09:00', '21:00', 'c', 'активен')$f$;
begin
    r := tst.mk_restaurant();
    select address_id into ra from restaurant where restaurant_id = r;
    c := tst.mk_client(); c2 := tst.mk_client();
    ca := tst.mk_client_address(c);
    select address_id into ad from client_address where client_address_id = ca;

    perform tst.expect_error('check_client_address_not_restaurant: INSERT адреса ресторана клиенту',
        format('insert into client_address(client_id, address_id) values (%L, %L)', c, ra), '23514', 'занят рестораном');
    perform tst.expect_error('check_client_address_not_restaurant: UPDATE address_id на адрес ресторана',
        format('update client_address set address_id = %L where client_address_id = %L', ra, ca), '23514', 'занят рестораном');
    perform tst.expect_ok('client_address: один адрес у двух клиентов',
        format('insert into client_address(client_id, address_id) values (%L, %L)', c2, ad));
    perform tst.expect_error('client_address: один адрес дважды у одного клиента (BR-2.5)',
        format('insert into client_address(client_id, address_id) values (%L, %L)', c, ad), '23505');

    perform tst.expect_error('check_restaurant_address_not_client: INSERT ресторана на адрес клиента',
        format(ins_rest, ad), '23514', 'используется клиентом');
    perform tst.expect_error('check_restaurant_address_not_client: UPDATE адреса ресторана на адрес клиента',
        format('update restaurant set address_id = %L where restaurant_id = %L', ad, r), '23514', 'используется клиентом');
    perform tst.expect_ok('restaurant: ресторан на свободный адрес', format(ins_rest, tst.mk_address()));
    perform tst.expect_error('restaurant: два ресторана на одном адресе (BR-3.3)', format(ins_rest, ra), '23505');

    -- uq_address_physical
    perform tst.expect_ok('uq_address_physical: адрес без квартиры',
        format('insert into address(street, house_number) values (%L, ''1'')', s));
    perform tst.expect_error('uq_address_physical: дубль без учёта регистра и пробелов',
        format('insert into address(street, house_number) values (%L, '' 1 '')', '  ' || upper(s) || ' '), '23505');
    perform tst.expect_ok('uq_address_physical: тот же дом с квартирой',
        format('insert into address(street, house_number, apartment_office) values (%L, ''1'', ''5'')', s));
    perform tst.expect_error('uq_address_physical: дубль квартиры',
        format('insert into address(street, house_number, apartment_office) values (%L, ''1'', '' 5 '')', lower(s)), '23505');
    perform tst.expect_error('address: пустая квартира запрещена',
        format('insert into address(street, house_number, apartment_office) values (%L, ''2'', ''  '')', s), '23514');
end $t$;


-- 7. product_restaurant_guard, product_measure_guard (BR-7.3, BR-7.15)
do $t$
declare
    o uuid; r uuid; p uuid; p2 uuid; ca uuid; p_free uuid; r2 uuid;
begin
    select * into o, r, p, p2, ca from tst.mk_order_full();
    p_free := tst.mk_product(r);
    r2 := tst.mk_restaurant();

    perform tst.expect_error('product_restaurant_guard: смена ресторана у блюда из заказа',
        format('update product set restaurant_id = %L where product_id = %L', r2, p), '23514', 'есть в заказах');
    perform tst.expect_ok('product_restaurant_guard: смена ресторана у блюда вне заказов',
        format('update product set restaurant_id = %L where product_id = %L', r2, p_free));
    perform tst.expect_error('product_measure_guard: смена единицы у блюда из заказа',
        format($f$update product set measure_unit = 'кг' where product_id = %L$f$, p), '23514', 'есть в заказах');
    perform tst.expect_ok('product_measure_guard: смена единицы у блюда вне заказов',
        format($f$update product set measure_unit = 'кг' where product_id = %L$f$, p_free));
    perform tst.expect_ok('product_measure_guard: та же единица у блюда из заказа (триггер не срабатывает)',
        format($f$update product set measure_unit = 'шт' where product_id = %L$f$, p));
end $t$;


-- 8. Курьеры: check_order_courier, check_courier_dismissal (BR-7.5)
do $t$
declare
    r uuid; ca uuid; c_free uuid; c_fired uuid;
    o uuid;
begin
    r := tst.mk_restaurant(); ca := tst.mk_client_address();
    c_free := tst.mk_courier(); c_fired := tst.mk_courier('уволен');

    -- check_order_courier
    perform tst.expect_error('check_order_courier: INSERT заказа с уволенным курьером',
        format($f$insert into "order"(client_address_id, restaurant_id, courier_id, status) values (%L, %L, %L, 'создан')$f$, ca, r, c_fired),
        '23514', 'уволенного');
    perform tst.expect_ok('check_order_courier: INSERT заказа с работающим курьером',
        format($f$insert into "order"(client_address_id, restaurant_id, courier_id, status) values (%L, %L, %L, 'создан')$f$, ca, r, c_free));
    perform tst.expect_ok('check_order_courier: INSERT заказа без курьера',
        format($f$insert into "order"(client_address_id, restaurant_id, status) values (%L, %L, 'создан')$f$, ca, r));
    o := tst.mk_order(ca, r);
    perform tst.expect_error('check_order_courier: UPDATE на уволенного курьера',
        format('update "order" set courier_id = %L where order_id = %L', c_fired, o), '23514', 'уволенного');
    perform tst.expect_ok('check_order_courier: UPDATE на работающего курьера',
        format('update "order" set courier_id = %L where order_id = %L', c_free, o));
    perform tst.expect_ok('check_order_courier: UPDATE courier_id = NULL',
        format('update "order" set courier_id = null where order_id = %L', o));

end $t$;

-- продолжение группы курьеров
do $t$
declare
    r uuid; ca uuid; c_done uuid; c_cancel uuid; c_none uuid; o_done uuid; o_cancel uuid;
    r2 uuid; p uuid; p2 uuid; ca2 uuid; c_deliv uuid;
begin
    r := tst.mk_restaurant(); ca := tst.mk_client_address();
    c_none := tst.mk_courier(); c_cancel := tst.mk_courier(); c_deliv := tst.mk_courier();

    select * into o_done, r2, p, p2, ca2 from tst.mk_order_full(true, true);
    update "order" set courier_id = c_deliv where order_id = o_done;
    o_cancel := tst.mk_order(ca, r, c_cancel);
    update "order" set status = 'отменён' where order_id = o_cancel;

    perform tst.expect_ok('check_courier_dismissal: курьер без заказов',
        format($f$update courier set status = 'уволен', dismissal_date = current_date where courier_id = %L$f$, c_none));
    perform tst.expect_ok('check_courier_dismissal: у курьера только отменённый заказ',
        format($f$update courier set status = 'уволен', dismissal_date = current_date where courier_id = %L$f$, c_cancel));
    perform tst.expect_ok('check_courier_dismissal: у курьера только доставленный заказ',
        format($f$update courier set status = 'уволен', dismissal_date = current_date where courier_id = %L$f$, c_deliv));
end $t$;

-- активный заказ в каждом из статусов "создан", "готовится", "в_доставке" блокирует увольнение
do $t$
declare
    o uuid; r uuid; p uuid; p2 uuid; ca uuid; c uuid; st text;
begin
    foreach st in array array['создан', 'готовится', 'в_доставке'] loop
        select * into o, r, p, p2, ca from tst.mk_order_full();
        c := tst.mk_courier();
        update "order" set courier_id = c, status = st::order_status where order_id = o;
        perform tst.expect_error('check_courier_dismissal: заказ в статусе «' || st || '»',
            format($f$update courier set status = 'уволен', dismissal_date = current_date where courier_id = %L$f$, c),
            'P0001', 'активные заказы');
    end loop;
end $t$;


-- 9. order_parties_guard (BR-7.2, BR-7.4, BR-11.3)
do $t$
declare
    r uuid; r2 uuid; c uuid; ca uuid; ca2 uuid; c_del uuid; ca_del uuid; o uuid;
    ins text := $f$insert into "order"(client_address_id, restaurant_id, status) values (%L, %L, 'создан')$f$;
begin
    r := tst.mk_restaurant(); r2 := tst.mk_restaurant();
    c := tst.mk_client(); ca := tst.mk_client_address(c); ca2 := tst.mk_client_address();
    c_del := tst.mk_client(); ca_del := tst.mk_client_address(c_del);
    delete from client where client_id = c_del;   -- client_address.client_id → NULL (BR-3.5)
    o := tst.mk_order(ca, r);

    perform tst.expect_ok('order_parties_guard: INSERT с адресом клиента и рестораном', format(ins, ca, r));
    perform tst.expect_error('order_parties_guard: INSERT без адреса', format(ins, null, r), '23502', 'адрес клиента');
    perform tst.expect_error('order_parties_guard: INSERT без ресторана', format(ins, ca, null), '23502', 'ресторан');
    perform tst.expect_error('order_parties_guard: INSERT на адрес без клиента', format(ins, ca_del, r), '23514', 'не привязан');
    perform tst.expect_error('order_parties_guard: INSERT на несуществующий client_address', format(ins, uuid_generate_v4(), r), '23514', 'не привязан');

    perform tst.expect_error('order_parties_guard: UPDATE адреса на NULL',
        format('update "order" set client_address_id = null where order_id = %L', o), '23502', 'адрес клиента');
    perform tst.expect_error('order_parties_guard: UPDATE ресторана на NULL',
        format('update "order" set restaurant_id = null where order_id = %L', o), '23502', 'ресторан');
    perform tst.expect_error('order_parties_guard: UPDATE адреса на адрес без клиента',
        format('update "order" set client_address_id = %L where order_id = %L', ca_del, o), '23514', 'не привязан');
    perform tst.expect_ok('order_parties_guard: UPDATE адреса на другой адрес клиента (заказ без отзывов)',
        format('update "order" set client_address_id = %L where order_id = %L', ca2, o));
    perform tst.expect_ok('order_restaurant_guard: смена ресторана у пустого заказа без отзывов',
        format('update "order" set restaurant_id = %L where order_id = %L', r2, o));
    perform tst.expect_error('order_parties_guard: UPDATE ресторана на NULL (порядок триггеров)',
        format('update "order" set restaurant_id = null where order_id = %L', o), '23502');
end $t$;


-- 10. Сохранение истории: ON DELETE SET NULL при depth > 1 (BR-3.5)
--     order_client_guard, order_restaurant_guard, review_order_immutable,
--     payment_copy_amount, payout_copy_amount, order_parties_guard, order_pay_status_sync
do $t$
declare
    o uuid; r uuid; p uuid; p2 uuid; ca uuid; rid uuid; pid uuid; po uuid;
    r_empty uuid; o_empty uuid; ca_e uuid;
begin
    -- удаление client_address у доставленного заказа с отзывом: order_client_guard (ранний выход)
    select * into o, r, p, p2, ca from tst.mk_order_full(true, true);
    rid := tst.mk_review(o, 'order');
    perform tst.expect_ok('order_client_guard: удаление client_address обнуляет order.client_address_id',
        format('delete from client_address where client_address_id = %L', ca));
    perform tst.expect_true('order.client_address_id стал NULL, заказ и отзыв сохранены',
        format('select client_address_id is null and exists (select 1 from review where review_id = %L) from "order" where order_id = %L', rid, o));

    -- удаление ресторана без блюд: order_restaurant_guard (ранний выход) и order_parties_guard при depth > 1
    r_empty := tst.mk_restaurant(); ca_e := tst.mk_client_address();
    o_empty := tst.mk_order(ca_e, r_empty);
    perform tst.expect_ok('order_restaurant_guard: удаление ресторана обнуляет order.restaurant_id',
        format('delete from restaurant where restaurant_id = %L', r_empty));
    perform tst.expect_true('order.restaurant_id стал NULL',
        format('select restaurant_id is null from "order" where order_id = %L', o_empty));

    -- удаление клиента: client_address.client_id → NULL, адрес сохранён
    perform tst.expect_ok('client: удаление клиента', format('delete from client where client_id = (select client_id from client_address where client_address_id = %L)', ca_e));
    perform tst.expect_true('client_address и address сохранены после удаления клиента',
        format('select client_id is null and exists (select 1 from address where address_id = ca.address_id) from client_address ca where client_address_id = %L', ca_e));

    -- удаление заказа (при временно отключённых trg_item_*): review/payment/payout.order_id → NULL
    select * into o, r, p, p2, ca from tst.mk_order_full(true, true);
    rid := tst.mk_review(o, 'order');
    select payment_id into pid from payment where order_id = o;
    insert into restaurant_payout(order_id, transaction_id, status) values (o, tst.rnd(24), 'успех') returning payout_id into po;

    perform tst.expect_ok('review_order_immutable / payment / payout: удаление заказа обнуляет order_id',
        $f$alter table order_structure disable trigger trg_item_before;
           alter table order_structure disable trigger trg_item_after;
        $f$ || format('delete from order_structure where order_id = %L; delete from "order" where order_id = %L; ', o, o) ||
        $f$alter table order_structure enable trigger trg_item_before;
           alter table order_structure enable trigger trg_item_after$f$);
    perform tst.expect_true('review.order_id = NULL после удаления заказа',  format('select order_id is null from review where review_id = %L', rid));
    perform tst.expect_true('payment.order_id = NULL после удаления заказа', format('select order_id is null from payment where payment_id = %L', pid));
    perform tst.expect_true('restaurant_payout.order_id = NULL после удаления заказа', format('select order_id is null from restaurant_payout where payout_id = %L', po));
    perform tst.expect_true('триггеры trg_item_* снова включены',
        $q$select count(*) = 2 from pg_trigger where tgrelid = 'shkuratetskiy_food.order_structure'::regclass
                               and tgname in ('trg_item_before', 'trg_item_after') and tgenabled = 'O'$q$);
end $t$;


-- 11. Дополнительные ветки: UPDATE review_id у подтипов, заказ-призрак, повторное увольнение
do $t$
declare
    o uuid; r uuid; p uuid; p2 uuid; ca uuid;
    o2 uuid; r2 uuid; pb uuid; pb2 uuid; ca2 uuid;
    rp uuid; rr uuid; ro uuid; rc uuid; c_fired uuid;
begin
    select * into o,  r,  p,  p2,  ca  from tst.mk_order_full(true, true);
    select * into o2, r2, pb, pb2, ca2 from tst.mk_order_full(true, true);
    rp := tst.mk_review(o, 'product', p);
    rr := tst.mk_review(o, 'restaurant', r);
    ro := tst.mk_review(o, 'order');

    -- тот же заказ: старая строка подтипа считается «другим отзывом» → дубль
    rc := uuid_generate_v4();
    perform tst.expect_error('check_product_review: UPDATE review_id на отзыв того же заказа',
        tst.chk(tst.rv_sql(rc, o, 'none') || format('; update product_review set review_id = %L where review_id = %L', rc, rp)),
        '23505', 'уже есть отзыв');
    rc := uuid_generate_v4();
    perform tst.expect_error('check_restaurant_review: UPDATE review_id на отзыв того же заказа',
        tst.chk(tst.rv_sql(rc, o, 'none') || format('; update restaurant_review set review_id = %L where review_id = %L', rc, rr)),
        '23505', 'уже есть отзыв');
    rc := uuid_generate_v4();
    perform tst.expect_error('check_order_review: UPDATE review_id на отзыв того же заказа',
        tst.chk(tst.rv_sql(rc, o, 'none') || format('; update order_review set review_id = %L where review_id = %L', rc, ro)),
        '23505', 'уже есть отзыв');

    -- перенос на отзыв другого заказа
    rc := uuid_generate_v4();
    perform tst.expect_error('check_product_review: UPDATE review_id на отзыв заказа без этого блюда',
        tst.chk(tst.rv_sql(rc, o2, 'none') || format('; update product_review set review_id = %L where review_id = %L', rc, rp)),
        '23514', 'нет в заказе');
    rc := uuid_generate_v4();
    perform tst.expect_error('check_restaurant_review: UPDATE review_id на отзыв заказа другого ресторана',
        tst.chk(tst.rv_sql(rc, o2, 'none') || format('; update restaurant_review set review_id = %L where review_id = %L', rc, rr)),
        '23514', 'сделан не в ресторане');
    rc := uuid_generate_v4();
    perform tst.expect_error('exactly_one_type: UPDATE review_id оставляет старый отзыв без подтипа (ветка ids=[old,new])',
        tst.chk(tst.rv_sql(rc, o2, 'none') || format('; update order_review set review_id = %L where review_id = %L', rc, ro)),
        '23514', 'ровно один');
    rc := uuid_generate_v4();
    perform tst.expect_ok('exactly_one_type: перенос order_review + новый подтип у старого отзыва',
        tst.chk(tst.rv_sql(rc, o2, 'none')
            || format('; update order_review set review_id = %L where review_id = %L', rc, ro)
            || format('; insert into product_review(review_id, product_id) values (%L, %L)', ro, p2)));
    perform tst.expect_true('после переноса: order_review у нового отзыва, product_review у старого',
        format('select exists (select 1 from order_review where review_id = %L) and exists (select 1 from product_review where review_id = %L)', rc, ro));

    -- item_before: заказ не существует (st IS NULL) → отсекает check_order_structure_restaurant
    perform tst.expect_error('item_before: INSERT в несуществующий заказ', tst.ins_item(uuid_generate_v4(), p), '23514', 'не из ресторана');

    -- check_courier_dismissal: повторное увольнение и восстановление
    c_fired := tst.mk_courier('уволен');
    perform tst.expect_ok('check_courier_dismissal: повторный UPDATE status=уволен (no-op)',
        format($f$update courier set status = 'уволен' where courier_id = %L$f$, c_fired));
    perform tst.expect_ok('check_courier_dismissal: восстановление курьера',
        format($f$update courier set status = 'свободен', dismissal_date = null where courier_id = %L$f$, c_fired));
end $t$;


-- Итог
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed, count(*) as total from tst.result;
select id, test, details from tst.result where not ok order by id;

rollback;