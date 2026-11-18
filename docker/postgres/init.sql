-- Non-superuser application role (NO BYPASSRLS) so PostgreSQL RLS policies always apply.
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'diq_app') THEN
        CREATE ROLE diq_app WITH LOGIN PASSWORD 'diq_app_local_dev' NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
    END IF;
END
$$;

CREATE DATABASE tenant_db OWNER diq_app;
CREATE DATABASE dispute_db OWNER diq_app;
CREATE DATABASE doc_db OWNER diq_app;
CREATE DATABASE knowledge_db OWNER diq_app;
CREATE DATABASE agent_db OWNER diq_app;

\connect knowledge_db;
CREATE EXTENSION IF NOT EXISTS vector;
GRANT ALL PRIVILEGES ON SCHEMA public TO diq_app;

\connect dispute_db;
GRANT ALL PRIVILEGES ON SCHEMA public TO diq_app;

\connect tenant_db;
GRANT ALL PRIVILEGES ON SCHEMA public TO diq_app;

\connect doc_db;
GRANT ALL PRIVILEGES ON SCHEMA public TO diq_app;

\connect agent_db;
GRANT ALL PRIVILEGES ON SCHEMA public TO diq_app;
