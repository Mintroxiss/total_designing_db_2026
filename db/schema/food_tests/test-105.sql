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


-- ИНФРАСТРУКТУРА

-- отложенные триггеры схемы срабатывают только при immediate
create function tst.settle() returns void language plpgsql as $$
begin
    set constraints all immediate;
    set constraints all deferred;
end $$;


create function tst.wipe() returns void language plpgsql as $$
declare
    v_tables text;
begin
    set constraints all immediate;

    select string_agg(format('%I.%I', schemaname, tablename), ', ' order by tablename)
    into v_tables
    from pg_tables
    where schemaname = 'shkuratetskiy_food';

    if v_tables is not null then
        execute 'truncate table ' || v_tables || ' restart identity';
    end if;

    set constraints all deferred;
end $$;


create function tst.expect_error(p_test text, p_sql text, p_sqlstate text default null, p_msg text default null)
returns void language plpgsql as $$
declare
    st  text;
    msg text;
begin
    begin
        execute p_sql;
        perform tst.settle();
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

    insert into tst.result(test, ok, details)
    values (p_test, false, 'ожидалась ошибка, но запрос выполнился');
end $$;


create function tst.expect_ok(p_test text, p_sql text)
returns void language plpgsql as $$
begin
    execute p_sql;
    perform tst.settle();
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


-- сравнение рейтинга сущности с ожидаемым; NULL = NULL считается совпадением
create function tst.expect_rating(p_test text, p_tbl text, p_id uuid, p_expected numeric)
returns void language plpgsql as $$
declare
    v numeric;
begin
    execute format('select rating from shkuratetskiy_food.%I where %I = $1', p_tbl, p_tbl || '_id')
    into v using p_id;

    insert into tst.result(test, ok, details)
    values (p_test,
            v is not distinct from p_expected,
            case when v is not distinct from p_expected then null
                 else format('ожидалось %s, получено %s', coalesce(p_expected::text, 'NULL'), coalesce(v::text, 'NULL')) end);
exception when others then
    insert into tst.result(test, ok, details) values (p_test, false, sqlstate || ': ' || sqlerrm);
end $$;


-- ГЕНЕРАТОРЫ ДАННЫХ

create function tst.mk_rest() returns uuid language plpgsql as $$
declare
    n bigint := nextval('tst.seq');
    a uuid;
    r uuid;
begin
    insert into shkuratetskiy_food.address(street, house_number)
    values ('Ресторанная ' || n, '1') returning address_id into a;

    insert into shkuratetskiy_food.restaurant(restaurant_name, address_id, description, work_start, work_end, company_details, status)
    values ('Ресторан ' || n, a, 'описание', '09:00', '22:00', 'реквизиты', 'активен')
    returning restaurant_id into r;

    return r;
end $$;


create function tst.mk_product(p_rest uuid, p_price numeric default 1000) returns uuid language plpgsql as $$
declare
    n bigint := nextval('tst.seq');
    c uuid;
    p uuid;
begin
    insert into shkuratetskiy_food.product_category(product_category_name)
    values ('Категория ' || n) returning product_category_id into c;

    insert into shkuratetskiy_food.product(product_name, product_category_id, price, restaurant_id, status, description, measure_unit)
    values ('Блюдо ' || n, c, p_price, p_rest, 'доступно', 'описание', 'шт')
    returning product_id into p;

    return p;
end $$;


-- доставленный и оплаченный заказ с позициями p_products
create function tst.mk_order(p_rest uuid, p_products uuid[]) returns uuid language plpgsql as $$
declare
    n  bigint := nextval('tst.seq');
    cl uuid;
    ad uuid;
    ca uuid;
    o  uuid;
    p  uuid;
