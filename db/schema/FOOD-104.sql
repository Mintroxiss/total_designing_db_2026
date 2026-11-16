create or replace procedure shkuratetskiy_food.add_product(
    p_product_name        varchar,
    p_product_category_id uuid,
    p_price               numeric,
    p_restaurant_id       uuid,
    p_status              shkuratetskiy_food.product_status,
    p_description         text,
    p_measure_unit        shkuratetskiy_food.measure_unit,
    p_photo_url           text    default null,
    p_rating              numeric default null
)
language plpgsql
set search_path = shkuratetskiy_food, exts
as $$
begin
    perform 1 from restaurant where restaurant_id = p_restaurant_id for share;
    if not found then
        raise exception 'Ресторан % не найден', p_restaurant_id
            using errcode = 'foreign_key_violation';
    end if;

    perform 1 from product_category
     where product_category_id = p_product_category_id for share;
    if not found then
        raise exception 'Категория % не найдена', p_product_category_id
            using errcode = 'foreign_key_violation';
    end if;

    -- product_id генерируется значением по умолчанию колонки (uuid_generate_v4())
    insert into product(product_name, product_category_id, price, restaurant_id,
                        photo_url, rating, status, description, measure_unit)
    values (p_product_name, p_product_category_id, p_price, p_restaurant_id,
            p_photo_url, p_rating, p_status, p_description, p_measure_unit);
exception
    when check_violation or not_null_violation then
        raise exception 'Не удалось добавить блюдо: %', sqlerrm
            using errcode = sqlstate;
end;
$$;