begin;


-- СОЗДАНИЕ СХЕМЫ
create schema if not exists exts;
create extension if not exists "uuid-ossp" schema exts;

drop schema if exists shkuratetskiy_food cascade;
create schema shkuratetskiy_food;

set local search_path to shkuratetskiy_food, exts;


-- ENUM-ТИПЫ
create type payment_type       as enum ('карта', 'наличные', 'безнал');
create type transaction_status as enum ('успех', 'ошибка', 'в_обработке');
create type pay_status         as enum ('ожидает', 'оплачен', 'ошибка'); 
create type restaurant_status  as enum ('активен', 'неактивен');
create type product_status     as enum ('доступно', 'нет_в_наличии', 'архив');
create type courier_status     as enum ('свободен', 'занят', 'на_доставке', 'уволен');
create type order_status       as enum ('создан', 'готовится', 'в_доставке', 'доставлен', 'отменён');
create type measure_unit       as enum ('шт', 'кг', 'л');
-- типа отзыва нет из-за того, что нормализовал таблицу и атрибут стал избыточен


-- ТАБЛИЦЫ
create table client (
    client_id    uuid default uuid_generate_v4() primary key,
    login        varchar(50) not null unique check (login ~ '^[a-z][a-z0-9_]{2,49}$'),
    password     varchar(32) not null check(password ~ '^[0-9a-f]{32}$'),
    phone_number char(12) not null unique check(phone_number ~ '^\+79\d{9}$')
);

create table address (
    address_id       uuid default uuid_generate_v4() primary key,
    street           varchar(150) not null,
    house_number     varchar(20) not null,
    apartment_office varchar(20) check(apartment_office is null or btrim(apartment_office) != '')
);

create table client_address (
    client_address_id uuid default uuid_generate_v4() primary key,
    client_id  uuid references client (client_id) on delete set null,
    address_id uuid not null references address (address_id),
    constraint uq_client_id_address_id unique (client_id, address_id)
);

create table restaurant (
    restaurant_id   uuid default uuid_generate_v4() primary key,
    restaurant_name varchar(100) not null,
    address_id      uuid not null unique references address (address_id),
    description     text not null,
    work_start      time not null,
    work_end        time not null,
    company_details text not null,
    rating          numeric(3,2) check(rating between 0 and 5),
    status          restaurant_status not null,
    check(work_start < work_end)
);

create table courier (
    courier_id     uuid default uuid_generate_v4() primary key,
    full_name      varchar(150) not null,
    phone_number   char(12) not null check(phone_number ~ '^\+79\d{9}$'),
    status         courier_status not null,
    hire_date      date not null default current_date,
    dismissal_date date,
    coefficient    numeric(2,1) not null default 0.1 check(coefficient between 0.1 and 0.5),
    check((status = 'уволен') = (dismissal_date is not null)),
    check(dismissal_date is null or hire_date < dismissal_date)
);

create table courier_pay (
    courier_pay_id   uuid default uuid_generate_v4() primary key,
    year             int not null check(year >= 2026),
    month            int not null check(month between 1 and 12),
    courier_id       uuid not null references courier (courier_id),
    amount           numeric(12,2) not null check(amount >= 0),
    coefficient_used numeric(2,1) not null check(coefficient_used between 0.1 and 0.5),
    check(make_date(year, month, 1) <= current_date),
    constraint uq_year_month_courier_id unique (year, month, courier_id)
);

create table product_category (
    product_category_id   uuid default uuid_generate_v4() primary key,
    product_category_name varchar(100) not null
);

create table product (
    product_id          uuid default uuid_generate_v4() primary key,
    product_name        varchar(150) not null,
    product_category_id uuid not null references product_category (product_category_id),
    price               numeric(12,2) not null check(price >= 0),
    restaurant_id       uuid not null references restaurant (restaurant_id),
    photo_url           text,
    rating              numeric(3,2) check(rating between 0 and 5),
    status              product_status not null,
    description         text not null,
    measure_unit        measure_unit not null
);

