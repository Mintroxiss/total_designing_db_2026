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

create table tst.snap (tbl text not null, h text not null);
create index on tst.snap (tbl, h);


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

    insert into tst.result(test, ok, details)
    values (p_test, false, 'ожидалась ошибка, но запрос выполнился');
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


-- запрос возвращает текст с описанием нарушений; NULL = тест пройден
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
    set constraints all immediate;

    select string_agg(
        format('%I.%I', schemaname, tablename),
        ', ' order by tablename
    )
    into v_tables
    from pg_tables
    where schemaname = 'shkuratetskiy_food';

    if v_tables is not null then
        execute 'truncate table ' || v_tables || ' restart identity';
    end if;

    set constraints all deferred;
end $$;


create function tst.total() returns bigint language plpgsql as $$
declare
    r record;
    c bigint;
    t bigint := 0;
begin
    for r in select tablename from pg_tables where schemaname = 'shkuratetskiy_food' loop
        execute format('select count(*) from shkuratetskiy_food.%I', r.tablename) into c;
        t := t + c;
    end loop;
    return t;
end $$;


create function tst.coef(p_cnt bigint) returns numeric language sql immutable as $$
    select case when p_cnt <= 150 then 0.1
                when p_cnt <= 250 then 0.2
                when p_cnt <= 500 then 0.3
                else 0.5 end
$$;


-- строки: от 1 до N символов
create function tst.bad_strings() returns text language plpgsql as $$
declare
    r record;
    v_c bigint;
    res text := '';
begin
    for r in select table_name t, column_name col, character_maximum_length ml
             from information_schema.columns
             where table_schema = 'shkuratetskiy_food'
               and data_type in ('character varying', 'character', 'text') loop
        execute format('select count(*) from shkuratetskiy_food.%I where char_length(%I) not between 1 and %s',
                       r.t, r.col, coalesce(r.ml, 1000000000)) into v_c;
        if v_c > 0 then
            res := res || format('%s.%s: %s; ', r.t, r.col, v_c);
        end if;
    end loop;
    return res;
end $$;


create function tst.bad_nulls() returns text language plpgsql as $$
declare
    r record;
    v_c bigint;
    res text := '';
begin
    for r in select table_name t, column_name col
             from information_schema.columns
             where table_schema = 'shkuratetskiy_food' and is_nullable = 'YES'
               and (table_name, column_name) not in (
                   ('address','apartment_office'), ('courier','dismissal_date'),
                   ('restaurant','rating'), ('product','rating'), ('product','photo_url'),
                   ('review','photo_url'), ('order','courier_id'), ('order','delivery_timestamp')) loop
        execute format('select count(*) from shkuratetskiy_food.%I where %I is null', r.t, r.col) into v_c;
        if v_c > 0 then
            res := res || format('%s.%s: %s; ', r.t, r.col, v_c);
        end if;
    end loop;
    return res;
end $$;


-- значения enum, которые ни разу не сгенерировались
create function tst.missing_enums() returns text language plpgsql as $$
declare
    r record;
    v_m text;
    res text := '';
begin
    for r in select * from (values
            ('payment','payment_type','payment_type'), ('payment','status','transaction_status'),
            ('restaurant_payout','status','transaction_status'), ('product','status','product_status'),
            ('product','measure_unit','measure_unit'), ('restaurant','status','restaurant_status'),
            ('courier','status','courier_status'), ('order','status','order_status'),
            ('order','pay_status','pay_status')) v(t, col, typ) loop
        execute format($q$select string_agg(e::text, ',') from unnest(enum_range(null::shkuratetskiy_food.%I)) e
                          where not exists (select 1 from shkuratetskiy_food.%I x where x.%I = e)$q$,
                       r.typ, r.t, r.col) into v_m;
        if v_m is not null then
            res := res || format('%s.%s: нет %s; ', r.t, r.col, v_m);
        end if;
    end loop;
    return res;
end $$;


-- снимок строк для проверки «старые данные не трогаются»
create function tst.snap_take() returns void language plpgsql as $$
declare
    v_t text;
begin
    delete from tst.snap;

    for v_t in select tablename from pg_tables where schemaname = 'shkuratetskiy_food' loop
        execute format('insert into tst.snap select %L, md5(x::text) from shkuratetskiy_food.%I x', v_t, v_t);
    end loop;