begin
    insert into shkuratetskiy_food.client(login, password, phone_number)
    values ('user_' || n, md5(n::text), '+79' || lpad(n::text, 9, '0'))
    returning client_id into cl;

    insert into shkuratetskiy_food.address(street, house_number)
    values ('Клиентская ' || n, '1') returning address_id into ad;

    insert into shkuratetskiy_food.client_address(client_id, address_id)
    values (cl, ad) returning client_address_id into ca;

    insert into shkuratetskiy_food."order"(client_address_id, restaurant_id, status)
    values (ca, p_rest, 'создан') returning order_id into o;

    foreach p in array p_products loop
        insert into shkuratetskiy_food.order_structure(order_id, product_id, quantity)
        values (o, p, 1);
    end loop;

    insert into shkuratetskiy_food.payment(order_id, payment_type, transaction_id, status)
    values (o, 'карта', 'tx-' || n, 'успех');

    update shkuratetskiy_food."order"
       set status = 'доставлен', delivery_timestamp = localtimestamp
     where order_id = o;

    return o;
end $$;


-- p_kind: 'product' | 'restaurant' | 'order'; p_target — id блюда/ресторана (для 'order' игнорируется)
create function tst.mk_review(p_order uuid, p_rating numeric, p_kind text, p_target uuid) returns uuid language plpgsql as $$
declare
    rv uuid;
begin
    insert into shkuratetskiy_food.review(order_id, description, rating)
    values (p_order, 'отзыв', p_rating) returning review_id into rv;

    if p_kind = 'product' then
        insert into shkuratetskiy_food.product_review(review_id, product_id) values (rv, p_target);
    elsif p_kind = 'restaurant' then
        insert into shkuratetskiy_food.restaurant_review(review_id, restaurant_id) values (rv, p_target);
    elsif p_kind = 'order' then
        insert into shkuratetskiy_food.order_review(review_id) values (rv);
    else
        raise exception 'неизвестный вид отзыва %', p_kind;
    end if;

    perform tst.settle();
    return rv;
end $$;


-- по одному новому доставленному заказу на каждую оценку; возвращает review_id в том же порядке
create function tst.mk_reviews(p_kind text, p_rest uuid, p_prod uuid, p_ratings numeric[]) returns uuid[] language plpgsql as $$
declare
    res uuid[] := '{}';
    x   numeric;
    o   uuid;
begin
    foreach x in array p_ratings loop
        o := tst.mk_order(p_rest, array[p_prod]);
        res := res || tst.mk_review(o, x, p_kind,
                                    case p_kind when 'product' then p_prod when 'restaurant' then p_rest end);
    end loop;
    return res;
end $$;


-- 1. Статика: форма триггеров
do $t$
declare
    fn text := $f$'shkuratetskiy_food.rating_change()'::regprocedure$f$;
begin
    perform tst.expect_true('статика: rating_change() возвращает trigger',
        format('select prorettype = ''trigger''::regtype from pg_proc where oid = %s', fn));

    perform tst.expect_true('статика: rating_change висит ровно на product_review, restaurant_review, review',
        format($q$select (select array_agg(distinct c.relname::text order by c.relname::text)
                          from pg_trigger t join pg_class c on c.oid = t.tgrelid
                          where t.tgfoid = %s and not t.tgisinternal)
                      = array['product_review', 'restaurant_review', 'review']$q$, fn));

    perform tst.expect_true('статика: на подтипах блюда и ресторана AFTER INSERT+UPDATE+DELETE',
        format($q$select count(*) = 2 from pg_trigger t
                  where t.tgfoid = %s and not t.tgisinternal
                    and t.tgrelid in ('shkuratetskiy_food.product_review'::regclass, 'shkuratetskiy_food.restaurant_review'::regclass)
                    and (t.tgtype & 28) = 28 and (t.tgtype & 2) = 0$q$, fn));

    perform tst.expect_true('статика: на review только AFTER UPDATE (оценка)',
        format($q$select exists (select 1 from pg_trigger t
                  where t.tgfoid = %s and not t.tgisinternal
                    and t.tgrelid = 'shkuratetskiy_food.review'::regclass
                    and (t.tgtype & 28) = 16 and (t.tgtype & 2) = 0)$q$, fn));
end $t$;


-- 2. Блюдо: начальное значение и первые отзывы
do $t$
declare
    r uuid; p uuid;
