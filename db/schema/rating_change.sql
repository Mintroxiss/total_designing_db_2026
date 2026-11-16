begin;

set local search_path to shkuratetskiy_food, exts;

create function refresh_product_rating(p_id uuid)
returns void
language plpgsql
set search_path = shkuratetskiy_food
as $$
begin
    perform 1 from product where product_id = p_id for update;

    update product p
       set rating = (select round(avg(r.rating), 2)
                     from product_review pr
                     join review r using (review_id)
                     where pr.product_id = p_id)
     where p.product_id = p_id;
end;
$$;

create function refresh_restaurant_rating(r_id uuid)
returns void
language plpgsql
set search_path = shkuratetskiy_food
as $$
begin
    perform 1 from restaurant where restaurant_id = r_id for update;

    update restaurant s
       set rating = (select round(avg(r.rating), 2)
                     from restaurant_review rr
                     join review r using (review_id)
                     where rr.restaurant_id = r_id)
    where s.restaurant_id = r_id;
end;
$$;

create function rating_change()
returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
declare
    ids uuid[] := '{}';
    x   uuid;
begin
    if tg_table_name = 'product_review' then
        if tg_op in ('UPDATE', 'DELETE') then ids := ids || old.product_id; end if;
        if tg_op in ('INSERT', 'UPDATE') then ids := ids || new.product_id; end if;

        for x in select distinct u from unnest(ids) u order by u loop
            perform refresh_product_rating(x);
        end loop;

    elsif tg_table_name = 'restaurant_review' then
        if tg_op in ('UPDATE', 'DELETE') then ids := ids || old.restaurant_id; end if;
        if tg_op in ('INSERT', 'UPDATE') then ids := ids || new.restaurant_id; end if;

        for x in select distinct u from unnest(ids) u order by u loop
            perform refresh_restaurant_rating(x);
        end loop;

    elsif tg_table_name = 'review' then
        for x in select product_id from product_review where review_id = new.review_id loop
            perform refresh_product_rating(x);
        end loop;
        for x in select restaurant_id from restaurant_review where review_id = new.review_id loop
            perform refresh_restaurant_rating(x);
        end loop;
    end if;

    return null;
end;
$$;

create trigger trg_product_review_rating
    after insert or update of product_id, review_id or delete on product_review
    for each row execute function rating_change();

create trigger trg_restaurant_review_rating
    after insert or update of restaurant_id, review_id or delete on restaurant_review
    for each row execute function rating_change();

create trigger trg_review_rating
    after update of rating on review
    for each row
    when (new.rating is distinct from old.rating)
    execute function rating_change();

commit;
