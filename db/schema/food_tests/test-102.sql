-- Требует установки FOOD-101.sql и FOOD-102.sql в тестовой базе
-- TRUNCATE удерживает блокировки до отката

begin;
set local search_path to shkuratetskiy_food, exts, pg_temp;

create temp table result (
    id int generated always as identity primary key,
    test text not null,
    ok boolean not null,
    details text
) on commit drop;

create temp table snap (tbl text not null, row_data jsonb not null) on commit drop;

create function pg_temp.expect_true(p_test text, p_query text)
returns void language plpgsql as $$
declare
    b boolean;
begin
    execute p_query into strict b;
    insert into pg_temp.result(test, ok, details)
    values (p_test, b is true, case when b is not true then 'условие ложно/NULL: ' || p_query end);
exception when others then
    insert into pg_temp.result(test, ok, details)
    values (p_test, false, sqlstate || ': ' || sqlerrm);
end $$;

create function pg_temp.expect_error(p_test text, p_n int, p_msg text)
returns void language plpgsql as $$
declare
    st text;
    msg text;
begin
    begin
        call shkuratetskiy_food.insert_test_data(p_n);
        -- Служебное исключение откатывает неожиданный успешный вызов
        raise exception using errcode = 'ZX001', message = 'исключения не было';
    exception when query_canceled or others then
        get stacked diagnostics st = returned_sqlstate, msg = message_text;
    end;
    insert into pg_temp.result(test, ok, details)
    values (p_test, st = 'P0001' and position(p_msg in msg) > 0,
        case when st <> 'P0001' or position(p_msg in msg) = 0
             then st || ': ' || msg end);
end $$;

create function pg_temp.wipe() returns void language sql as $$
    truncate table shkuratetskiy_food.review, shkuratetskiy_food.payment,
        shkuratetskiy_food.order_structure, shkuratetskiy_food."order",
        shkuratetskiy_food.courier_pay, shkuratetskiy_food.product,
        shkuratetskiy_food.restaurant, shkuratetskiy_food.client_address,
        shkuratetskiy_food.client, shkuratetskiy_food.courier,
        shkuratetskiy_food.address, shkuratetskiy_food.product_category;
$$;

create function pg_temp.total() returns bigint language sql as $$
    select (select count(*) from client) + (select count(*) from address)
         + (select count(*) from client_address) + (select count(*) from courier)
         + (select count(*) from courier_pay) + (select count(*) from restaurant)
         + (select count(*) from product_category) + (select count(*) from product)
         + (select count(*) from "order") + (select count(*) from order_structure)
         + (select count(*) from payment) + (select count(*) from review);
$$;

create function pg_temp.tables() returns text[] language sql immutable as $$
    select array['client','address','client_address','courier','courier_pay',
                 'restaurant','product_category','product','order',
                 'order_structure','payment','review'];
$$;

create function pg_temp.snap_take() returns void language plpgsql as $$
declare
    t text;
begin
    delete from pg_temp.snap;
    foreach t in array pg_temp.tables() loop
        execute format('insert into pg_temp.snap select %L, to_jsonb(x) from shkuratetskiy_food.%I x', t, t);
    end loop;
end $$;

create function pg_temp.snap_unchanged(p_label text) returns void language plpgsql as $$
declare
    t text;
begin
    foreach t in array pg_temp.tables() loop
        perform pg_temp.expect_true(p_label || ': старые строки ' || t || ' сохранены',
            format($q$select not exists (
                select row_data from pg_temp.snap where tbl = %L
                except all
                select to_jsonb(x) from shkuratetskiy_food.%I x)$q$, t, t));
    end loop;
end $$;

create function pg_temp.coef(p_cnt bigint) returns numeric language sql immutable as $$
    select case when p_cnt > 500 then 0.5
                when p_cnt > 250 then 0.3
                when p_cnt > 150 then 0.2
                else 0.1 end;
$$;

create function pg_temp.verify(p_ns int[], p_label text) returns void language plpgsql as $$
declare
    s bigint := (select sum(x) from unnest(p_ns) x);
    sf bigint := (select sum(x / 5) from unnest(p_ns) x);
    n int := p_ns[cardinality(p_ns)];
    w timestamp := date_trunc('month', localtimestamp) - interval '5 months';
    r record;