begin
    perform tst.wipe();
    r := tst.mk_rest();
    p := tst.mk_product(r);

    perform tst.expect_rating('блюдо: без отзывов rating = NULL', 'product', p, null);

    perform tst.mk_reviews('product', r, p, array[3]::numeric[]);
    perform tst.expect_rating('блюдо: один отзыв 3 → 3.00', 'product', p, 3.00);

    perform tst.mk_reviews('product', r, p, array[4]::numeric[]);
    perform tst.expect_rating('блюдо: отзывы 3, 4 → 3.50', 'product', p, 3.50);

    perform tst.mk_reviews('product', r, p, array[5]::numeric[]);
    perform tst.expect_rating('блюдо: отзывы 3, 4, 5 → 4.00 (проверка из задачи)', 'product', p, 4.00);
exception when others then
    insert into tst.result(test, ok, details) values ('блюдо: вставка отзывов — сценарий упал', false, sqlstate || ': ' || sqlerrm);
end $t$;


do $t$
declare
    r uuid; p uuid;
begin
    perform tst.wipe();
    r := tst.mk_rest();
    p := tst.mk_product(r);

    perform tst.mk_reviews('product', r, p, array[3, 4, 5]::numeric[]);
    perform tst.expect_rating('блюдо: сразу три отзыва 3, 4, 5 → 4.00', 'product', p, 4.00);
exception when others then
    insert into tst.result(test, ok, details) values ('блюдо: три отзыва — сценарий упал', false, sqlstate || ': ' || sqlerrm);
end $t$;


-- 3. Блюдо: удаление одного отзыва из {3, 4, 5}
do $t$
declare
    r uuid; p uuid; rv uuid[]; x int;
begin
    perform tst.wipe();
    r := tst.mk_rest();

    foreach x in array array[3, 4, 5] loop
        p  := tst.mk_product(r);
        rv := tst.mk_reviews('product', r, p, array[3, 4, 5]::numeric[]);

        delete from shkuratetskiy_food.review where review_id = rv[x - 2];
        perform tst.settle();

        perform tst.expect_rating(format('блюдо: удалён отзыв с оценкой %s из {3,4,5}', x), 'product', p,
                                  case x when 3 then 4.50 when 4 then 4.00 else 3.50 end);
    end loop;
exception when others then
    insert into tst.result(test, ok, details) values ('блюдо: удаление отзыва — сценарий упал', false, sqlstate || ': ' || sqlerrm);
end $t$;


-- 4. Блюдо: последовательное удаление до пустого набора
do $t$
declare
    r uuid; p uuid; rv uuid[];
begin
    perform tst.wipe();
    r  := tst.mk_rest();
    p  := tst.mk_product(r);
    rv := tst.mk_reviews('product', r, p, array[3, 4, 5]::numeric[]);

    delete from shkuratetskiy_food.review where review_id = rv[1];
    perform tst.settle();
    perform tst.expect_rating('блюдо: после удаления 3 остались {4,5} → 4.50', 'product', p, 4.50);

    delete from shkuratetskiy_food.review where review_id = rv[2];
    perform tst.settle();
    perform tst.expect_rating('блюдо: после удаления 4 остался {5} → 5.00', 'product', p, 5.00);

    delete from shkuratetskiy_food.review where review_id = rv[3];
    perform tst.settle();
    perform tst.expect_rating('блюдо: удалён последний отзыв → NULL', 'product', p, null);
exception when others then
    insert into tst.result(test, ok, details) values ('блюдо: удаление до пустого — сценарий упал', false, sqlstate || ': ' || sqlerrm);
end $t$;


-- 5. Блюдо: изменение оценки
do $t$
declare
    r uuid; p uuid; rv uuid[];
begin
    perform tst.wipe();
    r  := tst.mk_rest();
    p  := tst.mk_product(r);
    rv := tst.mk_reviews('product', r, p, array[3, 4, 5]::numeric[]);

    update shkuratetskiy_food.review set rating = 5 where review_id = rv[1];
    perform tst.settle();
    perform tst.expect_rating('блюдо: оценка 3 → 5, итого {5,4,5} → 4.67', 'product', p, 4.67);

    update shkuratetskiy_food.review set rating = 1 where review_id = rv[3];
    perform tst.settle();
    perform tst.expect_rating('блюдо: оценка 5 → 1, итого {5,4,1} → 3.33', 'product', p, 3.33);
