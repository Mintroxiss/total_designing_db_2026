begin;


-- СОЗДАНИЕ СХЕМЫ
create schema if not exists exts;
create extension if not exists "uuid-ossp" schema exts;

drop schema if exists shkuratetskiy_food cascade;
create schema shkuratetskiy_food;

set local search_path to shkuratetskiy_food, exts;


-- ENUM-ТИПЫ
create type payment_type       as enum ('карта', 'наличные', 'безнал');
create type payment_status     as enum ('успех', 'ошибка', 'в_обработке');
create type pay_status         as enum ('ожидает', 'оплачен', 'ошибка'); 
create type restaurant_status  as enum ('активен', 'неактивен');
create type product_status     as enum ('доступно', 'нет_в_наличии', 'архив');
create type courier_status     as enum ('свободен', 'занят', 'на_доставке', 'уволен');
create type order_status       as enum ('создан', 'готовится', 'в_доставке', 'доставлен', 'отменён');
create type entity_type        as enum ('блюдо', 'ресторан', 'заказ');
create type measure_unit       as enum ('шт', 'кг', 'л');


-- ТАБЛИЦЫ
create table client (
    client_id    uuid default uuid_generate_v4() primary key,
    login        varchar(50) not null unique check (login ~ '^[a-z][a-z0-9_]{2,49}$'),
    password     varchar(32) not null check(password ~ '^[0-9a-f]{32}$'),
    phone_number char(12) not null unique check(phone_number ~ '^\+79\d{9}$'),
    deleted_at   timestamp
);

create table address (
    address_id       uuid default uuid_generate_v4() primary key,
    street           varchar(150) not null,
    house_number     varchar(20) not null,
    apartment_office varchar(20)
);

create table client_address (
    client_address_id uuid default uuid_generate_v4() primary key,
    client_id         uuid not null references client (client_id) on delete restrict,
    address_id        uuid not null references address (address_id) on delete restrict,
    constraint uq_client_id_address_id unique (client_id, address_id)
);

create table restaurant (
    restaurant_id   uuid default uuid_generate_v4() primary key,
    restaurant_name varchar(100) not null,
    address_id      uuid not null unique references address (address_id) on delete restrict,
    description     text not null,
    work_start      time not null,
    work_end        time not null,
    inn             varchar not null,
    ogrn            varchar not null,
    bank_account    varchar not null,
    rating          numeric(3,2) check(rating between 0 and 5),
    status          restaurant_status not null,
    deleted_at      timestamp,
    check(work_start < work_end)
);

create table courier (
    courier_id     uuid default uuid_generate_v4() primary key,
    last_name      varchar not null,
    first_name     varchar not null,
    middle_name    varchar not null,
    phone_number   char(12) not null check(phone_number ~ '^\+79\d{9}$'),
    status         courier_status not null,
    hire_date      date not null default current_date,
    dismissal_date date,
    coefficient    numeric(2,1) not null default 0.1 check(coefficient between 0.1 and 0.5),
    check((status = 'уволен') = (dismissal_date is not null)),
    check(dismissal_date is null or hire_date <= dismissal_date)
);

create table courier_pay (
    courier_pay_id   uuid default uuid_generate_v4() primary key,
    year             int not null check(year >= 2026),
    month            int not null check(month between 1 and 12),
    courier_id       uuid not null references courier (courier_id) on delete restrict,
    amount           numeric(8,2) not null check(amount >= 0),
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
    product_category_id uuid not null references product_category (product_category_id) on delete restrict,
    price               numeric(7,2) not null check(price >= 0),
    restaurant_id       uuid not null references restaurant (restaurant_id) on delete restrict,
    photo_url           text,
    rating              numeric(3,2) check(rating between 0 and 5),
    status              product_status not null,
    description         text not null,
    measure_unit        measure_unit not null
);

create table "order" (
    order_id           uuid default uuid_generate_v4() primary key,
    courier_id         uuid references courier (courier_id) on delete restrict,
    client_address_id  uuid not null references client_address (client_address_id) on delete restrict,
    restaurant_id      uuid not null references restaurant (restaurant_id) on delete restrict,
    order_timestamp    timestamp not null default localtimestamp,
    delivery_timestamp timestamp,
    order_amount       numeric(8,2) not null default 0 check(order_amount >= 0),
    commission         numeric(8,2) generated always as (order_amount * 0.1) stored,
    total_amount       numeric(9,2) generated always as (order_amount * 1.1) stored,
    status             order_status not null,
    pay_status         pay_status not null default 'ожидает',
    description        text,
    deleted_at         timestamp,
    check((status = 'доставлен' and delivery_timestamp is not null) or (status != 'доставлен' and delivery_timestamp is null)),
    check(order_timestamp <= delivery_timestamp),
    check(status != 'доставлен' or pay_status = 'оплачен'),
    check (status in ('создан', 'отменён') or total_amount >= 1000),
    check (courier_id is not null or status in ('создан', 'готовится', 'отменён'))
);

