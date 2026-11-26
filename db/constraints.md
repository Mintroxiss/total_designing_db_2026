# Обоснование ограничений

## Enum-типы

| Тип | Значения | BR |
|---|---|---|
| payment_type | 'карта', 'наличные', 'безнал' | 8.2 |
| payment_status | 'успех', 'ошибка', 'в_обработке' | 8.2 |
| restaurant_status | 'активен', 'неактивен' | 4.3 |
| product_status | 'доступно', 'нет_в_наличии', 'архив' | 5.5 |
| courier_status | 'свободен', 'занят', 'на_доставке', 'уволен' | 6.2 |
| order_status | 'создан', 'готовится', 'в_доставке', 'доставлен', 'отменён' | 7.7 |
| entity_type | 'блюдо', 'ресторан', 'заказ' | 9.1 |
| pay_status | 'ожидает', 'оплачен', 'ошибка' | 7.8, 7.9, 8.7 |
| measure_unit | 'шт', 'кг', 'л' | 7.15 |

---

## Ловушки

### Ловушка 1: `payment` — неполная сущность

**Какие атрибуты добавил в `payment` и почему** (BR-1.7, BR-8.1, BR-8.2, BR-8.5, BR-8.6):

| Атрибут | Тип данных | Описание | Добавил, поскольку предполагается в... |
|---|---|---|---|
| payment_type | enum | тип оплаты | BR-8.2, BR-8.6 |
| amount | numeric | отправляемая клиентом сумма | BR-8.2, BR-8.4 |
| transaction_id | varchar | идентификатор финансовой транзакции | BR-1.7, BR-8.2, BR-8.3, BR-8.5 |
| transaction_timestamp | timestamp | дата и время транзакции | BR-8.2 |
| status | enum | статус оплаты | BR-8.2, BR-8.1 |

**Где хранится тип оплаты — `payment` или `order`** (BR-8.6):

```
Тип оплаты хранится в "payment", поскольку по "BR-8.6" у заказа может быть несколько попыток с разными типами. Это удобнее, чем создавать массив в "order".
```

### Ловушка 2: `order.address_id` — принадлежность клиенту (BR-7.4)

**Как обеспечено, что адрес доставки принадлежит клиенту:**

```
Было решено обеспечить принадлежность адреса клиенту в "order" через создание первичного ключа "client_address_id" в таблице "client_address" (не забыв добавить требование по уникальности связки атрибутов "client_id" и "address_id"). Убрал из "order" атрибуты "client_id" и "address_id", добавил "client_address_id".
```

### Ловушка 3: `order_structure` — один ресторан в заказе (BR-7.3)

**Как обеспечено, что все блюда из `order.restaurant_id`:**

```
Было решено обеспечить принадлежность всех блюд заказа одному ресторану через проверку соответствия "product.restaurant_id" и "order.restaurant_id". Проверка должна выполняться при добавлении и изменении позиции заказа, а также при изменении ресторана блюда или заказа. Поскольку ограничение зависит от данных нескольких таблиц, была реализована триггерная проверка. Это позволяет обеспечить BR-7.3 без дублирования атрибута restaurant_id в order_structure.
```

### Ловушка 4: `review` — полиморфизм (BR-9.1)

**Как реализована валидность `review.entity_id`:**

```
Было решено сохранить единую таблицу review с полиморфной ссылкой на объект отзыва. Поскольку entity_id может ссылаться на записи разных таблиц, обычный внешний ключ для данного атрибута не используется. Целостность обеспечивается триггерной функцией check_review_entity(), которая гарантирует, что:
- 'блюдо': блюдо с указанным entity_id присутствует в составе заказа
- 'ресторан': entity_id совпадает с restaurant_id заказа
- 'заказ': entity_id совпадает с order_id отзыва
```

---

## CHECK-ограничения

