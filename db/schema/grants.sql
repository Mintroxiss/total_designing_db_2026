begin;

do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'inspector') then
        create role inspector login password 'NetoSQL2025';
    else
        alter role inspector login password 'NetoSQL2025';
    end if;

    execute format('grant connect on database %I to inspector', current_database());
end $$;

alter role inspector set search_path = shkuratetskiy_food, exts;

grant all privileges on schema shkuratetskiy_food to inspector;
grant all privileges on all tables    in schema shkuratetskiy_food to inspector;
grant all privileges on all sequences in schema shkuratetskiy_food to inspector;
grant all privileges on all routines  in schema shkuratetskiy_food to inspector;

alter default privileges in schema shkuratetskiy_food grant all privileges on tables    to inspector;
alter default privileges in schema shkuratetskiy_food grant all privileges on sequences to inspector;
alter default privileges in schema shkuratetskiy_food grant all privileges on routines  to inspector;

grant usage   on schema exts to inspector;
grant execute on all functions in schema exts to inspector;

grant usage on schema information_schema, pg_catalog to inspector;

commit;