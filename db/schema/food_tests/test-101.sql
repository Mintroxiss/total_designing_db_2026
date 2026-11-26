-- Тесты логики триггеров актуальной схемы shkuratetskiy_food (PostgreSQL 15+).
-- Запускать целиком в тестовой БД после установки DDL. Данные не очищаются.
-- Проверяются 6 триггерных функций через реальные INSERT / UPDATE / DELETE.
-- PK, FK, UNIQUE, CHECK, NOT NULL, индексы и generated columns отдельно не тестируются.
begin;
set local search_path to shkuratetskiy_food, exts, pg_temp;

create temp table result (
    id int generated always as identity primary key,
    test text not null,
    ok boolean not null,
    details text
) on commit drop;

-- Один сценарий = одна запись. При неожиданном успехе или неверном результате
-- откатываем операцию во вложенной транзакции, чтобы не портить следующие тесты.
create function pg_temp.expect(p_test text, p_sql text, p_check text default null,
                               p_state text default null, p_msg text default null)
returns void language plpgsql as $$
declare
    b boolean;
    st text;
    msg text;
begin
    begin
        if p_sql is not null then execute p_sql; end if;
        if p_state is not null then
            raise exception using errcode = 'ZX001', message = 'ожидалась ошибка, но операция выполнена';
        end if;
        if p_check is not null then
            execute p_check into b;
            if b is distinct from true then
                raise exception using errcode = 'ZX002', message = 'неверное состояние: ' || p_check;
            end if;
        end if;
    exception when others then
        get stacked diagnostics st = returned_sqlstate, msg = message_text;
        if p_state is not null and st = p_state
           and (p_msg is null or position(p_msg in msg) > 0) then
            insert into pg_temp.result(test, ok) values (p_test, true);
        else
            insert into pg_temp.result(test, ok, details) values (p_test, false,
                case when p_state is not null then 'ожидалось ' || p_state || ' / ' || coalesce(p_msg, '') || '; ' else '' end
                || st || ': ' || msg);
        end if;
        return;
    end;
    insert into pg_temp.result(test, ok) values (p_test, true);
end $$;

-- Минимальные фикстуры. UUID нужны только для изоляции от существующих данных.
create function pg_temp.mk_address() returns uuid language plpgsql as $$
declare v_id uuid := exts.uuid_generate_v4();
begin
    insert into address(address_id, street, house_number) values (v_id, 'Тест ' || v_id, '1');
    return v_id;
end $$;

create function pg_temp.mk_ca() returns uuid language plpgsql as $$
declare
    v_client uuid := exts.uuid_generate_v4();
    v_id uuid;
    i bigint := 0;
begin
    loop
        insert into client(client_id, login, password, phone_number)
        values (v_client, 't_' || replace(v_client::text, '-', ''), md5('test'),
                '+79' || lpad(i::text, 9, '0'))
        on conflict (phone_number) do nothing;
        exit when found;
        i := i + 1;
        if i > 999999999 then raise exception 'Нет свободного тестового номера'; end if;
    end loop;
    insert into client_address(client_id, address_id) values (v_client, pg_temp.mk_address())
    returning client_address_id into v_id;
    return v_id;
end $$;

create function pg_temp.mk_rest() returns uuid language plpgsql as $$
declare v_id uuid;
begin
    insert into restaurant(restaurant_name, address_id, description, work_start, work_end,
                           inn, ogrn, bank_account, status)
    values ('Тест', pg_temp.mk_address(), 'Тест', '09:00', '22:00', '1234567890',
            '1234567890123', '40702000000000000000', 'активен')
    returning restaurant_id into v_id;
    return v_id;
end $$;

create function pg_temp.mk_product(p_rest uuid, p_unit measure_unit default 'шт', p_price numeric default 1000)
returns uuid language plpgsql as $$
declare v_cat uuid; v_id uuid;
begin
    insert into product_category(product_category_name) values ('Тест') returning product_category_id into v_cat;
    insert into product(product_name, product_category_id, price, restaurant_id, status, description, measure_unit)
    values ('Тест', v_cat, p_price, p_rest, 'доступно', 'Тест', p_unit) returning product_id into v_id;
    return v_id;
end $$;

create function pg_temp.mk_order(p_ca uuid, p_rest uuid) returns uuid language plpgsql as $$
declare v_id uuid;
begin
    insert into "order"(client_address_id, restaurant_id, status) values (p_ca, p_rest, 'создан')
    returning order_id into v_id;
    return v_id;
end $$;

create function pg_temp.item_sql(p_o uuid, p_p uuid, p_qty numeric default 1, p_price numeric default 1000)
returns text language sql as $$
    select format('insert into order_structure(order_id, product_id, quantity, price) values (%L,%L,%L,%L)', p_o,p_p,p_qty,p_price)
