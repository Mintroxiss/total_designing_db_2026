begin;

set local search_path to shkuratetskiy_food, exts;

-- Тестируем только значения агрегированных рейтингов после DML на review.
-- Все тестовые данные и вспомогательные объекты откатываются в конце.
create temp table rating_test_result (
    id      int generated always as identity primary key,
    test    text not null,
    ok      boolean not null,
    details text
);

create function pg_temp.expect_rating(
    p_test text, p_type entity_type, p_id uuid, p_expected numeric
) returns void language plpgsql as $$
declare
    v_rating numeric;
    v_found  boolean;
begin
    case p_type
        when 'блюдо' then
            select rating into v_rating from product where product_id = p_id;
        when 'ресторан' then
            select rating into v_rating from restaurant where restaurant_id = p_id;
    end case;
    v_found := found;

    insert into pg_temp.rating_test_result(test, ok, details)
    values (p_test,
            v_found and v_rating is not distinct from p_expected,
            case
                when not v_found then 'сущность не найдена'
                when v_rating is distinct from p_expected then
                    format('ожидалось %s, получено %s',
                           coalesce(p_expected::text, 'NULL'),
                           coalesce(v_rating::text, 'NULL'))
            end);
end;
$$;

-- Минимальные валидные данные для существующих ограничений схемы.
create function pg_temp.mk_rest() returns uuid language plpgsql as $$
declare
    a uuid;
    r uuid := uuid_generate_v4();
begin
    insert into address(street, house_number)
    values ('Тест рейтинга ' || r, '1') returning address_id into a;

    insert into restaurant(restaurant_id, restaurant_name, address_id,
                           description, work_start, work_end, inn, ogrn,
                           bank_account, status)
    values (r, 'Тестовый ресторан', a, 'описание', '09:00', '22:00',
            '7701234567', '1027700132195', '40702810900000000001', 'активен');
    return r;
end;
$$;

create function pg_temp.mk_product(p_rest uuid, p_id uuid default uuid_generate_v4())
returns uuid language plpgsql as $$
declare
    c uuid;
begin
    insert into product_category(product_category_name)
    values ('Тестовая категория') returning product_category_id into c;

    insert into product(product_id, product_name, product_category_id, price,
                        restaurant_id, status, description, measure_unit)
    values (p_id, 'Тестовое блюдо', c, 1000, p_rest, 'доступно', 'описание', 'шт');
    return p_id;
end;
$$;

create function pg_temp.mk_client_address() returns uuid language plpgsql as $$
declare
    c  uuid;
    a  uuid;
    ca uuid;
begin
    -- Не предполагаем, что рабочая схема пуста.
    loop
        insert into client(login, password, phone_number)
        values ('test_' || replace(uuid_generate_v4()::text, '-', ''),
                md5('rating test'),
                '+79' || lpad(floor(random() * 1000000000)::bigint::text, 9, '0'))
        on conflict do nothing
        returning client_id into c;
        exit when c is not null;
    end loop;

    insert into address(street, house_number)
    values ('Тестовый клиент ' || c, '1') returning address_id into a;

    insert into client_address(client_id, address_id)
    values (c, a) returning client_address_id into ca;
    return ca;
end;
$$;

create function pg_temp.mk_order(p_address uuid, p_rest uuid, p_products uuid[])
returns uuid language plpgsql as $$
declare
    o uuid;
begin
    insert into "order"(client_address_id, restaurant_id, status)
    values (p_address, p_rest, 'создан') returning order_id into o;

    insert into order_structure(order_id, product_id, quantity, price)
    select o, product_id, 1, price
    from product where product_id = any(p_products);
    return o;
end;
$$;

create function pg_temp.mk_review(p_order uuid, p_type entity_type,
                                  p_entity uuid, p_rating numeric)
returns uuid language plpgsql as $$
declare
    rv uuid;
begin
    insert into review(order_id, entity_type, entity_id, description, rating)
    values (p_order, p_type, p_entity, 'Тестовый отзыв', p_rating)
    returning review_id into rv;
    return rv;
end;
$$;