create table payment (
    payment_id            uuid default uuid_generate_v4() primary key,
    order_id              uuid not null references "order" (order_id) on delete restrict,
    payment_type          payment_type not null,
    amount                numeric(9,2) not null check(amount >= 1000),
    transaction_id        varchar(100) not null unique,
    transaction_timestamp timestamp not null default localtimestamp,
    status                payment_status not null
);

create table order_structure (
    order_id   uuid references "order" (order_id) on delete restrict,
    product_id uuid references product (product_id) on delete restrict,
    quantity   numeric(6,3) not null check(quantity > 0),
    price      numeric(7,2) not null check(price >= 0),
    primary key (order_id, product_id)
);

create table review (
    review_id        uuid default uuid_generate_v4() primary key,
    review_timestamp timestamp not null default localtimestamp,
    entity_id        uuid not null,
    entity_type      entity_type not null,
    order_id         uuid not null references "order" (order_id) on delete restrict,
    description      text not null,
    photo_url        text,
    rating           numeric(2,1) not null check(rating between 1 and 5),
    constraint uq_review_order_entity unique (order_id, entity_type, entity_id)
);


-- ИНДЕКСЫ

create index idx_payment_order_id
    on payment (order_id);

create index idx_order_structure_product_id
    on order_structure (product_id);

create index idx_client_address_address_id
    on client_address (address_id);

create index idx_courier_pay_courier_id
    on courier_pay (courier_id);

create index idx_review_entity
    on review (entity_type, entity_id);

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

create unique index uq_address_physical
    on address (
        lower(btrim(street)),
        lower(btrim(house_number)),
        coalesce(lower(btrim(apartment_office)), '')
    );


-- ТРИГГЕРНЫЕ ФУНКЦИИ

-- Запрещает добавлять в заказ блюда из разных ресторанов
create function check_order_product_restaurant()
returns trigger
language plpgsql
as $$
declare
    v_order_restaurant_id   uuid;
    v_product_restaurant_id uuid;
begin
    case tg_table_name

        -- Проверяет ресторан при добавлении или изменении позиции заказа
        when 'order_structure' then

            select restaurant_id
            into v_order_restaurant_id
            from shkuratetskiy_food."order"
            where order_id = new.order_id
            for no key update;

            select restaurant_id
            into v_product_restaurant_id
            from shkuratetskiy_food.product
            where product_id = new.product_id
            for share;

            if v_order_restaurant_id
                is distinct from v_product_restaurant_id then
                raise exception
                    'Блюдо % не принадлежит ресторану заказа %',
                    new.product_id, new.order_id
                    using errcode = '23514';
            end if;

        -- Проверяет состав заказов при смене ресторана блюда
        when 'product' then

            if exists (
                select 1
                from shkuratetskiy_food.order_structure os
                join shkuratetskiy_food."order" o
                    on o.order_id = os.order_id
                where os.product_id = old.product_id
                  and o.restaurant_id
                      is distinct from new.restaurant_id
            ) then
                raise exception
                    'Невозможно изменить ресторан блюда %: нарушается состав заказов',
                    old.product_id
                    using errcode = '23514';
            end if;

        -- Проверяет состав заказа при смене его ресторана
        when 'order' then

            if exists (
                select 1
                from shkuratetskiy_food.order_structure os
                join shkuratetskiy_food.product p
                    on p.product_id = os.product_id
                where os.order_id = old.order_id
                  and p.restaurant_id
                      is distinct from new.restaurant_id
            ) then
                raise exception
                    'Невозможно изменить ресторан заказа %: в заказе есть блюда другого ресторана',
                    old.order_id
                    using errcode = '23514';
            end if;

    end case;

    return new;
end;
$$;

-- Пересчитывает стоимость заказа при изменении его состава
create function update_order_amount()
returns trigger
language plpgsql
as $$
declare
    v_order_ids uuid[];
    v_order_id  uuid;
