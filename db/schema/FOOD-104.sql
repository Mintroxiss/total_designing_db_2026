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
security definer
set search_path = pg_catalog, pg_temp
as $$
begin
    if p_rating is not null then
        raise exception 'Рейтинг блюда рассчитывается по отзывам' using errcode = '23514';
    end if;

    insert into shkuratetskiy_food.product (
        product_name,
        product_category_id,
        price,
        restaurant_id,
        status,
        description,
        measure_unit,
        photo_url
    )
    values (
        p_product_name,
        p_product_category_id,
        p_price,
        p_restaurant_id,
        p_status,
        p_description,
        p_measure_unit,
        p_photo_url
    );
end;
$$;