$$;

create function pg_temp.amount_is(p_o uuid, p_amount numeric) returns text language sql as $$
    select format('select order_amount = %L from "order" where order_id = %L', p_amount,p_o)
$$;

create function pg_temp.status_is(p_o uuid, p_status text) returns text language sql as $$
    select format('select pay_status = %L from "order" where order_id = %L', p_status,p_o)
$$;

create function pg_temp.pay_sql(p_id uuid, p_o uuid, p_amount numeric, p_status text)
returns text language sql as $$
    select format('insert into payment(payment_id, order_id, payment_type, amount, transaction_id, status) values (%L,%L,''карта'',%L,%L,%L)',
                  p_id,p_o,p_amount,p_id::text,p_status)
$$;

create function pg_temp.review_sql(p_id uuid, p_o uuid, p_type text, p_entity uuid)
returns text language sql as $$
    select format('insert into review(review_id, order_id, entity_type, entity_id, description, rating) values (%L,%L,%L,%L,''Тест'',5)',
                  p_id,p_o,p_type,p_entity)
$$;

-- 1. check_order_product_restaurant: все три направления проверки
do $t$
declare
    r uuid; r2 uuid; ca uuid; o uuid; o2 uuid; empty_o uuid; p uuid; p2 uuid; free_p uuid;
begin
    r := pg_temp.mk_rest(); r2 := pg_temp.mk_rest(); ca := pg_temp.mk_ca();
    o := pg_temp.mk_order(ca,r); o2 := pg_temp.mk_order(ca,r2); empty_o := pg_temp.mk_order(ca,r);
    p := pg_temp.mk_product(r); p2 := pg_temp.mk_product(r2); free_p := pg_temp.mk_product(r);
    perform pg_temp.expect('Ресторан: INSERT чужого блюда',
        pg_temp.item_sql(o, p2), p_state => '23514', p_msg => 'не принадлежит ресторану заказа');
    perform pg_temp.expect('Ресторан: INSERT своего блюда',
        pg_temp.item_sql(o, p),
        format($q$select exists(select 1 from order_structure where order_id = %L and product_id = %L)$q$, o, p));
    perform pg_temp.expect('Ресторан: UPDATE product_id на чужое блюдо',
        format($q$update order_structure set product_id = %L where order_id = %L and product_id = %L$q$, p2, o, p), p_state => '23514', p_msg => 'не принадлежит ресторану заказа');
    perform pg_temp.expect('Ресторан: UPDATE order_id на заказ другого ресторана',
        format($q$update order_structure set order_id = %L where order_id = %L and product_id = %L$q$, o2, o, p), p_state => '23514', p_msg => 'не принадлежит ресторану заказа');
    perform pg_temp.expect('Ресторан: смена ресторана блюда с заказами',
        format($q$update product set restaurant_id = %L where product_id = %L$q$, r2, p), p_state => '23514', p_msg => 'нарушается состав заказов');
    perform pg_temp.expect('Ресторан: смена ресторана непустого заказа',
        format($q$update "order" set restaurant_id = %L where order_id = %L$q$, r2, o), p_state => '23514', p_msg => 'в заказе есть блюда другого ресторана');
    perform pg_temp.expect('Ресторан: смена ресторана свободного блюда',
        format($q$update product set restaurant_id = %L where product_id = %L$q$, r2, free_p),
        format($q$select restaurant_id = %L from product where product_id = %L$q$, r2, free_p));
    perform pg_temp.expect('Ресторан: смена ресторана пустого заказа',
        format($q$update "order" set restaurant_id = %L where order_id = %L$q$, r2, empty_o),
        format($q$select restaurant_id = %L from "order" where order_id = %L$q$, r2, empty_o));
    perform pg_temp.expect('Ресторан: одновременная замена заказа и блюда на согласованную пару',
        format($q$update order_structure set order_id = %L, product_id = %L where order_id = %L and product_id = %L$q$, o2, p2, o, p),
        format($q$select (select order_amount = %L from "order" where order_id = %L) and (select order_amount = %L from "order" where order_id = %L)$q$, 0, o, 1000, o2));
exception when others then
    insert into pg_temp.result(test, ok, details) values ('Ресторан: ошибка подготовки/сценария', false, sqlstate || ': ' || sqlerrm);
end $t$;

-- 2. update_order_amount: INSERT / UPDATE / DELETE, обе стороны переноса
do $t$
declare
    r uuid; ca uuid; o uuid; o2 uuid; p uuid; p2 uuid; p3 uuid;
