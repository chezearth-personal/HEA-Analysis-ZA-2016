/*
 * Purpose: to construct a table of geographical problem specs by Small Area, so that these can be
 * mapped and linked to analysis outcomes.
 *
 * The table can be mapped, although the GIS rendering package must filter on the analysis.
 *
 */

SELECT E'This query will only work if you have specified two switches on the command \nline for the \'analysis\' and \'hazard\' variables, using the syntax:\n\n-v analysis=M-YYYY -v hazard=HAZARD_TYPE\n\nwhere M is a one- or two-digit number representing the month of analysis (1 to \n12), YYYY is a four-digit number representing the year of analysis and \nHAZARD_TYPE is a one-word (no whitespace) description of the hazard.\n'::text AS "NOTICE";

-- Indices, table creation and preparation transaction
BEGIN;

--Drop indices to so they can be recreated
--DROP INDEX IF EXISTS zaf.prob_hazard_the_geom_gidx;

DROP INDEX IF EXISTS zaf.demog_sas_thegeom_gidx;

DROP INDEX IF EXISTS zaf.demog_sas_sacode_idx;

DROP INDEX IF EXISTS zaf.tbl_pop_agegender_12y_sacode_idx;

DROP INDEX IF EXISTS zaf.t1_thegeom_gidx;

DROP INDEX IF EXISTS zaf.t1_sacode_idx;

DROP INDEX IF EXISTS zaf.t2_thegeom_gidx;

-- Create indices if they do not exist
CREATE INDEX demog_sas_thegeom_gidx ON zaf.demog_sas USING gist (the_geom);

CREATE INDEX demog_sas_sacode_idx ON zaf.demog_sas USING btree (sa_code);

CREATE INDEX tbl_pop_agegender_12y_sacode_idx ON zaf.tbl_pop_agegender_12y USING btree (sa_code);


-- [records deleted instead] Remove any old table of affected small areas
-- DROP TABLE IF EXISTS zaf.demog_sas_ofa;

-- If it doesn't exist already, create a new table with the key outcome information for all affected
-- enumeration areas, with admin, livelihood zone, wealth group definition
-- social security, hazard and outcome information
CREATE TABLE IF NOT EXISTS zaf.demog_sas_ofa (
	gid serial primary key,
	the_geom geometry(multipolygon, 201100),
-- year and month of analysis (unique to each analysis event)
	ofa_year integer,
	ofa_month integer,
	sa_code integer,
	mn_code varchar(6),
	dc_code varchar(6),
	pr_code integer,
	-- population (census data only, current year will be added in next step)
	pop_size integer,
	-- livelihood zones: code, abbrev, name and wealth group
	lz_code integer,
	lz_affected varchar(30)
)
;

REINDEX INDEX zaf.prob_hazard_the_geom_gidx;

-- Done.
COMMIT;



-- Main transaction. Create an output table and populate it with the analysis.
SELECT E'Adding in the SAs. This takes quite a while. If any part fails, the entire \nprocess will be rolled back and none of the SAs will be included\n'::text AS "NOTICE";

BEGIN;


-- Remove all previous records for the analysis specified in the :analysis variable (-v
-- analysis=M-YYYY in the command line where M is a number (1 to 12) representing the month of
-- analysis and YYYY is a four-digit number (1980 to current year) representing the year of
-- analysis)
DELETE FROM
	zaf.demog_sas_ofa
WHERE
 		ofa_year = (
			-- Check that the month and year are not before 01-01-1980 or after the curent date. If
			-- so, force to the current month and year.
			SELECT
				CASE WHEN (date (q.y::text || '-' || q.m::text || '-01') < date '1980-01-01' OR date (q.y::text || '-' || q.m::text || '-01') > current_date) THEN extract (year from current_date) ELSE q.y	END AS ofa_year
				FROM (
					SELECT
						p.y,
						--make sure the value of the month number is 1..12 only.
						CASE WHEN p.m > 12 THEN 12 WHEN p.m < 1 THEN 1 ELSE p.m END AS m
					FROM (
						-- get the year, month values from the :analysis variable (TEXT) and coerces them
						-- to INTEGERs.
						SELECT
							substring( :'analysis' from  position( '-' in :'analysis' ) + 1 for length( :'analysis' ) - position( '-' in :'analysis' ))::integer AS y,
							substring( :'analysis' from 1 for position( '-' in :'analysis' ) - 1)::integer AS m
					) AS p
				) AS q
		)
	AND
		ofa_month = (
			-- Check that the month and year are not before 01-01-1980 or after the curent date. If
			-- so, force to the current month and year.
			SELECT
				CASE WHEN date (q.y::text || '-' || q.m::text || '-01') < date '1980-01-01' OR date (q.y::text || '-' || q.m::text || '-01') > current_date THEN extract (month from current_date) ELSE q.m END AS ofa_month
				FROM (
					SELECT
						p.y,
						--make sure the value of the month number is 1..12 only.
						CASE WHEN p.m > 12 THEN 12 WHEN p.m < 1 THEN 1 ELSE p.m END AS m
					FROM (
						-- get the year, month values from the :analysis variable (TEXT) and coerces them
						-- to INTEGERs.
						SELECT
							substring( :'analysis' from  position( '-' in :'analysis' ) + 1 for length( :'analysis' ) - position( '-' in :'analysis' ))::integer AS y,
							substring( :'analysis' from 1 for position( '-' in :'analysis' ) - 1)::integer AS m
					) AS p
				) AS q
		)
