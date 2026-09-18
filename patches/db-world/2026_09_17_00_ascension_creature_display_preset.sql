-- ===========================================================================
--  2026_09_17_00_ascension_creature_display_preset.sql
--  Project patch (lives in the deployment repo, not in the core repo).
--
--  Why this file exists:
--    Upstream commit e8f9afcc5 ("feat(Compat): implement creature display
--    preset support for mirrorimage npcs", #3983) added the code
--    modules/mod-ascension-compat/src/AscensionCreaturePreset.cpp, which reads
--
--        SELECT entry, display_id, race, gender, class, skin, face, hair,
--               haircolor, facialhair, guild_id, item_head, item_shoulders,
--               item_body, item_chest, item_waist, item_legs, item_feet,
--               item_wrists, item_hands, item_back, item_tabard
--          FROM creature_display_preset
--
--    ... but shipped no SQL that creates the table. Without it the worldserver
--    aborts right after "Loading Module Strings Locale":
--
--        [1146] Table 'acore_world.creature_display_preset' doesn't exist
--        Your database structure is not up to date. Please make sure you've
--        executed all queries in the sql/updates folders.
--        >> ABORTED
--
--  Column names and widths come from the module's struct CreatureDisplayPreset
--  (modules/mod-ascension-compat/src/AscensionCreaturePreset.h):
--    entry/display_id/guild_id/items = uint32, the rest = uint8.
--
--  An EMPTY table is fine: the loader then logs
--  ">> Table creature_display_preset is empty or missing." and the mirror-image
--  NPCs fall back to their normal display. Populate it to use real presets.
--
--  Applied by apply-missing-updates.sh (state MODULE), so it is registered in
--  acore_world.updates with its SHA1 and re-applied when the file changes.
-- ===========================================================================

CREATE TABLE IF NOT EXISTS `creature_display_preset` (
    `entry`          INT UNSIGNED     NOT NULL DEFAULT 0 COMMENT 'creature_template.entry',
    `display_id`     INT UNSIGNED     NOT NULL DEFAULT 0 COMMENT 'creature_template.display_id1..4',
    `race`           TINYINT UNSIGNED NOT NULL DEFAULT 0,
    `gender`         TINYINT UNSIGNED NOT NULL DEFAULT 0,
    `class`          TINYINT UNSIGNED NOT NULL DEFAULT 0,
    `skin`           TINYINT UNSIGNED NOT NULL DEFAULT 0,
    `face`           TINYINT UNSIGNED NOT NULL DEFAULT 0,
    `hair`           TINYINT UNSIGNED NOT NULL DEFAULT 0,
    `haircolor`      TINYINT UNSIGNED NOT NULL DEFAULT 0,
    `facialhair`     TINYINT UNSIGNED NOT NULL DEFAULT 0,
    `guild_id`       INT UNSIGNED     NOT NULL DEFAULT 0,
    `item_head`      INT UNSIGNED     NOT NULL DEFAULT 0,
    `item_shoulders` INT UNSIGNED     NOT NULL DEFAULT 0,
    `item_body`      INT UNSIGNED     NOT NULL DEFAULT 0,
    `item_chest`     INT UNSIGNED     NOT NULL DEFAULT 0,
    `item_waist`     INT UNSIGNED     NOT NULL DEFAULT 0,
    `item_legs`      INT UNSIGNED     NOT NULL DEFAULT 0,
    `item_feet`      INT UNSIGNED     NOT NULL DEFAULT 0,
    `item_wrists`    INT UNSIGNED     NOT NULL DEFAULT 0,
    `item_hands`     INT UNSIGNED     NOT NULL DEFAULT 0,
    `item_back`      INT UNSIGNED     NOT NULL DEFAULT 0,
    `item_tabard`    INT UNSIGNED     NOT NULL DEFAULT 0,
    PRIMARY KEY (`entry`, `display_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;