end $$;


create function tst.snap_diff() returns text language plpgsql as $$
declare
    v_t text;
    v_c bigint;
    res text := '';
begin
    for v_t in select tablename from pg_tables where schemaname = 'shkuratetskiy_food' loop
        execute format($q$select count(*) from tst.snap s where s.tbl = %L
                          and s.h not in (select md5(x::text) from shkuratetskiy_food.%I x)$q$, v_t, v_t) into v_c;
        if v_c > 0 then
            res := res || format('%s: изменено/удалено %s; ', v_t, v_c);
        end if;
    end loop;
    return res;
end $$;


-- Проверки результата генерации. p_ns — размеры всех вызовов после чистки
create function tst.verify(p_ns int[], p_label text) returns void language plpgsql as $$
declare
    s  bigint := (select sum(x) from unnest(p_ns) x);
    sf bigint := (select sum(x / 5) from unnest(p_ns) x);
    k  int    := cardinality(p_ns);
    lo text   := (localtimestamp - interval '6 months')::text;
    hi text   := localtimestamp::text;
    r  record;
begin
    for r in select * from (values ('product_category', s), ('courier', s), ('restaurant', s), ('client', s),
             ('address', 5 * s), ('client_address', 4 * s), ('product', 5 * s), ('order', 5 * s),
             ('payment', 5 * s), ('review', 5 * s), ('courier_pay', 6 * s)) v(t, e) loop
        perform tst.expect_true(format('%s: объём %s = %s', p_label, r.t, r.e),
                                format('select (select count(*) from %I) = %s', r.t, r.e));
    end loop;

    perform tst.expect_true(p_label || ': order_structure в [5s; 25s]',
        format('select count(*) between 5 * %1$s and 25 * %1$s from order_structure', s));

    perform tst.expect_true(p_label || ': доставленных >= 2s',
        format($q$select count(*) >= 2 * %s from "order" where status = 'доставлен'$q$, s));

    perform tst.expect_true(p_label || ': выплата ровно у каждого доставленного заказа и ни у одного другого',
        $q$select not exists (select 1 from "order" o
           where (select count(*) from restaurant_payout p where p.order_id = o.order_id) <> (o.status = 'доставлен')::int)$q$);

    perform tst.expect_true(p_label || ': платёж ровно один на заказ',
        $q$select not exists (select 1 from "order" o where (select count(*) from payment p where p.order_id = o.order_id) <> 1)$q$);

    perform tst.expect_true(p_label || ': есть отзывы всех трёх подтипов',
        'select (select count(*) from product_review) > 0 and (select count(*) from restaurant_review) > 0 and (select count(*) from order_review) > 0');


    -- курьеры
    perform tst.expect_true(p_label || ': уволенных = Σ(n/5)',
        format($q$select count(*) = %s from courier where status = 'уволен'$q$, sf));

    perform tst.expect_true(p_label || ': активных = Σ(n − n/5), минимум по одному на вызов',
        format($q$select count(*) = %s and count(*) >= %s from courier where status <> 'уволен'$q$, s - sf, k));

    perform tst.expect_true(p_label || ': курьер у заказа ↔ статус заказа',
        $q$select not exists (select 1 from "order"
           where (status in ('создан','отменён') and courier_id is not null)
              or (status in ('готовится','в_доставке','доставлен') and courier_id is null))$q$);

    perform tst.expect_true(p_label || ': заказы в работе не у уволенного курьера',
        $q$select not exists (select 1 from "order" o join courier c using (courier_id)
           where o.status in ('готовится','в_доставке') and c.status = 'уволен')$q$);

    perform tst.expect_true(p_label || ': доставка в пределах найма/увольнения курьера',
        $q$select not exists (select 1 from "order" o join courier c using (courier_id)
           where o.status = 'доставлен'
             and (o.order_timestamp::date < c.hire_date
                  or o.delivery_timestamp::date > coalesce(c.dismissal_date, 'infinity'::date)))$q$);

    perform tst.expect_true(p_label || ': hire_date/dismissal_date в [−6 мес; сегодня]',
        format('select not exists (select 1 from courier where hire_date not between %1$L::date and current_date or dismissal_date not between %1$L::date and current_date)', lo));


    -- связи
    perform tst.expect_true(p_label || ': у каждого клиента ровно 4 адреса',
        'select not exists (select 1 from client c where (select count(*) from client_address a where a.client_id = c.client_id) <> 4)');

    perform tst.expect_true(p_label || ': каждый адрес занят либо рестораном, либо клиентом',
        $q$select not exists (select 1 from address a
           where exists (select 1 from restaurant r where r.address_id = a.address_id)
               = exists (select 1 from client_address ca where ca.address_id = a.address_id))$q$);

    perform tst.expect_true(p_label || ': у каждого ресторана есть доступное блюдо',
        $q$select not exists (select 1 from restaurant r
           where not exists (select 1 from product p where p.restaurant_id = r.restaurant_id and p.status = 'доступно'))$q$);

    perform tst.expect_true(p_label || ': у заказа от 1 до 5 позиций',
        'select not exists (select 1 from "order" o where (select count(*) from order_structure x where x.order_id = o.order_id) not between 1 and 5)');


    -- статусы платежей
    perform tst.expect_true(p_label || ': статус платежа ↔ статус заказа',
        $q$select not exists (select 1 from payment p join "order" o using (order_id)
           where p.status <> (case o.status when 'создан' then 'в_обработке' when 'отменён' then 'ошибка' else 'успех' end)::transaction_status)$q$);


    -- время
    perform tst.expect_true(p_label || ': order/delivery в пределах 6 месяцев',
        format('select not exists (select 1 from "order" where order_timestamp not between %1$L and %2$L or delivery_timestamp not between %1$L and %2$L)', lo, hi));

    perform tst.expect_true(p_label || ': payment не раньше заказа и в пределах 6 месяцев',
        format('select not exists (select 1 from payment p join "order" o using (order_id) where p.transaction_timestamp not between %1$L and %2$L or p.transaction_timestamp < o.order_timestamp)', lo, hi));

    perform tst.expect_true(p_label || ': выплата не раньше доставки и в пределах 6 месяцев',
        format('select not exists (select 1 from restaurant_payout p join "order" o using (order_id) where p.payout_timestamp not between %1$L and %2$L or p.payout_timestamp < o.delivery_timestamp)', lo, hi));

    perform tst.expect_true(p_label || ': отзыв не раньше доставки и в пределах 6 месяцев',
        format('select not exists (select 1 from review r join "order" o using (order_id) where r.review_timestamp not between %1$L and %2$L or r.review_timestamp < o.delivery_timestamp)', lo, hi));


    -- рейтинги
    perform tst.expect_true(p_label || ': product.rating = avg(отзывов) или NULL',
        $q$select not exists (select 1 from product p where p.rating is distinct from
           (select round(avg(r.rating), 2) from product_review pr join review r using (review_id) where pr.product_id = p.product_id))$q$);

    perform tst.expect_true(p_label || ': restaurant.rating = avg(отзывов) или NULL',
        $q$select not exists (select 1 from restaurant s where s.rating is distinct from
           (select round(avg(r.rating), 2) from restaurant_review rr join review r using (review_id) where rr.restaurant_id = s.restaurant_id))$q$);


    -- courier_pay (BR-10.2)
    perform tst.expect_true(p_label || ': courier_pay — запись на каждого курьера за каждый из 6 месяцев',
        $q$select not exists (select 1 from courier c cross join generate_series(0, 5) g
           left join courier_pay p on p.courier_id = c.courier_id
                and make_date(p.year, p.month, 1) = (date_trunc('month', localtimestamp) - g * interval '1 month')::date
           where p.courier_pay_id is null)$q$);

    perform tst.expect_true(p_label || ': coefficient_used и amount совпадают с независимым пересчётом',
        $q$with m as (select (date_trunc('month', localtimestamp) - g * interval '1 month')::date as d from generate_series(0, 5) g),
           x as (select c.courier_id, m.d, count(o.order_id) as cnt, coalesce(sum(o.commission), 0) as com
                 from courier c cross join m
                 left join "order" o on o.courier_id = c.courier_id and o.status = 'доставлен'
                      and o.delivery_timestamp >= m.d and o.delivery_timestamp < m.d + interval '1 month'
                 group by c.courier_id, m.d),
           e as (select courier_id, d, com,
                        coalesce(lag(tst.coef(cnt)) over (partition by courier_id order by d), 0.1) as cu
                 from x)
           select not exists (select 1 from e
              left join courier_pay p on p.courier_id = e.courier_id and make_date(p.year, p.month, 1) = e.d
              where p.courier_pay_id is null or p.coefficient_used <> e.cu or p.amount <> round(e.cu * e.com, 2))$q$);

    perform tst.expect_true(p_label || ': courier.coefficient — на следующий месяц, не больше 0.5',
        $q$select not exists (select 1 from courier c
           where c.coefficient > 0.5
              or c.coefficient <> tst.coef((select count(*) from "order" o
                   where o.courier_id = c.courier_id and o.status = 'доставлен'
                     and o.delivery_timestamp >= date_trunc('month', localtimestamp))))$q$);


    -- общие проверки по всем колонкам
    perform tst.expect_empty(p_label || ': строки от 1 до N символов', 'select tst.bad_strings()');
    perform tst.expect_empty(p_label || ': NULL только в разрешённых колонках', 'select tst.bad_nulls()');


    -- статистика (только при достаточном n)
    if s >= 10 then
        for r in select * from (values ('address','apartment_office'), ('product','photo_url'), ('review','photo_url')) v(t, c) loop
            perform tst.expect_true(format('%s: %s.%s — встречаются и NULL, и значения', p_label, r.t, r.c),
                format('select exists (select 1 from %1$I where %2$I is null) and exists (select 1 from %1$I where %2$I is not null)', r.t, r.c));
        end loop;
    end if;

    if s >= 60 then
        perform tst.expect_empty(p_label || ': все значения enum встречаются', 'select tst.missing_enums()');
    end if;

    if s >= 60 and k = 1 then
        perform tst.expect_true(p_label || ': перекос — топ-1 курьер >= 20% доставок',
            $q$select coalesce(max(z.x), 0) * 5 >= coalesce(sum(z.x), 0)
               from (select count(*) x from "order" where status = 'доставлен' group by courier_id) z$q$);

        perform tst.expect_true(p_label || ': перекос — топ-3 курьера >= 45% доставок',
            $q$select coalesce(sum(z.x) filter (where z.rn <= 3), 0) * 100 >= 45 * coalesce(sum(z.x), 0)
               from (select count(*) x, row_number() over (order by count(*) desc) rn
                     from "order" where status = 'доставлен' group by courier_id) z$q$);
    end if;
