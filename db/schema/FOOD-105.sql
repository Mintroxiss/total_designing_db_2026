begin;

set local search_path to shkuratetskiy_food, exts;

-- Пересчитывает рейтинг блюда или ресторана при изменении отзывов
create or replace function rating_change()
returns trigger
language plpgsql
as $$
declare
    v_old_entity_type shkuratetskiy_food.entity_type;
    v_old_entity_id   uuid;
    v_new_entity_type shkuratetskiy_food.entity_type;
    v_new_entity_id   uuid;
    v_entity_type     shkuratetskiy_food.entity_type;
    v_entity_id       uuid;
begin
    case tg_op
        when 'INSERT' then
            v_new_entity_type := new.entity_type;
            v_new_entity_id   := new.entity_id;

        when 'UPDATE' then
            v_old_entity_type := old.entity_type;
            v_old_entity_id   := old.entity_id;
            v_new_entity_type := new.entity_type;
            v_new_entity_id   := new.entity_id;

        when 'DELETE' then
            v_old_entity_type := old.entity_type;
            v_old_entity_id   := old.entity_id;
    end case;

    for v_entity_type, v_entity_id in
        select distinct e.entity_type, e.entity_id
        from (
            values
                (v_old_entity_type, v_old_entity_id),
                (v_new_entity_type, v_new_entity_id)
        ) as e(entity_type, entity_id)
        where e.entity_type in ('блюдо', 'ресторан')
        order by e.entity_type, e.entity_id
    loop
        case v_entity_type

            when 'блюдо' then

                perform 1
                from shkuratetskiy_food.product
                where product_id = v_entity_id
                for no key update;

                update shkuratetskiy_food.product
                set rating = (
                    select round(avg(rating), 2)
                    from shkuratetskiy_food.review
                    where entity_type = 'блюдо'
                      and entity_id = v_entity_id
                )
                where product_id = v_entity_id;

            when 'ресторан' then

                perform 1
                from shkuratetskiy_food.restaurant
                where restaurant_id = v_entity_id
                for no key update;

                update shkuratetskiy_food.restaurant
                set rating = (
                    select round(avg(rating), 2)
                    from shkuratetskiy_food.review
                    where entity_type = 'ресторан'
                      and entity_id = v_entity_id
                )
                where restaurant_id = v_entity_id;

        end case;
    end loop;

    return null;
end;
$$;

create or replace trigger trg_review_rating
    after insert or update or delete
    on review
    for each row
    execute function rating_change();

commit;