create table "order" (
    order_id           uuid default uuid_generate_v4() primary key,
    courier_id         uuid references courier (courier_id),
    client_address_id  uuid references client_address (client_address_id) on delete set null,
    restaurant_id      uuid references restaurant (restaurant_id) on delete set null,
    order_timestamp    timestamp not null default localtimestamp,
    delivery_timestamp timestamp,
    order_amount       numeric(12,2),
    commission         numeric(12,2) generated always as (order_amount * 0.1) stored,
    total_amount       numeric(12,2) generated always as (order_amount * 1.1) stored check(total_amount >= 1000),
    status             order_status not null check(status in ('создан','отменён') or order_amount is not null),
    pay_status         pay_status not null default 'ожидает',
    description        text,
    check((status = 'доставлен' and delivery_timestamp is not null) or (status != 'доставлен' and delivery_timestamp is null)),
    check(order_timestamp <= delivery_timestamp),
    check(status != 'доставлен' or pay_status = 'оплачен')
);

create table restaurant_payout (
    payout_id        uuid default uuid_generate_v4() primary key,
    order_id         uuid references "order" (order_id) on delete set null,
    amount           numeric(12,2) not null check(amount >= 0),
    payout_timestamp timestamp not null default localtimestamp,
    transaction_id   varchar(100) not null unique,
    status           transaction_status not null
);

create table payment (
    payment_id            uuid default uuid_generate_v4() primary key,
    order_id              uuid references "order" (order_id) on delete set null,
    payment_type          payment_type not null,
    amount                numeric(12,2) not null check(amount > 0),
    transaction_id        varchar(100) not null unique,
    transaction_timestamp timestamp not null default localtimestamp,
    status                transaction_status not null
);

create table order_structure (
    order_id   uuid references "order" (order_id),
    product_id uuid references product (product_id),
    quantity   numeric(8,3) not null check(quantity > 0),
    price      numeric(12,2) not null check(price >= 0),
    primary key (order_id, product_id)
);

create table review (
    review_id        uuid default uuid_generate_v4() primary key,
    review_timestamp timestamp not null default localtimestamp,
    order_id         uuid references "order" (order_id) on delete set null,
    description      text not null,
    photo_url        text,
    rating           numeric(2,1) not null check(rating between 1 and 5)
);

create table product_review (
    review_id  uuid primary key references review (review_id) on delete cascade,
    product_id uuid not null references product (product_id)
);

create table restaurant_review (
    review_id     uuid primary key references review (review_id) on delete cascade,
    restaurant_id uuid not null references restaurant (restaurant_id)
);

create table order_review (
    review_id uuid primary key references review (review_id) on delete cascade
);

-- ИНДЕКСЫ
create index idx_review_order_id
    on review (order_id);

create index idx_payment_order_id
    on payment (order_id);

create index idx_restaurant_payout_order_id
    on restaurant_payout (order_id);

create index idx_order_structure_product_id
    on order_structure (product_id);

create index idx_client_address_address_id
    on client_address (address_id);

create index idx_product_review_product_id
    on product_review (product_id);

create index idx_restaurant_review_restaurant_id
    on restaurant_review (restaurant_id);

create index idx_courier_pay_courier_id
    on courier_pay (courier_id);

create index idx_product_restaurant_id
    on product (restaurant_id);

create index idx_product_product_category_id
    on product (product_category_id);

create index idx_order_restaurant_id
    on "order" (restaurant_id);

create index idx_order_courier_id
    on "order" (courier_id) where courier_id is not null;

create index idx_order_client_address_id
    on "order" (client_address_id);

create unique index uq_payment_order_success
    on payment (order_id) where status = 'успех';

create unique index uq_restaurant_payout_one_success
    on restaurant_payout (order_id)
    where status = 'успех';

-- BR-3.3, BR-3.4
create unique index uq_address_physical
    on address (
        lower(btrim(street)),
        lower(btrim(house_number)),
        coalesce(lower(btrim(apartment_office)), '')
    );