begin
    case tg_op
        when 'INSERT' then
            v_order_ids := array[new.order_id];

        when 'UPDATE' then
            v_order_ids := array[old.order_id, new.order_id];

        when 'DELETE' then
            v_order_ids := array[old.order_id];
    end case;

    for v_order_id in
        select order_id
        from shkuratetskiy_food."order"
        where order_id = any(v_order_ids)
        order by order_id
        for no key update
    loop
        update shkuratetskiy_food."order"
        set order_amount = (
            select coalesce(sum(quantity * price), 0)
            from shkuratetskiy_food.order_structure
            where order_id = v_order_id
        )
        where order_id = v_order_id;
    end loop;

    return null;
end;
$$;

-- Сверяет сумму попытки оплаты с общей суммой заказа
create function check_payment_amount()
returns trigger
language plpgsql
as $$
declare
    v_total_amount numeric;
begin
    case tg_table_name

        when 'payment' then

            if tg_op = 'UPDATE' then
                if old.amount = new.amount
                   and old.order_id = new.order_id
                   and new.status != 'успех' then
                    return new;
                end if;
            end if;

            select total_amount
            into v_total_amount
            from shkuratetskiy_food."order"
            where order_id = new.order_id
            for no key update;

            if not found then
                raise exception
                    'Заказ % не существует', new.order_id
                    using errcode = '23503';
            end if;

            if new.amount is distinct from v_total_amount then
                raise exception
                    'Сумма оплаты (%) не соответствует общей сумме заказа (%)',
                    new.amount, v_total_amount
                    using errcode = '23514';
            end if;

        when 'order' then

            -- Проверяет только успешные попытки оплаты при изменении суммы заказа
            if exists (
                select 1
                from shkuratetskiy_food.payment
                where order_id = new.order_id
                  and status = 'успех'
                  and amount is distinct from new.total_amount
            ) then
                raise exception
                    'Невозможно изменить сумму заказа %: существует успешная попытка оплаты',
                    new.order_id
                    using errcode = '23514';
            end if;

    end case;

    return new;
end;
$$;

-- Вычисляет статус оплаты заказа по попыткам оплаты
create function update_order_pay_status()
returns trigger
language plpgsql
as $$
declare
    v_order_ids  uuid[];
    v_order_id   uuid;
    v_pay_status shkuratetskiy_food.pay_status;
begin
    case tg_op
        when 'INSERT' then
            v_order_ids := array[new.order_id];

        when 'UPDATE' then
            v_order_ids := array[old.order_id, new.order_id];

        when 'DELETE' then
            v_order_ids := array[old.order_id];
    end case;

    for v_order_id in
        select order_id
        from shkuratetskiy_food."order"
        where order_id = any(v_order_ids)
        order by order_id
        for no key update
    loop
        select case
            when bool_or(status = 'успех') then 'оплачен'
            when bool_or(status = 'в_обработке') then 'ожидает'
            when count(*) = 0 then 'ожидает'
            else 'ошибка'
        end::shkuratetskiy_food.pay_status
        into v_pay_status
        from shkuratetskiy_food.payment
        where order_id = v_order_id;

        update shkuratetskiy_food."order"
        set pay_status = v_pay_status
        where order_id = v_order_id
          and pay_status is distinct from v_pay_status;
    end loop;

    return null;
end;
$$;

-- Проверяет, что объект отзыва относится к заказу клиента
create function check_review_entity()
returns trigger
language plpgsql
as $$
declare
    v_restaurant_id uuid;
