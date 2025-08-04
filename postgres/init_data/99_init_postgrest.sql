-- anonymous user for postgrest. This user will not have
-- any permission whatsoever, but will be able to connect.
create role web_anon noinherit nologin;

-- user for the formbackend. This user must have full access
-- to the tables and schemas the formbackend needs to interact with.
create role formbackend noinherit nologin;

grant USAGE on schema sampledata to formbackend;
grant SELECT, INSERT, UPDATE, DELETE on all tables in schema sampledata to formbackend;
grant all on all sequences in schema sampledata to formbackend;

grant SELECT on all tables in schema sampledata to web_anon;
grant SELECT on all sequences in schema sampledata to web_anon;
grant USAGE on schema sampledata to web_anon;

-- Apply session timeouts for roles
ALTER ROLE formbackend SET statement_timeout TO '10s';
ALTER ROLE web_anon SET statement_timeout TO '1s';

-- password will be replaced by init script
create role authenticator inherit login password 'letmein';
grant web_anon to authenticator;
grant formbackend to authenticator;