-- ФУНКЦИИ И ТРИГГЕРЫ

-- BR-7.3
create function check_order_structure_restaurant()
returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
declare
    order_rest uuid;
    prod_rest  uuid;
begin
    select restaurant_id into order_rest from "order" where order_id = new.order_id for share;
    select restaurant_id into prod_rest from product where product_id = new.product_id for share;

    if order_rest is distinct from prod_rest then
        raise exception 'Блюдо % не из ресторана заказа %', new.product_id, new.order_id
            using errcode = 'check_violation';
    end if;

    return new;
end;
$$;

create trigger trg_order_structure_restaurant
    before insert or update of order_id, product_id on order_structure
    for each row
    execute function check_order_structure_restaurant();


-- BR-8.4.
create function payment_copy_amount()
returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
declare
    order_total numeric(12,2);
    order_st order_status;
begin
    if tg_op = 'INSERT' then
        select total_amount, status
        into order_total, order_st
        from "order"
        where order_id = new.order_id
        for update;

        if not found then
            raise exception 'Заказ % не найден', new.order_id;
        end if;

        if order_st = 'отменён' then
            raise exception 'Заказ % отменён, оплата невозможна', new.order_id;
        end if;

        if order_total is null then
            raise exception 'Сумма заказа % не определена', new.order_id;
        end if;

        if new.amount is null then
            new.amount := order_total;
        elsif new.amount != order_total then
            raise exception 'Сумма оплаты не равна сумме заказа';
        end if;
    else
        if new.amount is distinct from old.amount then
            raise exception 'Нельзя менять сумму существующей попытки оплаты';
        end if;

        if new.order_id is distinct from old.order_id and pg_trigger_depth() = 1 then
            raise exception 'Нельзя менять заказ существующей попытки оплаты';
        end if;
end if;

    return new;
end;
$$;

create trigger trg_payment_amount_ins
    before insert on payment
    for each row
    execute function payment_copy_amount();

create trigger trg_payment_amount_upd
    before update of amount, order_id on payment
    for each row
    when (new.amount is distinct from old.amount or new.order_id is distinct from old.order_id)
    execute function payment_copy_amount();


-- BR-9.2, BR-9.5
create function check_product_review()
returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
declare
    ord uuid;
begin
    select order_id into ord from review where review_id = new.review_id;
    if ord is null then
        raise exception 'Отзыв % не найден', new.review_id
            using errcode = 'foreign_key_violation';
    end if;

    perform 1 from "order" where order_id = ord for update;

    if not exists (select 1 from order_structure where order_id = ord and product_id = new.product_id) then
        raise exception 'Блюда % нет в заказе %', new.product_id, ord
            using errcode = 'check_violation';
    end if;

    if exists (
        select 1 from product_review pr
        join review r using (review_id)
        where r.order_id = ord and pr.product_id = new.product_id
          and pr.review_id != new.review_id
    ) then
        raise exception 'На блюдо % в заказе % уже есть отзыв', new.product_id, ord
            using errcode = 'unique_violation';
    end if;

    return new;
end;
$$;

create trigger trg_product_review
    before insert or update of review_id, product_id on product_review
    for each row execute function check_product_review();


-- BR-9.2, BR-9.5
create function check_restaurant_review()
returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
declare
    ord      uuid;
    ord_rest uuid;
begin
    select order_id into ord from review where review_id = new.review_id;
    if ord is null then
        raise exception 'Отзыв % не найден', new.review_id
            using errcode = 'foreign_key_violation';
    end if;

    select restaurant_id into ord_rest from "order" where order_id = ord for update;

    if ord_rest is distinct from new.restaurant_id then
        raise exception 'Заказ % сделан не в ресторане %', ord, new.restaurant_id
            using errcode = 'check_violation';
    end if;

    if exists (
        select 1 from restaurant_review rr
        join review r using (review_id)
        where r.order_id = ord and rr.review_id != new.review_id
    ) then
        raise exception 'На ресторан в заказе % уже есть отзыв', ord
            using errcode = 'unique_violation';
    end if;

    return new;
