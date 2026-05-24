<?php
/**
 * Plugin Name: SeeDesktop - Secure File Transfer API (V3)
 * Description: REST API for GCS signed uploads, email completion, and sender history. Drop-in or include from functions.php.
 * Version: 3.2
 */

// 1. יצירת/עדכון טבלת העברות במסד הנתונים
add_action('init', 'sd_create_transfers_table', 10);
function sd_create_transfers_table() {
    global $wpdb;
    $table_name = $wpdb->prefix . 'sd_file_transfers';
    $charset_collate = $wpdb->get_charset_collate();

    $sql = "CREATE TABLE IF NOT EXISTS $table_name (
        id mediumint(9) NOT NULL AUTO_INCREMENT,
        sender_email varchar(100) NOT NULL,
        recipient_name varchar(100) NOT NULL,
        recipient_email varchar(100) NOT NULL,
        file_name varchar(255) NOT NULL,
        download_link text NOT NULL,
        message text,
        created_at datetime DEFAULT CURRENT_TIMESTAMP NOT NULL,
        PRIMARY KEY  (id)
    ) $charset_collate;";

    require_once ABSPATH . 'wp-admin/includes/upgrade.php';
    dbDelta($sql);
}

/**
 * dbDelta לא תמיד מוסיף עמודות לטבלה קיימת. SeeDesktop Flutter שולח message_body — חובה עמודת message.
 */
add_action('init', 'sd_ensure_transfers_message_column', 20);
function sd_ensure_transfers_message_column() {
    global $wpdb;
    $table_name = $wpdb->prefix . 'sd_file_transfers';
    $exists = $wpdb->get_var($wpdb->prepare('SHOW TABLES LIKE %s', $table_name));
    if ($exists !== $table_name) {
        return;
    }
    $col = $wpdb->get_results("SHOW COLUMNS FROM `{$table_name}` LIKE 'message'");
    if (empty($col)) {
        // phpcs:ignore WordPress.DB.PreparedSQL.InterpolatedNotPrepared -- table name from wpdb->prefix
        $wpdb->query("ALTER TABLE `{$table_name}` ADD COLUMN `message` text NULL AFTER `download_link`");
    }
}

// 1b. טבלת אנשי קשר להעברות (סנכרון בין מכשירים לפי sender_email)
add_action('init', 'sd_create_transfer_contacts_table', 10);
function sd_create_transfer_contacts_table() {
    global $wpdb;
    $table_name = $wpdb->prefix . 'sd_transfer_contacts';
    $charset_collate = $wpdb->get_charset_collate();

    $sql = "CREATE TABLE IF NOT EXISTS $table_name (
        id mediumint(9) NOT NULL AUTO_INCREMENT,
        sender_email varchar(100) NOT NULL,
        client_id varchar(64) NOT NULL DEFAULT '',
        full_name varchar(200) NOT NULL DEFAULT '',
        email varchar(100) NOT NULL,
        phone varchar(64) NOT NULL DEFAULT '',
        notes text,
        updated_at datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        PRIMARY KEY  (id),
        UNIQUE KEY sd_sender_recipient (sender_email, email)
    ) $charset_collate;";

    require_once ABSPATH . 'wp-admin/includes/upgrade.php';
    dbDelta($sql);
}

// 2. רישום נקודות הקצה (Endpoints) ב-API
add_action('rest_api_init', function () {
    register_rest_route('sd-transfer/v1', '/init', array(
        'methods' => 'POST',
        'callback' => 'sd_api_init_transfer',
        'permission_callback' => '__return_true',
    ));

    register_rest_route('sd-transfer/v1', '/complete', array(
        'methods' => 'POST',
        'callback' => 'sd_api_complete_transfer',
        'permission_callback' => '__return_true',
    ));

    register_rest_route('sd-transfer/v1', '/history', array(
        'methods' => 'GET',
        'callback' => 'sd_api_get_history',
        'permission_callback' => '__return_true',
    ));

    register_rest_route('sd-transfer/v1', '/contacts', array(
        'methods' => 'GET',
        'callback' => 'sd_api_get_contacts',
        'permission_callback' => '__return_true',
    ));

    register_rest_route('sd-transfer/v1', '/contacts/sync', array(
        'methods' => 'POST',
        'callback' => 'sd_api_sync_contacts',
        'permission_callback' => '__return_true',
    ));
});