;


SELECT E'Making temporary tables (t1 and t2) and indices for executing the main part of \nthe query \n'::text AS "NOTICE";


-- Create an populate temporary table that combines the SAs and populations, with indices to speed
-- up the INSERT queries
CREATE TABLE zaf.t1 (
	gid serial primary key,
	the_geom geometry(multipolygon, 201100),
	sa_code integer,
	mn_code varchar(6),
	dc_code varchar(6),
	pr_code integer,
	pop_size integer,
	lz_code integer
)
;

INSERT INTO zaf.t1 (
	the_geom,
	sa_code,
	mn_code,
	dc_code,
	pr_code,
	pop_size,
	lz_code
)
SELECT
	f.the_geom,
	f.sa_code,
	f.mn_code,
	f.dc_code,
	f.pr_code,
	g.total AS pop_size,
	f.lz_code
FROM
	zaf.demog_sas AS f,
	zaf.tbl_pop_agegender_12y AS g
WHERE
	f.sa_code = g.sa_code
;

CREATE INDEX t1_thegeom_gidx ON zaf.t1 USING GIST (the_geom);

CREATE INDEX t1_sacode_idx ON zaf.t1 USING btree (sa_code);


-- Create and populate a temporary table to get the intersection all the SAs that are not entirely
-- within the affected area (these will be SAs that are chopped smaller by the affected area).
CREATE TABLE zaf.t2 (
	gid serial primary key,
	the_geom geometry(multipolygon, 201100),
	sa_code integer,
	ofa_year integer,
	ofa_month integer
)
;

--EXPLAIN ANALYZE
INSERT INTO zaf.t2 (
	the_geom,
	sa_code,
	ofa_year,
	ofa_month
)
	SELECT
		ST_Multi(ST_Buffer(ST_Intersection(f.the_geom, g.the_geom),0.0)) AS the_geom,
		f.sa_code,
		g.ofa_year,
		g.ofa_month
	FROM
		zaf.demog_sas AS f,
		zaf.prob_hazard AS g,
		(
			SELECT
            CASE WHEN (date (q.y::text || '-' || q.m::text || '-01') < date '1980-01-01' OR date (q.y::text || '-' || q.m::text || '-01') > current_date) THEN extract (year from current_date) ELSE q.y END AS ofa_year,
	         CASE WHEN date (q.y::text || '-' || q.m::text || '-01') < date '1980-01-01' OR date (q.y::text || '-' || q.m::text || '-01') > current_date THEN extract (month from current_date) ELSE q.m END AS ofa_month
	      FROM (
	      	SELECT
            	p.y,
	            CASE WHEN p.m > 12 THEN 12 WHEN p.m < 1 THEN 1 ELSE p.m END AS m
            FROM (
	            SELECT
	            	substring( :'analysis' from  position( '-' in :'analysis' ) + 1 for length( :'analysis' ) - position( '-' in :'analysis' ))::integer AS y,
	            	substring( :'analysis' from 1 for position( '-' in :'analysis' ) - 1)::integer AS m
	         ) AS p
	      ) AS q
	   ) AS r
	WHERE
			ST_Intersects(f.the_geom, g.the_geom)
		AND
			f.gid NOT IN (
				SELECT
					h.gid
				FROM
					zaf.demog_sas AS h,
					zaf.prob_hazard AS i,
					(
						SELECT
			            CASE WHEN (date (t.y::text || '-' || t.m::text || '-01') < date '1980-01-01' OR date (t.y::text || '-' || t.m::text || '-01') > current_date) THEN extract (year from current_date) ELSE t.y END AS ofa_year,
				         CASE WHEN date (t.y::text || '-' || t.m::text || '-01') < date '1980-01-01' OR date (t.y::text || '-' || t.m::text || '-01') > current_date THEN extract (month from current_date) ELSE t.m END AS ofa_month
				      FROM (
				      	SELECT
			            	s.y,
				            CASE WHEN s.m > 12 THEN 12 WHEN s.m < 1 THEN 1 ELSE s.m END AS m
			            FROM (
				            SELECT
				            	substring( :'analysis' from  position( '-' in :'analysis' ) + 1 for length( :'analysis' ) - position( '-' in :'analysis' ))::integer AS y,
				            	substring( :'analysis' from 1 for position( '-' in :'analysis' ) - 1)::integer AS m
				         ) AS s
				      ) AS t
				   ) AS u
				WHERE
					ST_Within(h.the_geom, i.the_geom)
				AND
					i.ofa_year = u.ofa_year
				AND
					i.ofa_month = u.ofa_month
			)
		AND
			g.ofa_year = r.ofa_year
		AND
			g.ofa_month = r.ofa_month