end;
$$;

create trigger trg_restaurant_review
    before insert or update of review_id, restaurant_id on restaurant_review
    for each row execute function check_restaurant_review();


-- BR-9.5
create function check_order_review()
returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
declare
    ord uuid;
begin
    select order_id into ord from review where review_id = new.review_id;
    if ord is null then
        raise exception 'Отзыв % не найден', new.review_id
            using errcode = 'foreign_key_violation';
    end if;

    perform 1 from "order" where order_id = ord for update;

    if exists (
        select 1 from order_review orv
        join review r using (review_id)
        where r.order_id = ord and orv.review_id != new.review_id
    ) then
        raise exception 'На заказ % уже есть отзыв', ord
            using errcode = 'unique_violation';
    end if;

    return new;
end;
$$;

create trigger trg_order_review
    before insert or update of review_id on order_review
    for each row execute function check_order_review();


-- BR-9.1
create function check_review_single_type() returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
begin
    -- блокирует строку review, чтобы две параллельные транзакции
    -- не вставили один отзыв в разные подтаблицы одновременно
    perform 1 from review where review_id = new.review_id for update;

    if (tg_table_name != 'product_review'
            and exists (select 1 from product_review where review_id = new.review_id))
    or (tg_table_name != 'restaurant_review'
            and exists (select 1 from restaurant_review where review_id = new.review_id))
    or (tg_table_name != 'order_review'
            and exists (select 1 from order_review where review_id = new.review_id))
    then
        raise exception 'Отзыв % уже привязан к другому объекту', new.review_id
            using errcode = '23514';
    end if;

    return new;
end;
$$;

create trigger trg_product_review_single_type
    before insert or update of review_id on product_review
    for each row execute function check_review_single_type();

create trigger trg_restaurant_review_single_type
    before insert or update of review_id on restaurant_review
    for each row execute function check_review_single_type();

create trigger trg_order_review_single_type
    before insert or update of review_id on order_review
    for each row execute function check_review_single_type();


-- BR 7.10, BR-7.14
create function order_amount_guard() returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
begin
    if tg_op = 'INSERT' then
        new.order_amount := null;
    elsif new.order_amount is distinct from old.order_amount
          and pg_trigger_depth() = 1 then
        raise exception 'order_amount вычисляется автоматически';
    end if;
    return new;
end $$;

create trigger trg_order_amount_guard
before insert or update of order_amount on "order"
for each row execute function order_amount_guard();


-- BR-5.5, BR-7.3, BR-7.14, BR-7.15, BR-8.4
create function item_before() returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
declare
    oid uuid := case when tg_op = 'DELETE' then old.order_id else new.order_id end;
    st  order_status;
    p   numeric;
    pst product_status;
begin
    if tg_op = 'UPDATE' and new.order_id != old.order_id then
        raise exception 'Нельзя переносить позицию в другой заказ'
            using errcode = 'check_violation';
    end if;

    if tg_op = 'UPDATE' and new.product_id != old.product_id then
        raise exception 'Нельзя менять блюдо в позиции, удалите позицию и добавьте новую'
            using errcode = 'check_violation';
    end if;

    select status into st from "order" where order_id = oid for update;

    if st != 'создан'
        or exists (
            select 1
            from payment
            where order_id = oid
        )
        or exists (
            select 1
            from restaurant_payout
            where order_id = oid
        ) then
            raise exception 'Состав заказа % изменять нельзя', oid;
    end if;

    if tg_op = 'DELETE' then
        if exists (
            select 1
            from product_review pr
            join review r using (review_id)
            where r.order_id = old.order_id and pr.product_id = old.product_id
        ) then
            raise exception 'На блюдо % в заказе % уже есть отзыв', old.product_id, old.order_id
                using errcode = 'check_violation';
        end if;
        return old;
    elsif tg_op = 'INSERT' then
        select price, status into p, pst
        from product where product_id = new.product_id
        for share;

        if not found then
            raise exception 'Блюдо % не найдено', new.product_id
                using errcode = 'foreign_key_violation';
        end if;

        if pst != 'доступно' then
            raise exception 'Блюдо % недоступно для заказа (статус: %)', new.product_id, pst
                using errcode = 'check_violation';
        end if;

        if new.price is not null and new.price != p then
            raise exception 'Цена позиции должна совпадать с ценой блюда';
        end if;
        new.price := p;
    elsif new.price != old.price then
        raise exception 'Цена позиции фиксируется при добавлении';
    end if;

    return new;