begin
    case tg_table_name

        -- Проверяет объект при добавлении или изменении отзыва
        when 'review' then

            select restaurant_id
            into v_restaurant_id
            from shkuratetskiy_food."order"
            where order_id = new.order_id
            for share;

            if not found then
                raise exception
                    'Заказ % не существует', new.order_id
                    using errcode = '23503';
            end if;

            case new.entity_type

                when 'блюдо' then

                    perform 1
                    from shkuratetskiy_food.order_structure
                    where order_id = new.order_id
                      and product_id = new.entity_id
                    for share;

                    if not found then
                        raise exception
                            'Блюдо % отсутствует в заказе %',
                            new.entity_id, new.order_id
                            using errcode = '23514';
                    end if;

                when 'ресторан' then

                    if new.entity_id is distinct from v_restaurant_id then
                        raise exception
                            'Ресторан % не соответствует ресторану заказа %',
                            new.entity_id, new.order_id
                            using errcode = '23514';
                    end if;

                when 'заказ' then

                    if new.entity_id is distinct from new.order_id then
                        raise exception
                            'Идентификатор объекта отзыва не соответствует заказу %',
                            new.order_id
                            using errcode = '23514';
                    end if;

            end case;

        -- Защищает блюдо с отзывом при удалении или изменении позиции
        when 'order_structure' then

            if tg_op = 'UPDATE' then
                if old.order_id = new.order_id
                   and old.product_id = new.product_id then
                    return new;
                end if;
            end if;

            if exists (
                select 1
                from shkuratetskiy_food.review
                where order_id = old.order_id
                  and entity_id = old.product_id
                  and entity_type = 'блюдо'
            ) then
                raise exception
                    'Невозможно удалить или заменить блюдо % в заказе %: существует отзыв',
                    old.product_id, old.order_id
                    using errcode = '23514';
            end if;

            if tg_op = 'DELETE' then
                return old;
            end if;

        -- Проверяет отзывы на ресторан при смене ресторана заказа
        when 'order' then

            if exists (
                select 1
                from shkuratetskiy_food.review
                where order_id = old.order_id
                  and entity_type = 'ресторан'
                  and entity_id is distinct from new.restaurant_id
            ) then
                raise exception
                    'Невозможно изменить ресторан заказа %: существует отзыв на ресторан',
                    old.order_id
                    using errcode = '23514';
            end if;

    end case;

    return new;
end;
$$;

-- Проверяет соответствие количества единице измерения блюда
create function check_product_quantity()
returns trigger
language plpgsql
as $$
declare
    v_measure_unit shkuratetskiy_food.measure_unit;
begin
    case tg_table_name

        when 'order_structure' then

            select measure_unit
            into v_measure_unit
            from shkuratetskiy_food.product
            where product_id = new.product_id
            for share;

            if v_measure_unit = 'шт'
                and new.quantity <> trunc(new.quantity)
            then
                raise exception
                    'Количество штучного блюда должно быть целым'
                    using errcode = '23514';
            end if;

        when 'product' then

            if new.measure_unit = 'шт'
                and exists (
                    select 1
                    from shkuratetskiy_food.order_structure
                    where product_id = old.product_id
                      and quantity <> trunc(quantity)
                )
            then
                raise exception
                    'Невозможно изменить единицу измерения: существуют дробные позиции заказа'
                    using errcode = '23514';
            end if;

    end case;

    return new;
end;
$$;


-- ТРИГГЕРЫ

create trigger trg_order_structure_check_restaurant
    before insert or update of order_id, product_id
    on order_structure
    for each row
    execute function check_order_product_restaurant();

create trigger trg_product_check_restaurant
    before update of restaurant_id
    on product
    for each row
    when (old.restaurant_id is distinct from new.restaurant_id)
    execute function check_order_product_restaurant();

create trigger trg_order_check_restaurant
    before update of restaurant_id
    on "order"
    for each row
    when (old.restaurant_id is distinct from new.restaurant_id)
    execute function check_order_product_restaurant();

create trigger trg_update_order_amount
    after insert or update or delete
    on order_structure
    for each row
    execute function update_order_amount();

create trigger trg_payment_check_amount
    before insert or update of amount, order_id, status
    on payment
    for each row
    execute function check_payment_amount();

create trigger trg_order_check_payment_amount
    after update of order_amount
    on "order"
    for each row
    when (old.total_amount is distinct from new.total_amount)
    execute function check_payment_amount();

create trigger trg_update_order_pay_status
    after insert or update of status, order_id or delete
    on payment
    for each row
    execute function update_order_pay_status();

create trigger trg_check_review_entity
    before insert or update of entity_id, entity_type, order_id
    on review
    for each row
    execute function check_review_entity();

create trigger trg_order_structure_check_review
    before delete or update of order_id, product_id
    on order_structure
    for each row
    execute function check_review_entity();

create trigger trg_order_check_review
    before update of restaurant_id
    on "order"
    for each row
    when (old.restaurant_id is distinct from new.restaurant_id)
    execute function check_review_entity();

create trigger trg_order_structure_check_quantity
    before insert or update of product_id, quantity
    on order_structure
    for each row
    execute function check_product_quantity();

create trigger trg_product_check_measure_unit
    before update of measure_unit
    on product
    for each row
    when (old.measure_unit is distinct from new.measure_unit)
    execute function check_product_quantity();


commit;