begin
    r := pg_temp.mk_rest(); ca := pg_temp.mk_ca(); o := pg_temp.mk_order(ca,r); o2 := pg_temp.mk_order(ca,r);
    p := pg_temp.mk_product(r); p2 := pg_temp.mk_product(r,'кг', 250); p3 := pg_temp.mk_product(r,'л', 100);
    perform pg_temp.expect('Сумма: первая позиция ниже порога 1000',
        pg_temp.item_sql(o, p, 1, 500),
        pg_temp.amount_is(o, 500));
    perform pg_temp.expect('Сумма: несколько позиций одним INSERT',
        format($q$insert into order_structure(order_id,product_id,quantity,price) values (%L,%L,1.5,250), (%L,%L,0.75,100)$q$, o, p2, o, p3),
        pg_temp.amount_is(o, 950));
    perform pg_temp.expect('Сумма: UPDATE quantity',
        format($q$update order_structure set quantity = 2 where order_id = %L and product_id = %L$q$, o, p),
        pg_temp.amount_is(o, 1450));
    perform pg_temp.expect('Сумма: UPDATE price',
        format($q$update order_structure set price = 600 where order_id = %L and product_id = %L$q$, o, p),
        pg_temp.amount_is(o, 1650));
    perform pg_temp.expect('Сумма: дробное произведение округляется до копеек',
        format($q$update order_structure set quantity = 1.333, price = 100.01 where order_id = %L and product_id = %L$q$, o, p3),
        pg_temp.amount_is(o, 1708.31));
    perform pg_temp.expect('Сумма: второй заказ имеет собственную позицию',
        pg_temp.item_sql(o2, p, 1, 700),
        pg_temp.amount_is(o2, 700));
    perform pg_temp.expect('Сумма: перенос позиции пересчитывает оба непустых заказа',
        format($q$update order_structure set order_id = %L where order_id = %L and product_id = %L$q$, o2, o, p2),
        format($q$select (select order_amount = %L from "order" where order_id = %L) and (select order_amount = %L from "order" where order_id = %L)$q$, 1333.31, o, 1075, o2));
    perform pg_temp.expect('Сумма: DELETE одной позиции',
        format($q$delete from order_structure where order_id = %L and product_id = %L$q$, o2, p2),
        pg_temp.amount_is(o2, 700));
    perform pg_temp.expect('Сумма: DELETE последней позиции даёт 0, не NULL',
        format($q$delete from order_structure where order_id = %L and product_id = %L$q$, o2, p),
        pg_temp.amount_is(o2, 0));
    perform pg_temp.expect('Сумма: DELETE нескольких позиций одним запросом',
        format($q$delete from order_structure where order_id = %L$q$, o),
        format($q$select (select order_amount = %L from "order" where order_id = %L) and (select order_amount = %L from "order" where order_id = %L)$q$, 0, o, 0, o2));
    perform pg_temp.expect('Сумма: округляется общая сумма, а не каждое произведение отдельно',
        format($q$insert into order_structure(order_id,product_id,quantity,price) values (%L,%L,0.005,1), (%L,%L,0.005,1)$q$, o, p2, o, p3),
        pg_temp.amount_is(o, 0.01));
exception when others then
    insert into pg_temp.result(test, ok, details) values ('Сумма: ошибка подготовки/сценария', false, sqlstate || ': ' || sqlerrm);
end $t$;

-- 3. check_product_quantity: количество и смена единицы измерения
do $t$
declare
    r uuid; ca uuid; o uuid; o2 uuid; piece uuid; kg uuid; litre uuid; free_p uuid;