-- 1. INSERT, UPDATE, DELETE: одинаковая логика для блюда и ресторана.
-- Проверяем среднее, округление вверх/вниз, дробную оценку и NULL.
do $$
declare
    k entity_type;
    ca uuid; r uuid; p uuid; target uuid;
    rv1 uuid; rv2 uuid; rv3 uuid;
begin
    foreach k in array array['блюдо', 'ресторан']::entity_type[] loop
        begin
            ca := pg_temp.mk_client_address();
            r := pg_temp.mk_rest();
            p := pg_temp.mk_product(r);
            target := case k when 'блюдо' then p else r end;

            rv1 := pg_temp.mk_review(pg_temp.mk_order(ca, r, array[p]), k, target, 3);
            perform pg_temp.expect_rating(k || ': первый отзыв', k, target, 3.00);

            rv2 := pg_temp.mk_review(pg_temp.mk_order(ca, r, array[p]), k, target, 4);
            perform pg_temp.expect_rating(k || ': отзывы 3,4', k, target, 3.50);

            rv3 := pg_temp.mk_review(pg_temp.mk_order(ca, r, array[p]), k, target, 5);
            perform pg_temp.expect_rating(k || ': отзывы 3,4,5', k, target, 4.00);

            update review set rating = 5 where review_id = rv1;
            perform pg_temp.expect_rating(k || ': изменение 3 -> 5, округление вверх', k, target, 4.67);

            update review set rating = 1.3 where review_id = rv3;
            perform pg_temp.expect_rating(k || ': изменение 5 -> 1.3, округление вниз', k, target, 3.43);

            delete from review where review_id = rv1;
            perform pg_temp.expect_rating(k || ': после удаления 5 остались 4,1.3', k, target, 2.65);

            delete from review where review_id = rv3;
            perform pg_temp.expect_rating(k || ': остался один отзыв', k, target, 4.00);

            delete from review where review_id = rv2;
            perform pg_temp.expect_rating(k || ': удалён последний отзыв', k, target, null);
        exception when others then
            insert into pg_temp.rating_test_result(test, ok, details)
            values (k || ': INSERT/UPDATE/DELETE — ошибка сценария', false, sqlstate || ': ' || sqlerrm);
        end;
    end loop;
end;
$$;


-- 2. UPDATE entity_id: перенос отзыва между сущностями одного типа.
-- Для ресторана одновременно меняем order_id, чтобы отзыв оставался валидным.
do $$
declare
    k entity_type;
    ca uuid; r1 uuid; r2 uuid; p1 uuid; p2 uuid;
    a uuid; b uuid;
    o1 uuid; o2 uuid; dst1 uuid; dst2 uuid;
    rv1 uuid; rv2 uuid;
begin
    foreach k in array array['блюдо', 'ресторан']::entity_type[] loop
        begin
            ca := pg_temp.mk_client_address();
            r1 := pg_temp.mk_rest();
            p1 := pg_temp.mk_product(r1);

            if k = 'блюдо' then
                r2 := r1;
                p2 := pg_temp.mk_product(r1);
                a := p1;
                b := p2;
                o1 := pg_temp.mk_order(ca, r1, array[p1,p2]);
                o2 := pg_temp.mk_order(ca, r1, array[p1,p2]);
                dst1 := o1;
                dst2 := o2;
            else
                r2 := pg_temp.mk_rest();
                p2 := pg_temp.mk_product(r2);
                a := r1;
                b := r2;
                o1 := pg_temp.mk_order(ca, r1, array[p1]);
                o2 := pg_temp.mk_order(ca, r1, array[p1]);
                dst1 := pg_temp.mk_order(ca, r2, array[p2]);
                dst2 := pg_temp.mk_order(ca, r2, array[p2]);
            end if;

            perform pg_temp.mk_review(pg_temp.mk_order(ca, r2, array[p2]), k, b, 2);
            rv1 := pg_temp.mk_review(o1, k, a, 5);
            rv2 := pg_temp.mk_review(o2, k, a, 3);
            perform pg_temp.expect_rating(k || ': A до переноса', k, a, 4.00);
            perform pg_temp.expect_rating(k || ': B не затронут отзывами A', k, b, 2.00);

            update review set entity_id = b, order_id = dst1 where review_id = rv1;
            perform pg_temp.expect_rating(k || ': A после переноса 5', k, a, 3.00);
            perform pg_temp.expect_rating(k || ': B после переноса 5', k, b, 3.50);

            update review set entity_id = b, order_id = dst2 where review_id = rv2;
            perform pg_temp.expect_rating(k || ': A после переноса последнего отзыва', k, a, null);
            perform pg_temp.expect_rating(k || ': B после переноса 3', k, b, 3.33);
        exception when others then
            insert into pg_temp.rating_test_result(test, ok, details)
            values (k || ': перенос отзыва — ошибка сценария', false, sqlstate || ': ' || sqlerrm);
        end;
    end loop;
