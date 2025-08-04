-- anonymous user for postgrest. This user will not have
-- any permission whatsoever, but will be able to connect.
create role web_anon nologin;

-- user for the formbackend. This user must have full access
-- to the tables and schemas the formbackend needs to interact with.
create role formbackend nologin;

grant USAGE on schema sampledata to formbackend;
grant SELECT, INSERT, UPDATE, DELETE on all tables in schema sampledata to formbackend;
grant all on all sequences in schema sampledata to formbackend;

-- password will be replaced by init script
create role authenticator noinherit login password 'letmein';
grant web_anon to authenticator;
grant formbackend to authenticator;