end $$;

create trigger trg_item_before
before insert or update or delete on order_structure
for each row execute function item_before();


-- BR-7.10, BR-7.11, BR-7.14
create function item_after() returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
declare
    oid uuid := case when tg_op = 'DELETE' then old.order_id else new.order_id end;
    s   numeric;
begin
    perform 1 from "order" where order_id = oid for update;

    select round(sum(quantity * price), 2) into s
    from order_structure where order_id = oid;

    update "order"
       set order_amount = case when round(s * 1.1, 2) >= 1000 then s end
     where order_id = oid;
    return null;
end $$;

create trigger trg_item_after
after insert or update or delete on order_structure
for each row execute function item_after();


-- BR-7.8, BR-7.9, BR-8.7
create function order_pay_status_guard() returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
begin
    if tg_op = 'INSERT' then
        new.pay_status := 'ожидает';
    elsif new.pay_status is distinct from old.pay_status
          and pg_trigger_depth() = 1 then
        raise exception 'pay_status вычисляется автоматически';
    end if;
    return new;
end $$;

create trigger trg_order_pay_status_guard
before insert or update of pay_status on "order"
for each row execute function order_pay_status_guard();


-- BR-7.8, BR-7.9, BR-8.7
create function order_pay_status_sync()
returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
declare
    oid uuid;
    s   pay_status;
begin
    if tg_op = 'UPDATE' and old.order_id is distinct from new.order_id then
        -- Пересчитываем статус старого заказа
        oid := old.order_id;

        if oid is not null then
            perform sync_order_pay_status(oid);
        end if;
    end if;

    -- Пересчитываем статус текущего заказа
    oid := case when tg_op = 'DELETE' then old.order_id else new.order_id end;

    if oid is not null then
        perform sync_order_pay_status(oid);
    end if;

    return null;
end;
$$;

create function sync_order_pay_status(p_order_id uuid)
returns void
language plpgsql
set search_path = shkuratetskiy_food
as $$
declare
    s pay_status;
begin
    perform 1
    from "order"
    where order_id = p_order_id
    for update;

    if not found then
        return;
    end if;

    select case
               when bool_or(status = 'успех') then 'оплачен'
               when count(*) > 0 and bool_and(status = 'ошибка') then 'ошибка'
               else 'ожидает'
           end::pay_status
    into s
    from payment
    where order_id = p_order_id;

    update "order"
       set pay_status = s
     where order_id = p_order_id
       and pay_status is distinct from s;
end;
$$;

create trigger trg_payment_pay_status
after insert or update of status, order_id or delete on payment
for each row
execute function order_pay_status_sync();


-- BR-7.3, BR-9.2
create function order_restaurant_guard()
returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
begin
    if old.restaurant_id is not null and new.restaurant_id is null and pg_trigger_depth() > 1 then
        return new;
    end if;
    
    if exists (select 1 from order_structure where order_id = new.order_id) then
        raise exception 'Нельзя менять ресторан у заказа % с позициями', new.order_id
            using errcode = 'check_violation';
    end if;

    -- BR-9.2
    if exists (
        select 1
        from restaurant_review rr
        join review r using (review_id)
        where r.order_id = new.order_id
    ) then
        raise exception 'Нельзя менять ресторан у заказа %: на него уже есть отзыв', new.order_id
            using errcode = 'check_violation';
    end if;

    return new;