exception when others then
    insert into tst.result(test, ok, details) values ('блюдо: изменение оценки — сценарий упал', false, sqlstate || ': ' || sqlerrm);
end $t$;


-- фиксируем поведение условия WHEN: UPDATE без реального изменения оценки пересчёт не запускает
do $t$
declare
    r uuid; p uuid; rv uuid[];
begin
    perform tst.wipe();
    r  := tst.mk_rest();
    p  := tst.mk_product(r);
    rv := tst.mk_reviews('product', r, p, array[3, 5]::numeric[]);

    update shkuratetskiy_food.product set rating = 1.00 where product_id = p;
    update shkuratetskiy_food.review set rating = rating where review_id = rv[1];
    perform tst.settle();

    perform tst.expect_rating('блюдо: UPDATE rating = rating не пересчитывает (условие WHEN)', 'product', p, 1.00);
exception when others then
    insert into tst.result(test, ok, details) values ('блюдо: no-op UPDATE — сценарий упал', false, sqlstate || ': ' || sqlerrm);
end $t$;


-- 6. Блюдо: перенос отзыва на другое блюдо пересчитывает и старое, и новое
do $t$
declare
    r uuid; a uuid; b uuid; o_ab uuid; o_a uuid; o_b uuid; rv_a1 uuid;
begin
    perform tst.wipe();
    r := tst.mk_rest();
    a := tst.mk_product(r);
    b := tst.mk_product(r);

    o_ab  := tst.mk_order(r, array[a, b]);
    rv_a1 := tst.mk_review(o_ab, 5, 'product', a);

    o_a := tst.mk_order(r, array[a]);
    perform tst.mk_review(o_a, 3, 'product', a);

    o_b := tst.mk_order(r, array[b]);
    perform tst.mk_review(o_b, 2, 'product', b);

    perform tst.expect_rating('перенос: до переноса A = avg(5,3) = 4.00', 'product', a, 4.00);
    perform tst.expect_rating('перенос: до переноса B = 2.00', 'product', b, 2.00);

    update shkuratetskiy_food.product_review set product_id = b where review_id = rv_a1;
    perform tst.settle();

    perform tst.expect_rating('перенос: старое блюдо A после переноса = 3.00', 'product', a, 3.00);
    perform tst.expect_rating('перенос: новое блюдо B после переноса = avg(2,5) = 3.50', 'product', b, 3.50);
exception when others then
    insert into tst.result(test, ok, details) values ('перенос: отзыв на другое блюдо — сценарий упал', false, sqlstate || ': ' || sqlerrm);
end $t$;


-- перенос единственного отзыва: старое блюдо остаётся без отзывов => NULL
do $t$
declare
    r uuid; a uuid; b uuid; o uuid; rv uuid;
begin
    perform tst.wipe();
    r := tst.mk_rest();
    a := tst.mk_product(r);
    b := tst.mk_product(r);

    o  := tst.mk_order(r, array[a, b]);
    rv := tst.mk_review(o, 4, 'product', a);

    update shkuratetskiy_food.product_review set product_id = b where review_id = rv;
    perform tst.settle();

    perform tst.expect_rating('перенос: у старого блюда не осталось отзывов → NULL', 'product', a, null);
    perform tst.expect_rating('перенос: новое блюдо получило 4.00', 'product', b, 4.00);
exception when others then
    insert into tst.result(test, ok, details) values ('перенос: единственный отзыв — сценарий упал', false, sqlstate || ': ' || sqlerrm);
end $t$;


-- 7. Блюдо: округление до 2 знаков
do $t$
declare
    r uuid; p uuid;
begin
    perform tst.wipe();
    r := tst.mk_rest();

    p := tst.mk_product(r);
    perform tst.mk_reviews('product', r, p, array[3, 4, 4]::numeric[]);
    perform tst.expect_rating('округление: {3,4,4} → 3.67', 'product', p, 3.67);

    p := tst.mk_product(r);
    perform tst.mk_reviews('product', r, p, array[3, 3, 4]::numeric[]);
    perform tst.expect_rating('округление: {3,3,4} → 3.33', 'product', p, 3.33);

    p := tst.mk_product(r);
    perform tst.mk_reviews('product', r, p, array[4.5, 4]::numeric[]);
    perform tst.expect_rating('округление: дробные оценки {4.5,4} → 4.25', 'product', p, 4.25);