;

CREATE INDEX t2_thegeom_gidx ON zaf.t2 USING gist (the_geom);


SELECT E'Adding in the SAs that are completely contained within the hazard area ... \n'::text AS "NOTICE";

--EXPLAIN ANALYZE
INSERT INTO zaf.demog_sas_ofa (
	the_geom,
	ofa_year,
	ofa_month,
	sa_code,
	mn_code,
	dc_code,
	pr_code,
	pop_size,
	lz_code,
	lz_affected
)
	-- The SAs entirely within the affected area
	SELECT
		f.the_geom AS the_geom,
		r.ofa_year,
		r.ofa_month,
		f.sa_code,
		f.mn_code,
		f.dc_code,
		f.pr_code,
		f.pop_size,
		f.lz_code,
		:'hazard' AS lz_affected
	FROM
		zaf.t1 AS f,
		zaf.prob_hazard AS g,
		(
			SELECT
         	CASE WHEN (date (q.y::text || '-' || q.m::text || '-01') < date '1980-01-01' OR date (q.y::text || '-' || q.m::text || '-01') > current_date) THEN extract (year from current_date) ELSE q.y END AS ofa_year,
         	CASE WHEN date (q.y::text || '-' || q.m::text || '-01') < date '1980-01-01' OR date (q.y::text || '-' || q.m::text || '-01') > current_date THEN extract (month from current_date) ELSE q.m END AS ofa_month
         FROM (
         	SELECT
            	p.y,
            	CASE WHEN p.m > 12 THEN 12 WHEN p.m < 1 THEN 1 ELSE p.m END AS m
            FROM (
            	SELECT
               	substring( :'analysis' from  position( '-' in :'analysis' ) + 1 for length( :'analysis' ) - position( '-' in :'analysis' ))::integer AS y,
               	substring( :'analysis' from 1 for position( '-' in :'analysis' ) - 1)::integer AS m
            ) AS p
         ) AS q
      ) AS r
	WHERE
			ST_Within(f.the_geom, g.the_geom)
		AND
			g.ofa_year = r.ofa_year
		AND
			g.ofa_month = r.ofa_month
;


SELECT E'Add in the SAs that have one-third or more of their area intersecting with \nthe hazard area ... \n'::text AS "NOTICE";

--EXPLAIN ANALYZE
INSERT INTO zaf.demog_sas_ofa (
	the_geom,
	ofa_year,
	ofa_month,
	sa_code,
	mn_code,
	dc_code,
	pr_code,
	pop_size,
	lz_code,
	lz_affected
)
	-- The areas crossing, with more than one-third of the intesecting area
	-- WITHIN
	SELECT
		f.the_geom,
		g.ofa_year,
		g.ofa_month,
		f.sa_code,
		f.mn_code,
		f.dc_code,
		f.pr_code,
		f.pop_size,
		f.lz_code,
		:'hazard' AS lz_affected
	FROM
		zaf.t1 AS f,
		zaf.t2 AS g
	WHERE
		f.sa_code = g.sa_code
	GROUP BY
		f.the_geom,
		g.ofa_year,
		g.ofa_month,
		f.sa_code,
		f.mn_code,
		f.dc_code,
		f.pr_code,
		f.pop_size,
		f.lz_code,
		lz_affected
	HAVING 3 * sum(ST_Area(g.the_geom)) >= ST_Area(f.the_geom)
