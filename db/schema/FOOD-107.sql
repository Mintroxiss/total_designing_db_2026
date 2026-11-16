create procedure shkuratetskiy_food.courier_salary()
language plpgsql
set search_path = shkuratetskiy_food, exts
as $$
declare
    ms date := date_trunc('month', localtimestamp)::date;   -- начало текущего месяца
    me date := (date_trunc('month', localtimestamp) + interval '1 month')::date; -- начало следующего
begin
    with stat as (
        select c.courier_id,
               c.coefficient,
               count(o.order_id)                as cnt,
               coalesce(sum(o.commission), 0)   as comm
        from courier c
        left join "order" o on o.courier_id = c.courier_id
                           and o.status = 'доставлен'
                           and o.delivery_timestamp >= ms
                           and o.delivery_timestamp <  me
        where c.dismissal_date is null or c.dismissal_date >= ms
        group by c.courier_id, c.coefficient
    ), pay as (
        insert into courier_pay(year, month, courier_id, amount, coefficient_used)
        select extract(year  from ms)::int,
               extract(month from ms)::int,
               s.courier_id,
               round(coalesce(cp.coefficient_used, s.coefficient) * s.comm, 2),
               coalesce(cp.coefficient_used, s.coefficient)
        from stat s
        left join courier_pay cp on cp.courier_id = s.courier_id
                                and cp.year  = extract(year  from ms)::int
                                and cp.month = extract(month from ms)::int
        on conflict (year, month, courier_id) do update
            set amount           = excluded.amount,
                coefficient_used = excluded.coefficient_used
        returning courier_id
    )

    update courier c
       set coefficient = case when s.cnt <= 150 then 0.1
                              when s.cnt <= 250 then 0.2
                              when s.cnt <= 500 then 0.3
                              else 0.5 end
      from stat s
     where c.courier_id = s.courier_id
       and c.status != 'уволен'
       and c.coefficient is distinct from case when s.cnt <= 150 then 0.1
                                               when s.cnt <= 250 then 0.2
                                               when s.cnt <= 500 then 0.3
                                               else 0.5 end;
end;
$$;