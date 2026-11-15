```mermaid
erDiagram
    CLIENT {
        uuid client_id PK
        varchar login
        varchar password
        char phone_number
    }
    ADDRESS {
        uuid address_id PK
        varchar street
        varchar house_number
        varchar apartment_office
    }
    CLIENT_ADDRESS {
        uuid client_address_id PK
        uuid client_id FK
        uuid address_id FK
    }
    RESTAURANT {
        uuid restaurant_id PK
        varchar restaurant_name
        uuid address_id FK
        text description
        time work_start
        time work_end
        text company_details
        numeric rating
        enum status
    }
    RESTAURANT_PAYOUT {
    uuid payout_id PK
    uuid order_id FK
    numeric amount
    timestamp payout_timestamp
    varchar transaction_id
    enum status
    }
    COURIER {
        uuid courier_id PK
        varchar full_name
        char phone_number
        enum status
        date hire_date
        date dismissal_date
        numeric coefficient
    }
    COURIER_PAY {
        uuid courier_pay_id PK
        int year
        int month
        uuid courier_id FK
        numeric amount
        numeric coefficient_used
    }
    PRODUCT_CATEGORY {
        uuid product_category_id PK
        varchar product_category_name
    }
    PRODUCT {
        uuid product_id PK
        varchar product_name
        uuid product_category_id FK
        numeric price
        uuid restaurant_id FK
        text photo_url
        numeric rating
        enum status
        text description
        enum measure_unit
    }
    ORDER {
        uuid order_id PK
        uuid courier_id FK
        uuid client_address_id FK
        uuid restaurant_id FK
        timestamp order_timestamp
        timestamp delivery_timestamp
        numeric order_amount
        numeric commission
        numeric total_amount
        enum status
        enum pay_status
        text description
    }
    PAYMENT {
        uuid payment_id PK
        uuid order_id FK
        enum payment_type
        numeric amount
        varchar transaction_id
        timestamp transaction_timestamp
        enum status
    }
    ORDER_STRUCTURE {
        uuid order_id PK,FK
        uuid product_id PK,FK
        numeric quantity
    }
    REVIEW {
        uuid review_id PK
        timestamp review_timestamp
        uuid order_id FK
        text description
        text photo_url
        numeric rating
    }
    PRODUCT_REVIEW {
        uuid review_id PK, FK
        uuid product_id FK
    }
    RESTAURANT_REVIEW {
        uuid review_id PK, FK
        uuid restaurant_id FK
    }
    ORDER_REVIEW {
        uuid review_id PK, FK
    }

    CLIENT ||--o{ CLIENT_ADDRESS : ""
    ADDRESS ||--o{ CLIENT_ADDRESS : ""
    ADDRESS ||--o| RESTAURANT : ""
    RESTAURANT ||--o{ PRODUCT : ""
    PRODUCT_CATEGORY ||--o{ PRODUCT : ""
    COURIER ||--o{ COURIER_PAY : ""
    CLIENT_ADDRESS ||--o{ ORDER : ""
    RESTAURANT ||--o{ ORDER : ""
    COURIER ||--o{ ORDER : ""
    ORDER ||--o{ PAYMENT : ""
    ORDER ||--o{ ORDER_STRUCTURE : ""
    PRODUCT ||--o{ ORDER_STRUCTURE : ""
    ORDER ||--o{ REVIEW : ""
    REVIEW ||--|| PRODUCT_REVIEW : ""
    PRODUCT ||--o{ PRODUCT_REVIEW : ""
    REVIEW ||--|| RESTAURANT_REVIEW : ""
    RESTAURANT ||--o{ RESTAURANT_REVIEW : ""
    REVIEW ||--|| ORDER_REVIEW : ""
    ORDER ||--o{ RESTAURANT_PAYOUT : ""