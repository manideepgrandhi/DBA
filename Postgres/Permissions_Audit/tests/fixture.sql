-- Test fixture (local PostgreSQL only). Creates roles/schemas/objects that exercise every audit section + risk flag.
-- Run as a superuser:  psql -X -v ON_ERROR_STOP=1 -f tests/fixture.sql
DROP DATABASE IF EXISTS appdb;  DROP DATABASE IF EXISTS salesdb;
DO $$ DECLARE r text; BEGIN
  FOREACH r IN ARRAY ARRAY['audit_user','app_owner','app_reader','app_writer','app_user','alice','bob','carol','legacy_grp','rds_superuser','svc_etl','expired_u']
  LOOP IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN EXECUTE format('DROP OWNED BY %I CASCADE', r); END IF; END LOOP; END $$;
DROP ROLE IF EXISTS audit_user, alice, bob, carol, svc_etl, expired_u, app_user, app_writer, app_reader, app_owner, legacy_grp, rds_superuser;
CREATE ROLE rds_superuser NOLOGIN CREATEROLE CREATEDB;          -- stand-in for the Aurora role
CREATE ROLE audit_user LOGIN PASSWORD 'test-only-audit' IN ROLE rds_superuser;
CREATE ROLE app_owner NOLOGIN; CREATE ROLE app_reader NOLOGIN; CREATE ROLE app_writer NOLOGIN IN ROLE app_reader;
CREATE ROLE app_user NOLOGIN IN ROLE app_writer; CREATE ROLE legacy_grp NOLOGIN;
CREATE ROLE alice LOGIN PASSWORD 'x' VALID UNTIL '2099-01-01' IN ROLE app_user;
CREATE ROLE bob LOGIN PASSWORD 'x' IN ROLE app_reader CONNECTION LIMIT 5;
CREATE ROLE carol LOGIN PASSWORD 'x' IN ROLE rds_superuser;
CREATE ROLE svc_etl LOGIN PASSWORD 'x' NOINHERIT IN ROLE app_writer;
CREATE ROLE expired_u LOGIN PASSWORD 'x' VALID UNTIL '2020-01-01';
CREATE DATABASE appdb OWNER app_owner; CREATE DATABASE salesdb;
REVOKE ALL ON DATABASE salesdb FROM PUBLIC; GRANT CONNECT ON DATABASE salesdb TO app_reader, audit_user;
GRANT CREATE, TEMP ON DATABASE appdb TO bob;
\c appdb
GRANT CREATE ON SCHEMA public TO PUBLIC;            -- flag: PUBLIC CREATE on public
CREATE SCHEMA sales AUTHORIZATION app_owner; CREATE SCHEMA hr AUTHORIZATION alice; CREATE SCHEMA "Odd Name" AUTHORIZATION app_owner;
GRANT USAGE ON SCHEMA sales TO app_reader; GRANT CREATE ON SCHEMA sales TO app_writer WITH GRANT OPTION;
GRANT USAGE ON SCHEMA hr TO bob;
SET ROLE app_owner;
CREATE TABLE sales.orders(id int primary key, amount numeric, card text);
CREATE SEQUENCE sales.ord_seq; CREATE VIEW sales.v_orders AS SELECT id, amount FROM sales.orders;
CREATE MATERIALIZED VIEW sales.mv_tot AS SELECT sum(amount) s FROM sales.orders;
CREATE TABLE sales.parted(id int, d date) PARTITION BY RANGE (d);
CREATE TABLE sales.parted_2026 PARTITION OF sales.parted FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE FUNCTION sales.f_total() RETURNS numeric LANGUAGE sql AS 'SELECT sum(amount) FROM sales.orders';
CREATE FUNCTION sales.f_secdef(i int) RETURNS int LANGUAGE sql SECURITY DEFINER AS 'SELECT i';
CREATE PROCEDURE sales.p_purge() LANGUAGE sql AS 'DELETE FROM sales.orders WHERE false';
CREATE TABLE "Odd Name"."we|ird,tab""le"(x int);
ALTER DEFAULT PRIVILEGES IN SCHEMA sales GRANT SELECT ON TABLES TO app_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA sales GRANT INSERT, UPDATE, DELETE ON TABLES TO app_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA sales GRANT USAGE, SELECT ON SEQUENCES TO app_writer;
ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO app_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA sales GRANT SELECT ON TABLES TO bob;   -- flag: default priv direct to login
RESET ROLE;
GRANT SELECT ON sales.orders, sales.v_orders, sales.mv_tot TO app_reader;
GRANT INSERT, UPDATE, DELETE ON sales.orders TO app_writer;
GRANT USAGE ON SEQUENCE sales.ord_seq TO app_writer;
GRANT SELECT ON sales.orders TO bob WITH GRANT OPTION;    -- flags: direct to login + grant option
GRANT SELECT ON sales.v_orders TO PUBLIC;                  -- flag: PUBLIC object priv
GRANT SELECT (id, amount) ON sales.orders TO carol;        -- column grant
GRANT UPDATE (card) ON sales.orders TO svc_etl;
REVOKE EXECUTE ON FUNCTION sales.f_total() FROM PUBLIC; GRANT EXECUTE ON FUNCTION sales.f_total() TO app_user;
GRANT EXECUTE ON PROCEDURE sales.p_purge() TO app_writer;
SET ROLE alice; CREATE TABLE hr.salaries(emp int, pay numeric); RESET ROLE;   -- flag: owned by login user
GRANT SELECT ON hr.salaries TO bob;
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
CREATE SERVER remote_sales FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host '127.0.0.1', dbname 'salesdb');
GRANT USAGE ON FOREIGN SERVER remote_sales TO app_owner;
CREATE USER MAPPING FOR app_owner SERVER remote_sales OPTIONS (user 'app_owner', password 'fixture-only');
CREATE USER MAPPING FOR PUBLIC SERVER remote_sales;
CREATE FOREIGN TABLE sales.ft_remote(id int) SERVER remote_sales OPTIONS (table_name 'x');
ALTER FOREIGN TABLE sales.ft_remote OWNER TO app_owner;
GRANT SELECT ON sales.ft_remote TO app_reader;
\c salesdb
CREATE SCHEMA crm; CREATE TABLE crm.accounts(id int); GRANT USAGE ON SCHEMA crm TO app_reader; GRANT SELECT ON crm.accounts TO app_reader;