begin
    r := pg_temp.mk_rest(); ca := pg_temp.mk_ca(); o := pg_temp.mk_order(ca,r); o2 := pg_temp.mk_order(ca,r);
    piece := pg_temp.mk_product(r); kg := pg_temp.mk_product(r,'кг'); litre := pg_temp.mk_product(r,'л'); free_p := pg_temp.mk_product(r,'кг');
    perform pg_temp.expect('Количество: дробное шт при INSERT',
        pg_temp.item_sql(o, piece, 1.5), p_state => '23514', p_msg => 'Количество штучного блюда должно быть целым');
    perform pg_temp.expect('Количество: целое шт',
        pg_temp.item_sql(o, piece, 2),
        pg_temp.amount_is(o, 2000));
    perform pg_temp.expect('Количество: дробное кг',
        pg_temp.item_sql(o, kg, 0.5),
        pg_temp.amount_is(o, 2500));
    perform pg_temp.expect('Количество: дробное л',
        pg_temp.item_sql(o, litre, 0.75),
        pg_temp.amount_is(o, 3250));
    perform pg_temp.expect('Количество: дробное шт при UPDATE quantity',
        format($q$update order_structure set quantity = 1.5 where order_id = %L and product_id = %L$q$, o, piece), p_state => '23514', p_msg => 'Количество штучного блюда должно быть целым');
    perform pg_temp.expect('Количество: целое шт при UPDATE',
        format($q$update order_structure set quantity = 3 where order_id = %L and product_id = %L$q$, o, piece),
        pg_temp.amount_is(o, 4250));
    perform pg_temp.expect('Количество: дробная позиция в другом заказе',
        pg_temp.item_sql(o2, kg, 0.25),
        pg_temp.amount_is(o2, 250));
    perform pg_temp.expect('Количество: UPDATE product_id с кг на шт при дробном количестве',
        format($q$update order_structure set product_id = %L where order_id = %L and product_id = %L$q$, piece, o2, kg), p_state => '23514', p_msg => 'Количество штучного блюда должно быть целым');
    perform pg_temp.expect('Количество: смена кг на шт при дробных позициях',
        format($q$update product set measure_unit = 'шт' where product_id = %L$q$, kg), p_state => '23514', p_msg => 'существуют дробные позиции заказа');
    perform pg_temp.expect('Количество: смена л на шт при дробной позиции',
        format($q$update product set measure_unit = 'шт' where product_id = %L$q$, litre), p_state => '23514', p_msg => 'существуют дробные позиции заказа');
    perform pg_temp.expect('Количество: смена кг на л с дробными позициями',
        format($q$update product set measure_unit = 'л' where product_id = %L$q$, kg),
        format($q$select measure_unit = 'л' from product where product_id = %L$q$, kg));
    perform pg_temp.expect('Количество: исправление только одной дробной позиции',
        format($q$update order_structure set quantity = 1 where order_id = %L and product_id = %L$q$, o, kg),
        pg_temp.amount_is(o, 4750));
    perform pg_temp.expect('Количество: оставшаяся дробная позиция в другом заказе блокирует шт',
        format($q$update product set measure_unit = 'шт' where product_id = %L$q$, kg), p_state => '23514', p_msg => 'существуют дробные позиции заказа');
    perform pg_temp.expect('Количество: исправление последней дробной позиции',
        format($q$update order_structure set quantity = 2 where order_id = %L and product_id = %L$q$, o2, kg),
        pg_temp.amount_is(o2, 2000));
    perform pg_temp.expect('Количество: переход на шт при целых позициях во всех заказах',
        format($q$update product set measure_unit = 'шт' where product_id = %L$q$, kg),
        format($q$select measure_unit = 'шт' from product where product_id = %L$q$, kg));
    perform pg_temp.expect('Количество: переход на шт у блюда без заказов',
        format($q$update product set measure_unit = 'шт' where product_id = %L$q$, free_p),
        format($q$select measure_unit = 'шт' from product where product_id = %L$q$, free_p));
exception when others then
    insert into pg_temp.result(test, ok, details) values ('Количество: ошибка подготовки/сценария', false, sqlstate || ': ' || sqlerrm);
end $t$;

-- 4. check_payment_amount: сумма оплаты, исторические попытки, блокировка оплаченного заказа
do $t$
declare
    r uuid; ca uuid; o uuid; o2 uuid; p uuid; p2 uuid; failed uuid := exts.uuid_generate_v4(); pending uuid := exts.uuid_generate_v4();
    spare uuid := exts.uuid_generate_v4();
