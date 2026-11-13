# Обоснование ограничений

## Enum-типы

| Тип | Значения | BR |
|---|---|---|
| payment_type | 'карта', 'наличные', 'безнал' | 8.2 |
| transaction_status | 'успех', 'ошибка', 'в_обработке' | 7.9, 8.2 |
| restaurant_status | 'активен', 'неактивен' | 4.3 |
| product_status | 'доступно', 'нет_в_наличии', 'архив' | 5.5 |
| courier_status | 'свободен', 'занят', 'на_доставке', 'уволен' | 6.2 |
| order_status | 'создан', 'готовится', 'в_доставке', 'доставлен', 'отменён' | 7.7 |
| review_entity_type | 'блюдо', 'ресторан', 'заказ' | 9.1 |
| measure_unit | 'шт', 'кг', 'л' | - |

---

## Ловушки

### Ловушка 1: `payment` — неполная сущность

**Какие атрибуты добавил в `payment` и почему** (BR-1.7, BR-8.1, BR-8.2, BR-8.5, BR-8.6):

| Атрибут | Тип данных | Описание | Добавил, поскольку предполагается в... |
|---|---|---|---|
| payment_type | enum | тип оплаты | BR-8.2, BR-8.6 |
| amount | numeric | отправляемая клиентом сумма | BR-8.2 |
| transaction_id | varchar | идентификатор финансовой транзакции | BR-1.7, BR-8.2, BR-8.5 |
| transaction_timestamp | timestamp | дата и время транзакции | BR-8.2 |
| status | enum | статус оплаты | BR-8.2, BR-8.1 |

**Где хранится тип оплаты — `payment` или `order`** (BR-8.6):

```
Тип оплаты хранится в "payment", поскольку по "BR-8.6" у заказа может быть несколько попыток с разными типами. Это удобнее, чем создавать массив в "order".
```

### Ловушка 2: `order.address_id` — принадлежность клиенту (BR-7.4)

**Как обеспечено, что адрес доставки принадлежит клиенту:**

```
Было решено обеспечить принадлежность адреса клиенту в "order" через составной FK. Убрал связь с "client" и добавил связь с "client_address".
```

### Ловушка 3: `order_structure` — один ресторан в заказе (BR-7.3)

**Как обеспечено, что все блюда из `order.restaurant_id`:**

```
[что сделал + почему]
```

### Ловушка 4: `review` — полиморфизм (BR-9.1)

**Как реализована валидность `review.entity_id`:**

```
Выполнил нормализацию, поскольку это обеспечивает ссылочную целостность, позволяет добавлять дополнительные атрибуты конкретному типу по нужде, легко расширять добавлением новой сущности.
Какие действия совершены:
1. Создал сущности `product_review`, `restaurant_review`, `order_review`
2. Добавил в сущности первичный+внешний ключ `review_id`
3. На схеме указал связь "1 к 1" между `review` и созданными сущностями
4. Добавил в `product_review` атрибут `product_id`, который является внешним ключом к `product`
5. Добавил в `restaurant_review` атрибут `restaurant_id`, который является внешним ключом к `restaurant`
В `order_review` избыточно добавлять `order_id`, он содержится в `review`
```

---

## CHECK-ограничения

| Таблица | Столбец | Условие | BR | Обоснование |
|---|---|---|---|---|
| order | order_amount | order_amount >= 1000 | 1.8, 7.11 | минимальная сумма заказа по BR |
| restaurant | rating | rating between 0 and 5 | 4.2 | граничные значения по BR |
| restaurant | - | work_start < work_end | 4.4 | завершить работу ресторана не начав её невозможно |
| product | price | price >= 0 | 5.3 | цена блюда не может быть отрицательной |
| product | rating | rating between 0 and 5 | 5.4 | граничные значения по BR |
| courier | coefficient | coefficient between 0.1 and 0.5 | 6.4 | граничные значения по BR |
| order | - | (status = 'доставлен' and delivery_timestamp is not null) or (status != 'доставлен' and delivery_timestamp is null) | 7.12 | фиксация времени доставки невозможна без завершения доставки |
| order | - | order_timestamp <= delivery_timestamp | 7.13 | невозможно завершить заказ раньше, чем он создался |
| order_structure | quantity | quantity > 0 | 7.15 | не бывает блюд с отрицательным количеством/весом |
| review | rating | rating between 1 and 5 | 9.4 | граничные значения по BR |
| courier_pay | amount | amount >= 0 | 10.4 | сумма зарплаты не может быть отрицательной |