| Таблица | Столбец | Условие | BR | Обоснование |
|---|---|---|---|---|
| order | total_amount | status in ('создан', 'отменён') or total_amount >= 1000 | 1.8, 7.11 | минимальная сумма сформированного заказа составляет 1000 руб |
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
| courier | - | (status = 'уволен') = (dismissal_date is not null) | 6.3 | уволенный курьер имеет дату увольнения, работающий - нет |
| client | phone_number | phone_number ~ '^\+79\d{9}$' | - | формат мобильного номера РФ |
| courier | phone_number | phone_number ~ '^\+79\d{9}$' | - | формат мобильного номера РФ |
| courier_pay | year | year >= 2026 | - | год выплаты не может быть раньше, чем год старта сервиса |
| courier_pay | month | month between 1 and 12 | - | в году 12 месяцев |
| courier_pay | - | make_date(year, month, 1) <= current_date | - | нельзя создать запись об оплате позже текущей даты |
| courier_pay | coefficient_used | coefficient_used between 0.1 and 0.5 | 6.4, 10.2 | допустимый диапазон применённого коэффициента |
| order_structure | price | price >= 0 | 5.3 | цена блюда на момент оформления заказа неотрицательна |
| order | courier_id | courier_id is not null or status in ('создан','готовится','отменён') | 1.3, 7.5 | для выполнения доставки необходимо назначить курьера |
| client | password | password ~ '^[0-9a-f]{32}$' | 2.3 | проверка формата MD5 |
| courier | - | dismissal_date is null or hire_date <= dismissal_date | - | дата увольнения не может быть раньше даты найма |
| order | - | status != 'доставлен' or pay_status = 'оплачен' | 1.5, 8.1, 8.6 | нельзя доставить неоплаченный заказ |
| payment | amount | amount >= 1000 | 7.11, 8.4 | сумма попытки оплаты не может быть меньше минимальной суммы заказа |
| client | login | login ~ '^[a-z][a-z0-9_]{2,49}$' | - | логин должен начинаться с буквы и содержать от 3 до 50 символов |
| order | order_amount | order_amount >= 0 | 5.3, 7.10 | стоимость блюд в заказе не может быть отрицательной |


---

## UNIQUE-ограничения

| Таблица | Столбцы | BR | Обоснование |
|---|---|---|---|
| client | login | 2.2, 2.6 | атрибут, по которому идентифицируется пользователь |
| client | phone_number | 2.2, 2.6 | атрибут, по которому идентифицируется пользователь |
| restaurant | address_id | 3.3, 3.4 | рестораны не могут находиться по одному адресу |
| payment | transaction_id | 8.3 | идентификатор внешней транзакции всегда уникален |
| courier_pay | courier_id, year, month | 10.3 | не более одной записи о зарплате курьера за месяц |
| client_address | client_id, address_id | 2.5 | один адрес нельзя привязать к клиенту дважды |
| payment | order_id where status = 'успех' | 8.1 | не более одной успешной попытки оплаты заказа |
| review | order_id, entity_type, entity_id | 9.5 | в рамках одного заказа нельзя оставить несколько отзывов на один объект |
| address | street, house_number, apartment_office | 3.3, 3.4 | один физический адрес не должен быть представлен несколькими записями |

---

## FK-ограничения

| Таблица | Столбцы | → Таблица | BR | Обоснование |
|---|---|---|---|---|
| order | client_address_id | client_address | 7.2, 7.4 | заказ должен быть строго с адресом клиента |
| client_address | client_id | client | 2.4 | адрес привязывается к существующему клиенту |
| client_address | address_id | address | 2.4 | к клиенту привязывается существующий адрес |
| restaurant | address_id | address | 3.3 | у ресторана ровно один существующий адрес |
| product | product_category_id | product_category | 5.1 | блюдо принадлежит ровно одной категории |
| product | restaurant_id | restaurant | 5.1 | блюдо принадлежит ровно одному ресторану |
| courier_pay | courier_id | courier | 10.2 | зарплата начисляется существующему курьеру |
| order | courier_id | courier | 7.5 | доставку выполняет существующий курьер |
| order | restaurant_id | restaurant | 7.2 | заказ привязан к существующему ресторану |
| payment | order_id | order | 8.1 | попытка оплаты относится к существующему заказу |
| order_structure | order_id | order | 7.14 | позиция принадлежит существующему заказу |
| order_structure | product_id | product | 7.14 | позиция ссылается на существующее блюдо |
| review | order_id | order | 9.2 | отзыв всегда связан с существующим заказом |