exception when others then
    insert into tst.result(test, ok, details) values ('округление — сценарий упал', false, sqlstate || ': ' || sqlerrm);
end $t$;


-- 8. Ресторан: вставка
do $t$
declare
    r uuid; p uuid;
begin
    perform tst.wipe();
    r := tst.mk_rest();
    p := tst.mk_product(r);

    perform tst.expect_rating('ресторан: без отзывов rating = NULL', 'restaurant', r, null);

    perform tst.mk_reviews('restaurant', r, p, array[3]::numeric[]);
    perform tst.expect_rating('ресторан: один отзыв 3 → 3.00', 'restaurant', r, 3.00);

    perform tst.mk_reviews('restaurant', r, p, array[4]::numeric[]);
    perform tst.expect_rating('ресторан: отзывы 3, 4 → 3.50', 'restaurant', r, 3.50);

    perform tst.mk_reviews('restaurant', r, p, array[5]::numeric[]);
    perform tst.expect_rating('ресторан: отзывы 3, 4, 5 → 4.00', 'restaurant', r, 4.00);
exception when others then
    insert into tst.result(test, ok, details) values ('ресторан: вставка — сценарий упал', false, sqlstate || ': ' || sqlerrm);
end $t$;


-- 9. Ресторан: удаление, до пустого набора, изменение оценки
do $t$
declare
    r uuid; p uuid; rv uuid[]; x int;
begin
    perform tst.wipe();

    foreach x in array array[3, 4, 5] loop
        r  := tst.mk_rest();
        p  := tst.mk_product(r);
        rv := tst.mk_reviews('restaurant', r, p, array[3, 4, 5]::numeric[]);

        delete from shkuratetskiy_food.review where review_id = rv[x - 2];
        perform tst.settle();

        perform tst.expect_rating(format('ресторан: удалён отзыв с оценкой %s из {3,4,5}', x), 'restaurant', r,
                                  case x when 3 then 4.50 when 4 then 4.00 else 3.50 end);
    end loop;
exception when others then
    insert into tst.result(test, ok, details) values ('ресторан: удаление отзыва — сценарий упал', false, sqlstate || ': ' || sqlerrm);
end $t$;


do $t$
declare
    r uuid; p uuid; rv uuid[];
begin
    perform tst.wipe();
    r  := tst.mk_rest();
    p  := tst.mk_product(r);
    rv := tst.mk_reviews('restaurant', r, p, array[3, 4, 5]::numeric[]);

    delete from shkuratetskiy_food.review where review_id = rv[1];
    perform tst.settle();
    delete from shkuratetskiy_food.review where review_id = rv[2];
    perform tst.settle();
    perform tst.expect_rating('ресторан: остался один отзыв {5} → 5.00', 'restaurant', r, 5.00);

    delete from shkuratetskiy_food.review where review_id = rv[3];
    perform tst.settle();
    perform tst.expect_rating('ресторан: удалён последний отзыв → NULL', 'restaurant', r, null);
exception when others then
    insert into tst.result(test, ok, details) values ('ресторан: удаление до пустого — сценарий упал', false, sqlstate || ': ' || sqlerrm);
end $t$;


do $t$
declare
    r uuid; p uuid; rv uuid[];
begin
    perform tst.wipe();
    r  := tst.mk_rest();
    p  := tst.mk_product(r);
    rv := tst.mk_reviews('restaurant', r, p, array[3, 4, 5]::numeric[]);

    update shkuratetskiy_food.review set rating = 5 where review_id = rv[1];
    perform tst.settle();
    perform tst.expect_rating('ресторан: оценка 3 → 5, итого {5,4,5} → 4.67', 'restaurant', r, 4.67);