---

## UNIQUE-ограничения

| Таблица | Столбцы | BR | Обоснование |
|---|---|---|---|
| client | login | 2.2, 2.6 | атрибут, по которому идентифицируется пользователь |
| client | phone_number | 2.2, 2.6 | атрибут, по которому идентифицируется пользователь |
| restaurant | address_id | 3.3, 3.4 | рестораны не могут находиться по одному адресу |
| payment | transaction_id | 8.3 | идентификатор внешней транзакции всегда уникален |
| courier_pay | courier_id, year, month | 10.3 | курьер не должен получать зарплату дважды в месяц |

Если UNIQUE частичный (с `WHERE`) — укажи условие в столбце «Столбцы» или отдельной строкой.

---

## FK-ограничения

| Таблица | Столбцы | → Таблица | BR | Обоснование |
|---|---|---|---|---|
| order | client_id, address_id | client_address | 7.4 | заказ должен быть строго с адресом клиента |


---

## NOT NULL (только бизнес-обязательные)

| Таблица | Столбец | BR | Обоснование |
|---|---|---|---|
| client | login | 2.1 | обязательный атрибут для регистрации |
| client | password | 2.1 | обязательный атрибут для регистрации |
| client | phone_number | 2.1 | обязательный атрибут для регистрации |
| review | order_id | 9.2 | отзывы может писать клиент только к тому, что заказывал |
| review | description | 9.3 | отзыв по BR невозможен без текста |
| review | rating | 9.3 | не бывает отзывов без рейтинга |
| review | review_timestamp | 9.3 | полезная метрика для клиента, читающего отзыв |

---

## NULL (осознанно разрешено)

| Таблица | Столбец | BR | Почему NULL |
|---|---|---|---|
| address | apartment_office | 3.2 | бывают частные дома и отдельные входы, где указывать нечего |
| product | photo_url | 5.6 | фотография для чая, например, может быть избыточна |
| courier | dismissal_date | 6.3 | работающий курьер не имеет даты увольнения |
| order | delivery_timestamp | 7.12 | до получения заказа время доставки не фиксируется |
| review | photo_url | 9.3 | текстовых отзывов обычно достаточно |

---

## DEFAULT и GENERATED

| Таблица | Столбец | Значение | Обоснование |
|---|---|---|---|
| order | comission | generated always as (order_amount * 0.1) stored | значение вычисляется на основе order_amount, BR-1.4 |
| order | total_amount | generated always as (order_amount + comission) stored | значение вычисляется на основе order_amount и comission, BR-1.4 |
| courier | coefficient | 0.1 | по BR-6.5 |

---

## Нормализация (3НФ)

Короткое обоснование, что все таблицы в 3НФ:

```
client:
- 1НФ: все атрибуты атомарны (client_id, login, password, phone_number); первичный ключ client_id
- 2НФ: первичный ключ простой (client_id), частичных зависимостей нет
- 3НФ: транзитивных зависимостей нет; все неключевые атрибуты зависят только от client_id

address:
- 1НФ: все атрибуты атомарны (address_id, street, house_number, apartment_office); первичный ключ address_id
- 2НФ: первичный ключ простой (address_id), частичных зависимостей нет
- 3НФ: транзитивных зависимостей нет

client_address:
- 1НФ: все атрибуты атомарны (client_id, address_id); составной первичный ключ (client_id, address_id)
- 2НФ: неключевых атрибутов нет, частичных зависимостей быть не может
- 3НФ: неключевых атрибутов нет, транзитивных зависимостей нет

restaurant:
- 1НФ: атомарные атрибуты (restaurant_id, restaurant_name, address_id, description, work_start, work_end, rating, status); имеется неатомарный атрибут company_details, об этом особенном случае ниже; первичный ключ restaurant_id
- 2НФ: первичный ключ простой (restaurant_id), частичных зависимостей нет
- 3НФ: транзитивных зависимостей нет; address_id - внешний ключ

restaurant_payout:
- 1НФ: все атрибуты атомарны (payout_id, order_id, amount, payout_timestamp, transaction_id, status); первичный ключ payout_id
- 2НФ: первичный ключ простой (payout_id), частичных зависимостей нет
- 3НФ: транзитивных зависимостей нет; order_id - внешний ключ

courier:
- 1НФ: все атрибуты атомарны (courier_id, full_name, phone_number, status, hire_date, dismissal_date, coefficient); первичный ключ courier_id
- 2НФ: первичный ключ простой (courier_id), частичных зависимостей нет
- 3НФ: транзитивных зависимостей нет

courier_pay:
- 1НФ: все атрибуты атомарны (courier_pay_id, year, month, courier_id, amount, coefficient_used); первичный ключ courier_pay_id
- 2НФ: первичный ключ простой (courier_pay_id), частичных зависимостей нет
- 3НФ: транзитивных зависимостей нет; courier_id - внешний ключ

product_category:
- 1НФ: все атрибуты атомарны (product_category_id, product_category_name); первичный ключ product_category_id
- 2НФ: первичный ключ простой (product_category_id), частичных зависимостей нет
- 3НФ: транзитивных зависимостей нет

product:
- 1НФ: все атрибуты атомарны (product_id, product_name, product_category_id, price, restaurant_id, photo_url, rating, status, description, measure_unit); первичный ключ product_id
- 2НФ: первичный ключ простой (product_id), частичных зависимостей нет
- 3НФ: транзитивных зависимостей нет; product_category_id и restaurant_id - внешние ключи

order:
- 1НФ: все атрибуты атомарны (order_id, courier_id, client_id, address_id, restaurant_id, order_timestamp, delivery_timestamp, order_amount, commission, total_amount, status, pay_status, description); первичный ключ order_id
- 2НФ: первичный ключ простой (order_id), частичных зависимостей нет
- 3НФ: транзитивные зависимости есть:  comission и total_amount зависят от order_amount, но это особенный случай; courier_id, client_id, address_id, restaurant_id - внешние ключи

payment:
- 1НФ: все атрибуты атомарны (payment_id, order_id, payment_type, amount, transaction_id, transaction_timestamp, status); первичный ключ payment_id
- 2НФ: первичный ключ простой (payment_id), частичных зависимостей нет
- 3НФ: транзитивных зависимостей нет; order_id - внешний ключ

order_structure:
- 1НФ: все атрибуты атомарны (order_id, product_id, quantity); составной первичный ключ (order_id, product_id)
- 2НФ: неключевой атрибут quantity полностью зависит от всего составного ключа (order_id, product_id), частичных зависимостей нет
- 3НФ: неключевые атрибуты зависят только от первичного ключа, транзитивных зависимостей нет; order_id и product_id - внешние ключи

review:
- 1НФ: все атрибуты атомарны (review_id, review_timestamp, order_id, description, photo_url, rating); первичный ключ review_id
- 2НФ: первичный ключ простой (review_id), частичных зависимостей нет
- 3НФ: транзитивных зависимостей нет; order_id - внешний ключ

product_review:
- 1НФ: все атрибуты атомарны (review_id, product_id); первичный ключ review_id
- 2НФ: первичный ключ простой (review_id), частичных зависимостей нет
- 3НФ: транзитивных зависимостей нет; product_id и review_id - внешние ключи

restaurant_review:
- 1НФ: все атрибуты атомарны (review_id, restaurant_id); первичный ключ review_id
- 2НФ: первичный ключ простой (review_id), частичных зависимостей нет
- 3НФ: транзитивных зависимостей нет; restaurant_id и review_id - внешние ключи

order_review:
- 1НФ: все атрибуты атомарны (review_id); первичный ключ review_id
- 2НФ: первичный ключ простой (review_id), частичных зависимостей нет
- 3НФ: неключевых атрибутов нет, транзитивных зависимостей нет; review_id - внешний ключ

Особые случаи:
- order.comission и order.total_amount зависят от order.order_amount, но они генерируются автоматически из этого значения, следовательно нарушение обосновано
- имеется неатомарный атрибут restaurant.company_details, который, по BR-4.5, содержит ИНН, ОГРН, расчётный счёт. Если учесть, что предыдущий сотрудник сделал так при реализованном бэкенде и фронтенде, предполагаю, что дробление избыточно, следовательно закрываю глаза
- product.rating и restaurant.rating — агрегируемые атрибуты, рассчитываемые на основании оценок из таблиц отзывов. Их хранение в таблицах product и restaurant является осознанной денормализацией для ускорения чтения и сортировки товаров/ресторанов по рейтингу. Актуальность значений поддерживается триггером, автоматически обновляющим рейтинг при изменении отзывов
```