begin
    r := pg_temp.mk_rest(); ca := pg_temp.mk_ca(); o := pg_temp.mk_order(ca,r); o2 := pg_temp.mk_order(ca,r);
    p := pg_temp.mk_product(r); p2 := pg_temp.mk_product(r);
    execute pg_temp.item_sql(o,p,2); execute pg_temp.item_sql(o2,p,3);
    perform pg_temp.expect('Оплата: INSERT неверной суммы (выше допустимого минимума)',
        pg_temp.pay_sql(spare, o, 2100, 'в_обработке'), p_state => '23514', p_msg => 'не соответствует общей сумме заказа');
    perform pg_temp.expect('Оплата: INSERT корректной неуспешной попытки',
        pg_temp.pay_sql(failed, o, 2200, 'ошибка'),
        pg_temp.status_is(o, 'ошибка'));
    perform pg_temp.expect('Оплата: INSERT корректной ожидающей попытки',
        pg_temp.pay_sql(pending, o, 2200, 'в_обработке'),
        pg_temp.status_is(o, 'ожидает'));
    perform pg_temp.expect('Оплата: изменение заказа при неуспешных попытках разрешено',
        format($q$update order_structure set quantity = 3 where order_id = %L and product_id = %L$q$, o, p),
        pg_temp.amount_is(o, 3000));
    perform pg_temp.expect('Оплата: устаревшая сумма попытки сохраняется; смена статуса не на успех разрешена',
        format($q$update payment set status = 'ошибка' where payment_id = %L$q$, pending),
        format($q$select amount = 2200 and status = 'ошибка' from payment where payment_id = %L$q$, pending));
    perform pg_temp.expect('Оплата: устаревшая неуспешная попытка снова может ожидать',
        format($q$update payment set status = 'в_обработке' where payment_id = %L$q$, pending),
        pg_temp.status_is(o, 'ожидает'));
    perform pg_temp.expect('Оплата: устаревшая попытка не может стать успешной',
        format($q$update payment set status = 'успех' where payment_id = %L$q$, pending), p_state => '23514', p_msg => 'не соответствует общей сумме заказа');
    perform pg_temp.expect('Оплата: UPDATE amount на неверную сумму при статусе ошибка',
        format($q$update payment set amount = 3200 where payment_id = %L$q$, failed), p_state => '23514', p_msg => 'не соответствует общей сумме заказа');
    perform pg_temp.expect('Оплата: перенос устаревшей попытки к заказу с другой суммой',
        format($q$update payment set order_id = %L where payment_id = %L$q$, o2, failed), p_state => '23514', p_msg => 'не соответствует общей сумме заказа');
    perform pg_temp.expect('Оплата: UPDATE amount на текущую сумму разрешён',
        format($q$update payment set amount = 3300 where payment_id = %L$q$, failed),
        format($q$select amount = 3300 from payment where payment_id = %L$q$, failed));
    perform pg_temp.expect('Оплата: перенос корректной попытки к заказу с равной суммой',
        format($q$update payment set order_id = %L where payment_id = %L$q$, o2, failed),
        format($q$select (select pay_status = %L from "order" where order_id = %L) and (select pay_status = %L from "order" where order_id = %L)$q$, 'ожидает', o, 'ошибка', o2));
    perform pg_temp.expect('Оплата: одновременная коррекция суммы и переход в успех',
        format($q$update payment set amount = 3300, status = 'успех' where payment_id = %L$q$, pending),
        pg_temp.status_is(o, 'оплачен'));
    perform pg_temp.expect('Оплата: успешная попытка не допускает INSERT новой позиции с изменением суммы',
        pg_temp.item_sql(o, p2, 1), p_state => '23514', p_msg => 'существует успешная попытка оплаты');
    perform pg_temp.expect('Оплата: успешная попытка не допускает UPDATE quantity с изменением суммы',
        format($q$update order_structure set quantity = 4 where order_id = %L and product_id = %L$q$, o, p), p_state => '23514', p_msg => 'существует успешная попытка оплаты');
    perform pg_temp.expect('Оплата: успешная попытка не допускает UPDATE price с изменением суммы',
        format($q$update order_structure set price = 1100 where order_id = %L and product_id = %L$q$, o, p), p_state => '23514', p_msg => 'существует успешная попытка оплаты');
    perform pg_temp.expect('Оплата: успешная попытка не допускает DELETE позиции с изменением суммы',
        format($q$delete from order_structure where order_id = %L and product_id = %L$q$, o, p), p_state => '23514', p_msg => 'существует успешная попытка оплаты');
    perform pg_temp.expect('Оплата: перенос позиции из оплаченного заказа с изменением суммы запрещён',
        format($q$update order_structure set order_id = %L, product_id = %L where order_id = %L and product_id = %L$q$, o2, p2, o, p), p_state => '23514', p_msg => 'существует успешная попытка оплаты');
    perform pg_temp.expect('Оплата: перенос позиции в оплаченный заказ с изменением суммы запрещён',
        format($q$update order_structure set order_id = %L, product_id = %L where order_id = %L and product_id = %L$q$, o, p2, o2, p), p_state => '23514', p_msg => 'существует успешная попытка оплаты');
    perform pg_temp.expect('Оплата: прямой UPDATE суммы оплаченного заказа также запрещён',
        format($q$update "order" set order_amount = 4000 where order_id = %L$q$, o), p_state => '23514', p_msg => 'существует успешная попытка оплаты');
    perform pg_temp.expect('Оплата: успешная попытка не допускает собственный UPDATE amount на неверную сумму',
        format($q$update payment set amount = 3400 where payment_id = %L$q$, pending), p_state => '23514', p_msg => 'не соответствует общей сумме заказа');
    perform pg_temp.expect('Оплата: отклонённые операции не изменили оплаченный заказ',
        null,
        format($q$select order_amount = 3000 and pay_status = 'оплачен' and (select count(*) from order_structure where order_id = %L) = 1 from "order" where order_id = %L$q$, o, o));
    perform pg_temp.expect('Оплата: UPDATE позиции без изменения итоговой суммы разрешён',
        format($q$update order_structure set quantity = 2, price = 1500 where order_id = %L and product_id = %L$q$, o, p),
        format($q$select (select order_amount = 3000 from "order" where order_id = %L) and (select quantity = 2 and price = 1500 from order_structure where order_id = %L and product_id = %L)$q$, o, o, p));
    perform pg_temp.expect('Оплата: после удаления успешной попытки сумму снова можно менять',
        format($q$delete from payment where payment_id = %L; update order_structure set quantity = 4 where order_id = %L and product_id = %L$q$, pending, o, p),
        format($q$select order_amount = 6000 and pay_status = 'ожидает' from "order" where order_id = %L$q$, o));
