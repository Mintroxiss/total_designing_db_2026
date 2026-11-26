create or replace procedure shkuratetskiy_food.erase_test_data()
language plpgsql
set search_path = shkuratetskiy_food, exts
as $$
begin
    delete from review;

    -- Отменяет заказы перед удалением оплат и позиций
    update "order"
       set status = 'отменён',
           delivery_timestamp = null
     where status != 'отменён';

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