<?php
// Niche Club — API del panel de administración
declare(strict_types=1);

const ROOT        = __DIR__ . '/..';
const CATALOG     = ROOT . '/data/catalog.json';
const BACKUPS     = ROOT . '/data/backups';
const IMG_DIR     = ROOT . '/img';
const PRIVATE_DIR = __DIR__ . '/private';
const CONFIG      = PRIVATE_DIR . '/config.php';
const ATTEMPTS    = PRIVATE_DIR . '/attempts.json';
const TYPES       = ['Nicho', 'Diseñador', 'Árabe'];
const STATUSES    = ['Disponible', 'Agotado', 'Por encargo'];
const MAX_UPLOAD  = 8 * 1024 * 1024;
const KEEP_BACKUPS = 20;

ini_set('display_errors', '0');
date_default_timezone_set('America/Asuncion');

session_name('ncadmin');
session_set_cookie_params([
  'httponly' => true,
  'secure'   => !empty($_SERVER['HTTPS']) || ($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https',
  'samesite' => 'Strict',
  'path'     => '/',
]);
session_start();

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');

function out(array $data, int $code = 200): void {
  http_response_code($code);
  echo json_encode($data, JSON_UNESCAPED_UNICODE);
  exit;
}

function fail(string $msg, int $code = 400): void { out(['ok' => false, 'error' => $msg], $code); }

function body(): array {
  $raw = file_get_contents('php://input');
  $data = json_decode($raw ?: '[]', true);
  return is_array($data) ? $data : [];
}

function config(): ?array {
  if (!is_file(CONFIG)) return null;
  $c = include CONFIG;
  return is_array($c) ? $c : null;
}

function logged_in(): bool { return !empty($_SESSION['admin']); }

function require_login(): void {
  if (!logged_in()) fail('Sesión expirada. Volvé a ingresar.', 401);
  $token = $_SERVER['HTTP_X_CSRF'] ?? '';
  if (!hash_equals($_SESSION['csrf'] ?? '', $token)) fail('Token inválido. Recargá la página.', 403);
}

function start_session(): void {
  session_regenerate_id(true);
  $_SESSION['admin'] = true;
  $_SESSION['csrf'] = bin2hex(random_bytes(32));
}

// ---- Bloqueo por intentos fallidos (5 intentos → 15 minutos) ----
function attempts_load(): array {
  $a = is_file(ATTEMPTS) ? json_decode((string)file_get_contents(ATTEMPTS), true) : [];
  return is_array($a) ? $a : [];
}
function attempts_save(array $a): void {
  $now = time();
  $a = array_filter($a, fn($r) => ($r['until'] ?? 0) > $now || ($r['last'] ?? 0) > $now - 3600);
  file_put_contents(ATTEMPTS, json_encode($a), LOCK_EX);
}
function client_ip(): string { return $_SERVER['REMOTE_ADDR'] ?? '?'; }

// ---- Catálogo ----
function read_catalog(): array {
  $c = is_file(CATALOG) ? json_decode((string)file_get_contents(CATALOG), true) : null;
  if (!is_array($c) || !isset($c['products'])) $c = ['updated' => null, 'products' => []];
  return $c;
}

function slug(string $s): string {
  $s = iconv('UTF-8', 'ASCII//TRANSLIT//IGNORE', $s) ?: $s;
  $s = strtolower(preg_replace('/[^A-Za-z0-9]+/', '-', $s));
  return trim($s, '-') ?: 'producto';
}

function clean_product(array $p, int $i): array {
  $str = fn($k, $max = 120) => trim(mb_substr((string)($p[$k] ?? ''), 0, $max));
  $brand = $str('brand');
  $name  = $str('name');
  if ($brand === '' || $name === '') fail('El producto #' . ($i + 1) . ' necesita marca y nombre.');

  $type = $str('type');
  if (!in_array($type, TYPES, true)) fail("Tipo inválido en «$brand $name».");
  $status = $str('status');
  if (!in_array($status, STATUSES, true)) $status = 'Disponible';

  $p5  = (int)($p['p5'] ?? 0);
  $p10 = (int)($p['p10'] ?? 0);
  if ($p5 <= 0 || $p10 <= 0) fail("Revisá los precios de «$brand $name».");

  $img = $str('img', 200);
  if (!preg_match('#^img/[A-Za-z0-9._-]+\.(jpe?g|png|webp)$#i', $img) || !is_file(ROOT . '/' . $img)) {
    fail("Falta la foto de «$brand $name».");
  }

  $id = slug($str('id') ?: "$brand $name");

  $clean = [
    'id' => $id, 'brand' => $brand, 'name' => $name, 'type' => $type, 'img' => $img,
    'p5' => $p5, 'p10' => $p10, 'status' => $status, 'visible' => !empty($p['visible']),
  ];
  if (!empty($p['light'])) $clean['light'] = true;
  return $clean;
}

function save_catalog(array $products): array {
  $seen = [];
  $clean = [];
  foreach (array_values($products) as $i => $p) {
    if (!is_array($p)) fail('Datos inválidos.');
    $c = clean_product($p, $i);
    $base = $c['id']; $n = 2;
    while (isset($seen[$c['id']])) $c['id'] = $base . '-' . $n++;
    $seen[$c['id']] = true;
    $clean[] = $c;
  }
  if (!$clean) fail('El catálogo no puede quedar vacío.');

  if (!is_dir(BACKUPS)) mkdir(BACKUPS, 0755, true);
  if (is_file(CATALOG)) copy(CATALOG, BACKUPS . '/catalog-' . date('Ymd-His') . '.json');
  $old = glob(BACKUPS . '/catalog-*.json') ?: [];
  sort($old);
  foreach (array_slice($old, 0, max(0, count($old) - KEEP_BACKUPS)) as $f) unlink($f);

  $data = ['updated' => date('c'), 'products' => $clean];
  $json = json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) . "\n";
  $tmp = CATALOG . '.tmp';
  if (file_put_contents($tmp, $json, LOCK_EX) === false || !rename($tmp, CATALOG)) {
    fail('No se pudo guardar. Revisá los permisos de la carpeta data/.', 500);
  }
  return $data;
}

