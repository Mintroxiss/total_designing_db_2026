create or replace procedure shkuratetskiy_food.erase_test_data()
language plpgsql
set search_path = shkuratetskiy_food, exts
as $$
begin
    delete from review; -- подтипы отзывов уходят каскадом

    update "order"
       set status = 'создан', delivery_timestamp = null
     where status != 'создан';

    delete from restaurant_payout;
    delete from payment;
    delete from order_structure;
    delete from "order";

    delete from courier_pay;
    delete from courier;

    delete from product;
    delete from product_category;
    delete from restaurant;

    delete from client_address;
    delete from address;
    delete from client;
end;
$$;