;


SELECT E'Add in the SAs that less than one-third of their area intersecting with the \nhazard area ... \n'::text AS "NOTICE";

--EXPLAIN ANALYZE
INSERT INTO zaf.demog_sas_ofa (
	the_geom,
	ofa_year,
	ofa_month,
	sa_code,
	mn_code,
	dc_code,
	pr_code,
	pop_size,
	lz_code,
	lz_affected
)
	SELECT
		f.the_geom,
		g.ofa_year,
		g.ofa_month,
		f.sa_code,
		f.mn_code,
		f.dc_code,
		f.pr_code,
		f.pop_size,
		f.lz_code,
		'normal' AS lz_affected
	FROM
		zaf.t1 AS f,
		zaf.t2 AS g
	WHERE
		g.sa_code = f.sa_code
	GROUP BY
		f.the_geom,
		g.ofa_year,
		g.ofa_month,
		f.sa_code,
		f.mn_code,
		f.dc_code,
		f.pr_code,
		f.pop_size,
		f.lz_code,
		lz_affected
	HAVING 3 * sum(ST_Area(g.the_geom)) < ST_Area(f.the_geom)
;


SELECT E'Add in the SAs that do NOT intersect at all with the hazard area ... \n'::text AS "NOTICE";

--EXPLAIN ANALYZE
INSERT INTO zaf.demog_sas_ofa (
	the_geom,
	ofa_year,
	ofa_month,
	sa_code,
	mn_code,
	dc_code,
	pr_code,
	pop_size,
	lz_code,
	lz_affected
)
	-- The areas that do not intersect
	SELECT
		f.the_geom,
		r.ofa_year,
		r.ofa_month,
		f.sa_code,
		f.mn_code,
		f.dc_code,
		f.pr_code,
		f.pop_size,
		f.lz_code,
		'normal' AS lz_affected
	FROM
		zaf.t1 AS f,
		(
			SELECT
         	CASE WHEN (date (q.y::text || '-' || q.m::text || '-01') < date '1980-01-01' OR date (q.y::text || '-' || q.m::text || '-01') > current_date) THEN extract (year from current_date) ELSE q.y END AS ofa_year,
	         CASE WHEN date (q.y::text || '-' || q.m::text || '-01') < date '1980-01-01' OR date (q.y::text || '-' || q.m::text || '-01') > current_date THEN extract (month from current_date) ELSE q.m END AS ofa_month
         FROM (
	         SELECT
	         	p.y,
	         	CASE WHEN p.m > 12 THEN 12 WHEN p.m < 1 THEN 1 ELSE p.m END AS m
         	FROM (
               SELECT
	               substring( :'analysis' from  position( '-' in :'analysis' ) + 1 for length( :'analysis' ) - position( '-' in :'analysis' ))::integer AS y,
	            	substring( :'analysis' from 1 for position( '-' in :'analysis' ) - 1)::integer AS m
	         ) AS p
	      ) AS q
	   ) AS r
	WHERE
		f.gid NOT IN (
			SELECT
				h.gid
			FROM
				zaf.t1 AS h,
				zaf.prob_hazard AS i,
				(
					SELECT
		         	CASE WHEN (date (t.y::text || '-' || t.m::text || '-01') < date '1980-01-01' OR date (t.y::text || '-' || t.m::text || '-01') > current_date) THEN extract (year from current_date) ELSE t.y END AS ofa_year,
			         CASE WHEN date (t.y::text || '-' || t.m::text || '-01') < date '1980-01-01' OR date (t.y::text || '-' || t.m::text || '-01') > current_date THEN extract (month from current_date) ELSE t.m END AS ofa_month
		         FROM (
			         SELECT
			         	s.y,
			         	CASE WHEN s.m > 12 THEN 12 WHEN s.m < 1 THEN 1 ELSE s.m END AS m
		         	FROM (
		               SELECT
			               substring( :'analysis' from  position( '-' in :'analysis' ) + 1 for length( :'analysis' ) - position( '-' in :'analysis' ))::integer AS y,
			            	substring( :'analysis' from 1 for position( '-' in :'analysis' ) - 1)::integer AS m
			         ) AS s
			      ) AS t
			   ) AS u
			WHERE
					ST_Intersects(h.the_geom, i.the_geom)
				AND
					i.ofa_year = u.ofa_year
				AND
					i.ofa_month = u.ofa_month
		)
