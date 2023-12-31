DROP TABLE IF EXISTS zaf.tbl_lz_mapping;

BEGIN;
CREATE TABLE zaf.tbl_lz_mapping (
  lz_code integer primary key,
  lz_analysis_code integer,
  lz_analysis_name varchar(255),
  lz_analysis_abbrev varchar(5)
  )
;

INSERT INTO zaf.tbl_lz_mapping (
  lz_code,
  lz_analysis_code,
  lz_analysis_name,
  lz_analysis_abbrev
  )
    SELECT
      f.lz_code,
      f.lz_code,
      f.lz_name,
      f.lz_abbrev
    FROM
      zaf.tbl_livezones_list AS f,
      (SELECT lz_code FROM zaf.tbl_ofa_analysis GROUP BY lz_code) AS g
    WHERE
      f.lz_code = g.lz_code

    UNION
    -- farm workers
    SELECT
      lz_code,
      59050,
      'Commercial farm workers',
      'ZA_FW'
    FROM
      zaf.tbl_livezones_list AS h
    WHERE
      (
            h.lz_code < 59700
         AND
            TO_NUMBER (substring (TO_CHAR (h.lz_code, '99999') FROM 4 FOR 1), '9') < 6
         AND
            TO_NUMBER (substring (TO_CHAR (h.lz_code, '99999') FROM 5 FOR 1), '9') > 4
      ) OR (
            h.lz_code >= 59890 AND h.lz_code < 59900
      )

    UNION
    -- other open access zones
    SELECT
      lz_code,
      TO_NUMBER('59' || substring (TO_CHAR (i.lz_code, '99999') FROM 4 FOR 1) || '00', '99999'),
      CASE substring (TO_CHAR (i.lz_code, '99999') FROM 4 FOR 1)
         WHEN '1' THEN 'Open access livestock husbandry'
         WHEN '2' THEN 'Open access mixed livestock and crops'
         ELSE 'Open access cropping'
      END,
      CASE substring (TO_CHAR (i.lz_code, '99999') FROM 4 FOR 1)
         WHEN '1' THEN 'ZA1XX'
         WHEN '2' THEN 'ZA2XX'
         ELSE 'ZA3XX'
      END
    FROM
      zaf.tbl_livezones_list AS i
    WHERE
        i.lz_code < 59350
      AND
        TO_NUMBER (substring (TO_CHAR (i.lz_code, '99999') FROM 5 FOR 1), '9') < 5
      AND
        lz_code NOT IN (
          SELECT
            j.lz_code
          FROM
            zaf.tbl_livezones_list AS j,
            (SELECT lz_code FROM zaf.tbl_ofa_analysis GROUP BY lz_code) AS k
          WHERE
            k.lz_code = j.lz_code
          )

    UNION
    -- urban
    SELECT
      lz_code,
      59899,
      'Urban poor',
      'ZA_UP'
    FROM
      zaf.tbl_livezones_list
    WHERE
         -- INCLUDE the fishing LZs as kind of 'urban poor'
         (lz_code > 59700 AND lz_code < 59800)
      OR
         -- EXCLUDE 800 to 810 as these are just service LZs (e.g. commercial, industrial, transport, etc.) 830 to 839 are informal settlements (MUST INCLUDE) and 840 to 849 are combined informal/formal settlements (e.g. with lots of backyard dwellings) (MUST INCLUDE)
         (lz_code > 59810 AND lz_code < 59850)
      OR
         -- INCLUDE 852+, 862+, 872+ and 882+ as these have high unemployment and income poverty. 851, 861, 871 and 881 are all middle- to high-income, so EXCLUDE. Exclude 890 as these are urban smallholdings, should go under ZA_FW (050).
         (lz_code >= 59850 AND lz_code < 59890 AND TO_NUMBER(substring (TO_CHAR (lz_code, '99999') FROM 6 FOR 1), '9') > 1)

;
COMMIT;

SELECT f.lz_code AS "LZ Code", lz_analysis_code AS "Alt Code", lz_abbrev AS "Abbrev", lz_analysis_abbrev AS "Alt Abbrev", lz_name AS "Name", lz_analysis_name AS "Alt Name" FROM zaf.tbl_livezones_list AS f, zaf.tbl_lz_mapping AS g WHERE f.lz_code = g.lz_code ORDER BY f.lz_code;