end;
$$;

create trigger trg_order_restaurant_guard
    before update of restaurant_id on "order"
    for each row
    when (new.restaurant_id is distinct from old.restaurant_id)
    execute function order_restaurant_guard();


-- BR-3.4
create function check_client_address_not_restaurant()
returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
begin
    perform 1 from address where address_id = new.address_id for update;

    if exists (select 1 from restaurant where address_id = new.address_id) then
        raise exception 'Адрес % занят рестораном, его нельзя привязать клиенту', new.address_id
            using errcode = 'check_violation';
    end if;

    return new;
end;
$$;

create trigger trg_client_address_not_restaurant
    before insert or update of address_id on client_address
    for each row
    execute function check_client_address_not_restaurant();


-- BR-3.4
create function check_restaurant_address_not_client()
returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
begin
    perform 1 from address where address_id = new.address_id for update;

    if exists (select 1 from client_address where address_id = new.address_id) then
        raise exception 'Адрес % используется клиентом, его нельзя назначить ресторану', new.address_id
            using errcode = 'check_violation';
    end if;

    return new;
end;
$$;

create trigger trg_restaurant_address_not_client
    before insert or update of address_id on restaurant
    for each row
    execute function check_restaurant_address_not_client();


-- BR-7.3
create function product_restaurant_guard()
returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
begin
    if exists (select 1 from order_structure where product_id = new.product_id) then
        raise exception 'Нельзя менять ресторан у блюда %: оно есть в заказах', new.product_id
            using errcode = 'check_violation';
    end if;
    return new;
end;
$$;

create trigger trg_product_restaurant_guard
    before update of restaurant_id on product
    for each row
    when (new.restaurant_id is distinct from old.restaurant_id)
    execute function product_restaurant_guard();


-- BR-7.15
create function check_quantity_measure()
returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
declare
    u measure_unit;
begin
    select measure_unit into u from product where product_id = new.product_id for share;

    if u = 'шт' and new.quantity != trunc(new.quantity) then
        raise exception 'Количество % дробное, а блюдо % измеряется в штуках', new.quantity, new.product_id
            using errcode = 'check_violation';
    end if;

    return new;
end;
$$;

create trigger trg_order_structure_quantity
    before insert or update of product_id, quantity on order_structure
    for each row
    execute function check_quantity_measure();


-- BR-8.1
create function payment_closed_guard()
returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
declare
    ps pay_status;
begin
    select pay_status into ps from "order" where order_id = new.order_id for update;

    if ps = 'оплачен' then
        raise exception 'Заказ % уже оплачен, новые попытки оплаты не принимаются', new.order_id
            using errcode = 'check_violation';
    end if;

    return new;
end;
$$;

create trigger trg_payment_closed
    before insert on payment
    for each row
    execute function payment_closed_guard();


-- BR-9.2
create function review_order_immutable()
returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
begin
    if old.order_id is not null and new.order_id is null and pg_trigger_depth() > 1 then
        return new;
    end if;

    raise exception 'Нельзя менять заказ у существующего отзыва %', old.review_id
        using errcode = 'check_violation';
end;
$$;

create trigger trg_review_order_immutable
    before update of order_id on review
    for each row
    when (new.order_id is distinct from old.order_id)
    execute function review_order_immutable();


-- BR-7.15
create function product_measure_guard()
returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
begin
    if exists (select 1 from order_structure where product_id = new.product_id) then
        raise exception 'Нельзя менять единицу измерения у блюда %: оно есть в заказах', new.product_id
            using errcode = 'check_violation';
    end if;
    return new;
end;
$$;

create trigger trg_product_measure_guard
    before update of measure_unit on product
    for each row
    when (new.measure_unit is distinct from old.measure_unit)
    execute function product_measure_guard();


