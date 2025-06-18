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

SET search_path TO public;
CREATE EXTENSION IF NOT EXISTS postgis;

CREATE SCHEMA sampledata;

ALTER SCHEMA sampledata OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

CREATE TABLE sampledata.contacts (
    id integer NOT NULL,
    name character varying,
    phone character varying,
    picture character varying
);


ALTER TABLE sampledata.contacts OWNER TO postgres;

CREATE TABLE sampledata.fountain_types (
    id integer NOT NULL,
    type character varying
);


ALTER TABLE sampledata.fountain_types OWNER TO postgres;
CREATE SEQUENCE sampledata.fountain_types_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE sampledata.fountain_types_id_seq OWNER TO postgres;
ALTER TABLE ONLY sampledata.fountain_types ALTER COLUMN id SET DEFAULT nextval('sampledata.fountain_types_id_seq'::regclass);

CREATE TABLE sampledata.fountains (
    id integer NOT NULL,
    name character varying,
    type integer,
    geom geometry(Point, 4326)
);

ALTER TABLE sampledata.fountains OWNER TO postgres;

CREATE SEQUENCE sampledata.fountains_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE sampledata.fountains_id_seq OWNER TO postgres;

ALTER SEQUENCE sampledata.fountains_id_seq OWNED BY sampledata.fountains.id;

ALTER TABLE ONLY sampledata.fountains ALTER COLUMN id SET DEFAULT nextval('sampledata.fountains_id_seq'::regclass);


CREATE TABLE sampledata.fountains_pictures (
  id integer not null,
  img_path varchar,
  fountain_id integer
);

ALTER TABLE sampledata.fountains_pictures OWNER TO postgres;

CREATE SEQUENCE sampledata.fountains_pictures_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE sampledata.fountains_pictures_id_seq OWNER TO postgres;
ALTER TABLE ONLY sampledata.fountains_pictures ALTER COLUMN id SET DEFAULT nextval('sampledata.fountains_pictures_id_seq'::regclass);

ALTER TABLE ONLY sampledata.fountains_pictures
    ADD CONSTRAINT fountains_pictures_pk PRIMARY KEY (id);

CREATE TABLE sampledata.fountains_contacts (
    fountain_id integer not null,
    contact_id integer not null
);


ALTER TABLE sampledata.fountains_contacts OWNER TO postgres;

COPY sampledata.contacts (id, name, phone) FROM stdin;
1	Schmidt	123456789
2	Müller	987654321
3	Meyer	123123123
\.

CREATE SEQUENCE sampledata.contacts_id_seq
    AS integer
    START WITH 4
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE sampledata.contacts_id_seq OWNER TO postgres;
ALTER SEQUENCE sampledata.contacts_id_seq OWNED BY sampledata.contacts.id;
ALTER TABLE ONLY sampledata.contacts ALTER COLUMN id SET DEFAULT nextval('sampledata.contacts_id_seq'::regclass);

COPY sampledata.fountain_types (id, type) FROM stdin;
1	Tiefbrunnen
2	Springbrunnen
3	Trinkwasserbrunnen
\.

SELECT setval('sampledata.fountain_types_id_seq', 4, true);