exception when others then
    insert into tst.result(test, ok, details) values ('ресторан: изменение оценки — сценарий упал', false, sqlstate || ': ' || sqlerrm);
end $t$;


-- 10. Ресторан: перенос отзыва на чужой ресторан запрещён схемой, рейтинги не меняются
do $t$
declare
    r1 uuid; r2 uuid; p1 uuid; rv uuid[];
begin
    perform tst.wipe();
    r1 := tst.mk_rest();
    r2 := tst.mk_rest();
    p1 := tst.mk_product(r1);
    rv := tst.mk_reviews('restaurant', r1, p1, array[5]::numeric[]);

    perform tst.expect_error('ресторан: перенос отзыва в другой ресторан → check_violation',
        format('update shkuratetskiy_food.restaurant_review set restaurant_id = %L where review_id = %L', r2, rv[1]),
        '23514');

    perform tst.expect_rating('ресторан: после отклонённого переноса рейтинг первого не изменился', 'restaurant', r1, 5.00);
    perform tst.expect_rating('ресторан: после отклонённого переноса рейтинг второго NULL', 'restaurant', r2, null);
exception when others then
    insert into tst.result(test, ok, details) values ('ресторан: перенос — сценарий упал', false, sqlstate || ': ' || sqlerrm);
end $t$;


-- 11. Блюдо и ресторан считаются независимо
do $t$
declare
    r uuid; p uuid;
begin
    perform tst.wipe();
    r := tst.mk_rest();
    p := tst.mk_product(r);

    perform tst.mk_reviews('product', r, p, array[4]::numeric[]);
    perform tst.expect_rating('независимость: отзыв на блюдо → блюдо 4.00', 'product', p, 4.00);
    perform tst.expect_rating('независимость: отзыв на блюдо не меняет рейтинг ресторана', 'restaurant', r, null);

    perform tst.mk_reviews('restaurant', r, p, array[2]::numeric[]);
    perform tst.expect_rating('независимость: отзыв на ресторан не меняет рейтинг блюда', 'product', p, 4.00);
    perform tst.expect_rating('независимость: отзыв на ресторан → ресторан 2.00', 'restaurant', r, 2.00);
exception when others then
    insert into tst.result(test, ok, details) values ('независимость блюдо/ресторан — сценарий упал', false, sqlstate || ': ' || sqlerrm);
end $t$;


-- 12. Отзыв на блюдо A не меняет рейтинг блюда B
do $t$
declare
    r uuid; a uuid; b uuid; o uuid;
begin
    perform tst.wipe();
    r := tst.mk_rest();
    a := tst.mk_product(r);
    b := tst.mk_product(r);
    o := tst.mk_order(r, array[a, b]);

    perform tst.mk_review(o, 5, 'product', a);
    perform tst.expect_rating('изоляция блюд: A = 5.00', 'product', a, 5.00);
    perform tst.expect_rating('изоляция блюд: B без отзывов → NULL', 'product', b, null);

    perform tst.mk_review(o, 1, 'product', b);
    perform tst.expect_rating('изоляция блюд: после отзыва на B рейтинг A не изменился', 'product', a, 5.00);
    perform tst.expect_rating('изоляция блюд: B = 1.00', 'product', b, 1.00);
exception when others then
    insert into tst.result(test, ok, details) values ('изоляция блюд — сценарий упал', false, sqlstate || ': ' || sqlerrm);
end $t$;


-- изоляция ресторанов
do $t$
declare
    r1 uuid; r2 uuid; p1 uuid; p2 uuid;
begin
    perform tst.wipe();
    r1 := tst.mk_rest();
    r2 := tst.mk_rest();
    p1 := tst.mk_product(r1);
    p2 := tst.mk_product(r2);

    perform tst.mk_reviews('restaurant', r2, p2, array[2]::numeric[]);
    perform tst.mk_reviews('restaurant', r1, p1, array[5]::numeric[]);

    perform tst.expect_rating('изоляция ресторанов: отзыв на первый не меняет второй', 'restaurant', r2, 2.00);
    perform tst.expect_rating('изоляция ресторанов: первый = 5.00', 'restaurant', r1, 5.00);