---

## NOT NULL (только бизнес-обязательные)

| Таблица | Столбец | BR | Обоснование |
|---|---|---|---|
| order | status | 7.12 | `check` на delivery_timestamp строится на status |
| courier | status | 6.3 | `check` на dismissal_date строится на status |

---

## NULL (осознанно разрешено)

| Таблица | Столбец | BR | Почему NULL |
|---|---|---|---|
| address | apartment_office | 3.2 | бывают частные дома и отдельные входы, где указывать нечего |
| product | photo_url | 5.6 | фотография блюда необязательна |
| courier | dismissal_date | 6.3 | работающий курьер не имеет даты увольнения |
| order | delivery_timestamp | 7.12 | до получения заказа время доставки не фиксируется |
| review | photo_url | 9.3 | фотография отзыва необязательна |
| restaurant | rating | 9.7 | без отзывов null-значение по BR |
| product | rating | 9.7 | без отзывов null-значение по BR |
| order | courier_id | 7.5 | курьер может быть не назначен до начала доставки |
| order | description | - | клиент может не оставлять комментарий к заказу |
| client | deleted_at | 3.5 | null означает, что клиент не удалён |
| restaurant | deleted_at | 3.5 | null означает, что ресторан не удалён|
| order | deleted_at | - | null означает, что заказ не удалён |

---



## DEFAULT и GENERATED

| Таблица | Столбец | Значение | Обоснование |
|---|---|---|---|
| order | commission | generated always as (order_amount * 0.1) stored | значение вычисляется на основе order_amount, BR-1.4 |
| order | total_amount | generated always as (order_amount * 1.1) stored | значение вычисляется на основе order_amount, BR-7.10 |
| все таблицы с самостоятельным UUID PK | PK | default uuid_generate_v4() | BR-11.1, id генерируются на сервере |
| courier | coefficient | default 0.1 | BR-6.5, изначальный коэффициент нового курьера 0.1 |
| courier | hire_date | default current_date | BR-6.1, 6.5, дата найма фиксируется в момент создания записи о новом курьере |
| "order" | order_timestamp | default localtimestamp | BR-7.1, время создания заказа; BR-11.2, время в часовом поясе сервера |
| payment | transaction_timestamp | default localtimestamp | BR-8.2, дата и время попытки оплаты, BR-11.2 |
| review | review_timestamp | default localtimestamp | BR-9.3, дата отзыва, BR-11.2 |
| order | pay_status | default 'ожидает' | при создании заказа он ещё не оплачен |
| order | order_amount | default 0 | начальная стоимость формируемого заказа до добавления позиций |

---

## Триггеры и триггерные функции

| Триггерная функция | Триггер | BR | Обоснование |
|---|---|---|---|
| check_order_product_restaurant() | trg_order_structure_check_restaurant | 7.3 | проверка принадлежности блюда ресторану заказа |
| check_order_product_restaurant() | trg_product_check_restaurant | 7.3 | сохранение целостности состава заказов при изменении ресторана блюда |
| check_order_product_restaurant() | trg_order_check_restaurant | 7.3 | сохранение целостности состава заказа при изменении его ресторана |
| update_order_amount() | trg_update_order_amount | 7.10 | поддержание соответствия суммы заказа его составу |
| check_payment_amount() | trg_payment_check_amount | 8.4 | проверка соответствия суммы оплаты общей сумме заказа |
| check_payment_amount() | trg_order_check_payment_amount | 8.4 | сохранение соответствия общей суммы заказа сумме успешной оплаты |
| update_order_pay_status() | trg_update_order_pay_status | 7.8, 7.9, 8.7 | поддержание агрегированного статуса оплаты |
| check_review_entity() | trg_check_review_entity | 9.1, 9.2 | обеспечение целостности полиморфной связи |
| check_review_entity() | trg_order_structure_check_review | 9.2 | сохранение валидности отзывов при изменении состава заказа |
| check_review_entity() | trg_order_check_review | 9.2 | сохранение валидности отзывов при изменении ресторана заказа |
| check_product_quantity() | trg_order_structure_check_quantity | 7.15 | проверка соответствия количества блюда его единице измерения |
| check_product_quantity() | trg_product_check_measure_unit | 7.15 | сохранение допустимости количества блюда в заказах при изменении единицы измерения |