COPY sampledata.fountains (id, name, type, geom) FROM stdin;
1	Rathausbrunnen	2	01010000009951E3C13C551641D3C7729D38725541
2	Marktbrunnen	1	01010000002FBBAA7C105216416A48C71850725541
3	Obstbrunnen	2	01010000000204F5B14853164156EEC54B76725541
4	Dorfplatzbrunnen	1	01010000006E2F1A2F84541641B4C876C651725541
5	Stadtparkbrunnen	2	01010000004A7DFAF85B51164191E2F63C4E725541
6	Museumsbrunnen	1	0101000000E17A14AE375316419A99999951725541
7	Bürgerbrunnen	2	01010000003D0AD7A370531641B81E85EB51725541
8	Kindergartenbrunnen	1	0101000000295C8FC2755316413D0AD7A351725541
9	Bahnhofsbrunnen	2	0101000000713D0AD764541641EC51B81E52725541
10	Gartenbrunnen	1	0101000000A4703D0A7755164152B81E8552725541
11	Schulbrunnen	2	0101000000C3F5285C8F561641E17A14AE52725541
12	Brunnenplatz	1	01010000005C8FC2F5985716418FC2F52853725541
13	Altstadtbrunnen	2	0101000000AE47E1FA0059164185EB51B853725541
14	Heimatbrunnen	1	01010000000AD7A3700D5A1641AE47E1FA53725541
15	Kulturbrunnen	2	010100000014AE47E12C5B16413333333354725541
16	Theaterbrunnen	1	0101000000A4703D0A3F5C1641B81E85EB54725541
17	Neubaugebietsbrunnen	2	0101000000C3F5285C5E5D1641F6285C8F54725541
18	Festplatzbrunnen	1	0101000000666666667F5E164114AE47E154725541
19	Sportplatzbrunnen	2	01010000003D0AD7A3905F16410AD7A37055725541
20	Feuerwehrbrunnen	1	0101000000713D0AD7A3601641C3F5285C55725541
21	Friedhofsbrunnen	2	01010000008FC2F528B9611641295C8FC255725541
22	Kirchbrunnen	1	010100000066666666DA6216417B14AE4755725541
23	Alleeplatzbrunnen	2	010100000048E17A14FA6316413D0AD7A355725541
24	Sommerbrunnen	1	0101000000E17A14AE1C651641B81E85EB55725541
25	Winterbrunnen	2	0101000000AE47E1FA3D661641E17A14AE55725541
26	Historischer Brunnen	1	0101000000C3F5285C5E6716411F85EB5156725541
27	Modellbrunnen	2	0101000000295C8FC280681641AE47E1FA56725541
28	Zierbrunnen	1	0101000000713D0AD7A36916419A99999956725541
29	Gemeindebrunnen	2	01010000005C8FC2F5A16A1641CDCCCC4C56725541
30	Universitätsbrunnen	1	01010000003D0AD7A3C36B16410AD7A37057725541
31	Technikbrunnen	2	01010000009A999999F46C164148E17A1457725541
32	Ingenieurbrunnen	1	010100000014AE47E1166E16413333333357725541
33	Familienbrunnen	2	0101000000A4703D0A376F1641E17A14AE57725541
34	Märchenbrunnen	1	0101000000C3F5285C58701641AE47E1FA57725541
35	Wandererbrunnen	2	0101000000EC51B81E89711641C3F5285C58725541
36	Künstlerbrunnen	1	010100000048E17A14AA7216416666666658725541
37	Marktplatzbrunnen	2	01010000001F85EB51DB731641A4703D0A59725541
38	Einkaufszentrumbrunnen	1	0101000000AE47E1FAFC7416413D0AD7A359725541
39	Spielplatzbrunnen	2	0101000000666666661D7616418FC2F52859725541
40	Bibliotheksbrunnen	1	0101000000B81E85EB3E771641F6285C8F59725541
41	Industriebrunnen	2	01010000000AD7A3705F78164114AE47E159725541
42	Firmenbrunnen	1	01010000007B14AE4770791641333333335A725541
43	Rosenbrunnen	2	0101000000C3F5285C907A16419A9999995A725541
44	Lindenbrunnen	1	010100000048E17A14B17B16411F85EB515B725541
45	Eichenbrunnen	2	0101000000AE47E1FAE27C164152B81E855B725541
46	Birkenbrunnen	1	010100000014AE47E1037E1641C3F5285C5B725541
47	Ahornbrunnen	2	01010000003D0AD7A3247F164185EB51B85B725541
48	Pappelbrunnen	1	0101000000A4703D0A45801641333333335C725541
49	Bachbrunnen	2	0101000000F6285C8F66811641AE47E1FA5C725541
50	Quellbrunnen	1	0101000000295C8FC287821641D3F1F9285D725541
\.