exception when others then
    insert into tst.result(test, ok, details) values ('изоляция ресторанов — сценарий упал', false, sqlstate || ': ' || sqlerrm);
end $t$;


-- 13. Отзыв на заказ ничего не пересчитывает
do $t$
declare
    r uuid; p uuid; o uuid;
begin
    perform tst.wipe();

    -- нет других отзывов: рейтинги остаются NULL
    r := tst.mk_rest();
    p := tst.mk_product(r);
    o := tst.mk_order(r, array[p]);
    perform tst.mk_review(o, 5, 'order', null);
    perform tst.expect_rating('заказ: отзыв на заказ, блюдо остаётся NULL', 'product', p, null);
    perform tst.expect_rating('заказ: отзыв на заказ, ресторан остаётся NULL', 'restaurant', r, null);

    -- есть отзывы на блюдо и ресторан: значения не меняются
    r := tst.mk_rest();
    p := tst.mk_product(r);
    perform tst.mk_reviews('product', r, p, array[3]::numeric[]);
    perform tst.mk_reviews('restaurant', r, p, array[4]::numeric[]);
    o := tst.mk_order(r, array[p]);
    perform tst.mk_review(o, 1, 'order', null);
    perform tst.expect_rating('заказ: отзыв на заказ не меняет рейтинг блюда', 'product', p, 3.00);
    perform tst.expect_rating('заказ: отзыв на заказ не меняет рейтинг ресторана', 'restaurant', r, 4.00);
exception when others then
    insert into tst.result(test, ok, details) values ('заказ: вставка отзыва — сценарий упал', false, sqlstate || ': ' || sqlerrm);
end $t$;


-- 14. Изменение и удаление отзыва на заказ тоже не трогают агрегаты
do $t$
declare
    r uuid; p uuid; o uuid; orv uuid;
begin
    perform tst.wipe();
    r := tst.mk_rest();
    p := tst.mk_product(r);
    perform tst.mk_reviews('product', r, p, array[3]::numeric[]);
    perform tst.mk_reviews('restaurant', r, p, array[4]::numeric[]);

    o   := tst.mk_order(r, array[p]);
    orv := tst.mk_review(o, 5, 'order', null);

    perform tst.expect_ok('заказ: изменение оценки отзыва на заказ проходит без ошибок',
        format('update shkuratetskiy_food.review set rating = 1 where review_id = %L', orv));
    perform tst.expect_rating('заказ: после смены оценки блюдо = 3.00', 'product', p, 3.00);
    perform tst.expect_rating('заказ: после смены оценки ресторан = 4.00', 'restaurant', r, 4.00);

    perform tst.expect_ok('заказ: удаление отзыва на заказ проходит без ошибок',
        format('delete from shkuratetskiy_food.review where review_id = %L', orv));
    perform tst.expect_rating('заказ: после удаления блюдо = 3.00', 'product', p, 3.00);
    perform tst.expect_rating('заказ: после удаления ресторан = 4.00', 'restaurant', r, 4.00);
exception when others then
    insert into tst.result(test, ok, details) values ('заказ: изменение/удаление — сценарий упал', false, sqlstate || ': ' || sqlerrm);
end $t$;


-- 15. Смена оценки отзыва на блюдо не трогает рейтинг ресторана и наоборот
do $t$
declare
    r uuid; p uuid; rv_p uuid[]; rv_r uuid[];
begin
    perform tst.wipe();
    r    := tst.mk_rest();
    p    := tst.mk_product(r);
    rv_p := tst.mk_reviews('product', r, p, array[3]::numeric[]);
    rv_r := tst.mk_reviews('restaurant', r, p, array[4]::numeric[]);

    update shkuratetskiy_food.review set rating = 5 where review_id = rv_p[1];
    perform tst.settle();
    perform tst.expect_rating('смена оценки блюда: блюдо = 5.00', 'product', p, 5.00);
    perform tst.expect_rating('смена оценки блюда: ресторан не изменился', 'restaurant', r, 4.00);

    update shkuratetskiy_food.review set rating = 2 where review_id = rv_r[1];
    perform tst.settle();
    perform tst.expect_rating('смена оценки ресторана: ресторан = 2.00', 'restaurant', r, 2.00);
    perform tst.expect_rating('смена оценки ресторана: блюдо не изменилось', 'product', p, 5.00);
