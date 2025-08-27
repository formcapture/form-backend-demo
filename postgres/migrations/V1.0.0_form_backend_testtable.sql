SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

SET search_path TO public, sampledata;

CREATE TABLE IF NOT EXISTS sampledata.__form_backend_healthcheck (
    id Serial NOT NULL PRIMARY KEY,
    last_start timestamp without time zone
);
INSERT INTO sampledata.__form_backend_healthcheck (id, last_start) VALUES (1, TO_TIMESTAMP('1970-01-01','YYYY-MM-DD'));
ALTER TABLE sampledata.__form_backend_healthcheck OWNER TO postgres;
GRANT SELECT, UPDATE ON TABLE sampledata.__form_backend_healthcheck TO formbackend;
