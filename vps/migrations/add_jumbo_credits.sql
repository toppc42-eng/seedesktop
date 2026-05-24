-- Jumbo Mail credits per WordPress user email (MySQL example).
-- Adjust table/column names to match your WooCommerce / user meta schema.

ALTER TABLE wp_users
    ADD COLUMN jumbo_credits INT NOT NULL DEFAULT 0
    COMMENT 'Remaining Jumbo Mail transfer credits';

-- Or store on a custom licenses table:
-- ALTER TABLE wp_sd_licenses ADD COLUMN jumbo_credits INT NOT NULL DEFAULT 0;

-- Seed example:
-- UPDATE wp_users SET jumbo_credits = 5 WHERE user_email = 'user@example.com';