// ---- Fotos ----
function upload_image(): string {
  $f = $_FILES['file'] ?? null;
  if (!$f || ($f['error'] ?? 1) !== UPLOAD_ERR_OK) fail('No se recibió la imagen.');
  if ($f['size'] > MAX_UPLOAD) fail('La imagen pesa más de 8 MB.');
  $info = @getimagesize($f['tmp_name']);
  $ext = $info ? ([IMAGETYPE_JPEG => 'jpeg', IMAGETYPE_PNG => 'png', IMAGETYPE_WEBP => 'webp'][$info[2]] ?? null) : null;
  if (!$ext) fail('Formato no soportado. Usá JPG, PNG o WEBP.');

  $base = slug(pathinfo((string)($_POST['name'] ?? $f['name']), PATHINFO_FILENAME));
  $name = $base . '-' . substr(bin2hex(random_bytes(3)), 0, 6);
  $dest = IMG_DIR . '/' . $name . '.jpeg';

  // Reducir a 1200 px y pasar a JPG (las fotos del sitio pesan ~150 KB)
  if (function_exists('imagecreatetruecolor')) {
    $src = match ($ext) {
      'jpeg' => @imagecreatefromjpeg($f['tmp_name']),
      'png'  => @imagecreatefrompng($f['tmp_name']),
      'webp' => function_exists('imagecreatefromwebp') ? @imagecreatefromwebp($f['tmp_name']) : false,
    };
    if ($src) {
      [$w, $h] = [imagesx($src), imagesy($src)];
      $scale = min(1, 1200 / max($w, $h));
      $nw = (int)round($w * $scale); $nh = (int)round($h * $scale);
      $dst = imagecreatetruecolor($nw, $nh);
      imagefill($dst, 0, 0, imagecolorallocate($dst, 18, 18, 18));
      imagecopyresampled($dst, $src, 0, 0, 0, 0, $nw, $nh, $w, $h);
      if (imagejpeg($dst, $dest, 82)) return 'img/' . $name . '.jpeg';
    }
  }
  $dest = IMG_DIR . '/' . $name . '.' . $ext;
  if (!move_uploaded_file($f['tmp_name'], $dest)) fail('No se pudo guardar la imagen. Revisá los permisos de img/.', 500);
  return 'img/' . $name . '.' . $ext;
}