exception when others then
    insert into pg_temp.result(test, ok, details) values ('Сумма оплаты: ошибка подготовки/сценария', false, sqlstate || ': ' || sqlerrm);
end $t$;

-- 5. update_order_pay_status: приоритеты, смена статуса, перенос, удаление
do $t$
declare
    r uuid; ca uuid; o uuid; o2 uuid; p uuid; a uuid := exts.uuid_generate_v4(); b uuid := exts.uuid_generate_v4(); c uuid := exts.uuid_generate_v4();
begin
    r := pg_temp.mk_rest(); ca := pg_temp.mk_ca(); o := pg_temp.mk_order(ca,r); o2 := pg_temp.mk_order(ca,r);
    p := pg_temp.mk_product(r); execute pg_temp.item_sql(o,p); execute pg_temp.item_sql(o2,p);
    perform pg_temp.expect('Статус: единственная ошибка → ошибка',
        pg_temp.pay_sql(a, o, 1100, 'ошибка'),
        pg_temp.status_is(o, 'ошибка'));
    perform pg_temp.expect('Статус: ошибка + в_обработке → ожидает',
        pg_temp.pay_sql(b, o, 1100, 'в_обработке'),
        pg_temp.status_is(o, 'ожидает'));
    perform pg_temp.expect('Статус: ошибка + в_обработке + успех → оплачен',
        pg_temp.pay_sql(c, o, 1100, 'успех'),
        pg_temp.status_is(o, 'оплачен'));
    perform pg_temp.expect('Статус: UPDATE успех → ошибка при ожидающей попытке',
        format($q$update payment set status = 'ошибка' where payment_id = %L$q$, c),
        pg_temp.status_is(o, 'ожидает'));
    perform pg_temp.expect('Статус: UPDATE последней ожидающей попытки → ошибка',
        format($q$update payment set status = 'ошибка' where payment_id = %L$q$, b),
        pg_temp.status_is(o, 'ошибка'));
    perform pg_temp.expect('Статус: UPDATE ошибка → в_обработке',
        format($q$update payment set status = 'в_обработке' where payment_id = %L$q$, b),
        pg_temp.status_is(o, 'ожидает'));
    perform pg_temp.expect('Статус: UPDATE в_обработке → успех',
        format($q$update payment set status = 'успех' where payment_id = %L$q$, b),
        pg_temp.status_is(o, 'оплачен'));
    perform pg_temp.expect('Статус: перенос успешной попытки пересчитывает оба заказа',
        format($q$update payment set order_id = %L where payment_id = %L$q$, o2, b),
        format($q$select (select pay_status = %L from "order" where order_id = %L) and (select pay_status = %L from "order" where order_id = %L)$q$, 'ошибка', o, 'оплачен', o2));
    perform pg_temp.expect('Статус: перенос обратно одновременно со сменой на в_обработке',
        format($q$update payment set order_id = %L, status = 'в_обработке' where payment_id = %L$q$, o, b),
        format($q$select (select pay_status = %L from "order" where order_id = %L) and (select pay_status = %L from "order" where order_id = %L)$q$, 'ожидает', o, 'ожидает', o2));
    perform pg_temp.expect('Статус: новая успешная попытка через UPDATE',
        format($q$update payment set status = 'успех' where payment_id = %L$q$, c),
        pg_temp.status_is(o, 'оплачен'));
    perform pg_temp.expect('Статус: DELETE успеха → ожидает при оставшейся в_обработке',
        format($q$delete from payment where payment_id = %L$q$, c),
        pg_temp.status_is(o, 'ожидает'));
    perform pg_temp.expect('Статус: DELETE в_обработке → ошибка при оставшейся ошибке',
        format($q$delete from payment where payment_id = %L$q$, b),
        pg_temp.status_is(o, 'ошибка'));
    perform pg_temp.expect('Статус: DELETE последней ошибки → ожидает',
        format($q$delete from payment where payment_id = %L$q$, a),
        pg_temp.status_is(o, 'ожидает'));
exception when others then
    insert into pg_temp.result(test, ok, details) values ('Статус оплаты: ошибка подготовки/сценария', false, sqlstate || ': ' || sqlerrm);
