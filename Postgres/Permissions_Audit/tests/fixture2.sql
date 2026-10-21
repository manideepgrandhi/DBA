-- Second test "server" (another local cluster): minimal, clean setup
DROP DATABASE IF EXISTS billing;
DROP ROLE IF EXISTS audit_user; DROP ROLE IF EXISTS rds_superuser; DROP ROLE IF EXISTS bill_ro;
CREATE ROLE rds_superuser NOLOGIN; CREATE ROLE audit_user LOGIN PASSWORD 'test-only-audit' IN ROLE rds_superuser;
CREATE ROLE bill_ro NOLOGIN;
CREATE DATABASE billing; \c billing
REVOKE CREATE ON SCHEMA public FROM PUBLIC; CREATE SCHEMA inv; CREATE TABLE inv.invoices(id int);
GRANT USAGE ON SCHEMA inv TO bill_ro; GRANT SELECT ON inv.invoices TO bill_ro;