// ---- Rutas ----
$action = $_GET['action'] ?? '';

switch ($action) {
  case 'status':
    out(['ok' => true, 'setup' => config() === null, 'logged' => logged_in(), 'csrf' => logged_in() ? $_SESSION['csrf'] : null]);

  case 'setup':
    if (config() !== null) fail('El panel ya tiene contraseña.', 403);
    $pw = (string)(body()['password'] ?? '');
    if (mb_strlen($pw) < 10) fail('La contraseña debe tener al menos 10 caracteres.');
    if (!is_dir(PRIVATE_DIR)) mkdir(PRIVATE_DIR, 0755, true);
    $php = "<?php\nreturn " . var_export(['hash' => password_hash($pw, PASSWORD_DEFAULT)], true) . ";\n";
    if (file_put_contents(CONFIG, $php, LOCK_EX) === false) fail('No se pudo guardar la configuración. Revisá permisos de admin/private/.', 500);
    start_session();
    out(['ok' => true, 'csrf' => $_SESSION['csrf']]);

  case 'login':
    $cfg = config();
    if (!$cfg) fail('Primero creá la contraseña.', 403);
    $ip = client_ip();
    $all = attempts_load();
    $rec = $all[$ip] ?? ['count' => 0, 'until' => 0, 'last' => 0];
    if ($rec['until'] > time()) fail('Demasiados intentos. Probá de nuevo en ' . ceil(($rec['until'] - time()) / 60) . ' min.', 429);
    if (!password_verify((string)(body()['password'] ?? ''), $cfg['hash'])) {
      $rec['count']++; $rec['last'] = time();
      if ($rec['count'] >= 5) { $rec['until'] = time() + 900; $rec['count'] = 0; }
      $all[$ip] = $rec; attempts_save($all);
      usleep(600000);
      fail('Contraseña incorrecta.', 401);
    }
    unset($all[$ip]); attempts_save($all);
    start_session();
    out(['ok' => true, 'csrf' => $_SESSION['csrf']]);

  case 'logout':
    $_SESSION = [];
    session_destroy();
    out(['ok' => true]);

  case 'password':
    require_login();
    $b = body();
    if (!password_verify((string)($b['current'] ?? ''), config()['hash'] ?? '')) fail('La contraseña actual no es correcta.');
    $pw = (string)($b['password'] ?? '');
    if (mb_strlen($pw) < 10) fail('La nueva contraseña debe tener al menos 10 caracteres.');
    $php = "<?php\nreturn " . var_export(['hash' => password_hash($pw, PASSWORD_DEFAULT)], true) . ";\n";
    file_put_contents(CONFIG, $php, LOCK_EX);
    out(['ok' => true]);

  case 'catalog':
    require_login();
    out(['ok' => true, 'catalog' => read_catalog(), 'types' => TYPES, 'statuses' => STATUSES]);

  case 'save':
    require_login();
    $products = body()['products'] ?? null;
    if (!is_array($products)) fail('Datos inválidos.');
    out(['ok' => true, 'catalog' => save_catalog($products)]);

  case 'upload':
    require_login();
    out(['ok' => true, 'img' => upload_image()]);

  case 'backups':
    require_login();
    $files = glob(BACKUPS . '/catalog-*.json') ?: [];
    rsort($files);
    out(['ok' => true, 'backups' => array_map('basename', $files)]);

  case 'restore':
    require_login();
    $file = basename((string)(body()['file'] ?? ''));
    if (!preg_match('/^catalog-\d{8}-\d{6}\.json$/', $file) || !is_file(BACKUPS . '/' . $file)) fail('Copia no encontrada.');
    $data = json_decode((string)file_get_contents(BACKUPS . '/' . $file), true);
    if (!is_array($data['products'] ?? null)) fail('La copia está dañada.');
    out(['ok' => true, 'catalog' => save_catalog($data['products'])]);

  default:
    fail('Acción desconocida.', 404);
}