-- BR-1.5
create function payout_copy_amount()
returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
declare
    order_sum numeric(12,2);
    order_st  order_status;
    order_ps  pay_status;
begin
    if tg_op = 'INSERT' then
        select order_amount, status, pay_status into order_sum, order_st, order_ps
        from "order" where order_id = new.order_id
        for update;

        if not found then
            raise exception 'Заказ % не найден', new.order_id
                using errcode = 'foreign_key_violation';
        end if;

        if order_st = 'отменён' then
            raise exception 'Заказ % отменён, выплата невозможна', new.order_id
                using errcode = 'check_violation';
        end if;

        if order_ps != 'оплачен' then
            raise exception 'Заказ % не оплачен, выплата ресторану невозможна', new.order_id
                using errcode = 'check_violation';
        end if;

        if order_sum is null then
            raise exception 'Сумма заказа % без комиссии не определена', new.order_id
                using errcode = 'check_violation';
        end if;

        if new.amount is null then
            new.amount := order_sum;
        elsif new.amount != order_sum then
            raise exception 'Сумма перевода % не равна стоимости блюд заказа %', new.amount, order_sum
                using errcode = 'check_violation';
        end if;
    else
        if new.amount is distinct from old.amount then
            raise exception 'Нельзя менять сумму существующего перевода';
        end if;

        if new.order_id is distinct from old.order_id and (new.order_id is not null or pg_trigger_depth() = 1) then
            raise exception 'Нельзя переносить выплату на другой заказ';
        end if;
    end if;

    return new;
end;
$$;

create trigger trg_payout_amount_ins
    before insert on restaurant_payout
    for each row execute function payout_copy_amount();

create trigger trg_payout_amount_upd
    before update of amount, order_id on restaurant_payout
    for each row
    when (new.amount is distinct from old.amount or new.order_id is distinct from old.order_id)
    execute function payout_copy_amount();


-- BR-9.2
create function order_client_guard()
returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
begin
    if old.client_address_id is not null and new.client_address_id is null and pg_trigger_depth() > 1 then
        return new;
    end if;

    if exists (
        select 1
        from review
        where order_id = new.order_id
    ) then
        raise exception 'Нельзя менять адрес заказа %: на него уже есть отзыв', new.order_id
            using errcode = 'check_violation';
    end if;

    return new;
end;
$$;

create trigger trg_order_client_guard
    before update of client_address_id on "order"
    for each row
    when (new.client_address_id is distinct from old.client_address_id)
    execute function order_client_guard();


-- BR-9.2
create function review_lock_order()
returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
declare
    st order_status;
begin
    select status into st from "order" where order_id = new.order_id for update;

    if not found then
        raise exception 'Заказ % не найден', new.order_id
            using errcode = 'foreign_key_violation';
    end if;

    if st != 'доставлен' then
        raise exception 'Отзыв можно оставить только на доставленный заказ, статус заказа %: %', new.order_id, st
            using errcode = 'check_violation';
    end if;

    return new;
end;
$$;

create trigger trg_review_lock_order
    before insert on review
    for each row
    execute function review_lock_order();


-- BR-9.1
create function check_review_exactly_one_type()
returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
declare
    rid uuid;
    subtype_count integer;
    ids uuid[];
begin
    if tg_table_name = 'review' then
        if tg_op = 'DELETE' then
            return null;
        end if;

    ids := array[new.review_id];

    elsif tg_op = 'DELETE' then
        -- Удаление подтипа при удалении родительского review
        if not exists (
            select 1 from review where review_id = old.review_id
        ) then
            return null;
        end if;

    ids := array[old.review_id];

    elsif tg_op = 'UPDATE' then
        ids := array[old.review_id, new.review_id];

    else
        ids := array[new.review_id];
    end if;

    foreach rid in array ids loop

        perform 1
        from review
        where review_id = rid
        for update;

        if not found then
            continue;
        end if;

        select
            (exists (select 1 from product_review where review_id = rid))::int +
            (exists (select 1 from restaurant_review where review_id = rid))::int +
            (exists (select 1 from order_review where review_id = rid))::int
        into subtype_count;

        if subtype_count != 1 then
            raise exception
                'Отзыв % должен иметь ровно один подтип, найдено: %',
                rid, subtype_count
                using errcode = 'check_violation';
        end if;

    end loop;

    return null;