SELECT setval('sampledata.fountains_id_seq', 3, true);

COPY sampledata.fountains_contacts (fountain_id, contact_id) FROM stdin;
1	1
1	2
2	1
3	1
3	2
4	2
5	1
5	3
6	1
7	2
7	3
8	1
\.

ALTER TABLE ONLY sampledata.fountain_types
    ADD CONSTRAINT fountain_types_pk PRIMARY KEY (id);


ALTER TABLE ONLY sampledata.fountains_contacts
    ADD CONSTRAINT fountains_contacts_pk PRIMARY KEY (fountain_id, contact_id);


ALTER TABLE ONLY sampledata.fountains_contacts
    ADD CONSTRAINT fountains_contacts_un UNIQUE (fountain_id, contact_id);


ALTER TABLE ONLY sampledata.contacts
    ADD CONSTRAINT species_pk PRIMARY KEY (id);


ALTER TABLE ONLY sampledata.fountains
    ADD CONSTRAINT tree_pk PRIMARY KEY (id);


ALTER TABLE ONLY sampledata.fountains_contacts
    ADD CONSTRAINT fountains_contacts_fk FOREIGN KEY (fountain_id) REFERENCES sampledata.fountains(id);


ALTER TABLE ONLY sampledata.fountains_contacts
    ADD CONSTRAINT fountains_contacts_fk_1 FOREIGN KEY (contact_id) REFERENCES sampledata.contacts(id);


ALTER TABLE ONLY sampledata.fountains
    ADD CONSTRAINT fountains_fk FOREIGN KEY (type) REFERENCES sampledata.fountain_types(id);

ALTER TABLE ONLY sampledata.fountains_pictures
    ADD CONSTRAINT fountains_pictures_fk FOREIGN KEY (fountain_id) REFERENCES sampledata.fountains(id);


CREATE TABLE sampledata.inspections (
    id integer NOT NULL,
    title character varying,
    description character varying,
    fountain_id integer
);

ALTER TABLE sampledata.inspections OWNER TO postgres;

COPY sampledata.inspections (id, title, description, fountain_id) FROM stdin;
1	Erstbegehung	Erstbegehung des Brunnens	1
2	Nachprüfung	Alle Mängel behoben	1
\.

ALTER TABLE ONLY sampledata.inspections
    ADD CONSTRAINT inspections_pk PRIMARY KEY (id);

ALTER TABLE ONLY sampledata.inspections
    ADD CONSTRAINT fountains_fk_1 FOREIGN KEY (fountain_id) REFERENCES sampledata.fountains(id);

CREATE SEQUENCE sampledata.inspections_id_seq
    AS integer
    START WITH 3
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE sampledata.inspections_id_seq OWNER TO postgres;
ALTER SEQUENCE sampledata.inspections_id_seq OWNED BY sampledata.inspections.id;
ALTER TABLE ONLY sampledata.inspections ALTER COLUMN id SET DEFAULT nextval('sampledata.inspections_id_seq'::regclass);


CREATE TABLE sampledata.inspections_contacts (
    inspection_id integer not null,
    contact_id integer not null
);

ALTER TABLE sampledata.inspections_contacts OWNER TO postgres;

ALTER TABLE ONLY sampledata.inspections_contacts
    ADD CONSTRAINT inspections_contacts_pk PRIMARY KEY (inspection_id, contact_id);

ALTER TABLE ONLY sampledata.inspections_contacts
    ADD CONSTRAINT inspections_contacts_un UNIQUE (inspection_id, contact_id);

ALTER TABLE ONLY sampledata.inspections_contacts
    ADD CONSTRAINT inspections_contacts_fk FOREIGN KEY (inspection_id) REFERENCES sampledata.inspections(id);

ALTER TABLE ONLY sampledata.inspections_contacts
    ADD CONSTRAINT inspections_contacts_fk_1 FOREIGN KEY (contact_id) REFERENCES sampledata.contacts(id);