// 3. פונקציית העזר: ייצור Signed URL
function sd_generate_gcs_signed_url($file_name, $method = 'PUT') {
    $json_key_path = ABSPATH . 'elivc/private/google-service-account.json';

    if (!file_exists($json_key_path)) {
        return new WP_Error('file_missing', 'Error: File not found at path -> ' . $json_key_path);
    }

    $file_content = file_get_contents($json_key_path);
    $key_data = json_decode($file_content, true);

    if ($key_data === null) {
        return new WP_Error('json_invalid', 'Error: JSON is invalid or corrupted. ' . json_last_error_msg());
    }

    $client_email = $key_data['client_email'];
    $private_key = $key_data['private_key'];

    $bucket = 'my-saas-uploads-2025';
    $object_name = 'uploads6/' . time() . '_' . $file_name;
    $expiry = time() + (60 * 60);

    $content_type = ($method === 'PUT') ? 'application/octet-stream' : '';
    $string_to_sign = "$method\n\n$content_type\n$expiry\n/$bucket/$object_name";

    $signature = '';
    openssl_sign($string_to_sign, $signature, $private_key, 'sha256');
    $encoded_signature = urlencode(base64_encode($signature));

    $signed_url = "https://storage.googleapis.com/$bucket/$object_name" .
        "?GoogleAccessId=$client_email" .
        "&Expires=$expiry" .
        "&Signature=$encoded_signature";

    return array(
        'signed_url' => $signed_url,
        'file_key' => $object_name,
    );
}

// 4. API Endpoint 1: Init
function sd_api_init_transfer($request) {
    $file_name = sanitize_file_name($request->get_param('file_name'));
    // Min 25 MB (Jumbo Send — large files only). No max. Must match Flutter [kSecureTransferMinFileBytes].
    $min_bytes = 25 * 1024 * 1024;
    $size_param = $request->get_param('file_size_bytes');
    if ($size_param !== null && $size_param !== '') {
        $file_size = (int) $size_param;
        if ($file_size > 0 && $file_size < $min_bytes) {
            return new WP_REST_Response(array(
                'success' => false,
                'error'   => 'File too small (minimum 25 MB for Jumbo Send).',
            ), 400);
        }
    }
    $result = sd_generate_gcs_signed_url($file_name, 'PUT');

    if (is_wp_error($result)) {
        return new WP_REST_Response(array('success' => false, 'error' => $result->get_error_message()), 400);
    }

    return new WP_REST_Response(array(
        'success' => true,
        'signed_url' => $result['signed_url'],
        'file_key' => $result['file_key'],
    ), 200);
}

/**
 * קריאת הודעה מ-SeeDesktop Flutter: message_body (וגם תאימות לאחור: message).
 */
function sd_transfer_get_message_from_request($request) {
    $body = sanitize_textarea_field((string) $request->get_param('message_body'));
    if ($body !== '') {
        return $body;
    }
    return sanitize_textarea_field((string) $request->get_param('message'));
}

