-- -- anonymous user for postgrest. This user will not have
-- -- any permission whatsoever, but will be able to connect.
CREATE ROLE web_anon NOINHERIT NOLOGIN;
--
-- -- user for the formbackend. This user must have full access
-- -- to the tables and schemas the formbackend needs to interact with.
CREATE ROLE formbackend NOINHERIT NOLOGIN;

CREATE ROLE authenticator LOGIN NOINHERIT NOCREATEDB NOCREATEROLE NOSUPERUSER;

GRANT USAGE ON SCHEMA sampledata TO formbackend;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA sampledata TO formbackend;
GRANT ALL ON ALL SEQUENCES IN SCHEMA sampledata TO formbackend;

GRANT USAGE ON SCHEMA sampledata TO web_anon;
GRANT SELECT ON ALL TABLES IN SCHEMA sampledata TO web_anon;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA sampledata TO web_anon;

GRANT web_anon TO authenticator;
GRANT formbackend TO authenticator;