end;
$$;

create constraint trigger trg_review_exactly_one_type
after insert or update on review
deferrable initially deferred
for each row
execute function check_review_exactly_one_type();

create constraint trigger trg_product_review_exactly_one_type
after insert or update or delete on product_review
deferrable initially deferred
for each row
execute function check_review_exactly_one_type();

create constraint trigger trg_restaurant_review_exactly_one_type
after insert or update or delete on restaurant_review
deferrable initially deferred
for each row
execute function check_review_exactly_one_type();

create constraint trigger trg_order_review_exactly_one_type
after insert or update or delete on order_review
deferrable initially deferred
for each row
execute function check_review_exactly_one_type();


-- BR-7.5
create function check_order_courier()
returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
declare
    courier_st courier_status;
begin
    if new.courier_id is null then
        return new;
    end if;

    select status into courier_st
    from courier
    where courier_id = new.courier_id
    for share;

    if courier_st = 'уволен' then
        raise exception 'Нельзя назначить уволенного курьера % на заказ',
            new.courier_id
            using errcode = 'check_violation';
    end if;

    return new;
end;
$$;


create trigger trg_order_courier_check
before insert or update of courier_id on "order"
for each row
execute function check_order_courier();


-- BR-7.5
create function check_courier_dismissal()
returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
begin
    if new.status = 'уволен'
       and old.status != 'уволен'
       and exists (
           select 1
           from "order"
           where courier_id = new.courier_id
             and status in ('создан', 'готовится', 'в_доставке')
       )
    then
        raise exception 'Нельзя уволить курьера: за ним закреплены активные заказы';
    end if;

    return new;
end;
$$;

create trigger trg_courier_dismissal_check
before update of status on courier
for each row
execute function check_courier_dismissal();


-- BR-8.1
create function prevent_success_transaction_change()
returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
begin
    if old.status = 'успех'
       and new.status != 'успех'
    then
        raise exception 'Нельзя изменить статус успешной транзакции';
    end if;

    return new;
end;
$$;

create trigger trg_payment_success_immutable
before update of status on payment
for each row
execute function prevent_success_transaction_change();


create trigger trg_payout_success_immutable
before update of status on restaurant_payout
for each row
execute function prevent_success_transaction_change();


-- BR-7.2, BR-7.4, BR-11.3
create function order_parties_guard()
returns trigger
language plpgsql
set search_path = shkuratetskiy_food
as $$
declare
    cl uuid;
begin
    if tg_op = 'INSERT' or new.client_address_id is distinct from old.client_address_id then
        if new.client_address_id is null then
            if tg_op = 'INSERT' or pg_trigger_depth() = 1 then
                raise exception 'У заказа должен быть адрес клиента'
                    using errcode = 'not_null_violation';
            end if;
        else
            select client_id into cl
            from client_address
            where client_address_id = new.client_address_id
            for share;

            if cl is null then
                raise exception 'Адрес % не привязан к клиенту, оформить на него заказ нельзя',
                    new.client_address_id
                    using errcode = 'check_violation';
            end if;
        end if;
    end if;

    if tg_op = 'INSERT' or new.restaurant_id is distinct from old.restaurant_id then
        if new.restaurant_id is null
           and (tg_op = 'INSERT' or pg_trigger_depth() = 1) then
            raise exception 'У заказа должен быть ресторан'
                using errcode = 'not_null_violation';
        end if;
    end if;

    return new;
end;
$$;

create trigger trg_order_parties_guard
    before insert or update of client_address_id, restaurant_id on "order"
    for each row
    execute function order_parties_guard();


commit;