exception when others then
    insert into tst.result(test, ok, details) values ('смена оценки: независимость — сценарий упал', false, sqlstate || ': ' || sqlerrm);
end $t$;


-- 16. Каскад: рейтинги пересчитываются, когда отзыв удалён вместе со своим подтипом, а у блюда остаются другие отзывы
do $t$
declare
    r uuid; a uuid; b uuid; o uuid; rv_a uuid; rv_b uuid;
begin
    perform tst.wipe();
    r := tst.mk_rest();
    a := tst.mk_product(r);
    b := tst.mk_product(r);
    o := tst.mk_order(r, array[a, b]);

    rv_a := tst.mk_review(o, 5, 'product', a);
    rv_b := tst.mk_review(o, 2, 'product', b);

    delete from shkuratetskiy_food.review where review_id = rv_a;
    perform tst.settle();

    perform tst.expect_rating('каскад: удалён отзыв на A → A = NULL', 'product', a, null);
    perform tst.expect_rating('каскад: удаление отзыва на A не трогает B', 'product', b, 2.00);
exception when others then
    insert into tst.result(test, ok, details) values ('каскад — сценарий упал', false, sqlstate || ': ' || sqlerrm);
end $t$;


-- 17. Ручное значение перезаписывается при следующем изменении отзывов
do $t$
declare
    r uuid; p uuid;
begin
    perform tst.wipe();
    r := tst.mk_rest();
    p := tst.mk_product(r);
    perform tst.mk_reviews('product', r, p, array[3]::numeric[]);

    update shkuratetskiy_food.product set rating = 1.00 where product_id = p;
    perform tst.expect_rating('ручной рейтинг: значение записано', 'product', p, 1.00);

    perform tst.mk_reviews('product', r, p, array[5]::numeric[]);
    perform tst.expect_rating('ручной рейтинг: новый отзыв пересчитал по всем отзывам {3,5} → 4.00', 'product', p, 4.00);
exception when others then
    insert into tst.result(test, ok, details) values ('ручной рейтинг — сценарий упал', false, sqlstate || ': ' || sqlerrm);
end $t$;


-- 18. refresh_* напрямую: тот же результат, что и у триггера; без отзывов — NULL; чужой id не падает
do $t$
declare
    r uuid; p uuid; p0 uuid;
begin
    perform tst.wipe();
    r  := tst.mk_rest();
    p  := tst.mk_product(r);
    p0 := tst.mk_product(r);

    perform tst.mk_reviews('product', r, p, array[3, 5]::numeric[]);
    perform tst.mk_reviews('restaurant', r, p, array[2, 4]::numeric[]);

    update shkuratetskiy_food.product set rating = 1.00 where product_id in (p, p0);
    update shkuratetskiy_food.restaurant set rating = 1.00 where restaurant_id = r;

    perform shkuratetskiy_food.refresh_product_rating(p);
    perform shkuratetskiy_food.refresh_product_rating(p0);
    perform shkuratetskiy_food.refresh_restaurant_rating(r);

    perform tst.expect_rating('refresh_product_rating: пересчёт {3,5} → 4.00', 'product', p, 4.00);
    perform tst.expect_rating('refresh_product_rating: блюдо без отзывов → NULL', 'product', p0, null);
    perform tst.expect_rating('refresh_restaurant_rating: пересчёт {2,4} → 3.00', 'restaurant', r, 3.00);

    perform tst.expect_ok('refresh_product_rating: несуществующий id не падает',
        format('select shkuratetskiy_food.refresh_product_rating(%L)', exts.uuid_generate_v4()));
    perform tst.expect_ok('refresh_restaurant_rating: несуществующий id не падает',
        format('select shkuratetskiy_food.refresh_restaurant_rating(%L)', exts.uuid_generate_v4()));
exception when others then
    insert into tst.result(test, ok, details) values ('refresh_*: прямой вызов — сценарий упал', false, sqlstate || ': ' || sqlerrm);
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