---

## Нормализация (3НФ)

Короткое обоснование, что все таблицы в 3НФ:

```
client:
- 1НФ: все атрибуты атомарны (client_id, login, password, phone_number, deleted_at); первичный ключ client_id
- 2НФ: первичный ключ простой (client_id), частичных зависимостей нет
- 3НФ: транзитивных зависимостей нет; все неключевые атрибуты зависят только от client_id

address:
- 1НФ: все атрибуты атомарны (address_id, street, house_number, apartment_office); первичный ключ address_id
- 2НФ: первичный ключ простой (address_id), частичных зависимостей нет
- 3НФ: транзитивных зависимостей нет

client_address:
- 1НФ: все атрибуты атомарны (client_address_id, client_id, address_id); первичный ключ client_address_id
- 2НФ: неключевых атрибутов нет, частичных зависимостей быть не может
- 3НФ: неключевых атрибутов нет, транзитивных зависимостей нет; client_id и address_id - внешние ключи

restaurant:
- 1НФ: атомарные атрибуты (restaurant_id, restaurant_name, address_id, description, work_start, work_end, inn, ogrn, bank_account, rating, status, deleted_at); первичный ключ restaurant_id
- 2НФ: первичный ключ простой (restaurant_id), частичных зависимостей нет
- 3НФ: транзитивных зависимостей нет; address_id - внешний ключ

courier:
- 1НФ: все атрибуты атомарны (courier_id, last_name, first_name, middle_name, phone_number, status, hire_date, dismissal_date, coefficient); первичный ключ courier_id
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
- 1НФ: все атрибуты атомарны (order_id, courier_id, client_address_id, restaurant_id, order_timestamp, delivery_timestamp, order_amount, commission, total_amount, status, pay_status, description, deleted_at); первичный ключ order_id
- 2НФ: первичный ключ простой (order_id), частичных зависимостей нет
- 3НФ: транзитивные зависимости есть:  commission и total_amount зависят от order_amount, но это особенный случай; courier_id, client_address_id, restaurant_id - внешние ключи

payment:
- 1НФ: все атрибуты атомарны (payment_id, order_id, payment_type, amount, transaction_id, transaction_timestamp, status); первичный ключ payment_id
- 2НФ: первичный ключ простой (payment_id), частичных зависимостей нет
- 3НФ: транзитивных зависимостей нет; order_id - внешний ключ

order_structure:
- 1НФ: все атрибуты атомарны (order_id, product_id, quantity, price); составной первичный ключ (order_id, product_id)
- 2НФ: неключевые атрибуты quantity и price полностью зависят от всего составного ключа (order_id, product_id), частичных зависимостей нет
- 3НФ: неключевые атрибуты зависят только от первичного ключа, транзитивных зависимостей нет; order_id и product_id - внешние ключи

review:
- 1НФ: все атрибуты атомарны (review_id, review_timestamp, entity_id, entity_type, order_id, description, photo_url, rating); первичный ключ review_id
- 2НФ: первичный ключ простой (review_id), частичных зависимостей нет
- 3НФ: транзитивных зависимостей нет; order_id - внешний ключ; есть полиморфная связь через entity_id и entity_type

Особые случаи:
- order.commission и order.total_amount зависят от order.order_amount, но они генерируются автоматически из этого значения, следовательно нарушение обосновано
- product.rating и restaurant.rating — агрегируемые атрибуты, рассчитываемые на основании оценок из таблиц отзывов. Их хранение в таблицах product и restaurant является осознанной денормализацией для ускорения чтения и сортировки товаров/ресторанов по рейтингу. Актуальность значений поддерживается триггером, автоматически обновляющим рейтинг при изменении отзывов
- order.pay_status вычисляется по попыткам оплаты (BR-8.7), хранится как агрегат для скорости чтения и обновляется триггером
- order.order_amount агрегирует стоимость позиций (BR-7.10)
- review.entity_id и review.entity_type образуют полиморфную связь. Данное решение само не нарушает 3НФ, но требует дополнительной проверки ссылочной целостности
```
