<?php
// סיסמת האדמין שלך - תשנה אותה למה שתרצה
$admin_password = "326542";
$settings_file = 'settings.json';

// מאפשר לתוכנה לשלוח בקשות
header("Access-Control-Allow-Origin: *");
header("Content-Type: text/plain");

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $provided_password = $_POST['password'] ?? '';
    $new_delay = $_POST['delay'] ?? '0';

    if ($provided_password === $admin_password) {
        $existing = [];
        if (file_exists($settings_file)) {
            $raw = @file_get_contents($settings_file);
            if ($raw !== false && $raw !== '') {
                $decoded = json_decode($raw, true);
                if (is_array($decoded)) {
                    $existing = $decoded;
                }
            }
        }

        $merged = array_merge($existing, [
            "ad_delay_seconds" => (int)$new_delay,
            "last_updated" => date('Y-m-d H:i:s'),
        ]);

        // Canonical booleans: always present in settings.json so all clients can parse them
        // (legacy files often had only ad_delay_seconds).
        $rmmVisible = array_key_exists('rmm_scripts_ui_visible', $existing)
            ? (bool)$existing['rmm_scripts_ui_visible']
            : false;
        $marketingVisible = array_key_exists('upgrade_marketing_visible', $existing)
            ? (bool)$existing['upgrade_marketing_visible']
            : true;

        // Prefer canonical keys (Flutter client); fall back to legacy short keys.
        if (array_key_exists('rmm_scripts_ui_visible', $_POST)) {
            $v = $_POST['rmm_scripts_ui_visible'];
            $rmmVisible = ($v === true || $v === 1 || $v === '1'
                || strtolower((string) $v) === 'true'
                || strtolower((string) $v) === 'on');
        } elseif (array_key_exists('rmm_scripts_ui', $_POST)) {
            $v = $_POST['rmm_scripts_ui'];
            $rmmVisible = ($v === '1' || $v === 'true' || $v === true || $v === 1 || $v === 'on');
        }
        if (array_key_exists('upgrade_marketing_visible', $_POST)) {
            $v = $_POST['upgrade_marketing_visible'];
            $marketingVisible = ($v === true || $v === 1 || $v === '1'
                || strtolower((string) $v) === 'true'
                || strtolower((string) $v) === 'on');
        } elseif (array_key_exists('upgrade_marketing', $_POST)) {
            $v = $_POST['upgrade_marketing'];
            $marketingVisible = ($v === '1' || $v === 'true' || $v === true || $v === 1 || $v === 'on');
        }

        $merged['rmm_scripts_ui_visible'] = $rmmVisible;
        $merged['upgrade_marketing_visible'] = $marketingVisible;

        $settings_data = json_encode($merged, JSON_UNESCAPED_UNICODE);
        file_put_contents($settings_file, $settings_data);
        echo "Success";
    } else {
        http_response_code(403);
        echo "Error: Wrong password";
    }
} else {
    echo "API is ready. Send a POST request to save settings.";
}
?>