// 5. API Endpoint 2: Complete & Email
function sd_api_complete_transfer($request) {
    global $wpdb;

    $sender = sanitize_email($request->get_param('sender_email'));
    $rec_name = sanitize_text_field($request->get_param('recipient_name'));
    $rec_email = sanitize_email($request->get_param('recipient_email'));
    $file_key = sanitize_text_field($request->get_param('file_key'));
    $user_msg = sd_transfer_get_message_from_request($request);
    $bucket = 'my-saas-uploads-2025';

    $download_link = "https://storage.googleapis.com/{$bucket}/{$file_key}";

    $table_name = $wpdb->prefix . 'sd_file_transfers';
    $inserted = $wpdb->insert(
        $table_name,
        array(
            'sender_email' => $sender,
            'recipient_name' => $rec_name,
            'recipient_email' => $rec_email,
            'file_name' => basename($file_key),
            'download_link' => $download_link,
            'message' => $user_msg,
        ),
        array('%s', '%s', '%s', '%s', '%s', '%s')
    );

    if ($inserted === false) {
        return new WP_REST_Response(array(
            'success' => false,
            'error' => 'Failed to save transfer history',
            'detail' => $wpdb->last_error ?: 'unknown_db_error',
        ), 500);
    }

    $subject = 'קובץ חדש נשלח אליך דרך SeeDesktop';
    $html = "<div style='font-family: Arial, sans-serif; direction: rtl; border: 1px solid #e2e8f0; padding: 25px; border-radius: 12px; max-width: 600px; margin: auto;'>";
    $html .= "<h2 style='color: #0ea5e9; border-bottom: 2px solid #0ea5e9; padding-bottom: 10px;'>שלום {$rec_name},</h2>";
    $html .= "<p style='font-size: 16px;'>הטכנאי שלך (<strong>{$sender}</strong>) שלח אליך קובץ מאובטח להורדה.</p>";

    if (!empty($user_msg)) {
        $html .= "<div style='background: #f8fafc; padding: 15px; border-right: 4px solid #0ea5e9; margin: 20px 0; font-style: italic; color: #334155;'>";
        $html .= '<strong>הודעה מהשולח:</strong><br>' . nl2br(esc_html($user_msg));
        $html .= '</div>';
    }

    $html .= "<p style='color: #64748b; font-size: 14px;'>הקובץ יהיה זמין להורדה למשך 30 ימים.</p>";
    $html .= "<div style='text-align: center; margin-top: 30px;'>";
    $html .= "<a href='" . esc_url($download_link) . "' style='display:inline-block; padding:14px 28px; background-color:#0ea5e9; color:white; text-decoration:none; border-radius:8px; font-weight: bold; font-size: 16px;'>לחץ כאן להורדת הקובץ</a>";
    $html .= '</div>';
    $html .= "<p style='margin-top: 40px; font-size: 12px; color: #94a3b8; text-align: center;'>נשלח באמצעות מערכת העברת הקבצים של SeeDesktop</p>";
    $html .= '</div>';

    $headers = array('Content-Type: text/html; charset=UTF-8');
    wp_mail($rec_email, $subject, $html, $headers);

    sd_transfer_upsert_contact_from_recipient($sender, $rec_name, $rec_email);

    return new WP_REST_Response(array('success' => true), 200);
}

/**
 * עדכון ספר טלפונים אחרי שליחה (אותו מפתח ייחודי: sender + email נמען).
 */
function sd_transfer_upsert_contact_from_recipient($sender, $rec_name, $rec_email) {
    global $wpdb;

    $sender = sanitize_email($sender);
    $rec_email = sanitize_email($rec_email);
    if (empty($sender) || empty($rec_email)) {
        return;
    }

    $table_name = $wpdb->prefix . 'sd_transfer_contacts';
    $rec_name = sanitize_text_field($rec_name);

    // phpcs:ignore WordPress.DB.PreparedSQL.InterpolatedNotPrepared -- table name from prefix
    $sql = $wpdb->prepare(
        "INSERT INTO `$table_name` (sender_email, client_id, full_name, email, phone, notes)
        VALUES (%s, %s, %s, %s, %s, %s)
        ON DUPLICATE KEY UPDATE full_name = VALUES(full_name), updated_at = CURRENT_TIMESTAMP",
        $sender,
        '',
        $rec_name,
        $rec_email,
        '',
        ''
    );

    $wpdb->query($sql);
}