begin
    -- Проверяет общее число строк после очередного вызова
    for r in select * from (values
        ('client', s), ('courier', s), ('product_category', s), ('restaurant', s),
        ('address', 5*s), ('client_address', 4*s), ('product', 5*s),
        ('order', 5*s), ('payment', 5*s), ('review', 5*s), ('courier_pay', 6*s)
    ) v(t, expected) loop
        perform pg_temp.expect_true(format('%s: %s — %s строк', p_label, r.t, r.expected),
            format('select count(*) = %s from %I', r.expected, r.t));
    end loop;

    -- Проверяет адреса, меню и состав заказов
    perform pg_temp.expect_true(p_label || ': ровно 4 адреса у каждого клиента',
        $q$select not exists (select 1 from client c where
            (select count(*) from client_address a where a.client_id = c.client_id) <> 4)$q$);

    perform pg_temp.expect_true(p_label || ': каждый адрес используется ровно один раз',
        $q$select not exists (select 1 from address a where
            (select count(*) from restaurant r where r.address_id = a.address_id) +
            (select count(*) from client_address ca where ca.address_id = a.address_id) <> 1)$q$);

    perform pg_temp.expect_true(p_label || ': ровно 5 блюд и минимум одно доступное в каждом ресторане',
        $q$select not exists (select 1 from restaurant r left join product p using (restaurant_id)
            group by r.restaurant_id having count(p.product_id) <> 5
                or count(*) filter (where p.status = 'доступно') = 0)$q$);

    perform pg_temp.expect_true(p_label || ': от 1 до 5 позиций у каждого заказа',
        $q$select not exists (select 1 from "order" o left join order_structure s using (order_id)
            group by o.order_id having count(s.product_id) not between 1 and 5)$q$);

    perform pg_temp.expect_true(p_label || ': в заказах только доступные блюда по цене меню',
        $q$select not exists (select 1 from order_structure s join product p using (product_id)
            where p.status <> 'доступно' or s.price is distinct from p.price)$q$);

    -- Генератор соблюдает минимум суммы в том числе для созданных и отменённых заказов
    perform pg_temp.expect_true(p_label || ': генератор обеспечивает сумму до комиссии не менее 1000',
        $q$select not exists (select 1 from "order" where order_amount < 1000 or total_amount < 1000)$q$);

    -- Проверяет статусы и назначения курьеров
    perform pg_temp.expect_true(p_label || ': минимум 2n доставленных заказов в новой партии',
        format($q$select count(*) >= %s from "order" o where o.status = 'доставлен'
            and not exists (select 1 from pg_temp.snap s where s.tbl = 'order'
                and s.row_data->>'order_id' = o.order_id::text)$q$, 2*n));

    perform pg_temp.expect_true(p_label || ': уволенных = сумма floor(n/5)',
        format($q$select count(*) = %s from courier where status = 'уволен'$q$, sf));

    perform pg_temp.expect_true(p_label || ': активных = сумма (n - floor(n/5))',
        format($q$select count(*) = %s and count(*) >= %s from courier where status <> 'уволен'$q$,
            s-sf, cardinality(p_ns)));

    perform pg_temp.expect_true(p_label || ': курьер назначен только готовящимся, доставляемым и доставленным',
        $q$select not exists (select 1 from "order" where
            (status in ('готовится','в_доставке','доставлен')) <> (courier_id is not null))$q$);

    perform pg_temp.expect_true(p_label || ': заказы в работе не у уволенных курьеров',
        $q$select not exists (select 1 from "order" o join courier c using (courier_id)
            where o.status in ('готовится','в_доставке') and c.status = 'уволен')$q$);

    perform pg_temp.expect_true(p_label || ': все курьеры наняты в начале окна генерации',
        format('select not exists (select 1 from courier where hire_date <> %L::date)', w::date));

    perform pg_temp.expect_true(p_label || ': увольнение в день последней доставки либо найма',
        $q$select not exists (select 1 from courier c where c.status = 'уволен'
            and c.dismissal_date is distinct from coalesce((select max(o.delivery_timestamp)::date
                from "order" o where o.courier_id = c.courier_id and o.status = 'доставлен'), c.hire_date))$q$);

    perform pg_temp.expect_true(p_label || ': доставка приходится на период работы курьера',
        $q$select not exists (select 1 from "order" o join courier c using (courier_id)
            where o.status = 'доставлен' and (o.order_timestamp::date < c.hire_date
                or o.delivery_timestamp::date > coalesce(c.dismissal_date, 'infinity'::date)))$q$);

    perform pg_temp.expect_true(p_label || ': ровно одна попытка оплаты и она успешна',
        $q$select not exists (select 1 from "order" o left join payment p using (order_id)
            group by o.order_id having count(p.payment_id) <> 1
                or count(*) filter (where p.status = 'успех') <> 1)$q$);

    perform pg_temp.expect_true(p_label || ': заказ оплачен на полную сумму',
        $q$select not exists (select 1 from payment p join "order" o using (order_id)
            where o.pay_status <> 'оплачен' or p.amount <> o.total_amount)$q$);

    -- Проверяет даты за шесть календарных месяцев
    perform pg_temp.expect_true(p_label || ': заказы в календарном окне, резерв 3 часа',
        format($q$select not exists (select 1 from "order" where order_timestamp
            not between %L::timestamp and localtimestamp - interval '3 hours')$q$, w));

    perform pg_temp.expect_true(p_label || ': доставка через 30–119 минут после заказа',
        $q$select not exists (select 1 from "order" where status = 'доставлен'
            and (delivery_timestamp - order_timestamp not between interval '30 minutes' and interval '119 minutes'
                or delivery_timestamp > localtimestamp))$q$);

    perform pg_temp.expect_true(p_label || ': попытка оплаты в течение 10 минут после заказа',
        $q$select not exists (select 1 from payment p join "order" o using (order_id)
            where p.transaction_timestamp not between o.order_timestamp and o.order_timestamp + interval '10 minutes'
                or p.transaction_timestamp > localtimestamp)$q$);

    if n >= 10 then
        perform pg_temp.expect_true(p_label || ': заказы есть в каждом из пяти полных месяцев окна',
            $q$select not exists (select 1 from generate_series(1,5) g where not exists (
                select 1 from "order" o where date_trunc('month', o.order_timestamp) =
                    date_trunc('month', localtimestamp) - g * interval '1 month'
                    and not exists (select 1 from pg_temp.snap old where old.tbl = 'order'
                        and old.row_data->>'order_id' = o.order_id::text)))$q$);
    end if;

    -- Проверяет охват отзывами новой партии
    perform pg_temp.expect_true(p_label || ': в новой партии отзывы всех 3 типов',
        $q$select count(distinct r.entity_type) = 3 from review r where not exists (
            select 1 from pg_temp.snap s where s.tbl = 'review'
                and s.row_data->>'review_id' = r.review_id::text)$q$);

    perform pg_temp.expect_true(p_label || ': отзывы только после доставки, в течение часа',
        $q$select not exists (select 1 from review r join "order" o using (order_id)
            where o.status <> 'доставлен' or o.delivery_timestamp is null
               or r.review_timestamp not between o.delivery_timestamp and o.delivery_timestamp + interval '1 hour'
               or r.review_timestamp > localtimestamp)$q$);

    -- Сверяет выплаты с заказами по месяцу доставки
    perform pg_temp.expect_true(p_label || ': выплата каждому курьеру за каждый из 6 месяцев',
        $q$select not exists (select 1 from courier c cross join generate_series(0,5) g
            left join courier_pay p on p.courier_id = c.courier_id
                and make_date(p.year,p.month,1) = (date_trunc('month',localtimestamp)-g*interval '1 month')::date
            where p.courier_pay_id is null)$q$);

    perform pg_temp.expect_true(p_label || ': коэффициент прошлого месяца и сумма выплаты корректны',
        $q$with monthly as (
            select courier_id, date_trunc('month',delivery_timestamp)::date as m,
                   count(*) as cnt, sum(commission) as com
            from "order" where status = 'доставлен' group by 1,2
        ), expected as (
            select p.courier_id, p.year, p.month, p.coefficient_used, p.amount,
                   pg_temp.coef(coalesce(prev.cnt,0)) as coef,
                   coalesce(curr.com,0) as com
            from courier_pay p
            left join monthly curr on curr.courier_id = p.courier_id
                and curr.m = make_date(p.year,p.month,1)
            left join monthly prev on prev.courier_id = p.courier_id
                and prev.m = (make_date(p.year,p.month,1)-interval '1 month')::date
        ) select not exists (select 1 from expected where coefficient_used is distinct from coef
            or amount is distinct from round(coef * com,2))$q$);

    perform pg_temp.expect_true(p_label || ': текущий коэффициент рассчитан по доставкам текущего месяца',
        $q$select not exists (select 1 from courier c left join (
            select courier_id,count(*) cnt from "order" where status = 'доставлен'
                and delivery_timestamp >= date_trunc('month',localtimestamp)
                and delivery_timestamp < date_trunc('month',localtimestamp)+interval '1 month'
            group by courier_id) o using (courier_id)
            where c.coefficient is distinct from pg_temp.coef(coalesce(o.cnt,0)))$q$);

    -- Проверяет отсутствие пустых строк по BR-11.3
    for r in select table_name t, column_name c from information_schema.columns
        where table_schema = 'shkuratetskiy_food'
          and table_name = any(pg_temp.tables())
          and data_type in ('character varying','character','text') loop
        perform pg_temp.expect_true(format('%s: %s.%s — нет пустых строк',p_label,r.t,r.c),
            format('select not exists (select 1 from %I where btrim(%I) = '''')',r.t,r.c));
    end loop;

    perform pg_temp.expect_true(p_label || ': свободный текст состоит из русских букв',
        $q$select not exists (
            select 1 from (
                select unnest(array[street, house_number, apartment_office]) as value from address
                union all select unnest(array[last_name, first_name, middle_name]) from courier
                union all select unnest(array[restaurant_name, description]) from restaurant
                union all select product_category_name from product_category
                union all select unnest(array[product_name, description]) from product
                union all select description from "order"
                union all select description from review
                union all select transaction_id from payment
            ) generated_text
            where value !~ '^[абвгдеёжзийклмнопрстуфхцчшщъыьэюя]+$')$q$);

    -- Проверяет наличие NULL и заполненных значений в опциональных полях
    for r in select * from (values ('address','apartment_office'),
        ('product','photo_url'), ('review','photo_url')) v(t,c) loop
        perform pg_temp.expect_true(format('%s: %s.%s — есть NULL и непустые значения',p_label,r.t,r.c),
            format('select exists (select 1 from %1$I where %2$I is null) and exists (select 1 from %1$I where %2$I is not null)',r.t,r.c));
    end loop;

    -- Проверяет полный набор значений enum при n от 5
    if n >= 5 then
        for r in select * from (values
            ('payment','payment_type','payment_type'),
            ('product','status','product_status'), ('product','measure_unit','measure_unit'),
            ('restaurant','status','restaurant_status'), ('courier','status','courier_status'),
            ('order','status','order_status')
        ) v(t,c,typ) loop
            perform pg_temp.expect_true(format('%s: все значения %s.%s в новой партии',p_label,r.t,r.c),
                format($q$select not exists (select 1 from unnest(enum_range(null::shkuratetskiy_food.%I)) e
                    where not exists (select 1 from %I x where x.%I = e
                        and not exists (select 1 from pg_temp.snap old
                            where old.tbl = %L and old.row_data = to_jsonb(x))))$q$,r.typ,r.t,r.c,r.t));
        end loop;
    end if;

    -- Проверяет минимальные доли доставок у ведущих курьеров
    if n >= 60 and cardinality(p_ns) = 1 then
        perform pg_temp.expect_true(p_label || ': топ-1 курьер выполняет не менее 20% доставок',
            $q$select coalesce(max(cnt),0)*5 >= sum(cnt) from (
                select count(*) cnt from "order" where status = 'доставлен' group by courier_id) x$q$);
        perform pg_temp.expect_true(p_label || ': топ-3 курьера выполняют не менее 45% доставок',
            $q$select coalesce(sum(cnt) filter (where rn <= 3),0)*100 >= 45*sum(cnt) from (
                select count(*) cnt,row_number() over (order by count(*) desc) rn
                from "order" where status = 'доставлен' group by courier_id) x$q$);
    end if;
end $$;

-- Повторно запускает генерацию и проверяет сохранность прежних строк
create function pg_temp.run(p_ns int[], p_label text, p_same_seed boolean default false)
returns void language plpgsql as $$
declare
    n int;
    done int[] := '{}';
    label text;
begin
    perform pg_temp.wipe();
    foreach n in array p_ns loop
        label := p_label || ', вызов ' || (cardinality(done)+1) || ', n=' || n;
        perform pg_temp.snap_take();
        begin
            if p_same_seed then perform setseed(0.123); end if;
            call shkuratetskiy_food.insert_test_data(n);
        exception when others then
            insert into pg_temp.result(test,ok,details) values
                (label || ': вызов без исключений',false,sqlstate || ': ' || sqlerrm);
            return;
        end;
        insert into pg_temp.result(test,ok) values (label || ': вызов без исключений',true);
        if cardinality(done) > 0 then perform pg_temp.snap_unchanged(label); end if;
        done := array_append(done,n);
        perform pg_temp.verify(done,label);
    end loop;
end $$;

-- Проверяет обработку некорректных аргументов
select pg_temp.wipe();
set local statement_timeout = '5s';
do $$
begin
    perform pg_temp.expect_error('value = 0',0,'value должно быть >= 1');
    perform pg_temp.expect_error('value < 0',-1,'value должно быть >= 1');
    perform pg_temp.expect_error('value = NULL',null,'value должно быть >= 1');
    perform pg_temp.expect_true('после некорректных аргументов данных нет','select pg_temp.total() = 0');
end $$;
set local statement_timeout = 0;

-- Запускает положительные сценарии с июня 2026 года
do $$
begin
    if date_trunc('month',localtimestamp)-interval '5 months' < date '2026-01-01' then
        perform pg_temp.expect_error('календарное окно до 2026 года',1,
            'Схема courier_pay не допускает все 6 месяцев до 2026 года');
        perform pg_temp.expect_true('после ошибки календарного окна данных нет','select pg_temp.total() = 0');
        raise notice 'Положительные сценарии недоступны до июня 2026 года';
    else
        perform pg_temp.run(array[1],'минимальное значение');
        perform pg_temp.run(array[4],'граница до увольнения');
        perform pg_temp.run(array[5],'граница первого увольнения');
        perform pg_temp.run(array[10],'FOOD-102: обычный вызов');
        perform pg_temp.run(array[60],'распределение доставок');
        perform pg_temp.run(array[1,10,5],'повторные вызовы разных размеров');
        perform pg_temp.run(array_fill(10,array[11]),'FOOD-102: первый вызов и 10 повторов');
        -- Одинаковый seed повышает вероятность коллизий телефонов
        perform pg_temp.run(array[10,10],'повтор с одинаковым seed',true);
    end if;
end $$;

-- Проверяет фактические выплаты с повышенным коэффициентом
-- Пропускает сценарий при замене true на false
set local statement_timeout = '3600s';
do $$
begin
    if true and date_trunc('month',localtimestamp)-interval '5 months' >= date '2026-01-01' then
        perform pg_temp.run(array[3000],'повышенные коэффициенты');
        perform pg_temp.expect_true('повышенные коэффициенты реально использованы',
            'select exists (select 1 from courier_pay where coefficient_used > 0.1)');
    end if;
end $$;
set local statement_timeout = 0;

select count(*) filter (where ok) as passed,
       count(*) filter (where not ok) as failed,
       count(*) as total
from pg_temp.result;

select id,test,details from pg_temp.result where not ok order by id;
rollback;