end $t$;

-- 6. check_review_entity: три типа отзывов, INSERT и UPDATE
-- Статус «создан» выбран специально: актуальный триггер проверяет принадлежность
-- объекта заказу, а не факт доставки; успешная оплата не должна маскировать проверки.
do $t$
declare
    r uuid; r2 uuid; ca uuid; o uuid; o2 uuid; p uuid; p2 uuid; p3 uuid;
    rp uuid := exts.uuid_generate_v4(); rr uuid := exts.uuid_generate_v4(); ro uuid := exts.uuid_generate_v4(); x uuid := exts.uuid_generate_v4();
begin
    r := pg_temp.mk_rest(); r2 := pg_temp.mk_rest(); ca := pg_temp.mk_ca(); o := pg_temp.mk_order(ca,r); o2 := pg_temp.mk_order(ca,r2);
    p := pg_temp.mk_product(r); p2 := pg_temp.mk_product(r); p3 := pg_temp.mk_product(r);
    execute pg_temp.item_sql(o,p); execute pg_temp.item_sql(o,p2);
    perform pg_temp.expect('Отзыв: блюдо того же ресторана, но вне заказа',
        pg_temp.review_sql(x, o, 'блюдо', p3), p_state => '23514', p_msg => 'отсутствует в заказе');
    perform pg_temp.expect('Отзыв: ресторан не соответствует заказу',
        pg_temp.review_sql(x, o, 'ресторан', r2), p_state => '23514', p_msg => 'не соответствует ресторану заказа');
    perform pg_temp.expect('Отзыв: идентификатор другого заказа',
        pg_temp.review_sql(x, o, 'заказ', o2), p_state => '23514', p_msg => 'Идентификатор объекта отзыва не соответствует заказу');
    perform pg_temp.expect('Отзыв: заказанное блюдо',
        pg_temp.review_sql(rp, o, 'блюдо', p),
        format($q$select exists(select 1 from review where review_id = %L)$q$, rp));
    perform pg_temp.expect('Отзыв: ресторан заказа',
        pg_temp.review_sql(rr, o, 'ресторан', r),
        format($q$select exists(select 1 from review where review_id = %L)$q$, rr));
    perform pg_temp.expect('Отзыв: сам заказ',
        pg_temp.review_sql(ro, o, 'заказ', o),
        format($q$select exists(select 1 from review where review_id = %L)$q$, ro));
    perform pg_temp.expect('Отзыв: UPDATE entity_id блюда на отсутствующее',
        format($q$update review set entity_id = %L where review_id = %L$q$, p3, rp), p_state => '23514', p_msg => 'отсутствует в заказе');
    perform pg_temp.expect('Отзыв: UPDATE entity_id ресторана на чужой',
        format($q$update review set entity_id = %L where review_id = %L$q$, r2, rr), p_state => '23514', p_msg => 'не соответствует ресторану заказа');
    perform pg_temp.expect('Отзыв: UPDATE entity_id заказа на другой',
        format($q$update review set entity_id = %L where review_id = %L$q$, o2, ro), p_state => '23514', p_msg => 'Идентификатор объекта отзыва не соответствует заказу');
    perform pg_temp.expect('Отзыв: UPDATE order_id без согласования объекта',
        format($q$update review set order_id = %L where review_id = %L$q$, o2, rp), p_state => '23514', p_msg => 'отсутствует в заказе');
    perform pg_temp.expect('Отзыв: UPDATE entity_type без согласования объекта',
        format($q$update review set entity_type = 'ресторан' where review_id = %L$q$, rp), p_state => '23514', p_msg => 'не соответствует ресторану заказа');
    perform pg_temp.expect('Отзыв: UPDATE entity_id на другое блюдо заказа',
        format($q$update review set entity_id = %L where review_id = %L$q$, p2, rp),
        format($q$select entity_id = %L from review where review_id = %L$q$, p2, rp));
    perform pg_temp.expect('Отзыв: согласованный UPDATE order_id и entity_id',
        format($q$update review set order_id = %L, entity_id = %L where review_id = %L$q$, o2, o2, ro),
        format($q$select order_id = %L and entity_id = %L from review where review_id = %L$q$, o2, o2, ro));
    perform pg_temp.expect('Отзыв: согласованный UPDATE entity_type и entity_id',
        format($q$update review set entity_type = 'заказ', entity_id = %L where review_id = %L$q$, o, rp),
        format($q$select entity_type = 'заказ' and entity_id = %L from review where review_id = %L$q$, o, rp));
exception when others then
    insert into pg_temp.result(test, ok, details) values ('Объект отзыва: ошибка подготовки/сценария', false, sqlstate || ': ' || sqlerrm);
end $t$;