end $$;


-- чистка + вызовы подряд без очистки + verify
create function tst.run(p_ns int[]) returns void language plpgsql as $$
declare
    v_n     int;
    v_label text := 'ns={' || array_to_string(p_ns, ',') || '}';
begin
    perform tst.wipe();

    begin
        foreach v_n in array p_ns loop
            call shkuratetskiy_food.insert_test_data(v_n);
        end loop;

        set constraints all immediate;
        set constraints all deferred;

    exception when others then
        insert into tst.result(test, ok, details)
        values (v_label || ': вызов без исключений', false, sqlstate || ': ' || sqlerrm);
        return;
    end;

    insert into tst.result(test, ok) values (v_label || ': вызов без исключений', true);

    begin
        perform tst.verify(p_ns, v_label);
    exception when others then
        insert into tst.result(test, ok, details)
        values (v_label || ': verify без исключений', false, sqlstate || ': ' || sqlerrm);
    end;
end $$;


-- 1. Статика: требования AC к исходнику процедуры
do $t$
declare
    q text := $f$select %s from pg_proc where oid = 'shkuratetskiy_food.insert_test_data(integer)'::regprocedure$f$;
begin
    perform tst.expect_true('исходник: нет gen_random_uuid',
        format(q, $x$prosrc !~* 'gen_random_uuid'$x$));

    perform tst.expect_true('исходник: каждый uuid_generate_v4 вызван с префиксом exts.',
        format(q, $x$regexp_replace(prosrc, 'exts[.]uuid_generate_v4', '', 'gi') !~* 'uuid_generate_v4'$x$));

    perform tst.expect_true('исходник: client.password через md5(random()::text)',
        format(q, $x$prosrc ~ 'md5\(random\(\)::text\)'$x$));

    perform tst.expect_true('исходник: enum через enum_range',
        format(q, $x$prosrc ~ 'enum_range'$x$));

    perform tst.expect_true('исходник: нет COMMIT/ROLLBACK внутри',
        format(q, $x$prosrc !~* '\m(commit|rollback)\M'$x$));