;

SELECT E'Deleting temporary tables (t1 and t2) and their associated indices\n'::text AS "NOTICE";

DROP INDEX IF EXISTS zaf.t1_thegeom_gidx;

DROP INDEX IF EXISTS zaf.t1_sacode_idx;

DROP TABLE IF EXISTS zaf.t1;

DROP INDEX IF EXISTS t2_thegeom_gidx;

DROP TABLE IF EXISTS zaf.t2;



COMMIT;



SELECT E'Done. \nOutputting a count of affected rows in table \"zaf.demog_sas_ofa\" \n'::text AS "NOTICE";


-- Present a count of all changed SAs (can be checked against original number of SAs) for the
-- current analysis
SELECT
	ofa_year,
	ofa_month,
	count(sa_code) AS num_sas,
	lz_affected AS affected
FROM
	zaf.demog_sas_ofa
WHERE
 		ofa_year = (
			SELECT
				CASE WHEN (date (q.y::text || '-' || q.m::text || '-01') < date '1980-01-01' OR date (q.y::text || '-' || q.m::text || '-01') > current_date) THEN extract (year from current_date) ELSE q.y	END AS ofa_year
			FROM (
				SELECT
					p.y,
					CASE WHEN p.m > 12 THEN 12 WHEN p.m < 1 THEN 1 ELSE p.m END AS m
				FROM (
					SELECT
						substring( :'analysis' from  position( '-' in :'analysis' ) + 1 for length( :'analysis' ) - position( '-' in :'analysis' ))::integer AS y,
						substring( :'analysis' from 1 for position( '-' in :'analysis' ) - 1)::integer AS m
				) AS p
			) AS q
		)
	AND
		ofa_month = (
			SELECT
				CASE WHEN date (q.y::text || '-' || q.m::text || '-01') < date '1980-01-01' OR date (q.y::text || '-' || q.m::text || '-01') > current_date THEN extract (month from current_date) ELSE q.m END AS ofa_month
			FROM (
				SELECT
					p.y,
					CASE WHEN p.m > 12 THEN 12 WHEN p.m < 1 THEN 1 ELSE p.m END AS m
				FROM (
					SELECT
						substring( :'analysis' from  position( '-' in :'analysis' ) + 1 for length( :'analysis' ) - position( '-' in :'analysis' ))::integer AS y,
						substring( :'analysis' from 1 for position( '-' in :'analysis' ) - 1)::integer AS m
				) AS p
			) AS q
		)
GROUP BY
	affected,
	ofa_year,
	ofa_month
UNION SELECT
	ofa_year,
	ofa_month,
	count(sa_code) AS num_sas,
	'TOTAL' AS affected
FROM
	zaf.demog_sas_ofa
WHERE
		ofa_year = (
			SELECT
				CASE WHEN (date (q.y::text || '-' || q.m::text || '-01') < date '1980-01-01' OR date (q.y::text || '-' || q.m::text || '-01') > current_date) THEN extract (year from current_date) ELSE q.y	END AS ofa_year
			FROM (
				SELECT
					p.y,
					CASE WHEN p.m > 12 THEN 12 WHEN p.m < 1 THEN 1 ELSE p.m END AS m
				FROM (
					SELECT
						substring( :'analysis' from  position( '-' in :'analysis' ) + 1 for length( :'analysis' ) - position( '-' in :'analysis' ))::integer AS y,
						substring( :'analysis' from 1 for position( '-' in :'analysis' ) - 1)::integer AS m
				) AS p
			) AS q
		)
	AND
		ofa_month = (
			SELECT
				CASE WHEN date (q.y::text || '-' || q.m::text || '-01') < date '1980-01-01' OR date (q.y::text || '-' || q.m::text || '-01') > current_date THEN extract (month from current_date) ELSE q.m END AS ofa_month
			FROM (
				SELECT
					p.y,
					CASE WHEN p.m > 12 THEN 12 WHEN p.m < 1 THEN 1 ELSE p.m END AS m
				FROM (
					SELECT
						substring( :'analysis' from  position( '-' in :'analysis' ) + 1 for length( :'analysis' ) - position( '-' in :'analysis' ))::integer AS y,
						substring( :'analysis' from 1 for position( '-' in :'analysis' ) - 1)::integer AS m
				) AS p
			) AS q
		)
GROUP BY
	affected,
	ofa_month,
	ofa_year
ORDER BY
	ofa_year desc, ofa_month desc, affected desc
;