-- 7. check_review_entity: защита связанных объектов при обратных изменениях
do $t$
declare
    r uuid; r2 uuid; ca uuid; o uuid; o2 uuid; o3 uuid; p uuid; p2 uuid; p3 uuid;
    rp uuid := exts.uuid_generate_v4(); rr uuid := exts.uuid_generate_v4();
begin
    r := pg_temp.mk_rest(); r2 := pg_temp.mk_rest(); ca := pg_temp.mk_ca();
    o := pg_temp.mk_order(ca,r); o2 := pg_temp.mk_order(ca,r); o3 := pg_temp.mk_order(ca,r);
    p := pg_temp.mk_product(r); p2 := pg_temp.mk_product(r); p3 := pg_temp.mk_product(r);
    execute pg_temp.item_sql(o,p); execute pg_temp.item_sql(o,p2);
    execute pg_temp.review_sql(rp,o,'блюдо',p);
    -- Пустой заказ с отзывом на ресторан изолирует этот триггер от проверки состава.
    execute pg_temp.review_sql(rr,o3,'ресторан',r);
    perform pg_temp.expect('Отзыв: DELETE позиции с отзывом',
        format($q$delete from order_structure where order_id = %L and product_id = %L$q$, o, p), p_state => '23514', p_msg => 'существует отзыв');
    perform pg_temp.expect('Отзыв: UPDATE product_id позиции с отзывом',
        format($q$update order_structure set product_id = %L where order_id = %L and product_id = %L$q$, p3, o, p), p_state => '23514', p_msg => 'существует отзыв');
    perform pg_temp.expect('Отзыв: UPDATE order_id позиции с отзывом',
        format($q$update order_structure set order_id = %L where order_id = %L and product_id = %L$q$, o2, o, p), p_state => '23514', p_msg => 'существует отзыв');
    perform pg_temp.expect('Отзыв: UPDATE quantity позиции с отзывом не меняет объект отзыва',
        format($q$update order_structure set quantity = 2 where order_id = %L and product_id = %L$q$, o, p),
        pg_temp.amount_is(o, 3000));
    perform pg_temp.expect('Отзыв: UPDATE неизменных ключей позиции разрешён',
        format($q$update order_structure set order_id = order_id, product_id = product_id where order_id = %L and product_id = %L$q$, o, p),
        pg_temp.amount_is(o, 3000));
    perform pg_temp.expect('Отзыв: замена блюда без отзыва разрешена',
        format($q$update order_structure set product_id = %L where order_id = %L and product_id = %L$q$, p3, o, p2),
        format($q$select exists(select 1 from order_structure where order_id = %L and product_id = %L)$q$, o, p3));
    perform pg_temp.expect('Отзыв: DELETE блюда без отзыва разрешён',
        format($q$delete from order_structure where order_id = %L and product_id = %L$q$, o, p3),
        pg_temp.amount_is(o, 2000));
    perform pg_temp.expect('Отзыв: смена ресторана пустого заказа с отзывом на ресторан',
        format($q$update "order" set restaurant_id = %L where order_id = %L$q$, r2, o3), p_state => '23514', p_msg => 'существует отзыв на ресторан');
    perform pg_temp.expect('Отзыв: после удаления отзыва на блюдо его можно перенести',
        format($q$delete from review where review_id = %L; update order_structure set order_id = %L where order_id = %L and product_id = %L$q$, rp, o2, o, p),
        format($q$select (select order_amount = %L from "order" where order_id = %L) and (select order_amount = %L from "order" where order_id = %L)$q$, 0, o, 2000, o2));
    perform pg_temp.expect('Отзыв: после удаления отзыва на ресторан смена ресторана разрешена',
        format($q$delete from review where review_id = %L; update "order" set restaurant_id = %L where order_id = %L$q$, rr, r2, o3),
        format($q$select restaurant_id = %L from "order" where order_id = %L$q$, r2, o3));
    perform pg_temp.expect('Отзыв: отзыв на заказ сам по себе не блокирует смену ресторана',
        pg_temp.review_sql(rr,o3,'заказ',o3) || format($q$; update "order" set restaurant_id = %L where order_id = %L$q$, r, o3),
        format($q$select restaurant_id = %L from "order" where order_id = %L$q$, r, o3));
exception when others then
    insert into pg_temp.result(test, ok, details) values ('Защита объекта отзыва: ошибка подготовки/сценария', false, sqlstate || ': ' || sqlerrm);
end $t$;

-- Итог: одна строка со счётчиками и отдельный вывод только ошибок.
select count(*) filter (where ok) as passed,
       count(*) filter (where not ok) as failed,
       count(*) as total
from pg_temp.result;
select id, test, details from pg_temp.result where not ok order by id;
rollback;