// 6b. GET אנשי קשר לפי מייל שולח
function sd_api_get_contacts($request) {
    global $wpdb;

    $email = sanitize_email($request->get_param('email'));
    if (empty($email)) {
        return new WP_REST_Response(array('error' => 'Email required'), 400);
    }

    $table_name = $wpdb->prefix . 'sd_transfer_contacts';
    $rows = $wpdb->get_results(
        $wpdb->prepare(
            "SELECT id, client_id, full_name, email, phone, notes, updated_at
             FROM $table_name
             WHERE sender_email = %s
             ORDER BY full_name ASC, email ASC",
            $email
        )
    );

    $out = array();
    foreach ($rows as $r) {
        $cid = !empty($r->client_id) ? $r->client_id : (string) $r->id;
        $out[] = array(
            'id' => $cid,
            'full_name' => $r->full_name,
            'email' => $r->email,
            'phone' => $r->phone,
            'notes' => $r->notes,
        );
    }

    return new WP_REST_Response($out, 200);
}

// 6c. POST סנכרון מלא (מחליף את הרשימה בשרת עבור השולח)
function sd_api_sync_contacts($request) {
    global $wpdb;

    $sender = sanitize_email($request->get_param('sender_email'));
    if (empty($sender)) {
        return new WP_REST_Response(array('success' => false, 'error' => 'sender_email required'), 400);
    }

    $contacts = $request->get_param('contacts');
    if (!is_array($contacts)) {
        return new WP_REST_Response(array('success' => false, 'error' => 'contacts must be array'), 400);
    }

    $table_name = $wpdb->prefix . 'sd_transfer_contacts';

    $wpdb->query('START TRANSACTION');

    $del = $wpdb->delete($table_name, array('sender_email' => $sender), array('%s'));
    if (false === $del) {
        $wpdb->query('ROLLBACK');
        return new WP_REST_Response(
            array(
                'success' => false,
                'error' => 'Failed to clear contacts',
                'detail' => $wpdb->last_error ?: 'delete_failed',
            ),
            500
        );
    }

    foreach ($contacts as $c) {
        if (!is_array($c)) {
            continue;
        }

        $client_id = isset($c['id']) ? sanitize_text_field((string) $c['id']) : '';
        $full_name = isset($c['full_name']) ? sanitize_text_field((string) $c['full_name']) : '';
        $em = isset($c['email']) ? sanitize_email((string) $c['email']) : '';
        if (empty($em)) {
            continue;
        }

        $phone = isset($c['phone']) ? sanitize_text_field((string) $c['phone']) : '';
        $notes = isset($c['notes']) ? sanitize_textarea_field((string) $c['notes']) : '';

        $ins = $wpdb->insert(
            $table_name,
            array(
                'sender_email' => $sender,
                'client_id' => $client_id,
                'full_name' => $full_name,
                'email' => $em,
                'phone' => $phone,
                'notes' => $notes,
            ),
            array('%s', '%s', '%s', '%s', '%s', '%s')
        );

        if (false === $ins) {
            $wpdb->query('ROLLBACK');
            return new WP_REST_Response(
                array(
                    'success' => false,
                    'error' => 'Insert failed',
                    'detail' => $wpdb->last_error ?: 'insert_failed',
                ),
                500
            );
        }
    }

    $wpdb->query('COMMIT');

    return new WP_REST_Response(array('success' => true), 200);
}

// 7. API Endpoint 3: היסטוריה
function sd_api_get_history($request) {
    global $wpdb;
    $email = sanitize_email($request->get_param('email'));

    if (empty($email)) {
        return new WP_REST_Response(array('error' => 'Email required'), 400);
    }

    $table_name = $wpdb->prefix . 'sd_file_transfers';
    $results = $wpdb->get_results(
        $wpdb->prepare(
            "SELECT recipient_name, recipient_email, file_name, download_link, message, created_at
         FROM $table_name
         WHERE sender_email = %s
         ORDER BY created_at DESC
         LIMIT 30",
            $email
        )
    );

    return new WP_REST_Response($results, 200);
}