end $t$;


-- 2. Матрица размеров: границы n/5, несколько вызовов подряд без очистки
do $t$
declare
    v_x text;
begin
    foreach v_x in array array['1', '4', '5', '10', '37', '60', '10,10,10', '1,10,5'] loop
        perform tst.run(string_to_array(v_x, ',')::int[]);
    end loop;
end $t$;


-- 3. Некорректные аргументы
do $t$
begin
    perform tst.wipe();

    perform tst.expect_error('args: value = 0', 'call shkuratetskiy_food.insert_test_data(0)', 'P0001', '>= 1');
    perform tst.expect_error('args: value < 0', 'call shkuratetskiy_food.insert_test_data(-5)', 'P0001', '>= 1');

    perform tst.expect_true('args: после ошибок таблицы пусты', 'select tst.total() = 0');
end $t$;


-- 4. Атомарность: процедура сама не коммитит
do $t$
begin
    perform tst.wipe();

    begin
        call shkuratetskiy_food.insert_test_data(10);
        raise exception 'откат';
    exception when raise_exception then
        null;
    end;

    perform tst.expect_true('atomicity: откат внешней транзакции убирает все данные', 'select tst.total() = 0');
end $t$;


-- 5. Независимость от search_path вызывающего
do $t$
begin
    perform tst.wipe();

    begin
        execute 'set local search_path to public';
        call shkuratetskiy_food.insert_test_data(5);

        set constraints all immediate;
        set constraints all deferred;
    exception when others then
        insert into tst.result(test, ok, details)
        values ('search_path: вызов при чужом search_path', false, sqlstate || ': ' || sqlerrm);
    end;

    execute 'set local search_path to shkuratetskiy_food, exts, tst';

    perform tst.expect_true('search_path: данные созданы при чужом search_path',
        'select (select count(*) from client) = 5 and (select count(*) from "order") = 25');