end;
$$;


-- 3. UPDATE entity_type: все переходы между блюдом, рестораном и заказом.
-- Блюдо и ресторан намеренно имеют одинаковый UUID: тип тоже является
-- частью идентификатора объекта отзыва. Отзывы на заказ не входят в рейтинг.
do $$
declare
    ca uuid; r uuid; p uuid; o_base uuid; o uuid; rv uuid;
    step record;
begin
    ca := pg_temp.mk_client_address();
    r := pg_temp.mk_rest();
    p := pg_temp.mk_product(r, r);
    o_base := pg_temp.mk_order(ca, r, array[p]);
    o := pg_temp.mk_order(ca, r, array[p]);

    perform pg_temp.mk_review(o_base, 'блюдо', p, 2);
    perform pg_temp.mk_review(o_base, 'ресторан', r, 3);
    perform pg_temp.expect_rating('разные типы с одним UUID: блюдо', 'блюдо', p, 2.00);
    perform pg_temp.expect_rating('разные типы с одним UUID: ресторан', 'ресторан', r, 3.00);

    rv := pg_temp.mk_review(o, 'заказ', o, 5);
    perform pg_temp.expect_rating('INSERT отзыва на заказ: блюдо', 'блюдо', p, 2.00);
    perform pg_temp.expect_rating('INSERT отзыва на заказ: ресторан', 'ресторан', r, 3.00);

    update review set rating = 1 where review_id = rv;
    perform pg_temp.expect_rating('UPDATE отзыва на заказ: блюдо', 'блюдо', p, 2.00);
    perform pg_temp.expect_rating('UPDATE отзыва на заказ: ресторан', 'ресторан', r, 3.00);

    -- В каждом переходе оценка переносимого отзыва равна 5.
    for step in
        select * from (values
            (1, 'заказ -> блюдо',    'блюдо'::entity_type,    p, 3.50, 3.00),
            (2, 'блюдо -> ресторан','ресторан'::entity_type, r, 2.00, 4.00),
            (3, 'ресторан -> заказ','заказ'::entity_type,    o, 2.00, 3.00),
            (4, 'заказ -> ресторан','ресторан'::entity_type, r, 2.00, 4.00),
            (5, 'ресторан -> блюдо','блюдо'::entity_type,     p, 3.50, 3.00),
            (6, 'блюдо -> заказ',   'заказ'::entity_type,    o, 2.00, 3.00)
        ) as t(n, name, kind, target, product_rating, restaurant_rating)
        order by n
    loop
        update review
        set entity_type = step.kind, entity_id = step.target, rating = 5
        where review_id = rv;

        perform pg_temp.expect_rating(step.name || ': блюдо', 'блюдо', p, step.product_rating);
        perform pg_temp.expect_rating(step.name || ': ресторан', 'ресторан', r, step.restaurant_rating);
    end loop;

    delete from review where review_id = rv;
    perform pg_temp.expect_rating('DELETE отзыва на заказ: блюдо', 'блюдо', p, 2.00);
    perform pg_temp.expect_rating('DELETE отзыва на заказ: ресторан', 'ресторан', r, 3.00);
exception when others then
    insert into pg_temp.rating_test_result(test, ok, details)
    values ('смена типа отзыва — ошибка сценария', false, sqlstate || ': ' || sqlerrm);
end;
$$;


-- Итог: 48 проверок при успешном выполнении всех сценариев.
select count(*) filter (where ok) as passed,
       count(*) filter (where not ok) as failed,
       count(*) as total
from pg_temp.rating_test_result;

select id, test, details
from pg_temp.rating_test_result
where not ok
order by id;

rollback;