end $t$;


-- 6. Повторные вызовы не трогают строки предыдущих вызовов
do $t$
begin
    perform tst.wipe();

    call shkuratetskiy_food.insert_test_data(10);
    perform tst.snap_take();

    call shkuratetskiy_food.insert_test_data(7);

    set constraints all immediate;
    set constraints all deferred;

    perform tst.expect_empty('повторный вызов: строки первого вызова не изменены', 'select tst.snap_diff()');
exception when others then
    insert into tst.result(test, ok, details)
    values ('повторный вызов: строки первого вызова не изменены', false, sqlstate || ': ' || sqlerrm);
end $t$;


-- 7. Коллизии логинов/телефонов/адресов: одинаковый seed даёт одинаковые «случайные» значения,
--    второй вызов обязан пройти через циклы повторов (on conflict do nothing)
do $t$
begin
    perform tst.wipe();

    perform setseed(0.123);
    call shkuratetskiy_food.insert_test_data(10);

    perform setseed(0.123);
    call shkuratetskiy_food.insert_test_data(10);

    set constraints all immediate;
    set constraints all deferred;

    perform tst.verify(array[10, 10], 'collisions');
exception when others then
    insert into tst.result(test, ok, details)
    values ('collisions: повторный вызов с тем же seed', false, sqlstate || ': ' || sqlerrm);
end $t$;


-- 8. NULL в аргументе (последним: ожидаемо виснет в цикле по адресам)
set local statement_timeout = '5s';

do $t$
declare
    v text;
begin
    perform tst.wipe();

    begin
        call shkuratetskiy_food.insert_test_data(null);
        v := 'исключения нет';
    exception
        when query_canceled then
            v := 'ЗАВИСЛА: сработал statement_timeout';
        when others then
            v := 'raised';
    end;

    insert into tst.result(test, ok, details)
    values ('args: value = NULL → исключение', v = 'raised', nullif(v, 'raised'));
end $t$;

set local statement_timeout = 0;


-- 9. Тяжёлый прогон. Проявляются коэффициенты > 0.1
set local statement_timeout = '3600s';
do $t$
begin
    perform tst.run(array[3000]);
    perform tst.expect_true('heavy n=3000: встречаются коэффициенты > 0.1',
        'select exists (select 1 from courier_pay where coefficient_used > 0.1)');
end $t$;
set local statement_timeout = 0;


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